import Foundation

/// One file attached to a report, uploaded as a multipart field: screenshot, timeline, audio, llm…
struct OutboxPart: Equatable {
    let name: String
    let contentType: String
    let data: Data

    /// Multipart field: attachments share one field, "attachment", each with its own file name.
    var fieldName: String { name.hasPrefix("attachment:") ? "attachment" : name }

    var filename: String {
        if name.hasPrefix("attachment:") { return String(name.dropFirst("attachment:".count)) }
        switch contentType {
        case "image/jpeg": return "\(name).jpg"
        case "image/png": return "\(name).png"
        case "application/json": return "\(name).json"
        case "audio/wav": return "\(name).wav"
        default: return name
        }
    }
}

/// A report waiting to be uploaded. Lives on disk until the server confirms it, so nothing is lost
/// to a dead network, a killed app, or a reboot.
struct OutboxItem: Equatable {
    /// Also sent as `client_id`, so a retried upload never creates a duplicate report.
    let id: String
    let directory: URL
    let meta: Data
    let parts: [OutboxPart]
    /// Where it goes: `v1/reports` (multipart) or another endpoint that takes `meta` as a JSON body.
    let path: String

    func part(_ name: String) -> OutboxPart? { parts.first { $0.name == name } }
}

/// File-backed queue: one folder per report, named `<millis>-<id>` so listing sorts oldest first.
/// Inside: `meta.json`, plus `part-<name>` and `part-<name>.type` for each attachment.
final class Outbox: @unchecked Sendable {
    let root: URL
    private let fileManager = FileManager.default
    private let lock = NSLock()

    init(root: URL) {
        self.root = root
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Mizu/outbox", isDirectory: true)
    }

    /// Writes the report to a temp folder first and moves it into place, so a half-written item is never uploaded.
    @discardableResult
    func enqueue(meta: [String: Any], parts: [OutboxPart] = [], path: String = "v1/reports") throws -> String {
        let id = UUID().uuidString.lowercased()
        var meta = meta
        meta["client_id"] = id
        let metaData = try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys])

        let millis = Int(Date().timeIntervalSince1970 * 1000)
        let name = "\(millis)-\(id)"
        let staging = root.appendingPathComponent(".staging-\(name)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try metaData.write(to: staging.appendingPathComponent("meta.json"))
        if path != "v1/reports" { try Data(path.utf8).write(to: staging.appendingPathComponent("path.txt")) }
        for part in parts {
            try part.data.write(to: staging.appendingPathComponent("part-\(part.name)"))
            try Data(part.contentType.utf8).write(to: staging.appendingPathComponent("part-\(part.name).type"))
        }

        lock.lock()
        defer { lock.unlock() }
        try fileManager.moveItem(at: staging, to: root.appendingPathComponent(name, isDirectory: true))
        return id
    }

    /// Pending reports, oldest first.
    func pending() -> [OutboxItem] {
        lock.lock()
        defer { lock.unlock() }
        let names = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        return names
            .filter { !$0.hasPrefix(".") }
            .sorted()
            .compactMap { name in
                let dir = root.appendingPathComponent(name, isDirectory: true)
                guard let meta = try? Data(contentsOf: dir.appendingPathComponent("meta.json")) else { return nil }
                let id = String(name.split(separator: "-", maxSplits: 1).last ?? Substring(name))
                let files = (try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? []
                let parts: [OutboxPart] = files
                    .filter { $0.hasPrefix("part-") && !$0.hasSuffix(".type") }
                    .sorted()
                    .compactMap { file in
                        guard let data = try? Data(contentsOf: dir.appendingPathComponent(file)) else { return nil }
                        let type = (try? Data(contentsOf: dir.appendingPathComponent(file + ".type")))
                            .flatMap { String(data: $0, encoding: .utf8) } ?? "application/octet-stream"
                        return OutboxPart(name: String(file.dropFirst("part-".count)), contentType: type, data: data)
                    }
                let path = (try? Data(contentsOf: dir.appendingPathComponent("path.txt"))).flatMap { String(data: $0, encoding: .utf8) } ?? "v1/reports"
                return OutboxItem(id: id, directory: dir, meta: meta, parts: parts, path: path)
            }
    }

    func remove(_ item: OutboxItem) {
        lock.lock()
        defer { lock.unlock() }
        try? fileManager.removeItem(at: item.directory)
    }
}
