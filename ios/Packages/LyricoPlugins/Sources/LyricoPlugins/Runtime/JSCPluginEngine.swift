#if canImport(JavaScriptCore)
import Foundation
import JavaScriptCore

/// Deadline / cancellation state polled by the JavaScriptCore watchdog.
private final class WatchdogState: @unchecked Sendable {
    private let lock = NSLock()
    private var deadline: Date?
    private var cancelled = false
    private(set) var terminatedByTimeout = false
    private(set) var terminatedByCancel = false

    func begin(timeoutMs: Int64) {
        lock.lock(); defer { lock.unlock() }
        deadline = timeoutMs > 0 ? Date().addingTimeInterval(Double(timeoutMs) / 1000) : nil
        terminatedByTimeout = false
        terminatedByCancel = false
    }

    func end() { lock.lock(); deadline = nil; lock.unlock() }

    func setCancelled(_ value: Bool) { lock.lock(); cancelled = value; lock.unlock() }

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func shouldTerminate() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cancelled { terminatedByCancel = true; return true }
        if let deadline, Date() >= deadline { terminatedByTimeout = true; return true }
        return false
    }
}

private typealias JSShouldTerminateCallbackFn = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Bool
private typealias JSContextGroupSetExecutionTimeLimitFn = @convention(c) (OpaquePointer?, Double, JSShouldTerminateCallbackFn?, UnsafeMutableRawPointer?) -> Void

private let setExecutionTimeLimit: JSContextGroupSetExecutionTimeLimitFn? = {
    // RTLD_DEFAULT ((void *)-2 on Darwin): search every loaded image.
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit") else { return nil }
    return unsafeBitCast(symbol, to: JSContextGroupSetExecutionTimeLimitFn.self)
}()

private let watchdogCallback: JSShouldTerminateCallbackFn = { _, info in
    guard let info else { return false }
    return Unmanaged<WatchdogState>.fromOpaque(info).takeUnretainedValue().shouldTerminate()
}

/// JavaScriptCore implementation of the plugin runtime. Mirrors the Android QuickJS bridge:
/// `__lyricoHostCall(name, payloadJson)` host function, `HOST_API_BOOTSTRAP`, per-call deadline
/// enforced by the JSC watchdog, cancellation, and `call(function, requestJson)` returning
/// `JSON.stringify(result)` (`"null"` for undefined). Returned promises are awaited.
final class JSCPluginEngine: PluginScriptEngine {
    private let virtualMachine: JSVirtualMachine
    private let context: JSContext
    private let hostApi: HostApi
    private let timeoutMs: Int64
    private let watchdog = WatchdogState()
    private var closed = false

    static var engineVersion: String {
        Bundle(for: JSContext.self).infoDictionary?["CFBundleShortVersionString"] as? String ?? "system"
    }

    init(hostApi: HostApi, timeoutMs: Int64) throws {
        self.hostApi = hostApi
        self.timeoutMs = timeoutMs
        guard let vm = JSVirtualMachine(), let ctx = JSContext(virtualMachine: vm) else {
            throw PluginRuntimeError.engineUnavailable("Unable to create JavaScriptCore context")
        }
        virtualMachine = vm
        context = ctx
        context.name = "Lyrico plugin \(hostApi.pluginId)"
        context.exceptionHandler = { ctx, exception in ctx?.exception = exception }

        let api = hostApi
        let hostCall: @convention(block) (JSValue?, JSValue?) -> JSValue? = { nameValue, payloadValue in
            let ctx = JSContext.current()
            let name = nameValue.flatMap { $0.isUndefined ? nil : $0.toString() } ?? "undefined"
            let payload = payloadValue.flatMap { $0.isUndefined ? nil : $0.toString() } ?? "undefined"
            do {
                let result = try api.call(name, payload)
                return JSValue(object: result, in: ctx)
            } catch {
                ctx?.exception = JSValue(newErrorFromMessage: "Host API call failed: \(name): \(error)", in: ctx)
                return JSValue(undefinedIn: ctx)
            }
        }
        context.setObject(hostCall, forKeyedSubscript: "__lyricoHostCall" as NSString)

        if let setLimit = setExecutionTimeLimit {
            let group = JSContextGetGroup(context.jsGlobalContextRef)
            setLimit(group, 0.1, watchdogCallback, Unmanaged.passUnretained(watchdog).toOpaque())
        }

        try runGuarded(timeoutMs: 0) {
            context.evaluateScript(HostBootstrap.script, withSourceURL: URL(string: "lyrico-host://bootstrap"))
            context.evaluateScript(HostBootstrap.invokeHelper, withSourceURL: URL(string: "lyrico-host://invoke"))
        }
    }

    func evaluate(_ script: String, filename: String) throws {
        guard !closed else { throw PluginRuntimeError.closed }
        hostApi.beginInvocation(timeoutMs: timeoutMs)
        try runGuarded(timeoutMs: timeoutMs) {
            context.evaluateScript(script, withSourceURL: URL(string: "plugin://" + (filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "script")))
        }
    }

    func call(_ function: String, requestJSON: String) throws -> String {
        guard !closed else { throw PluginRuntimeError.closed }
        hostApi.beginInvocation(timeoutMs: timeoutMs)
        var settled: (Bool, String)?
        let onSettled: @convention(block) (Bool, String?) -> Void = { ok, payload in
            settled = (ok, payload ?? "null")
        }
        var outcome: JSValue?
        try runGuarded(timeoutMs: timeoutMs) {
            let invoke = context.objectForKeyedSubscript("__lyricoInvoke")
            outcome = invoke?.call(withArguments: [function, requestJSON, unsafeBitCast(onSettled, to: AnyObject.self)])
        }
        guard let outcome, let kind = outcome.objectForKeyedSubscript("kind")?.toString() else {
            throw PluginRuntimeError.scriptError("JavaScript execution failed, interrupted, or out of memory")
        }
        switch kind {
        case "missing":
            throw PluginRuntimeError.functionNotFound(function)
        case "value":
            return outcome.objectForKeyedSubscript("json")?.toString() ?? "null"
        default:
            if settled == nil {
                // Microtasks are drained when the outermost API call returns; give it one more turn.
                try runGuarded(timeoutMs: timeoutMs) { context.evaluateScript("void 0") }
            }
            guard let settled else { throw PluginRuntimeError.promiseNeverSettled(function) }
            if settled.0 { return settled.1 }
            throw PluginRuntimeError.scriptError(settled.1)
        }
    }

    func resetCancellation() {
        watchdog.setCancelled(false)
        hostApi.resetCancellation()
    }

    func cancel() {
        watchdog.setCancelled(true)
        hostApi.cancelInvocation()
    }

    func close() {
        closed = true
        context.setObject(nil, forKeyedSubscript: "__lyricoHostCall" as NSString)
    }

    private func runGuarded(timeoutMs: Int64, _ body: () -> Void) throws {
        watchdog.begin(timeoutMs: timeoutMs)
        context.exception = nil
        body()
        watchdog.end()
        if let exception = context.exception {
            context.exception = nil
            if watchdog.terminatedByCancel || watchdog.isCancelled && exception.toString().contains("terminated") { throw PluginRuntimeError.cancelled }
            if watchdog.terminatedByTimeout { throw PluginRuntimeError.timedOut }
            throw PluginRuntimeError.scriptError(Self.describe(exception))
        }
        if watchdog.terminatedByCancel { throw PluginRuntimeError.cancelled }
        if watchdog.terminatedByTimeout { throw PluginRuntimeError.timedOut }
    }

    /// QuickJS bridge `exceptionToString`: message, then the stack when it adds information.
    static func describe(_ exception: JSValue) -> String {
        var message = exception.toString() ?? ""
        if message == "null" || message == "undefined" { message = "" }
        if let stackValue = exception.objectForKeyedSubscript("stack"), !stackValue.isUndefined, !stackValue.isNull,
           let stack = stackValue.toString(), !stack.isEmpty, stack != message {
            if !message.isEmpty { message += "\n" }
            message += stack
        }
        return message.isEmpty ? "JavaScript execution failed, interrupted, or out of memory" : message
    }
}
#endif
