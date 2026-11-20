package com.lonx.lyrico.desktop.ui

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.runComposeUiTest
import com.lonx.lyrico.desktop.AppTheme
import com.lonx.lyrico.desktop.TagSnapshot
import com.lonx.lyrico.desktop.e2e.E2E
import com.lonx.lyrico.desktop.library.BatchField
import com.lonx.lyrico.desktop.tag.CoverArt
import com.lonx.lyrico.desktop.tag.TagEdit
import com.lonx.lyrico.desktop.tag.TagField
import com.lonx.lyrico.desktop.tag.TagService
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Drives the real batch editor UI headlessly (runs on windows-latest in CI). */
@OptIn(ExperimentalTestApi::class)
class BatchPaneUiTest {
    @get:Rule
    val tmp = TemporaryFolder()

    /**
     * The user's report: select songs with different values, press 全选, change only 专辑, apply -> everything else
     * (other frames, 〈多个值〉 fields, lyrics, covers) must stay exactly as it was.
     */
    @Test
    fun selectAllThenChangeOnlyAlbumChangesNothingElse() = runComposeUiTest {
        val rich = mapOf("a.mp3" to "rich0_v24.mp3", "b.flac" to "rich1.flac", "c.m4a" to "rich2.m4a", "d.opus" to "rich1.opus", "e.mp3" to "rich2_v23v1.mp3")
        val state = libraryState(tmp.root, rich.mapValues { (_, res) -> { f: File -> f.writeBytes(E2E.resourceBytes("/audio/rich/$res")) } })
        val files = rich.keys.map { File(tmp.root, "music/$it") }
        val before = files.associateWith { TagSnapshot.of(it) }
        val covers = files.associateWith { TagService.read(it, withCover = true).cover!!.bytes }
        state.select(state.songs.map { it.id }.toSet())
        val b = state.batch!!
        setContent { Fresh { AppTheme(false) { BatchPane(state) } } }
        awaitState("tags read") { b.tagsLoaded }
        assertTrue(onAllNodesWithText("〈多个值〉", substring = true, useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty())

        // 全选 with nothing changed ticks nothing and cannot apply anything
        onNodeWithTag("batch-toggle-all").performScrollTo().performClick()
        for (f in BatchField.entries) onNodeWithTag("batch-check-${f.name}").performScrollTo().assertIsOff()
        onNodeWithTag("batch-apply").assertIsNotEnabled()
        assertTrue(b.buildEdit().isEmpty, "全选 alone must not produce any write")

        // change only 专辑; 全不选 / 全选 cycle only touches that field
        onNodeWithTag("batch-field-ALBUM").performScrollTo().performTextReplacement("统一专辑")
        onNodeWithTag("batch-check-ALBUM").assertIsOn()
        onNodeWithTag("batch-toggle-all").performScrollTo().assertTextContains("全不选").performClick()
        onNodeWithTag("batch-check-ALBUM").assertIsOff()
        onNodeWithTag("batch-apply").assertIsNotEnabled()
        onNodeWithTag("batch-toggle-all").performScrollTo().assertTextContains("全选").performClick()
        for (f in BatchField.entries) {
            val node = onNodeWithTag("batch-check-${f.name}").performScrollTo()
            if (f == BatchField.ALBUM) node.assertIsOn() else node.assertIsOff()
        }
        assertEquals(TagEdit(mapOf(TagField.ALBUM to "统一专辑")), b.buildEdit())

        onNodeWithTag("batch-apply").assertIsEnabled().performClick()
        onNodeWithText("确认修改 ${files.size} 首歌曲？").assertExists()
        onNodeWithText("• 专辑 → 「统一专辑」").assertExists()
        assertEquals(listOf("专辑 → 「统一专辑」"), b.confirm, "the dialog lists only the album, nothing cleared")
        onNodeWithTag("batch-confirm").performClick()
        awaitState("batch applied") { state.lastBatch != null && state.busy == null }
        assertEquals(mapOf("已修改" to files.size), state.lastBatch!!.counts, state.lastBatch!!.failures.toString())

        for (f in files) {
            val keys = if (f.extension == "mp3") setOf("TALB", "v1.album") else if (f.extension == "m4a") setOf("©alb") else setOf("ALBUM")
            assertEquals(TagSnapshot.without(before.getValue(f), keys), TagSnapshot.without(TagSnapshot.of(f), keys), "${f.name}: only the album may change")
            assertEquals("统一专辑", TagService.read(f)[TagField.ALBUM], f.name)
            assertContentEquals(covers.getValue(f), TagService.read(f, withCover = true).cover!!.bytes, "${f.name} cover")
        }
        E2E.report("ui", "BatchPane (${E2E.os}): 5 rich files (ID3v2.4, FLAC, M4A, Opus, ID3v2.3+v1) with different titles/artists/covers; 全选 with no edits ticks nothing; only 专辑 changed -> confirm lists only 专辑 -> every other frame and cover identical")
    }

    @Test
    fun explicitClearButtonAndCoverChoice() = runComposeUiTest {
        val exts = listOf("mp3", "flac", "opus", "ape")
        val state = libraryState(tmp.root, exts.withIndex().associate { (i, ext) ->
            "歌$i.$ext" to { f: File -> TagService.write(f, TagEdit(mapOf(TagField.TITLE to "标题$i", TagField.ARTIST to "歌手$i", TagField.ALBUM to "同一张专辑", TagField.GENRE to "流行"), "[00:01.00]歌词$i")) }
        })
        val webp = E2E.resourceFile("/audio/cover.webp", File(tmp.root, "img"))
        state.chooseImage = { webp }
        state.select(state.songs.map { it.id }.toSet())
        val b = state.batch!!
        setContent { Fresh { AppTheme(false) { BatchPane(state) } } }
        awaitState("tags read") { b.tagsLoaded }
        onNodeWithTag("batch-field-ALBUM").assertTextContains("同一张专辑")

        // emptying a text field is NOT a clear
        onNodeWithTag("batch-field-ALBUM").performScrollTo().performTextReplacement("")
        onNodeWithTag("batch-check-ALBUM").assertIsOff()
        // explicit 清空 is
        onNodeWithTag("batch-clear-GENRE").performScrollTo().performClick()
        onNodeWithTag("batch-check-GENRE").assertIsOn()
        onNodeWithText("将从所有所选歌曲中清除「流派」").assertExists()
        onNodeWithTag("batch-field-ARTIST").performScrollTo().performTextReplacement("统一歌手")
        onNodeWithTag("batch-cover-choose").performScrollTo().performClick()
        onNodeWithTag("batch-check-COVER").assertIsOn()
        onNodeWithText("将把所有所选歌曲的封面替换为「cover.webp」").assertExists()

        onNodeWithTag("batch-apply").performClick()
        onNodeWithText("• 艺术家 → 「统一歌手」").assertExists()
        onNodeWithText("• 流派 → 清除").assertExists()
        onNodeWithText("• 封面 → 替换为「cover.webp」").assertExists()
        assertEquals(listOf("艺术家 → 「统一歌手」", "流派 → 清除", "封面 → 替换为「cover.webp」"), b.confirm)
        onNodeWithTag("batch-confirm-cancel").performClick()
        waitForIdle()
        assertNull(state.lastBatch, "nothing written after 返回修改")
        onNodeWithTag("batch-apply").performClick()
        onNodeWithTag("batch-confirm").performClick()
        awaitState("batch applied") { state.lastBatch != null && state.busy == null }
        assertEquals(mapOf("已修改" to exts.size), state.lastBatch!!.counts, state.lastBatch!!.failures.toString())

        val cover = CoverArt.fromFile(webp)
        for ((i, ext) in exts.withIndex()) {
            val t = TagService.read(File(tmp.root, "music/歌$i.$ext"), withCover = true)
            assertEquals("统一歌手", t[TagField.ARTIST], ext)
            assertEquals("", t[TagField.GENRE], ext)
            assertEquals("标题$i", t[TagField.TITLE], "$ext 〈多个值〉 title kept")
            assertEquals("同一张专辑", t[TagField.ALBUM], "$ext emptied-but-not-cleared album kept")
            assertEquals("[00:01.00]歌词$i", t.lyrics.trimEnd(), "$ext lyrics kept")
            assertContentEquals(cover.bytes, t.cover?.bytes, ext)
        }
        E2E.report("ui", "BatchPane: emptied text != clear, 清空 button clears 流派, webp cover via 选择图片, confirm dialog lists exactly 艺术家/流派/封面; 〈多个值〉 titles and lyrics kept on ${exts.joinToString()}")
    }
}
