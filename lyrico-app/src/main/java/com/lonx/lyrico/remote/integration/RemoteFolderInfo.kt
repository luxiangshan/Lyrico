package com.lonx.lyrico.remote.integration

import com.lonx.lyrico.data.model.entity.FolderEntity
import com.lonx.lyrico.remote.RemoteConfig
import com.lonx.lyrico.remote.RemoteType

/** How the Folder Manager shows a `remote://` folder row. */
data class RemoteFolderInfo(
    val config: RemoteConfig?,
    val configId: String,
    /** Path inside the remote location, e.g. "/Music/Rock". */
    val remotePath: String,
    /** True when this row is one of the folders the user chose for the location. */
    val isRoot: Boolean,
) {
    val typeBadge: String
        get() = config?.type?.let(::badgeOf) ?: "Remote"

    /** Name shown in the list / title / breadcrumb. */
    fun label(): String {
        val name = config?.displayName?.ifBlank { null } ?: typeBadge
        return if (isRoot) {
            if (remotePath == "/") name else "$name · ${RemoteUri.fileName(remotePath)}"
        } else {
            RemoteUri.fileName(remotePath).ifBlank { name }
        }
    }

    /** Secondary line: server + path. */
    fun subtitle(): String {
        val c = config ?: return remotePath
        val server = when (c.type) {
            RemoteType.SMB -> listOf(c.baseUrl, c.share).filter { it.isNotBlank() }.joinToString("/")
            RemoteType.CLOUD115 -> "115"
            else -> c.baseUrl
        }
        return if (server.isBlank()) remotePath else "$server  $remotePath"
    }

    companion object {
        fun badgeOf(type: RemoteType): String = when (type) {
            RemoteType.WEBDAV -> "WebDAV"
            RemoteType.OPENLIST -> "OpenList"
            RemoteType.SMB -> "SMB"
            RemoteType.CLOUD115 -> "115"
        }

        fun resolve(folder: FolderEntity, configs: Map<String, RemoteConfig>): RemoteFolderInfo? {
            val parsed = RemoteUri.parseDisplayPath(folder.path) ?: return null
            val config = configs[parsed.configId]
            val isRoot = config?.folders.orEmpty().any { RemoteUri.normalizePath(it) == parsed.path }
            return RemoteFolderInfo(config, parsed.configId, parsed.path, isRoot)
        }
    }
}
