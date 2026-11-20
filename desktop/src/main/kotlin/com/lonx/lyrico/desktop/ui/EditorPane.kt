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
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
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
import com.lonx.lyrico.desktop.lyrics.LrcFiles
import com.lonx.lyrico.desktop.lyrics.LyricsTarget
import com.lonx.lyrico.desktop.tag.TagField
import java.io.File

@Composable
fun EditorPane(state: AppState) {
    val e = state.editor
    when {
        state.editorLoading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                CircularProgressIndicator()
                Spacer(Modifier.height(8.dp))
                Text("正在读取…（远程文件需要先下载）", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        state.editorError != null -> Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text("无法打开这首歌", style = MaterialTheme.typography.titleMedium)
                Spacer(Modifier.height(8.dp))
                SelectionContainer { Text(state.editorError.orEmpty(), color = MaterialTheme.colorScheme.error) }
                Spacer(Modifier.height(12.dp))
                OutlinedButton(onClick = { state.selectedSongs.singleOrNull()?.let { state.openEditor(it) } }) { Text("重试") }
            }
        }
        e == null -> Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
            Text("选择一首歌曲进行编辑；按住 Ctrl 或 Shift 选择多首可批量编辑、批量导出 LRC。", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        else -> Editor(state, e)
    }
}

@OptIn(ExperimentalLayoutApi::class, ExperimentalMaterial3Api::class)
@Composable
private fun Editor(state: AppState, e: EditorState) {
    val song = e.song
    Column(Modifier.fillMaxSize()) {
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(16.dp)) {
            Row {
                val bmp = remember(e.cover) { e.cover?.let { ImageUtils.decode(it.bytes) } }
                Box(Modifier.size(150.dp).clip(RoundedCornerShape(10.dp)).background(MaterialTheme.colorScheme.surfaceVariant), contentAlignment = Alignment.Center) {
                    if (bmp != null) Image(bmp, "封面", Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                    else Text("无封面", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Spacer(Modifier.width(14.dp))
                Column(Modifier.weight(1f)) {
                    Text(song.displayTitle, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    SelectionContainer {
                        Text(if (song.isRemote) "${state.remote.config(song.remoteId!!)?.displayName ?: "远程"}：${song.path}" else song.path,
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 3, overflow = TextOverflow.Ellipsis)
                    }
                    val a = e.data.tag.audio
                    Text(listOf(a.format, formatDuration(a.durationSeconds), if (a.bitrateKbps > 0) "${a.bitrateKbps} kbps" else "", if (a.sampleRate > 0) "${a.sampleRate} Hz" else "", "%.1f MB".format(song.size / 1048576.0))
                        .filter { it.isNotBlank() }.joinToString(" · "), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Spacer(Modifier.height(8.dp))
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        OutlinedButton(onClick = {
                            Dialogs.openFile("选择封面图片", "图片", Dialogs.imageExtensions)?.let { state.setCover(it) }
                        }) { Text("更换封面") }
                        OutlinedButton(onClick = { state.removeCover() }, enabled = e.cover != null) { Text("移除") }
                        OutlinedButton(onClick = {
                            val c = e.cover ?: return@OutlinedButton
                            Dialogs.saveFile("导出封面", "${song.baseName}.${c.extension}", if (song.isRemote) null else File(song.path).parentFile)?.let {
                                runCatching { it.writeBytes(c.bytes) }.onSuccess { _ -> state.toast("封面已导出：${it.absolutePath}") }
                                    .onFailure { ex -> state.toast("导出失败：${ex.message}") }
                            }
                        }, enabled = e.cover != null) { Text("导出") }
                        if (state.plugins.hasCoverSources) TextButton(onClick = { state.plugins.openCoverSearch(e) }) { Text("搜索封面") }
                    }
                }
            }
            Spacer(Modifier.height(14.dp))
            FieldGrid(e)
            Spacer(Modifier.height(14.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("歌词", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.width(8.dp))
                val hint = when {
                    e.lyricsFromLrc && !e.lyricsChanged -> "来自同名 LRC 文件（仅显示，标签内无歌词）"
                    e.lyrics.isBlank() -> "无歌词"
                    LrcFiles.isSynced(e.lyrics) -> "LRC 逐行时间轴"
                    else -> "纯文本歌词"
                }
                Text(hint, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            FlowRow(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                TextButton(onClick = {
                    val dir = if (song.isRemote) null else File(song.path).parentFile
                    Dialogs.openFile("导入 LRC 文件", "歌词文件 (*.lrc, *.txt)", listOf("lrc", "txt"), dir)?.let { f ->
                        runCatching { LrcFiles.read(f) }.onSuccess { e.lyrics = it; state.toast("已导入「${f.name}」，保存后写入") }
                            .onFailure { ex -> state.toast("读取失败：${ex.message}") }
                    }
                }) { Text("导入 LRC…") }
                TextButton(onClick = { state.loadAdjacentLrcIntoEditor() }) { Text("载入同名 LRC") }
                TextButton(onClick = { state.exportEditorLrc() }, enabled = e.lyrics.isNotBlank()) { Text("导出 LRC…") }
                TextButton(onClick = {
                    val dir = if (song.isRemote) null else File(song.path).parentFile
                    Dialogs.saveFile("LRC 另存为", LrcFiles.lrcNameFor(song.fileName), dir)?.let { f ->
                        runCatching { LrcFiles.write(f, e.lyrics, state.settings.lrcOptions) }
                            .onSuccess { state.toast("已保存：${f.absolutePath}") }.onFailure { ex -> state.toast("保存失败：${ex.message}") }
                    }
                }, enabled = e.lyrics.isNotBlank()) { Text("另存为…") }
                TextButton(onClick = { e.lyrics = "" }, enabled = e.lyrics.isNotEmpty()) { Text("清空") }
                if (state.plugins.hasLyricsSources) TextButton(onClick = { state.plugins.openLyricsSearch(e) }) { Text("搜索歌词") }
            }
            OutlinedTextField(
                value = e.lyrics,
                onValueChange = { e.lyrics = it },
                modifier = Modifier.fillMaxWidth().heightIn(min = 320.dp, max = 640.dp).testTag("editor-lyrics"),
                textStyle = TextStyle(fontFamily = FontFamily.Monospace, fontSize = 13.sp),
                placeholder = { Text("[00:12.34]歌词内容……") },
            )
        }
        HorizontalDivider()
        Surface(tonalElevation = 2.dp) {
            Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("歌词保存到", style = MaterialTheme.typography.bodyMedium)
                    Spacer(Modifier.width(10.dp))
                    SingleChoiceSegmentedButtonRow(Modifier.weight(1f)) {
                        LyricsTarget.entries.forEachIndexed { i, t ->
                            SegmentedButton(
                                selected = e.target == t,
                                onClick = { e.target = t },
                                shape = SegmentedButtonDefaults.itemShape(i, LyricsTarget.entries.size),
                                modifier = Modifier.testTag("target-${t.name}"),
                            ) { Text(t.label, maxLines = 1) }
                        }
                    }
                }
                Spacer(Modifier.height(8.dp))
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        if (e.dirty) "有未保存的更改" else "无更改",
                        style = MaterialTheme.typography.bodySmall,
                        color = if (e.dirty) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.weight(1f),
                    )
                    TextButton(onClick = { state.revertEditor() }, enabled = e.dirty && !e.saving) { Text("还原") }
                    if (state.plugins.hasMetadataSources) TextButton(onClick = { state.plugins.openMetadataSearch(e) }) { Text("搜索信息") }
                    Button(onClick = { state.saveEditor(e.target) }, enabled = !e.saving, modifier = Modifier.testTag("editor-save")) {
                        if (e.saving) { CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp); Spacer(Modifier.width(8.dp)) }
                        Text(if (song.isRemote) "保存并上传" else "保存")
                    }
                }
            }
        }
    }
}

@Composable
private fun FieldGrid(e: EditorState) {
    val rows = listOf(
        listOf(TagField.TITLE),
        listOf(TagField.ARTIST, TagField.ALBUM_ARTIST),
        listOf(TagField.ALBUM),
        listOf(TagField.TRACK, TagField.TRACK_TOTAL, TagField.DISC, TagField.DISC_TOTAL),
        listOf(TagField.YEAR, TagField.GENRE),
        listOf(TagField.COMPOSER, TagField.LYRICIST),
        listOf(TagField.COMMENT),
    )
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        for (r in rows) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for (f in r) {
                    val changed = e.fields[f] != e.original[f]
                    OutlinedTextField(
                        value = e.fields[f].orEmpty(),
                        onValueChange = { e.fields[f] = it },
                        label = { Text(f.label + if (changed) " *" else "") },
                        singleLine = f != TagField.COMMENT,
                        maxLines = if (f == TagField.COMMENT) 4 else 1,
                        modifier = Modifier.weight(1f).testTag("editor-field-${f.name}"),
                    )
                }
            }
        }
    }
}
