package com.lonx.lyrico.desktop.ui

import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHostState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.lonx.lyrico.desktop.library.EditorData
import com.lonx.lyrico.desktop.library.LibraryCache
import com.lonx.lyrico.desktop.library.LibraryScanner
import com.lonx.lyrico.desktop.library.LocalSongStore
import com.lonx.lyrico.desktop.library.LrcExportOutcome
import com.lonx.lyrico.desktop.library.Song
import com.lonx.lyrico.desktop.library.SongActions
import com.lonx.lyrico.desktop.library.SongSorting
import com.lonx.lyrico.desktop.library.SongStore
import com.lonx.lyrico.desktop.library.SortKey
import com.lonx.lyrico.desktop.lyrics.LrcFiles
import com.lonx.lyrico.desktop.lyrics.LyricsTarget
import com.lonx.lyrico.desktop.remote.RemoteHub
import com.lonx.lyrico.desktop.settings.AppSettings
import com.lonx.lyrico.desktop.settings.SettingsStore
import com.lonx.lyrico.desktop.tag.CoverArt
import com.lonx.lyrico.desktop.tag.CoverChange
import com.lonx.lyrico.desktop.tag.TagEdit
import com.lonx.lyrico.desktop.tag.TagField
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

class EditorState(val data: EditorData, defaultTarget: LyricsTarget) {
    val song: Song get() = data.song
    val original: Map<TagField, String> = TagField.entries.associateWith { data.tag[it] }
    val fields = mutableStateMapOf<TagField, String>().apply { putAll(original) }
    var lyrics by mutableStateOf(data.displayLyrics)
    var lyricsFromLrc by mutableStateOf(data.lyricsFromLrc)
    var cover by mutableStateOf(data.tag.cover)
    var coverChange: CoverChange by mutableStateOf(CoverChange.Keep)
    var target by mutableStateOf(defaultTarget)
    var saving by mutableStateOf(false)

    val changedFields: Map<TagField, String> get() = fields.filter { (k, v) -> v != original[k] }
    val lyricsChanged: Boolean get() = LrcFiles.normalize(lyrics) != LrcFiles.normalize(data.displayLyrics)
    val dirty: Boolean get() = changedFields.isNotEmpty() || lyricsChanged || coverChange != CoverChange.Keep

    fun buildEdit() = TagEdit(fields = changedFields, cover = coverChange)
}

class BatchState(songs: List<Song>) {
    val enabled = mutableStateMapOf<TagField, Boolean>()
    val values = mutableStateMapOf<TagField, String>()
    val mixed = HashSet<TagField>()
    var coverChange: CoverChange by mutableStateOf(CoverChange.Keep)

    init {
        fun common(f: (Song) -> String): String? = songs.map(f).distinct().singleOrNull()
        val known = mapOf<TagField, (Song) -> String>(
            TagField.ARTIST to { it.artist }, TagField.ALBUM to { it.album }, TagField.ALBUM_ARTIST to { it.albumArtist },
            TagField.YEAR to { it.year }, TagField.GENRE to { it.genre }, TagField.DISC to { it.disc },
        )
        for (f in TagField.entries) {
            val getter = known[f]
            val c = if (getter != null) common(getter) else null
            if (getter != null && c == null) mixed += f
            values[f] = c.orEmpty()
            enabled[f] = false
        }
    }

    fun buildEdit() = TagEdit(fields = TagField.entries.filter { enabled[it] == true }.associateWith { values[it].orEmpty() }, cover = coverChange)
}

class AppState(val scope: CoroutineScope) {
    var settings by mutableStateOf(SettingsStore.load())
        private set
    var songs by mutableStateOf(LibraryCache.load())
        private set
    var query by mutableStateOf("")
    var location by mutableStateOf<String?>(null)
    var selection by mutableStateOf<Set<String>>(emptySet())
        private set
    private var anchor: String? = null
    var scanStatus by mutableStateOf<String?>(null)
    var busy by mutableStateOf<String?>(null)
    var editor by mutableStateOf<EditorState?>(null)
        private set
    var editorLoading by mutableStateOf(false)
    var editorError by mutableStateOf<String?>(null)
    var batch by mutableStateOf<BatchState?>(null)
        private set
    /** Selection waiting for the user to confirm discarding unsaved edits. */
    var pendingSelection by mutableStateOf<Set<String>?>(null)
    var showSettings by mutableStateOf(false)
    var showRemoteDialog by mutableStateOf(false)
    var showPlugins by mutableStateOf(false)
    var confirmExit by mutableStateOf(false)
    val snackbar = SnackbarHostState()
    val remote = RemoteHub(this)
    val plugins = com.lonx.lyrico.desktop.plugin.PluginHub(this)

    val sortKey: SortKey get() = runCatching { SortKey.valueOf(settings.sortKey) }.getOrDefault(SortKey.TITLE)

    val visibleSongs: List<Song> by derivedStateOf {
        SongSorting.filterAndSort(songs, query, sortKey, settings.sortDescending, location)
    }
    val selectedSongs: List<Song> by derivedStateOf { visibleSongs.filter { it.id in selection } }

    fun storeFor(song: Song): SongStore = if (song.isRemote) remote.storeFor(song.remoteId!!) else LocalSongStore
    val actions = SongActions({ settings }, ::storeFor)

    fun updateSettings(transform: (AppSettings) -> AppSettings) {
        settings = transform(settings)
        scope.launch(Dispatchers.IO) { runCatching { SettingsStore.save(settings) } }
    }

    fun toast(msg: String, long: Boolean = false) {
        scope.launch { snackbar.showSnackbar(msg, withDismissAction = true, duration = if (long) SnackbarDuration.Long else SnackbarDuration.Short) }
    }

    // ---------------------------------------------------------------- library

    private var saveJob: Job? = null
    private fun persistSongsSoon() {
        saveJob?.cancel()
        saveJob = scope.launch(Dispatchers.IO) { delay(1500); LibraryCache.save(songs) }
    }

    fun replaceSongs(transform: (List<Song>) -> List<Song>) {
        songs = transform(songs)
        persistSongsSoon()
    }

    fun updateSong(song: Song) = replaceSongs { list -> list.map { if (it.id == song.id) song else it } }

    fun addFolder(dir: File) {
        val path = dir.absolutePath
        if (settings.folders.any { it.equals(path, true) }) { toast("该文件夹已添加"); return }
        updateSettings { it.copy(folders = it.folders + path) }
        rescan()
    }

    fun removeFolder(path: String) {
        updateSettings { it.copy(folders = it.folders - path) }
        if (location == path) location = null
        replaceSongs { list -> list.filter { s -> s.isRemote || settings.folders.any { SongSorting.belongsTo(s, it) } } }
        select(emptySet())
    }

    private var scanJob: Job? = null
    fun rescan() {
        scanJob?.cancel()
        scanJob = scope.launch {
            scanStatus = "正在扫描…"
            val cached = songs.filter { !it.isRemote }.associateBy { it.id }
            val remoteSongs = songs.filter { it.isRemote }
            try {
                val result = LibraryScanner.scan(settings.folders, cached, settings.scanThreads) { done, total, partial ->
                    scope.launch {
                        scanStatus = "正在扫描 $done / $total"
                        if (done < total) songs = remoteSongs + partial
                    }
                }
                songs = remoteSongs + result
                persistSongsSoon()
                val errors = result.count { it.error != null }
                scanStatus = null
                toast("扫描完成：${result.size} 首" + if (errors > 0) "，$errors 个文件无法读取" else "")
                editor?.let { e -> if (songs.none { it.id == e.song.id }) { editor = null } }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                scanStatus = null
                toast("扫描失败：${e.message}", long = true)
            }
        }
    }

    // ---------------------------------------------------------------- selection

    fun onRowClick(song: Song, ctrl: Boolean, shift: Boolean) {
        val next = when {
            shift && anchor != null -> {
                val list = visibleSongs
                val a = list.indexOfFirst { it.id == anchor }
                val b = list.indexOfFirst { it.id == song.id }
                if (a < 0 || b < 0) setOf(song.id) else list.subList(minOf(a, b), maxOf(a, b) + 1).map { it.id }.toSet()
            }
            ctrl -> if (song.id in selection) selection - song.id else selection + song.id
            else -> setOf(song.id)
        }
        if (!shift) anchor = song.id
        select(next)
    }

    fun toggleCheck(song: Song) {
        anchor = song.id
        select(if (song.id in selection) selection - song.id else selection + song.id)
    }

    fun selectAllVisible() = select(visibleSongs.map { it.id }.toSet())

    fun select(ids: Set<String>, force: Boolean = false) {
        val e = editor
        if (!force && e != null && e.dirty && ids != setOf(e.song.id)) {
            pendingSelection = ids
            return
        }
        pendingSelection = null
        selection = ids
        batch = null
        if (ids.size == 1) {
            val song = songs.firstOrNull { it.id == ids.first() } ?: return
            if (editor?.song?.id != song.id || force) openEditor(song)
        } else {
            editor = null
            editorError = null
            if (ids.size > 1) batch = BatchState(songs.filter { it.id in ids })
        }
    }

    private var editorJob: Job? = null
    fun openEditor(song: Song) {
        editorJob?.cancel()
        editor = null
        editorError = null
        editorLoading = true
        editorJob = scope.launch {
            try {
                val data = withContext(Dispatchers.IO) { actions.load(song) }
                editor = EditorState(data, settings.lyricsTarget)
                if (data.song != song) updateSong(data.song)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                editorError = e.message ?: e.javaClass.simpleName
            } finally {
                editorLoading = false
            }
        }
    }

    // ---------------------------------------------------------------- editor actions

    fun saveEditor(target: LyricsTarget) {
        val e = editor ?: return
        if (e.saving) return
        e.saving = true
        scope.launch {
            try {
                val result = withContext(Dispatchers.IO) {
                    actions.save(e.song, e.buildEdit(), e.lyrics, e.data.tag.lyrics, target)
                }
                Thumbnails.invalidate(e.song)
                updateSong(result.song)
                toast(result.messages.joinToString("；"))
                editor = null
                openEditor(result.song)
            } catch (ex: Exception) {
                toast("保存失败：${ex.message ?: ex.javaClass.simpleName}", long = true)
            } finally {
                e.saving = false
            }
        }
    }

    fun revertEditor() {
        val e = editor ?: return
        openEditor(e.song)
    }

    fun setCover(file: File) {
        val e = editor ?: return
        try {
            val art = CoverArt.fromFile(file)
            if (ImageUtils.decode(art.bytes) == null) { toast("无法识别该图片"); return }
            e.cover = art
            e.coverChange = CoverChange.Replace(art)
        } catch (ex: Exception) {
            toast("读取图片失败：${ex.message}")
        }
    }

    fun removeCover() {
        val e = editor ?: return
        e.cover = null
        e.coverChange = if (e.data.tag.cover != null) CoverChange.Remove else CoverChange.Keep
    }

    /** Writes the editor's current lyrics to the .lrc only. */
    fun exportEditorLrc() {
        val e = editor ?: return
        if (e.lyrics.isBlank()) { toast("歌词为空"); return }
        scope.launch {
            try {
                val where = withContext(Dispatchers.IO) { storeFor(e.song).writeLrc(e.song, LrcFiles.normalize(e.lyrics), settings.lrcOptions) }
                updateSong(e.song.copy(hasLrc = true))
                toast("已导出 LRC：$where")
            } catch (ex: Exception) {
                toast("导出失败：${ex.message}", long = true)
            }
        }
    }

    fun loadAdjacentLrcIntoEditor() {
        val e = editor ?: return
        scope.launch {
            val text = withContext(Dispatchers.IO) { runCatching { storeFor(e.song).readLrc(e.song) }.getOrNull() }
            if (text.isNullOrBlank()) toast("没有找到同名 LRC 文件") else { e.lyrics = text; toast("已载入同名 LRC，保存后生效") }
        }
    }

    // ---------------------------------------------------------------- batch actions

    private fun runBatch(title: String, list: List<Song>, op: (Song) -> String?) {
        if (list.isEmpty()) return
        scope.launch {
            val failures = ArrayList<String>()
            val counts = HashMap<String, Int>()
            for ((i, s) in list.withIndex()) {
                busy = "$title ${i + 1} / ${list.size}"
                try {
                    val outcome = withContext(Dispatchers.IO) { op(s) }
                    if (outcome != null) counts[outcome] = (counts[outcome] ?: 0) + 1
                } catch (e: Exception) {
                    failures += "${s.fileName}：${e.message ?: e.javaClass.simpleName}"
                }
            }
            busy = null
            val summary = counts.entries.joinToString("，") { "${it.key} ${it.value} 首" }
            val fail = if (failures.isEmpty()) "" else "；失败 ${failures.size} 首（${failures.take(3).joinToString("；")}${if (failures.size > 3) "…" else ""}）"
            toast("$title 完成：$summary$fail", long = failures.isNotEmpty())
            val sel = selection
            if (sel.size > 1) batch = BatchState(songs.filter { it.id in sel })
        }
    }

    fun applyBatch() {
        val b = batch ?: return
        val edit = b.buildEdit()
        if (edit.isEmpty) { toast("请先勾选要修改的字段"); return }
        runBatch("批量修改", selectedSongs) { s ->
            val updated = actions.applyEdit(s, edit)
            Thumbnails.invalidate(s)
            scope.launch { updateSong(updated) }
            "已修改"
        }
    }

    fun batchExportLrc(list: List<Song> = selectedSongs) {
        runBatch("导出 LRC", list) { s ->
            val (outcome, updated) = actions.exportLrc(s, settings.batchExportOverwrite)
            if (updated != s) scope.launch { updateSong(updated) }
            when (outcome) {
                LrcExportOutcome.EXPORTED -> "已导出"
                LrcExportOutcome.NO_LYRICS -> "无歌词"
                LrcExportOutcome.EXISTS_SKIPPED -> "已存在跳过"
                LrcExportOutcome.FAILED -> "失败"
            }
        }
    }

    fun batchImportLrc(list: List<Song> = selectedSongs) {
        runBatch("LRC 写入标签", list) { s ->
            val updated = actions.importLrcToTag(s)
            if (updated == null) "无同名 LRC" else { scope.launch { updateSong(updated) }; "已写入" }
        }
    }

    fun exportCover(song: Song, dest: File) {
        scope.launch {
            val ok = runCatching { withContext(Dispatchers.IO) { actions.exportCover(song, dest) } }
            toast(if (ok.getOrNull() == true) "封面已导出：${dest.absolutePath}" else "导出失败：${ok.exceptionOrNull()?.message ?: "没有封面"}")
        }
    }
}
