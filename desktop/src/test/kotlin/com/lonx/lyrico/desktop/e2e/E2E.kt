package com.lonx.lyrico.desktop.e2e

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import java.io.File
import java.util.concurrent.Executors

/** Shared helpers for the end-to-end tests (these run in CI on windows-latest as part of `gradlew test`). */
object E2E {
    /** Every format the batch editor must write. */
    val formats = listOf("mp3", "flac", "m4a", "ogg", "opus", "wav", "aiff", "ape", "wv")

    fun sample(ext: String, dest: File): File {
        dest.parentFile?.mkdirs()
        E2E::class.java.getResourceAsStream("/audio/sample.$ext")!!.use { i -> dest.outputStream().use { i.copyTo(it) } }
        return dest
    }

    fun resourceBytes(path: String): ByteArray = E2E::class.java.getResourceAsStream(path)!!.use { it.readBytes() }

    fun resourceFile(path: String, dir: File): File = File(dir, path.substringAfterLast('/')).also { dir.mkdirs(); it.writeBytes(resourceBytes(path)) }

    /** Like the Swing/Main dispatcher: one thread, so AppState updates happen in order. */
    fun uiScope(): CoroutineScope {
        val exec = Executors.newSingleThreadExecutor { r -> Thread(r, "e2e-ui").apply { isDaemon = true } }
        // State is written on this thread (the app writes it on the Swing thread); publish each write to the
        // global snapshot right away, as the desktop event loop does, so a running compose test sees it.
        val publishing = java.util.concurrent.Executor { r -> exec.execute { try { r.run() } finally { androidx.compose.runtime.snapshots.Snapshot.sendApplyNotifications() } } }
        return CoroutineScope(SupervisorJob() + publishing.asCoroutineDispatcher())
    }

    fun waitUntil(what: String, timeoutMs: Long = 30_000, describe: () -> String = { "" }, cond: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (!cond()) {
            if (System.currentTimeMillis() > deadline) {
                val dump = Thread.getAllStackTraces().filterKeys { it.name.startsWith("e2e") || it.name.contains("DefaultDispatcher") || it.name.contains("AWT") }
                    .entries.joinToString("\n") { (t, st) -> "${t.name} ${t.state}\n  " + st.take(25).joinToString("\n  ") }
                System.err.println("TIMEOUT DUMP for $what\n$dump")
                throw AssertionError("timed out waiting for: $what ${describe()}")
            }
            Thread.sleep(25)
        }
    }

    val os: String = "${System.getProperty("os.name")} ${System.getProperty("os.arch")} / Java ${System.getProperty("java.version")}"

    /** Appends a line to build/e2e-report/<name>.txt (printed by CI) and stdout. */
    fun report(name: String, line: String) {
        val dir = File(System.getProperty("lyrico.e2eReport") ?: "build/e2e-report").apply { mkdirs() }
        File(dir, "$name.txt").appendText("$line\n", Charsets.UTF_8)
        println("[$name] $line")
    }
}
