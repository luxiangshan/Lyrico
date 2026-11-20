package com.lonx.lyrico.desktop.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.VerticalScrollbar
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollbarAdapter
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.isCtrlPressed
import androidx.compose.ui.input.pointer.isMetaPressed
import androidx.compose.ui.input.pointer.isShiftPressed
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lonx.lyrico.desktop.library.Song
import com.lonx.lyrico.desktop.library.SortKey

@Composable
fun SongListPane(state: AppState, modifier: Modifier) {
    Column(modifier) {
        Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(
                value = state.query,
                onValueChange = { state.query = it },
                modifier = Modifier.weight(1f),
                singleLine = true,
                placeholder = { Text("搜索标题、艺术家、专辑、文件名") },
                leadingIcon = { Icon(Icons.Default.Search, null) },
                trailingIcon = { if (state.query.isNotEmpty()) IconButton(onClick = { state.query = "" }) { Icon(Icons.Default.Clear, "清除") } },
            )
            SortMenu(state)
        }
        val visible = state.visibleSongs
        Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            val allChecked = visible.isNotEmpty() && visible.all { it.id in state.selection }
            Checkbox(checked = allChecked, onCheckedChange = { if (allChecked) state.select(emptySet()) else state.selectAllVisible() })
            Text(
                if (state.selection.isEmpty()) "${visible.size} 首" else "已选 ${state.selection.size} / ${visible.size} 首",
                style = MaterialTheme.typography.bodyMedium,
            )
            Spacer(Modifier.weight(1f))
            Text("Ctrl/Shift+单击 可多选", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        state.busy?.let {
            Column(Modifier.fillMaxWidth().padding(horizontal = 12.dp)) {
                Text(it, style = MaterialTheme.typography.bodySmall)
                LinearProgressIndicator(Modifier.fillMaxWidth())
            }
        }
        HorizontalDivider(Modifier.padding(top = 4.dp))
        if (visible.isEmpty()) {
            EmptyLibrary(state)
        } else {
            Box(Modifier.fillMaxSize()) {
                val listState = rememberLazyListState()
                LazyColumn(Modifier.fillMaxSize().padding(end = 10.dp), state = listState) {
                    items(visible, key = { it.id }) { song ->
                        SongRow(state, song, song.id in state.selection)
                    }
                }
                VerticalScrollbar(rememberScrollbarAdapter(listState), Modifier.align(Alignment.CenterEnd).fillMaxHeight())
            }
        }
    }
}

@Composable
private fun EmptyLibrary(state: AppState) {
    Column(Modifier.fillMaxSize().padding(32.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
        if (state.songs.isEmpty()) {
            Text("还没有歌曲", style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.size(8.dp))
            Text("添加本地音乐文件夹，或添加 WebDAV / OpenList / SMB / 115 远程位置。", color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.size(16.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedButton(onClick = { Dialogs.chooseFolder("添加音乐文件夹")?.let { state.addFolder(it) } }) { Text("添加文件夹") }
                OutlinedButton(onClick = { state.remote.editing = null; state.showRemoteDialog = true }) { Text("添加远程位置") }
            }
        } else {
            Text("没有符合条件的歌曲", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun SortMenu(state: AppState) {
    var open by remember { mutableStateOf(false) }
    Box {
        TextButton(onClick = { open = true }) { Text("排序：${state.sortKey.label}") }
        DropdownMenu(open, onDismissRequest = { open = false }) {
            for (k in SortKey.entries) {
                DropdownMenuItem(text = { Text(k.label + if (k == state.sortKey) "  ✓" else "") }, onClick = {
                    state.updateSettings { it.copy(sortKey = k.name) }; open = false
                })
            }
        }
    }
    IconButton(onClick = { state.updateSettings { it.copy(sortDescending = !it.sortDescending) } }) {
        Icon(if (state.settings.sortDescending) Icons.Default.KeyboardArrowDown else Icons.Default.KeyboardArrowUp, if (state.settings.sortDescending) "降序" else "升序")
    }
}

@Composable
private fun Badge(text: String, color: Color) {
    Box(Modifier.clip(RoundedCornerShape(4.dp)).background(color.copy(alpha = 0.15f)).padding(horizontal = 5.dp, vertical = 1.dp)) {
        Text(text, color = color, fontSize = 11.sp, fontWeight = FontWeight.Medium)
    }
}

fun formatDuration(sec: Int): String = if (sec <= 0) "" else "%d:%02d".format(sec / 60, sec % 60)

@Composable
fun CoverThumb(state: AppState, song: Song, size: Int) {
    var bmp by remember(song.id, song.size, song.modified, song.hasCover) { mutableStateOf<ImageBitmap?>(Thumbnails.cached(song)) }
    LaunchedEffect(song.id, song.size, song.modified, song.hasCover) {
        if (bmp == null && song.hasCover) {
            bmp = Thumbnails.load(song) { s -> if (s.isRemote) state.remote.cachedFile(s) else java.io.File(s.path) }
        }
    }
    Box(Modifier.size(size.dp).clip(RoundedCornerShape(6.dp)).background(MaterialTheme.colorScheme.surfaceVariant), contentAlignment = Alignment.Center) {
        val b = bmp
        if (b != null) Image(b, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        else Text("♪", color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun SongRow(state: AppState, song: Song, selected: Boolean) {
    var ctrl by remember { mutableStateOf(false) }
    var shift by remember { mutableStateOf(false) }
    Row(
        Modifier.fillMaxWidth()
            .background(if (selected) MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.55f) else Color.Transparent)
            .pointerInput(Unit) {
                awaitPointerEventScope {
                    while (true) {
                        val ev = awaitPointerEvent(PointerEventPass.Initial)
                        if (ev.type == PointerEventType.Press) {
                            ctrl = ev.keyboardModifiers.isCtrlPressed || ev.keyboardModifiers.isMetaPressed
                            shift = ev.keyboardModifiers.isShiftPressed
                        }
                    }
                }
            }
            .clickable { state.onRowClick(song, ctrl, shift) }
            .padding(horizontal = 8.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Checkbox(checked = selected, onCheckedChange = { state.toggleCheck(song) })
        CoverThumb(state, song, 40)
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text(song.displayTitle, maxLines = 1, overflow = TextOverflow.Ellipsis, fontWeight = FontWeight.Medium)
            val sub = listOf(song.artist, song.album).filter { it.isNotBlank() }.joinToString(" · ").ifEmpty { song.fileName }
            Text(sub, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
            if (song.error != null) Icon(Icons.Default.Warning, song.error, tint = MaterialTheme.colorScheme.error, modifier = Modifier.size(16.dp))
            if (song.isRemote) Badge("远程", Color(0xFF7B5CC4))
            if (song.hasTagLyrics) Badge("词", Color(0xFF2E8C4C))
            if (song.hasLrc) Badge("LRC", Color(0xFF2F6AC8))
            Badge(song.extension.uppercase(), MaterialTheme.colorScheme.onSurfaceVariant)
            Text(formatDuration(song.durationSeconds), style = MaterialTheme.typography.bodySmall, modifier = Modifier.width(40.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
