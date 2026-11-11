package com.lonx.lyrico.remote.webdav

import okhttp3.Authenticator
import okhttp3.Challenge
import okhttp3.Credentials
import okhttp3.Interceptor
import okhttp3.Request
import okhttp3.Response
import okhttp3.Route
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * HTTP Basic + Digest (RFC 7616: MD5, MD5-sess, SHA-256, SHA-256-sess, qop=auth) for OkHttp.
 *
 * Install as both [Authenticator] (answers 401 challenges) and network-independent [Interceptor]
 * (adds the header preemptively once the scheme is known, saving a round trip per request,
 * which matters for PUT uploads).
 */
internal class HttpAuth(private val username: String, private val password: String) : Authenticator, Interceptor {

    private class DigestState(val realm: String, val nonce: String, val opaque: String?, val algorithm: String, val qop: String?) {
        var nc = 0
    }

    @Volatile private var basicKnown = false
    @Volatile private var digest: DigestState? = null
    private val random = SecureRandom()

    private val hasCredentials get() = username.isNotEmpty() || password.isNotEmpty()

    override fun intercept(chain: Interceptor.Chain): Response {
        val req = chain.request()
        if (!hasCredentials || req.header("Authorization") != null) return chain.proceed(req)
        val header = synchronized(this) {
            val d = digest
            when {
                d != null -> digestHeader(req, d)
                basicKnown -> Credentials.basic(username, password, Charsets.UTF_8)
                else -> null
            }
        }
        return chain.proceed(if (header == null) req else req.newBuilder().header("Authorization", header).build())
    }

    override fun authenticate(route: Route?, response: Response): Request? {
        if (!hasCredentials) return null
        if (priorCount(response) >= 3) return null
        val challenges = response.challenges()
        val digestChallenge = pickDigest(challenges)
        val sentAuth = response.request.header("Authorization")

        synchronized(this) {
            if (digestChallenge != null) {
                val stale = digestChallenge.authParams["stale"].equals("true", ignoreCase = true)
                // Our digest was already rejected and the nonce is not merely stale -> wrong credentials.
                // (A fresh nonce without stale=true is retried once: some servers expire nonces silently.)
                val sentNonce = sentAuth?.let { Regex("nonce=\"([^\"]*)\"").find(it)?.groupValues?.get(1) }
                if (sentAuth != null && sentAuth.startsWith("Digest", true) && !stale &&
                    (sentNonce == digestChallenge.authParams["nonce"] || response.priorResponse != null)
                ) {
                    digest = null
                    return null
                }
                val p = digestChallenge.authParams
                val nonce = p["nonce"] ?: return null
                val qopOffered = p["qop"]
                val qop = qopOffered?.split(',')?.map { it.trim() }?.let { opts ->
                    when {
                        opts.any { it.equals("auth", true) } -> "auth"
                        else -> return null // auth-int only: unsupported
                    }
                }
                val state = DigestState(
                    realm = p["realm"] ?: "",
                    nonce = nonce,
                    opaque = p["opaque"],
                    algorithm = p["algorithm"] ?: "MD5",
                    qop = qop,
                )
                if (hashName(state.algorithm) == null) return null
                digest = state
                basicKnown = false
                return response.request.newBuilder().header("Authorization", digestHeader(response.request, state)).build()
            }
            val basic = challenges.firstOrNull { it.scheme.equals("Basic", true) }
            // Some servers send 401 without a challenge header at all; Basic is the only sensible guess.
            if (basic == null && challenges.isNotEmpty()) return null
            if (sentAuth != null && sentAuth.startsWith("Basic", true)) {
                basicKnown = false
                return null
            }
            basicKnown = true
            val charset = basic?.charset ?: Charsets.UTF_8
            return response.request.newBuilder()
                .header("Authorization", Credentials.basic(username, password, charset))
                .build()
        }
    }

    private fun pickDigest(challenges: List<Challenge>): Challenge? {
        val digests = challenges.filter { it.scheme.equals("Digest", true) && it.authParams["nonce"] != null }
        return digests.firstOrNull { (it.authParams["algorithm"] ?: "").startsWith("SHA-256", true) }
            ?: digests.firstOrNull { hashName(it.authParams["algorithm"] ?: "MD5") != null }
    }

    private fun priorCount(response: Response): Int {
        var n = 0
        var r = response.priorResponse
        while (r != null) { n++; r = r.priorResponse }
        return n
    }

    private fun digestHeader(request: Request, d: DigestState): String {
        val algo = d.algorithm
        val hash = hashName(algo)!!
        val uri = request.url.encodedPath + (request.url.encodedQuery?.let { "?$it" } ?: "")
        val cnonce = ByteArray(8).also { random.nextBytes(it) }.joinToString("") { "%02x".format(it) }
        d.nc++
        val nc = "%08x".format(d.nc)
        var ha1 = h(hash, "$username:${d.realm}:$password")
        if (algo.endsWith("-sess", true)) ha1 = h(hash, "$ha1:${d.nonce}:$cnonce")
        val ha2 = h(hash, "${request.method}:$uri")
        val resp = if (d.qop != null) h(hash, "$ha1:${d.nonce}:$nc:$cnonce:${d.qop}:$ha2") else h(hash, "$ha1:${d.nonce}:$ha2")
        val sb = StringBuilder("Digest ")
        sb.append("username=\"").append(quote(username)).append("\", ")
        sb.append("realm=\"").append(quote(d.realm)).append("\", ")
        sb.append("nonce=\"").append(quote(d.nonce)).append("\", ")
        sb.append("uri=\"").append(quote(uri)).append("\", ")
        sb.append("algorithm=").append(algo).append(", ")
        sb.append("response=\"").append(resp).append("\"")
        if (d.qop != null) sb.append(", qop=").append(d.qop).append(", nc=").append(nc).append(", cnonce=\"").append(cnonce).append("\"")
        if (d.opaque != null) sb.append(", opaque=\"").append(quote(d.opaque)).append("\"")
        return sb.toString()
    }

    private fun quote(s: String) = s.replace("\\", "\\\\").replace("\"", "\\\"")

    companion object {
        fun hashName(algorithm: String): String? = when (algorithm.uppercase().removeSuffix("-SESS")) {
            "MD5" -> "MD5"
            "SHA-256" -> "SHA-256"
            else -> null
        }

        fun h(hash: String, s: String): String =
            MessageDigest.getInstance(hash).digest(s.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
    }
}
