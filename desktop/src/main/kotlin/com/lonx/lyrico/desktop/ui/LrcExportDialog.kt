package com.lonx.lyrico.desktop.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.lonx.lyrico.desktop.lyrics.LrcConflict

/** Export dialog shared by the editor (current lyrics of one song) and the batch pane (tag lyrics of the selection). */
@Composable
fun LrcExportDialog(state: AppState, p: LrcExportPrompt) {
    AlertDialog(
        onDismissRequest = { state.lrcExport = null },
        title = { Text(if (p.single) "导出 LRC：${p.songs.first().fileName}" else "导出 LRC（${p.songs.size} 首）") },
        text = { LrcExportForm(state, p) },
        confirmButton = { TextButton(onClick = { state.runLrcExport(p) }, modifier = Modifier.testTag("lrc-export-confirm")) { Text("导出") } },
        dismissButton = { TextButton(onClick = { state.lrcExport = null }) { Text("取消") } },
    )
}

@Composable
fun LrcExportForm(state: AppState, p: LrcExportPrompt) {
    Column(Modifier.widthIn(min = 420.dp, max = 560.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text("导出位置", fontWeight = FontWeight.SemiBold)
        val dir = p.dir
        SelectionContainer {
            Text(
                dir?.absolutePath ?: "每首歌曲所在的文件夹（默认，同名 .lrc）",
                modifier = Modifier.testTag("lrc-dir-label"),
                color = if (dir == null) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.primary,
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = { state.chooseLrcExportDir(p) }, modifier = Modifier.testTag("lrc-choose-dir")) { Text("选择导出目录…") }
            OutlinedButton(onClick = { p.dir = null }, enabled = dir != null, modifier = Modifier.testTag("lrc-clear-dir")) { Text("清除") }
        }
        val remote = p.songs.count { it.isRemote }
        if (remote > 0) Text(
            if (dir == null) "其中 $remote 首是远程歌曲：LRC 会上传到远程歌曲所在文件夹。" else "其中 $remote 首是远程歌曲：LRC 写入上面的本地目录，不上传。",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(6.dp))
        Text("已存在同名 .lrc 时", fontWeight = FontWeight.SemiBold)
        for (c in LrcConflict.entries) {
            val enabled = c != LrcConflict.NUMBER || dir != null
            Row(
                Modifier.selectable(selected = p.conflict == c, enabled = enabled, role = Role.RadioButton) { p.conflict = c }.testTag("lrc-conflict-${c.name}"),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                RadioButton(selected = p.conflict == c, onClick = null, enabled = enabled)
                Spacer(Modifier.width(6.dp))
                Text(c.label + when (c) {
                    LrcConflict.NUMBER -> if (dir == null) "（仅导出到指定目录时可用；导出到歌曲文件夹时按「跳过」处理）" else "（如「晴天 (2).lrc」）"
                    LrcConflict.OVERWRITE -> if (dir != null) "（不同文件夹中的同名歌曲，后导出的会覆盖先导出的）" else ""
                    LrcConflict.SKIP -> ""
                }, color = if (enabled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        Spacer(Modifier.height(6.dp))
        Row(Modifier.selectable(selected = p.rememberDir, role = Role.Checkbox) { p.rememberDir = !p.rememberDir }.testTag("lrc-remember"), verticalAlignment = Alignment.CenterVertically) {
            Checkbox(checked = p.rememberDir, onCheckedChange = null)
            Spacer(Modifier.width(6.dp))
            Text("记住导出目录（下次默认选中上次的目录）")
        }
        val s = state.settings
        Text(
            (if (p.lyricsOverride != null) "导出编辑框中的歌词。" else "导出标签内的歌词；没有歌词的歌曲会跳过。") +
                " 编码 UTF-8${if (s.lrcBom) " 带 BOM" else ""}，换行 ${s.lrcLineEnding.label}（可在设置中修改）。",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}
