package com.lonx.lyrico.desktop.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.runComposeUiTest
import com.lonx.lyrico.desktop.AppTheme
import com.lonx.lyrico.desktop.e2e.E2E
import com.lonx.lyrico.desktop.plugin.PluginRepository
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import kotlin.test.assertEquals
import kotlin.test.assertFalse

/** 插件管理 row 启用 switch and the batch-match "本次使用的插件" chips. */
@OptIn(ExperimentalTestApi::class)
class PluginToggleUiTest {
    @get:Rule
    val tmp = TemporaryFolder()

    @Test
    fun disableSwitchAndPerRunChips() = runComposeUiTest {
        val state = libraryState(tmp.root, mapOf("晴天.mp3" to { _: File -> }))
        val hub = state.plugins
        hub.installZipNow(E2E.resourceFile("/plugins/mock-a.zip", File(tmp.root, "dl")))
        hub.installZipNow(E2E.resourceFile("/plugins/mock-b.zip", File(tmp.root, "dl")))
        val a = hub.plugins.first { it.id.endsWith("mocka") }
        val b = hub.plugins.first { it.id.endsWith("mockb") }
        var showBatch = false
        setContent {
            Fresh { AppTheme(false) {
                Column {
                    PluginRow(state, a)
                    PluginRow(state, b)
                }
                hub.confirmBatch?.let { if (showBatch) BatchMatchConfirm(state, it) }
            } }
        }
        onNodeWithTag("plugin-enabled-${b.id}").performClick()
        waitForIdle()
        assertFalse(hub.state(b.id).enabled)
        assertFalse(PluginRepository(File(tmp.root, "plugins")).states().getValue(b.id).enabled)
        onNodeWithText("${b.displayName}  1.0（已停用）").assertExists()

        showBatch = true
        hub.batchMatchLyrics(state.songs)
        refresh()
        onNodeWithTag("source-${a.id}").assertExists()
        onNodeWithTag("source-${b.id}").assertDoesNotExist()
        onNodeWithTag("source-${a.id}").performClick()
        assertEquals(emptyList(), hub.batchSelected.toList())
        onNodeWithText("开始").assertIsNotEnabled()
        E2E.report("ui", "Plugins (${E2E.os}): 启用 switch disables plugin (persisted); batch-match chips list only enabled plugins")
    }
}
