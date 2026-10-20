import XCTest
@testable import Mizu

final class RemoteConfigTests: XCTestCase {
    private var cacheURL: URL!

    override func setUp() {
        cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent("mizu-config-\(UUID()).json")
        StubProtocol.reset()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cacheURL)
    }

    private func makeClient() -> ConfigClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return ConfigClient(endpoint: URL(string: "https://mizu.test")!, ingestKey: "mizu_ik_test",
                            session: URLSession(configuration: config), cacheURL: cacheURL)
    }

    private func serve(_ json: String) {
        StubProtocol.mode = .status(200)
        StubProtocol.responseBody = Data(json.utf8)
    }

    func testFetchesAndAppliesWhatClaudeAskedFor() async {
        let timeline = Timeline()
        let llm = LLMStore(timeline: nil, recordContent: false)
        let client = makeClient()
        client.timeline = timeline
        client.llmStore = llm
        client.defaultLLMContent = false
        let future = Int64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        serve(#"{"config":{"debug_tags":["context"],"timeline_minutes":20,"llm_content":true,"expires_at":\#(future)},"server_time":0}"#)

        let ok = await client.refresh()
        XCTAssertTrue(ok)
        XCTAssertEqual(StubProtocol.successfulRequests.first?.url?.path, "/v1/config")
        XCTAssertEqual(StubProtocol.successfulRequests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer mizu_ik_test")
        XCTAssertTrue(client.debugGate.isOn("context"))
        XCTAssertFalse(client.debugGate.isOn("nav"))
        XCTAssertEqual(timeline.retention, Timeline.defaultRetention, "an old server's timeline_minutes no longer shortens the week")
        XCTAssertTrue(llm.recordContent)
        XCTAssertEqual(timeline.snapshot().last?.kind, "mizu.config", "Claude can see in the timeline when settings changed")

        // Cleared remotely: back to the app's own defaults.
        serve(#"{"config":{},"server_time":0}"#)
        await client.refresh()
        XCTAssertFalse(client.debugGate.isOn("context"))
        XCTAssertEqual(timeline.retention, Timeline.defaultRetention)
        XCTAssertFalse(llm.recordContent)
    }

    func testWildcardTagTurnsOnEverything() {
        let gate = DebugGate()
        gate.set(["*"])
        XCTAssertTrue(gate.isOn("anything"))
    }

    func testExpiredOverridesAreIgnoredEvenFromCache() {
        let past = Int64(Date().addingTimeInterval(-60).timeIntervalSince1970 * 1000)
        let config = RemoteConfig(debug_tags: ["x"], timeline_minutes: 30, llm_content: true, expires_at: past,
                                  repro: .init(id: "rp_1", note: "try again"))
        let effective = config.effective()
        XCTAssertNil(effective.debug_tags)
        XCTAssertNil(effective.timeline_minutes)
        XCTAssertEqual(effective.repro?.note, "try again", "repro requests don't expire")
    }

    func testSettingsSurviveARelaunchWithoutNetwork() async {
        serve(#"{"config":{"debug_tags":["context"]},"server_time":0}"#)
        await makeClient().refresh()

        StubProtocol.mode = .offline
        let relaunched = makeClient()
        relaunched.loadCache()
        let ok = await relaunched.refresh()
        XCTAssertFalse(ok)
        XCTAssertTrue(relaunched.debugGate.isOn("context"), "cached settings apply while offline")
    }

    func testReproRequestFlow() async {
        let client = makeClient()
        let shown = expectation(description: "banner asked to show")
        shown.expectedFulfillmentCount = 1
        shown.assertForOverFulfill = true
        var shownNote: String?
        client.onNewRepro = { shownNote = $0.note; shown.fulfill(); return true }

        serve(#"{"config":{"repro":{"id":"rp_1","note":"Open Chat, send two messages, shake.","created_at":1}},"server_time":0}"#)
        await client.refresh()
        await client.refresh() // same request again: no second banner
        await fulfillment(of: [shown], timeout: 2)
        XCTAssertEqual(shownNote, "Open Chat, send two messages, shake.")

        XCTAssertNil(client.activeRepro, "not linked to reports until the developer has seen it")
        client.markSeen(.init(id: "rp_1", note: "Open Chat, send two messages, shake."))
        XCTAssertEqual(client.activeRepro?.id, "rp_1")

        client.answered(.init(id: "rp_1", note: ""))
        XCTAssertNil(client.activeRepro)

        // Seen ids are remembered across launches, so a relaunch doesn't re-show the banner.
        let relaunched = makeClient()
        relaunched.loadCache()
        var reshown = false
        relaunched.onNewRepro = { _ in reshown = true; return true }
        await relaunched.refresh()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(reshown)
    }

    func testBannerThatCouldNotShowYetIsRetried() async {
        let client = makeClient()
        var attempts = 0
        client.onNewRepro = { _ in attempts += 1; return attempts > 1 } // first try: app not on screen yet
        serve(#"{"config":{"repro":{"id":"rp_2","note":"again","created_at":1}},"server_time":0}"#)
        await client.refresh()
        try? await Task.sleep(nanoseconds: 50_000_000)
        await client.refresh()
        try? await Task.sleep(nanoseconds: 50_000_000)
        await client.refresh() // shown on the second try; no third
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(attempts, 2)
    }

    func testLLMContentSwitchOnlyAffectsNewCalls() throws {
        let store = LLMStore(timeline: nil, recordContent: true)
        let call = store.start(model: "m", system: "sys", messages: [.user("hi")], tools: [], params: [:])
        store.recordContent = false
        call.finish(output: "reply")
        XCTAssertEqual(store.all.first?.output, "reply", "a call that started with content on keeps its reply")
        store.start(model: "m", system: "sys", messages: [.user("hi")], tools: [], params: [:]).finish(output: "secret")
        XCTAssertNil(store.all.last?.output)
        XCTAssertNil(store.all.last?.system)
    }
}
