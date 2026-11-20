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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lonx.lyrico.desktop.library.BatchCover
import com.lonx.lyrico.desktop.library.BatchField
import com.lonx.lyrico.desktop.plugin.MatchStatus
import com.lonx.lyrico.desktop.plugin.MatchTarget
import com.lonx.lyrico.desktop.plugin.MatchWriteMode

@Composable
fun BatchPane(state: AppState) {
    val b = state.batch ?: return
    val count = b.songs.size
    Column(Modifier.fillMaxSize()) {
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(16.dp)) {
            Text("已选择 $count 首", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(10.dp))
            BatchMatchCard(state, b)
            Spacer(Modifier.height(18.dp))
            HorizontalDivider()
            Spacer(Modifier.height(12.dp))
            ManualBatchEdit(state, b)
        }
        HorizontalDivider()
        Surface(tonalElevation = 2.dp) {
            Row(Modifier.fillMaxWidth().padding(16.dp, 10.dp), verticalAlignment = Alignment.CenterVertically) {
                val n = b.checkedSet.size
                Column(Modifier.weight(1f)) {
                    Text(if (n == 0) "手动编辑：尚未修改任何字段" else "手动编辑：将修改 $n 项（其余字段保持原样）", style = MaterialTheme.typography.bodySmall)
                    state.busy?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.primary) }
                }
                OutlinedButton(onClick = { state.select(emptySet()) }) { Text("取消选择") }
                Spacer(Modifier.width(8.dp))
                OutlinedButton(onClick = { state.applyBatch() }, enabled = n > 0 && state.busy == null, modifier = Modifier.testTag("batch-apply")) { Text("应用修改到 $count 首") }
            }
        }
    }
    b.confirm?.let { lines ->
        AlertDialog(
            onDismissRequest = { b.confirm = null },
            title = { Text("确认修改 $count 首歌曲？") },
            text = {
                Column {
                    Text("只会修改以下字段：", fontWeight = FontWeight.Medium)
                    for (l in lines) Text("• $l", color = if (l.endsWith("清除") || l.endsWith("移除")) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface)
                    Spacer(Modifier.height(6.dp))
                    Text("其余字段、歌词与封面保持每首歌原来的值。", style = MaterialTheme.typography.bodySmall)
                }
            },
            confirmButton = { TextButton(onClick = { state.applyBatch(confirmed = true) }, modifier = Modifier.testTag("batch-confirm")) { Text("确认应用") } },
            dismissButton = { TextButton(onClick = { b.confirm = null }, modifier = Modifier.testTag("batch-confirm-cancel")) { Text("返回修改") } },
        )
    }
}

/** Primary action: plugins look up each song and write the best match (Android 批量匹配). */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun BatchMatchCard(state: AppState, b: BatchState) {
    val hub = state.plugins
    val s = state.settings
    val targets = s.batchMatchTargets.toSet()
    val run = hub.matchRun
    val running = run != null && !run.finished
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.45f))) {
        Column(Modifier.padding(14.dp)) {
            Text("批量匹配", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Text("用插件为每首歌自动查询歌曲信息、歌词和封面，选最匹配的结果写入。低于匹配阈值的歌曲跳过；结果里没有的字段不会被清空。",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.height(8.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("填写字段", style = MaterialTheme.typography.labelLarge, modifier = Modifier.weight(1f))
                val all = targets.size == MatchTarget.entries.size
                TextButton(onClick = { state.updateSettings { it.copy(batchMatchTargets = if (all) emptyList() else MatchTarget.entries.toList()) } },
                    modifier = Modifier.testTag("match-toggle-all")) { Text(if (all) "全不选" else "全选") }
            }
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                for (t in MatchTarget.entries) {
                    val on = t in targets
                    FilterChip(on, {
                        state.updateSettings { st -> st.copy(batchMatchTargets = MatchTarget.entries.filter { x -> if (x == t) !on else x in st.batchMatchTargets }) }
                    }, label = { Text(t.label) }, modifier = Modifier.testTag("match-target-${t.name}"))
                }
            }
            Spacer(Modifier.height(6.dp))
            Text("写入方式", style = MaterialTheme.typography.labelLarge)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                for (m in MatchWriteMode.entries) {
                    FilterChip(s.batchMatchMode == m, { state.updateSettings { it.copy(batchMatchMode = m) } }, label = { Text(m.label) }, modifier = Modifier.testTag("match-mode-${m.name}"))
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Checkbox(s.batchMatchPreferFileName, { v -> state.updateSettings { it.copy(batchMatchPreferFileName = v) } }, modifier = Modifier.testTag("match-prefer-filename"))
                Text("按文件名匹配（忽略标签里的标题/艺术家）", style = MaterialTheme.typography.bodyMedium)
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("同时处理", style = MaterialTheme.typography.bodyMedium)
                Spacer(Modifier.width(8.dp))
                for (n in 1..4) {
                    FilterChip(s.batchMatchConcurrency == n, { state.updateSettings { it.copy(batchMatchConcurrency = n) } }, label = { Text("$n") },
                        modifier = Modifier.padding(end = 4.dp).testTag("match-conc-$n"))
                }
                Text("首", style = MaterialTheme.typography.bodyMedium)
            }
            SourcePicker(hub.matchPlugins(), hub.matchSelected)
            Text("歌词保存方式：${s.lyricsTarget.label}（设置中修改）", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.height(8.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Button(
                    onClick = { hub.startBatchMatch(b.songs) },
                    enabled = !running && state.busy == null && targets.isNotEmpty() && hub.matchSelected.isNotEmpty(),
                    modifier = Modifier.testTag("match-start"),
                ) { Text("开始批量匹配（${b.songs.size} 首）") }
                Spacer(Modifier.width(8.dp))
                if (running) OutlinedButton(onClick = { hub.stopBatchMatch() }, modifier = Modifier.testTag("match-stop")) { Text("停止") }
                else if (run != null) TextButton(onClick = { hub.matchRun = null }) { Text("关闭结果") }
            }
            if (run != null) {
                Spacer(Modifier.height(8.dp))
                val done = run.results.size
                LinearProgressIndicator(progress = { if (run.songs.isEmpty()) 1f else done.toFloat() / run.songs.size }, modifier = Modifier.fillMaxWidth())
                Text(
                    (if (run.finished) (if (run.cancelled) "已停止 " else "完成 ") else "进行中 ") + "$done / ${run.songs.size}：已匹配 ${run.count(MatchStatus.MATCHED)}，未匹配 ${run.count(MatchStatus.NOT_FOUND)}，跳过 ${run.count(MatchStatus.SKIPPED)}，失败 ${run.count(MatchStatus.FAILED)}" +
                        if (run.inProgress.isNotEmpty()) "\n正在处理：" + run.inProgress.joinToString("、") else "",
                    style = MaterialTheme.typography.bodySmall, modifier = Modifier.testTag("match-progress"),
                )
                val list = run.results.toList()
                LazyColumn(Modifier.fillMaxWidth().heightIn(max = 260.dp).testTag("match-results")) {
                    items(list.size) { i ->
                        val r = list[i]
                        val color = when (r.status) {
                            MatchStatus.MATCHED -> MaterialTheme.colorScheme.primary
                            MatchStatus.FAILED -> MaterialTheme.colorScheme.error
                            else -> MaterialTheme.colorScheme.onSurfaceVariant
                        }
                        Row(Modifier.padding(vertical = 3.dp)) {
                            Text(r.status.label, color = color, fontWeight = FontWeight.Medium, modifier = Modifier.width(52.dp), style = MaterialTheme.typography.bodySmall)
                            Column(Modifier.weight(1f)) {
                                Text(r.song.fileName, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.Medium)
                                Text(r.detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                }
            }
        }
    }
}

/** Secondary: manual batch edit. Only fields the user changed (or explicitly cleared) are written. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ManualBatchEdit(state: AppState, b: BatchState) {
    val count = b.songs.size
    val busy = state.busy != null
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text("手动批量编辑", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
        TextButton(onClick = { b.toggleAll() }, enabled = b.pending.isNotEmpty(), modifier = Modifier.testTag("batch-toggle-all")) { Text(if (b.allChecked) "全不选" else "全选") }
    }
    Text("只写入你修改过的字段：输入新值即自动勾选；〈多个值〉的字段不输入则每首保留各自的值。要清除某个字段，请点它右侧的「清空」。全选只勾选已修改的字段，不会清除任何内容。",
        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    if (!b.tagsLoaded) Text("正在读取标签…", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.primary)
    Spacer(Modifier.height(10.dp))
    for (f in BatchField.entries) {
        if (!f.isText) continue
        val changed = b.hasChange(f)
        val isChecked = b.checked[f] == true && changed
        val clearing = b.clearing[f] == true
        val value = b.values[f].orEmpty()
        val lyrics = f == BatchField.LYRICS
        Row(verticalAlignment = Alignment.CenterVertically) {
            Checkbox(checked = isChecked, onCheckedChange = { b.setChecked(f, it) }, enabled = changed, modifier = Modifier.testTag("batch-check-${f.name}"))
            OutlinedTextField(
                value = value,
                onValueChange = { b.setValue(f, it) },
                label = {
                    val hint = when {
                        clearing -> "  将清除"
                        b.mixed[f] == true && value.isEmpty() -> if (b.tagsLoaded) "  〈多个值〉" else "  读取中…"
                        else -> ""
                    }
                    Text(f.label + hint + if (isChecked) " ✓" else "")
                },
                placeholder = { Text(if (clearing) "将清除" else if (b.mixed[f] == true) (if (b.tagsLoaded) "〈多个值〉保持各自原值" else "读取中…") else "") },
                supportingText = when {
                    clearing -> { { Text("将从所有所选歌曲中清除「${f.label}」", color = MaterialTheme.colorScheme.error) } }
                    isChecked -> { { Text("将写入所有所选歌曲") } }
                    changed -> { { Text("已修改但未勾选，不会写入") } }
                    lyrics -> { { Text("写入标签内的歌词（不生成 .lrc）") } }
                    else -> null
                },
                singleLine = !lyrics,
                textStyle = if (lyrics) TextStyle(fontFamily = FontFamily.Monospace, fontSize = 13.sp) else MaterialTheme.typography.bodyLarge,
                modifier = Modifier.weight(1f).let { if (lyrics) it.heightIn(min = 120.dp, max = 240.dp) else it }.testTag("batch-field-${f.name}"),
            )
            TextButton(onClick = { b.toggleClear(f) }, modifier = Modifier.testTag("batch-clear-${f.name}")) { Text(if (clearing) "撤销清空" else "清空") }
        }
        Spacer(Modifier.height(4.dp))
    }
    Spacer(Modifier.height(4.dp))
    Row(verticalAlignment = Alignment.Top) {
        val coverChanged = b.hasChange(BatchField.COVER)
        val coverChecked = b.checked[BatchField.COVER] == true && coverChanged
        Checkbox(checked = coverChecked, onCheckedChange = { b.setChecked(BatchField.COVER, it) }, enabled = coverChanged, modifier = Modifier.testTag("batch-check-COVER"))
        Column(Modifier.weight(1f).padding(top = 12.dp)) {
            Text("封面", style = MaterialTheme.typography.titleSmall)
            Row(verticalAlignment = Alignment.CenterVertically) {
                val c = b.cover
                val bmp = remember(c) { (c as? BatchCover.Replace)?.let { ImageUtils.decode(it.art.bytes) } }
                Box(Modifier.size(64.dp).clip(RoundedCornerShape(6.dp)).background(MaterialTheme.colorScheme.surfaceVariant), contentAlignment = Alignment.Center) {
                    if (bmp != null) Image(bmp, "新封面", Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                    else Text(if (c == BatchCover.Remove) "移除" else "不变", style = MaterialTheme.typography.bodySmall)
                }
                Spacer(Modifier.width(10.dp))
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    OutlinedButton(onClick = { state.chooseBatchCover() }, modifier = Modifier.testTag("batch-cover-choose")) { Text("选择图片…") }
                    OutlinedButton(onClick = { b.setRemoveCover() }, modifier = Modifier.testTag("batch-cover-remove")) { Text("移除封面") }
                    if (c != BatchCover.Keep) TextButton(onClick = { b.keepCover() }, modifier = Modifier.testTag("batch-cover-keep")) { Text("保持不变") }
                }
            }
            val c = b.cover
            Text(
                when {
                    c is BatchCover.Replace && coverChecked -> "将把所有所选歌曲的封面替换为「${c.name ?: "所选图片"}」"
                    c == BatchCover.Remove && coverChecked -> "将移除所有所选歌曲的封面"
                    c != BatchCover.Keep -> "已选择但未勾选，不会修改封面"
                    else -> "不修改封面（${b.withCover}/$count 首当前有封面）"
                },
                style = MaterialTheme.typography.bodySmall,
                color = if (coverChecked && c == BatchCover.Remove) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
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
    }
}
