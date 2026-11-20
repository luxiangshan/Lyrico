package com.lonx.lyrico.desktop.library

import com.lonx.lyrico.desktop.lyrics.LrcFiles
import com.lonx.lyrico.desktop.lyrics.LrcWriteOptions
import java.io.File

/**
 * Access to a song's bytes. Local songs are edited in place; remote songs are downloaded to a cache
 * file, edited, and uploaded back.
 */
interface SongStore {
    /** A local file with the song's current content (downloads remote files). */
    fun fileFor(song: Song): File

    /** Called after [fileFor]'s file was modified (uploads remote files). */
    fun commit(song: Song, file: File)

    /** Text of the .lrc next to the song, or null. */
    fun readLrc(song: Song): String?

    /** True when a .lrc with the song's name (any case) exists next to it. */
    fun hasLrc(song: Song): Boolean

    /** Writes the .lrc next to the song. Returns where it went (for messages). */
    fun writeLrc(song: Song, text: String, options: LrcWriteOptions): String

    /** Fresh size/mtime after a commit. */
    fun refreshStat(song: Song, file: File): Song
}

object LocalSongStore : SongStore {
    override fun fileFor(song: Song): File = File(song.path)

    override fun commit(song: Song, file: File) = Unit

    override fun readLrc(song: Song): String? = LrcFiles.findAdjacent(File(song.path))?.let { LrcFiles.read(it) }

    override fun hasLrc(song: Song): Boolean = LrcFiles.findAdjacent(File(song.path)) != null

    override fun writeLrc(song: Song, text: String, options: LrcWriteOptions): String {
        val audio = File(song.path)
        // Reuse an existing differently-cased "Song.LRC" rather than creating a second file.
        val target = LrcFiles.findAdjacent(audio) ?: LrcFiles.lrcFileFor(audio)
        LrcFiles.write(target, text, options)
        return target.absolutePath
    }

    override fun refreshStat(song: Song, file: File): Song = song.copy(size = file.length(), modified = file.lastModified())
}
