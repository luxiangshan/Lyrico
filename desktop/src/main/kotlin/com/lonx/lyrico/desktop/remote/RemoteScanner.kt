package com.lonx.lyrico.desktop.remote

import com.lonx.lyrico.desktop.library.Song
import com.lonx.lyrico.desktop.tag.TagData
import com.lonx.lyrico.desktop.tag.TagService
import com.lonx.lyrico.remote.RemoteEntry
import com.lonx.lyrico.remote.RemoteStorage
import java.io.File

object RemoteScanner {
    const val HEAD_BYTES = 1L shl 20 // 1 MiB

    /** Recursively lists audio files under [folders]; also returns lowercase base names of .lrc files per directory. */
    fun listAudio(storage: RemoteStorage, folders: List<String>, cancelled: () -> Boolean, onDir: (String) -> Unit): Pair<List<RemoteEntry>, Map<String, Set<String>>> {
        val audio = ArrayList<RemoteEntry>()
        val lrc = HashMap<String, Set<String>>()
        val seen = HashSet<String>()
        val queue = ArrayDeque(folders.ifEmpty { listOf("/") })
        while (queue.isNotEmpty() && !cancelled()) {
            val dir = queue.removeFirst()
            if (!seen.add(dir)) continue
            onDir(dir)
            val entries = storage.list(dir)
            lrc[dir] = entries.filter { !it.isDirectory && it.name.endsWith(".lrc", true) }
                .map { it.name.substringBeforeLast('.').lowercase() }.toSet()
            for (e in entries) {
                if (e.isDirectory) { if (!e.name.startsWith(".")) queue.addLast(e.path) }
                else if (!e.name.startsWith(".") && TagService.isAudio(e.name)) audio += e
            }
        }
        return audio to lrc
    }

    /** Total ID3v2 tag length from its header, or 0. */
    fun id3TagSize(f: File): Long {
        val h = ByteArray(10)
        f.inputStream().use { if (it.readNBytes(h, 0, 10) < 10) return 0 }
        if (h[0] != 'I'.code.toByte() || h[1] != 'D'.code.toByte() || h[2] != '3'.code.toByte()) return 0
        val size = ((h[6].toLong() and 0x7f) shl 21) or ((h[7].toLong() and 0x7f) shl 14) or ((h[8].toLong() and 0x7f) shl 7) or (h[9].toLong() and 0x7f)
        return size + 10 + (if (h[5].toInt() and 0x10 != 0) 10 else 0)
    }

    fun parentOf(path: String) = path.substringBeforeLast('/', "").ifEmpty { "/" }

    fun songFor(remoteId: String, e: RemoteEntry, hasLrc: Boolean) = Song(
        id = Song.remoteKey(remoteId, e.path),
        path = e.path,
        remoteId = remoteId,
        fileName = e.name,
        size = e.size,
        modified = e.modifiedMillis,
        hasLrc = hasLrc,
        tagsLoaded = false,
    )

    /**
     * Reads tags from a partial download (head, or tail for APEv2 formats); falls back to the full file.
     * Returns tags plus cover bytes for the thumbnail cache. Duration is dropped for partial reads.
     */
    fun readTags(storage: RemoteStorage, song: Song, store: RemoteSongStore, tmpDir: File): Pair<TagData, ByteArray?> {
        store.cachedIfFresh(song)?.let { f ->
            val t = TagService.read(f, withCover = true)
            return t to t.cover?.bytes
        }
        val tail = song.extension == "ape" || song.extension == "wv"
        var want = HEAD_BYTES
        var attempt = 0
        while (attempt < 3 && song.size > HEAD_BYTES * 2 && want < song.size * 9 / 10) {
            attempt++
            tmpDir.mkdirs()
            val part = File.createTempFile("head", "." + song.extension, tmpDir)
            try {
                val offset = if (tail) song.size - want else 0
                storage.openRange(song.path, offset, want).use { i -> part.outputStream().use { it.write(i.readBytes()) } }
                val needed = if (tail) 0 else id3TagSize(part)
                if (needed > want) {
                    want = needed + 256 * 1024 // whole ID3 tag (large embedded cover) plus some audio frames
                    continue
                }
                val t = TagService.read(part, withCover = true)
                val cleaned = TagData(t.fields, t.lyrics, null, t.hasCover, t.audio.copy(durationSeconds = 0, bitrateKbps = 0))
                return cleaned to t.cover?.bytes
            } catch (_: Exception) {
                want *= 8 // e.g. big FLAC picture block; M4A with moov at the end ends in a full download
            } finally {
                part.delete()
            }
        }
        val full = store.fileFor(song)
        val t = TagService.read(full, withCover = true)
        return t to t.cover?.bytes
    }
}
