package com.lonx.lyrico.remote.smb

import com.hierynomus.smbj.SMBClient
import com.lonx.lyrico.remote.RemoteAuthException
import com.rapid7.client.dcerpc.mssrvs.ServerService
import com.rapid7.client.dcerpc.transport.SMBTransportFactories

/**
 * Share enumeration (NetrShareEnum over the srvsvc named pipe) via smbj-rpc (com.rapid7.client:dcerpc).
 * Kept in its own file: if the integration decides not to ship the dcerpc dependency, delete this file and
 * SmbStorage still compiles (the folder UI then asks the user to type the share name).
 */
data class SmbShareInfo(val name: String, val remark: String)

/** Lists the browsable disk shares on [host] ("host[:port]"). Blocking; call off the main thread. */
fun SmbStorage.Companion.listShares(
    host: String,
    user: String,
    pass: String,
    domain: String = "",
): List<SmbShareInfo> {
    val hp = SmbPaths.parseHost(host)
    val hostDesc = "${hp.host}:${hp.port}"
    try {
        SMBClient(buildSmbConfig()).use { client ->
            client.connect(hp.host, hp.port).use { conn ->
                authenticate(conn, user, pass, domain).use { session ->
                    val transport = SMBTransportFactories.SRVSVC.getTransport(session)
                    val shares = ServerService(transport).shares1
                    return SmbShareFilter.diskShares(shares.map { Triple(it.netName, it.type, it.remark) })
                }
            }
        }
    } catch (e: RemoteAuthException) {
        throw e
    } catch (e: Exception) {
        throw SmbErrors.map(e, "share list of $hostDesc", hostDesc)
    }
}

/** Pure filtering of NetShareInfo1 rows: keep plain disk shares, drop IPC$/printers/admin (special) shares. */
internal object SmbShareFilter {
    private const val STYPE_MASK = 0x0FFFFFFF
    private const val STYPE_DISKTREE = 0
    private const val STYPE_SPECIAL = 0x80000000.toInt()

    fun diskShares(rows: List<Triple<String?, Int, String?>>): List<SmbShareInfo> = rows
        .asSequence()
        .filter { (name, type, _) ->
            !name.isNullOrBlank() &&
                (type and STYPE_MASK) == STYPE_DISKTREE &&
                (type and STYPE_SPECIAL) == 0 &&
                !name.endsWith("$")
        }
        .map { (name, _, remark) -> SmbShareInfo(name!!.trim(), remark.orEmpty()) }
        .distinctBy { it.name.lowercase() }
        .sortedBy { it.name.lowercase() }
        .toList()
}
