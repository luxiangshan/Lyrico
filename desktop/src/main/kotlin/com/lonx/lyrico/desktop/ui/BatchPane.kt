package com.lonx.lyrico.desktop.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.lonx.lyrico.desktop.tag.CoverArt
import com.lonx.lyrico.desktop.tag.CoverChange
import com.lonx.lyrico.desktop.tag.TagField

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun BatchPane(state: AppState) {
    val b = state.batch ?: return
    val count = state.selection.size
    val busy = state.busy != null
    Column(Modifier.fillMaxSize()) {
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(16.dp)) {
            Text("批量编辑 $count 首", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Text("勾选要修改的字段；留空并勾选表示清除该字段。", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.height(10.dp))
            val fields = TagField.entries.filter { it != TagField.TITLE && it != TagField.TRACK }
            for (f in fields) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(checked = b.enabled[f] == true, onCheckedChange = { b.enabled[f] = it })
                    OutlinedTextField(
                        value = b.values[f].orEmpty(),
                        onValueChange = { b.values[f] = it; b.enabled[f] = true },
                        label = { Text(f.label) },
                        placeholder = { if (f in b.mixed) Text("<多个值>") },
                        singleLine = true,
                        modifier = Modifier.weight(1f),
                    )
                }
                Spacer(Modifier.height(4.dp))
            }
            Spacer(Modifier.height(8.dp))
            Text("封面", style = MaterialTheme.typography.titleSmall)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.Center) {
                OutlinedButton(onClick = {
                    Dialogs.openFile("选择封面图片", "图片", Dialogs.imageExtensions)?.let {
                        runCatching { CoverArt.fromFile(it) }.onSuccess { art -> b.coverChange = CoverChange.Replace(art) }
                    }
                }) { Text("统一更换封面…") }
                OutlinedButton(onClick = { b.coverChange = CoverChange.Remove }) { Text("全部移除封面") }
                if (b.coverChange != CoverChange.Keep) OutlinedButton(onClick = { b.coverChange = CoverChange.Keep }) { Text("不修改封面") }
            }
            Text(
                when (b.coverChange) {
                    CoverChange.Keep -> "封面：不修改"
                    CoverChange.Remove -> "封面：将全部移除"
                    is CoverChange.Replace -> "封面：将替换为所选图片"
                },
                style = MaterialTheme.typography.bodySmall,
            )
            Spacer(Modifier.height(16.dp))
            HorizontalDivider()
            Spacer(Modifier.height(12.dp))
            Text("歌词 / LRC", style = MaterialTheme.typography.titleSmall)
            Text("导出：把标签内的歌词保存为同名 .lrc（UTF-8${if (state.settings.lrcBom) " 带 BOM" else ""}），${if (state.settings.batchExportOverwrite) "覆盖" else "跳过"}已有的 LRC。\n写入标签：把同名 .lrc 的内容写入音频标签。",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.height(6.dp))
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                OutlinedButton(onClick = { state.batchExportLrc() }, enabled = !busy) { Text("批量导出 LRC") }
                OutlinedButton(onClick = { state.batchImportLrc() }, enabled = !busy) { Text("同名 LRC 写入标签") }
                if (state.plugins.hasLyricsSources) OutlinedButton(onClick = { state.plugins.batchMatchLyrics(state.selectedSongs) }, enabled = !busy) { Text("插件批量匹配歌词") }
            }
        }
        HorizontalDivider()
        Surface(tonalElevation = 2.dp) {
            Row(Modifier.fillMaxWidth().padding(16.dp, 10.dp), verticalAlignment = Alignment.CenterVertically) {
                val n = b.enabled.count { it.value } + if (b.coverChange != CoverChange.Keep) 1 else 0
                Text(if (n == 0) "未选择要修改的字段" else "将修改 $n 项", style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f))
                OutlinedButton(onClick = { state.select(emptySet()) }) { Text("取消选择") }
                Spacer(Modifier.width(8.dp))
                Button(onClick = { state.applyBatch() }, enabled = n > 0 && !busy) { Text("应用到 $count 首") }
            }
        }
    }
}
