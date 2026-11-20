package com.lonx.lyrico.desktop

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.VerticalDivider
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.painter.BitmapPainter
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.WindowPosition
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import com.lonx.lyrico.desktop.ui.AppState
import com.lonx.lyrico.desktop.ui.BatchPane
import com.lonx.lyrico.desktop.ui.Dialogs
import com.lonx.lyrico.desktop.ui.EditorPane
import com.lonx.lyrico.desktop.ui.ImageUtils
import com.lonx.lyrico.desktop.ui.PluginsDialog
import com.lonx.lyrico.desktop.ui.RemoteDialog
import com.lonx.lyrico.desktop.ui.SettingsDialog
import com.lonx.lyrico.desktop.ui.Sidebar
import com.lonx.lyrico.desktop.ui.SongListPane

const val APP_VERSION = "1.7.0"

fun main(args: Array<String>) {
    if (args.firstOrNull() == "--selftest") {
        val ok = SelfTest.run(java.io.File(args.getOrNull(1) ?: "lyrico-selftest.txt"))
        kotlin.system.exitProcess(if (ok) 0 else 1)
    }
    Dialogs.initLookAndFeel()
    val icon = Thread.currentThread().contextClassLoader.getResourceAsStream("icon.png")?.use { it.readBytes() }
        ?.let { ImageUtils.decode(it) }?.let { BitmapPainter(it) }
    application {
        val windowState = rememberWindowState(size = DpSize(1360.dp, 860.dp), position = WindowPosition(Alignment.Center))
        val scope = rememberCoroutineScope()
        val state = remember { AppState(scope) }
        Window(
            onCloseRequest = { if (state.editor?.dirty == true) state.confirmExit = true else exitApplication() },
            state = windowState,
            title = "Lyrico Mod $APP_VERSION",
            icon = icon,
        ) {
            AppTheme(state.settings.darkTheme) {
                App(state)
                if (state.confirmExit) {
                    AlertDialog(
                        onDismissRequest = { state.confirmExit = false },
                        title = { Text("有未保存的更改") },
                        text = { Text("当前歌曲的修改尚未保存，确定要退出吗？") },
                        confirmButton = { TextButton(onClick = { exitApplication() }) { Text("放弃并退出") } },
                        dismissButton = { TextButton(onClick = { state.confirmExit = false }) { Text("取消") } },
                    )
                }
            }
        }
    }
}

@Composable
fun AppTheme(dark: Boolean, content: @Composable () -> Unit) {
    val scheme = if (dark) darkColorScheme(primary = Color(0xFF9DC1FF), secondary = Color(0xFF8FD0C3))
    else lightColorScheme(primary = Color(0xFF2F6AC8), secondary = Color(0xFF2E8C7C), surfaceVariant = Color(0xFFE9EEF6))
    MaterialTheme(colorScheme = scheme, content = content)
}

@Composable
fun App(state: AppState) {
    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Box(Modifier.fillMaxSize()) {
            Row(Modifier.fillMaxSize()) {
                Sidebar(state, Modifier.width(230.dp).fillMaxHeight())
                VerticalDivider()
                SongListPane(state, Modifier.weight(1f).fillMaxHeight())
                VerticalDivider()
                Column(Modifier.width(560.dp).fillMaxHeight()) {
                    when {
                        state.selection.size > 1 && state.batch != null -> BatchPane(state)
                        else -> EditorPane(state)
                    }
                }
            }
            SnackbarHost(state.snackbar, Modifier.align(Alignment.BottomCenter).padding(16.dp).fillMaxWidth(0.6f))
        }
        if (state.showSettings) SettingsDialog(state)
        if (state.showRemoteDialog) RemoteDialog(state)
        if (state.showPlugins) PluginsDialog(state)
        state.plugins.session?.let { com.lonx.lyrico.desktop.ui.PluginSearchDialog(state, it) }
        state.lrcExport?.let { com.lonx.lyrico.desktop.ui.LrcExportDialog(state, it) }
        state.plugins.confirmBatch?.let { com.lonx.lyrico.desktop.ui.BatchMatchConfirm(state, it) }
        state.pendingSelection?.let { pending ->
            AlertDialog(
                onDismissRequest = { state.pendingSelection = null },
                title = { Text("放弃未保存的更改？") },
                text = { Text("当前歌曲有未保存的修改，切换后这些修改会丢失。") },
                confirmButton = { TextButton(onClick = { state.select(pending, force = true) }) { Text("放弃更改") } },
                dismissButton = { TextButton(onClick = { state.pendingSelection = null }) { Text("继续编辑") } },
            )
        }
    }
}
