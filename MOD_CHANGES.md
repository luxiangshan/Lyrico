# Lyrico Mod：远程存储版改动说明

分支：`remote-storage`。本 Mod 以独立包名 `com.lonx.lyrico.mod`（应用名 “Lyrico Mod”）安装，可与原版 Lyrico 共存；Debug 构建为 `com.lonx.lyrico.mod.debug`。

## 新功能

### 1. 文件夹管理支持远程位置
- 「文件夹管理」右上角的添加图标改为菜单：**本地文件夹**（原有流程）/ **WebDAV** / **OpenList** / **SMB** / **115网盘**。
- 各类型的连接表单：
  - WebDAV：服务器地址（如 `https://host:port/dav`）、用户名、密码
  - OpenList：服务器地址（如 `http://host:5244`）、用户名（留空为游客）、密码
  - SMB：主机（`192.168.1.10` 或 `nas.local:445`）、共享名、用户名、密码、域（可选）
  - 115网盘：三种登录方式（标签切换 + 折叠的高级项）：
    - **账号密码登录**（默认）：「打开 115 登录页」在应用内 WebView 打开 115 官方网页登录页 `https://115.com/?mode=login`（桌面版 Chrome UA，才会显示账号密码表单；启用 JavaScript、DOM Storage，接受第三方 Cookie）。密码、验证码、短信/二次验证均由 115 页面自己处理。应用每 1.2 秒及每次页面加载完成时读取 WebView `CookieManager` 中 `.115.com` 的 UID / CID / SEID（及 KID，如有）；齐全后用 `Cloud115Storage.testConnection` 验证，成功即关闭网页、进入文件夹选择（与扫码登录后相同）；验证失败则留在页面并显示原因。打开前和关闭网页时（无论成功或取消）都会清除 WebView 中 115 相关域名的 Cookie，登录信息只保存在加密存储里。页面上提示：网页登录会占用 115 的"网页端"登录位，可能让其他浏览器里的 115 下线。顶栏按钮可刷新页面，返回键退出网页登录。
    - **扫码登录**：显示二维码，用 115 App 扫码；状态依次显示 等待扫码 / 已扫码 / 已确认 / 已过期，可「刷新二维码」。新增「保存二维码到相册」（Android 10+ 通过 MediaStore 写入 `图片/LyricoMod`，无需权限；Android 9 改为打开分享）和「分享二维码」（缓存 PNG 经 FileProvider 分享），以便在 115 App 里从相册识别或用另一部手机扫码。切换到其它标签时停止轮询。
    - **手动填写 Cookie（高级，默认折叠）**：多行输入框，接受 `UID=…; CID=…; SEID=…; KID=…`（可带 `Cookie:` 前缀、换行、引号），必须含 UID、CID、SEID，经 testConnection 验证后进入文件夹选择。
    - Cookie 校验统一为 UID、CID、SEID 必需，KID 可选（网页登录的会话可能没有 KID）。
- 密码框默认掩码，可点眼睛图标显示；编辑已有位置时密码留空表示不修改。
- 连接成功后进入远程文件夹浏览器，可勾选一个或多个文件夹；保存时会再次测试连接。
- 远程文件夹出现在文件夹列表中，带类型标签（WebDAV / OpenList / SMB / 115）与歌曲数量；菜单提供 **重新扫描 / 编辑 / 删除**（删除只从曲库移除，不删服务器文件；若是该位置最后一个文件夹，位置及登录信息一并删除）。如有上传失败的修改，还会出现 **重试上传（N）**。

### 2. 扫描
- 递归遍历所选远程文件夹（跳过隐藏目录、`@eaDir`、`#recycle` 等），支持与本地相同的扩展名：mp3、flac、m4a、ogg、opus、wav、aac、wma、ape。
- 歌曲写入原有歌曲表，`uri` 形如 `remote://<位置ID>/<URL 编码路径>`，`source = REMOTE`；文件路径显示为 `remote://<位置ID>/目录/文件名`。
- **部分读取**：读取标签不再下载整首歌。远程文件通过 `StorageManager.openProxyFileDescriptor` 生成只读代理文件描述符（`RemoteProxyFd`，每个描述符一个 HandlerThread），TagLib 读到哪里才用 `RemoteStorage.openRange` 按 256 KB 分块拉取哪里（`RemoteBlockReader`；全局 LRU 64 块≈16 MB；连续读到第 3 块后才预读 1 块；失败重试 1 次）。远程扫描时音频属性用 TagLib 的 Fast 模式。典型 MP3/FLAC 只需读取文件头尾约 0.5–0.8 MB。
  - 若已有有效的完整缓存副本（待上传的修改，或远程大小+修改时间未变），直接读本地副本，不联网。
  - 某个文件用部分读取解析失败时，仅对该文件退回整文件下载后重试。
  - 列表扫描得到的文件信息（大小/修改时间）会缓存 10 分钟，读标签时不必再 stat 一次。
  - OpenList 的下载地址缓存 4 分钟（不必每个分块都调用 `/api/fs/get`）；HTTP 连接池扩为 8 个保活连接。
- 远程文件 6 个并行读取（`LibraryScanRepositoryImpl.REMOTE_CONCURRENCY`），本地文件仍逐个读取；大小+修改时间未变的文件直接跳过。
- **歌曲列表逐步出现**：扫描中每 20 首（`FLUSH_EVERY`）写一次数据库，不再等全部扫完。
- **列表封面**：扫描时顺带把内嵌封面（前封面，否则第一张图）存入磁盘封面缓存（`cacheDir/remote-covers`，64 MB，按 歌曲 uri + 文件大小 + 修改时间 区分；无封面的歌曲也记录，避免反复读取）。列表封面先查该缓存，没有则通过部分读取现场提取并写入缓存；Coil 的缓存键包含“是否已缓存”，封面可用后列表项重新加载。文件被修改/重命名/删除后对应封面缓存失效。
- 手动刷新曲库（全库扫描）也会扫描远程位置；某个远程位置连不上时只记录失败，不会删除它的歌曲。
- 本地扫描逻辑不变（远程歌曲不会被本地扫描删除，远程根文件夹不会被“空文件夹清理”删除）。

### 3. 编辑与写回
- 编辑标签 / 歌词 / 封面、批量处理（匹配元数据、歌词、封面、批量编辑、ReplayGain 等）对远程歌曲同样生效：
  先下载到缓存（大小/修改时间未变则复用），在缓存副本上写入，写完后通过 `RemoteStorage.upload` 上传覆盖。
- 上传失败时：编辑结果保留在缓存中（标记为“待上传”，不会被重新下载覆盖），界面提示失败原因；再次保存或在文件夹管理中「重试上传」即可。
- 重命名 / 删除远程歌曲直接调用远程存储的 rename / delete。
- 远程歌曲可播放（先下载到缓存，再通过 FileProvider 交给播放器）。播放、ReplayGain 仍下载完整文件（需要解码全文件）。
- 打开编辑页读取标签、列表封面使用部分读取；保存时才下载完整文件（已有有效缓存副本则复用）。

### 4. 首次启动
- 曲库为空时「添加文件夹」按钮弹出与文件夹管理相同的选择：本地文件夹 / WebDAV / OpenList / SMB / 115网盘；远程类型进入同一远程位置添加流程，保存后（登记文件夹并开始扫描）返回曲库页，即视为已添加文件夹。

### 5. 安全
- 位置配置（类型、名称、地址、共享名、用户名、域、文件夹）保存在 DataStore。
- 密码、115 Cookie、OpenList Token 等用 Android Keystore 中的 AES-256-GCM 密钥加密后保存（`remote_secrets`），并排除在系统备份之外。

## 已知限制
- 部分读取依赖系统 AppFuse（`openProxyFileDescriptor`），尚未在真机上验证各格式；失败时会自动退回整文件下载。
- 缓存上限 1 GB（LRU 清理，待上传文件不清理），位于应用缓存目录，系统清理缓存后需重新下载。
- 分享、导出等其它直接依赖 content:// 的功能对远程歌曲可能不可用。
- 同一文件若在服务器端与本地同时被修改，以本地待上传版本为准（覆盖服务器端）。
- 115 扫码登录使用 “支付宝小程序” 设备槽（不会挤掉手机 App 的登录）；账号密码（网页）登录使用 115 的“网页端”登录位，会挤掉其他浏览器里的 115 网页登录。
- 115 网页登录页的地址、表单与登录成功后的 Cookie 由 115 决定，若 115 改版需要调整 `Cloud115WebCookies`（登录地址 / UA / 读取的域名）。
- 本次修改未在真机上测试。

## 构建
- GitHub Actions：`.github/workflows/build-mod.yml`，推送到 `remote-storage` 或手动运行（workflow_dispatch）即可，**无需任何仓库 Secrets**。
  - 检出子模块（taglib / quickjs-ng / ffmpeg）、JDK 21、安装 NDK `29.0.14206865`（及 CMake 4.1.2）。
  - 先构建 Release（R8 + 内置 mod 密钥签名）；若失败自动退回构建 Debug。
  - 产物 Artifact 名为 **Lyrico-Mod**（按 ABI 拆分：arm64-v8a / armeabi-v7a）。
- 签名：`lyrico-app/mod-debug.keystore`（别名、密码均为 `lyricomod`），未配置 `LYRICO_KEYSTORE_*` 时 Release 使用它；所有 mod 构建签名一致，可直接覆盖升级。
- 本地：`./gradlew :lyrico-app:assembleRelease`（需 Android SDK 37、NDK 29.0.14206865、CMake 4.1.2、JDK 21，并 `git submodule update --init --recursive`）。

## 主要代码位置
- `remote/RemoteStorage.kt`：统一接口；`remote/webdav`、`remote/smb`、`remote/cloud115`：各协议实现。
- `remote/integration/`：配置仓库、加密凭据、存储工厂/管理、缓存与写回、远程扫描、位置服务、编辑界面 ViewModel、115 扫码桥接、二维码生成、二维码保存/分享（`QrImageExport.kt`）、115 网页登录 Cookie 读取与清除（`Cloud115WebCookies.kt`）；部分读取：`RemoteBlockCache.kt`（分块缓存，纯 JVM，有单元测试）、`RemoteProxyFd.kt`、`RemoteReadAccess.kt`、`RemoteCoverCache.kt`。
- `screens/RemoteLocationScreen.kt`：添加/编辑远程位置与文件夹选择。
- 修改：`AudioFileAccess`、`AudioTagRepositoryImpl`（写后上传）、`SongFileRepositoryImpl`（远程重命名/删除）、`LibraryScanRepositoryImpl`（远程扫描）、`FolderManagerScreen` / `FolderManagerViewModel`、`FolderDao`、`LibraryFolderRepository`、`AudioCoverFetcher`、`ReplayGainScanner`、`PlaybackRepositoryImpl`、`AppModule`、Gradle 与 ProGuard 配置。
