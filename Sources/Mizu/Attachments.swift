import Foundation

/// A file sent with a report: a log, a pipeline dump, anything you used to put in a debug zip.
/// Claude reads text attachments a page or a search at a time with `get_attachment`, so big logs are fine.
public struct MizuAttachment: Equatable, Sendable {
    public var name: String
    public var data: Data
    public var contentType: String

    public init(name: String, data: Data, contentType: String = "application/octet-stream") {
        self.name = name
        self.data = data
        self.contentType = contentType
    }

    /// A text file, e.g. `MizuAttachment(name: "pipeline.log", text: log)`.
    public init(name: String, text: String) {
        self.init(name: name, data: Data(text.utf8), contentType: name.hasSuffix(".json") ? "application/json" : "text/plain")
    }

    /// Anything `Encodable`, as pretty-printed JSON, e.g. `MizuAttachment(name: "turn.json", json: turnState)`.
    public init<T: Encodable>(name: String, json value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.init(name: name, data: try encoder.encode(value), contentType: "application/json")
    }

    /// A file on disk. Returns nil if it can't be read.
    public init?(fileURL: URL, name: String? = nil) {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        self.init(name: name ?? fileURL.lastPathComponent, data: data, contentType: Self.contentType(for: fileURL.pathExtension))
    }

    static func contentType(for ext: String) -> String {
        switch ext.lowercased() {
        case "txt", "log": return "text/plain"
        case "json": return "application/json"
        case "jsonl", "ndjson": return "application/x-ndjson"
        case "csv": return "text/csv"
        case "md": return "text/markdown"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }

    static let maxFiles = 20
    static let maxFileBytes = 10 * 1024 * 1024
    static let maxTotalBytes = 25 * 1024 * 1024

    /// Keeps what fits the server's limits (20 files, 10 MB each, 25 MB total), in order; returns what was dropped.
    static func fitting(_ attachments: [MizuAttachment]) -> (kept: [MizuAttachment], dropped: [String]) {
        var kept: [MizuAttachment] = []
        var dropped: [String] = []
        var total = 0
        for a in attachments {
            if kept.count >= maxFiles || a.data.count > maxFileBytes || total + a.data.count > maxTotalBytes {
                dropped.append(a.name)
            } else {
                kept.append(a)
                total += a.data.count
            }
        }
        return (kept, dropped)
    }

    /// Outbox part for this attachment. The part name carries the file name: `attachment:<name>`.
    var outboxPart: OutboxPart {
        OutboxPart(name: "attachment:" + Self.safe(name), contentType: contentType, data: data)
    }

    /// File-system and header safe; the server makes its own safe name too.
    static func safe(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? "file" : String(trimmed.prefix(100))
    }
}
