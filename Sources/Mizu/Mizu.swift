import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif

/// Shake your phone, Claude sees what happened.
///
///     Mizu.start(key: "mizu_ik_…")
///
/// Only runs in DEBUG builds unless `Options.enableInRelease` is set.
public enum Mizu {
    public struct Options {
        public var endpoint = URL(string: "https://mizu.dance")!
        /// Shaking the device opens the report sheet.
        public var shakeToReport = true
        /// iOS shows "Undo Typing" on shake by default, which fights the report sheet. Turned off while Mizu runs.
        public var disableShakeToUndo = true
        /// Mizu is meant for your own debug builds. Set this only if you really want it in TestFlight/App Store builds.
        public var enableInRelease = false
        /// Keep a rolling timeline (screens, taps, keyboard, network, logs) and attach it to reports.
        public var recordTimeline = true
        /// Keep full prompts and responses of `Mizu.llm` calls. Off records only model, timing and token counts.
        public var recordLLMContent = true

        public init() {}
    }

    /// Overrides the auto-detected screen name sent with reports, e.g. `Mizu.screenName = "ChatView"`.
    public static var screenName: String?

    public static var isRunning: Bool { client != nil }

    static var client: MizuClient?
    static var options = Options()
    static var timeline: Timeline?
    static var llmStore: LLMStore?
    static var configClient: ConfigClient?
    private static var networkObserver: NetworkObserver?
    private static var persistTimer: Timer?

    @MainActor
    public static func start(key: String, options: Options = Options()) {
        #if !DEBUG
        guard options.enableInRelease else { return }
        #endif
        guard client == nil else { return }
        guard key.hasPrefix("mizu_ik_") else {
            if key.hasPrefix("mizu_sk_") {
                MizuLog.warn("That's your secret account token. Apps get an ingest key (mizu_ik_…). Mizu did not start.")
            } else {
                MizuLog.warn("Expected an ingest key starting with mizu_ik_. Mizu did not start.")
            }
            return
        }
        self.options = options
        client = MizuClient(key: key, endpoint: options.endpoint)

        if options.recordTimeline {
            let timeline = Timeline(storeURL: Timeline.defaultStoreURL())
            timeline.restore()
            var launch = DeviceInfo.appMeta().compactMapValues { $0 as? String }.mapValues(TimelineValue.string)
            launch["pid"] = .int(Int(ProcessInfo.processInfo.processIdentifier))
            timeline.record("app.launch", launch)
            self.timeline = timeline

            let network = NetworkObserver(timeline: timeline, ignoredHost: options.endpoint.host)
            network.install()
            networkObserver = network

            let llm = LLMStore(timeline: timeline, recordContent: options.recordLLMContent, storeURL: LLMStore.defaultStoreURL())
            llm.restore()
            llmStore = llm

            #if canImport(UIKit)
            UIKitObserver(timeline: timeline).install()
            #endif

            persistTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in Mizu.persistAll() }
        }

        // What Claude asked this app to capture: cached copy now, fresh copy as soon as the network allows.
        let config = ConfigClient(endpoint: options.endpoint, ingestKey: key)
        config.timeline = timeline
        config.llmStore = llmStore
        config.defaultLLMContent = options.recordLLMContent
        #if canImport(UIKit)
        config.onNewRepro = { repro in
            MainActor.assumeIsolated { ReproBanner.show(repro) }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
            Task { await config.refresh() }
        }
        #else
        config.onNewRepro = { _ in false }
        #endif
        config.loadCache()
        configClient = config
        Task { await config.refresh() }

        #if canImport(UIKit)
        if options.disableShakeToUndo && options.shakeToReport {
            UIApplication.shared.applicationSupportsShakeToEdit = false
        }
        #endif
    }

    /// A breadcrumb that's off until Claude turns its tag on (MCP `set_capture` with `debug_tags`), so you can leave
    /// detailed logging in your code and pay nothing for it until a bug needs it. No rebuild required.
    ///
    ///     Mizu.debug("history before send", tag: "context", data: ["count": history.count])
    public static func debug(_ message: @autoclosure () -> String, tag: String, data: @autoclosure () -> [String: Any] = [:]) {
        guard let timeline, configClient?.debugGate.isOn(tag) == true else { return }
        var fields = data().mapValues(TimelineValue.init)
        fields["message"] = .string(String(message().prefix(4000)))
        fields["tag"] = .string(tag)
        timeline.record("debug", fields)
    }

    /// Adds a line to the timeline. Cheap; call it wherever you'd use print.
    ///
    ///     Mizu.log("built context", tag: "llm", data: ["messages": 12, "tokens": 3400])
    public static func log(_ message: String, tag: String? = nil, data: [String: Any] = [:]) {
        guard let timeline else { return }
        var fields = data.mapValues(TimelineValue.init)
        fields["message"] = .string(String(message.prefix(2000)))
        if let tag { fields["tag"] = .string(tag) }
        timeline.record("log", fields)
    }

    /// Starts recording one LLM call: exactly what your app is sending. Finish it with `call.finish(output:)`.
    ///
    ///     let call = Mizu.llm(model: "claude-sonnet-5-5", system: systemPrompt, messages: history)
    ///     call.firstToken()                       // when streaming starts (optional)
    ///     call.finish(output: reply, inputTokens: 1200, outputTokens: 300)
    ///
    /// Safe to call when Mizu isn't running: you get a call object that does nothing.
    public static func llm(model: String, system: String? = nil, messages: [LLMMessage], tools: [String] = [],
                           params: [String: Any] = [:]) -> LLMCall {
        guard let llmStore else { return LLMCall(id: "c0", store: nil) }
        return llmStore.start(model: model, system: system, messages: messages, tools: tools, params: params.mapValues(TimelineValue.init))
    }

    /// Wraps an LLM request so it's recorded even when it throws.
    ///
    ///     let reply = try await Mizu.traceLLM(model: model, messages: history, output: { $0.text }) {
    ///         try await client.messages.create(...)
    ///     }
    public static func traceLLM<T>(model: String, system: String? = nil, messages: [LLMMessage], tools: [String] = [],
                                   params: [String: Any] = [:], output: (T) -> String,
                                   _ run: () async throws -> T) async rethrows -> T {
        let call = llm(model: model, system: system, messages: messages, tools: tools, params: params)
        do {
            let result = try await run()
            call.finish(output: output(result))
            return result
        } catch {
            call.fail(error)
            throw error
        }
    }

    static func persistAll() {
        timeline?.persist()
        llmStore?.persist()
    }

    /// Marks that a screen appeared. `.mizuScreen("Chat")` in SwiftUI calls this for you.
    public static func screen(_ name: String) {
        #if canImport(UIKit)
        if Thread.isMainThread {
            MainActor.assumeIsolated { UIKitObserver.current?.screenAppeared(name, source: "app") }
            return
        }
        #endif
        timeline?.record("screen", ["name": .string(name), "via": "app"])
    }

    /// Sends a report without the sheet. Saved to disk first, uploaded when the network allows.
    public static func report(note: String? = nil, screenshot: Data? = nil, screenshotType: String = "image/jpeg") {
        var parts = contextParts(trigger: "api")
        if let screenshot { parts.append(OutboxPart(name: "screenshot", contentType: screenshotType, data: screenshot)) }
        report(note: note, screen: currentScreen(), parts: parts)
    }

    /// Best guess at what screen the developer is looking at.
    static func currentScreen() -> String? {
        if let screenName { return screenName }
        #if canImport(UIKit)
        if Thread.isMainThread {
            return MainActor.assumeIsolated { UIKitObserver.current?.currentScreen }
        }
        #endif
        return nil
    }

    /// What was going on just now: the timeline and recent LLM calls. Captured the moment a report starts.
    static func contextParts(trigger: String) -> [OutboxPart] {
        var parts: [OutboxPart] = []
        if let timeline {
            timeline.record("mizu.report", ["trigger": .string(trigger)])
            if let data = timeline.encodedSnapshot() {
                parts.append(OutboxPart(name: "timeline", contentType: "application/json", data: data))
            }
        }
        if let data = llmStore?.encodedSnapshot() {
            parts.append(OutboxPart(name: "llm", contentType: "application/json", data: data))
        }
        return parts
    }

    static func report(note: String?, screen: String?, parts: [OutboxPart]) {
        guard let client else {
            MizuLog.warn("Mizu.report called before Mizu.start; ignoring.")
            return
        }
        var meta = DeviceInfo.appMeta()
        if let note, !note.isEmpty { meta["note"] = note }
        if let screen { meta["screen"] = screen }
        if let repro = configClient?.activeRepro {
            meta["repro_id"] = repro.id
            configClient?.answered(repro)
        }
        client.send(meta: meta, parts: parts)
    }

    #if canImport(UIKit)
    /// Opens the report sheet, same as shaking.
    @MainActor
    public static func showReporter() {
        guard isRunning else { return }
        ReporterPresenter.present()
    }
    #endif
}

/// Owns the outbox and uploader, and decides when to try sending.
final class MizuClient: @unchecked Sendable {
    let outbox: Outbox
    let uploader: Uploader
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dance.mizu.client")
    private var retryDelay: TimeInterval = 5
    private var retryWork: DispatchWorkItem?

    init(key: String, endpoint: URL, outbox: Outbox = Outbox(root: Outbox.defaultRoot())) {
        self.outbox = outbox
        self.uploader = Uploader(endpoint: endpoint, ingestKey: key, outbox: outbox)

        monitor.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied { self?.flushSoon() }
        }
        monitor.start(queue: queue)

        #if canImport(UIKit)
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            self?.flushSoon()
        }
        #endif

        // Anything left over from last launch.
        flushSoon()
    }

    func send(meta: [String: Any], parts: [OutboxPart], path: String = "v1/reports") {
        do {
            try outbox.enqueue(meta: meta, parts: parts, path: path)
        } catch {
            MizuLog.warn("Could not save report: \(error)")
            return
        }
        flushSoon()
    }

    func flushSoon() {
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.uploader.flush()
            self.queue.async { self.handle(outcome) }
        }
    }

    /// Backs off 5s, 15s, 45s… up to 5 minutes while the network or server is unhappy.
    private func handle(_ outcome: Uploader.Outcome) {
        retryWork?.cancel()
        switch outcome {
        case .drained:
            retryDelay = 5
        case .retryLater:
            let work = DispatchWorkItem { [weak self] in self?.flushSoon() }
            retryWork = work
            queue.asyncAfter(deadline: .now() + retryDelay, execute: work)
            retryDelay = min(retryDelay * 3, 300)
        }
    }
}
