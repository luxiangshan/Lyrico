package com.lonx.lyrico.desktop.remote

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.lonx.lyrico.desktop.library.Song
import com.lonx.lyrico.desktop.settings.AppDirs
import com.lonx.lyrico.desktop.ui.AppState
import com.lonx.lyrico.desktop.ui.Thumbnails
import com.lonx.lyrico.remote.RemoteConfig
import com.lonx.lyrico.remote.RemoteEntry
import com.lonx.lyrico.remote.RemoteStorage
import com.lonx.lyrico.remote.RemoteType
import com.lonx.lyrico.remote.cloud115.Cloud115Storage
import com.lonx.lyrico.remote.smb.SmbStorage
import com.lonx.lyrico.remote.webdav.OpenListStorage
import com.lonx.lyrico.remote.webdav.WebDavStorage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

val RemoteType.label: String
    get() = when (this) {
        RemoteType.WEBDAV -> "WebDAV"
        RemoteType.OPENLIST -> "OpenList / Alist"
        RemoteType.SMB -> "SMB 共享"
        RemoteType.CLOUD115 -> "115 网盘"
    }

fun createStorage(config: RemoteConfig): RemoteStorage = when (config.type) {
    RemoteType.WEBDAV -> WebDavStorage(config)
    RemoteType.OPENLIST -> OpenListStorage(config, RemoteConfigStore)
    RemoteType.SMB -> SmbStorage(config, RemoteConfigStore)
    RemoteType.CLOUD115 -> Cloud115Storage(config, RemoteConfigStore)
}

class RemoteHub(private val app: AppState) {
    var configs by mutableStateOf(RemoteConfigStore.load())
        private set
    /** Scan status text per remote id. */
    val scanStatus = mutableStateMapOf<String, String>()
    /** Remote config being edited in the dialog (null = new). */
    var editing by mutableStateOf<RemoteConfig?>(null)

    private val storages = ConcurrentHashMap<String, RemoteStorage>()
    private val stores = ConcurrentHashMap<String, RemoteSongStore>()
    private val jobs = HashMap<String, Job>()

    fun config(id: String) = configs.firstOrNull { it.id == id }

    private fun storage(id: String): RemoteStorage = storages.getOrPut(id) {
        createStorage(config(id) ?: throw IllegalStateException("远程位置已删除"))
    }

    fun storeFor(id: String): RemoteSongStore = stores.getOrPut(id) {
        RemoteSongStore({ storage(id) }, File(AppDirs.remoteFiles, id))
    }

    fun cachedFile(song: Song): File? = song.remoteId?.let { storeFor(it).cachedIfFresh(song) }

    fun newId(): String = UUID.randomUUID().toString().substring(0, 8)

    fun save(config: RemoteConfig) {
        val exists = configs.any { it.id == config.id }
        configs = if (exists) configs.map { if (it.id == config.id) config else it } else configs + config
        storages.remove(config.id)?.let { runCatching { it.close() } }
        RemoteConfigStore.save(configs)
        scan(config.id)
    }

    fun remove(id: String) {
        jobs.remove(id)?.cancel()
        configs = configs.filter { it.id != id }
        storages.remove(id)?.let { runCatching { it.close() } }
        stores.remove(id)
        RemoteConfigStore.save(configs)
        RemoteConfigStore.dropExtras(id)
        File(AppDirs.remoteFiles, id).deleteRecursively()
        if (app.location == "remote:$id") app.location = null
        app.replaceSongs { list -> list.filter { it.remoteId != id } }
        app.select(emptySet(), force = true)
    }

    suspend fun test(config: RemoteConfig) = withContext(Dispatchers.IO) {
        createStorage(config).use { it.testConnection() }
    }

    suspend fun listDirs(config: RemoteConfig, path: String): List<RemoteEntry> = withContext(Dispatchers.IO) {
        createStorage(config).use { s -> s.list(path).filter { it.isDirectory }.sortedBy { it.name.lowercase() } }
    }

    fun scan(id: String) {
        jobs[id]?.cancel()
        jobs[id] = app.scope.launch {
            val cfg = config(id) ?: return@launch
            scanStatus[id] = "正在列出文件…"
            try {
                val store = storeFor(id)
                val st = storage(id)
                val (entries, lrc) = withContext(Dispatchers.IO) {
                    RemoteScanner.listAudio(st, cfg.folders, { !isActive }) { dir -> app.scope.launch { scanStatus[id] = "正在列出 $dir" } }
                }
                val old = app.songs.filter { it.remoteId == id }.associateBy { it.id }
                val listed = entries.map { e ->
                    val hasLrc = e.name.substringBeforeLast('.').lowercase() in lrc[RemoteScanner.parentOf(e.path)].orEmpty()
                    val prev = old[Song.remoteKey(id, e.path)]
                    if (prev != null && prev.tagsLoaded && prev.size == e.size && prev.modified == e.modifiedMillis) prev.copy(hasLrc = hasLrc)
                    else RemoteScanner.songFor(id, e, hasLrc)
                }
                app.replaceSongs { list -> list.filter { it.remoteId != id } + listed }
                val pending = listed.filter { !it.tagsLoaded }
                val done = AtomicInteger()
                val failures = AtomicInteger()
                val sem = Semaphore(4)
                val tmpDir = File(AppDirs.cache, "remote-head")
                coroutineScope {
                    pending.map { s ->
                        async(Dispatchers.IO) {
                            sem.withPermit {
                                if (!isActive) return@withPermit
                                val updated = try {
                                    val (tag, cover) = RemoteScanner.readTags(st, s, store, tmpDir)
                                    val u = s.withTag(tag)
                                    if (cover != null) Thumbnails.put(u, cover)
                                    u
                                } catch (e: Exception) {
                                    failures.incrementAndGet()
                                    s.copy(tagsLoaded = true, error = RemoteErrors.friendly(e))
                                }
                                val n = done.incrementAndGet()
                                withContext(Dispatchers.Main) {
                                    app.updateSong(updated)
                                    scanStatus[id] = "正在读取标签 $n / ${pending.size}"
                                }
                            }
                        }
                    }.awaitAll()
                }
                scanStatus.remove(id)
                val f = failures.get()
                app.toast("「${cfg.displayName}」扫描完成：${listed.size} 首" + if (f > 0) "，$f 首读取失败" else "")
            } catch (e: kotlinx.coroutines.CancellationException) {
                scanStatus.remove(id)
                throw e
            } catch (e: Exception) {
                scanStatus.remove(id)
                app.toast("「${cfg.displayName}」扫描失败：${RemoteErrors.friendly(e)}", long = true)
            }
        }
    }
}
