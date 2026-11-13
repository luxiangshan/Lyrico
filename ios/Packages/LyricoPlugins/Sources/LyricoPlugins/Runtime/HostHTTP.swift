import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct HostHTTPResponse {
    let code: Int
    let message: String
    let headers: [(String, [String])]
    let body: [UInt8]
}

/// Synchronous HTTP client for host API calls (OkHttp semantics: body returned for any status,
/// optional redirect following, 8 MiB response cap, no cookies, no caching).
final class HostHTTPClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let responseLimit = 8 * 1024 * 1024

    private final class TaskState {
        var data = Data()
        var response: HTTPURLResponse?
        var error: Error?
        var followRedirects = true
        var tooLarge = false
        let done = DispatchSemaphore(value: 0)
    }

    private let lock = NSLock()
    private var states: [Int: TaskState] = [:]
    private var session: URLSession!
    private let delegateQueue = OperationQueue()

    init(configuration: URLSessionConfiguration) {
        super.init()
        let config = configuration
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        delegateQueue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
    }

    func invalidate() { session.invalidateAndCancel() }

    /// Executes the request, blocking the calling (plugin) thread.
    func execute(_ request: URLRequest, followRedirects: Bool, deadline: Date?, isCancelled: @escaping () -> Bool,
                 registerCancel: (@escaping () -> Void) -> Void) throws -> HostHTTPResponse {
        let task = session.dataTask(with: request)
        let state = TaskState()
        state.followRedirects = followRedirects
        lock.lock(); states[task.taskIdentifier] = state; lock.unlock()
        defer { lock.lock(); states[task.taskIdentifier] = nil; lock.unlock() }
        registerCancel { task.cancel() }
        if isCancelled() { task.cancel() }
        task.resume()
        let waitResult: DispatchTimeoutResult
        if let deadline {
            let remaining = max(deadline.timeIntervalSinceNow, 0.001)
            waitResult = state.done.wait(timeout: .now() + remaining)
        } else {
            state.done.wait()
            waitResult = .success
        }
        if waitResult == .timedOut {
            task.cancel()
            _ = state.done.wait(timeout: .now() + 2)
            throw HostCallError.io("java.io.InterruptedIOException: timeout")
        }
        if isCancelled() { throw HostCallError.state("Plugin invocation cancelled") }
        if state.tooLarge { throw HostCallError.argument("Plugin response is too large") }
        if let error = state.error {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorTimedOut {
                throw HostCallError.io("java.net.SocketTimeoutException: timeout")
            }
            throw HostCallError.io("java.io.IOException: \(error.localizedDescription)")
        }
        guard let response = state.response else { throw HostCallError.io("java.io.IOException: No HTTP response") }
        var grouped: [(String, [String])] = []
        for (rawKey, rawValue) in response.allHeaderFields {
            let key = String(describing: rawKey).lowercased()
            let value = String(describing: rawValue)
            let values = key == "set-cookie" ? HostHTTPClient.splitSetCookie(value) : [value]
            if let idx = grouped.firstIndex(where: { $0.0 == key }) { grouped[idx].1.append(contentsOf: values) } else { grouped.append((key, values)) }
        }
        grouped.sort { $0.0 < $1.0 }
        return HostHTTPResponse(code: response.statusCode, message: "", headers: grouped, body: Array(state.data))
    }

    private func state(for task: URLSessionTask) -> TaskState? {
        lock.lock(); defer { lock.unlock() }
        return states[task.taskIdentifier]
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler((state(for: task)?.followRedirects ?? true) ? request : nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let s = state(for: dataTask) else { completionHandler(.cancel); return }
        s.response = response as? HTTPURLResponse
        if response.expectedContentLength > Int64(HostHTTPClient.responseLimit) {
            s.tooLarge = true
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let s = state(for: dataTask) else { return }
        if s.data.count + data.count > HostHTTPClient.responseLimit {
            s.tooLarge = true
            dataTask.cancel()
            return
        }
        s.data.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let s = state(for: task) else { return }
        if s.response == nil { s.response = task.response as? HTTPURLResponse }
        s.error = error
        s.done.signal()
    }

    /// Splits a folded `Set-Cookie` header back into individual cookies.
    static func splitSetCookie(_ value: String) -> [String] {
        var parts: [String] = []
        var current = ""
        let chars = Array(value)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "," {
                // A comma inside an Expires date ("Wed, 21 Oct") is followed by a space and a weekday-ish token.
                let rest = String(chars[(i + 1)...])
                let nextToken = rest.drop(while: { $0 == " " }).prefix { $0 != ";" && $0 != "," }
                if nextToken.contains("=") {
                    parts.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                    i += 1
                    continue
                }
            }
            current.append(c)
            i += 1
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current.trimmingCharacters(in: .whitespaces)) }
        return parts
    }
}
