package com.lonx.lyrico.desktop.ui

import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHostState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.lonx.lyrico.desktop.library.BatchChange
import com.lonx.lyrico.desktop.library.BatchCover
import com.lonx.lyrico.desktop.library.BatchEdit
import com.lonx.lyrico.desktop.library.BatchField
import com.lonx.lyrico.desktop.library.EditorData
import com.lonx.lyrico.desktop.library.LibraryCache
import com.lonx.lyrico.desktop.library.LibraryScanner
import com.lonx.lyrico.desktop.library.LocalSongStore
import com.lonx.lyrico.desktop.library.Song
import com.lonx.lyrico.desktop.library.SongActions
import com.lonx.lyrico.desktop.library.SongSorting
import com.lonx.lyrico.desktop.library.SongStore
import com.lonx.lyrico.desktop.library.SortKey
import com.lonx.lyrico.desktop.lyrics.LrcConflict
import com.lonx.lyrico.desktop.lyrics.LrcExportPlan
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

/**
 * Manual batch editor. A field is written ONLY when the user changed it: typed a value that differs from the shared one
 * (or any value into a 〈多个值〉 field), or pressed its 清空 button. Ticking alone never writes anything; the tick only
 * includes/excludes a pending change. 全选 ticks the fields that have a pending change and clears nothing.
 * The cover is kept unless an image was chosen or 移除封面 was pressed.
 */
class BatchState(val songs: List<Song>) {
    val checked = mutableStateMapOf<BatchField, Boolean>()
    val values = mutableStateMapOf<BatchField, String>()
    /** true = the songs have different values (or not all could be read): placeholder 〈多个值〉. */
    val mixed = mutableStateMapOf<BatchField, Boolean>()
    /** Shared value each field had when loaded ("" for 〈多个值〉), to tell a real edit from the initial text. */
    private val original = mutableStateMapOf<BatchField, String>()
    /** Fields the user explicitly asked to clear with the 清空 button. */
    val clearing = mutableStateMapOf<BatchField, Boolean>()
    private val touched = HashSet<BatchField>()
    var cover by mutableStateOf<BatchCover>(BatchCover.Keep)
    /** Songs that currently have a cover (from the library index). */
    val withCover: Int = songs.count { it.hasCover }
    var tagsLoaded by mutableStateOf(false)
    /** Change summary waiting for confirmation (null = no dialog). */
    var confirm by mutableStateOf<List<String>?>(null)

    init {
        val index = BatchEdit.fromIndex(songs)
        for (f in BatchField.entries) {
            checked[f] = false
            if (!f.isText) continue
            values[f] = index[f].orEmpty()
            original[f] = index[f].orEmpty()
            mixed[f] = f !in index || index[f] == null
        }
    }

    /** Fills shared values read from the tags, leaving fields the user already edited alone. */
    fun applyShared(shared: Map<BatchField, String?>) {
        for ((f, v) in shared) {
            original[f] = v.orEmpty()
            if (f in touched) continue
            values[f] = v.orEmpty()
            mixed[f] = v == null
        }
        tagsLoaded = true
    }

    /** The user typed in a field: it becomes a pending change (and is ticked) only if the text really differs. */
    fun setValue(f: BatchField, v: String) {
        values[f] = v
        touched += f
        clearing[f] = false
        checked[f] = isEdited(f)
    }

    /** 清空 button: explicitly clear this field on every selected song. Pressing it again undoes it. */
    fun toggleClear(f: BatchField) {
        val on = clearing[f] != true
        clearing[f] = on
        if (on) { values[f] = ""; touched += f } else { values[f] = original[f].orEmpty(); touched -= f }
        checked[f] = hasChange(f)
    }

    /** A non-empty value that differs from what the songs share (any non-empty value for 〈多个值〉). */
    fun isEdited(f: BatchField): Boolean {
        val v = values[f].orEmpty()
        return f in touched && v.isNotBlank() && (mixed[f] == true || v.trim() != original[f].orEmpty().trim())
    }

    fun hasChange(f: BatchField): Boolean = when (f) {
        BatchField.COVER -> cover != BatchCover.Keep
        else -> clearing[f] == true || isEdited(f)
    }

    fun setCoverImage(art: CoverArt, name: String?) { cover = BatchCover.Replace(art, name); checked[BatchField.COVER] = true }
    fun setRemoveCover() { cover = BatchCover.Remove; checked[BatchField.COVER] = true }
    fun keepCover() { cover = BatchCover.Keep; checked[BatchField.COVER] = false }

    /** Ticking a field without a pending change does nothing (it is not "write empty"). */
    fun setChecked(f: BatchField, on: Boolean) { checked[f] = on && hasChange(f) }

    val pending: List<BatchField> get() = BatchField.entries.filter { hasChange(it) }
    val checkedSet: Set<BatchField> get() = BatchField.entries.filter { checked[it] == true && hasChange(it) }.toSet()
    val allChecked: Boolean get() = pending.isNotEmpty() && pending.all { checked[it] == true }

    /** 全选 ticks every field that has a pending change; 全不选 unticks all. Never clears or writes anything by itself. */
    fun toggleAll() {
        val v = !allChecked
        BatchField.entries.forEach { checked[it] = v && hasChange(it) }
    }

    fun changes(): Map<BatchField, BatchChange> {
        val out = LinkedHashMap<BatchField, BatchChange>()
        for (f in checkedSet) {
            if (f == BatchField.COVER) continue
            out[f] = if (clearing[f] == true) BatchChange.Clear else BatchChange.SetValue(values[f].orEmpty())
        }
        return out
    }

    private fun coverAction(): BatchCover = if (BatchField.COVER in checkedSet) cover else BatchCover.Keep
    fun buildEdit(): TagEdit = BatchEdit.build(changes(), coverAction())
    fun describe(): List<String> = BatchEdit.describe(changes(), coverAction())
}

class BatchSummary(val title: String, val counts: Map<String, Int>, val failures: List<String>)

/** State of the LRC export dialog (one song from the editor, or the batch selection). */
class LrcExportPrompt(val songs: List<Song>, val lyricsOverride: String?, initialDir: File?, conflict: LrcConflict, rememberDir: Boolean) {
    var dir by mutableStateOf(initialDir)
    var conflict by mutableStateOf(conflict)
    var rememberDir by mutableStateOf(rememberDir)
    val single get() = lyricsOverride != null || songs.size == 1
}

class AppState(val scope: CoroutineScope, pluginDir: File? = null) {
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
    val plugins = com.lonx.lyrico.desktop.plugin.PluginHub(this, pluginDir?.let { com.lonx.lyrico.desktop.plugin.PluginRepository(it) } ?: com.lonx.lyrico.desktop.plugin.PluginRepository())
    var lrcExport by mutableStateOf<LrcExportPrompt?>(null)

    /** File choosers (replaced by tests; the real ones are Swing dialogs). */
    var chooseDirectory: (title: String, start: File?) -> File? = { t, d -> Dialogs.chooseFolder(t, d) }
    var chooseImage: () -> File? = { Dialogs.openFile("选择封面图片", "图片 (jpg/png/webp)", Dialogs.imageExtensions) }

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
            // Progress updates are posted asynchronously; never let a late one overwrite the final state.
            val finished = java.util.concurrent.atomic.AtomicBoolean(false)
            try {
                val result = LibraryScanner.scan(settings.folders, cached, settings.scanThreads) { done, total, partial ->
                    scope.launch {
                        if (finished.get()) return@launch
                        scanStatus = "正在扫描 $done / $total"
                        if (done < total) songs = remoteSongs + partial
                    }
                }
                finished.set(true)
                songs = remoteSongs + result
                persistSongsSoon()
                val errors = result.count { it.error != null }
                scanStatus = null
                toast("扫描完成：${result.size} 首" + if (errors > 0) "，$errors 个文件无法读取" else "")
                editor?.let { e -> if (songs.none { it.id == e.song.id }) { editor = null } }
            } catch (e: kotlinx.coroutines.CancellationException) {
                finished.set(true)
                throw e
            } catch (e: Exception) {
                finished.set(true)
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
            if (ids.size > 1) openBatch(ids)
        }
    }

    private var batchLoadJob: Job? = null
    private fun openBatch(ids: Set<String>) {
        val b = BatchState(songs.filter { it.id in ids })
        batch = b
        plugins.syncMatchSelection()
        batchLoadJob?.cancel()
        batchLoadJob = scope.launch {
            val tags = withContext(Dispatchers.IO) {
                b.songs.map { s ->
                    runCatching {
                        val f = if (s.isRemote) (storeFor(s) as? com.lonx.lyrico.desktop.remote.RemoteSongStore)?.cachedIfFresh(s) else File(s.path)
                        f?.let { com.lonx.lyrico.desktop.tag.TagService.read(it, false) }
                    }.getOrNull()
                }
            }
            if (batch === b) b.applyShared(BatchEdit.shared(tags))
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

    fun setCoverBytes(bytes: ByteArray) {
        val e = editor ?: return
        if (ImageUtils.decode(bytes) == null) { toast("无法识别该图片"); return }
        val art = CoverArt(bytes, CoverArt.sniffMime(bytes))
        e.cover = art
        e.coverChange = CoverChange.Replace(art)
    }

    fun removeCover() {
        val e = editor ?: return
        e.cover = null
        e.coverChange = if (e.data.tag.cover != null) CoverChange.Remove else CoverChange.Keep
    }

    /** Opens the LRC export dialog for the editor's current lyrics. */
    fun exportEditorLrc() {
        val e = editor ?: return
        if (e.lyrics.isBlank()) { toast("歌词为空"); return }
        openLrcExport(listOf(e.song), e.lyrics)
    }

    fun loadAdjacentLrcIntoEditor() {
        val e = editor ?: return
        scope.launch {
            val text = withContext(Dispatchers.IO) { runCatching { storeFor(e.song).readLrc(e.song) }.getOrNull() }
            if (text.isNullOrBlank()) toast("没有找到同名 LRC 文件") else { e.lyrics = text; toast("已载入同名 LRC，保存后生效") }
        }
    }

    // ---------------------------------------------------------------- batch actions

    /** Result of the last finished batch run (shown as a toast; read by tests). */
    var lastBatch by mutableStateOf<BatchSummary?>(null)

    fun runBatch(title: String, list: List<Song>, op: (Song) -> String?) {
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
            lastBatch = BatchSummary(title, counts.toMap(), failures.toList())
            busy = null
            val summary = counts.entries.joinToString("，") { "${it.key} ${it.value} 首" }
            val fail = if (failures.isEmpty()) "" else "；失败 ${failures.size} 首（${failures.take(3).joinToString("；")}${if (failures.size > 3) "…" else ""}）"
            toast("$title 完成：$summary$fail", long = failures.isNotEmpty())
            val sel = selection
            if (sel.size > 1) openBatch(sel)
        }
    }

    /** Writes the batch changes after the user confirmed the list of what will change. */
    fun applyBatch(confirmed: Boolean = false) {
        val b = batch ?: return
        val edit = b.buildEdit()
        if (edit.isEmpty) { toast("没有要修改的字段：先在字段中输入新值，或点「清空」/选择封面"); return }
        if (!confirmed) { b.confirm = b.describe(); return }
        b.confirm = null
        val coverTouched = edit.cover != CoverChange.Keep
        runBatch("批量修改", b.songs.mapNotNull { s -> songs.firstOrNull { it.id == s.id } }) { s ->
            val updated = actions.applyEdit(s, edit)
            if (coverTouched) Thumbnails.invalidate(s)
            scope.launch { updateSong(updated) }
            "已修改"
        }
    }

    fun chooseBatchCover() {
        val b = batch ?: return
        val f = chooseImage() ?: return
        try {
            val art = CoverArt.fromFile(f)
            if (ImageUtils.decode(art.bytes) == null) { toast("无法识别该图片（支持 jpg/png/webp）"); return }
            b.setCoverImage(art, f.name)
        } catch (ex: Exception) {
            toast("读取图片失败：${ex.message}")
        }
    }

    fun openLrcExport(list: List<Song> = selectedSongs, lyricsOverride: String? = null) {
        if (list.isEmpty()) return
        val s = settings
        val dir = if (s.rememberLrcExportDir) s.lrcExportDir?.let { File(it) }?.takeIf { it.isDirectory } else null
        lrcExport = LrcExportPrompt(list, lyricsOverride, dir, s.lrcExportConflict, s.rememberLrcExportDir)
    }

    fun chooseLrcExportDir(p: LrcExportPrompt) {
        val start = p.dir ?: settings.lrcExportDir?.let { File(it) }?.takeIf { it.isDirectory }
        chooseDirectory("选择 LRC 导出目录", start)?.let { p.dir = it }
    }

    fun runLrcExport(p: LrcExportPrompt) {
        lrcExport = null
        val dir = p.dir
        updateSettings { it.copy(lrcExportConflict = p.conflict, rememberLrcExportDir = p.rememberDir, lrcExportDir = dir?.absolutePath ?: it.lrcExportDir) }
        if (dir != null && !dir.isDirectory && !dir.mkdirs()) { toast("无法创建导出目录：${dir.absolutePath}", long = true); return }
        val plan = LrcExportPlan(dir, p.conflict)
        val where = dir?.absolutePath ?: "歌曲所在文件夹"
        runBatch("导出 LRC 到 $where", p.songs) { s ->
            val r = actions.exportLrc(s, plan, p.lyricsOverride)
            if (r.song != s) scope.launch { updateSong(r.song) }
            r.outcome.label
        }
    }

    fun batchExportLrc(list: List<Song> = selectedSongs) = openLrcExport(list)

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
