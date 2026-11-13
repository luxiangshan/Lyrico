import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import RemoteStorage

final class ZDebugTests: StubTestCase {
    func test204() async throws {
        StubURLProtocol.enqueue(.code(204))
        let c = HTTPClient(configuration: StubURLProtocol.configuration())
        let r = try await c.send(URLRequest(url: URL(string: "http://x.test/a")!, method: "DELETE"))
        print("got", r.status)
    }
    func test401() async throws {
        StubURLProtocol.enqueue(.code(401, headers: ["WWW-Authenticate": "Basic realm=\"dav\""]))
        let c = HTTPClient(configuration: StubURLProtocol.configuration())
        let r = try await c.send(URLRequest(url: URL(string: "http://x.test/a")!, method: "DELETE"))
        print("got", r.status)
    }
}
