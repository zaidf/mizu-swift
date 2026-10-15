import Foundation

/// A message sent to (or received from) an LLM, as your app built it.
public struct LLMMessage: Codable, Equatable, Sendable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }

    public static func system(_ content: String) -> LLMMessage { LLMMessage(role: "system", content: content) }
    public static func user(_ content: String) -> LLMMessage { LLMMessage(role: "user", content: content) }
    public static func assistant(_ content: String) -> LLMMessage { LLMMessage(role: "assistant", content: content) }
    public static func tool(_ content: String) -> LLMMessage { LLMMessage(role: "tool", content: content) }
}

/// Everything about one LLM call: exactly what the app sent, what came back, and how long it took.
struct LLMRecord: Codable, Equatable {
    let id: String
    let model: String
    let started_at: Int64
    var status: String  // running | done | failed
    var system: String?
    var messages: [LLMMessage]
    var tools: [String]
    var params: [String: TimelineValue]
    var first_token_ms: Int?
    var ms: Int?
    var output: String?
    var input_tokens: Int?
    var output_tokens: Int?
    var stop_reason: String?
    var error: String?
}

/// One in-flight LLM call. Call `firstToken()` when streaming starts (optional), then `finish` or `fail`.
///
///     let call = Mizu.llm(model: "claude-sonnet-5-5", system: prompt, messages: history)
///     let reply = try await client.send(...)
///     call.finish(output: reply.text, inputTokens: reply.usage.input, outputTokens: reply.usage.output)
///
/// When Mizu isn't running this does nothing, so it's safe to leave in your code.
public final class LLMCall: @unchecked Sendable {
    public let id: String
    private let store: LLMStore?
    private let started = Date()
    private let lock = NSLock()
    private var sawFirstToken = false
    private var ended = false

    init(id: String, store: LLMStore?) {
        self.id = id
        self.store = store
    }

    private var elapsedMs: Int { Int(Date().timeIntervalSince(started) * 1000) }

    /// The first streamed token arrived. Time-to-first-token is often where "the screen goes blank" lives.
    public func firstToken() {
        lock.lock()
        guard !sawFirstToken, !ended else { lock.unlock(); return }
        sawFirstToken = true
        lock.unlock()
        store?.firstToken(id, ms: elapsedMs)
    }

    public func finish(output: String, inputTokens: Int? = nil, outputTokens: Int? = nil, stopReason: String? = nil) {
        guard markEnded() else { return }
        store?.finish(id, ms: elapsedMs, output: output, inputTokens: inputTokens, outputTokens: outputTokens, stopReason: stopReason)
    }

    public func fail(_ error: Error) {
        fail(message: String(describing: error))
    }

    public func fail(message: String) {
        guard markEnded() else { return }
        store?.fail(id, ms: elapsedMs, error: message)
    }

    private func markEnded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if ended { return false }
        ended = true
        return true
    }
}

/// Keeps the most recent LLM calls in full and mirrors a short summary of each into the timeline.
/// Prompts can be big, so it holds at most `maxCalls` calls and roughly `maxChars` characters.
final class LLMStore: @unchecked Sendable {
    let maxCalls: Int
    let maxChars: Int
    /// Can be flipped remotely (set_capture llm_content). Applies to calls started after the change.
    var recordContent: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _recordContent }
        set { lock.lock(); _recordContent = newValue; lock.unlock() }
    }
    private var _recordContent: Bool
    private let timeline: Timeline?
    private let storeURL: URL?
    private let clock: () -> Date
    private let lock = NSLock()
    private var records: [LLMRecord] = []
    private var counter = 0
    /// Whether each call started with content recording on, so flipping the setting mid-call can't half-record it.
    private var contentByCall: [String: Bool] = [:]
    private var dirty = false

    init(timeline: Timeline?, recordContent: Bool = true, maxCalls: Int = 30, maxChars: Int = 2_000_000,
         storeURL: URL? = nil, clock: @escaping () -> Date = Date.init) {
        self.timeline = timeline
        self._recordContent = recordContent
        self.maxCalls = maxCalls
        self.maxChars = maxChars
        self.storeURL = storeURL
        self.clock = clock
    }

    static func defaultStoreURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mizu/llm.json")
    }

    func start(model: String, system: String?, messages: [LLMMessage], tools: [String], params: [String: TimelineValue]) -> LLMCall {
        lock.lock()
        let recordContent = _recordContent
        counter += 1
        // Short ids a person can say: c1, c2… Prefixed with the launch so they stay unique across relaunches.
        let id = "c\(counter)-\(Self.launchTag)"
        contentByCall[id] = recordContent
        if contentByCall.count > maxCalls * 2 { contentByCall = contentByCall.filter { key, _ in records.contains { $0.id == key } } }
        records.append(LLMRecord(
            id: id, model: model, started_at: Int64(clock().timeIntervalSince1970 * 1000), status: "running",
            system: recordContent ? system : nil, messages: recordContent ? messages : [], tools: tools, params: params
        ))
        trim()
        dirty = true
        lock.unlock()

        var data: [String: TimelineValue] = [
            "call": .string(id),
            "model": .string(model),
            "msgs": .int(messages.count),
            "chars": .int((system?.count ?? 0) + messages.reduce(0) { $0 + $1.content.count }),
        ]
        if recordContent, let last = messages.last(where: { $0.role == "user" }) {
            data["last_user"] = .string(Self.preview(last.content))
        }
        timeline?.record("llm.start", data)
        return LLMCall(id: id, store: self)
    }

    func firstToken(_ id: String, ms: Int) {
        update(id) { $0.first_token_ms = ms }
        timeline?.record("llm.first_token", ["call": .string(id), "ms": .int(ms)])
    }

    func finish(_ id: String, ms: Int, output: String, inputTokens: Int?, outputTokens: Int?, stopReason: String?) {
        lock.lock()
        let recordContent = contentByCall[id] ?? _recordContent
        lock.unlock()
        update(id) {
            $0.status = "done"
            $0.ms = ms
            $0.output = recordContent ? output : nil
            $0.input_tokens = inputTokens
            $0.output_tokens = outputTokens
            $0.stop_reason = stopReason
        }
        var data: [String: TimelineValue] = ["call": .string(id), "ms": .int(ms), "out_chars": .int(output.count)]
        if let inputTokens { data["in_tokens"] = .int(inputTokens) }
        if let outputTokens { data["out_tokens"] = .int(outputTokens) }
        if let stopReason { data["stop"] = .string(stopReason) }
        if recordContent { data["output"] = .string(Self.preview(output)) }
        timeline?.record("llm.end", data)
    }

    func fail(_ id: String, ms: Int, error: String) {
        update(id) {
            $0.status = "failed"
            $0.ms = ms
            $0.error = String(error.prefix(2000))
        }
        timeline?.record("llm.error", ["call": .string(id), "ms": .int(ms), "error": .string(String(error.prefix(200)))])
    }

    /// Calls from the last `seconds`, oldest first, for attaching to a report.
    func encodedSnapshot(seconds: TimeInterval = 600) -> Data? {
        let cutoff = Int64((clock().timeIntervalSince1970 - seconds) * 1000)
        lock.lock()
        let recent = records.filter { $0.started_at >= cutoff }
        lock.unlock()
        guard !recent.isEmpty else { return nil }
        return try? JSONEncoder().encode(["calls": recent])
    }

    var all: [LLMRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    func persist() {
        guard let storeURL else { return }
        lock.lock()
        let snapshot = dirty ? records : nil
        dirty = false
        lock.unlock()
        guard let snapshot, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
    }

    func restore() {
        guard let storeURL, let data = try? Data(contentsOf: storeURL),
              let saved = try? JSONDecoder().decode([LLMRecord].self, from: data) else { return }
        lock.lock()
        records = saved + records
        trim()
        lock.unlock()
    }

    private func update(_ id: String, _ change: (inout LLMRecord) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = records.lastIndex(where: { $0.id == id }) else { return }
        change(&records[index])
        trim()
        dirty = true
    }

    /// Drops the oldest calls past the count or size budget. Caller holds the lock.
    private func trim() {
        if records.count > maxCalls { records.removeFirst(records.count - maxCalls) }
        var total = records.reduce(0) { $0 + Self.size(of: $1) }
        while total > maxChars, records.count > 1 {
            total -= Self.size(of: records.removeFirst())
        }
    }

    private static func size(of r: LLMRecord) -> Int {
        (r.system?.count ?? 0) + r.messages.reduce(0) { $0 + $1.content.count } + (r.output?.count ?? 0)
    }

    static func preview(_ text: String, max: Int = 80) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
    }

    private static let launchTag: String = String(Int(Date().timeIntervalSince1970) % 100_000, radix: 36)
}
