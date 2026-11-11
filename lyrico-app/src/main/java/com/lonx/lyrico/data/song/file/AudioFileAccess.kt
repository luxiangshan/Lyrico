package com.lonx.lyrico.data.song.file

import android.app.RecoverableSecurityException
import android.content.ContentUris
import android.content.Context
import android.content.IntentSender
import android.net.Uri
import android.os.Build
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Log
import androidx.core.net.toUri
import com.lonx.lyrico.R
import com.lonx.lyrico.remote.integration.RemoteFileCache
import com.lonx.lyrico.remote.integration.RemoteUri
import java.io.File
import java.io.FileNotFoundException
import java.util.Collections

class AudioFileAccess(
    private val context: Context,
    /** Lyrico Mod: local copies of `remote://` songs (null in tests / when remote storage is unavailable). */
    private val remoteFileCache: RemoteFileCache? = null,
    /** Lyrico Mod: partial (ranged) reads of `remote://` songs; null = always download whole files. */
    private val remoteReadAccess: com.lonx.lyrico.remote.integration.RemoteReadAccess? = null,
) {
    /** remote:// uris whose cached copy was opened writable and still needs [finishRemoteWrite]. */
    private val openRemoteWrites: MutableSet<String> = Collections.synchronizedSet(mutableSetOf())

    fun isRemote(uriString: String): Boolean = RemoteUri.isRemote(uriString)

    fun getDisplayName(uriString: String): String {
        if (RemoteUri.isRemote(uriString)) {
            return RemoteUri.parse(uriString)?.path?.let(RemoteUri::fileName)
                ?.takeIf { it.isNotBlank() } ?: uriString.substringAfterLast("/")
        }
        val uri = uriString.toUri()
        return when (uri.scheme) {
            "content" -> getOpenableDisplayName(uri)
            "file" -> uri.path?.let(::File)?.name
            else -> File(uriString).name
        }?.takeIf { it.isNotBlank() } ?: uriString.substringAfterLast("/")
    }

    /**
     * [allowPartial] (remote songs only): serve reads through a partial-read proxy descriptor instead of
     * downloading the whole file. Pass false to force a full local copy (e.g. retry after a failed read).
     */
    fun openReadableDescriptor(
        uriString: String,
        trace: (String) -> Unit = {},
        allowPartial: Boolean = true,
    ): ParcelFileDescriptor? {
        if (RemoteUri.isRemote(uriString)) {
            remoteReadAccess?.let { return it.openRead(uriString, allowPartial, trace) }
            val file = remoteLocalCopy(uriString, trace)
            return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
        }
        val uri = uriString.toUri()
        if (uri.scheme == "file" || uri.scheme.isNullOrBlank()) {
            val file = if (uri.scheme == "file") {
                File(uri.path ?: throw FileNotFoundException(uriString))
            } else {
                File(uriString)
            }
            return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
        }

        return openContentDescriptor(uri, "r", trace)
    }

    fun openWritableDescriptor(uriString: String, trace: (String) -> Unit = {}): ParcelFileDescriptor? {
        if (RemoteUri.isRemote(uriString)) {
            val parsed = RemoteUri.parse(uriString) ?: throw FileNotFoundException(uriString)
            val cache = remoteFileCache ?: throw FileNotFoundException("Remote storage unavailable: $uriString")
            val file = cache.beginWrite(parsed.configId, parsed.path)
            openRemoteWrites += uriString
            trace("remoteWrite cached=${file.name} size=${file.length()}")
            return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_WRITE)
        }
        val uri = uriString.toUri()
        if (uri.scheme == "file" || uri.scheme.isNullOrBlank()) {
            val file = if (uri.scheme == "file") {
                File(uri.path ?: throw FileNotFoundException(uriString))
            } else {
                File(uriString)
            }
            return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_WRITE)
        }

        return openContentDescriptor(uri, "rw", trace)
    }

    /**
     * Lyrico Mod: must be called after the descriptor from [openWritableDescriptor] is closed.
     * [success] = the tag write succeeded → the cached copy is uploaded back to the remote location
     * (throws [RemoteFileCache.RemoteUploadException] with a user-facing message on failure; the edited
     * copy stays pending and can be retried). [success] = false → the copy is discarded.
     * No-op for local uris or when no remote write is open.
     */
    fun finishRemoteWrite(uriString: String, success: Boolean, trace: (String) -> Unit = {}) {
        if (!RemoteUri.isRemote(uriString) || !openRemoteWrites.remove(uriString)) return
        val parsed = RemoteUri.parse(uriString) ?: return
        val cache = remoteFileCache ?: return
        if (!success) {
            cache.abortWrite(parsed.configId, parsed.path)
            trace("remoteWrite aborted")
            return
        }
        try {
            cache.commitWrite(parsed.configId, parsed.path)
            trace("remoteWrite uploaded")
        } catch (e: RemoteFileCache.RemoteUploadException) {
            trace("remoteWrite uploadFailed=${e.message}")
            throw RemoteFileCache.RemoteUploadException(
                context.getString(R.string.remote_upload_failed, e.message ?: ""),
                e.cause ?: e
            )
        }
    }

    /** Lyrico Mod: renames a remote song; returns (newUri, newDisplayPath) or null on a name conflict. Blocking. */
    fun renameRemote(uriString: String, newFileName: String): Pair<String, String>? {
        val parsed = RemoteUri.parse(uriString) ?: throw FileNotFoundException(uriString)
        val cache = remoteFileCache ?: throw FileNotFoundException("Remote storage unavailable: $uriString")
        val newPath = cache.renameRemote(parsed.configId, parsed.path, newFileName) ?: return null
        return RemoteUri.build(parsed.configId, newPath) to RemoteUri.displayPath(parsed.configId, newPath)
    }

    /** Lyrico Mod: deletes a remote song; false when it was already missing. Blocking. */
    fun deleteRemote(uriString: String): Boolean {
        val parsed = RemoteUri.parse(uriString) ?: throw FileNotFoundException(uriString)
        val cache = remoteFileCache ?: throw FileNotFoundException("Remote storage unavailable: $uriString")
        return cache.deleteRemote(parsed.configId, parsed.path)
    }

    /** Cached local copy of a remote song if one exists (no network); null for local uris. */
    fun cachedRemoteCopy(uriString: String): File? {
        val parsed = RemoteUri.parse(uriString) ?: return null
        return remoteFileCache?.cachedCopy(parsed.configId, parsed.path)
    }

    /** Downloads (or reuses) the local copy of a remote song. Blocking. */
    fun remoteLocalCopy(uriString: String, trace: (String) -> Unit = {}): File {
        val parsed = RemoteUri.parse(uriString) ?: throw FileNotFoundException(uriString)
        val cache = remoteFileCache ?: throw FileNotFoundException("Remote storage unavailable: $uriString")
        return cache.ensureLocal(parsed.configId, parsed.path).also {
            trace("remoteRead cached=${it.name} size=${it.length()}")
        }
    }

    fun createWritePermissionIntentSender(uriString: String, trace: (String) -> Unit = {}): IntentSender? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
        if (RemoteUri.isRemote(uriString)) return null

        return try {
            val uri = uriString.toUri()
            val writableUri = uri.toWritableMediaStoreUri()
            trace("permissionMapping original=$uri mapped=$writableUri")
            if (writableUri == null) return null

            MediaStore.createWriteRequest(context.contentResolver, listOf(writableUri))
                .intentSender
        } catch (e: Exception) {
            trace("permissionRequest error=${e.stackTraceToString()}")
            Log.w(TAG, "Unable to create write permission request: $uriString", e)
            null
        }
    }

    fun writePermissionFromThrowable(uriString: String, throwable: Throwable, trace: (String) -> Unit = {}): IntentSender? {
        if (RemoteUri.isRemote(uriString)) return null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && throwable is RecoverableSecurityException) {
            trace("permissionRequest recoverableSecurityException uri=$uriString")
            return throwable.userAction.actionIntent.intentSender
        }
        if (throwable is SecurityException) {
            return createWritePermissionIntentSender(uriString, trace)
        }
        return null
    }

    fun deleteDocument(uri: Uri): Boolean {
        return DocumentsContract.deleteDocument(context.contentResolver, uri)
    }

    fun renameDocument(uri: Uri, newFileName: String): Uri? {
        return DocumentsContract.renameDocument(context.contentResolver, uri, newFileName)
    }

    fun isUriMissing(uri: Uri): Boolean {
        if (uri.scheme == RemoteUri.SCHEME) return false
        return try {
            context.contentResolver.openFileDescriptor(uri, "r")?.use { }
            false
        } catch (e: FileNotFoundException) {
            true
        } catch (e: SecurityException) {
            false
        } catch (e: Exception) {
            true
        }
    }

    fun openInputBytes(uri: Uri): ByteArray? {
        if (uri.scheme == RemoteUri.SCHEME) return remoteLocalCopy(uri.toString()).readBytes()
        return context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
    }

    private fun openContentDescriptor(uri: Uri, mode: String, trace: (String) -> Unit = {}): ParcelFileDescriptor? {
        var originalFailure: Exception? = null
        var mappedFailure: Exception? = null
        fun attempt(target: Uri, mapped: Boolean = false): ParcelFileDescriptor? =
            tryOpenContentDescriptor(target, mode, trace) { error ->
                if (mapped) mappedFailure = error else originalFailure = error
            }
        val mediaStoreAudioUri = uri.toMediaStoreAudioUri()
        if (mediaStoreAudioUri != null && mediaStoreAudioUri != uri) {
            attempt(mediaStoreAudioUri, mapped = true)?.let { return it }
        }

        attempt(uri)?.let { return it }

        if (mediaStoreAudioUri == null && uri.scheme == "content") {
            findMediaStoreAudioUri(uri)?.let { matchedUri ->
                trace("descriptorMapping original=$uri matched=$matchedUri")
                attempt(matchedUri, mapped = true)?.let { return it }
            }
        }

        // Authorization applies to the mapped MediaStore item. Preserve its actual failure,
        // rather than turning every failed open (including missing files) into a permission request.
        if (mode == "rw") {
            // A provider-supplied recovery action is stronger evidence than a failed inferred mapping.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                if (originalFailure is RecoverableSecurityException) throw originalFailure!!
                if (mappedFailure is RecoverableSecurityException) throw mappedFailure!!
            }
            throw mappedFailure ?: originalFailure
                ?: FileNotFoundException("Provider returned no writable descriptor: $uri")
        }
        return null
    }

    private fun tryOpenContentDescriptor(
        uri: Uri,
        mode: String,
        trace: (String) -> Unit,
        onFailure: (Exception) -> Unit,
    ): ParcelFileDescriptor? {
        return try {
            context.contentResolver.openFileDescriptor(uri, mode).also {
                trace("openDescriptor uri=$uri mode=$mode result=${if (it == null) "null" else "opened"}")
                if (it == null) onFailure(FileNotFoundException("Provider returned no descriptor: $uri"))
            }
        } catch (e: SecurityException) {
            onFailure(e)
            trace("openDescriptor uri=$uri mode=$mode error=${e.stackTraceToString()}")
            null
        } catch (e: FileNotFoundException) {
            onFailure(e)
            trace("openDescriptor uri=$uri mode=$mode error=${e.stackTraceToString()}")
            null
        } catch (e: IllegalArgumentException) {
            onFailure(e)
            trace("openDescriptor uri=$uri mode=$mode error=${e.stackTraceToString()}")
            null
        }
    }

    private fun Uri.toWritableMediaStoreUri(): Uri? {
        return toMediaStoreAudioUri()
            ?: takeIf { scheme == "content" }?.let(::findMediaStoreAudioUri)
    }

    private fun findMediaStoreAudioUri(sourceUri: Uri): Uri? {
        sourceUri.toMediaStoreAudioUri()?.let { return it }
        if (sourceUri.scheme != "content") return null

        val displayName = getOpenableDisplayName(sourceUri)
            ?: sourceUri.lastPathSegment?.let(Uri::decode)
            ?: return null
        val sourceSize = getOpenableSize(sourceUri)
        val sourceRelativePath = inferRelativePath(sourceUri)
        // A name alone cannot identify an external file safely enough for editing.
        if (sourceSize == null && sourceRelativePath == null) return null

        val projection = buildList {
            add(MediaStore.Audio.Media._ID)
            add(MediaStore.Audio.Media.DISPLAY_NAME)
            add(MediaStore.Audio.Media.SIZE)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                add(MediaStore.Audio.Media.RELATIVE_PATH)
            }
        }.toTypedArray()

        val selection = buildString {
            append("${MediaStore.Audio.Media.DISPLAY_NAME} = ?")
            if (sourceSize != null) {
                append(" AND ${MediaStore.Audio.Media.SIZE} = ?")
            }
        }
        val selectionArgs = buildList {
            add(displayName)
            sourceSize?.let { add(it.toString()) }
        }.toTypedArray()

        return try {
            context.contentResolver.query(
                MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
                projection,
                selection,
                selectionArgs,
                "${MediaStore.Audio.Media.DATE_MODIFIED} DESC"
            )?.use { cursor ->
                val idIndex = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
                val relativePathIndex = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    cursor.getColumnIndex(MediaStore.Audio.Media.RELATIVE_PATH)
                } else {
                    -1
                }

                var matchedUri: Uri? = null
                while (cursor.moveToNext()) {
                    val mediaUri = ContentUris.withAppendedId(
                        MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
                        cursor.getLong(idIndex)
                    )
                    if (sourceRelativePath != null) {
                        if (relativePathIndex < 0 ||
                            cursor.getString(relativePathIndex)?.trimEnd('/') != sourceRelativePath.trimEnd('/')) {
                            continue
                        }
                    }
                    // Do not choose an arbitrary copy when multiple items match.
                    if (matchedUri != null) return@use null
                    matchedUri = mediaUri
                }
                matchedUri
            }
        } catch (e: Exception) {
            Log.w(TAG, "Unable to match MediaStore audio uri: $sourceUri", e)
            null
        }
    }

    private fun Uri.toMediaStoreAudioUri(): Uri? {
        if (scheme != "content" || authority != "media") return null
        val id = runCatching { ContentUris.parseId(this) }.getOrNull()
            ?.takeIf { it >= 0L }
            ?: return null

        return when {
            isMediaStoreAudioItemUri(this) -> this
            isMediaStoreFilesItemUri(this) -> ContentUris.withAppendedId(
                MediaStore.Audio.Media.getContentUri(pathSegments.first()),
                id
            )
            else -> null
        }
    }

    private fun isMediaStoreAudioItemUri(uri: Uri): Boolean {
        if (!isMediaStoreItemUri(uri)) return false
        return uri.pathSegments.any { it == "audio" }
    }

    private fun isMediaStoreFilesItemUri(uri: Uri): Boolean {
        if (!isMediaStoreItemUri(uri)) return false
        return uri.pathSegments.any { it == "file" }
    }

    private fun isMediaStoreItemUri(uri: Uri): Boolean {
        if (uri.scheme != "content" || uri.authority != "media") return false
        return runCatching { ContentUris.parseId(uri) >= 0L }.getOrDefault(false)
    }

    private fun getOpenableDisplayName(uri: Uri): String? {
        return try {
            context.contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null
            )?.use { cursor ->
                if (!cursor.moveToFirst()) return@use null
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0) cursor.getString(index)?.takeIf { it.isNotBlank() } else null
            }
        } catch (e: Exception) {
            null
        }
    }

    private fun getOpenableSize(uri: Uri): Long? {
        return try {
            context.contentResolver.query(
                uri,
                arrayOf(OpenableColumns.SIZE),
                null,
                null,
                null
            )?.use { cursor ->
                if (!cursor.moveToFirst()) return@use null
                val index = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (index >= 0 && !cursor.isNull(index)) cursor.getLong(index) else null
            }
        } catch (e: Exception) {
            null
        }
    }

    private fun inferRelativePath(uri: Uri): String? {
        val documentRelativePath = inferDocumentRelativePath(uri)
        if (documentRelativePath != null) return documentRelativePath

        val pathSegments = uri.pathSegments
        val externalRootIndex = pathSegments.indexOfFirst {
            it == "external_files" || it == "external" || it == "external_storage"
        }
        if (externalRootIndex < 0 || pathSegments.size <= externalRootIndex + 2) return null

        return pathSegments
            .drop(externalRootIndex + 1)
            .dropLast(1)
            .joinToString("/")
            .takeIf { it.isNotBlank() }
            ?.let { "$it/" }
    }

    private fun inferDocumentRelativePath(uri: Uri): String? {
        return try {
            if (!DocumentsContract.isDocumentUri(context, uri)) return null

            val documentId = DocumentsContract.getDocumentId(uri)
            val relativePathWithFile = documentId.substringAfter(':', missingDelimiterValue = "")
            if (relativePathWithFile.isBlank()) return null

            relativePathWithFile.substringBeforeLast(
                delimiter = "/",
                missingDelimiterValue = ""
            ).takeIf { it.isNotBlank() }?.let { "$it/" }
        } catch (e: Exception) {
            null
        }
    }

    private companion object {
        const val TAG = "AudioFileAccess"
    }
}
