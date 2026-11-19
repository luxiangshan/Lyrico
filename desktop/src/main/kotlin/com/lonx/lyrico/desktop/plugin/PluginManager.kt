package com.lonx.lyrico.desktop.plugin

import com.lonx.lyrico.desktop.APP_VERSION
import com.lonx.lyrico.desktop.settings.AppDirs
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import java.util.zip.ZipInputStream

@Serializable
data class PluginState(
    val metadataEnabled: Boolean = true,
    val lyricsEnabled: Boolean = true,
    val coverEnabled: Boolean = true,
    val order: Int = 0,
    val config: Map<String, String> = emptyMap(),
)

@Serializable
data class CatalogRelease(
    val id: String,
    val name: String,
    val versionCode: Int,
    val versionName: String,
    val apiVersion: Int,
    val minHostApiVersion: Int = 1,
    val downloadUrl: String,
    val sha256: String = "",
    val size: Long = 0,
    val changelog: String = "",
) {
    val compatible get() = apiVersion in 1..PluginManifest.PLUGIN_PROTOCOL_VERSION && minHostApiVersion in 1..PluginManifest.PLATFORM_API_VERSION
}

@Serializable
data class PluginCatalog(val schemaVersion: Int = 1, val plugins: List<CatalogRelease> = emptyList())

class InstalledPlugin(val dir: File, val manifest: PluginManifest) {
    val id get() = manifest.id
    val strings: PluginStrings by lazy { PluginStrings.load(dir, manifest) }
    private val snap by lazy { strings.snapshot(PluginStrings.preferredLocales()) }
    val displayName: String get() = snap.text(manifest.name)
    val description: String get() = snap.text(manifest.description)
    fun text(value: String) = snap.text(value)
    val caps get() = manifest.effectiveCapabilities
    val iconFile: File? get() = manifest.icon?.let { File(dir, it) }?.takeIf { it.isFile }

    /** Concatenated scripts: includeDirs (*.js sorted by relative path), then the entry. */
    fun script(): String {
        val sb = StringBuilder()
        val root = dir.canonicalFile
        for (inc in manifest.includeDirs) {
            val d = File(root, inc).canonicalFile
            if (!d.toPath().startsWith(root.toPath()) || !d.isDirectory) continue
            d.walkTopDown().filter { it.isFile && it.extension == "js" }
                .sortedBy { it.relativeTo(d).invariantSeparatorsPath }
                .forEach { f -> sb.append("\n//# sourceURL=").append(f.relativeTo(root).invariantSeparatorsPath).append('\n').append(f.readText()) }
        }
        val entry = File(root, manifest.entry).canonicalFile
        require(entry.toPath().startsWith(root.toPath()) && entry.isFile) { "入口脚本不存在：${manifest.entry}" }
        sb.append("\n//# sourceURL=").append(manifest.entry).append('\n').append(entry.readText())
        return sb.toString()
    }
}

/** Installed plugins live in %APPDATA%\LyricoMod\plugins\<id>\ ; states in plugins-state.json. */
class PluginRepository(private val root: File = AppDirs.plugins) {
    private val stateFile get() = File(root.parentFile, "plugins-state.json")
    private val stateSer = MapSerializer(String.serializer(), PluginState.serializer())
    val http: OkHttpClient = OkHttpClient.Builder().connectTimeout(15, TimeUnit.SECONDS).readTimeout(30, TimeUnit.SECONDS).build()

    fun installed(): List<InstalledPlugin> = root.listFiles { f -> f.isDirectory && !f.name.startsWith(".") }.orEmpty().mapNotNull { d ->
        val m = File(d, "manifest.json")
        if (!m.isFile) null else runCatching { InstalledPlugin(d, pluginJson.decodeFromString(PluginManifest.serializer(), m.readText())) }.getOrNull()
    }.sortedBy { it.id }

    fun states(): Map<String, PluginState> = try {
        if (stateFile.isFile) pluginJson.decodeFromString(stateSer, stateFile.readText()) else emptyMap()
    } catch (_: Exception) { emptyMap() }

    fun saveStates(s: Map<String, PluginState>) { stateFile.writeText(pluginJson.encodeToString(stateSer, s)) }

    fun remove(id: String) {
        installed().firstOrNull { it.id == id }?.dir?.deleteRecursively()
        saveStates(states() - id)
    }

    private val idPattern = Regex("[a-zA-Z][a-zA-Z0-9_]*(\\.[a-zA-Z][a-zA-Z0-9_]*)+")

    private fun validate(m: PluginManifest) {
        require(idPattern.matches(m.id)) { "插件 ID 无效：${m.id}" }
        require(m.apiVersion in 1..PluginManifest.PLUGIN_PROTOCOL_VERSION) { "插件 API 版本 ${m.apiVersion} 不受支持（最高 ${PluginManifest.PLUGIN_PROTOCOL_VERSION}）" }
        require(m.minHostApiVersion in 1..PluginManifest.PLATFORM_API_VERSION) { "插件需要宿主 API ${m.minHostApiVersion}，当前为 ${PluginManifest.PLATFORM_API_VERSION}" }
    }

    /** Unpacks [bytes] (a zip) into a map of path -> content. */
    private fun unzip(bytes: ByteArray): Map<String, ByteArray> {
        val out = LinkedHashMap<String, ByteArray>()
        var total = 0L
        ZipInputStream(bytes.inputStream()).use { z ->
            while (true) {
                val e = z.nextEntry ?: break
                val name = e.name.replace('\\', '/').trimStart('/')
                if (e.isDirectory || name.isEmpty()) continue
                require(name.split('/').none { it == ".." }) { "插件包含不安全路径：$name" }
                val data = z.readBytes()
                total += data.size
                require(total < 64L * 1024 * 1024) { "插件包过大" }
                out[name] = data
            }
        }
        return out
    }

    /** Installs one plugin zip, or a bundle holding several plugin zips/folders. Returns installed manifests. */
    fun installZip(bytes: ByteArray): List<PluginManifest> {
        val files = unzip(bytes)
        val manifests = files.keys.filter { it == "manifest.json" || it.endsWith("/manifest.json") }
        val installed = ArrayList<PluginManifest>()
        if (manifests.isEmpty()) {
            val nested = files.filterKeys { it.endsWith(".zip", true) }
            require(nested.isNotEmpty()) { "压缩包中没有找到 manifest.json" }
            nested.values.forEach { installed += installZip(it) }
            return installed
        }
        for (mPath in manifests) {
            val prefix = mPath.removeSuffix("manifest.json")
            val m = pluginJson.decodeFromString(PluginManifest.serializer(), String(files.getValue(mPath), Charsets.UTF_8))
            validate(m)
            val tmp = File(root, ".install-${m.id}")
            tmp.deleteRecursively(); tmp.mkdirs()
            for ((p, data) in files) if (p.startsWith(prefix)) {
                val f = File(tmp, p.removePrefix(prefix))
                f.parentFile.mkdirs(); f.writeBytes(data)
            }
            val ip = InstalledPlugin(tmp, m)
            ip.script() // entry must exist
            val dest = File(root, m.id)
            dest.deleteRecursively()
            require(tmp.renameTo(dest)) { "无法写入插件目录" }
            installed += m
        }
        return installed
    }

    fun download(url: String): ByteArray {
        val req = Request.Builder().url(url).header("User-Agent", "Lyrico/$APP_VERSION").build()
        http.newCall(req).execute().use { r ->
            if (!r.isSuccessful) throw IOException("下载失败：HTTP ${r.code}")
            return r.body.bytes()
        }
    }

    fun fetchCatalog(url: String): PluginCatalog {
        val text = String(download(url), Charsets.UTF_8)
        val c = pluginJson.decodeFromString(PluginCatalog.serializer(), text)
        val base = url.toHttpUrl()
        return c.copy(plugins = c.plugins.map { it.copy(downloadUrl = base.resolve(it.downloadUrl)?.toString() ?: it.downloadUrl) })
    }

    fun installRelease(r: CatalogRelease): List<PluginManifest> {
        val bytes = download(r.downloadUrl)
        if (r.sha256.isNotBlank()) {
            val got = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
            require(got.equals(r.sha256, true)) { "插件文件校验失败（SHA-256 不匹配）" }
        }
        return installZip(bytes)
    }

    companion object {
        const val OFFICIAL_CATALOG = "https://github.com/Replica0110/Lyrico-Plugins/releases/latest/download/catalog.json"
    }
}

/** Runs one plugin's functions. One JS context per plugin, reused, recreated after a timeout. */
class PluginSource(val plugin: InstalledPlugin, private val repo: PluginRepository, private val configProvider: () -> Map<String, String>) : AutoCloseable {
    private var runtime: GraalJsRuntime? = null

    private fun rt(): GraalJsRuntime = synchronized(this) {
        runtime?.takeIf { !it.isClosed } ?: run {
            val host = HostApi(
                appInfo = HostAppInfo(name = "Lyrico", packageName = "com.lonx.lyrico.mod", versionName = APP_VERSION, versionCode = 170, buildType = "desktop"),
                runtimeInfo = HostRuntimeInfo(engine = "graaljs"),
                okHttpClient = repo.http,
                pluginId = plugin.id,
                cacheRootDir = File(AppDirs.cache, "plugin-cache").apply { mkdirs() },
                pluginStrings = plugin.strings,
            )
            GraalJsRuntime(host).also { r -> r.eval(plugin.script(), "${plugin.id}.js"); runtime = r }
        }
    }

    private fun config(): JsonObject {
        val user = configProvider()
        return buildJsonObject { plugin.manifest.configFields.forEach { f -> put(f.key, user[f.key] ?: f.defaultValue) } }
    }

    private fun invoke(fn: String, request: JsonObject) = synchronized(this) {
        val out = rt().call(fn, request.toString())
        pluginJson.parseToJsonElement(out)
    }

    fun searchSongs(keyword: String, page: Int = 1, pageSize: Int = 20, separator: String = "/"): List<PluginSong> {
        val req = buildJsonObject { put("keyword", keyword); put("page", page); put("pageSize", pageSize); put("separator", separator); put("config", config()) }
        return PluginResultParser.songs(plugin.id, plugin.displayName, invoke("searchSongs", req), separator)
    }

    fun getLyrics(song: PluginSong, options: LyricsFormatOptions, page: Int = 1, pageSize: Int = 20): List<LyricsCandidate> {
        val s = buildJsonObject {
            put("id", song.id); put("title", song.title); put("artist", song.artist); put("album", song.album)
            put("duration", song.durationMs); put("sourceId", plugin.id); put("pluginId", plugin.id)
            put("fields", JsonObject(song.fields.mapValues { JsonPrimitive(it.value) }))
            put("internal", song.internal ?: JsonObject(emptyMap()))
        }
        val req = buildJsonObject { put("song", s); put("page", page); put("pageSize", pageSize); put("config", config()) }
        return PluginResultParser.lyrics(plugin.id, plugin.displayName, invoke("getLyrics", req), song, options)
    }

    fun searchCovers(keyword: String, pageSize: Int = 8): List<CoverCandidate> {
        val req = buildJsonObject { put("keyword", keyword); put("page", 1); put("pageSize", pageSize); put("config", config()) }
        return PluginResultParser.covers(plugin.id, plugin.displayName, invoke("searchCovers", req))
    }

    override fun close() { synchronized(this) { runtime?.close(); runtime = null } }
}
