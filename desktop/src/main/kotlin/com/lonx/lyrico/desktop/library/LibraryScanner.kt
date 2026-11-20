package com.lonx.lyrico.desktop.library

import com.lonx.lyrico.desktop.settings.AppDirs
import com.lonx.lyrico.desktop.settings.appJson
import com.lonx.lyrico.desktop.tag.TagService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import kotlinx.serialization.builtins.ListSerializer
import java.io.File
import java.nio.file.FileVisitResult
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.SimpleFileVisitor
import java.nio.file.attribute.BasicFileAttributes
import java.util.concurrent.atomic.AtomicInteger

object LibraryCache {
    private val file get() = File(AppDirs.cache, "library.json")

    fun load(): List<Song> = try {
        if (file.isFile) appJson.decodeFromString(ListSerializer(Song.serializer()), file.readText()) else emptyList()
    } catch (_: Exception) {
        emptyList()
    }

    fun save(songs: List<Song>) {
        try {
            val tmp = File(file.parentFile, "library.json.tmp")
            tmp.writeText(appJson.encodeToString(ListSerializer(Song.serializer()), songs))
            Files.move(tmp.toPath(), file.toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING)
        } catch (_: Exception) {
        }
    }
}

object LibraryScanner {

    data class Found(val file: File, val size: Long, val modified: Long)

    /** Lists audio files below [root] (recursive, hidden folders skipped). */
    fun listAudio(root: File): List<Found> {
        val result = ArrayList<Found>()
        if (!root.isDirectory) return result
        Files.walkFileTree(root.toPath(), object : SimpleFileVisitor<Path>() {
            override fun preVisitDirectory(dir: Path, attrs: BasicFileAttributes): FileVisitResult {
                val name = dir.fileName?.toString().orEmpty()
                return if (dir != root.toPath() && (name.startsWith(".") || name == "\$RECYCLE.BIN" || name == "System Volume Information"))
                    FileVisitResult.SKIP_SUBTREE else FileVisitResult.CONTINUE
            }

            override fun visitFile(file: Path, attrs: BasicFileAttributes): FileVisitResult {
                val n = file.fileName.toString()
                if (attrs.isRegularFile && !n.startsWith(".") && TagService.isAudio(n)) {
                    result += Found(file.toFile(), attrs.size(), attrs.lastModifiedTime().toMillis())
                }
                return FileVisitResult.CONTINUE
            }

            override fun visitFileFailed(file: Path, exc: java.io.IOException): FileVisitResult = FileVisitResult.CONTINUE
        })
        return result
    }

    fun readSong(found: Found, hasLrc: Boolean): Song {
        val base = Song(
            id = found.file.absolutePath,
            path = found.file.absolutePath,
            fileName = found.file.name,
            size = found.size,
            modified = found.modified,
            hasLrc = hasLrc,
        )
        return try {
            base.withTag(TagService.read(found.file, withCover = false))
        } catch (e: Exception) {
            base.copy(error = e.message ?: e.javaClass.simpleName)
        }
    }

    private fun lrcNames(dir: File?): Set<String> =
        dir?.list { _, n -> n.endsWith(".lrc", true) }?.map { it.substringBeforeLast('.').lowercase() }?.toSet() ?: emptySet()

    /**
     * Scans [folders], reusing [cached] entries whose size and mtime are unchanged.
     * [onProgress] gets (done, total, partial results) roughly every 50 files.
     */
    suspend fun scan(
        folders: List<String>,
        cached: Map<String, Song>,
        threads: Int,
        onProgress: (Int, Int, List<Song>) -> Unit,
    ): List<Song> = withContext(Dispatchers.IO) {
        val found = folders.flatMap { listAudio(File(it)) }.distinctBy { it.file.absolutePath }
        val total = found.size
        val done = AtomicInteger()
        val lrcByDir = HashMap<String, Set<String>>()
        found.map { it.file.parentFile }.distinct().forEach { d -> lrcByDir[d?.absolutePath.orEmpty()] = lrcNames(d) }
        val sem = Semaphore(threads.coerceIn(1, 16))
        val results = arrayOfNulls<Song>(total)
        coroutineScope {
            found.mapIndexed { i, f ->
                async {
                    sem.withPermit {
                        ensureActive()
                        val hasLrc = f.file.nameWithoutExtension.lowercase() in lrcByDir[f.file.parentFile?.absolutePath.orEmpty()].orEmpty()
                        val c = cached[f.file.absolutePath]
                        val song = if (c != null && c.size == f.size && c.modified == f.modified && c.error == null) c.copy(hasLrc = hasLrc)
                        else readSong(f, hasLrc)
                        results[i] = song
                        val n = done.incrementAndGet()
                        if (n % 50 == 0 || n == total) onProgress(n, total, results.filterNotNull())
                    }
                }
            }.awaitAll()
        }
        if (total == 0) onProgress(0, 0, emptyList())
        results.filterNotNull()
    }
}
