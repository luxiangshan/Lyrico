package com.lonx.lyrico.remote.cloud115

import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.util.Base64

/** File digests used by 115 upload (port of 115driver pkg/crypto/digest.go and UploadDigestRange). */
object Cloud115Hash {
    const val PRE_HASH_SIZE = 128 * 1024

    data class Digest(
        val size: Long,
        /** Upper-case hex SHA-1 of the first 128 KiB. */
        val preId: String,
        /** Upper-case hex SHA-1 of the whole file (115 "fileid"/quick id). */
        val sha1: String,
        /** Base64 MD5 of the whole file (OSS Content-MD5). */
        val md5Base64: String,
    )

    fun digest(file: File): Digest {
        val sha = MessageDigest.getInstance("SHA-1")
        val md5 = MessageDigest.getInstance("MD5")
        var preId: String? = null
        var total = 0L
        file.inputStream().buffered(64 * 1024).use { input ->
            val buf = ByteArray(64 * 1024)
            while (true) {
                val want = if (preId == null) minOf(buf.size.toLong(), PRE_HASH_SIZE - total).toInt() else buf.size
                val n = input.read(buf, 0, want)
                if (n < 0) break
                sha.update(buf, 0, n); md5.update(buf, 0, n)
                total += n
                if (preId == null && total >= PRE_HASH_SIZE) {
                    preId = hexUpper((sha.clone() as MessageDigest).digest())
                }
            }
        }
        val full = hexUpper(sha.digest())
        return Digest(total, preId ?: full, full, Base64.getEncoder().encodeToString(md5.digest()))
    }

    /** SHA-1 (upper hex) of the inclusive byte range "start-end" (115 `sign_check`). */
    fun rangeSha1(file: File, rangeSpec: String): String {
        val parts = rangeSpec.trim().split("-")
        if (parts.size != 2) throw IOException("bad sign_check range: $rangeSpec")
        val start = parts[0].trim().toLong()
        val end = parts[1].trim().toLong()
        if (start < 0 || end < start) throw IOException("bad sign_check range: $rangeSpec")
        val sha = MessageDigest.getInstance("SHA-1")
        RandomAccessFile(file, "r").use { raf ->
            raf.seek(start)
            var remaining = end - start + 1
            val buf = ByteArray(64 * 1024)
            while (remaining > 0) {
                val n = raf.read(buf, 0, minOf(buf.size.toLong(), remaining).toInt())
                if (n < 0) throw IOException("sign_check range beyond end of file")
                sha.update(buf, 0, n)
                remaining -= n
            }
        }
        return hexUpper(sha.digest())
    }

    fun hexUpper(b: ByteArray): String = hex(b).uppercase()

    fun hex(b: ByteArray): String {
        val sb = StringBuilder(b.size * 2)
        for (x in b) {
            val v = x.toInt() and 0xff
            sb.append("0123456789abcdef"[v ushr 4]).append("0123456789abcdef"[v and 0xf])
        }
        return sb.toString()
    }

    fun sha1Hex(s: String): String = hex(MessageDigest.getInstance("SHA-1").digest(s.toByteArray(Charsets.UTF_8)))
    fun md5Hex(s: String): String = hex(MessageDigest.getInstance("MD5").digest(s.toByteArray(Charsets.UTF_8)))

    /** Upload `sig` (115driver GenerateSignature). */
    fun uploadSignature(userId: String, userKey: String, fileId: String, target: String): String =
        sha1Hex(userKey + sha1Hex(userId + fileId + target + "0") + "000000").uppercase()

    /** Upload `token` (115driver GenerateToken). */
    fun uploadToken(
        userId: String, fileId: String, fileSize: String, signKey: String, signVal: String,
        timestamp: String, appVer: String,
    ): String = md5Hex(UPLOAD_MD5_SALT + fileId + fileSize + signKey + signVal + userId + timestamp + md5Hex(userId) + appVer)

    private const val UPLOAD_MD5_SALT = "Qclm8MGWUv59TnrR0XPg"
}
