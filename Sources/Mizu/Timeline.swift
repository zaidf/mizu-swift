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

/// The black box: always recording, cheaply, so the history you need already exists when you shake.
///
/// Two layers:
/// - in memory, the last few minutes (`maxAge`, at most `maxEvents`), for quick looks and tests;
/// - on disk, one append-only file per hour (`timeline/<hour start ms>.ndjson`), kept for `retention` (7 days by
///   default). `persist()` appends what's new every few seconds, so saving stays cheap however long the history is.
///
/// A report uploads the hourly files compressed (`uploadParts()`); without a store it falls back to the in-memory
/// window as one JSON part, the format servers have always read.
final class Timeline: @unchecked Sendable {
    static let defaultRetention: TimeInterval = 7 * 24 * 3600
    /// Keeps a report's upload reasonable even after a very busy week; the oldest hours go first.
    static let maxUploadBytes = 20 * 1024 * 1024

    private(set) var maxEvents: Int
    private(set) var maxAge: TimeInterval
    private(set) var retention: TimeInterval
    private let storeDirectory: URL?
    private let clock: () -> Date
    private let lock = NSLock()
    private let diskLock = NSLock()
    private var events: [TimelineEvent] = []
    private var unsaved: [TimelineEvent] = []

    init(maxEvents: Int = 5000, maxAge: TimeInterval = 600, retention: TimeInterval = Timeline.defaultRetention,
         storeDirectory: URL? = nil, clock: @escaping () -> Date = Date.init) {
        self.maxEvents = maxEvents
        self.maxAge = maxAge
        self.retention = retention
        self.storeDirectory = storeDirectory
        self.clock = clock
    }

    static func defaultStoreDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mizu/timeline", isDirectory: true)
    }

    /// Where SDK 0.4 and earlier kept the last few minutes; its events are moved into the hourly files once.
    static func legacyStoreURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mizu/timeline.json")
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
        if storeDirectory != nil { unsaved.append(event) }
        lock.unlock()
    }

    /// Events from the last `maxAge` seconds in memory, oldest first, at most `maxEvents`.
    func snapshot() -> [TimelineEvent] {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = now() - Int64(maxAge * 1000)
        return Array(events.drop(while: { $0.t < cutoff }).suffix(maxEvents))
    }

    /// The in-memory window as one JSON document (the original upload format).
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

    // MARK: disk

    private static func hourStart(_ t: Int64) -> Int64 { t - ((t % 3_600_000) + 3_600_000) % 3_600_000 }

    /// The hourly files on disk, oldest first.
    func segmentFiles() -> [(start: Int64, url: URL)] {
        guard let storeDirectory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: storeDirectory.path) else { return [] }
        return names.compactMap { name -> (Int64, URL)? in
            guard name.hasSuffix(".ndjson"), let start = Int64(name.dropLast(".ndjson".count)) else { return nil }
            return (start, storeDirectory.appendingPathComponent(name))
        }
        .sorted { $0.0 < $1.0 }
    }

    /// Appends new events to their hour's file and drops files older than `retention`.
    func persist() {
        guard let storeDirectory else { return }
        lock.lock()
        let pending = unsaved
        unsaved.removeAll(keepingCapacity: true)
        lock.unlock()

        diskLock.lock()
        defer { diskLock.unlock() }
        let fm = FileManager.default
        try? fm.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        if !pending.isEmpty {
            let encoder = JSONEncoder()
            var byHour: [Int64: Data] = [:]
            for event in pending {
                guard var line = try? encoder.encode(event) else { continue }
                line.append(0x0A)
                byHour[Self.hourStart(event.t), default: Data()].append(line)
            }
            for (hour, data) in byHour {
                let url = storeDirectory.appendingPathComponent("\(hour).ndjson")
                if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
                if let handle = try? FileHandle(forWritingTo: url) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }
            }
        }
        let oldest = Self.hourStart(now() - Int64(retention * 1000))
        for file in segmentFiles() where file.start < oldest { try? fm.removeItem(at: file.url) }
    }

    /// After a relaunch: moves an SDK 0.4 file into the hourly files, then loads the last few minutes into memory.
    func restore(legacyURL: URL? = nil) {
        if let legacyURL, let data = try? Data(contentsOf: legacyURL),
           let saved = try? JSONDecoder().decode([TimelineEvent].self, from: data) {
            lock.lock()
            unsaved = saved + unsaved
            lock.unlock()
            persist()
            try? FileManager.default.removeItem(at: legacyURL)
        }
        let cutoff = now() - Int64(maxAge * 1000)
        var recent: [TimelineEvent] = []
        for file in segmentFiles().suffix(2) where file.start + 3_600_000 >= cutoff {
            recent += Self.readEvents(file.url).filter { $0.t >= cutoff }
        }
        lock.lock()
        events = Array((recent + events).suffix(maxEvents))
        lock.unlock()
    }

    static func readEvents(_ url: URL) -> [TimelineEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(TimelineEvent.self, from: Data($0)) }
    }

    /// What a report uploads: the hourly files (compressed), plus a small info part. Saves first, so it's current.
    /// Without a store (or if nothing's on disk yet) it's the in-memory window as one JSON part, as before.
    func uploadParts(extra: [String: TimelineValue] = [:]) -> [OutboxPart] {
        persist()
        diskLock.lock()
        let files = segmentFiles()
        var segments: [OutboxPart] = []
        var total = 0
        var dropped = 0
        for file in files.reversed() {  // newest first, so a very busy week loses its oldest hours
            guard let raw = try? Data(contentsOf: file.url), !raw.isEmpty else { continue }
            guard let packed = try? (raw as NSData).compressed(using: .zlib) as Data else { continue }
            if total + packed.count > Self.maxUploadBytes { dropped += 1; continue }
            total += packed.count
            segments.append(OutboxPart(name: "timeline_segment:\(file.start).ndjson.deflate", contentType: "application/octet-stream", data: packed))
        }
        diskLock.unlock()
        guard !segments.isEmpty else {
            return encodedSnapshot(extra: extra).map { [OutboxPart(name: "timeline", contentType: "application/json", data: $0)] } ?? []
        }
        struct Info: Encodable {
            let format = 2
            let captured_at: Int64
            let retention_seconds: Int
            let tz_offset_minutes: Int
            let hours_left_out: Int
            let info: [String: TimelineValue]
        }
        let info = Info(captured_at: now(), retention_seconds: Int(retention), tz_offset_minutes: TimeZone.current.secondsFromGMT() / 60,
                        hours_left_out: dropped, info: extra)
        guard let infoData = try? JSONEncoder().encode(info) else { return [] }
        return [OutboxPart(name: "timeline_info", contentType: "application/json", data: infoData)] + segments.reversed()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return events.count
    }
}
