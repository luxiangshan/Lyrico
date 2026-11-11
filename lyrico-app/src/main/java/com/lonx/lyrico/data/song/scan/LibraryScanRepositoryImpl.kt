package com.lonx.lyrico.data.song.scan

import com.lonx.lyrico.data.model.log.recordOperation
import com.lonx.lyrico.data.model.log.withLogOperation

import android.content.Context
import android.util.Log
import androidx.room.withTransaction
import com.lonx.audiotag.model.CustomTagField
import com.lonx.lyrico.data.LyricoDatabase
import com.lonx.lyrico.data.LibraryOperationLock
import com.lonx.lyrico.data.model.SongFile
import com.lonx.lyrico.data.model.entity.SongEntity
import com.lonx.lyrico.data.model.log.AppLogLevel
import com.lonx.lyrico.data.model.log.AppLogType
import com.lonx.lyrico.data.repository.AppLogRepository
import com.lonx.lyrico.data.repository.LibraryIndexRepository
import com.lonx.lyrico.data.repository.SettingsRepository
import com.lonx.lyrico.data.song.mapper.SongMetadataMapper
import com.lonx.lyrico.data.song.search.LyricFtsIndexer
import com.lonx.lyrico.data.song.tag.AudioTagReadOptions
import com.lonx.lyrico.data.song.tag.AudioTagRepository
import com.lonx.lyrico.utils.MediaScanner
import com.lonx.lyrico.utils.LyricsSearchTextExtractor
import com.lonx.lyrico.utils.UriUtils
import com.lonx.lyrico.remote.integration.RemoteLibraryScanner
import com.lonx.lyrico.remote.integration.RemoteRootFolder
import com.lonx.lyrico.remote.integration.RemoteScanResult
import com.lonx.lyrico.remote.integration.RemoteUri
import com.lonx.lyrico.remote.integration.RemoteCoverPick
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext

class LibraryScanRepositoryImpl(
    private val context: Context,
    private val database: LyricoDatabase,
    private val mediaScanner: MediaScanner,
    private val settingsRepository: SettingsRepository,
    private val audioTagRepository: AudioTagRepository,
    private val songMetadataMapper: SongMetadataMapper,
    private val libraryIndexRepository: LibraryIndexRepository,
    private val appLogRepository: AppLogRepository,
    private val operationLock: LibraryOperationLock,
    /** Lyrico Mod: remote (WebDAV / OpenList / SMB / 115) folders. */
    private val remoteScanner: RemoteLibraryScanner? = null,
) : LibraryScanRepository {

    private val songDao = database.songDao()
    private val folderDao = database.folderDao()

    override suspend fun synchronize(
        request: LibraryScanRequest,
        onProgress: suspend (LibraryScanProgress) -> Unit
    ): LibraryScanResult {
        return operationLock.withLock {
            withContext(Dispatchers.IO) {
                withLogOperation("library-scan") { synchronizeLocked(request, onProgress) }
            }
        }
    }

    private suspend fun synchronizeLocked(
        request: LibraryScanRequest,
        onProgress: suspend (LibraryScanProgress) -> Unit
    ): LibraryScanResult {
        val started = System.nanoTime()
        var filteredShort = 0
        var unchanged = 0
        try {
            Log.d(TAG, "Start library sync: fullRescan=${request.fullRescan}")
            onProgress(LibraryScanProgress(stage = LibraryScanStage.LISTING_FILES))

            val removedSafFolders = if (request.removeMissingSafFolders) {
                removeSafFoldersWithoutPermission()
            } else {
                0
            }
            val dbSyncInfos = songDao.getAllSyncInfo()
            val dbSongMap = dbSyncInfos.associateBy { it.uri }

            val deviceUris = mutableSetOf<String>()
            val impactedFolderIds = mutableSetOf<Long>()
            val failures = mutableListOf<LibraryScanFailure>()
            val songsToUpsert = mutableListOf<ScannedSongMetadata>()
            val minDuration = 60_000L
            val indexLyrics = settingsRepository.lyricIndexEnabled.first()
            val unchangedSongUris = mutableListOf<String>()

            val safFolders = if (request.folderIds == null) {
                folderDao.getSafFolders()
            } else {
                folderDao.getScanRootFoldersFor(request.folderIds)
            }
            val safFolderById = safFolders.associateBy { it.id }
            val safScanResult = mediaScanner.querySongsFromSafFolders(safFolders)
            val deviceSongs = safScanResult.songs
            safScanResult.failedFolderIds.forEach { folderId ->
                val folder = safFolderById.getValue(folderId)
                failures.add(
                    LibraryScanFailure(
                        uri = folder.treeUri,
                        fileName = folder.path,
                        stage = LibraryScanFailureStage.Collecting,
                        message = "无法读取目录，请检查存储状态和访问权限"
                    )
                )
            }
            // Lyrico Mod: enumerate remote folders and merge them into the same processing loop.
            val remoteRoots = selectRemoteRoots(request.folderIds)
            val remoteScanResult = if (remoteRoots.isEmpty() || remoteScanner == null) {
                RemoteScanResult(emptyList(), emptySet(), emptyMap())
            } else {
                remoteScanner.scan(remoteRoots)
            }
            val remoteRootById = remoteRoots.associateBy { it.folder.id }
            remoteScanResult.failedFolders.forEach { (folderId, message) ->
                val root = remoteRootById[folderId]
                failures.add(
                    LibraryScanFailure(
                        uri = root?.folder?.path,
                        fileName = root?.folder?.path,
                        stage = LibraryScanFailureStage.Collecting,
                        message = "无法读取远程目录：$message"
                    )
                )
            }
            val candidates: List<ScanCandidate> =
                deviceSongs.map { ScanCandidate(it.songFile, it.rootFolderId, it.folderPath, "SAF") } +
                    remoteScanResult.songs.map {
                        ScanCandidate(it.songFile, it.rootFolderId, it.folderPath, RemoteUri.SOURCE, it.configId, it.entry)
                    }
            val rootFolderById = safFolderById + remoteRootById.mapValues { it.value.folder }

            appLogRepository.recordOperation(AppLogType.APP, TAG, "Scan enumeration finished",
                "fullRescan=${request.fullRescan}\nignoreShortAudio=${request.ignoreShortAudio}\nindexLyrics=$indexLyrics\n" +
                    "roots=${safFolders.map { it.id }}\nfiles=${deviceSongs.size}\n" +
                    "successfulRoots=${safScanResult.successfulFolderIds}\nfailedRoots=${safScanResult.failedFolderIds}\nmissingRoots=${safScanResult.missingFolderIds}\n" +
                    "remoteRoots=${remoteRoots.map { it.folder.id }}\nremoteFiles=${remoteScanResult.songs.size}\nremoteFailed=${remoteScanResult.failedFolders.keys}",
                level = if (safScanResult.failedFolderIds.isEmpty()) AppLogLevel.DEBUG else AppLogLevel.WARNING)

            onProgress(
                LibraryScanProgress(
                    stage = LibraryScanStage.READING_METADATA,
                    current = 0,
                    total = candidates.size
                )
            )

            // Lyrico Mod: candidates are processed in windows. Within a window the per-file plan (and the
            // folder rows) are prepared sequentially, tag reads run in parallel (remote files with
            // REMOTE_CONCURRENCY partial reads, local files one at a time as before), and results are then
            // applied in order. New/changed songs are written to the database every FLUSH_EVERY songs so
            // the song list fills progressively during long (remote) scans.
            val remoteSemaphore = Semaphore(REMOTE_CONCURRENCY)
            val localSemaphore = Semaphore(1)
            val pendingFlush = mutableListOf<ScannedSongMetadata>()
            var processed = 0

            suspend fun flushPending() {
                if (pendingFlush.isEmpty()) return
                val batch = pendingFlush.toList()
                pendingFlush.clear()
                writeSongs(batch, indexLyrics)
            }

            for (window in candidates.withIndex().chunked(SCAN_WINDOW)) {
                val plans = mutableListOf<ScanPlan>()
                for ((index, scannedSong) in window) {
                    val deviceSong = scannedSong.songFile
                    try {
                        val deviceUriString = deviceSong.uri.toString()
                        val dbInfo = dbSongMap[deviceUriString]
                        val needsUpdate = request.fullRescan ||
                            dbInfo == null ||
                            dbInfo.fileLastModified != deviceSong.lastModified ||
                            dbInfo.fileSize != deviceSong.fileSize ||
                            dbInfo.filePath != deviceSong.filePath
                        val knownDuration = when {
                            deviceSong.duration > 0L -> deviceSong.duration
                            !needsUpdate -> dbInfo.durationMilliseconds.toLong()
                            else -> 0L
                        }
                        if (request.ignoreShortAudio && knownDuration > 0L && knownDuration <= minDuration) {
                            filteredShort++
                            if (filteredShort <= 20) appLogRepository.recordOperation(AppLogType.APP, TAG, "Scan skipped short audio",
                                "uri=$deviceUriString\ndurationMs=$knownDuration\nthresholdMs=$minDuration", deviceUriString)
                            plans += ScanPlan(index, scannedSong, ScanAction.SKIP)
                            continue
                        }
                        if (!needsUpdate) {
                            plans += ScanPlan(index, scannedSong, ScanAction.UNCHANGED)
                            continue
                        }
                        val rootFolder = rootFolderById[scannedSong.rootFolderId]
                        val folderId = folderDao.upsertScannedFolderTreeAndGetLeafId(
                            rootPath = rootFolder?.path ?: scannedSong.folderPath,
                            folderPath = scannedSong.folderPath,
                            isIgnored = rootFolder?.isIgnored ?: false
                        )
                        impactedFolderIds.add(folderId)
                        plans += ScanPlan(index, scannedSong, ScanAction.READ, folderId, dbInfo?.id ?: 0L)
                    } catch (e: Exception) {
                        if (e is kotlinx.coroutines.CancellationException) throw e
                        plans += ScanPlan(index, scannedSong, ScanAction.FAILED, error = e)
                    }
                }

                val results: List<Result<ScannedSongMetadata?>?> = coroutineScope {
                    plans.map { plan ->
                        if (plan.action != ScanAction.READ) return@map null
                        val semaphore = if (plan.candidate.remoteConfigId != null) remoteSemaphore else localSemaphore
                        async(Dispatchers.IO) {
                            semaphore.withPermit {
                                try {
                                    Result.success(
                                        extractSongMetadata(
                                            songFile = plan.candidate.songFile,
                                            folderId = plan.folderId,
                                            existingId = plan.existingId,
                                            source = plan.candidate.source,
                                            indexLyrics = indexLyrics,
                                            remote = plan.candidate.remoteConfigId != null,
                                        )
                                    )
                                } catch (e: Exception) {
                                    if (e is kotlinx.coroutines.CancellationException) throw e
                                    Result.failure(e)
                                }
                            }
                        }
                    }.map { it?.await() }
                }

                for ((i, plan) in plans.withIndex()) {
                    val deviceSong = plan.candidate.songFile
                    val deviceUriString = deviceSong.uri.toString()
                    when (plan.action) {
                        ScanAction.SKIP -> Unit
                        ScanAction.UNCHANGED -> {
                            unchanged++
                            if (indexLyrics) unchangedSongUris.add(deviceUriString)
                            deviceUris.add(deviceUriString)
                        }
                        ScanAction.READ, ScanAction.FAILED -> {
                            val result = results[i]
                            val error = plan.error ?: result?.exceptionOrNull()
                            if (error != null) {
                                // The file was enumerated; a read failure alone cannot confirm its deletion.
                                deviceUris.add(deviceUriString)
                                Log.e(TAG, "Failed to process song: ${deviceSong.fileName}", error)
                                failures.add(
                                    LibraryScanFailure(
                                        uri = deviceUriString,
                                        fileName = deviceSong.fileName,
                                        stage = LibraryScanFailureStage.ReadingMetadata,
                                        message = error.message ?: error::class.java.simpleName,
                                        throwable = error
                                    )
                                )
                            } else {
                                val metadata = result?.getOrNull()
                                if (
                                    request.ignoreShortAudio &&
                                    metadata != null &&
                                    metadata.entity.durationMilliseconds > 0 &&
                                    metadata.entity.durationMilliseconds <= minDuration
                                ) {
                                    filteredShort++
                                    if (filteredShort <= 20) appLogRepository.recordOperation(AppLogType.APP, TAG, "Scan skipped short audio after tag read",
                                        "uri=$deviceUriString\ndurationMs=${metadata.entity.durationMilliseconds}\nthresholdMs=$minDuration", deviceUriString)
                                } else {
                                    if (metadata != null) {
                                        songsToUpsert.add(metadata)
                                        pendingFlush.add(metadata)
                                    }
                                    deviceUris.add(deviceUriString)
                                }
                            }
                        }
                    }
                    processed++
                    onProgress(
                        LibraryScanProgress(
                            stage = LibraryScanStage.READING_METADATA,
                            current = processed,
                            total = candidates.size,
                            currentFile = deviceSong.fileName
                        )
                    )
                }
                if (pendingFlush.size >= FLUSH_EVERY) flushPending()
            }

            val missingSafFolderIds = safScanResult.missingFolderIds
            val successfulScannedFolderIds = folderDao
                .getFolderTreeIds(safScanResult.successfulFolderIds)
                .toSet()

            val deletedUris = dbSyncInfos
                .filter { info ->
                    info.source == "SAF" &&
                        info.folderId in successfulScannedFolderIds &&
                        info.uri !in deviceUris
                }
                .map { it.uri }
                .toSet()

            // Lyrico Mod: remote songs that vanished from a successfully listed remote root.
            val successfulRemoteFolderIds = folderDao
                .getFolderTreeIds(remoteScanResult.successfulFolderIds)
                .toSet()
            val deletedRemoteUris = dbSyncInfos
                .filter { info ->
                    info.source == RemoteUri.SOURCE &&
                        info.folderId in successfulRemoteFolderIds &&
                        info.uri !in deviceUris
                }
                .map { it.uri }
                .toSet()

            val missingFolderSongUris = dbSyncInfos
                .filter { info -> info.source == "SAF" && info.folderId in missingSafFolderIds }
                .map { it.uri }
                .toSet()

            val allDeletedUris = deletedUris + deletedRemoteUris + missingFolderSongUris
            if (allDeletedUris.isNotEmpty()) {
                impactedFolderIds.addAll(
                    dbSyncInfos
                        .filter { it.uri in allDeletedUris }
                        .map { it.folderId }
                )
            }
            impactedFolderIds.addAll(missingSafFolderIds)

            val lyricsToIndex = unchangedSongUris.chunked(BATCH_SIZE).flatMap { uris ->
                songDao.getSongLyricsMissingIndex(uris).map { row ->
                    row.copy(lyricSearchText = LyricsSearchTextExtractor.toSearchText(row.lyrics).orEmpty())
                }
            }
            val databaseChanges = songsToUpsert.size + allDeletedUris.size +
                missingSafFolderIds.size + lyricsToIndex.size
            onProgress(
                LibraryScanProgress(
                    stage = LibraryScanStage.WRITING_DATABASE,
                    current = 0,
                    total = databaseChanges
                )
            )

            database.withTransaction {
                // Songs not yet written by an intermediate flush.
                upsertSongsLocked(pendingFlush, indexLyrics)
                pendingFlush.clear()

                lyricsToIndex.chunked(BATCH_SIZE).forEach { rows ->
                    rows.forEach { row ->
                        songDao.updateLyricSearchText(row.uri, row.lyricSearchText)
                    }
                    LyricFtsIndexer.replaceSongLyrics(songDao, rows)
                }

                allDeletedUris.chunked(BATCH_SIZE).forEach { chunk ->
                    songDao.deleteByUris(chunk)
                }

                missingSafFolderIds.forEach { folderId ->
                    folderDao.deleteFolderTreePermanently(folderId)
                }

                impactedFolderIds
                    .filterNot { it in missingSafFolderIds }
                    .forEach { folderId -> folderDao.refreshSongCount(folderId) }

                folderDao.performPostScanCleanup()
                if (remoteRoots.isNotEmpty()) deleteEmptyRemoteSubfolders(remoteRoots)
            }

            if (songsToUpsert.isNotEmpty()) {
                val indexedSongs = songDao.getSongsByUris(songsToUpsert.map { it.entity.uri })
                libraryIndexRepository.reindexSongs(indexedSongs)
            }
            if (allDeletedUris.isNotEmpty() || missingSafFolderIds.isNotEmpty() || removedSafFolders > 0) {
                libraryIndexRepository.refreshAndPruneIndexes()
            }

            onProgress(
                LibraryScanProgress(
                    stage = LibraryScanStage.WRITING_DATABASE,
                    current = databaseChanges,
                    total = databaseChanges
                )
            )

            if (failures.isEmpty()) settingsRepository.saveLastScanTime(System.currentTimeMillis())
            val result = LibraryScanResult(
                scanned = candidates.size,
                inserted = songsToUpsert.count { it.isInsert },
                updated = songsToUpsert.count { !it.isInsert },
                deleted = allDeletedUris.size,
                skipped = candidates.size - songsToUpsert.size,
                failures = failures
            )
            logResult(request, result, removedSafFolders, impactedFolderIds.size, filteredShort, unchanged,
                (System.nanoTime() - started) / 1_000_000)
            onProgress(LibraryScanProgress(stage = LibraryScanStage.FINISHED))
            return result
        } catch (e: Exception) {
            logException("Library synchronization failed", e)
            throw e
        }
    }

    /** Lyrico Mod: writes a batch of scanned songs mid-scan so the list fills progressively. */
    private suspend fun writeSongs(batch: List<ScannedSongMetadata>, indexLyrics: Boolean) {
        database.withTransaction {
            upsertSongsLocked(batch, indexLyrics)
            batch.map { it.entity.folderId }.distinct().forEach { folderDao.refreshSongCount(it) }
        }
    }

    private suspend fun upsertSongsLocked(batch: List<ScannedSongMetadata>, indexLyrics: Boolean) {
        batch.chunked(BATCH_SIZE).forEach { chunk ->
            val songs = chunk.map { it.entity }
            songDao.upsertAll(songs)
            if (indexLyrics) {
                LyricFtsIndexer.replaceSongs(songDao, songs)
            } else {
                songDao.deleteLyricFtsByUris(songs.map { it.uri })
            }
            chunk.forEach { metadata ->
                database.songCustomTagKeyDao().replaceForSong(
                    songUri = metadata.entity.uri,
                    keys = metadata.customFields.mapNotNull { field ->
                        field.key.trim().takeIf { it.isNotBlank() }?.uppercase()
                    }
                )
            }
        }
    }

    /** Remote roots touched by this request (all of them for a full-library scan). */
    private suspend fun selectRemoteRoots(folderIds: Set<Long>?): List<RemoteRootFolder> {
        val scanner = remoteScanner ?: return emptyList()
        val allFolders = folderDao.getAllFoldersOnce()
        val roots = scanner.rootFolders(allFolders)
        if (folderIds == null) return roots
        val selectedPaths = allFolders.filter { it.id in folderIds }.map { it.path.trimEnd('/') }
        return roots.filter { root ->
            val rootPath = root.folder.path.trimEnd('/')
            root.folder.id in folderIds || selectedPaths.any { it.startsWith("$rootPath/") }
        }
    }

    /** Remote sub-folders left without songs (the chosen roots themselves are kept). */
    private suspend fun deleteEmptyRemoteSubfolders(roots: List<RemoteRootFolder>) {
        val rootIds = roots.map { it.folder.id }.toSet()
        val all = folderDao.getAllFoldersOnce()
        val remote = all.filter { RemoteUri.isRemote(it.path) }
        val removable = remote.filter { folder ->
            folder.id !in rootIds &&
                folder.songCount == 0 &&
                !folder.isIgnored &&
                remote.none { other -> other.path.startsWith(folder.path.trimEnd('/') + "/") }
        }.map { it.id }
        if (removable.isNotEmpty()) folderDao.deleteFoldersPermanently(removable)
    }

    private suspend fun removeSafFoldersWithoutPermission(): Int {
        val foldersWithoutPermission = folderDao.getSafFoldersForPermissionCheck()
            .filterNot { folder ->
                UriUtils.hasPersistedReadPermission(context, folder.treeUri)
            }
        val folderIds = foldersWithoutPermission.map { it.id }
        if (folderIds.isEmpty()) return 0
        database.withTransaction {
            folderIds.forEach { folderId ->
                folderDao.deleteFolderTreePermanently(folderId)
            }
        }
        return folderIds.size
    }

    private suspend fun extractSongMetadata(
        songFile: SongFile,
        folderId: Long,
        existingId: Long,
        source: String,
        indexLyrics: Boolean,
        remote: Boolean = false,
    ): ScannedSongMetadata? {
        val audioData = audioTagRepository.read(
            uri = songFile.uri.toString(),
            options = AudioTagReadOptions(
                strict = true,
                multiValueSeparator = settingsRepository.separator.first()
            )
        )
        if (remote) {
            // Lyrico Mod: keep the embedded cover so song lists show it right away (keyed like the list's
            // CoverRequest: uri + library file size + library mtime).
            remoteScanner?.readAccess?.coverCache?.put(
                songFile.uri.toString(),
                songFile.fileSize,
                songFile.lastModified,
                RemoteCoverPick.frontCover(audioData.pictures)
            )
        }
        val entity = songMetadataMapper.fromScannedFile(
            file = songFile,
            tag = audioData,
            folderId = folderId,
            existingId = existingId,
            source = source,
            indexLyrics = indexLyrics
        )
        return ScannedSongMetadata(
            entity = entity,
            customFields = audioData.customFields,
            isInsert = existingId == 0L
        )
    }

    private suspend fun logResult(
        request: LibraryScanRequest,
        result: LibraryScanResult,
        removedSafFolders: Int,
        foldersUpdated: Int,
        filteredShort: Int,
        unchanged: Int,
        elapsedMs: Long
    ) {
        try {
            appLogRepository.log(
                level = if (result.failures.isEmpty()) AppLogLevel.INFO else AppLogLevel.WARNING,
                type = AppLogType.APP,
                tag = TAG,
                message = "Library synchronization finished",
                detail = buildString {
                    appendLine("fullRescan=${request.fullRescan}")
                    appendLine("scanned=${result.scanned}")
                    appendLine("inserted=${result.inserted}")
                    appendLine("updated=${result.updated}")
                    appendLine("deleted=${result.deleted}")
                    appendLine("removedSafFolders=$removedSafFolders")
                    appendLine("foldersUpdated=$foldersUpdated")
                    appendLine("failures=${result.failures.size}")
                    appendLine("ignoreShortAudio=${request.ignoreShortAudio}")
                    appendLine("filteredShort=$filteredShort")
                    appendLine("unchanged=$unchanged")
                    appendLine("elapsedMs=$elapsedMs")
                    appendLine("failureDetails=${result.failures.take(20).map { "${it.uri}|stage=${it.stage}|${it.throwable?.javaClass?.simpleName}:${it.message}" }}")
                }
            )
        } catch (e: Exception) {
            Log.w(TAG, "Failed to write scan log", e)
        }
    }

    private suspend fun logException(message: String, throwable: Throwable) {
        try {
            appLogRepository.logException(
                type = AppLogType.APP,
                tag = TAG,
                message = message,
                throwable = throwable
            )
        } catch (e: Exception) {
            Log.w(TAG, "Failed to write scan exception log", e)
        }
    }

    private data class ScanCandidate(
        val songFile: SongFile,
        val rootFolderId: Long,
        val folderPath: String,
        val source: String,
        val remoteConfigId: String? = null,
        val remoteEntry: com.lonx.lyrico.remote.RemoteEntry? = null,
    )

    private enum class ScanAction { SKIP, UNCHANGED, READ, FAILED }

    private class ScanPlan(
        val index: Int,
        val candidate: ScanCandidate,
        val action: ScanAction,
        val folderId: Long = 0L,
        val existingId: Long = 0L,
        val error: Exception? = null,
    )

    private data class ScannedSongMetadata(
        val entity: SongEntity,
        val customFields: List<CustomTagField>,
        val isInsert: Boolean
    )

    private companion object {
        const val TAG = "LibraryScanRepository"
        const val BATCH_SIZE = 50
        /** Parallel tag reads of remote files (each a partial-read proxy descriptor). */
        const val REMOTE_CONCURRENCY = 6
        /** Candidates planned / read together; results are applied in order per window. */
        const val SCAN_WINDOW = 24
        /** Write new/changed songs to the database every this many songs during a scan. */
        const val FLUSH_EVERY = 20
    }
}
