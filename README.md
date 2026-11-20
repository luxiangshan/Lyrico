# Lyrico Mod

> **这是 [Replica0110/Lyrico](https://github.com/Replica0110/Lyrico) 的非官方修改版（Fork）**，在原版基础上增加远程文件夹，并新增 iOS 版与 Windows 版。原版说明见下方「Lyrico（原版说明）」。

**下载：[最新正式版 Release](https://github.com/luxiangshan/Lyrico/releases/latest)**（Android APK、iOS 未签名 IPA、Windows 便携 ZIP / MSI）

| 平台 | 代码位置 | 说明 |
|---|---|---|
| Android 9+ | `lyrico-app/` | 原版 + 远程文件夹；独立包名 `com.lonx.lyrico.mod`，可与原版共存 |
| iOS / iPadOS 16+ | `ios/` | SwiftUI 原生重写（TagLib），未签名 IPA，用 TrollStore 或全能签安装 |
| Windows 10/11 x64 | `desktop/` | Compose Desktop（jaudiotagger），自带 Java 运行环境，便携 ZIP 或 MSI |

主要新增：

- **远程文件夹**（三端）：WebDAV、OpenList/Alist、SMB、115网盘；按需分块读取标签，编辑后上传覆盖。
- **插件**（三端通用原版 JS 插件）：搜索歌曲信息、歌词、封面，批量匹配（补充 / 覆盖）。
- **Windows**：歌词写入标签（MP3 为 ID3 USLT）、另存 .lrc 或两者都要；手动批量编辑（逐字段勾选）、批量封面、LRC 导出到指定目录。

各平台功能、安装方法和已知限制见 [Release 说明](https://github.com/luxiangshan/Lyrico/releases/latest)、[MOD_CHANGES.md](./MOD_CHANGES.md)（Android）、[desktop/RELEASE_NOTES.md](./desktop/RELEASE_NOTES.md)（Windows）。

> 远程存储未在真实服务器上完整验证，iOS 版未在真机测试；修改标签前请备份音乐文件。本 Mod 的问题请勿反馈到上游仓库。

**构建**：全部由 GitHub Actions 完成，无需仓库 Secrets——`build-mod.yml`（Android APK，仓库内置 Mod 密钥签名）、`build-ios.yml`（macOS 构建未签名 IPA）、`build-windows.yml`（windows-latest 测试并打包 ZIP + MSI）。推送到 `master` 时构建并上传 Artifact；推送 `v*-mod` 标签时三个工作流把安装包上传到同名正式 Release（说明取自 `RELEASE_NOTES.md`）。原版的 `build-release.yml`、`deploy-docs.yml` 需要上游签名与 Pages 配置，在本 Fork 中自动跳过。

**许可与致谢**：基于 [Replica0110/Lyrico](https://github.com/Replica0110/Lyrico)，沿用其 [Apache License 2.0](./LICENSE)；第三方组件见 [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md)。感谢原作者及贡献者。

---

# Lyrico（原版说明）

[![GitHub Release](https://img.shields.io/github/v/release/replica0110/lyrico?style=flat-square)](https://github.com/Replica0110/Lyrico/releases)
![GitHub Downloads (all assets, all releases)](https://img.shields.io/github/downloads/replica0110/lyrico/total?style=flat-square)
[![License](https://img.shields.io/github/license/Replica0110/Lyrico?style=flat-square)](./LICENSE)

Lyrico 是一款面向 Android 的开源本地音乐标签编辑与歌词管理工具。它用于整理本地音乐库、读写音频元数据，并通过插件化搜索源补全歌词、封面和其他歌曲信息。

## 功能特性

- **本地音乐库管理**：扫描本地音乐文件，按歌曲、艺术家、专辑、文件夹等维度浏览与搜索。
- **音频元数据编辑**：读取和修改标题、艺术家、专辑、专辑艺术家、年份、流派、音轨号、歌词、封面、注释和自定义标签等信息。
- **多格式标签读写**：基于 TagLib 处理 MP3、FLAC、OGG/Opus、M4A/AAC、WAV、APE 等常见音频格式。
- **歌词与封面补全**：通过插件搜索歌词、翻译、音译、封面和候选元数据，并写入本地音频文件。
- **歌词格式处理**：支持普通 LRC、增强型逐字歌词、TTML 等歌词内容的展示、匹配、转换与写入。
- **批量整理流程**：支持多选、批量匹配、批量编辑、批量重命名、批量响度分析、批量分享和批量删除。
- **插件化搜索源**：在线搜索能力由插件提供，应用本体负责运行时、配置界面、结果处理和标签写入。
- **双界面风格**：内置 Miuix 与 SaltUI 两套界面，切换后立即生效。

## 插件系统

Lyrico 的在线音乐信息搜索采用插件化架构。搜索源插件以 JavaScript 编写，运行在 Android 端嵌入式 [quickjs-ng](https://github.com/quickjs-ng/quickjs) 运行时中。

插件可以声明并实现以下能力：

- 搜索歌曲信息
- 获取歌词
- 搜索封面
- 声明插件配置项

应用会根据插件 manifest 暴露配置界面、运行插件脚本，并将插件返回的结果转换为应用内部的歌曲、歌词和封面数据。插件文档从这里开始阅读：

- [插件使用](https://replica0110.github.io/Lyrico/plugins/using.html)
- [插件开发概览](https://replica0110.github.io/Lyrico/plugins/overview.html)
- [Manifest 参考](https://replica0110.github.io/Lyrico/plugins/manifest.html)
- [宿主 API](https://replica0110.github.io/Lyrico/plugins/host-api.html)

## 已适配 Lyrico 外部编辑功能的播放器

接入方式见 [外部编辑接入指南](https://replica0110.github.io/Lyrico/guide/external-edit.html)。如需加入下方列表，请提交 PR。

| 播放器名称                                                       | 适配版本                       |
|-------------------------------------------------------------|----------------------------|
| [光锥音乐](https://coneplayer.trantor.ink/#/)                   | 1.1.4+                     |
| [Halcyon](https://github.com/Kifranei/Halcyon)              | 1.1.0+                     |
| [棱镜音乐](https://github.com/Ryderwe/PrismMusic-Release)       | 0.1.3+                     |
| [mica-music](https://github.com/lecoix/mica-music)          | 0.1.9.1+                   |
| [Raws-Music](https://github.com/QFDY-GZC/RawS-Music)        | 0.9.39-beta+               |
| [Salt Player](https://github.com/Moriafly/SaltPlayerSource) | 12.4.0-alpha01-2026091601+ |
| [MD3Music](https://github.com/zzyoxml/md3Music)             | 5.5.0+                     |

## 构建

推荐使用 Android Studio 打开项目，也可以直接通过 Gradle 构建。

基础环境：

- [JDK 21](https://adoptium.net/temurin/releases/?version=21)
- [Android SDK](https://developer.android.com/studio)
- [Android NDK 29](https://developer.android.com/ndk/downloads)
- [CMake 4.1.2](https://cmake.org/download/)
- [Git](https://git-scm.com/downloads/)（Windows 使用 [Git for Windows](https://gitforwindows.org/) 附带的 Bash）
- [GNU Make 4.x](https://community.chocolatey.org/packages/make)

首次构建前初始化源码子模块：

```powershell
git submodule update --init --recursive
```

常用命令：

```powershell
.\gradlew.bat :lyrico-app:assembleDebug
```

仅检查 Kotlin 编译：

```powershell
.\gradlew.bat :lyrico-app:compileDebugKotlin
```

主要模块：

- `lyrico-app`：Android 应用主模块，包含 UI、音乐库、搜索、插件运行时和业务逻辑。
- `lyrico-audiotag`：音频标签读写模块，封装底层音频元数据处理能力。
- `docs`：VitePress 文档站点，覆盖插件使用、插件开发和宿主 API。

## 维护取向

项目开发主要围绕维护者自身的实际使用需求展开，不追求覆盖所有可能的个性化场景。主线功能通常会优先考虑：

- 对多数用户有实际价值
- 交互和概念足够简单
- 长期维护成本可控
- 能通过插件或配置扩展的能力不硬编码进应用本体

高度定制化、使用场景过窄或会明显增加复杂度的功能，可能不会纳入主线，更适合通过插件、配置或 fork 项目实现。

## 参考项目与第三方组件

项目在开发过程中参考或使用了以下优秀项目：

- [LDDC](https://github.com/chenmozhijin/LDDC)：简单易用的精准歌词下载匹配工具
- [any-listen-extension-online-metadata](https://github.com/any-listen/any-listen-extension-online-metadata)：any-listen 音频元数据搜索插件
- [Miuix](https://github.com/compose-miuix-ui/miuix)：Xiaomi HyperOS 风格的 Compose UI 组件库
- [SaltUI](https://github.com/Moriafly/SaltUI)：Compose Multiplatform 平台化 UI 组件库
- [音乐标签](https://www.cnblogs.com/vinlxc/p/11932130.html)：音频标签编辑应用
- [quickjs-ng](https://github.com/quickjs-ng/quickjs)：嵌入式 JavaScript 运行时
- [TagLib](https://github.com/taglib/taglib)：音频元数据读写库
- [libebur128](https://github.com/jiixyj/libebur128)：EBU R128 音频响度标准实现

## 捐赠

如果 Lyrico 对你有帮助，可以通过 [爱发电](https://ifdian.net/a/replica0110) 支持项目维护。

[赞助者列表](https://replica0110.github.io/Sponsors/)

## 许可证

Lyrico 本体代码基于 [Apache License 2.0](./LICENSE) 开源。

项目使用的第三方组件仍遵循各自许可证。Gradle/Android 依赖的许可信息可在应用内“开源许可”页面查看；随源码引入或嵌入构建的组件见 [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md)。
