package com.lonx.lyrico.desktop.library

import com.lonx.lyrico.desktop.tag.TagData
import com.lonx.lyrico.desktop.tag.TagField
import kotlinx.serialization.Serializable

@Serializable
data class Song(
    /** Local absolute path, or "remote:<configId>:<remotePath>". */
    val id: String,
    /** Local absolute path or remote path ('/'-separated). */
    val path: String,
    /** Remote location id; null for local files. */
    val remoteId: String? = null,
    val fileName: String,
    val size: Long = 0,
    val modified: Long = 0,
    val title: String = "",
    val artist: String = "",
    val album: String = "",
    val albumArtist: String = "",
    val track: String = "",
    val disc: String = "",
    val year: String = "",
    val genre: String = "",
    val durationSeconds: Int = 0,
    val bitrateKbps: Int = 0,
    val hasCover: Boolean = false,
    val hasTagLyrics: Boolean = false,
    val hasLrc: Boolean = false,
    /** Tags have been read (remote files are listed first, read later). */
    val tagsLoaded: Boolean = true,
    val error: String? = null,
) {
    val isRemote: Boolean get() = remoteId != null
    val extension: String get() = fileName.substringAfterLast('.', "").lowercase()
    val baseName: String get() = fileName.substringBeforeLast('.', fileName)
    val displayTitle: String get() = title.ifBlank { baseName }
    val folder: String get() = path.substring(0, maxOf(path.lastIndexOf('/'), path.lastIndexOf('\\')).coerceAtLeast(0))

    fun withTag(t: TagData): Song = copy(
        title = t[TagField.TITLE],
        artist = t[TagField.ARTIST],
        album = t[TagField.ALBUM],
        albumArtist = t[TagField.ALBUM_ARTIST],
        track = t[TagField.TRACK],
        disc = t[TagField.DISC],
        year = t[TagField.YEAR],
        genre = t[TagField.GENRE],
        durationSeconds = t.audio.durationSeconds,
        bitrateKbps = t.audio.bitrateKbps,
        hasCover = t.hasCover,
        hasTagLyrics = t.lyrics.isNotBlank(),
        tagsLoaded = true,
        error = null,
    )

    companion object {
        fun remoteKey(remoteId: String, path: String) = "remote:$remoteId:$path"
    }
}

enum class SortKey(val label: String) {
    TITLE("标题"),
    ARTIST("艺术家"),
    ALBUM("专辑"),
    FILE_NAME("文件名"),
    MODIFIED("修改时间"),
    TRACK("音轨号"),
    YEAR("年份"),
}

object SongSorting {
    private val collator = java.text.Collator.getInstance(java.util.Locale.CHINA)

    private fun num(s: String) = s.substringBefore('/').trim().toIntOrNull() ?: Int.MAX_VALUE

    fun comparator(key: SortKey): Comparator<Song> = when (key) {
        SortKey.TITLE -> compareBy(collator) { it.displayTitle }
        SortKey.ARTIST -> compareBy<Song, String>(collator) { it.artist }.thenBy(collator) { it.album }
            .thenBy { num(it.disc) }.thenBy { num(it.track) }
        SortKey.ALBUM -> compareBy<Song, String>(collator) { it.album }.thenBy { num(it.disc) }.thenBy { num(it.track) }
        SortKey.FILE_NAME -> compareBy(collator) { it.fileName }
        SortKey.MODIFIED -> compareBy { it.modified }
        SortKey.TRACK -> compareBy<Song> { num(it.disc) }.thenBy { num(it.track) }
        SortKey.YEAR -> compareBy<Song, String>(collator) { it.year }.thenBy(collator) { it.album }
    }

    fun filterAndSort(songs: List<Song>, query: String, key: SortKey, descending: Boolean, location: String?): List<Song> {
        val q = query.trim()
        val terms = q.split(' ').filter { it.isNotBlank() }
        val filtered = songs.asSequence().filter { s ->
            (location == null || belongsTo(s, location)) && terms.all { t ->
                s.displayTitle.contains(t, true) || s.artist.contains(t, true) || s.album.contains(t, true) ||
                    s.fileName.contains(t, true) || s.albumArtist.contains(t, true) || s.genre.contains(t, true)
            }
        }.toList()
        val c = comparator(key)
        return filtered.sortedWith(if (descending) c.reversed() else c)
    }

    /** location = local folder path, or "remote:<id>" for a whole remote location. */
    fun belongsTo(s: Song, location: String): Boolean = if (location.startsWith("remote:")) {
        s.id.startsWith("$location:")
    } else {
        !s.isRemote && (s.path == location || s.path.startsWith(location.trimEnd('/', '\\') + java.io.File.separator) ||
            s.path.startsWith(location.trimEnd('/', '\\') + "/"))
    }
}
