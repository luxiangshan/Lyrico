import Foundation

/// Errors produced by the script runtime.
public enum PluginRuntimeError: Error, CustomStringConvertible, Equatable {
    case functionNotFound(String)
    case scriptError(String)
    case timedOut
    case cancelled
    case promiseNeverSettled(String)
    case engineUnavailable(String)
    case closed

    public var description: String {
        switch self {
        case .functionNotFound(let f): return "JavaScript function not found: \(f)"
        case .scriptError(let m): return m
        case .timedOut: return "Plugin invocation timed out"
        case .cancelled: return "Plugin invocation cancelled"
        case .promiseNeverSettled(let f): return "Promise returned by \(f) did not settle"
        case .engineUnavailable(let m): return m
        case .closed: return "Plugin instance has been retired"
        }
    }
}

/// A JavaScript engine instance bound to one plugin. All methods except `cancel` are called on the
/// plugin's dedicated executor thread.
protocol PluginScriptEngine: AnyObject {
    func evaluate(_ script: String, filename: String) throws
    func call(_ function: String, requestJSON: String) throws -> String
    func resetCancellation()
    /// Thread-safe; interrupts running JS and in-flight host HTTP.
    func cancel()
    func close()
}

/// Single thread executor with a large stack (Android uses one 4 MiB thread per plugin).
final class PluginExecutor: @unchecked Sendable {
    private let condition = NSCondition()
    private var queue: [() -> Void] = []
    private var stopped = false
    private var thread: Thread?

    init(name: String, stackSize: Int = 4 * 1024 * 1024) {
        let thread = Thread { [self] in self.loop() }
        thread.name = name
        thread.stackSize = stackSize
        self.thread = thread
        thread.start()
    }

    private func loop() {
        while true {
            condition.lock()
            while queue.isEmpty && !stopped { condition.wait() }
            if queue.isEmpty && stopped { condition.unlock(); break }
            let work = queue.removeFirst()
            condition.unlock()
            autoreleasepool { work() }
        }
        thread = nil
    }

    func submit(_ work: @escaping () -> Void) {
        condition.lock()
        queue.append(work)
        condition.signal()
        condition.unlock()
    }

    /// Runs remaining work then stops the thread.
    func shutdown() {
        condition.lock()
        stopped = true
        condition.signal()
        condition.unlock()
    }

    func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            submit {
                do { continuation.resume(returning: try body()) } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

#if !canImport(ObjectiveC)
@inline(__always) func autoreleasepool<T>(_ body: () throws -> T) rethrows -> T { try body() }
#endif
