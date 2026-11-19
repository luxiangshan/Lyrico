package com.lonx.lyrico.desktop.remote

import com.lonx.lyrico.desktop.library.Song
import com.lonx.lyrico.desktop.library.SongStore
import com.lonx.lyrico.desktop.lyrics.LrcFiles
import com.lonx.lyrico.desktop.lyrics.LrcWriteOptions
import com.lonx.lyrico.remote.RemoteAuthException
import com.lonx.lyrico.remote.RemoteStorage
import java.io.File
import java.io.IOException
import java.security.MessageDigest

/** Turns provider errors into short Chinese messages; HTTP 405 on upload gets an OpenList-specific hint. */
object RemoteErrors {
    fun friendly(e: Throwable, upload: Boolean = false): String {
        val msg = e.message.orEmpty()
        return when {
            upload && (Regex("""\b405\b""").containsMatchIn(msg) || msg.contains("method not allowed", true)) ->
                "上传被服务器拒绝（HTTP 405）：该远程目录不允许写入。若使用 OpenList/Alist，通常是挂载的存储不支持上传，" +
                    "请在 OpenList 后台确认该存储支持上传、账号有写入权限，或换一个可写的存储/目录。"
            e is RemoteAuthException || Regex("""\b401\b""").containsMatchIn(msg) -> "登录失败或凭据已失效，请检查用户名/密码（或重新登录 115）：$msg"
            Regex("""\b403\b""").containsMatchIn(msg) -> "没有权限（HTTP 403）：$msg"
            Regex("""\b404\b""").containsMatchIn(msg) -> "远程文件不存在（HTTP 404）：$msg"
            Regex("""\b507\b""").containsMatchIn(msg) -> "远程空间不足（HTTP 507）"
            msg.contains("cannot reach", true) || e is java.net.ConnectException || e is java.net.UnknownHostException ->
                "无法连接服务器：$msg"
            else -> msg.ifBlank { e.javaClass.simpleName }
        }
    }
}

class RemoteUploadException(message: String, cause: Throwable) : IOException(message, cause)

/**
 * Remote songs are downloaded into a cache folder for editing and uploaded back on save.
 * The cache copy is reused while the remote size/mtime match.
 */
class RemoteSongStore(
    private val storage: () -> RemoteStorage,
    private val cacheDir: File,
) : SongStore {

    private fun hash(s: String) = MessageDigest.getInstance("SHA-1").digest(s.toByteArray()).joinToString("") { "%02x".format(it) }

    fun cacheFile(song: Song): File = File(cacheDir, hash(song.path) + "." + song.extension.ifEmpty { "bin" })
    private fun metaFile(song: Song) = File(cacheDir, hash(song.path) + ".meta")

    /** The cached full copy if it is still current, else null (no network). */
    fun cachedIfFresh(song: Song): File? {
        val f = cacheFile(song)
        val meta = metaFile(song)
        if (!f.isFile || !meta.isFile) return null
        return if (meta.readText() == "${song.size}|${song.modified}" && f.length() == song.size) f else null
    }

    override fun fileFor(song: Song): File {
        cachedIfFresh(song)?.let { return it }
        cacheDir.mkdirs()
        val f = cacheFile(song)
        val tmp = File(cacheDir, f.name + ".part")
        try {
            storage().openRead(song.path).use { input -> tmp.outputStream().use { input.copyTo(it, 256 * 1024) } }
        } catch (e: Exception) {
            tmp.delete()
            throw IOException("下载「${song.fileName}」失败：${RemoteErrors.friendly(e)}", e)
        }
        f.delete()
        if (!tmp.renameTo(f)) { tmp.copyTo(f, true); tmp.delete() }
        metaFile(song).writeText("${song.size}|${song.modified}")
        return f
    }

    override fun commit(song: Song, file: File) {
        try {
            storage().upload(song.path, file)
        } catch (e: Exception) {
            metaFile(song).delete() // local copy no longer matches the server
            throw RemoteUploadException("上传「${song.fileName}」失败：${RemoteErrors.friendly(e, upload = true)}", e)
        }
    }

    private fun parentOf(path: String) = path.substringBeforeLast('/', "").ifEmpty { "/" }

    private fun join(dir: String, name: String) = if (dir.endsWith("/")) dir + name else "$dir/$name"

    override fun readLrc(song: Song): String? {
        val base = song.baseName
        val entry = storage().list(parentOf(song.path)).firstOrNull {
            !it.isDirectory && it.name.endsWith(".lrc", true) && it.name.substringBeforeLast('.').equals(base, true)
        } ?: return null
        return storage().openRead(entry.path).use { LrcFiles.decode(it.readBytes()) }
    }

    override fun writeLrc(song: Song, text: String, options: LrcWriteOptions): String {
        val dir = parentOf(song.path)
        val existing = try {
            storage().list(dir).firstOrNull {
                !it.isDirectory && it.name.endsWith(".lrc", true) && it.name.substringBeforeLast('.').equals(song.baseName, true)
            }?.path
        } catch (_: Exception) {
            null
        }
        val target = existing ?: join(dir, LrcFiles.lrcNameFor(song.fileName))
        val tmp = File.createTempFile("lyrico", ".lrc")
        try {
            tmp.writeBytes(LrcFiles.encode(text, options))
            storage().upload(target, tmp)
        } catch (e: Exception) {
            throw RemoteUploadException("上传 LRC 失败：${RemoteErrors.friendly(e, upload = true)}", e)
        } finally {
            tmp.delete()
        }
        return "远程 $target"
    }

    override fun refreshStat(song: Song, file: File): Song {
        val st = try { storage().stat(song.path) } catch (_: Exception) { null }
        val updated = if (st != null) song.copy(size = st.size.takeIf { it >= 0 } ?: file.length(), modified = st.modifiedMillis)
        else song.copy(size = file.length())
        if (file == cacheFile(song) && file.length() == updated.size) metaFile(song).writeText("${updated.size}|${updated.modified}")
        return updated
    }
}
