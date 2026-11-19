package com.lonx.lyrico.desktop.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
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
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.DialogWindow
import androidx.compose.ui.window.rememberDialogState
import com.lonx.lyrico.desktop.APP_VERSION
import com.lonx.lyrico.desktop.AppTheme
import com.lonx.lyrico.desktop.lyrics.LineEnding
import com.lonx.lyrico.desktop.lyrics.LyricsTarget
import com.lonx.lyrico.desktop.settings.AppDirs

@Composable
private fun Section(title: String) {
    Spacer(Modifier.height(12.dp))
    Text(title, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary, fontWeight = FontWeight.SemiBold)
    Spacer(Modifier.height(4.dp))
}

@Composable
private fun <T> Choice(label: String, options: List<Pair<T, String>>, value: T, onChange: (T) -> Unit) {
    Text(label, style = MaterialTheme.typography.bodyMedium)
    Column {
        for ((v, text) in options) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                RadioButton(selected = v == value, onClick = { onChange(v) })
                Text(text)
            }
        }
    }
}

@Composable
private fun Toggle(label: String, desc: String?, value: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(label)
            if (desc != null) Text(desc, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Switch(checked = value, onCheckedChange = onChange)
    }
}

@Composable
fun SettingsDialog(state: AppState) {
    DialogWindow(onCloseRequest = { state.showSettings = false }, title = "设置", state = rememberDialogState(size = DpSize(620.dp, 760.dp))) {
        AppTheme(state.settings.darkTheme) {
            Surface(Modifier.fillMaxSize()) {
                Column(Modifier.fillMaxSize()) {
                    Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(20.dp)) {
                        val s = state.settings
                        Section("歌词保存")
                        Choice("默认保存位置（编辑页可每次单独选择）", LyricsTarget.entries.map { it to it.label }, s.lyricsTarget) { v -> state.updateSettings { it.copy(lyricsTarget = v) } }
                        Toggle("标签无歌词时显示同名 LRC", "仅显示，不会自动写入标签", s.autoLoadAdjacentLrc) { v -> state.updateSettings { it.copy(autoLoadAdjacentLrc = v) } }

                        Section("LRC 文件")
                        Toggle("UTF-8 带 BOM", "部分老旧播放器/车机需要 BOM 才能正确识别中文", s.lrcBom) { v -> state.updateSettings { it.copy(lrcBom = v) } }
                        Choice("换行符", LineEnding.entries.map { it to it.label }, s.lrcLineEnding) { v -> state.updateSettings { it.copy(lrcLineEnding = v) } }
                        Toggle("批量导出时覆盖已有 LRC", null, s.batchExportOverwrite) { v -> state.updateSettings { it.copy(batchExportOverwrite = v) } }

                        Section("MP3 / WAV / AIFF（ID3）")
                        Choice("ID3 版本", listOf("2.3" to "ID3v2.3（UTF-16，Windows 资源管理器兼容性最好）", "2.4" to "ID3v2.4（UTF-8）"), s.id3Version) { v -> state.updateSettings { it.copy(id3Version = v) } }
                        Choice("歌词帧（USLT）语言代码", listOf("chi" to "chi（中文）", "XXX" to "XXX（未指定）", "eng" to "eng", "jpn" to "jpn"), s.usltLanguage) { v -> state.updateSettings { it.copy(usltLanguage = v) } }
                        Text("歌词按原样（含 LRC 时间标签）写入 MP3 的 USLT 帧；FLAC/OGG/Opus 写入 LYRICS 字段；M4A 写入 ©lyr；APE/WavPack 写入 APEv2 Lyrics。",
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)

                        Section("扫描与外观")
                        Choice("扫描并发数", listOf(2 to "2", 4 to "4（默认）", 8 to "8"), s.scanThreads) { v -> state.updateSettings { it.copy(scanThreads = v) } }
                        Toggle("深色主题", null, s.darkTheme) { v -> state.updateSettings { it.copy(darkTheme = v) } }

                        Section("关于")
                        Text("Lyrico Mod for Windows $APP_VERSION")
                        Text("数据目录：${AppDirs.root.absolutePath}", style = MaterialTheme.typography.bodySmall)
                        Spacer(Modifier.height(6.dp))
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            OutlinedButton(onClick = {
                                runCatching { java.awt.Desktop.getDesktop().open(AppDirs.root) }
                            }) { Text("打开数据目录") }
                            OutlinedButton(onClick = {
                                AppDirs.thumbs.deleteRecursively(); AppDirs.remoteFiles.deleteRecursively()
                                state.toast("已清除封面缩略图和远程文件缓存")
                            }) { Text("清除缓存") }
                        }
                    }
                    HorizontalDivider()
                    Row(Modifier.fillMaxWidth().padding(12.dp)) {
                        Spacer(Modifier.weight(1f))
                        Button(onClick = { state.showSettings = false }) { Text("完成") }
                        Spacer(Modifier.width(8.dp))
                    }
                }
            }
        }
    }
}
