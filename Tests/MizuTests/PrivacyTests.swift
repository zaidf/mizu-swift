import XCTest
@testable import Mizu

final class PrivacyTests: XCTestCase {
    func testPathsKeepTheirShapeButNotPersonalIds() {
        XCTAssertEqual(NetworkObserver.redactPath("/users/jane@x.com/orders/48213"), "/users/:email/orders/:id")
        XCTAssertEqual(NetworkObserver.redactPath("/v1/chats/3f2504e0-4f89-11d3-9a0c-0305e82c3301/messages"), "/v1/chats/:uuid/messages")
        XCTAssertEqual(NetworkObserver.redactPath("/files/a8f3k2m9x7q4b6n1z0/download"), "/files/:id/download")
        XCTAssertEqual(NetworkObserver.redactPath("/v1/messages"), "/v1/messages", "ordinary paths are untouched")
        XCTAssertEqual(NetworkObserver.redactPath("/api/2024/report"), "/api/:id/report")
        XCTAssertEqual(NetworkObserver.redactPath("/page/12"), "/page/12", "short numbers stay")
        XCTAssertEqual(NetworkObserver.redactPath(""), "/")
    }

    func testIgnoredHostsIncludeSubdomains() {
        let ignored: Set<String> = ["example.com"]
        XCTAssertTrue(NetworkObserver.isIgnored("example.com", ignored))
        XCTAssertTrue(NetworkObserver.isIgnored("auth.Example.com", ignored))
        XCTAssertFalse(NetworkObserver.isIgnored("notexample.com", ignored))
    }

    func testLLMContentDefaultsToOnInDebugBuildsAndCanBeTurnedOff() {
        var options = Mizu.Options()
        XCTAssertNil(options.recordLLMContent)
        XCTAssertTrue(options.llmContentEnabled, "tests are a debug build")
        options.recordLLMContent = false
        XCTAssertFalse(options.llmContentEnabled)
    }

    func testRecordedRequestsAreRedactedEndToEnd() async throws {
        let timeline = Timeline()
        NetworkObserver(timeline: timeline, ignoredHosts: ["skip.example"]).install()
        StubProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        _ = try await session.data(from: URL(string: "https://api.example.com/users/jane@x.com/orders/48213?token=abc")!)
        _ = try await session.data(from: URL(string: "https://cdn.skip.example/thing")!)
        for _ in 0..<50 where !timeline.snapshot().contains(where: { $0.kind == "net.end" }) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let json = String(decoding: try XCTUnwrap(timeline.encodedSnapshot()), as: UTF8.self)
        let paths = timeline.snapshot().compactMap { $0.data["path"] }
        XCTAssertTrue(paths.contains(.string("/users/:email/orders/:id")), "got \(paths)")
        XCTAssertFalse(json.contains("jane"))
        XCTAssertFalse(json.contains("48213"))
        XCTAssertFalse(json.contains("token=abc"))
        XCTAssertFalse(json.contains("skip.example"))
    }
}
