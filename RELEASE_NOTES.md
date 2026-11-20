# Lyrico Mod 1.7.0（Android / iOS / Windows）

Lyrico Mod 是 [Replica0110/Lyrico](https://github.com/Replica0110/Lyrico) 的非官方修改版（基于上游 1.7.0），主要增加**远程文件夹**（WebDAV / OpenList / SMB / 115网盘），并新增 iOS 版和 Windows 版。三个平台的安装包都由 `master` 上的同一次提交通过 GitHub Actions 构建。

> 本版没有在真实的 WebDAV / OpenList / SMB / 115 服务器上做过完整验证，iOS 版也没有在真机上测试。修改标签前请先备份音乐文件。

## 下载

| 平台 | 文件 | 说明 |
|---|---|---|
| Android 9+（64 位） | `LyricoMod-1.7.0-*-arm64-v8a.apk` | 绝大多数手机选这个 |
| Android（32 位） | `LyricoMod-1.7.0-*-armeabi-v7a.apk` | 老旧 32 位设备 |
| iPhone / iPad（iOS 16+） | `LyricoMod-1.7.0-*-ios-unsigned.ipa` | 未签名，需 TrollStore 或自签工具 |
| Windows 10/11 x64 | `LyricoMod-1.7.0-*-windows-x64-portable.zip` | 便携版，解压即用 |
| Windows 10/11 x64 | `LyricoMod-1.7.0-*-windows-x64.msi` | 安装版 |

## 安装

- **Android**：安装 APK 即可。包名 `com.lonx.lyrico.mod`、应用名「Lyrico Mod」，与原版 Lyrico 互不影响、可同时安装。用仓库内固定的 Mod 密钥签名，之前从本仓库预发布装过的 Mod 可以直接覆盖升级（不能覆盖原版）。
- **iOS / iPadOS**：IPA 未签名。用 **TrollStore** 直接安装；或用 **全能签** 等工具用自己的证书签名后安装。
- **Windows**：
  - 便携版：解压 ZIP，运行 `Lyrico Mod\Lyrico Mod.exe`；
  - 安装版：运行 MSI（安装到当前用户，创建开始菜单和桌面快捷方式）。
  - 两种都自带 Java 运行环境，**无需安装 Java**。安装包未做代码签名，SmartScreen 提示时点「更多信息 → 仍要运行」。数据目录 `%APPDATA%\LyricoMod`。

## Android

在原版全部功能基础上：

- **远程文件夹**：「文件夹管理」和首次启动的「添加文件夹」可选 本地 / WebDAV / OpenList / SMB / 115网盘；连接后浏览并勾选一个或多个文件夹，远程文件夹带类型标签和歌曲数，可重新扫描 / 编辑 / 删除（只从曲库移除，不删服务器文件）。
- **115 登录**：账号密码（应用内打开 115 官方网页登录）、扫码登录（可保存/分享二维码）、手动填写 Cookie。
- **快速扫描**：读取标签只按需分块读取文件（256 KB 分块缓存，常见 MP3/FLAC 约读 0.5–0.8 MB），6 路并行；扫描中每 20 首写入一次，列表逐步出现；扫描时缓存列表封面。
- **编辑写回**：编辑标签、歌词、封面及批量处理对远程歌曲同样可用：下载到缓存、写入、上传覆盖；上传失败保留修改，可「重试上传」。远程歌曲可重命名、删除、播放。
- 密码、Cookie、Token 用 Android Keystore（AES-256-GCM）加密保存，不进入系统备份。

## iOS / iPadOS（新）

- SwiftUI 重写的原生应用，标签读写使用与安卓相同的 TagLib。
- 音乐库、标签编辑（信息 / 歌词 / 封面）、批量操作、文件夹管理、设置；通过系统文件选择器导入文件。
- **插件**：与安卓相同的 JS 插件（JavaScriptCore 运行），插件管理（ZIP / 链接 / 订阅安装、启用、排序、配置）；编辑页搜索歌曲信息、歌词、封面。
- **批量匹配**：移植安卓匹配算法和阈值，补充 / 覆盖、按文件名匹配、并发 1–4。
- **远程文件夹**：WebDAV / OpenList / SMB / 115（扫码、网页、Cookie 登录），文件夹管理 › + › 远程位置；分块读取标签。
- 尚未移植：ReplayGain、批量任务记录、艺术家分隔符与字符映射、歌词清理规则、编辑字段设置、应用日志；不提供安卓的两套界面风格。

## Windows（新）

Compose Desktop 桌面版，标签读写用 jaudiotagger（Opus、APE/WavPack 自写），支持 MP3 / FLAC / M4A / OGG / Opus / WAV / AIFF / WMA / DSF / APE / WavPack。

- **歌词保存方式**：写入标签 / 保存为 .lrc / 两者都要（可设默认）。MP3 写入 ID3v2 USLT（默认 v2.3，已有 v2.4 的保持 v2.4），FLAC/OGG/Opus 写 LYRICS，M4A 写 ©lyr，APE/WV 写 APEv2。LRC 默认与歌曲同名同目录，UTF-8（可选 BOM、CRLF）。
- **批量匹配**（多选后的首要操作）：用插件自动查询歌曲信息、歌词、封面并写入；算法和阈值与安卓相同；可选字段、**补充（只填空白）/ 覆盖**、按文件名匹配、并发 1–4、按次选择插件；显示每首结果；插件结果没有的字段不会被清空。
- **手动批量编辑**：每个字段单独「应用」勾选，只写入真正修改的字段，清除需点该字段的「清空」，应用前确认框逐项列出改动。
- **批量封面**：批量更换 / 移除封面（jpg / png / webp），含远程歌曲。
- **LRC 导出**：可选导出目录（默认歌曲同目录），覆盖 / 跳过 / 重名加序号，记住上次目录。
- **插件**：与安卓通用的 JS 插件（GraalJS 运行），导入 ZIP、订阅 catalog.json 安装 / 更新、配置、排序；可单独启用每个插件，搜索和批量匹配可按次勾选插件。
- **远程文件夹**：WebDAV、OpenList/Alist、SMB、115（扫码登录）；下载编辑后上传覆盖，LRC 上传到歌曲旁边。
- 密码等凭据用 Windows DPAPI 加密保存。
- 尚未移植：ReplayGain、重命名、批量任务记录、歌词清理规则、115 账号密码登录。

## 已知限制 / 未验证

- 远程文件夹在三端都只做了单元测试和模拟服务器测试（安卓 SMB 另测过本地 Samba），**未在真实 WebDAV / OpenList / 115 服务器上完整验证**。
- iOS 版**未在真机上测试**；115 网页登录、文件选择、TrollStore / 全能签安装后的钥匙串行为需要真机确认。
- Windows 版 CI 在 windows-latest 上跑通单元、端到端和无头界面测试并对安装包自检，但系统文件选择框、MSI 安装和真实远程服务器未经人工验证。
- 安卓：分享、导出等依赖 content:// 的功能对远程歌曲可能不可用；服务器端与本地同时修改同一文件时以本地待上传版本为准。
- 115 网页登录占用 115 的“网页端”登录位，可能让其他浏览器里的 115 网页下线；扫码登录不受影响。

## 致谢与许可

基于 [Replica0110/Lyrico](https://github.com/Replica0110/Lyrico)（Apache License 2.0）。本 Mod 不是官方版本，问题请勿反馈到上游仓库。
