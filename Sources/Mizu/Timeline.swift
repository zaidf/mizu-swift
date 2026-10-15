import Foundation

/// A JSON-safe value for timeline event fields.
public enum TimelineValue: Encodable, Equatable, Sendable,
    ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }

    /// Best-effort conversion for `Mizu.log(_:data:)`; anything exotic becomes its description.
    init(_ any: Any) {
        switch any {
        case let v as Bool: self = .bool(v)
        case let v as Int: self = .int(v)
        case let v as Double: self = .double((v * 1000).rounded() / 1000)
        case let v as Float: self = .double(Double(v))
        case let v as String: self = .string(v)
        default: self = .string(String(describing: any))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        }
    }
}

extension TimelineValue: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) { self = .bool(v) }
        else if let v = try? container.decode(Int.self) { self = .int(v) }
        else if let v = try? container.decode(Double.self) { self = .double(v) }
        else { self = .string(try container.decode(String.self)) }
    }
}

/// One thing that happened. Encodes flat: `{"t": 1739…, "kind": "keyboard.show", "height": 336}`.
struct TimelineEvent: Codable, Equatable {
    /// Unix time in milliseconds (device clock).
    let t: Int64
    let kind: String
    let data: [String: TimelineValue]

    init(t: Int64, kind: String, data: [String: TimelineValue] = [:]) {
        self.t = t
        self.kind = kind
        self.data = data
    }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(t, forKey: Key("t"))
        try container.encode(kind, forKey: Key("kind"))
        for (key, value) in data where key != "t" && key != "kind" {
            try container.encode(value, forKey: Key(key))
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        t = try container.decode(Int64.self, forKey: Key("t"))
        kind = try container.decode(String.self, forKey: Key("kind"))
        var data: [String: TimelineValue] = [:]
        for key in container.allKeys where key.stringValue != "t" && key.stringValue != "kind" {
            if let value = try? container.decode(TimelineValue.self, forKey: key) { data[key.stringValue] = value }
        }
        self.data = data
    }
}

/// The black box: always recording the last few minutes, cheaply, so the timeline you need already exists
/// when you shake. Capped by count and age; saved to disk now and then so it survives a crash or relaunch.
final class Timeline: @unchecked Sendable {
    private(set) var maxEvents: Int
    private(set) var maxAge: TimeInterval
    private let storeURL: URL?
    private let clock: () -> Date
    private let lock = NSLock()
    private var events: [TimelineEvent] = []
    private var dirty = false

    init(maxEvents: Int = 5000, maxAge: TimeInterval = 600, storeURL: URL? = nil, clock: @escaping () -> Date = Date.init) {
        self.maxEvents = maxEvents
        self.maxAge = maxAge
        self.storeURL = storeURL
        self.clock = clock
    }

    static func defaultStoreURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mizu/timeline.json")
    }

    /// How far back to keep, e.g. when Claude asks for a longer timeline. Event cap scales with it.
    func setRetention(minutes: Int) {
        lock.lock()
        maxAge = TimeInterval(minutes * 60)
        maxEvents = max(5000, minutes * 500)
        lock.unlock()
    }

    private func now() -> Int64 { Int64(clock().timeIntervalSince1970 * 1000) }

    func record(_ kind: String, _ data: [String: TimelineValue] = [:]) {
        let event = TimelineEvent(t: now(), kind: kind, data: data)
        lock.lock()
        let maxEvents = self.maxEvents
        events.append(event)
        // Trim in chunks so appends stay O(1) amortized.
        if events.count > maxEvents + maxEvents / 10 {
            events.removeFirst(events.count - maxEvents)
        }
        dirty = true
        lock.unlock()
    }

    /// Events from the last `maxAge` seconds, oldest first, at most `maxEvents`.
    func snapshot() -> [TimelineEvent] {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = now() - Int64(maxAge * 1000)
        return Array(events.drop(while: { $0.t < cutoff }).suffix(maxEvents))
    }

    /// The JSON uploaded with a report.
    func encodedSnapshot(extra: [String: TimelineValue] = [:]) -> Data? {
        struct Payload: Encodable {
            let captured_at: Int64
            let span_seconds: Int
            let events: [TimelineEvent]
            let info: [String: TimelineValue]
        }
        let events = snapshot()
        lock.lock()
        let span = Int(maxAge)
        lock.unlock()
        let payload = Payload(captured_at: now(), span_seconds: span, events: events, info: extra)
        return try? JSONEncoder().encode(payload)
    }

    /// Writes recent events to disk if anything changed.
    func persist() {
        guard let storeURL else { return }
        lock.lock()
        let shouldWrite = dirty
        dirty = false
        lock.unlock()
        guard shouldWrite, let data = try? JSONEncoder().encode(snapshot()) else { return }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
    }

    /// Loads what the previous run left behind (if still recent), so a crash-and-relaunch keeps its history.
    func restore() {
        guard let storeURL, let data = try? Data(contentsOf: storeURL),
              let saved = try? JSONDecoder().decode([TimelineEvent].self, from: data) else { return }
        let cutoff = now() - Int64(maxAge * 1000)
        lock.lock()
        events = saved.filter { $0.t >= cutoff } + events
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return events.count
    }
}
