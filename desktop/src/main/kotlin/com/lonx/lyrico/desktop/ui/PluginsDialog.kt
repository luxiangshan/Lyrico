package com.lonx.lyrico.desktop.ui

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable

@Composable
fun PluginsDialog(state: AppState) {
    AlertDialog(
        onDismissRequest = { state.showPlugins = false },
        title = { Text("插件") },
        text = { Text("插件功能尚未在 Windows 版中提供。") },
        confirmButton = { TextButton(onClick = { state.showPlugins = false }) { Text("确定") } },
    )
}
