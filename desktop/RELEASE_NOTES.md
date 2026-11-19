# Lyrico Mod for Windows 1.7.0

两种下载（都自带 Java 运行环境，无需另外安装 Java）：

- `LyricoMod-1.7.0-*-windows-x64.msi`：安装版（安装到当前用户，开始菜单和桌面快捷方式）。
- `LyricoMod-1.7.0-*-windows-x64-portable.zip`：便携版，解压后运行 `Lyrico Mod\Lyrico Mod.exe`。

## 功能
- 添加本地文件夹，扫描 MP3 / FLAC / M4A / OGG / Opus / WAV / AIFF / WMA / DSF / APE / WavPack，歌曲列表支持搜索、排序、封面缩略图。
- 编辑标题、艺术家、专辑、专辑艺术家、音轨/碟号、年份、流派、作曲、作词、备注、封面（更换/移除/导出）和歌词。
- 歌词可「写入标签」「保存为 LRC」或「两者都要」（设置中可设默认值）：
  MP3 写入 ID3v2 USLT（原样保留 LRC 时间标签，语言 chi/XXX 可选），FLAC/OGG/Opus 写入 LYRICS，M4A 写入 ©lyr，WAV/AIFF 写入 ID3 块，APE/WV 写入 APEv2 Lyrics。
  LRC 与歌曲同名、同目录，UTF-8（可选 BOM 和 CRLF）。
- 多选批量编辑公共字段/封面，批量导出 LRC，同名 LRC 批量写入标签；标签无歌词时显示同名 LRC（仅显示）。
- 远程位置：WebDAV、OpenList/Alist、SMB、115（扫码登录）——下载编辑后上传覆盖，LRC 上传到歌曲旁边。

数据目录：`%APPDATA%\LyricoMod`。
