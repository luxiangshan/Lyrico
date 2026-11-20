package com.lonx.lyrico.desktop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Build
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.lonx.lyrico.desktop.remote.label
import java.io.File

@Composable
private fun SectionTitle(text: String) {
    Text(text, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(start = 12.dp, top = 12.dp, bottom = 4.dp))
}

@Composable
private fun NavItem(title: String, subtitle: String?, selected: Boolean, onClick: () -> Unit, trailing: @Composable () -> Unit = {}) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 6.dp, vertical = 1.dp).clip(RoundedCornerShape(8.dp))
            .background(if (selected) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surface)
            .clickable(onClick = onClick).padding(start = 10.dp, top = 6.dp, bottom = 6.dp, end = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis, fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal)
            if (subtitle != null) Text(subtitle, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        trailing()
    }
}

@Composable
fun Sidebar(state: AppState, modifier: Modifier) {
    Column(modifier.background(MaterialTheme.colorScheme.surface)) {
        Text("Lyrico Mod", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, modifier = Modifier.padding(start = 16.dp, top = 16.dp))
        Text("音乐标签与歌词编辑", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 16.dp, bottom = 8.dp))
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
            NavItem("全部歌曲", "${state.songs.size} 首", state.location == null, { state.location = null })

            SectionTitle("本地文件夹")
            for (f in state.settings.folders) {
                val count = state.songs.count { com.lonx.lyrico.desktop.library.SongSorting.belongsTo(it, f) }
                NavItem(File(f).name.ifEmpty { f }, "$count 首 · $f", state.location == f, { state.location = f }) {
                    IconButton(onClick = { state.removeFolder(f) }, modifier = Modifier.size(28.dp)) {
                        Icon(Icons.Default.Close, "移除文件夹", Modifier.size(16.dp))
                    }
                }
            }
            TextButton(onClick = { Dialogs.chooseFolder("添加音乐文件夹")?.let { state.addFolder(it) } }, modifier = Modifier.padding(start = 4.dp)) {
                Icon(Icons.Default.Add, null, Modifier.size(18.dp)); Spacer(Modifier.size(4.dp)); Text("添加文件夹")
            }

            SectionTitle("远程位置")
            for (c in state.remote.configs) {
                val key = "remote:${c.id}"
                val status = state.remote.scanStatus[c.id]
                val count = state.songs.count { it.remoteId == c.id }
                NavItem(c.displayName, status ?: "${c.type.label} · $count 首", state.location == key, { state.location = key }) {
                    IconButton(onClick = { state.remote.scan(c.id) }, modifier = Modifier.size(28.dp)) { Icon(Icons.Default.Refresh, "重新扫描", Modifier.size(16.dp)) }
                    IconButton(onClick = { state.remote.editing = c; state.showRemoteDialog = true }, modifier = Modifier.size(28.dp)) { Icon(Icons.Default.Edit, "编辑", Modifier.size(16.dp)) }
                }
            }
            TextButton(onClick = { state.remote.editing = null; state.showRemoteDialog = true }, modifier = Modifier.padding(start = 4.dp)) {
                Icon(Icons.Default.Add, null, Modifier.size(18.dp)); Spacer(Modifier.size(4.dp)); Text("添加远程位置")
            }
        }
        HorizontalDivider()
        Column(Modifier.padding(8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            state.scanStatus?.let { Text(it, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(4.dp)) }
            OutlinedButton(onClick = { state.rescan() }, modifier = Modifier.fillMaxWidth(), enabled = state.scanStatus == null) {
                Icon(Icons.Default.Refresh, null, Modifier.size(18.dp)); Spacer(Modifier.size(6.dp)); Text("重新扫描本地")
            }
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                TextButton(onClick = { state.showPlugins = true }, modifier = Modifier.weight(1f)) {
                    Icon(Icons.Default.Build, null, Modifier.size(18.dp)); Spacer(Modifier.size(4.dp)); Text("插件")
                }
                TextButton(onClick = { state.showSettings = true }, modifier = Modifier.weight(1f)) {
                    Icon(Icons.Default.Settings, null, Modifier.size(18.dp)); Spacer(Modifier.size(4.dp)); Text("设置")
                }
            }
            Spacer(Modifier.height(2.dp))
        }
    }
}
