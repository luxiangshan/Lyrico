package com.lonx.lyrico.desktop.ui

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.runComposeUiTest
import com.lonx.lyrico.desktop.AppTheme
import com.lonx.lyrico.desktop.e2e.E2E
import com.lonx.lyrico.desktop.lyrics.LrcFiles
import com.lonx.lyrico.desktop.tag.TagField
import com.lonx.lyrico.desktop.tag.TagService
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import kotlin.test.assertEquals
import kotlin.test.assertFalse

/** Drives the single-song editor: 两者都要 / 保存为 LRC / 写入标签, then 保存. */
@OptIn(ExperimentalTestApi::class)
class EditorSaveUiTest {
    @get:Rule
    val tmp = TemporaryFolder()

    @Test
    fun saveWithEachTarget() = runComposeUiTest {
        val state = libraryState(tmp.root, mapOf("晴天.flac" to { _: File -> }))
        val audio = File(tmp.root, "music/晴天.flac")
        val lrc = File(tmp.root, "music/晴天.lrc")
        state.select(setOf(state.songs.single().id))
        setContent { Fresh { AppTheme(false) { EditorPane(state) } } }

        fun saveWith(target: String, lyrics: String, title: String? = null) {
            awaitState("editor loaded") { state.editor != null && !state.editorLoading }
            val e = state.editor
            onNodeWithTag("target-$target").performClick()
            title?.let { onNodeWithTag("editor-field-TITLE").performScrollTo().performTextReplacement(it) }
            onNodeWithTag("editor-lyrics").performScrollTo().performTextReplacement(lyrics)
            onNodeWithTag("editor-save").performClick()
            awaitState("saved and reloaded") { state.editor != null && state.editor !== e && !state.editorLoading }
        }

        saveWith("BOTH", "[00:01.00]界面两者", title = "界面标题")
        assertEquals("[00:01.00]界面两者", TagService.read(audio).lyrics)
        assertEquals("界面标题", TagService.read(audio)[TagField.TITLE])
        assertEquals("[00:01.00]界面两者", LrcFiles.read(lrc))

        saveWith("LRC", "[00:02.00]界面仅LRC")
        assertEquals("[00:01.00]界面两者", TagService.read(audio).lyrics)
        assertEquals("[00:02.00]界面仅LRC", LrcFiles.read(lrc))

        lrc.delete()
        saveWith("TAG", "[00:03.00]界面仅标签")
        assertEquals("[00:03.00]界面仅标签", TagService.read(audio).lyrics)
        assertFalse(lrc.exists())
        E2E.report("ui", "Editor (${E2E.os}): 两者都要 / 保存为 LRC / 写入标签 via buttons + 保存")
    }
}
