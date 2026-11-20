package com.lonx.lyrico.desktop.ui

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextClearance
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.runComposeUiTest
import com.lonx.lyrico.desktop.AppTheme
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

/** Drives the real batch editor UI headlessly: 全选 / 全不选, ticking fields, choosing a cover, confirming clears, saving. */
@OptIn(ExperimentalTestApi::class)
class BatchPaneUiTest {
    @get:Rule
    val tmp = TemporaryFolder()

    @Test
    fun selectAllToggleTickFieldsCoverAndApply() = runComposeUiTest {
        val exts = listOf("mp3", "flac", "opus", "ape")
        val state = libraryState(tmp.root, exts.withIndex().associate { (i, ext) ->
            "歌$i.$ext" to { f: File -> TagService.write(f, TagEdit(mapOf(TagField.TITLE to "标题$i", TagField.ARTIST to "歌手$i", TagField.ALBUM to "同一张专辑", TagField.GENRE to "流行"))) }
        })
        val webp = E2E.resourceFile("/audio/cover.webp", File(tmp.root, "img"))
        state.chooseImage = { webp }
        state.select(state.songs.map { it.id }.toSet())
        val b = state.batch!!
        setContent { Fresh { AppTheme(false) { BatchPane(state) } } }
        awaitState("tags read") { b.tagsLoaded }

        // shared values and 〈多个值〉
        onNodeWithTag("batch-field-ALBUM").assertTextContains("同一张专辑")
        assert(onAllNodesWithText("〈多个值〉", substring = true, useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty())

        // 全选 ticks every field (including 歌词 and 封面), 全不选 clears them
        onNodeWithTag("batch-toggle-all").performClick()
        for (f in BatchField.entries) onNodeWithTag("batch-check-${f.name}").assertIsOn()
        onNodeWithText("全不选").assertExists()
        // applying now would clear the differing titles etc. -> confirmation, then back out
        onNodeWithTag("batch-apply").performClick()
        onNodeWithText("确认清除字段？").assertExists()
        onNodeWithText("返回修改").performClick()
        waitForIdle()
        assertNull(state.lastBatch, "nothing written after 返回修改")
        onNodeWithTag("batch-toggle-all").performClick()
        for (f in BatchField.entries) onNodeWithTag("batch-check-${f.name}").assertIsOff()
        onNodeWithText("全选").assertExists()

        // typing ticks the field; clearing a ticked field means "clear this tag"
        onNodeWithTag("batch-field-ARTIST").performScrollTo().performTextReplacement("统一歌手")
        onNodeWithTag("batch-check-ARTIST").assertIsOn()
        onNodeWithTag("batch-field-GENRE").performScrollTo().performTextClearance()
        onNodeWithTag("batch-check-GENRE").assertIsOn()
        onNodeWithText("将清除所有所选歌曲的「流派」").assertExists()
        // album typed but then unticked -> not written
        onNodeWithTag("batch-field-ALBUM").performScrollTo().performTextReplacement("不要写入")
        onNodeWithTag("batch-check-ALBUM").performClick().assertIsOff()
        onNodeWithTag("batch-cover-choose").performScrollTo().performClick()
        onNodeWithTag("batch-check-COVER").assertIsOn()
        onNodeWithText("将把所有所选歌曲的封面替换为「cover.webp」").assertExists()

        onNodeWithTag("batch-apply").performClick()
        onNodeWithText("确认清除字段？").assertExists()
        onNodeWithTag("batch-confirm-clear").performClick()
        awaitState("batch applied") { state.lastBatch != null && state.busy == null }
        assertEquals(mapOf("已修改" to exts.size), state.lastBatch!!.counts, state.lastBatch!!.failures.toString())

        val cover = CoverArt.fromFile(webp)
        for ((i, ext) in exts.withIndex()) {
            val t = TagService.read(File(tmp.root, "music/歌$i.$ext"), withCover = true)
            assertEquals("统一歌手", t[TagField.ARTIST], ext)
            assertEquals("", t[TagField.GENRE], ext)
            assertEquals("标题$i", t[TagField.TITLE], ext)
            assertEquals("同一张专辑", t[TagField.ALBUM], ext)
            assertContentEquals(cover.bytes, t.cover?.bytes, ext)
        }
        E2E.report("ui", "BatchPane (${E2E.os}): 全选/全不选, typed+cleared fields, unticked album, webp cover via 选择图片, confirm, applied to ${exts.joinToString()}")
    }
}
