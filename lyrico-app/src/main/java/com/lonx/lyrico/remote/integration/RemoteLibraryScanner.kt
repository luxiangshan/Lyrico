package com.lonx.lyrico.remote.integration

import android.net.Uri
import android.util.Log
import com.lonx.lyrico.data.model.SongFile
import com.lonx.lyrico.data.model.entity.FolderEntity
import com.lonx.lyrico.remote.RemoteAuthException
import com.lonx.lyrico.remote.RemoteEntry
import java.util.Locale
import kotlin.math.abs

data class RemoteScannedSong(
    val songFile: SongFile,
    val rootFolderId: Long,
    /** Display folder path, `remote://<configId>/dir/sub`. */
    val folderPath: String,
    val configId: String,
    val entry: RemoteEntry,
)

data class RemoteScanResult(
    val songs: List<RemoteScannedSong>,
    val successfulFolderIds: Set<Long>,
    val failedFolders: Map<Long, String>,
)

/** A remote folder chosen by the user, together with its FolderEntity row. */
data class RemoteRootFolder(
    val folder: FolderEntity,
    val configId: String,
    val remotePath: String,
)

/**
 * Lists audio files below the user's chosen remote folders (recursively). Tag reading itself happens
 * in LibraryScanRepositoryImpl through the regular AudioTagRepository → AudioFileAccess path.
 */
class RemoteLibraryScanner(
    private val configRepository: RemoteConfigRepository,
    private val storageManager: RemoteStorageManager,
    val fileCache: RemoteFileCache,
) {

    /** Remote root folders among [allFolders]: FolderEntity rows whose path is a chosen folder of a saved location. */
    suspend fun rootFolders(allFolders: List<FolderEntity>): List<RemoteRootFolder> {
        val byPath = allFolders.associateBy { it.path.trimEnd('/') }
        return configRepository.getAll().flatMap { config ->
            topLevelFolders(config.folders).mapNotNull { remotePath ->
                val display = RemoteUri.displayPath(config.id, remotePath)
                byPath[display]?.let { RemoteRootFolder(it, config.id, remotePath) }
            }
        }
    }

    /** Blocking. Walks every root; a failing root is reported and its songs are left untouched. */
    fun scan(roots: List<RemoteRootFolder>, onFolder: (String) -> Unit = {}): RemoteScanResult {
        val songs = mutableListOf<RemoteScannedSong>()
        val ok = mutableSetOf<Long>()
        val failed = mutableMapOf<Long, String>()
        val seen = mutableSetOf<String>()
        for (root in roots) {
            try {
                val storage = storageManager.storage(root.configId)
                val found = mutableListOf<RemoteScannedSong>()
                walk(root, storage::list, root.remotePath, 0, found, seen, onFolder)
                songs += found
                ok += root.folder.id
            } catch (e: Exception) {
                if (e is RemoteAuthException) storageManager.invalidate(root.configId)
                Log.e(TAG, "Remote scan failed: ${root.folder.path}", e)
                failed[root.folder.id] = e.message ?: e::class.java.simpleName
            }
        }
        return RemoteScanResult(songs, ok, failed)
    }

    private fun walk(
        root: RemoteRootFolder,
        list: (String) -> List<RemoteEntry>,
        dir: String,
        depth: Int,
        out: MutableList<RemoteScannedSong>,
        seen: MutableSet<String>,
        onFolder: (String) -> Unit,
    ) {
        if (depth > MAX_DEPTH) return
        onFolder(dir)
        val entries = list(dir)
        for (entry in entries) {
            val name = entry.name.ifBlank { RemoteUri.fileName(entry.path) }
            val path = RemoteUri.normalizePath(entry.path.ifBlank { RemoteUri.childPath(dir, name) })
            if (entry.isDirectory) {
                if (shouldSkipDirectory(name) || path == RemoteUri.normalizePath(dir)) continue
                walk(root, list, path, depth + 1, out, seen, onFolder)
                continue
            }
            if (!RemoteUri.isSupportedAudio(name)) continue
            val uri = RemoteUri.build(root.configId, path)
            if (!seen.add(uri)) continue
            val displayPath = RemoteUri.displayPath(root.configId, path)
            out += RemoteScannedSong(
                songFile = SongFile(
                    mediaId = virtualMediaId(uri),
                    uri = Uri.parse(uri),
                    filePath = displayPath,
                    fileName = name,
                    lastModified = entry.modifiedMillis,
                    dateAdded = entry.modifiedMillis,
                    duration = 0,
                    fileSize = entry.size.coerceAtLeast(0),
                ),
                rootFolderId = root.folder.id,
                folderPath = RemoteUri.displayPath(root.configId, RemoteUri.parentPath(path)),
                configId = root.configId,
                entry = entry.copy(path = path, name = name),
            )
        }
    }

    private fun shouldSkipDirectory(name: String): Boolean {
        val normalized = name.lowercase(Locale.ROOT)
        return normalized.startsWith(".") || normalized == "@eadir" || normalized == "#recycle" ||
            normalized == "\$recycle.bin" || normalized == "system volume information"
    }

    private fun virtualMediaId(uri: String): Long = -abs(uri.hashCode().toLong()).coerceAtLeast(1L)

    companion object {
        private const val TAG = "RemoteLibraryScanner"
        private const val MAX_DEPTH = 32

        /** Drops folders nested inside another chosen folder of the same location. */
        fun topLevelFolders(folders: List<String>): List<String> {
            val normalized = folders.map(RemoteUri::normalizePath).distinct()
            return normalized.filter { candidate ->
                normalized.none { other ->
                    other != candidate && (other == "/" || candidate.startsWith("$other/"))
                }
            }
        }
    }
}
