package com.lonx.lyrico.desktop.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.DialogWindow
import androidx.compose.ui.window.rememberDialogState
import com.lonx.lyrico.desktop.AppTheme
import com.lonx.lyrico.desktop.plugin.InstalledPlugin
import com.lonx.lyrico.desktop.plugin.PluginManifest
import com.lonx.lyrico.desktop.plugin.SearchKind
import com.lonx.lyrico.desktop.plugin.SearchSession

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun PluginsDialog(state: AppState) {
    val hub = state.plugins
    var catalogUrl by remember { mutableStateOf(state.settings.pluginCatalogUrl) }
    DialogWindow(onCloseRequest = { state.showPlugins = false; hub.catalog = null }, title = "插件管理", state = rememberDialogState(size = DpSize(760.dp, 820.dp))) {
        AppTheme(state.settings.darkTheme) {
            Surface(Modifier.fillMaxSize()) {
                Column(Modifier.fillMaxSize().padding(16.dp)) {
                    Text("插件提供歌曲信息、歌词和封面搜索，与安卓版 Lyrico 插件通用（JS 插件，GraalJS 运行）。", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Spacer(Modifier.height(8.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                        Button(onClick = { Dialogs.openFile("导入插件 ZIP", "插件包 (*.zip)", listOf("zip"))?.let { hub.installZip(it) } }, enabled = hub.busy == null) { Text("本地导入 ZIP…") }
                        OutlinedTextField(catalogUrl, { catalogUrl = it }, label = { Text("订阅链接（catalog.json）") }, singleLine = true, modifier = Modifier.weight(1f))
                        OutlinedButton(onClick = { state.updateSettings { it.copy(pluginCatalogUrl = catalogUrl.trim()) }; hub.loadCatalog(catalogUrl.trim()) }, enabled = hub.busy == null) { Text("获取列表") }
                    }
                    hub.busy?.let { Column { Spacer(Modifier.height(6.dp)); Text(it); LinearProgressIndicator(Modifier.fillMaxWidth()) } }
                    hub.catalog?.let { cat ->
                        Spacer(Modifier.height(8.dp))
                        Card {
                            Column(Modifier.padding(10.dp).heightIn(max = 260.dp).verticalScroll(rememberScrollState())) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text("在线插件（${cat.size}）", fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                                    TextButton(onClick = { hub.installAll(cat) }, enabled = hub.busy == null) { Text("全部安装/更新") }
                                    TextButton(onClick = { hub.catalog = null }) { Text("收起") }
                                }
                                for (r in cat) {
                                    val installed = hub.plugins.firstOrNull { it.id == r.id }
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        Column(Modifier.weight(1f)) {
                                            Text("${r.name}  ${r.versionName}", fontWeight = FontWeight.Medium)
                                            Text(r.id + (if (!r.compatible) " · 不兼容" else ""), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                        }
                                        val label = when {
                                            installed == null -> "安装"
                                            installed.manifest.versionCode < r.versionCode -> "更新"
                                            else -> "重新安装"
                                        }
                                        TextButton(onClick = { hub.installRelease(r) }, enabled = r.compatible && hub.busy == null) { Text(label) }
                                    }
                                }
                            }
                        }
                    }
                    Spacer(Modifier.height(10.dp))
                    Text("已安装（${hub.plugins.size}）", style = MaterialTheme.typography.titleSmall)
                    if (hub.plugins.isEmpty()) Text("还没有插件。可在上方粘贴订阅链接获取官方插件，或导入 ZIP。", color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(8.dp))
                    LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        items(hub.plugins.sortedBy { hub.state(it.id).order }, key = { it.id }) { p -> PluginRow(state, p) }
                    }
                    HorizontalDivider()
                    Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.weight(1f)) {
                            Checkbox(state.settings.pluginIncludeTranslation, { v -> state.updateSettings { it.copy(pluginIncludeTranslation = v) } })
                            Text("歌词包含翻译")
                            Spacer(Modifier.width(12.dp))
                            Checkbox(state.settings.pluginWordByWord, { v -> state.updateSettings { it.copy(pluginWordByWord = v) } })
                            Text("逐字（增强 LRC）")
                        }
                        Button(onClick = { state.showPlugins = false; hub.catalog = null }) { Text("完成") }
                    }
                }
            }
            hub.configuring?.let { PluginConfigDialog(state, it) }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun PluginRow(state: AppState, p: InstalledPlugin) {
    val hub = state.plugins
    val st = hub.state(p.id)
    var confirmRemove by remember { mutableStateOf(false) }
    Card {
        Row(Modifier.fillMaxWidth().padding(10.dp), verticalAlignment = Alignment.CenterVertically) {
            val icon = remember(p.iconFile) { p.iconFile?.let { runCatching { ImageUtils.decode(it.readBytes()) }.getOrNull() } }
            Box(Modifier.size(40.dp).clip(RoundedCornerShape(8.dp)).background(MaterialTheme.colorScheme.surfaceVariant), contentAlignment = Alignment.Center) {
                if (icon != null) Image(icon, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) else Text("JS", fontSize = 12.sp)
            }
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                Text("${p.displayName}  ${p.manifest.versionName}", fontWeight = FontWeight.SemiBold)
                Text(p.description.lines().firstOrNull().orEmpty(), style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis, color = MaterialTheme.colorScheme.onSurfaceVariant)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    if (PluginManifest.CAP_SEARCH_SONGS in p.caps) FilterChip(st.metadataEnabled, { hub.updateState(p.id) { it.copy(metadataEnabled = !it.metadataEnabled) } }, label = { Text("歌曲信息") })
                    if (PluginManifest.CAP_GET_LYRICS in p.caps) FilterChip(st.lyricsEnabled, { hub.updateState(p.id) { it.copy(lyricsEnabled = !it.lyricsEnabled) } }, label = { Text("歌词") })
                    if (PluginManifest.CAP_SEARCH_COVERS in p.caps) FilterChip(st.coverEnabled, { hub.updateState(p.id) { it.copy(coverEnabled = !it.coverEnabled) } }, label = { Text("封面") })
                }
            }
            Column(horizontalAlignment = Alignment.End) {
                Row {
                    TextButton(onClick = { hub.move(p.id, -1) }) { Text("上移") }
                    TextButton(onClick = { hub.move(p.id, 1) }) { Text("下移") }
                }
                Row {
                    if (p.manifest.configFields.isNotEmpty()) TextButton(onClick = { hub.configuring = p }) { Text("配置") }
                    TextButton(onClick = { confirmRemove = true }) { Text("删除", color = MaterialTheme.colorScheme.error) }
                }
            }
        }
    }
    if (confirmRemove) AlertDialog(
        onDismissRequest = { confirmRemove = false },
        title = { Text("删除插件「${p.displayName}」？") },
        confirmButton = { TextButton(onClick = { confirmRemove = false; hub.remove(p.id) }) { Text("删除") } },
        dismissButton = { TextButton(onClick = { confirmRemove = false }) { Text("取消") } },
    )
}

@Composable
private fun PluginConfigDialog(state: AppState, p: InstalledPlugin) {
    val hub = state.plugins
    val values = remember(p.id) {
        mutableStateMapOf<String, String>().apply { p.manifest.configFields.forEach { f -> put(f.key, hub.state(p.id).config[f.key] ?: f.defaultValue) } }
    }
    AlertDialog(
        onDismissRequest = { hub.configuring = null },
        title = { Text("配置：${p.displayName}") },
        text = {
            Column(Modifier.heightIn(max = 520.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                for (f in p.manifest.configFields) {
                    val title = p.text(f.title)
                    val summary = f.summary?.let { p.text(it) }
                    when (f.type) {
                        "switch" -> Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) { Text(title); summary?.let { Text(it, style = MaterialTheme.typography.bodySmall) } }
                            Switch(values[f.key] == "true", { values[f.key] = it.toString() })
                        }
                        "dropdown" -> {
                            var open by remember { mutableStateOf(false) }
                            Column {
                                Text(title); summary?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
                                Box {
                                    OutlinedButton(onClick = { open = true }) { Text(f.options.firstOrNull { it.value == values[f.key] }?.let { p.text(it.label) } ?: values[f.key].orEmpty()) }
                                    DropdownMenu(open, { open = false }) {
                                        f.options.forEach { o -> DropdownMenuItem(text = { Text(p.text(o.label)) }, onClick = { values[f.key] = o.value; open = false }) }
                                    }
                                }
                            }
                        }
                        "markdown" -> Text(p.text(f.defaultValue.ifBlank { f.summary.orEmpty() }), style = MaterialTheme.typography.bodySmall)
                        else -> OutlinedTextField(
                            values[f.key].orEmpty(), { values[f.key] = it },
                            label = { Text(title + if (f.required) " *" else "") },
                            supportingText = summary?.let { { Text(it) } },
                            singleLine = f.type != "textarea",
                            visualTransformation = if (f.type == "password") PasswordVisualTransformation() else androidx.compose.ui.text.input.VisualTransformation.None,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = { hub.saveConfig(p.id, values.toMap()); hub.configuring = null }) { Text("保存") } },
        dismissButton = { TextButton(onClick = { hub.configuring = null }) { Text("取消") } },
    )
}

/** Lyrics / cover / metadata search window opened from the editor. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun PluginSearchDialog(state: AppState, s: SearchSession) {
    val hub = state.plugins
    DialogWindow(onCloseRequest = { s.job?.cancel(); hub.session = null }, title = "搜索${s.kind.label}", state = rememberDialogState(size = DpSize(820.dp, 760.dp))) {
        AppTheme(state.settings.darkTheme) {
            Surface(Modifier.fillMaxSize()) {
                Column(Modifier.fillMaxSize().padding(16.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedTextField(s.keyword, { s.keyword = it }, label = { Text("关键词") }, singleLine = true, modifier = Modifier.weight(1f))
                        Button(onClick = { hub.run(s) }) { Text("搜索") }
                    }
                    if (s.running > 0) { Spacer(Modifier.height(6.dp)); Text("正在搜索（剩余 ${s.running} 个来源）…", style = MaterialTheme.typography.bodySmall); LinearProgressIndicator(Modifier.fillMaxWidth()) }
                    hub.busy?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
                    for (e in s.errors) Text(e, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
                    Spacer(Modifier.height(8.dp))
                    when (s.kind) {
                        SearchKind.LYRICS -> LyricsResults(state, s, Modifier.weight(1f))
                        SearchKind.COVER -> Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
                            if (s.covers.isEmpty() && s.running == 0) Text("没有结果", color = MaterialTheme.colorScheme.onSurfaceVariant)
                            FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                                for ((c, bmp) in s.covers.toList()) {
                                    Column(Modifier.width(170.dp).clip(RoundedCornerShape(8.dp)).clickable { hub.applyCover(s, c) }.padding(4.dp)) {
                                        Box(Modifier.size(160.dp).clip(RoundedCornerShape(8.dp)).background(MaterialTheme.colorScheme.surfaceVariant), contentAlignment = Alignment.Center) {
                                            if (bmp != null) Image(bmp, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) else CircularProgressIndicator(Modifier.size(24.dp))
                                        }
                                        Text(c.album.ifBlank { c.title }, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.Medium)
                                        Text("${c.artist} · ${c.year} · ${c.sourceName}", maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    }
                                }
                            }
                        }
                        SearchKind.METADATA -> Column(Modifier.weight(1f)) {
                            Row(verticalAlignment = Alignment.CenterVertically) { Checkbox(s.applyCoverWithMetadata, { s.applyCoverWithMetadata = it }); Text("同时使用该结果的封面") }
                            LazyColumn(Modifier.weight(1f)) {
                                items(s.songs.toList()) { song ->
                                    Column(Modifier.fillMaxWidth().clickable { hub.applyMetadata(s, song) }.padding(8.dp)) {
                                        Text(song.title, fontWeight = FontWeight.Medium)
                                        Text(listOf(song.artist, song.album, song.year, formatDuration((song.durationMs / 1000).toInt()), song.sourceName).filter { it.isNotBlank() }.joinToString(" · "),
                                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    }
                                    HorizontalDivider()
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun LyricsResults(state: AppState, s: SearchSession, modifier: Modifier) {
    var selected by remember { mutableStateOf(0) }
    val list = s.lyrics.toList()
    Row(modifier) {
        LazyColumn(Modifier.width(320.dp).fillMaxSize()) {
            items(list.size) { i ->
                val c = list[i]
                Column(Modifier.fillMaxWidth().background(if (i == selected) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surface).clickable { selected = i }.padding(8.dp)) {
                    Text(c.title, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(listOf(c.artist, c.album, c.date).filter { it.isNotBlank() }.joinToString(" · "), style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text("${c.sourceName} · ${c.text.lines().size} 行", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.primary)
                }
                HorizontalDivider()
            }
            if (list.isEmpty() && s.running == 0) item { Text("没有结果", Modifier.padding(8.dp), color = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            val c = list.getOrNull(selected)
            Box(Modifier.weight(1f).fillMaxWidth().clip(RoundedCornerShape(8.dp)).background(MaterialTheme.colorScheme.surfaceVariant).padding(10.dp)) {
                SelectionContainer(Modifier.verticalScroll(rememberScrollState())) {
                    Text(c?.text ?: "", fontFamily = FontFamily.Monospace, fontSize = 13.sp)
                }
            }
            Spacer(Modifier.height(8.dp))
            Row { Spacer(Modifier.weight(1f)); Button(onClick = { c?.let { state.plugins.applyLyrics(s, it) } }, enabled = c != null) { Text("使用这份歌词") } }
        }
    }
}

@Composable
fun BatchMatchConfirm(state: AppState, songs: List<com.lonx.lyrico.desktop.library.Song>) {
    val hub = state.plugins
    AlertDialog(
        onDismissRequest = { hub.confirmBatch = null },
        title = { Text("插件批量匹配歌词（${songs.size} 首）") },
        text = {
            Column {
                Text("按插件顺序搜索，选择标题/艺术家/时长最接近的结果，保存到：${state.settings.lyricsTarget.label}（可在设置中修改默认值）。")
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(state.settings.batchSkipExistingLyrics, { v -> state.updateSettings { it.copy(batchSkipExistingLyrics = v) } })
                    Text("跳过已有歌词的歌曲")
                }
            }
        },
        confirmButton = { TextButton(onClick = { hub.runBatchMatch(songs) }) { Text("开始") } },
        dismissButton = { TextButton(onClick = { hub.confirmBatch = null }) { Text("取消") } },
    )
}
