import XCTest
@testable import Mizu

final class LLMTests: XCTestCase {
    func testRecordsTheFullCallAndSummarizesItInTheTimeline() throws {
        let timeline = Timeline()
        let store = LLMStore(timeline: timeline)
        let call = store.start(
            model: "claude-sonnet-5-5", system: "You are a helpful assistant.",
            messages: [.user("hi"), .assistant("hello!"), .user("why is the sky blue")],
            tools: ["search"], params: ["temperature": .double(0.7)]
        )
        call.firstToken()
        call.firstToken() // only the first one counts
        call.finish(output: "Rayleigh scattering.", inputTokens: 1200, outputTokens: 8, stopReason: "end_turn")
        call.finish(output: "ignored") // ending twice is a no-op

        let record = try XCTUnwrap(store.all.first)
        XCTAssertEqual(record.status, "done")
        XCTAssertEqual(record.system, "You are a helpful assistant.")
        XCTAssertEqual(record.messages.count, 3)
        XCTAssertEqual(record.output, "Rayleigh scattering.")
        XCTAssertEqual(record.input_tokens, 1200)
        XCTAssertEqual(record.tools, ["search"])
        XCTAssertNotNil(record.first_token_ms)

        let kinds = timeline.snapshot().map(\.kind)
        XCTAssertEqual(kinds, ["llm.start", "llm.first_token", "llm.end"])
        let start = timeline.snapshot()[0]
        XCTAssertEqual(start.data["call"], .string(call.id))
        XCTAssertEqual(start.data["msgs"], .int(3))
        XCTAssertEqual(start.data["last_user"], "why is the sky blue")
        XCTAssertEqual(timeline.snapshot()[2].data["in_tokens"], .int(1200))
    }

    func testFailuresAreRecorded() throws {
        let timeline = Timeline()
        let store = LLMStore(timeline: timeline)
        store.start(model: "m", system: nil, messages: [.user("x")], tools: [], params: [:]).fail(message: "HTTP 529 overloaded")
        XCTAssertEqual(store.all.first?.status, "failed")
        XCTAssertEqual(store.all.first?.error, "HTTP 529 overloaded")
        XCTAssertEqual(timeline.snapshot().last?.kind, "llm.error")
    }

    func testContentCanBeLeftOut() throws {
        let timeline = Timeline()
        let store = LLMStore(timeline: timeline, recordContent: false)
        let call = store.start(model: "m", system: "secret system", messages: [.user("private")], tools: [], params: [:])
        call.finish(output: "private reply", inputTokens: 5, outputTokens: 2)
        let record = try XCTUnwrap(store.all.first)
        XCTAssertNil(record.system)
        XCTAssertTrue(record.messages.isEmpty)
        XCTAssertNil(record.output)
        XCTAssertEqual(record.input_tokens, 5)
        let json = String(decoding: try XCTUnwrap(timeline.encodedSnapshot()), as: UTF8.self)
        XCTAssertFalse(json.contains("private"), "no prompt or output text in the timeline either")
    }

    func testKeepsOnlyRecentCallsWithinBudget() {
        let store = LLMStore(timeline: nil, maxCalls: 5, maxChars: 1000)
        for i in 0..<20 {
            store.start(model: "m", system: nil, messages: [.user("call \(i)")], tools: [], params: [:]).finish(output: "ok")
        }
        XCTAssertEqual(store.all.count, 5)
        XCTAssertEqual(store.all.last?.messages.first?.content, "call 19")

        let big = LLMStore(timeline: nil, maxCalls: 50, maxChars: 1000)
        for _ in 0..<5 {
            big.start(model: "m", system: nil, messages: [.user(String(repeating: "x", count: 400))], tools: [], params: [:])
        }
        XCTAssertEqual(big.all.count, 2, "oldest dropped once over the character budget")
    }

    func testSnapshotOnlyIncludesRecentCalls() throws {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let store = LLMStore(timeline: nil, clock: { now })
        store.start(model: "old", system: nil, messages: [], tools: [], params: [:])
        now += 700
        store.start(model: "new", system: nil, messages: [], tools: [], params: [:])
        let json = try JSONSerialization.jsonObject(with: XCTUnwrap(store.encodedSnapshot())) as! [String: [[String: Any]]]
        XCTAssertEqual(json["calls"]?.map { $0["model"] as? String }, ["new"])
    }

    func testSurvivesRelaunch() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mizu-llm-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let before = LLMStore(timeline: nil, storeURL: url)
        before.start(model: "m", system: nil, messages: [.user("hi")], tools: [], params: [:]).finish(output: "yo")
        before.persist()
        let after = LLMStore(timeline: nil, storeURL: url)
        after.restore()
        XCTAssertEqual(after.all.first?.output, "yo")
    }

    func testDoesNothingWhenMizuIsNotRunning() async throws {
        XCTAssertNil(Mizu.llmStore)
        let call = Mizu.llm(model: "m", messages: [.user("hi")])
        call.finish(output: "fine") // no crash, no effect
        struct Boom: Error {}
        do {
            _ = try await Mizu.traceLLM(model: "m", messages: [], output: { (s: String) in s }) { throw Boom() }
            XCTFail("should rethrow")
        } catch is Boom {}
    }
}
