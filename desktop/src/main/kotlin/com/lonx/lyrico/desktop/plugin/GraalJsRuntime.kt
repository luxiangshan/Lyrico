package com.lonx.lyrico.desktop.plugin

import org.graalvm.polyglot.Context
import org.graalvm.polyglot.Engine
import org.graalvm.polyglot.HostAccess
import org.graalvm.polyglot.PolyglotException
import org.graalvm.polyglot.Source
import org.graalvm.polyglot.proxy.ProxyExecutable
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

class PluginScriptException(message: String, cause: Throwable? = null) : Exception(message, cause)

/**
 * JS runtime for Lyrico source plugins on GraalJS. Mirrors the Android QuickJS bridge: a single
 * `__lyricoHostCall(name, json)` native function, the same Platform bootstrap, and
 * `call(fn, requestJson)` returning the JSON-serialized result.
 */
class GraalJsRuntime(private val hostApi: HostApi?, private val timeoutMs: Long = 30_000) : AutoCloseable {

    private val context: Context = Context.newBuilder("js")
        .engine(sharedEngine)
        .allowHostAccess(HostAccess.NONE)
        .allowIO(false)
        .allowCreateThread(false)
        .allowNativeAccess(false)
        .option("js.ecmascript-version", "2023")
        .build()

    @Volatile private var closed = false

    init {
        if (hostApi != null) {
            context.getBindings("js").putMember("__lyricoHostCall", ProxyExecutable { args ->
                val name = args.getOrNull(0)?.asString().orEmpty()
                val payload = args.getOrNull(1)?.takeIf { it.isString }?.asString() ?: "{}"
                hostApi.call(name, payload)
            })
        }
        eval(BOOTSTRAP, "<lyrico-host>")
    }

    @Synchronized
    fun eval(script: String, filename: String = "<eval>"): String = guarded {
        hostApi?.beginInvocation(timeoutMs)
        val v = context.eval(Source.newBuilder("js", script, filename).buildLiteral())
        if (v.isNull) "null" else v.toString()
    }

    @Synchronized
    fun call(functionName: String, requestJson: String): String = guarded {
        hostApi?.beginInvocation(timeoutMs)
        hostApi?.resetCancellation()
        context.getBindings("js").getMember("__lyricoInvoke").execute(functionName, requestJson).asString()
    }

    private inline fun <T> guarded(block: () -> T): T {
        check(!closed) { "JS runtime is closed" }
        var watchdog: ScheduledFuture<*>? = null
        if (timeoutMs > 0) {
            watchdog = timer.schedule({
                hostApi?.cancelInvocation()
                runCatching { context.close(true) }
                closed = true
            }, timeoutMs, TimeUnit.MILLISECONDS)
        }
        try {
            return block()
        } catch (e: PolyglotException) {
            if (e.isCancelled || closed) throw PluginScriptException("插件执行超时（${timeoutMs / 1000} 秒）", e)
            throw PluginScriptException(e.message ?: "JavaScript error", e)
        } finally {
            watchdog?.cancel(false)
        }
    }

    val isClosed: Boolean get() = closed

    @Synchronized
    override fun close() {
        if (!closed) {
            closed = true
            runCatching { context.close(true) }
        }
    }

    companion object {
        private val sharedEngine: Engine by lazy {
            Engine.newBuilder("js")
                .option("engine.WarnInterpreterOnly", "false")
                .build()
        }
        private val timer = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "lyrico-js-watchdog").apply { isDaemon = true } }
        val BOOTSTRAP: String by lazy {
            GraalJsRuntime::class.java.getResourceAsStream("/plugin/bootstrap.js")!!.use { String(it.readBytes(), Charsets.UTF_8) }
        }
    }
}
