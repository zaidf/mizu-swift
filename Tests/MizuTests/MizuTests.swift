import XCTest
@testable import Mizu

final class OutboxTests: XCTestCase {
    var outbox: Outbox!

    override func setUp() {
        outbox = Outbox(root: FileManager.default.temporaryDirectory.appendingPathComponent("mizu-tests-\(UUID().uuidString)"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: outbox.root)
    }

    func testEnqueuePersistsInOrderAndRemoves() throws {
        let first = try outbox.enqueue(meta: ["note": "one"], parts: [OutboxPart(name: "screenshot", contentType: "image/jpeg", data: Data([1, 2, 3]))])
        Thread.sleep(forTimeInterval: 0.002)
        let second = try outbox.enqueue(meta: ["note": "two"])

        // A fresh Outbox on the same folder sees the same items: survives relaunch.
        let reopened = Outbox(root: outbox.root)
        let items = reopened.pending()
        XCTAssertEqual(items.map(\.id), [first, second])
        XCTAssertEqual(items[0].part("screenshot")?.data, Data([1, 2, 3]))
        XCTAssertEqual(items[0].part("screenshot")?.contentType, "image/jpeg")
        XCTAssertTrue(items[1].parts.isEmpty)

        let meta = try JSONSerialization.jsonObject(with: items[0].meta) as! [String: Any]
        XCTAssertEqual(meta["note"] as? String, "one")
        XCTAssertEqual(meta["client_id"] as? String, first)

        reopened.remove(items[0])
        XCTAssertEqual(outbox.pending().map(\.id), [second])
    }
}

final class UploaderTests: XCTestCase {
    var outbox: Outbox!
    var uploader: Uploader!

    override func setUp() {
        outbox = Outbox(root: FileManager.default.temporaryDirectory.appendingPathComponent("mizu-tests-\(UUID().uuidString)"))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        uploader = Uploader(endpoint: URL(string: "https://mizu.test")!, ingestKey: "mizu_ik_test", outbox: outbox, session: URLSession(configuration: config))
        StubProtocol.reset()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: outbox.root)
    }

    func testOfflineThenOnlineSendsExactlyOnce() async throws {
        try outbox.enqueue(meta: ["note": "keyboard bug"], parts: [OutboxPart(name: "screenshot", contentType: "image/jpeg", data: Data("jpeg".utf8))])

        StubProtocol.mode = .offline
        let offline = await uploader.flush()
        XCTAssertEqual(offline, .retryLater(sent: 0))
        XCTAssertEqual(outbox.pending().count, 1, "report stays on disk while offline")

        StubProtocol.mode = .status(201)
        let online = await uploader.flush()
        XCTAssertEqual(online, .drained(sent: 1))
        XCTAssertEqual(outbox.pending().count, 0)

        let again = await uploader.flush()
        XCTAssertEqual(again, .drained(sent: 0))
        XCTAssertEqual(StubProtocol.successfulRequests.count, 1, "sent exactly once")

        let request = try XCTUnwrap(StubProtocol.successfulRequests.first)
        XCTAssertEqual(request.url?.path, "/v1/reports")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer mizu_ik_test")
        let body = String(decoding: request.body, as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"meta\""))
        XCTAssertTrue(body.contains("keyboard bug"))
        XCTAssertTrue(body.contains("name=\"screenshot\"; filename=\"screenshot.jpg\""))
    }

    func testVoiceNoteIsUploadedAsAudioPart() async throws {
        try outbox.enqueue(meta: ["note": "hi"], parts: [OutboxPart(name: "audio", contentType: "audio/wav", data: Data("RIFFwav".utf8))])
        XCTAssertEqual(Outbox(root: outbox.root).pending().first?.part("audio")?.data, Data("RIFFwav".utf8), "voice note survives relaunch")
        StubProtocol.mode = .status(201)
        _ = await uploader.flush()
        let body = String(decoding: try XCTUnwrap(StubProtocol.successfulRequests.first).body, as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"audio\"; filename=\"audio.wav\""))
        XCTAssertTrue(body.contains("Content-Type: audio/wav"))
        XCTAssertTrue(body.contains("RIFFwav"))
    }

    func testFeatureRequestsGoToTheirOwnEndpointAsJSON() async throws {
        try outbox.enqueue(meta: ["want": "dark mode"], path: "v1/requests")
        XCTAssertEqual(Outbox(root: outbox.root).pending().first?.path, "v1/requests", "survives relaunch")
        StubProtocol.mode = .status(201)
        let outcome = await uploader.flush()
        XCTAssertEqual(outcome, .drained(sent: 1))
        let request = try XCTUnwrap(StubProtocol.successfulRequests.first)
        XCTAssertEqual(request.url?.path, "/v1/requests")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let json = try JSONSerialization.jsonObject(with: request.body) as! [String: Any]
        XCTAssertEqual(json["want"] as? String, "dark mode")
        XCTAssertNotNil(json["client_id"], "retries stay idempotent")
    }

    func testAttachmentsShareOneFieldWithTheirOwnFilenames() async throws {
        try outbox.enqueue(meta: ["note": "x"], parts: [
            MizuAttachment(name: "pipeline.log", text: "step 1").outboxPart,
            MizuAttachment(name: "turn.json", text: "{}").outboxPart,
        ])
        StubProtocol.mode = .status(201)
        _ = await uploader.flush()
        let body = String(decoding: try XCTUnwrap(StubProtocol.successfulRequests.first).body, as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"attachment\"; filename=\"pipeline.log\""))
        XCTAssertTrue(body.contains("name=\"attachment\"; filename=\"turn.json\""))
    }

    func testServerErrorsKeepReportsAndAuthErrorsToo() async throws {
        try outbox.enqueue(meta: [:])
        for status in [500, 503, 429, 401] {
            StubProtocol.mode = .status(status)
            let outcome = await uploader.flush()
            XCTAssertEqual(outcome, .retryLater(sent: 0), "HTTP \(status)")
            XCTAssertEqual(outbox.pending().count, 1)
        }
    }

    func testUnsendableReportIsDroppedSoItDoesNotBlockTheQueue() async throws {
        try outbox.enqueue(meta: [:])
        StubProtocol.mode = .status(413)
        let outcome = await uploader.flush()
        XCTAssertEqual(outcome, .drained(sent: 0))
        XCTAssertEqual(outbox.pending().count, 0)
    }

    func testConcurrentFlushesDoNotDoubleSend() async throws {
        try outbox.enqueue(meta: [:])
        StubProtocol.mode = .status(201)
        async let a = uploader.flush()
        async let b = uploader.flush()
        _ = await (a, b)
        XCTAssertEqual(StubProtocol.successfulRequests.count, 1)
    }
}

final class ScreenNameTests: XCTestCase {
    func testSwiftUIHostingNames() {
        XCTAssertEqual(ScreenName.from(typeName: "UIHostingController<ChatView>"), "ChatView")
        XCTAssertEqual(ScreenName.from(typeName: "UIHostingController<ModifiedContent<ChatView, _EnvironmentKeyWritingModifier<Optional<Store>>>>"), "ChatView")
        XCTAssertEqual(ScreenName.from(typeName: "SettingsViewController"), "SettingsViewController")
        XCTAssertEqual(ScreenName.from(typeName: "UIHostingController<AnyView>"), "UIHostingController")
        XCTAssertEqual(ScreenName.from(typeName: "UIHostingController<ModifiedContent<AnyView, RootModifier>>"), "UIHostingController")
    }
}

/// Fakes the network for URLSession.
final class StubProtocol: URLProtocol {
    enum Mode { case offline, status(Int) }
    struct Captured { let url: URL?; let headers: [String: String]; let body: Data
        func value(forHTTPHeaderField name: String) -> String? { headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value }
    }

    nonisolated(unsafe) static var mode: Mode = .status(201)
    nonisolated(unsafe) static var responseBody = Data("{}".utf8)
    nonisolated(unsafe) static var successfulRequests: [Captured] = []
    static let lock = NSLock()

    static func reset() { lock.withLock { mode = .status(201); successfulRequests = []; responseBody = Data("{}".utf8) } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let mode = Self.lock.withLock { Self.mode }
        switch mode {
        case .offline:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case .status(let code):
            if (200..<300).contains(code) {
                let captured = Captured(url: request.url, headers: request.allHTTPHeaderFields ?? [:], body: Self.body(of: request))
                Self.lock.withLock { Self.successfulRequests.append(captured) }
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.lock.withLock { Self.responseBody })
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
