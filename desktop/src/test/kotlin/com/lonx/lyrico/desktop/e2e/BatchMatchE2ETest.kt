package com.lonx.lyrico.desktop.e2e

import com.lonx.lyrico.desktop.TagSnapshot
import com.lonx.lyrico.desktop.lyrics.LyricsTarget
import com.lonx.lyrico.desktop.plugin.BatchMatchConfig
import com.lonx.lyrico.desktop.plugin.MatchStatus
import com.lonx.lyrico.desktop.plugin.MatchTarget
import com.lonx.lyrico.desktop.plugin.MatchWriteMode
import com.lonx.lyrico.desktop.tag.TagEdit
import com.lonx.lyrico.desktop.tag.TagField
import com.lonx.lyrico.desktop.tag.TagService
import com.lonx.lyrico.desktop.ui.AppState
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okio.Buffer
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import com.lonx.lyrico.desktop.ui.awaitState
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * 批量匹配 end to end with a real plugin ZIP (testdata/plugins/mock-meta) installed through the 导入插件 path, talking to a
 * mock HTTP server, writing real files: supplement keeps existing values, overwrite only overwrites fields the result
 * has, a low-score result is skipped, covers and lyrics are written.
 */
class BatchMatchE2ETest {
    @get:Rule
    val tmp = TemporaryFolder()

    private val server = MockWebServer()
    val searches = AtomicInteger()
    val coverJpg: ByteArray = E2E.resourceBytes("/audio/cover.jpg")

    /** Server catalog: an entry is returned when its "match" text occurs in the search keyword. */
    private fun catalog(base: String) = listOf(
        """{"match":"晴天","id":"s1","title":"晴天","artist":"周杰伦","album":"叶惠美","durationMs":1000,"cover":"${base}m/cover/s1.jpg",
           "fields":{"album_artist":"周杰伦","date":"2003-07-31","track_number":"3/11","disc_number":"1/1","composer":"周杰伦","lyricist":"方文山"}}""",
        """{"match":"十年","id":"s2","title":"十年","artist":"陈奕迅","album":"黑白灰","durationMs":1000,"fields":{"genre":"流行"}}""",
        """{"match":"相约","id":"s3","title":"完全无关的另一首歌","artist":"别的歌手","album":"别的专辑","durationMs":1000,"cover":"${base}m/cover/s3.jpg","fields":{"genre":"爵士"}}""",
    )

    @Before
    fun start() {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val url = request.url
                val base = server.url("/").toString()
                return when {
                    url.encodedPath == "/m/search" -> {
                        searches.incrementAndGet()
                        val kw = url.queryParameter("keyword").orEmpty()
                        val hits = catalog(base).filter { e -> Regex(""""match":"(.*?)"""").find(e)!!.groupValues[1].let { kw.contains(it) } }
                        MockResponse.Builder().body("[" + hits.joinToString(",") + "]").addHeader("Content-Type", "application/json; charset=utf-8").build()
                    }
                    url.encodedPath == "/m/lyric" -> MockResponse.Builder().body("[00:01.00]插件歌词 ${url.queryParameter("id")}\n[00:02.00]第二行")
                        .addHeader("Content-Type", "text/plain; charset=utf-8").build()
                    url.encodedPath.startsWith("/m/cover/") -> MockResponse.Builder().body(Buffer().write(coverJpg)).addHeader("Content-Type", "image/jpeg").build()
                    else -> MockResponse.Builder().code(404).build()
                }
            }
        }
        server.start()
    }

    @After
    fun stop() = server.close()

    private val id = "com.lyrico.test.mockmeta"

    private fun setup(files: Map<String, (File) -> Unit>): Pair<AppState, File> {
        System.setProperty("lyrico.home", File(tmp.root, "home").absolutePath)
        val state = AppState(E2E.uiScope(), File(tmp.root, "plugins"))
        state.plugins.installZipNow(E2E.resourceFile("/plugins/mock-meta.zip", File(tmp.root, "downloads")))
        state.plugins.saveConfig(id, mapOf("baseUrl" to server.url("/").toString()))
        val dir = File(tmp.root, "music")
        for ((name, init) in files) init(File(dir, name).also { it.parentFile.mkdirs() })
        state.addFolder(dir)
        E2E.waitUntil("scan") { state.songs.size == files.size && state.scanStatus == null }
        state.updateSettings { it.copy(lyricsTarget = LyricsTarget.TAG) }
        return state to dir
    }

    private fun run(state: AppState, cfg: BatchMatchConfig) {
        state.select(state.songs.map { it.id }.toSet())
        assertEquals(listOf(id), state.plugins.matchSelected.toList(), "plugin ticked by default")
        state.plugins.startBatchMatch(state.songs.sortedBy { it.fileName }, cfg)
        E2E.waitUntil("batch match", 60_000) { state.plugins.matchRun?.finished == true }
    }

    private fun sample(ext: String, fields: Map<TagField, String>, lyrics: String? = null): (File) -> Unit = { f ->
        E2E.sample(ext, f); TagService.write(f, TagEdit(fields, lyrics))
    }

    @Test
    fun supplementFillsOnlyEmptyFieldsWritesCoverAndLyricsSkipsLowScore() {
        val (state, dir) = setup(linkedMapOf(
            "1 晴天.mp3" to sample("mp3", mapOf(TagField.TITLE to "晴天", TagField.ARTIST to "周杰伦", TagField.ALBUM to "我自己的专辑")),
            "2 十年.flac" to sample("flac", mapOf(TagField.TITLE to "十年", TagField.ARTIST to "陈奕迅", TagField.GENRE to "粤语")),
            "3 相约九八.m4a" to sample("m4a", mapOf(TagField.TITLE to "相约九八", TagField.ARTIST to "王菲")),
        ))
        val lowBefore = File(dir, "3 相约九八.m4a").readBytes()
        run(state, BatchMatchConfig(MatchTarget.entries.toSet(), MatchWriteMode.SUPPLEMENT, concurrency = 2))
        val results = state.plugins.matchRun!!.results.associateBy { it.song.fileName }
        assertEquals(MatchStatus.MATCHED, results.getValue("1 晴天.mp3").status, results.toString())
        assertEquals(MatchStatus.MATCHED, results.getValue("2 十年.flac").status)
        assertEquals(MatchStatus.NOT_FOUND, results.getValue("3 相约九八.m4a").status, results.getValue("3 相约九八.m4a").detail)
        assertTrue(results.getValue("1 晴天.mp3").detail.startsWith("模拟歌曲信息源 "), results.getValue("1 晴天.mp3").detail)

        val t1 = TagService.read(File(dir, "1 晴天.mp3"), withCover = true)
        assertEquals("我自己的专辑", t1[TagField.ALBUM], "supplement keeps the existing album")
        assertEquals("周杰伦", t1[TagField.ALBUM_ARTIST]); assertEquals("3", t1[TagField.TRACK]); assertEquals("11", t1[TagField.TRACK_TOTAL])
        assertEquals("2003", t1[TagField.YEAR]); assertEquals("方文山", t1[TagField.LYRICIST]); assertEquals("周杰伦", t1[TagField.COMPOSER])
        assertEquals("[00:01.00]插件歌词 s1\n[00:02.00]第二行", t1.lyrics.trimEnd())
        assertContentEquals(coverJpg, t1.cover?.bytes, "cover written")

        val t2 = TagService.read(File(dir, "2 十年.flac"), withCover = true)
        assertEquals("粤语", t2[TagField.GENRE], "supplement keeps the existing genre")
        assertEquals("黑白灰", t2[TagField.ALBUM])
        assertEquals("", t2[TagField.YEAR], "result has no date: nothing written, nothing cleared")
        assertEquals(null, t2.cover, "result has no cover")

        assertContentEquals(lowBefore, File(dir, "3 相约九八.m4a").readBytes(), "low score: file untouched")
        E2E.report("batch-match", "supplement (${E2E.os}): 晴天 filled album artist/track/year/composer/lyricist/lyrics/cover, kept own album; 十年 kept own genre; 相约九八 low score skipped, file untouched; ${results.values.joinToString(" | ") { "${it.song.fileName}: ${it.status.label} ${it.detail}" }}")
    }

    @Test
    fun overwriteReplacesOnlyFieldsPresentInResultAndKeepsAllOtherFrames() {
        val (state, dir) = setup(linkedMapOf(
            "1 晴天.mp3" to { f: File -> E2E.resourceFile("/audio/rich/rich0_v24.mp3", f.parentFile).renameTo(f) },
            "2 十年.flac" to { f: File -> E2E.resourceFile("/audio/rich/rich1.flac", f.parentFile).renameTo(f) },
        ))
        val f1 = File(dir, "1 晴天.mp3"); val f2 = File(dir, "2 十年.flac")
        val before1 = TagSnapshot.of(f1); val before2 = TagSnapshot.of(f2)
        val oldCover2 = TagService.read(f2, withCover = true).cover!!.bytes
        run(state, BatchMatchConfig(setOf(MatchTarget.ALBUM, MatchTarget.GENRE, MatchTarget.COMPOSER, MatchTarget.LYRICIST, MatchTarget.COVER), MatchWriteMode.OVERWRITE, concurrency = 1))
        val results = state.plugins.matchRun!!.results.associateBy { it.song.fileName }
        assertEquals(MatchStatus.MATCHED, results.getValue("1 晴天.mp3").status, results.toString())

        // 晴天: result has album/composer/lyricist/cover but NO genre -> genre "流行" kept
        val t1 = TagService.read(f1, withCover = true)
        assertEquals("叶惠美", t1[TagField.ALBUM]); assertEquals("周杰伦", t1[TagField.COMPOSER]); assertEquals("方文山", t1[TagField.LYRICIST])
        assertEquals("流行", t1[TagField.GENRE], "overwrite never clears a field the result lacks")
        assertContentEquals(coverJpg, t1.cover!!.bytes)
        val changed1 = setOf("TALB", "TCOM", "TEXT", "APIC")
        assertEquals(TagSnapshot.without(before1, changed1), TagSnapshot.without(TagSnapshot.of(f1), changed1), "晴天: every other frame identical")
        assertTrue(TagSnapshot.values(TagSnapshot.of(f1), "APIC").any { it.contains("PictureType=4") }, "back cover kept")
        assertEquals("2.4", TagSnapshot.id3Version(f1))

        // 十年: result has album + genre only (no composer/lyricist/cover) -> those kept, old cover bytes kept
        val t2 = TagService.read(f2, withCover = true)
        assertEquals("黑白灰", t2[TagField.ALBUM]); assertEquals("流行", t2[TagField.GENRE])
        assertEquals("作曲 1", t2[TagField.COMPOSER]); assertEquals("作词 1", t2[TagField.LYRICIST])
        assertContentEquals(oldCover2, t2.cover!!.bytes)
        val changed2 = setOf("ALBUM", "GENRE")
        assertEquals(TagSnapshot.without(before2, changed2), TagSnapshot.without(TagSnapshot.of(f2), changed2), "十年: every other comment/picture identical")
        E2E.report("batch-match", "overwrite: only fields present in the result replaced (genre/composer/lyricist/cover kept when missing); all other frames identical; ${results.values.joinToString(" | ") { "${it.song.fileName}: ${it.detail}" }}")
    }

    /** The same flow through the real batch pane UI: 批量匹配 is the first, prominent action. */
    @OptIn(androidx.compose.ui.test.ExperimentalTestApi::class)
    @Test
    fun batchMatchFromTheBatchPaneUi() = androidx.compose.ui.test.runComposeUiTest {
        val (state, dir) = setup(linkedMapOf(
            "1 晴天.mp3" to sample("mp3", mapOf(TagField.TITLE to "晴天", TagField.ARTIST to "周杰伦", TagField.GENRE to "我的流派")),
            "2 十年.ogg" to sample("ogg", mapOf(TagField.TITLE to "十年", TagField.ARTIST to "陈奕迅")),
            "3 相约九八.wv" to sample("wv", mapOf(TagField.TITLE to "相约九八", TagField.ARTIST to "王菲")),
        ))
        val lowBefore = File(dir, "3 相约九八.wv").readBytes()
        state.select(state.songs.map { it.id }.toSet())
        setContent { com.lonx.lyrico.desktop.ui.Fresh { com.lonx.lyrico.desktop.AppTheme(false) { com.lonx.lyrico.desktop.ui.BatchPane(state) } } }
        waitForIdle()
        onNodeWithTag("source-$id").assertIsSelected()
        onNodeWithTag("match-toggle-all").assertTextContains("全选").performClick()
        awaitState("all targets") { state.settings.batchMatchTargets.size == MatchTarget.entries.size }
        onNodeWithTag("match-mode-SUPPLEMENT").performClick()
        onNodeWithTag("match-conc-2").performClick()
        onNodeWithTag("match-start").assertIsEnabled().performClick()
        awaitState("match finished", 60_000) { state.plugins.matchRun?.finished == true }
        onNodeWithTag("match-progress").assertTextContains("完成 3 / 3：已匹配 2，未匹配 1，跳过 0，失败 0", substring = true)
        assertTrue(onAllNodesWithText("最高分", substring = true).fetchSemanticsNodes().isNotEmpty(), "low-score reason shown")
        val t1 = TagService.read(File(dir, "1 晴天.mp3"), withCover = true)
        assertEquals("叶惠美", t1[TagField.ALBUM]); assertEquals("我的流派", t1[TagField.GENRE], "existing genre kept")
        assertContentEquals(coverJpg, t1.cover?.bytes)
        assertTrue(t1.lyrics.startsWith("[00:01.00]插件歌词 s1"))
        val t2 = TagService.read(File(dir, "2 十年.ogg"))
        assertEquals("黑白灰", t2[TagField.ALBUM]); assertEquals("流行", t2[TagField.GENRE])
        assertContentEquals(lowBefore, File(dir, "3 相约九八.wv").readBytes(), "low score: untouched")
        E2E.report("ui", "批量匹配 via BatchPane (${E2E.os}): 全选 fields, 补充, 2 at once -> 已匹配 2 / 未匹配 1 shown; existing genre kept; cover+lyrics written; low score file untouched")
    }
}
