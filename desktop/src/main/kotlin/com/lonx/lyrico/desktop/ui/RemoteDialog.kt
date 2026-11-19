package com.lonx.lyrico.desktop.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
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
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.toComposeImageBitmap
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.DialogWindow
import androidx.compose.ui.window.rememberDialogState
import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter
import com.lonx.lyrico.desktop.AppTheme
import com.lonx.lyrico.desktop.remote.RemoteErrors
import com.lonx.lyrico.desktop.remote.label
import com.lonx.lyrico.remote.RemoteConfig
import com.lonx.lyrico.remote.RemoteEntry
import com.lonx.lyrico.remote.RemoteType
import com.lonx.lyrico.remote.cloud115.Cloud115QrLogin
import com.lonx.lyrico.remote.smb.SmbStorage
import com.lonx.lyrico.remote.smb.listShares
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.awt.image.BufferedImage

fun qrImage(content: String, size: Int = 240): ImageBitmap {
    val m = QRCodeWriter().encode(content, BarcodeFormat.QR_CODE, size, size)
    val img = BufferedImage(m.width, m.height, BufferedImage.TYPE_INT_RGB)
    for (x in 0 until m.width) for (y in 0 until m.height) img.setRGB(x, y, if (m.get(x, y)) 0x000000 else 0xFFFFFF)
    return img.toComposeImageBitmap()
}

@Composable
fun RemoteDialog(state: AppState) {
    val hub = state.remote
    val original = hub.editing
    var type by remember { mutableStateOf(original?.type ?: RemoteType.WEBDAV) }
    var name by remember { mutableStateOf(original?.displayName ?: "") }
    var url by remember { mutableStateOf(original?.baseUrl ?: "") }
    var share by remember { mutableStateOf(original?.share ?: "") }
    var user by remember { mutableStateOf(original?.username ?: "") }
    var secret by remember { mutableStateOf(original?.secret ?: "") }
    var domain by remember { mutableStateOf(original?.domain ?: "") }
    val folders = remember { mutableStateListOf<String>().apply { addAll(original?.folders ?: listOf("/")) } }
    var status by remember { mutableStateOf<String?>(null) }
    var working by remember { mutableStateOf(false) }
    var browsing by remember { mutableStateOf(false) }
    var showQr by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val id = remember { original?.id ?: hub.newId() }

    fun build() = RemoteConfig(
        id = id, type = type,
        displayName = name.ifBlank { type.label },
        baseUrl = url.trim(), share = share.trim(), username = user.trim(), secret = if (type == RemoteType.CLOUD115) secret.trim() else secret,
        domain = domain.trim(), folders = folders.toList().ifEmpty { listOf("/") },
    )

    fun close() { state.showRemoteDialog = false; hub.editing = null }

    DialogWindow(onCloseRequest = { close() }, title = if (original == null) "添加远程位置" else "编辑远程位置", state = rememberDialogState(size = DpSize(640.dp, 780.dp))) {
        AppTheme(state.settings.darkTheme) {
            Surface(Modifier.fillMaxSize()) {
                Column(Modifier.fillMaxSize()) {
                    Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text("类型", style = MaterialTheme.typography.titleSmall)
                        Row {
                            for (t in RemoteType.entries) {
                                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.clickable(enabled = original == null) { type = t }) {
                                    RadioButton(selected = type == t, onClick = { type = t }, enabled = original == null)
                                    Text(t.label)
                                    Spacer(Modifier.width(8.dp))
                                }
                            }
                        }
                        OutlinedTextField(name, { name = it }, label = { Text("显示名称") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                        when (type) {
                            RemoteType.WEBDAV -> {
                                OutlinedTextField(url, { url = it }, label = { Text("WebDAV 地址") }, placeholder = { Text("https://example.com:5244/dav") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                                UserPass(user, { user = it }, secret, { secret = it })
                            }
                            RemoteType.OPENLIST -> {
                                OutlinedTextField(url, { url = it }, label = { Text("OpenList / Alist 地址") }, placeholder = { Text("http://192.168.1.2:5244") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                                UserPass(user, { user = it }, secret, { secret = it }, "用户名（留空为游客）")
                                Text("提示：若保存时提示 HTTP 405，说明该挂载存储不支持上传，请换一个可写的存储。", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            RemoteType.SMB -> {
                                OutlinedTextField(url, { url = it }, label = { Text("主机（host 或 host:port）") }, placeholder = { Text("192.168.1.10") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    OutlinedTextField(share, { share = it }, label = { Text("共享名") }, singleLine = true, modifier = Modifier.weight(1f))
                                    Spacer(Modifier.width(8.dp))
                                    OutlinedButton(enabled = !working && url.isNotBlank(), onClick = {
                                        working = true; status = "正在获取共享列表…"
                                        scope.launch {
                                            status = try {
                                                val shares = withContext(Dispatchers.IO) { SmbStorage.listShares(url.trim(), user.trim(), secret, domain.trim()) }
                                                if (shares.size == 1) share = shares.first().name
                                                "可用共享：" + shares.joinToString("、") { it.name }.ifEmpty { "（无）" }
                                            } catch (e: Exception) { "获取共享失败：${RemoteErrors.friendly(e)}" }
                                            working = false
                                        }
                                    }) { Text("列出共享") }
                                }
                                UserPass(user, { user = it }, secret, { secret = it })
                                OutlinedTextField(domain, { domain = it }, label = { Text("域（可选）") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                            }
                            RemoteType.CLOUD115 -> {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Button(onClick = { showQr = true }) { Text("扫码登录 115") }
                                    Spacer(Modifier.width(8.dp))
                                    Text(if (secret.isNotBlank()) "已获取 Cookie" else "用 115 App 扫码，或手动粘贴 Cookie", style = MaterialTheme.typography.bodySmall)
                                }
                                OutlinedTextField(secret, { secret = it }, label = { Text("Cookie（UID=…; CID=…; SEID=…; KID=…）") }, modifier = Modifier.fillMaxWidth().heightIn(min = 80.dp), maxLines = 4)
                            }
                        }
                        HorizontalDivider(Modifier.padding(vertical = 6.dp))
                        Text("要扫描的文件夹", style = MaterialTheme.typography.titleSmall)
                        for (f in folders.toList()) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(f, modifier = Modifier.weight(1f))
                                TextButton(onClick = { folders.remove(f) }) { Text("移除") }
                            }
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            OutlinedButton(onClick = { browsing = true }, enabled = !working) { Text("浏览并添加文件夹…") }
                            OutlinedButton(enabled = !working, onClick = {
                                working = true; status = "正在测试连接…"
                                scope.launch {
                                    status = try { hub.test(build()); "连接成功 ✓" } catch (e: Exception) { "连接失败：${RemoteErrors.friendly(e)}" }
                                    working = false
                                }
                            }) { Text("测试连接") }
                            if (working) CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.dp)
                        }
                        status?.let { SelectionContainer { Text(it, color = if (it.contains("失败")) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface) } }
                        Text("保存后会列出这些文件夹中的音频文件并读取标签（只下载文件头部）。编辑时会下载完整文件，保存后上传覆盖；导出 LRC 会上传到歌曲旁边。",
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    HorizontalDivider()
                    Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        if (original != null) TextButton(onClick = { confirmDelete = true }) { Text("删除此位置", color = MaterialTheme.colorScheme.error) }
                        Spacer(Modifier.weight(1f))
                        TextButton(onClick = { close() }) { Text("取消") }
                        Spacer(Modifier.width(8.dp))
                        Button(onClick = { hub.save(build()); close() }, enabled = !working) { Text("保存并扫描") }
                    }
                }
            }
            if (browsing) FolderBrowser(state, build(), onPick = { if (it !in folders) { folders.remove("/"); folders.add(it) }; browsing = false }, onDismiss = { browsing = false })
            if (showQr) QrLoginDialog(onCookie = { secret = it; showQr = false; status = "115 登录成功 ✓" }, onDismiss = { showQr = false })
            if (confirmDelete) AlertDialog(
                onDismissRequest = { confirmDelete = false },
                title = { Text("删除远程位置？") },
                text = { Text("只会从 Lyrico 中移除「${original?.displayName}」及其缓存，不会删除服务器上的文件。") },
                confirmButton = { TextButton(onClick = { original?.let { hub.remove(it.id) }; confirmDelete = false; close() }) { Text("删除") } },
                dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("取消") } },
            )
        }
    }
}

@Composable
private fun UserPass(user: String, onUser: (String) -> Unit, pass: String, onPass: (String) -> Unit, userLabel: String = "用户名") {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedTextField(user, onUser, label = { Text(userLabel) }, singleLine = true, modifier = Modifier.weight(1f))
        OutlinedTextField(pass, onPass, label = { Text("密码") }, singleLine = true, visualTransformation = PasswordVisualTransformation(), modifier = Modifier.weight(1f))
    }
}

@Composable
private fun FolderBrowser(state: AppState, config: RemoteConfig, onPick: (String) -> Unit, onDismiss: () -> Unit) {
    var path by remember { mutableStateOf("/") }
    var entries by remember { mutableStateOf<List<RemoteEntry>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    fun load(p: String) {
        loading = true; error = null
        scope.launch {
            try { entries = state.remote.listDirs(config, p); path = p } catch (e: Exception) { error = RemoteErrors.friendly(e) }
            loading = false
        }
    }
    remember { load("/"); 0 }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("选择文件夹") },
        text = {
            Column(Modifier.heightIn(min = 200.dp, max = 420.dp)) {
                Text("当前：$path", fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(6.dp))
                if (loading) CircularProgressIndicator()
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    if (path != "/") Text("⬆ 上一级", Modifier.fillMaxWidth().clickable { load(path.substringBeforeLast('/', "").ifEmpty { "/" }) }.padding(8.dp))
                    for (e in entries) Text("📁 ${e.name}", Modifier.fillMaxWidth().clickable { load(e.path) }.padding(8.dp))
                    if (!loading && entries.isEmpty() && error == null) Text("（没有子文件夹）", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        },
        confirmButton = { TextButton(onClick = { onPick(path) }, enabled = !loading && error == null) { Text("选择此文件夹") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
    )
}

@Composable
private fun QrLoginDialog(onCookie: (String) -> Unit, onDismiss: () -> Unit) {
    var qr by remember { mutableStateOf<ImageBitmap?>(null) }
    var status by remember { mutableStateOf("正在获取二维码…") }
    val scope = rememberCoroutineScope()
    var job by remember { mutableStateOf<Job?>(null) }
    fun start() {
        job?.cancel()
        job = scope.launch {
            try {
                val login = Cloud115QrLogin()
                val session = withContext(Dispatchers.IO) { login.start() }
                qr = qrImage(session.qrContent)
                status = "请用 115 App 扫码并在手机上确认"
                while (isActive) {
                    when (withContext(Dispatchers.IO) { login.poll(session) }) {
                        Cloud115QrLogin.Status.WAITING -> Unit
                        Cloud115QrLogin.Status.SCANNED -> status = "已扫码，请在手机上确认登录"
                        Cloud115QrLogin.Status.CONFIRMED -> {
                            status = "正在登录…"
                            val cookie = withContext(Dispatchers.IO) { login.login(session) }
                            onCookie(cookie); return@launch
                        }
                        Cloud115QrLogin.Status.EXPIRED -> { status = "二维码已过期，请刷新"; return@launch }
                        Cloud115QrLogin.Status.CANCELLED -> { status = "已取消登录"; return@launch }
                    }
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                status = "登录失败：${RemoteErrors.friendly(e)}"
            }
        }
    }
    DisposableEffect(Unit) { start(); onDispose { job?.cancel() } }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("115 扫码登录") },
        text = {
            Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
                qr?.let { Image(it, "二维码", Modifier.size(240.dp)) } ?: CircularProgressIndicator()
                Spacer(Modifier.height(8.dp))
                Text(status)
                Text("登录占用「115生活 支付宝小程序」设备槽位，不会挤掉手机 App。", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        },
        confirmButton = { TextButton(onClick = { start() }) { Text("刷新二维码") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("关闭") } },
    )
}
