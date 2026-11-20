package com.lonx.lyrico.desktop.plugin

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.ImageBitmap
import com.lonx.lyrico.desktop.library.Song
import com.lonx.lyrico.desktop.lyrics.LrcFiles
import com.lonx.lyrico.desktop.tag.TagEdit
import com.lonx.lyrico.desktop.tag.TagField
import com.lonx.lyrico.desktop.ui.AppState
import com.lonx.lyrico.desktop.ui.EditorState
import com.lonx.lyrico.desktop.ui.ImageUtils
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.concurrent.ConcurrentHashMap

enum class SearchKind(val label: String) { LYRICS("歌词"), COVER("封面"), METADATA("歌曲信息") }

/** State of one search dialog. Results stream in per source. */
class SearchSession(val kind: SearchKind, val editor: EditorState, initialKeyword: String, sourceIds: List<String>) {
    /** Plugins ticked for this search (default: every enabled one). */
    val selected = mutableStateListOf<String>().apply { addAll(sourceIds) }
    var keyword by mutableStateOf(initialKeyword)
    val lyrics = mutableStateListOf<LyricsCandidate>()
    val covers = mutableStateListOf<Pair<CoverCandidate, ImageBitmap?>>()
    val songs = mutableStateListOf<PluginSong>()
    val errors = mutableStateListOf<String>()
    var running by mutableStateOf(0)
    var applyCoverWithMetadata by mutableStateOf(true)
    var job: Job? = null
}

/** Simple title/artist/duration similarity used to rank plugin results (0..1). */
object MatchScore {
    private fun norm(s: String) = s.lowercase().replace(Regex("""\(.*?\)|（.*?）|\[.*?]|【.*?】"""), "")
        .replace(Regex("""[\s\p{Punct}（）【】「」《》·・、，。！？：；]+"""), "")

    fun text(a: String, b: String): Double {
        val x = norm(a); val y = norm(b)
        if (x.isEmpty() || y.isEmpty()) return 0.0
        if (x == y) return 1.0
        if (x.contains(y) || y.contains(x)) return 0.8 * minOf(x.length, y.length) / maxOf(x.length, y.length) + 0.2
        val common = x.toSet().intersect(y.toSet()).size.toDouble()
        return common / maxOf(x.toSet().size, y.toSet().size) * 0.6
    }

    fun artist(a: String, b: String): Double {
        val sa = a.split('/', '&', ',', '、', ';', '；').map { it.trim() }.filter { it.isNotEmpty() }
        val sb = b.split('/', '&', ',', '、', ';', '；').map { it.trim() }.filter { it.isNotEmpty() }
        if (sa.isEmpty() || sb.isEmpty()) return 0.5
        return sa.maxOf { x -> sb.maxOf { y -> text(x, y) } }
    }

    fun song(title: String, artist: String, durationSec: Int, cTitle: String, cArtist: String, cDurationMs: Long): Double {
        val d = if (durationSec > 0 && cDurationMs > 0) {
            val diff = kotlin.math.abs(durationSec - cDurationMs / 1000.0)
            if (diff <= 3) 1.0 else if (diff <= 10) 0.6 else 0.0
        } else 0.5
        return text(title, cTitle) * 0.6 + artist(artist, cArtist) * 0.3 + d * 0.1
    }
}

/** A running or finished 批量匹配: per-song results stream in. */
class BatchMatchRun(val songs: List<Song>, val config: BatchMatchConfig, val sourceNames: List<String>) {
    val results = mutableStateListOf<SongMatchResult>()
    val inProgress = mutableStateListOf<String>()
    var finished by mutableStateOf(false)
    var cancelled by mutableStateOf(false)
    var job: Job? = null
    fun count(s: MatchStatus) = results.count { it.status == s }
}

class PluginHub(private val app: AppState, val repo: PluginRepository = PluginRepository()) {
    var plugins by mutableStateOf(repo.installed())
        private set
    var states by mutableStateOf(repo.states())
        private set
    var session by mutableStateOf<SearchSession?>(null)
    var busy by mutableStateOf<String?>(null)
    var catalog by mutableStateOf<List<CatalogRelease>?>(null)
    var configuring by mutableStateOf<InstalledPlugin?>(null)
    var confirmBatch by mutableStateOf<List<Song>?>(null)
    /** Plugins ticked in the batch-match dialog (default: every enabled lyrics source). */
    val batchSelected = mutableStateListOf<String>()
    private val sources = ConcurrentHashMap<String, PluginSource>()

    fun state(id: String) = states[id] ?: PluginState(order = plugins.indexOfFirst { it.id == id })

    /** Enabled plugins for [kind], in the user's order. Disabled plugins (master switch or per type) are left out. */
    fun enabled(kind: SearchKind): List<InstalledPlugin> = plugins.filter { p ->
        val s = state(p.id)
        s.enabled && when (kind) {
            SearchKind.LYRICS -> PluginManifest.CAP_GET_LYRICS in p.caps && s.lyricsEnabled
            SearchKind.COVER -> PluginManifest.CAP_SEARCH_COVERS in p.caps && s.coverEnabled
            SearchKind.METADATA -> PluginManifest.CAP_SEARCH_SONGS in p.caps && s.metadataEnabled
        }
    }.sortedBy { state(it.id).order }

    val hasLyricsSources get() = enabled(SearchKind.LYRICS).isNotEmpty()
    val hasCoverSources get() = enabled(SearchKind.COVER).isNotEmpty()
    val hasMetadataSources get() = enabled(SearchKind.METADATA).isNotEmpty()

    private fun source(p: InstalledPlugin) = sources.getOrPut(p.id) { PluginSource(p, repo) { state(p.id).config } }

    private fun reload() {
        sources.values.forEach { runCatching { it.close() } }
        sources.clear()
        plugins = repo.installed()
        states = repo.states()
    }

    fun updateState(id: String, transform: (PluginState) -> PluginState) {
        states = states + (id to transform(state(id)))
        repo.saveStates(states)
    }

    fun saveConfig(id: String, config: Map<String, String>) {
        states = states + (id to state(id).copy(config = config))
        repo.saveStates(states)
        sources.remove(id)?.close()
    }

    fun move(id: String, delta: Int) {
        val order = plugins.sortedBy { state(it.id).order }.map { it.id }.toMutableList()
        val i = order.indexOf(id); val j = (i + delta).coerceIn(0, order.lastIndex)
        if (i < 0 || i == j) return
        order.removeAt(i); order.add(j, id)
        states = order.withIndex().associate { (n, pid) -> pid to state(pid).copy(order = n) }
        repo.saveStates(states)
    }

    private fun launchBusy(label: String, block: suspend () -> String) {
        busy = label
        app.scope.launch {
            val msg = try { block() } catch (e: Exception) { "$label 失败：${e.message ?: e.javaClass.simpleName}" }
            busy = null
            app.toast(msg, long = true)
        }
    }

    /** 导入插件 button: installs a local ZIP. */
    fun installZip(file: File) = launchBusy("安装插件") { withContext(Dispatchers.IO) { installZipNow(file) } }

    /** Blocking part of [installZip]; returns the message shown to the user. */
    fun installZipNow(file: File): String {
        val ms = repo.installZip(file.readBytes())
        reload()
        return "已安装：" + ms.joinToString("、") { m -> plugins.firstOrNull { it.id == m.id }?.displayName ?: m.id }
    }

    fun loadCatalog(url: String) = launchBusy("获取插件列表") {
        catalog = withContext(Dispatchers.IO) { repo.fetchCatalog(url).plugins }
        "共 ${catalog?.size ?: 0} 个插件"
    }

    fun installRelease(r: CatalogRelease) = launchBusy("安装 ${r.name}") {
        withContext(Dispatchers.IO) { repo.installRelease(r) }
        reload()
        "已安装 ${plugins.firstOrNull { it.id == r.id }?.displayName ?: r.name} ${r.versionName}"
    }

    fun installAll(list: List<CatalogRelease>) = launchBusy("安装全部插件") {
        val failed = ArrayList<String>()
        for (r in list.filter { it.compatible }) {
            try { withContext(Dispatchers.IO) { repo.installRelease(r) } } catch (e: Exception) { failed += "${r.name}：${e.message}" }
        }
        reload()
        if (failed.isEmpty()) "已安装 ${list.size} 个插件" else "部分失败：" + failed.joinToString("；")
    }

    fun remove(id: String) {
        sources.remove(id)?.close()
        repo.remove(id)
        reload()
    }

    private val formatOptions get() = LyricsFormatOptions(app.settings.pluginIncludeTranslation, app.settings.pluginWordByWord)

    private fun keywordOf(e: EditorState): String {
        val t = e.fields[TagField.TITLE].orEmpty().ifBlank { e.song.baseName }
        return listOf(t, e.fields[TagField.ARTIST].orEmpty()).filter { it.isNotBlank() }.joinToString(" ")
    }

    private fun newSession(kind: SearchKind, e: EditorState, keyword: String) = SearchSession(kind, e, keyword, enabled(kind).map { it.id })

    fun openLyricsSearch(e: EditorState) { session = newSession(SearchKind.LYRICS, e, keywordOf(e)).also { run(it) } }
    fun openCoverSearch(e: EditorState) {
        val kw = listOf(e.fields[TagField.ALBUM].orEmpty().ifBlank { e.fields[TagField.TITLE].orEmpty() }, e.fields[TagField.ARTIST].orEmpty())
            .filter { it.isNotBlank() }.joinToString(" ").ifBlank { e.song.baseName }
        session = newSession(SearchKind.COVER, e, kw).also { run(it) }
    }
    fun openMetadataSearch(e: EditorState) { session = newSession(SearchKind.METADATA, e, keywordOf(e)).also { run(it) } }

    /** Lyrics for one song from one source: via its own song search when it has one, else direct. */
    private fun lyricsFrom(p: InstalledPlugin, title: String, artist: String, album: String, durationSec: Int, keyword: String, maxSongs: Int): List<LyricsCandidate> {
        val src = source(p)
        val opts = formatOptions
        return if (PluginManifest.CAP_SEARCH_SONGS in p.caps) {
            val songs = src.searchSongs(keyword, pageSize = 8)
                .sortedByDescending { MatchScore.song(title, artist, durationSec, it.title, it.artist, it.durationMs) }
                .take(maxSongs)
            songs.flatMap { s -> runCatching { src.getLyrics(s, opts) }.getOrDefault(emptyList()) }
        } else {
            src.getLyrics(PluginSong(p.id, p.displayName, "", title, artist, album, durationSec * 1000L, "", "", "", emptyMap(), null), opts)
        }
    }

    fun run(s: SearchSession) {
        s.job?.cancel()
        s.lyrics.clear(); s.covers.clear(); s.songs.clear(); s.errors.clear()
        val list = enabled(s.kind).filter { it.id in s.selected }
        if (list.isEmpty()) { s.errors += "没有勾选可用的插件"; s.running = 0; return }
        s.running = list.size
        val e = s.editor
        s.job = app.scope.launch {
            coroutineScope {
                for (p in list) launch {
                    try {
                        when (s.kind) {
                            SearchKind.LYRICS -> {
                                val r = withContext(Dispatchers.IO) {
                                    lyricsFrom(p, e.fields[TagField.TITLE].orEmpty().ifBlank { s.keyword }, e.fields[TagField.ARTIST].orEmpty(),
                                        e.fields[TagField.ALBUM].orEmpty(), e.data.tag.audio.durationSeconds, s.keyword, 3)
                                }
                                s.lyrics.addAll(r)
                            }
                            SearchKind.COVER -> {
                                val r = withContext(Dispatchers.IO) { source(p).searchCovers(s.keyword) }
                                s.covers.addAll(r.map { it to null })
                                r.forEach { c ->
                                    launch {
                                        val bmp = withContext(Dispatchers.IO) { runCatching { ImageUtils.thumbnailPng(repo.download(c.url), 160)?.let { ImageUtils.decode(it) } }.getOrNull() }
                                        val idx = s.covers.indexOfFirst { it.first === c }
                                        if (idx >= 0) s.covers[idx] = c to bmp
                                    }
                                }
                            }
                            SearchKind.METADATA -> s.songs.addAll(withContext(Dispatchers.IO) { source(p).searchSongs(s.keyword, pageSize = 10) })
                        }
                    } catch (ex: kotlinx.coroutines.CancellationException) {
                        throw ex
                    } catch (ex: Exception) {
                        s.errors += "${p.displayName}：${ex.message ?: ex.javaClass.simpleName}"
                    } finally {
                        s.running--
                    }
                }
            }
        }
    }

    fun applyLyrics(s: SearchSession, c: LyricsCandidate) {
        s.editor.lyrics = c.text
        s.editor.lyricsFromLrc = false
        session = null
        app.toast("已填入「${c.sourceName}」的歌词，保存后生效")
    }

    fun applyCover(s: SearchSession, c: CoverCandidate) {
        busy = "下载封面"
        app.scope.launch {
            try {
                val bytes = withContext(Dispatchers.IO) { repo.download(c.url) }
                app.setCoverBytes(bytes)
                session = null
            } catch (e: Exception) {
                app.toast("下载封面失败：${e.message}")
            } finally { busy = null }
        }
    }

    fun applyMetadata(s: SearchSession, song: PluginSong) {
        val e = s.editor
        fun set(f: TagField, v: String) { if (v.isNotBlank()) e.fields[f] = v }
        set(TagField.TITLE, song.title)
        set(TagField.ARTIST, song.artist)
        set(TagField.ALBUM, song.album)
        set(TagField.YEAR, song.year)
        val f = song.fields
        set(TagField.ALBUM_ARTIST, f["album_artist"].orEmpty())
        set(TagField.GENRE, f["genre"].orEmpty())
        set(TagField.COMPOSER, f["composer"].orEmpty())
        set(TagField.LYRICIST, f["lyricist"].orEmpty())
        set(TagField.COMMENT, f["comment"].orEmpty())
        val track = song.trackNumber.ifBlank { f["track_number"].orEmpty() }
        if (track.isNotBlank()) { val (n, t) = track.split('/').let { it[0].trim() to it.getOrElse(1) { "" }.trim() }; set(TagField.TRACK, n); set(TagField.TRACK_TOTAL, t) }
        val disc = f["disc_number"].orEmpty()
        if (disc.isNotBlank()) { val (n, t) = disc.split('/').let { it[0].trim() to it.getOrElse(1) { "" }.trim() }; set(TagField.DISC, n); set(TagField.DISC_TOTAL, t) }
        f["lyrics"]?.takeIf { it.isNotBlank() && e.lyrics.isBlank() }?.let { e.lyrics = it }
        val pic = song.picUrl
        session = null
        if (s.applyCoverWithMetadata && pic.isNotBlank()) applyCover(s, CoverCandidate(song.sourceId, song.sourceName, song.title, song.artist, song.album, song.year, pic))
        app.toast("已填入「${song.sourceName}」的歌曲信息，保存后生效")
    }

    // ---------------------------------------------------------------- 批量匹配 (Android batch match)

    var matchRun by mutableStateOf<BatchMatchRun?>(null)
    /** Plugins ticked for 批量匹配 this run (default: every plugin enabled for metadata, lyrics or covers). */
    val matchSelected = mutableStateListOf<String>()
    private var matchSelectionInit = false

    /** Plugins usable by 批量匹配 (enabled for any of 歌曲信息/歌词/封面), in the user's order. */
    fun matchPlugins(): List<InstalledPlugin> =
        (enabled(SearchKind.METADATA) + enabled(SearchKind.LYRICS) + enabled(SearchKind.COVER)).distinctBy { it.id }.sortedBy { state(it.id).order }

    /** Called when the batch pane opens: keeps the user's ticks, adds newly enabled plugins, drops disabled ones. */
    fun syncMatchSelection() {
        val ids = matchPlugins().map { it.id }
        if (!matchSelectionInit) { matchSelected.clear(); matchSelected.addAll(ids); matchSelectionInit = true; return }
        matchSelected.retainAll(ids.toSet())
    }

    private fun matchSource(p: InstalledPlugin): MatchSource = object : MatchSource {
        override val id = p.id
        override val name = p.displayName
        override val searchesSongs = PluginManifest.CAP_SEARCH_SONGS in p.caps
        override val providesLyrics = PluginManifest.CAP_GET_LYRICS in p.caps
        override val searchesCovers = PluginManifest.CAP_SEARCH_COVERS in p.caps
        override fun searchSongs(keyword: String, pageSize: Int) = source(p).searchSongs(keyword, pageSize = pageSize, separator = "/")
        override fun lyrics(song: PluginSong) = source(p).getLyrics(song, formatOptions)
        override fun searchCovers(keyword: String) = source(p).searchCovers(keyword)
    }

    /** Starts 批量匹配 over [songs] with the saved config and the ticked plugins. */
    fun startBatchMatch(songs: List<Song>, cfg: BatchMatchConfig = app.settings.batchMatchConfig, sourceIds: Collection<String> = matchSelected.toList()) {
        if (songs.isEmpty() || matchRun?.finished == false) return
        if (cfg.targets.isEmpty()) { app.toast("请先勾选要匹配的字段"); return }
        val ids = sourceIds.toSet()
        val meta = enabled(SearchKind.METADATA).filter { it.id in ids }
        val lyr = enabled(SearchKind.LYRICS).filter { it.id in ids }
        val cov = enabled(SearchKind.COVER).filter { it.id in ids }
        if (meta.isEmpty() && lyr.isEmpty() && cov.isEmpty()) { app.toast("没有勾选可用的插件（在 插件管理 中安装并启用）"); return }
        val metaS = meta.map(::matchSource); val lyrS = lyr.map(::matchSource); val covS = cov.map(::matchSource)
        val run = BatchMatchRun(songs, cfg, (meta + lyr + cov).distinctBy { it.id }.map { it.displayName })
        matchRun = run
        val target = app.settings.lyricsTarget
        val sem = kotlinx.coroutines.sync.Semaphore(cfg.concurrency.coerceIn(1, 4))
        run.job = app.scope.launch {
            coroutineScope {
                for (s in songs) launch {
                    sem.acquire()
                    try {
                        run.inProgress += s.fileName
                        val r = withContext(Dispatchers.IO) { matchOne(s, cfg, metaS, lyrS, covS, target) }
                        run.results += r
                        r.updated?.let { u -> if (MatchTarget.COVER in r.written) com.lonx.lyrico.desktop.ui.Thumbnails.invalidate(s); app.updateSong(u) }
                    } finally {
                        run.inProgress -= s.fileName
                        sem.release()
                    }
                }
            }
            run.finished = true
            app.toast("批量匹配完成：已匹配 ${run.count(MatchStatus.MATCHED)}，未匹配 ${run.count(MatchStatus.NOT_FOUND)}，跳过 ${run.count(MatchStatus.SKIPPED)}，失败 ${run.count(MatchStatus.FAILED)}")
        }
        run.job?.invokeOnCompletion { e -> if (e != null) app.scope.launch { run.cancelled = true; run.finished = true } }
    }

    fun stopBatchMatch() { matchRun?.job?.cancel() }

    /** Blocking: matches one song and writes the result. Never clears a field. */
    fun matchOne(s: Song, cfg: BatchMatchConfig, meta: List<MatchSource>, lyr: List<MatchSource>, cov: List<MatchSource>, target: com.lonx.lyrico.desktop.lyrics.LyricsTarget): SongMatchResult = try {
        val live = app.songs.firstOrNull { it.id == s.id } ?: s
        val tag = app.actions.readTags(live)
        val (status, plan) = BatchMatcher.plan(live, tag, cfg, meta, lyr, cov, download = { repo.download(it) }, isImage = { ImageUtils.decode(it) != null || com.lonx.lyrico.desktop.tag.ImageSize.of(it) != null })
        if (status == MatchStatus.MATCHED) {
            val updated = app.actions.applyMatch(live, plan, target)
            SongMatchResult(live, status, plan.detail, plan.written, updated)
        } else SongMatchResult(live, status, plan.detail)
    } catch (e: kotlinx.coroutines.CancellationException) {
        throw e
    } catch (e: Exception) {
        SongMatchResult(s, MatchStatus.FAILED, e.message ?: e.javaClass.simpleName)
    }

    /** Batch: best-scoring lyrics from the ticked enabled sources (in order) saved with the default destination. */
    fun batchMatchLyrics(songs: List<Song>) {
        batchSelected.clear()
        batchSelected.addAll(enabled(SearchKind.LYRICS).map { it.id })
        confirmBatch = songs
    }

    fun runBatchMatch(songs: List<Song>, sourceIds: Collection<String> = batchSelected.toList()) {
        confirmBatch = null
        val list = enabled(SearchKind.LYRICS).filter { it.id in sourceIds }
        if (list.isEmpty()) { app.toast("没有勾选可用的歌词插件"); return }
        val skip = app.settings.batchSkipExistingLyrics
        val target = app.settings.lyricsTarget
        app.runBatch("插件匹配歌词", songs) { s -> matchLyrics(s, list, skip, target) }
    }

    /** Blocking: finds and saves lyrics for one song using [list]; returns the outcome label. */
    fun matchLyrics(s: Song, list: List<InstalledPlugin>, skip: Boolean, target: com.lonx.lyrico.desktop.lyrics.LyricsTarget): String {
        if (skip && (s.hasTagLyrics || (s.hasLrc && !target.writesTag))) return "已有歌词跳过"
        val title = s.title.ifBlank { s.baseName }
        val keyword = listOf(title, s.artist).filter { it.isNotBlank() }.joinToString(" ")
        var best: Pair<LyricsCandidate, Double>? = null
        for (p in list) {
            val cands = runCatching { lyricsFrom(p, title, s.artist, s.album, s.durationSeconds, keyword, 2) }.getOrDefault(emptyList())
            val top = cands.filter { LrcFiles.isSynced(it.text) || it.text.isNotBlank() }
                .map { it to MatchScore.song(title, s.artist, s.durationSeconds, it.title, it.artist, it.durationMs) }
                .maxByOrNull { it.second }
            if (top != null && (best == null || top.second > best.second)) best = top
            if (best != null && best.second >= 0.85) break
        }
        val chosen = best?.takeIf { it.second >= 0.55 } ?: return "未找到匹配"
        val tagLyrics = if (s.hasTagLyrics) "\u0000" else ""
        val r = app.actions.save(s, TagEdit(), chosen.first.text, tagLyrics, target)
        app.scope.launch { app.updateSong(r.song) }
        return "已匹配"
    }
}
