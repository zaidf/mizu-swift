import XCTest
@testable import Mizu

final class TimelineTests: XCTestCase {
    func testCapsByCount() {
        let timeline = Timeline(maxEvents: 100)
        for i in 0..<1000 { timeline.record("tick", ["i": .int(i)]) }
        let events = timeline.snapshot()
        XCTAssertEqual(events.count, 100)
        XCTAssertEqual(events.first?.data["i"], .int(900), "keeps the newest")
        XCTAssertLessThanOrEqual(timeline.count, 110, "memory stays bounded")
    }

    func testDropsEventsOlderThanMaxAge() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let timeline = Timeline(maxAge: 600, clock: { now })
        timeline.record("old")
        now += 601
        timeline.record("new")
        XCTAssertEqual(timeline.snapshot().map(\.kind), ["new"])
    }

    func testEncodesFlatJSON() throws {
        let timeline = Timeline()
        timeline.record("keyboard.will_show", ["height": 336, "anim_ms": 250])
        let data = try XCTUnwrap(timeline.encodedSnapshot())
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let event = (json["events"] as! [[String: Any]])[0]
        XCTAssertEqual(event["kind"] as? String, "keyboard.will_show")
        XCTAssertEqual(event["height"] as? Int, 336)
        XCTAssertNotNil(event["t"])
        XCTAssertNotNil(json["captured_at"])
    }

    func testSurvivesRelaunch() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mizu-timeline-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let before = Timeline(storeURL: url)
        before.record("screen", ["name": "Chat"])
        before.persist()

        let after = Timeline(storeURL: url)
        after.restore()
        after.record("app.launch")
        XCTAssertEqual(after.snapshot().map(\.kind), ["screen", "app.launch"])
    }

    func testLogValuesConvert() {
        XCTAssertEqual(TimelineValue(12), .int(12))
        XCTAssertEqual(TimelineValue(true), .bool(true))
        XCTAssertEqual(TimelineValue("x"), .string("x"))
        XCTAssertEqual(TimelineValue([1, 2]), .string("[1, 2]"))
    }

    /// Budget: recording must be cheap enough to leave on all the time.
    func testOverheadBudget() {
        let timeline = Timeline()
        let start = Date()
        for i in 0..<100_000 { timeline.record("tap", ["x": .int(i), "y": 10, "view": "Button"]) }
        let perEvent = Date().timeIntervalSince(start) / 100_000
        XCTAssertLessThan(perEvent, 0.00002, "each event should cost well under 20µs (was \(perEvent * 1_000_000)µs)")

        let encodeStart = Date()
        let data = timeline.encodedSnapshot()!
        XCTAssertLessThan(Date().timeIntervalSince(encodeStart), 0.25, "snapshot at shake time must feel instant")
        XCTAssertLessThan(data.count, 2_000_000, "a full timeline stays small enough to upload on cellular")
    }
}

final class NetworkObserverTests: XCTestCase {
    func testRecordsRequestsWithoutQueryStrings() async throws {
        let timeline = Timeline()
        NetworkObserver(timeline: timeline, ignoredHosts: ["mizu.test"]).install()
        StubProtocol.reset()
        StubProtocol.mode = .status(201)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        var request = URLRequest(url: URL(string: "https://api.example.com/v1/chat?key=secret")!)
        request.httpMethod = "POST"
        _ = try await session.data(for: request)
        _ = try await session.data(from: URL(string: "https://mizu.test/v1/reports")!)

        // KVO completion lands just after the response.
        for _ in 0..<50 where !timeline.snapshot().contains(where: { $0.kind == "net.end" }) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let events = timeline.snapshot()
        let end = try XCTUnwrap(events.first { $0.kind == "net.end" })
        XCTAssertEqual(end.data["host"], "api.example.com")
        XCTAssertEqual(end.data["path"], "/v1/chat")
        XCTAssertEqual(end.data["method"], "POST")
        XCTAssertEqual(end.data["status"], .int(201))
        XCTAssertNotNil(end.data["ms"])
        XCTAssertFalse(events.contains { $0.data.values.contains(.string("mizu.test")) }, "Mizu's own uploads are not recorded")
        XCTAssertFalse(String(decoding: timeline.encodedSnapshot()!, as: UTF8.self).contains("secret"), "query strings never recorded")
        XCTAssertEqual(events.filter { $0.kind == "net.start" }.count, 1, "one start per request, even with layered resume hooks")
    }
}
