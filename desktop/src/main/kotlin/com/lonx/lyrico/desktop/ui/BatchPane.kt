package com.lonx.lyrico.desktop.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lonx.lyrico.desktop.library.BatchField

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun BatchPane(state: AppState) {
    val b = state.batch ?: return
    val count = b.songs.size
    val busy = state.busy != null
    Column(Modifier.fillMaxSize()) {
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("批量编辑 $count 首", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                TextButton(onClick = { b.toggleAll() }, modifier = Modifier.testTag("batch-toggle-all")) { Text(if (b.allChecked) "全不选" else "全选") }
            }
            Text("只写入勾选的字段。勾选但留空 = 清除该字段（封面勾选但未选图片 = 移除封面）。〈多个值〉表示所选歌曲的值不同，不勾选则各自保留。",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (!b.tagsLoaded) Text("正在读取标签…", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.primary)
            Spacer(Modifier.height(10.dp))
            for (f in BatchField.entries) {
                if (!f.isText) continue
                val isChecked = b.checked[f] == true
                val value = b.values[f].orEmpty()
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(checked = isChecked, onCheckedChange = { b.checked[f] = it }, modifier = Modifier.testTag("batch-check-${f.name}"))
                    val lyrics = f == BatchField.LYRICS
                    OutlinedTextField(
                        value = value,
                        onValueChange = { b.setValue(f, it) },
                        // A placeholder is only drawn while focused (the label takes its place), so the label says it too.
                        label = {
                            val mixedHint = if (b.mixed[f] == true && value.isEmpty()) (if (b.tagsLoaded) "  〈多个值〉" else "  读取中…") else ""
                            Text(f.label + mixedHint + if (isChecked) " ✓" else "")
                        },
                        placeholder = { if (b.mixed[f] == true) Text(if (b.tagsLoaded) "〈多个值〉" else "读取中…") },
                        supportingText = when {
                            isChecked && value.isBlank() -> { { Text("将清除所有所选歌曲的「${f.label}」", color = MaterialTheme.colorScheme.error) } }
                            lyrics -> { { Text("写入标签内的歌词（不生成 .lrc）") } }
                            else -> null
                        },
                        singleLine = !lyrics,
                        textStyle = if (lyrics) TextStyle(fontFamily = FontFamily.Monospace, fontSize = 13.sp) else MaterialTheme.typography.bodyLarge,
                        modifier = Modifier.weight(1f).let { if (lyrics) it.heightIn(min = 120.dp, max = 240.dp) else it }.testTag("batch-field-${f.name}"),
                    )
                }
                Spacer(Modifier.height(4.dp))
            }
            Spacer(Modifier.height(4.dp))
            Row(verticalAlignment = Alignment.Top) {
                val coverChecked = b.checked[BatchField.COVER] == true
                Checkbox(checked = coverChecked, onCheckedChange = { b.checked[BatchField.COVER] = it }, modifier = Modifier.testTag("batch-check-COVER"))
                Column(Modifier.weight(1f).padding(top = 12.dp)) {
                    Text("封面", style = MaterialTheme.typography.titleSmall)
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        val bmp = remember(b.cover) { b.cover?.let { ImageUtils.decode(it.bytes) } }
                        Box(Modifier.size(64.dp).clip(RoundedCornerShape(6.dp)).background(MaterialTheme.colorScheme.surfaceVariant), contentAlignment = Alignment.Center) {
                            if (bmp != null) Image(bmp, "新封面", Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                            else Text(if (coverChecked) "移除" else "—", style = MaterialTheme.typography.bodySmall)
                        }
                        Spacer(Modifier.width(10.dp))
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            OutlinedButton(onClick = { state.chooseBatchCover() }, modifier = Modifier.testTag("batch-cover-choose")) { Text("选择图片…") }
                            OutlinedButton(onClick = { b.setRemoveCover() }, modifier = Modifier.testTag("batch-cover-remove")) { Text("移除封面") }
                        }
                    }
                    Text(
                        when {
                            !coverChecked -> "不修改封面（${b.withCover}/$count 首当前有封面）"
                            b.cover != null -> "将把所有所选歌曲的封面替换为「${b.coverFileName ?: "所选图片"}」"
                            else -> "将移除所有所选歌曲的封面"
                        },
                        style = MaterialTheme.typography.bodySmall,
                        color = if (coverChecked && b.cover == null) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Text("支持 jpg / png / webp；MP3/FLAC/M4A/OGG/Opus/WAV/AIFF/APE/WavPack 均会写入，远程歌曲会下载、写入后上传。",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            Spacer(Modifier.height(16.dp))
            HorizontalDivider()
            Spacer(Modifier.height(12.dp))
            Text("歌词 / LRC", style = MaterialTheme.typography.titleSmall)
            Text("导出 LRC：把标签内的歌词保存为 .lrc，可选择导出目录。\n同名 LRC 写入标签：把歌曲旁同名 .lrc 的内容写入音频标签。",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.height(6.dp))
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                OutlinedButton(onClick = { state.openLrcExport(b.songs) }, enabled = !busy, modifier = Modifier.testTag("batch-export-lrc")) { Text("批量导出 LRC…") }
                OutlinedButton(onClick = { state.batchImportLrc(b.songs) }, enabled = !busy) { Text("同名 LRC 写入标签") }
                if (state.plugins.hasLyricsSources) OutlinedButton(onClick = { state.plugins.batchMatchLyrics(b.songs) }, enabled = !busy) { Text("插件批量匹配歌词") }
            }
        }
        HorizontalDivider()
        Surface(tonalElevation = 2.dp) {
            Row(Modifier.fillMaxWidth().padding(16.dp, 10.dp), verticalAlignment = Alignment.CenterVertically) {
                val n = b.checkedSet.size
                Column(Modifier.weight(1f)) {
                    Text(if (n == 0) "未勾选要修改的字段" else "将修改 $n 项", style = MaterialTheme.typography.bodySmall)
                    state.busy?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.primary) }
                }
                OutlinedButton(onClick = { state.select(emptySet()) }) { Text("取消选择") }
                Spacer(Modifier.width(8.dp))
                Button(onClick = { state.applyBatch() }, enabled = n > 0 && !busy, modifier = Modifier.testTag("batch-apply")) { Text("应用到 $count 首") }
            }
        }
    }
    b.confirmClear?.let { cleared ->
        AlertDialog(
            onDismissRequest = { b.confirmClear = null },
            title = { Text("确认清除字段？") },
            text = { Text("以下勾选的字段为空，应用后会从 $count 首歌曲中清除：\n" + cleared.joinToString("、") { it.label }) },
            confirmButton = { TextButton(onClick = { state.applyBatch(confirmed = true) }, modifier = Modifier.testTag("batch-confirm-clear")) { Text("确认应用") } },
            dismissButton = { TextButton(onClick = { b.confirmClear = null }) { Text("返回修改") } },
        )
    }
}
