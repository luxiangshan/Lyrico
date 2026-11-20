package com.lonx.lyrico.desktop

import com.lonx.lyrico.desktop.plugin.LyricsConverter
import com.lonx.lyrico.desktop.plugin.LyricsFormatOptions
import com.lonx.lyrico.desktop.plugin.PluginRepository
import com.lonx.lyrico.desktop.plugin.PluginSong
import com.lonx.lyrico.desktop.plugin.PluginSource
import org.junit.Assume
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class PluginRuntimeTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private fun zip(files: Map<String, String>): ByteArray {
        val bos = ByteArrayOutputStream()
        ZipOutputStream(bos).use { z -> for ((n, c) in files) { z.putNextEntry(ZipEntry(n)); z.write(c.toByteArray()); z.closeEntry() } }
        return bos.toByteArray()
    }

    private fun zipDir(dir: File): ByteArray {
        val bos = ByteArrayOutputStream()
        ZipOutputStream(bos).use { z ->
            dir.walkTopDown().filter { it.isFile }.forEach { f ->
                z.putNextEntry(ZipEntry(f.relativeTo(dir).invariantSeparatorsPath)); z.write(f.readBytes()); z.closeEntry()
            }
        }
        return bos.toByteArray()
    }

    private val manifest = """{"id":"com.example.test","name":"@plugin.name","versionCode":1,"versionName":"1.0","apiVersion":5,"minHostApiVersion":4,
        "entry":"source.js","includeDirs":["lib"],"capabilities":["searchSongs","getLyrics","searchCovers"],
        "configFields":[{"key":"size","title":"@cfg","type":"text","defaultValue":"500"}],
        "i18n":{"defaultLocale":"en","resources":{"en":"locales/en.json","zh-Hans":"locales/zh-Hans.json"}}}"""

    private val source = """
        function searchSongs(req) {
          var x = Platform.xml.findElements("<a><b id='1'>x</b><b id='2'>y</b></a>", "b");
          return [{ id: "1", title: req.keyword, artist: ["A", "B"], album: { name: "专辑" }, duration: 1000,
                    picUrl: "http://x/" + req.config.size, fields: { date: "2003-07-31" },
                    internal: { md5: Platform.crypto.md5("hello"), b64: Platform.base64.encodeText("你好"), n: x.length, t: Platform.i18n.t("hello", "世界"), loc: Platform.i18n.getLocale(), spread: [...new Set([1,1,2])].length, opt: (req.config?.size ?? "none") } }];
        }
        function getLyrics(req) {
          return [{ type: "structured", tags: { ti: req.song.title, ar: "歌手", al: "专辑", date: "2003" },
            original: [[1000, 2000, [[1000, 1500, "你"], [1500, 2000, "好"]]], [2500, 3000, "第二行"]],
            translated: [[1000, 2000, "Hello"], [2500, 3000, "Line two"]] },
            { type: "rawEnhancedLrc", tags: { ti: "t", ar: "a", al: "b", date: "2000" }, rawEnhancedLrc: "[00:01.00]<00:01.00>词<00:01.50>语" }];
        }
        function searchCovers(req) { return [{ title: "t", artist: "a", album: "b", year: "2024", picUrl: "http://img/1.jpg" }]; }
    """

    @Test
    fun installsAndRunsPluginWithHostApi() {
        System.setProperty("lyrico.home", File(tmp.root, "home").absolutePath)
        val repo = PluginRepository(File(tmp.root, "plugins").apply { mkdirs() })
        val installed = repo.installZip(zip(mapOf(
            "manifest.json" to manifest, "source.js" to source, "lib/01_util.js" to "var LIB_LOADED = true;",
            "locales/en.json" to """{"plugin.name":"Test","cfg":"Size","hello":"Hello %1${'$'}s"}""",
            "locales/zh-Hans.json" to """{"plugin.name":"测试插件","cfg":"尺寸","hello":"你好 %1${'$'}s"}""",
        )))
        assertEquals("com.example.test", installed.single().id)
        val p = repo.installed().single()
        assertEquals("测试插件", p.displayName)
        PluginSource(p, repo) { mapOf("size" to "1200") }.use { src ->
            val songs = src.searchSongs("晴天")
            val s = songs.single()
            assertEquals("晴天", s.title)
            assertEquals("A/B", s.artist)
            assertEquals("专辑", s.album)
            assertEquals("http://x/1200", s.picUrl)
            assertEquals("2003", s.year)
            val internal = s.internal!!.toString()
            assertTrue(internal.contains("5d41402abc4b2a76b9719d911017c592"), internal)
            assertTrue(internal.contains("5L2g5aW9"), internal)
            assertTrue(internal.contains("\"n\":"), internal)
            assertTrue(internal.contains("你好 世界"), internal)
            assertTrue(internal.contains("\"spread\":2"), internal)

            val lyrics = src.getLyrics(s, LyricsFormatOptions(includeTranslation = true))
            assertEquals(2, lyrics.size)
            assertEquals("[00:01.00]你好\n[00:01.00]Hello\n[00:02.50]第二行\n[00:02.50]Line two", lyrics[0].text)
            assertEquals("歌手", lyrics[0].artist)
            assertEquals("[00:01.00]词语", lyrics[1].text)
            val wbw = src.getLyrics(s, LyricsFormatOptions(wordByWord = true))
            assertEquals("[00:01.00]<00:01.00>你<00:01.50>好<00:02.00>\n[00:02.50]第二行", wbw[0].text)
            assertEquals("http://img/1.jpg", src.searchCovers("x").single().url)
        }
        repo.remove("com.example.test")
        assertTrue(repo.installed().isEmpty())
    }

    @Test
    fun ttmlAndVerbatimConversion() {
        val ttml = """<tt><body><div><p begin="00:01.500" end="00:03.000"><span begin="1.5s">你</span><span>好</span><span ttm:role="x-translation">hello</span></p>
            <p begin="1:02.25">第二 &amp; 行</p></div></body></tt>"""
        assertEquals("[00:01.50]你好\n[01:02.25]第二 & 行", LyricsConverter.ttmlToLrc(ttml).trim())
        assertEquals("[00:01.00]逐字歌词", LyricsConverter.lineLevel("[00:01.00]逐[00:01.20]字[00:01.40]歌<00:01.60>词"))
    }

    /** Runs the official plugins from /workspace/work/lyrico-plugins-official against the real services (LYRICO_NET_TEST=1). */
    @Test
    fun officialPluginsAgainstNetwork() {
        val dir = System.getenv("LYRICO_PLUGINS_DIR")
        Assume.assumeTrue(System.getenv("LYRICO_NET_TEST") == "1" && dir != null)
        System.setProperty("lyrico.home", File(tmp.root, "home2").absolutePath)
        val repo = PluginRepository(File(tmp.root, "plugins2").apply { mkdirs() })
        val report = StringBuilder()
        for (name in listOf("netease", "qq", "kugou", "lrcshare", "musicbrainz", "apple", "soda")) {
            val d = File(dir, name)
            if (!File(d, "manifest.json").isFile) continue
            try {
                val m = repo.installZip(zipDir(d)).single()
                val p = repo.installed().first { it.id == m.id }
                PluginSource(p, repo) { emptyMap() }.use { src ->
                    val line = StringBuilder("$name(${p.displayName}): ")
                    var songs: List<PluginSong> = emptyList()
                    if ("searchSongs" in p.caps) {
                        songs = src.searchSongs("晴天 周杰伦", pageSize = 5)
                        line.append("songs=${songs.size} first=${songs.firstOrNull()?.let { "${it.title}/${it.artist}/${it.album}" }} ")
                    }
                    if ("getLyrics" in p.caps) {
                        val song = songs.firstOrNull() ?: PluginSong(p.id, p.displayName, "", "晴天", "周杰伦", "叶惠美", 269000, "", "", "", emptyMap(), null)
                        val ly = src.getLyrics(song, LyricsFormatOptions())
                        line.append("lyrics=${ly.size} sample=${ly.firstOrNull()?.text?.lines()?.drop(3)?.firstOrNull()} ")
                    }
                    if ("searchCovers" in p.caps) {
                        val c = src.searchCovers("晴天 周杰伦")
                        line.append("covers=${c.size} ")
                    }
                    report.appendLine(line)
                }
            } catch (e: Throwable) {
                report.appendLine("$name: ERROR ${e.javaClass.simpleName}: ${e.message?.take(300)}")
            }
        }
        File(System.getenv("LYRICO_NET_REPORT") ?: File(tmp.root, "r.txt").path).writeText(report.toString())
        println(report)
    }
}
