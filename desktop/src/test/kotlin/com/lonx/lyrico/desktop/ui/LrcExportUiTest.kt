package com.lonx.lyrico.desktop.ui

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.runComposeUiTest
import com.lonx.lyrico.desktop.AppTheme
import com.lonx.lyrico.desktop.e2e.E2E
import com.lonx.lyrico.desktop.lyrics.LrcConflict
import com.lonx.lyrico.desktop.lyrics.LrcFiles
import com.lonx.lyrico.desktop.tag.TagEdit
import com.lonx.lyrico.desktop.tag.TagService
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Drives the LRC export dialog from the batch pane: 选择导出目录, 重名时加序号, 记住导出目录, 清除. */
@OptIn(ExperimentalTestApi::class)
class LrcExportUiTest {
    @get:Rule
    val tmp = TemporaryFolder()

    @Test
    fun exportToChosenDirectoryThenSongFolders() = runComposeUiTest {
        val state = libraryState(tmp.root, mapOf(
            "A/晴天.mp3" to { f: File -> TagService.write(f, TagEdit(lyrics = "[00:01.00]A")) },
            "B/晴天.flac" to { f: File -> TagService.write(f, TagEdit(lyrics = "[00:01.00]B")) },
        ))
        state.updateSettings { it.copy(rememberLrcExportDir = false, lrcExportConflict = LrcConflict.OVERWRITE) }
        val out = File(tmp.root, "导出目录").apply { mkdirs() }
        state.chooseDirectory = { _, _ -> out }
        state.select(state.songs.map { it.id }.toSet())
        awaitState("batch tags read") { state.batch?.tagsLoaded == true }
        setContent {
            Fresh {
                AppTheme(false) {
                    BatchPane(state)
                    state.lrcExport?.let { LrcExportDialog(state, it) }
                }
            }
        }
        onNodeWithTag("batch-export-lrc").performScrollTo().performClick()
        onNodeWithTag("lrc-dir-label").assertTextContains("每首歌曲所在的文件夹", substring = true)
        onNodeWithTag("lrc-conflict-NUMBER").assertIsNotEnabled()
        onNodeWithTag("lrc-choose-dir").performClick()
        onNodeWithTag("lrc-dir-label").assertTextEquals(out.absolutePath)
        onNodeWithTag("lrc-conflict-NUMBER").performClick()
        onNodeWithTag("lrc-remember").performClick()
        onNodeWithTag("lrc-export-confirm").performClick()
        awaitState("export 1") { state.lastBatch != null && state.busy == null && state.batch?.tagsLoaded == true }
        assertEquals(listOf("晴天 (2).lrc", "晴天.lrc"), out.list()!!.sorted())
        assertEquals(setOf("[00:01.00]A", "[00:01.00]B"), out.listFiles()!!.map { LrcFiles.read(it) }.toSet())
        assertTrue(state.settings.rememberLrcExportDir)
        assertEquals(out.absolutePath, state.settings.lrcExportDir)
        assertEquals(LrcConflict.NUMBER, state.settings.lrcExportConflict)

        // remembered directory is preselected; 清除 goes back to song folders
        val first = state.lastBatch
        onNodeWithTag("batch-export-lrc").performScrollTo().performClick()
        onNodeWithTag("lrc-dir-label").assertTextEquals(out.absolutePath)
        onNodeWithTag("lrc-clear-dir").performClick()
        onNodeWithTag("lrc-dir-label").assertTextContains("每首歌曲所在的文件夹", substring = true)
        onNodeWithTag("lrc-conflict-OVERWRITE").performClick()
        onNodeWithTag("lrc-remember").performClick() // turn "remember" off
        onNodeWithTag("lrc-export-confirm").performClick()
        awaitState("export 2") { state.lastBatch !== first && state.busy == null && state.batch?.tagsLoaded == true }
        assertEquals("[00:01.00]A", LrcFiles.read(File(tmp.root, "music/A/晴天.lrc")))
        assertEquals("[00:01.00]B", LrcFiles.read(File(tmp.root, "music/B/晴天.lrc")))
        assertEquals(2, out.list()!!.size, "nothing new in the export dir")
        assertFalse(state.settings.rememberLrcExportDir)

        // not remembered -> next dialog starts unselected
        onNodeWithTag("batch-export-lrc").performScrollTo().performClick()
        onNodeWithTag("lrc-dir-label").assertTextContains("每首歌曲所在的文件夹", substring = true)
        E2E.report("ui", "LRC export dialog (${E2E.os}): chosen dir + 重名时加序号 -> ${out.list()!!.sorted()}; 清除 -> song folders; 记住导出目录 on/off")
    }
}
