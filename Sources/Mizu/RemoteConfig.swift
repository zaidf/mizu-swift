import Foundation

/// What Claude asked this app to capture (via the `set_capture` / `request_repro` MCP tools).
struct RemoteConfig: Codable, Equatable {
    struct Repro: Codable, Equatable {
        let id: String
        let note: String
    }

    var debug_tags: [String]?
    var timeline_minutes: Int?
    var llm_content: Bool?
    var expires_at: Int64?
    var repro: Repro?

    /// Overrides stop applying once expired (the server does this too; this covers a cached copy read offline).
    func effective(now: Date = Date()) -> RemoteConfig {
        if let expires_at, Int64(now.timeIntervalSince1970 * 1000) >= expires_at {
            return RemoteConfig(repro: repro)
        }
        return self
    }
}

/// Something this install reported (or asked for) that's now fixed in a build it's running.
struct FixedNotice: Codable, Equatable {
    let id: String
    let kind: String          // "report" | "request" (a feature)
    let label: String?        // "FIXED" | "SHIPPED" | "DONE", from the server's kind; older servers don't send it
    let what: String          // what they reported or asked for
    let note: String?         // what was done
    let fixed_in_build: String?
    let reported_at: Int64
}

/// `Mizu.debug` lines are off unless Claude turns their tag on.
final class DebugGate: @unchecked Sendable {
    private let lock = NSLock()
    private var tags: Set<String> = []

    func set(_ tags: [String]) {
        lock.lock()
        self.tags = Set(tags)
        lock.unlock()
    }

    func isOn(_ tag: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tags.contains("*") || tags.contains(tag)
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return tags.sorted()
    }
}

/// Fetches `GET /v1/config`, caches it on disk, and applies it to the timeline, LLM store and debug gate.
final class ConfigClient: @unchecked Sendable {
    private let endpoint: URL
    private let ingestKey: String
    private let session: URLSession
    private let cacheURL: URL?
    private let lock = NSLock()
    private var current = RemoteConfig()
    private var seenRepros: [String] = []
    /// Banner already requested this launch (the developer may not have tapped it yet).
    private var notifiedRepros: Set<String> = []
    /// Last settings applied, so the timeline only notes real changes.
    private var lastApplied: RemoteConfig?

    let debugGate = DebugGate()
    weak var timeline: Timeline?
    weak var llmStore: LLMStore?
    /// What the app chose in `Mizu.Options`, restored when an override is cleared or expires.
    var defaultLLMContent = true
    /// Sent with each check-in so the server knows which fixes this install should hear about.
    var installID: String?
    var build: String?
    /// Called on the main thread for each fix this install hasn't been told about. Returns whether it was shown.
    var onFixed: ((FixedNotice) -> Bool)?
    /// Fixes shown this launch, so a slow acknowledgement never shows one twice.
    private var shownFixes: Set<String> = []

    /// Called on the main thread when a repro request the developer hasn't seen yet arrives.
    /// Returns whether the banner could be shown (not yet, e.g., during launch); if not, the next refresh tries again.
    var onNewRepro: ((RemoteConfig.Repro) -> Bool)?

    init(endpoint: URL, ingestKey: String, session: URLSession = Uploader.makeSession(), cacheURL: URL? = ConfigClient.defaultCacheURL()) {
        self.endpoint = endpoint
        self.ingestKey = ingestKey
        self.session = session
        self.cacheURL = cacheURL
    }

    static func defaultCacheURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mizu/config.json")
    }

    private struct Cache: Codable {
        var config: RemoteConfig
        var seen_repros: [String]
    }

    var config: RemoteConfig {
        lock.lock()
        defer { lock.unlock() }
        return current.effective()
    }

    /// The open repro request the developer has been shown, if any. Reports sent now answer it.
    var activeRepro: RemoteConfig.Repro? {
        lock.lock()
        defer { lock.unlock() }
        guard let repro = current.repro, seenRepros.contains(repro.id) else { return nil }
        return repro
    }

    /// Applies whatever was cached last time, so settings hold even when launching offline.
    func loadCache() {
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        lock.lock()
        current = cache.config
        seenRepros = cache.seen_repros
        lock.unlock()
        apply()
    }

    @discardableResult
    func refresh() async -> Bool {
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/config"))
        request.setValue("Bearer \(ingestKey)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let installID { request.setValue(installID, forHTTPHeaderField: "X-Mizu-Install") }
        if let build { request.setValue(build, forHTTPHeaderField: "X-Mizu-Build") }
        struct Response: Decodable { let config: RemoteConfig; let fixed: [FixedNotice]? }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return false }
        update(decoded.config)
        deliver(decoded.fixed ?? [])
        return true
    }

    /// Shows the first fix not shown yet; the rest wait for the next check-in, one card at a time.
    func deliver(_ fixes: [FixedNotice]) {
        lock.lock()
        let next = fixes.first { !shownFixes.contains($0.id) }
        lock.unlock()
        guard let next else { return }
        DispatchQueue.main.async {
            guard self.onFixed?(next) == true else { return }
            self.lock.lock()
            self.shownFixes.insert(next.id)
            self.lock.unlock()
        }
    }

    /// The person closed the "Fixed" card: tell the server so it isn't shown again.
    func acknowledge(_ notice: FixedNotice) {
        Task { await sendSeen([notice.id]) }
    }

    @discardableResult
    func sendSeen(_ ids: [String]) async -> Bool {
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/notices/seen"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(ingestKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let installID { request.setValue(installID, forHTTPHeaderField: "X-Mizu-Install") }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["ids": ids])
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    func update(_ config: RemoteConfig) {
        lock.lock()
        let changed = config != current
        current = config
        let repro = config.repro
        let isNew = repro.map { !seenRepros.contains($0.id) && !notifiedRepros.contains($0.id) } ?? false
        lock.unlock()

        if changed {
            apply()
            save()
        }
        if let repro, isNew {
            DispatchQueue.main.async {
                guard self.onNewRepro?(repro) == true else { return }
                self.lock.lock()
                self.notifiedRepros.insert(repro.id)
                self.lock.unlock()
            }
        }
    }

    /// The developer saw the banner; reports from now on answer this request.
    func markSeen(_ repro: RemoteConfig.Repro) {
        lock.lock()
        if !seenRepros.contains(repro.id) { seenRepros = Array((seenRepros + [repro.id]).suffix(20)) }
        lock.unlock()
        save()
    }

    /// A report answered the request: stop treating it as open (the server clears it too).
    func answered(_ repro: RemoteConfig.Repro) {
        lock.lock()
        if current.repro?.id == repro.id { current.repro = nil }
        lock.unlock()
        save()
    }

    private func apply() {
        var c = config
        c.repro = nil
        c.expires_at = nil
        lock.lock()
        let same = lastApplied == c
        lastApplied = c
        lock.unlock()
        guard !same else { return }
        debugGate.set(c.debug_tags ?? [])
        timeline?.setRetention(minutes: c.timeline_minutes ?? 10)
        llmStore?.recordContent = c.llm_content ?? defaultLLMContent

        var summary: [String: TimelineValue] = ["timeline_min": .int(c.timeline_minutes ?? 10)]
        if let tags = c.debug_tags, !tags.isEmpty { summary["debug_tags"] = .string(tags.joined(separator: ",")) }
        if let llm = c.llm_content { summary["llm_content"] = .bool(llm) }
        timeline?.record("mizu.config", summary)
    }

    private func save() {
        guard let cacheURL else { return }
        lock.lock()
        let cache = Cache(config: current, seen_repros: seenRepros)
        lock.unlock()
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}
