package com.lonx.lyrico.utils.coil

import com.lonx.lyrico.data.artwork.ArtistPosterReader
import com.lonx.lyrico.data.artwork.readArtworkSafely
import android.content.ContentResolver
import coil3.ImageLoader
import coil3.decode.DataSource
import coil3.decode.ImageSource
import coil3.fetch.Fetcher
import coil3.fetch.FetchResult
import coil3.fetch.SourceFetchResult
import coil3.request.Options
import com.lonx.audiotag.model.AudioPictureType
import com.lonx.audiotag.rw.AudioTagReader
import com.lonx.lyrico.data.model.artwork.CoverCandidate
import com.lonx.lyrico.data.model.artwork.CoverRequest
import okio.Buffer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class AudioCoverFetcher(
    private val contentResolver: ContentResolver,
    private val request: CoverRequest,
    private val posterReader: ArtistPosterReader,
    private val options: Options,
    /** Lyrico Mod: read-only descriptor of a `remote://` song (local copy or partial-read proxy). */
    private val remoteDescriptor: ((String) -> android.os.ParcelFileDescriptor?)? = null,
    /** Lyrico Mod: disk cache of remote songs' embedded front covers (filled by the library scan). */
    private val remoteCovers: com.lonx.lyrico.remote.integration.RemoteCoverCache? = null,
) : Fetcher {

    private fun openDescriptor(uri: android.net.Uri): android.os.ParcelFileDescriptor? {
        if (uri.scheme == "remote") return remoteDescriptor?.invoke(uri.toString())
        return contentResolver.openFileDescriptor(uri, "r")
    }

    /** A plain "front cover of this one remote song" request, which the remote cover cache can answer. */
    private fun isCacheableRemoteCover(): Boolean =
        remoteCovers != null && request.uri.scheme == "remote" && request.artistName == null &&
            !request.skipEmbeddedPictures && request.pictureType == AudioPictureType.FrontCover &&
            request.fallbackToAny && request.fallbackPictureTypes.isEmpty() &&
            request.candidates.all { it.uri == request.uri }

    private suspend fun fetchRemoteCover(): ByteArray? {
        val cache = remoteCovers ?: return null
        val uri = request.uri.toString()
        when (val hit = cache.get(uri, request.fileSize, request.lastUpdate)) {
            is com.lonx.lyrico.remote.integration.RemoteCoverCache.Lookup.Hit -> return hit.bytes
            com.lonx.lyrico.remote.integration.RemoteCoverCache.Lookup.NoCover -> return null
            com.lonx.lyrico.remote.integration.RemoteCoverCache.Lookup.Miss -> Unit
        }
        // Strict read: a network failure throws (and is not remembered as "no cover").
        val bytes = try {
            openDescriptor(request.uri)?.use { pfd ->
                val data = AudioTagReader.read(
                    pfd = pfd,
                    readPictures = true,
                    strict = true,
                    audioPropertiesReadStyle = com.lonx.audiotag.model.AudioPropertiesReadStyle.Fast,
                )
                com.lonx.lyrico.remote.integration.RemoteCoverPick.frontCover(data.pictures) ?: ByteArray(0)
            }
        } catch (e: Exception) {
            if (e is kotlinx.coroutines.CancellationException) throw e
            android.util.Log.w("AudioCoverFetcher", "Remote cover read failed: $uri", e)
            null
        } ?: return null
        cache.put(uri, request.fileSize, request.lastUpdate, bytes)
        return bytes.takeIf { it.isNotEmpty() }
    }

    override suspend fun fetch(): FetchResult? {
        val candidateList = request.candidates.takeIf { it.isNotEmpty() }
            ?: listOf(CoverCandidate(request.uri, request.lastUpdate))

        val pictureBytes = withContext(Dispatchers.IO) {
            if (isCacheableRemoteCover()) {
                fetchRemoteCover()
            } else if (request.artistName != null) {
                posterReader.resolve(request)?.bytes
                    // Covers and other artists' images are display fallbacks, never edit targets.
                    ?: if (!request.skipEmbeddedPictures && request.fallbackToAny) {
                        readRequestedPicture(candidateList, includeOtherArtists = true)
                            ?: readFallbackPicture(candidateList)
                    } else null
            } else {
                readRequestedPicture(candidateList)
                    ?: readFallbackPicture(candidateList)
            }
        } ?: return null

        if (pictureBytes.isEmpty()) {
            return null
        }


        val buffer = Buffer().apply { write(pictureBytes) }
        val imageSource = ImageSource(buffer, options.fileSystem)

        return SourceFetchResult(
            source = imageSource,
            mimeType = "image/*",
            dataSource = DataSource.DISK
        )
    }

    private suspend fun readRequestedPicture(
        candidates: List<CoverCandidate>,
        includeOtherArtists: Boolean = false
    ): ByteArray? {
        for (candidate in candidates) {
            val bytes = readArtworkSafely {
                openDescriptor(candidate.uri)?.use { pfd ->
                    AudioTagReader.readPicture(
                        pfd = pfd,
                        pictureType = request.pictureType,
                        fallbackPictureTypes = request.fallbackPictureTypes,
                        fallbackToAny = includeOtherArtists,
                        description = request.artistName
                    )
                }
            }
            if (bytes != null && bytes.isNotEmpty()) return bytes
        }
        return null
    }

    private suspend fun readFallbackPicture(
        candidates: List<CoverCandidate>
    ): ByteArray? {
        if (!request.fallbackToAny) return null
        val firstCandidate = candidates.firstOrNull() ?: return null
        return readArtworkSafely {
            openDescriptor(firstCandidate.uri)?.use { pfd ->
                AudioTagReader.readPicture(
                    pfd = pfd,
                    pictureType = AudioPictureType.FrontCover,
                    fallbackToAny = true
                )
            }
        }
    }

    class Factory(
        private val contentResolver: ContentResolver,
        private val posterReader: ArtistPosterReader,
        private val remoteDescriptor: ((String) -> android.os.ParcelFileDescriptor?)? = null,
        private val remoteCovers: (() -> com.lonx.lyrico.remote.integration.RemoteCoverCache?)? = null,
    ) :
        Fetcher.Factory<CoverRequest> {
        override fun create(
            data: CoverRequest,
            options: Options,
            imageLoader: ImageLoader
        ) = AudioCoverFetcher(
            contentResolver = contentResolver,
            posterReader = posterReader,
            request = data,
            options = options,
            remoteDescriptor = remoteDescriptor,
            remoteCovers = remoteCovers?.invoke()
        )
    }
}
