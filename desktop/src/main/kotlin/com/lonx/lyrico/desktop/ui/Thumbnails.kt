package com.lonx.lyrico.desktop.ui

import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.toComposeImageBitmap
import com.lonx.lyrico.desktop.library.Song
import com.lonx.lyrico.desktop.settings.AppDirs
import com.lonx.lyrico.desktop.tag.TagService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import org.jetbrains.skia.EncodedImageFormat
import org.jetbrains.skia.Image
import org.jetbrains.skia.Rect
import org.jetbrains.skia.SamplingMode
import org.jetbrains.skia.Surface
import java.io.File
import java.security.MessageDigest

object ImageUtils {
    fun decode(bytes: ByteArray): ImageBitmap? = try {
        Image.makeFromEncoded(bytes).toComposeImageBitmap()
    } catch (_: Throwable) {
        null
    }

    /** Center-crops and scales to a [size]x[size] PNG. */
    fun thumbnailPng(bytes: ByteArray, size: Int): ByteArray? = try {
        var img = Image.makeFromEncoded(bytes)
        val side = minOf(img.width, img.height)
        var src = Rect.makeXYWH(((img.width - side) / 2).toFloat(), ((img.height - side) / 2).toFloat(), side.toFloat(), side.toFloat())
        // progressive halving keeps downscaled covers smooth
        var cur = side
        while (cur / 2 >= size * 2) {
            cur /= 2
            val s = Surface.makeRasterN32Premul(cur, cur)
            s.canvas.drawImageRect(img, src, Rect.makeWH(cur.toFloat(), cur.toFloat()), SamplingMode.LINEAR, null, true)
            img = s.makeImageSnapshot()
            src = Rect.makeWH(cur.toFloat(), cur.toFloat())
        }
        val out = Surface.makeRasterN32Premul(size, size)
        out.canvas.drawImageRect(img, src, Rect.makeWH(size.toFloat(), size.toFloat()), SamplingMode.MITCHELL, null, true)
        out.makeImageSnapshot().encodeToData(EncodedImageFormat.PNG)?.bytes
    } catch (_: Throwable) {
        null
    }
}

object Thumbnails {
    private const val SIZE = 96
    private val mem = object : LinkedHashMap<String, ImageBitmap>(256, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, ImageBitmap>?) = size > 800
    }
    private val misses = HashSet<String>()
    private val sem = Semaphore(3)

    fun key(song: Song): String {
        val md = MessageDigest.getInstance("SHA-1").digest("${song.id}|${song.size}|${song.modified}".toByteArray())
        return md.joinToString("") { "%02x".format(it) }
    }

    fun cached(song: Song): ImageBitmap? = synchronized(mem) { mem[key(song)] }

    fun invalidate(song: Song) {
        val k = key(song)
        synchronized(mem) { mem.remove(k); misses.remove(k) }
        File(AppDirs.thumbs, "$k.png").delete()
    }

    /** Stores a thumbnail produced elsewhere (e.g. during a remote scan). */
    fun put(song: Song, coverBytes: ByteArray) {
        val png = ImageUtils.thumbnailPng(coverBytes, SIZE) ?: return
        File(AppDirs.thumbs, "${key(song)}.png").writeBytes(png)
    }

    /** [fileFor] returns a local file to read the cover from, or null when none is available cheaply. */
    suspend fun load(song: Song, fileFor: (Song) -> File?): ImageBitmap? {
        if (!song.hasCover) return null
        val k = key(song)
        synchronized(mem) { mem[k]?.let { return it }; if (k in misses) return null }
        return withContext(Dispatchers.IO) {
            sem.withPermit {
                val disk = File(AppDirs.thumbs, "$k.png")
                val png = if (disk.isFile) disk.readBytes() else {
                    val f = fileFor(song)
                    val cover = try { f?.let { TagService.read(it, withCover = true).cover } } catch (_: Exception) { null }
                    cover?.let { ImageUtils.thumbnailPng(it.bytes, SIZE) }?.also { disk.writeBytes(it) }
                }
                val bmp = png?.let { ImageUtils.decode(it) }
                synchronized(mem) { if (bmp != null) mem[k] = bmp else if (fileFor(song) != null) misses += k }
                bmp
            }
        }
    }
}
