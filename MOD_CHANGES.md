# Lyrico Mod：远程存储版改动说明

分支：`remote-storage`。本 Mod 以独立包名 `com.lonx.lyrico.mod`（应用名 “Lyrico Mod”）安装，可与原版 Lyrico 共存；Debug 构建为 `com.lonx.lyrico.mod.debug`。

## 新功能

### 1. 文件夹管理支持远程位置
- 「文件夹管理」右上角的添加图标改为菜单：**本地文件夹**（原有流程）/ **WebDAV** / **OpenList** / **SMB** / **115网盘**。
- 各类型的连接表单：
  - WebDAV：服务器地址（如 `https://host:port/dav`）、用户名、密码
  - OpenList：服务器地址（如 `http://host:5244`）、用户名（留空为游客）、密码
  - SMB：主机（`192.168.1.10` 或 `nas.local:445`）、共享名、用户名、密码、域（可选）
  - 115网盘：显示二维码，用 115 App 扫码；状态依次显示 等待扫码 / 已扫码 / 已确认 / 已过期，可「刷新二维码」
- 密码框默认掩码，可点眼睛图标显示；编辑已有位置时密码留空表示不修改。
- 连接成功后进入远程文件夹浏览器，可勾选一个或多个文件夹；保存时会再次测试连接。
- 远程文件夹出现在文件夹列表中，带类型标签（WebDAV / OpenList / SMB / 115）与歌曲数量；菜单提供 **重新扫描 / 编辑 / 删除**（删除只从曲库移除，不删服务器文件；若是该位置最后一个文件夹，位置及登录信息一并删除）。如有上传失败的修改，还会出现 **重试上传（N）**。

### 2. 扫描
- 递归遍历所选远程文件夹（跳过隐藏目录、`@eaDir`、`#recycle` 等），支持与本地相同的扩展名：mp3、flac、m4a、ogg、opus、wav、aac、wma、ape。
- 歌曲写入原有歌曲表，`uri` 形如 `remote://<位置ID>/<URL 编码路径>`，`source = REMOTE`；文件路径显示为 `remote://<位置ID>/目录/文件名`。
- 读取标签时把文件下载到缓存再走原有 TagLib 路径；并发下载 3 个；大小+修改时间未变的文件直接跳过。
- 手动刷新曲库（全库扫描）也会扫描远程位置；某个远程位置连不上时只记录失败，不会删除它的歌曲。
- 本地扫描逻辑不变（远程歌曲不会被本地扫描删除，远程根文件夹不会被“空文件夹清理”删除）。

### 3. 编辑与写回
- 编辑标签 / 歌词 / 封面、批量处理（匹配元数据、歌词、封面、批量编辑、ReplayGain 等）对远程歌曲同样生效：
  先下载到缓存（大小/修改时间未变则复用），在缓存副本上写入，写完后通过 `RemoteStorage.upload` 上传覆盖。
- 上传失败时：编辑结果保留在缓存中（标记为“待上传”，不会被重新下载覆盖），界面提示失败原因；再次保存或在文件夹管理中「重试上传」即可。
- 重命名 / 删除远程歌曲直接调用远程存储的 rename / delete。
- 远程歌曲可播放（先下载到缓存，再通过 FileProvider 交给播放器）。

### 4. 安全
- 位置配置（类型、名称、地址、共享名、用户名、域、文件夹）保存在 DataStore。
- 密码、115 Cookie、OpenList Token 等用 Android Keystore 中的 AES-256-GCM 密钥加密后保存（`remote_secrets`），并排除在系统备份之外。

## 已知限制
- 列表中的封面只读取已缓存的副本，不会为显示封面而联网下载；打开编辑页或扫描后即可显示。
- 缓存上限 1 GB（LRU 清理，待上传文件不清理），位于应用缓存目录，系统清理缓存后需重新下载。
- 分享、导出等其它直接依赖 content:// 的功能对远程歌曲可能不可用。
- 同一文件若在服务器端与本地同时被修改，以本地待上传版本为准（覆盖服务器端）。
- 115 登录使用 “支付宝小程序” 设备槽（不会挤掉手机 App 的登录）。
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
- `remote/integration/`：配置仓库、加密凭据、存储工厂/管理、缓存与写回、远程扫描、位置服务、编辑界面 ViewModel、115 扫码桥接、二维码生成。
- `screens/RemoteLocationScreen.kt`：添加/编辑远程位置与文件夹选择。
- 修改：`AudioFileAccess`、`AudioTagRepositoryImpl`（写后上传）、`SongFileRepositoryImpl`（远程重命名/删除）、`LibraryScanRepositoryImpl`（远程扫描）、`FolderManagerScreen` / `FolderManagerViewModel`、`FolderDao`、`LibraryFolderRepository`、`AudioCoverFetcher`、`ReplayGainScanner`、`PlaybackRepositoryImpl`、`AppModule`、Gradle 与 ProGuard 配置。
