package com.lonx.lyrico.desktop.lyrics

import kotlinx.serialization.Serializable
import java.io.File

/** What to do when the .lrc to export already exists. */
@Serializable
enum class LrcConflict(val label: String) {
    OVERWRITE("覆盖已有文件"),
    SKIP("跳过已有文件"),
    NUMBER("重名时加序号");
}

/**
 * One export run. [dir] null = next to each song (song folder, local or remote); otherwise every .lrc goes to [dir]
 * as <basename>.lrc. Names already used in this run count as collisions (songs with the same name in different folders).
 */
class LrcExportPlan(val dir: File?, conflict: LrcConflict) {
    /** "Add a number" only makes sense for a chosen directory; in song folders the .lrc must keep the song's name. */
    val conflict: LrcConflict = if (dir == null && conflict == LrcConflict.NUMBER) LrcConflict.SKIP else conflict
    private val claimed = HashSet<String>()

    enum class Kind { NEW, OVERWRITE, RENAMED }

    class Target(val file: File, val kind: Kind)

    /** Existing file with this name, compared case-insensitively (Windows semantics on every OS). */
    private fun existing(name: String): File? {
        val d = dir ?: return null
        val matches = d.listFiles { f -> f.isFile && f.name.equals(name, true) }.orEmpty()
        return matches.firstOrNull { it.name == name } ?: matches.firstOrNull()
    }

    private fun taken(name: String) = name.lowercase() in claimed || existing(name) != null

    /** Picks the file for [baseName] in [dir], or null to skip. Thread-safe; claims the name for this run. */
    @Synchronized
    fun resolve(baseName: String): Target? {
        val d = requireNotNull(dir) { "resolve() needs an export directory" }
        val name = "$baseName.lrc"
        val collision = taken(name)
        val target = when {
            !collision -> Target(File(d, name), Kind.NEW)
            conflict == LrcConflict.SKIP -> null
            conflict == LrcConflict.OVERWRITE -> Target(existing(name) ?: File(d, name), Kind.OVERWRITE)
            else -> {
                var n = 2
                while (taken("$baseName ($n).lrc")) n++
                Target(File(d, "$baseName ($n).lrc"), Kind.RENAMED)
            }
        }
        if (target != null) claimed += target.file.name.lowercase()
        return target
    }
}
