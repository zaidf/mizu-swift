import XCTest
@testable import Mizu

final class AttachmentTests: XCTestCase {
    override func tearDown() {
        Mizu.attachments = nil
    }

    func testTextJsonAndFileAttachments() throws {
        let log = MizuAttachment(name: "pipeline.log", text: "step 1\nstep 2")
        XCTAssertEqual(log.contentType, "text/plain")
        struct Turn: Encodable { let id: Int; let chunks: [String] }
        let turn = try MizuAttachment(name: "turn.json", json: Turn(id: 12, chunks: ["a", "b"]))
        XCTAssertEqual(turn.contentType, "application/json")
        XCTAssertTrue(String(decoding: turn.data, as: UTF8.self).contains("\"id\" : 12"))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mizu-\(UUID()).ndjson")
        try Data("{}\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(MizuAttachment(fileURL: url)?.contentType, "application/x-ndjson")
        XCTAssertNil(MizuAttachment(fileURL: URL(fileURLWithPath: "/nope/missing.txt")))
    }

    func testKeepsWhatFitsTheLimits() {
        let small = (0..<25).map { MizuAttachment(name: "f\($0).txt", text: "x") }
        let (kept, dropped) = MizuAttachment.fitting(small)
        XCTAssertEqual(kept.count, 20)
        XCTAssertEqual(dropped.count, 5)

        let big = MizuAttachment(name: "big.bin", data: Data(count: 10 * 1024 * 1024 + 1))
        let nine = MizuAttachment(name: "nine.bin", data: Data(count: 9 * 1024 * 1024))
        let result = MizuAttachment.fitting([big, nine, nine, nine])
        XCTAssertEqual(result.kept.map(\.name), ["nine.bin", "nine.bin"], "25 MB total")
        XCTAssertEqual(result.dropped, ["big.bin", "nine.bin"])
    }

    func testSafeNamesAndOutboxParts() {
        XCTAssertEqual(MizuAttachment.safe("../turn 12 dump.json"), "turn-12-dump.json")
        let part = MizuAttachment(name: "pipeline.log", text: "x").outboxPart
        XCTAssertEqual(part.name, "attachment:pipeline.log")
        XCTAssertEqual(part.fieldName, "attachment")
        XCTAssertEqual(part.filename, "pipeline.log")
    }

    func testProviderAndExtrasAreCombined() {
        Mizu.attachments = { [MizuAttachment(name: "state.json", text: "{}")] }
        let parts = Mizu.attachmentParts([MizuAttachment(name: "turn.log", text: "x")])
        XCTAssertEqual(parts.map(\.filename), ["state.json", "turn.log"])
    }

    func testShareDebugAndEventAreSafeWhenMizuIsOff() {
        XCTAssertFalse(Mizu.isRunning)
        Mizu.event("pipeline.retrieve", data: ["chunks": 8])
        Mizu.shareDebug(note: "nothing should happen", attachments: [MizuAttachment(name: "a.txt", text: "x")])
    }

    func testEventsUseTheirOwnKind() {
        let timeline = Timeline()
        let saved = Mizu.timeline
        Mizu.timeline = timeline
        defer { Mizu.timeline = saved }
        Mizu.event("pipeline.rerank", data: ["ms": 41, "top": "doc-7"])
        Mizu.event("  ")
        XCTAssertEqual(timeline.snapshot().map(\.kind), ["pipeline.rerank"])
        XCTAssertEqual(timeline.snapshot().first?.data["ms"], .int(41))
    }
}
