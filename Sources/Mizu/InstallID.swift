import Foundation

/// An anonymous id for this install of the app, kept on the device. It ties reports and feature requests to the
/// install that sent them, so that install can hear when they're fixed. Not tied to a person or a device id;
/// deleting the app resets it.
enum InstallID {
    static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mizu/install-id")
    }

    static func load(at url: URL = defaultURL()) -> String {
        if let saved = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           saved.count >= 16 {
            return saved
        }
        let id = UUID().uuidString.lowercased()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? id.write(to: url, atomically: true, encoding: .utf8)
        return id
    }
}
