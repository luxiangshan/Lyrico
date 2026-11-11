package com.lonx.lyrico.remote.smb

/**
 * Pure helpers for converting between the interface's '/'-separated paths (absolute within the share,
 * starting with '/') and smbj share-relative paths ('\\'-separated, no leading separator, "" = share root).
 */
object SmbPaths {
    const val DEFAULT_PORT = 445
    const val TEMP_SUFFIX = ".lyrico-tmp"

    /** Parsed "host[:port]" (also accepts "smb://host[:port][/...]", "\\\\host" and "[ipv6]:port"). */
    data class HostPort(val host: String, val port: Int)

    fun parseHost(baseUrl: String): HostPort {
        var s = baseUrl.trim()
        if (s.startsWith("smb://", ignoreCase = true)) s = s.substring(6)
        s = s.trimStart('\\', '/')
        // Drop anything after the authority (a path accidentally pasted into the host field).
        val cut = s.indexOfFirst { it == '/' || it == '\\' }
        if (cut >= 0) s = s.substring(0, cut)
        require(s.isNotEmpty()) { "SMB host is empty" }

        if (s.startsWith("[")) { // [ipv6] or [ipv6]:port
            val end = s.indexOf(']')
            require(end > 0) { "Invalid SMB host: $baseUrl" }
            val host = s.substring(1, end)
            val rest = s.substring(end + 1)
            val port = if (rest.startsWith(":")) parsePort(rest.substring(1), baseUrl) else DEFAULT_PORT
            return HostPort(host, port)
        }
        val colons = s.count { it == ':' }
        if (colons == 1) {
            val idx = s.indexOf(':')
            val host = s.substring(0, idx)
            require(host.isNotEmpty()) { "SMB host is empty" }
            return HostPort(host, parsePort(s.substring(idx + 1), baseUrl))
        }
        // No port, or a bare IPv6 literal without brackets.
        return HostPort(s, DEFAULT_PORT)
    }

    private fun parsePort(p: String, original: String): Int {
        if (p.isEmpty()) return DEFAULT_PORT
        val port = p.toIntOrNull()
        require(port != null && port in 1..65535) { "Invalid SMB port in \"$original\"" }
        return port
    }

    /** Normalizes an interface path: leading '/', no trailing '/', collapses duplicates, rejects "..". */
    fun normalize(path: String): String {
        val parts = path.replace('\\', '/').split('/').filter { it.isNotEmpty() && it != "." }
        require(parts.none { it == ".." }) { "Path must not contain '..': $path" }
        return "/" + parts.joinToString("/")
    }

    /** "/Music/a.flac" -> "Music\\a.flac"; "/" -> "". */
    fun toSmb(path: String): String = normalize(path).removePrefix("/").replace('/', '\\')

    /** "Music\\a.flac" -> "/Music/a.flac"; "" -> "/". */
    fun fromSmb(smbPath: String): String = normalize(smbPath.replace('\\', '/'))

    /** Child path in interface form. */
    fun child(dirPath: String, name: String): String {
        val dir = normalize(dirPath)
        return if (dir == "/") "/$name" else "$dir/$name"
    }

    /** Parent in interface form ("/" for top-level entries and for root). */
    fun parent(path: String): String {
        val p = normalize(path)
        val idx = p.lastIndexOf('/')
        return if (idx <= 0) "/" else p.substring(0, idx)
    }

    fun name(path: String): String = normalize(path).substringAfterLast('/')

    /** Interface path of the hidden temp file used during upload: "<dir>/.<name>.lyrico-tmp". */
    fun tempPathFor(path: String): String = child(parent(path), ".${name(path)}$TEMP_SUFFIX")

    fun isTempName(name: String): Boolean = name.startsWith(".") && name.endsWith(TEMP_SUFFIX)

    /** Validates a new file name for rename (single path segment, no characters SMB forbids). */
    fun validateName(newName: String) {
        require(newName.isNotBlank()) { "New name is empty" }
        require(newName != "." && newName != "..") { "Invalid name: $newName" }
        val bad = newName.firstOrNull { it in "\\/:*?\"<>|" || it.code < 0x20 }
        require(bad == null) { "Name contains a character not allowed on SMB: '$bad'" }
        require(!newName.endsWith(" ") && !newName.endsWith(".")) { "Name must not end with a space or dot" }
    }
}
