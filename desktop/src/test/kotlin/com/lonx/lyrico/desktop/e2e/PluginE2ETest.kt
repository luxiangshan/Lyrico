package com.lonx.lyrico.desktop.e2e

import com.lonx.lyrico.desktop.plugin.PluginRepository
import com.lonx.lyrico.desktop.plugin.SearchKind
import com.lonx.lyrico.desktop.lyrics.LyricsTarget
import com.lonx.lyrico.desktop.tag.TagEdit
import com.lonx.lyrico.desktop.tag.TagField
import com.lonx.lyrico.desktop.tag.TagService
import com.lonx.lyrico.desktop.ui.AppState
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * (a) installs real plugin ZIPs (src/test/resources/plugins, sources in desktop/testdata/plugins) through the same code as
 * the 导入插件 button and searches lyrics against a mock HTTP source; plus selective enabling: a disabled plugin is never called.
 */
class PluginE2ETest {
    @get:Rule
    val tmp = TemporaryFolder()

    private val server = MockWebServer()
    private val hits = ConcurrentHashMap<String, AtomicInteger>()
    private fun hits(src: String) = hits[src]?.get() ?: 0

    @Before
    fun start() {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val path = request.url.encodedPath
                val src = path.trim('/').substringBefore('/')
                hits.getOrPut(src) { AtomicInteger() }.incrementAndGet()
                return when {
                    path.endsWith("/search") -> MockResponse.Builder().body(
                        """[{"id":"${src}1","title":"晴天","artist":"周杰伦","album":"叶惠美","durationMs":1000,"year":"2003"}]""",
                    ).addHeader("Content-Type", "application/json; charset=utf-8").build()
                    path.endsWith("/lyric") -> MockResponse.Builder().body("[00:01.00]来自源${src.uppercase()}的歌词\n[00:02.00]第二行")
                        .addHeader("Content-Type", "text/plain; charset=utf-8").build()
                    else -> MockResponse.Builder().code(404).build()
                }
            }
        }
        server.start()
    }

    @After
    fun stop() = server.close()

    private val idA = "com.lyrico.test.mocka"
    private val idB = "com.lyrico.test.mockb"

    private fun setup(): Pair<AppState, File> {
        System.setProperty("lyrico.home", File(tmp.root, "home").absolutePath)
        val state = AppState(E2E.uiScope(), File(tmp.root, "plugins"))
        val zips = File(tmp.root, "downloads")
        // same path as 插件管理 › 本地导入 ZIP… (PluginHub.installZip -> installZipNow)
        val msgA = state.plugins.installZipNow(E2E.resourceFile("/plugins/mock-a.zip", zips))
        val msgB = state.plugins.installZipNow(E2E.resourceFile("/plugins/mock-b.zip", zips))
        E2E.report("plugins", "installed via 导入插件 path: $msgA / $msgB")
        val base = server.url("/").toString()
        state.plugins.saveConfig(idA, mapOf("baseUrl" to base))
        state.plugins.saveConfig(idB, mapOf("baseUrl" to base))
        val dir = File(tmp.root, "music")
        val f = E2E.sample("mp3", File(dir, "晴天.mp3"))
        TagService.write(f, TagEdit(mapOf(TagField.TITLE to "晴天", TagField.ARTIST to "周杰伦")))
        state.addFolder(dir)
        E2E.waitUntil("scan") { state.songs.any { it.title == "晴天" } && state.scanStatus == null }
        return state to f
    }

    @Test
    fun installSearchAndSelectiveEnabling() {
        val (state, file) = setup()
        val hub = state.plugins
        assertEquals(setOf(idA, idB), hub.plugins.map { it.id }.toSet())
        assertTrue(hub.hasLyricsSources)

        // editor lyrics search with both plugins
        val song = state.songs.single()
        state.select(setOf(song.id))
        E2E.waitUntil("editor") { state.editor != null }
        hub.openLyricsSearch(state.editor!!)
        val s1 = hub.session!!
        assertEquals(listOf(idA, idB), s1.selected.toList())
        E2E.waitUntil("search 1") { s1.running == 0 }
        assertTrue(s1.errors.isEmpty(), s1.errors.toString())
        assertEquals(setOf("来自源A的歌词", "来自源B的歌词"), s1.lyrics.map { it.text.lines().first().substringAfter(']') }.toSet())
        assertTrue(hits("a") > 0 && hits("b") > 0)
        E2E.report("plugins", "editor search (both enabled): ${s1.lyrics.size} candidates from ${s1.lyrics.map { it.sourceName }.toSet()}")

        // disable B (master 启用 switch): editor search and batch matching never call it
        hub.updateState(idB) { it.copy(enabled = false) }
        assertEquals(listOf(idA), hub.enabled(SearchKind.LYRICS).map { it.id })
        assertFalse(PluginRepository(File(tmp.root, "plugins")).states().getValue(idB).enabled, "persisted to plugins-state.json")
        hits.clear()
        hub.openLyricsSearch(state.editor!!)
        val s2 = hub.session!!
        assertEquals(listOf(idA), s2.selected.toList())
        E2E.waitUntil("search 2") { s2.running == 0 }
        assertEquals(listOf("来自源A的歌词"), s2.lyrics.map { it.text.lines().first().substringAfter(']') })
        assertEquals(0, hits("b"), "disabled plugin B must not be called")

        hub.batchMatchLyrics(state.songs)
        assertEquals(listOf(idA), hub.batchSelected.toList())
        state.updateSettings { it.copy(batchSkipExistingLyrics = false, lyricsTarget = LyricsTarget.TAG) }
        val before = state.lastBatch
        hub.runBatchMatch(state.songs)
        E2E.waitUntil("batch match") { state.lastBatch !== before }
        assertEquals(mapOf("已匹配" to 1), state.lastBatch!!.counts, state.lastBatch!!.failures.toString())
        assertTrue(TagService.read(file).lyrics.startsWith("[00:01.00]来自源A的歌词"))
        assertEquals(0, hits("b"), "disabled plugin B must not be called by batch matching")
        E2E.report("plugins", "B disabled: editor search + batch match called A ${hits("a")}x, B 0x; tag lyrics from A")

        // per-run choice: re-enable B, tick only B for this run
        hub.updateState(idB) { it.copy(enabled = true) }
        hits.clear()
        hub.batchMatchLyrics(state.songs)
        hub.batchSelected.remove(idA)
        val before2 = state.lastBatch
        hub.runBatchMatch(state.songs)
        E2E.waitUntil("batch match 2") { state.lastBatch !== before2 }
        assertTrue(TagService.read(file).lyrics.startsWith("[00:01.00]来自源B的歌词"))
        assertEquals(0, hits("a"), "unticked plugin A must not be called in this run")

        // per-type switch: lyrics off for A, covers still on
        hub.updateState(idA) { it.copy(lyricsEnabled = false) }
        assertEquals(listOf(idB), hub.enabled(SearchKind.LYRICS).map { it.id })
        assertEquals(listOf(idA, idB), hub.enabled(SearchKind.COVER).map { it.id })
        val reloaded = PluginRepository(File(tmp.root, "plugins")).states()
        assertFalse(reloaded.getValue(idA).lyricsEnabled)
        assertTrue(reloaded.getValue(idA).coverEnabled)
        E2E.report("plugins", "per-run selection (only B ticked): A 0x; per-type toggle persisted")
        hub.repo.http.dispatcher.executorService.shutdown()
    }

    /** Real network, informational only (never fails): official catalog -> LrcShare plugin -> search. */
    @Test
    fun officialLrcSharePluginOnlineSoft() {
        try {
            val repo = PluginRepository(File(tmp.root, "official").apply { mkdirs() })
            val cat = repo.fetchCatalog(PluginRepository.OFFICIAL_CATALOG)
            val r = cat.plugins.first { it.id == "com.lrcshare.source" }
            repo.installRelease(r)
            val p = repo.installed().first { it.id == r.id }
            com.lonx.lyrico.desktop.plugin.PluginSource(p, repo) { emptyMap() }.use { src ->
                val songs = src.searchSongs("晴天 周杰伦", pageSize = 5)
                val ly = songs.firstOrNull()?.let { src.getLyrics(it, com.lonx.lyrico.desktop.plugin.LyricsFormatOptions()) }.orEmpty()
                E2E.report("plugins-online", "LrcShare ${r.versionName}: songs=${songs.size} first=${songs.firstOrNull()?.let { "${it.title}/${it.artist}" }} lyrics=${ly.size} lines=${ly.firstOrNull()?.text?.lines()?.size}")
                assertNotNull(songs)
            }
        } catch (e: Throwable) {
            E2E.report("plugins-online", "SKIPPED/FAILED (not counted): ${e.javaClass.simpleName}: ${e.message?.take(200)}")
        }
    }
}
