import XCTest
@testable import RemoteStorage
final class SmokeTests: XCTestCase { func testX() { XCTAssertEqual(RemotePaths.normalize("a//b"), "/a/b") } }
