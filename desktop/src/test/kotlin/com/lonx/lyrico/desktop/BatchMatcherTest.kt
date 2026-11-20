package com.lonx.lyrico.desktop

import com.lonx.lyrico.desktop.library.Song
import com.lonx.lyrico.desktop.plugin.BatchMatchConfig
import com.lonx.lyrico.desktop.plugin.BatchMatcher
import com.lonx.lyrico.desktop.plugin.CoverCandidate
import com.lonx.lyrico.desktop.plugin.LyricsCandidate
import com.lonx.lyrico.desktop.plugin.MatchCandidate
import com.lonx.lyrico.desktop.plugin.MatchLocalSong
import com.lonx.lyrico.desktop.plugin.MatchSource
import com.lonx.lyrico.desktop.plugin.MatchStatus
import com.lonx.lyrico.desktop.plugin.MatchTarget
import com.lonx.lyrico.desktop.plugin.MatchWriteMode
import com.lonx.lyrico.desktop.plugin.MusicMatch
import com.lonx.lyrico.desktop.plugin.PluginSong
import com.lonx.lyrico.desktop.tag.AudioInfo
import com.lonx.lyrico.desktop.tag.TagData
import com.lonx.lyrico.desktop.tag.TagField
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Pure tests of the ported Android matching rules (no plugins, no files). */
class BatchMatcherTest {
    private class Fake(val results: List<PluginSong>, val lyricsText: String? = "[00:01.00]插件歌词") : MatchSource {
        val queries = ArrayList<String>()
        override val id = "fake"
        override val name = "假插件"
        override val searchesSongs = true
        override val providesLyrics = lyricsText != null
        override val searchesCovers = false
        override fun searchSongs(keyword: String, pageSize: Int): List<PluginSong> { queries += keyword; return results.take(pageSize) }
        override fun lyrics(song: PluginSong) = lyricsText?.let { listOf(LyricsCandidate(id, name, song.title, song.artist, song.album, "", "lrc", it)) }.orEmpty()
        override fun searchCovers(keyword: String) = emptyList<CoverCandidate>()
    }

    private fun result(title: String, artist: String, album: String = "", fields: Map<String, String> = emptyMap(), pic: String = "", durMs: Long = 269_000) =
        PluginSong("fake", "假插件", "1", title, artist, album, durMs, fields["date"].orEmpty(), fields["track_number"].orEmpty(), pic, fields, null)

    private fun tag(fields: Map<TagField, String>, lyrics: String = "", cover: Boolean = false) =
        TagData(fields, lyrics, null, cover, AudioInfo(durationSeconds = 269))

    private val song = Song(id = "x", path = "/x/周杰伦 - 晴天.mp3", fileName = "周杰伦 - 晴天.mp3", title = "晴天", artist = "周杰伦", durationSeconds = 269)
    private val png = byteArrayOf(0x89.toByte(), 'P'.code.toByte(), 'N'.code.toByte(), 'G'.code.toByte(), 13, 10, 26, 10, 0, 0, 0, 13)

    @Test
    fun portedScoringMatchesAndroidBehaviour() {
        val local = MatchLocalSong("周杰伦 - 晴天.mp3", "晴天", "周杰伦", 269_000)
        val exact = MusicMatch.calculateMatchScoreDetail(MatchCandidate("晴天", "周杰伦", 269_000), local)
        assertTrue(exact.finalScore >= BatchMatcher.META_EARLY_FINAL && exact.textScore >= BatchMatcher.META_EARLY_TEXT, "$exact")
        val other = MusicMatch.calculateMatchScoreDetail(MatchCandidate("七里香", "周杰伦", 299_000), local)
        assertTrue(other.finalScore < BatchMatcher.META_MIN_FINAL, "$other")
        assertEquals(1.0, MusicMatch.smartSimilarity("晴天 (Live)", "晴天"))
        assertEquals(listOf("周杰伦", "晴天"), MusicMatch.parseFileNameSegments("01. 周杰伦 - 晴天.mp3"))
        assertEquals(listOf("晴天 周杰伦", "晴天", "周杰伦"), MusicMatch.buildSearchQueries(local).take(3))
        assertEquals(listOf("周杰伦 - 晴天"), MusicMatch.buildSearchQueries(local, preferFileName = true))
    }

    @Test
    fun supplementOnlyFillsBlankFieldsAndNeverClears() {
        val src = Fake(listOf(result("晴天", "周杰伦", "叶惠美", mapOf("genre" to "流行", "date" to "2003-07-31", "track_number" to "3/11", "composer" to ""))))
        val t = tag(mapOf(TagField.TITLE to "晴天", TagField.ARTIST to "周杰伦", TagField.ALBUM to "我自己的专辑", TagField.COMPOSER to "周杰伦"), lyrics = "[00:01.00]已有歌词")
        val (status, plan) = BatchMatcher.plan(song, t, BatchMatchConfig(MatchTarget.entries.toSet(), MatchWriteMode.SUPPLEMENT), listOf(src), listOf(src), emptyList(), { png })
        assertEquals(MatchStatus.MATCHED, status, plan.detail)
        assertEquals(mapOf(TagField.TRACK to "3", TagField.TRACK_TOTAL to "11", TagField.YEAR to "2003", TagField.GENRE to "流行"), plan.fields)
        assertNull(plan.lyrics, "existing lyrics kept in supplement mode")
        assertTrue(plan.fields.values.none { it.isBlank() })
        assertTrue(plan.detail.startsWith("假插件 "), plan.detail)
    }

    @Test
    fun overwriteOnlyReplacesFieldsTheResultHas() {
        val src = Fake(listOf(result("晴天", "周杰伦", "叶惠美", mapOf("date" to "2003"), pic = "http://x/c.png")))
        val t = tag(mapOf(TagField.TITLE to "晴天", TagField.ARTIST to "周杰伦", TagField.ALBUM to "旧专辑", TagField.GENRE to "摇滚", TagField.YEAR to "2003-07-31", TagField.COMPOSER to "周杰伦"), cover = true)
        val (status, plan) = BatchMatcher.plan(song, t, BatchMatchConfig(MatchTarget.entries.toSet(), MatchWriteMode.OVERWRITE), listOf(src), listOf(src), emptyList(), { png })
        assertEquals(MatchStatus.MATCHED, status, plan.detail)
        assertEquals(mapOf(TagField.ALBUM to "叶惠美"), plan.fields, "genre/composer missing from result -> kept; same title/artist and a less precise year are not rewritten")
        assertEquals("[00:01.00]插件歌词", plan.lyrics)
        assertNotNull(plan.cover)
        assertEquals(listOf(MatchTarget.ALBUM, MatchTarget.LYRICS, MatchTarget.COVER), plan.written)
    }

    @Test
    fun lowScoreIsSkippedAndNothingWritten() {
        val src = Fake(listOf(result("完全无关的歌", "别的歌手", "别的专辑", mapOf("genre" to "爵士"), pic = "http://x/c.png", durMs = 100_000)))
        val (status, plan) = BatchMatcher.plan(song, tag(mapOf(TagField.TITLE to "晴天", TagField.ARTIST to "周杰伦")), BatchMatchConfig(), listOf(src), listOf(src), emptyList(), { png })
        assertEquals(MatchStatus.NOT_FOUND, status, plan.detail)
        assertTrue(plan.isEmpty)
        assertTrue(plan.detail.contains("低于"), plan.detail)
    }

    @Test
    fun supplementWithEverythingFilledSkipsWithoutSearching() {
        val src = Fake(listOf(result("晴天", "周杰伦", "叶惠美")))
        val full = TagField.entries.associateWith { "x" }
        val cfg = BatchMatchConfig(setOf(MatchTarget.ALBUM, MatchTarget.LYRICS, MatchTarget.COVER), MatchWriteMode.SUPPLEMENT)
        val (status, _) = BatchMatcher.plan(song, tag(full, lyrics = "x", cover = true), cfg, listOf(src), listOf(src), emptyList(), { png })
        assertEquals(MatchStatus.SKIPPED, status)
        assertTrue(src.queries.isEmpty(), "no plugin call when nothing is needed")
        assertFalse(BatchMatcher.needed(tag(full, "x", true), cfg).isNotEmpty())
    }
}
