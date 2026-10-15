import XCTest
@testable import Mizu

final class LoopTests: XCTestCase {
    private var cacheURL: URL!

    override func setUp() {
        cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent("mizu-loop-\(UUID()).json")
        StubProtocol.reset()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cacheURL)
    }

    private func makeClient() -> ConfigClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = ConfigClient(endpoint: URL(string: "https://mizu.test")!, ingestKey: "mizu_ik_test",
                                  session: URLSession(configuration: config), cacheURL: cacheURL)
        client.installID = "inst-1"
        client.build = "43"
        return client
    }

    private let twoFixes = #"""
    {"config":{},"server_time":0,"fixed":[
      {"id":"r_1","kind":"report","what":"hotel photos take seconds to load","note":"Photos now load instantly.","fixed_in_build":"43","reported_at":1},
      {"id":"fr_2","kind":"request","what":"Export the chat as a PDF","note":null,"fixed_in_build":null,"reported_at":2}
    ]}
    """#

    func testInstallIDIsStable() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mizu-install-\(UUID())")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = InstallID.load(at: url)
        XCTAssertEqual(InstallID.load(at: url), first)
        XCTAssertGreaterThanOrEqual(first.count, 16)
    }

    func testCheckInSendsInstallAndBuild() async throws {
        StubProtocol.mode = .status(200)
        StubProtocol.responseBody = Data(#"{"config":{},"server_time":0}"#.utf8)
        await makeClient().refresh()
        let request = try XCTUnwrap(StubProtocol.successfulRequests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Mizu-Install"), "inst-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Mizu-Build"), "43")
    }

    func testFixesShowOneAtATimeAndNeverTwiceInALaunch() async throws {
        StubProtocol.mode = .status(200)
        StubProtocol.responseBody = Data(twoFixes.utf8)
        let client = makeClient()
        var shown: [FixedNotice] = []
        client.onFixed = { shown.append($0); return true }

        await client.refresh()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(shown.map(\.id), ["r_1"], "one card at a time")
        XCTAssertEqual(shown.first?.note, "Photos now load instantly.")

        await client.refresh() // server hasn't heard the ack yet: still returns both
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(shown.map(\.id), ["r_1", "fr_2"], "the next one, never r_1 again")
    }

    func testAFixThatCouldNotShowIsTriedAgain() async throws {
        StubProtocol.mode = .status(200)
        StubProtocol.responseBody = Data(twoFixes.utf8)
        let client = makeClient()
        var attempts = 0
        client.onFixed = { _ in attempts += 1; return attempts > 1 }
        await client.refresh()
        try await Task.sleep(nanoseconds: 50_000_000)
        await client.refresh()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(attempts, 2)
    }

    func testAcknowledgingTellsTheServer() async throws {
        StubProtocol.mode = .status(200)
        StubProtocol.responseBody = Data(#"{"ok":true}"#.utf8)
        let ok = await makeClient().sendSeen(["r_1"])
        XCTAssertTrue(ok)
        let request = try XCTUnwrap(StubProtocol.successfulRequests.first)
        XCTAssertEqual(request.url?.path, "/v1/notices/seen")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Mizu-Install"), "inst-1")
        let body = try JSONSerialization.jsonObject(with: request.body) as! [String: [String]]
        XCTAssertEqual(body["ids"], ["r_1"])
    }
}
