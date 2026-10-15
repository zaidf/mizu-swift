import Foundation
import ObjectiveC

/// Records every URLSession request's method, host, path, status, size and duration.
///
/// How: it replaces `URLSessionTask.resume` (on the concrete task classes) with a version that notes the task and
/// then calls the original, and observes the task's `state` with KVO. It only watches: it never sits in the data
/// path, so it can't change or break responses, streaming included. Debug builds only, like the rest of Mizu.
///
/// Never recorded: query strings, headers, bodies. Path segments that look like emails, UUIDs or long ids become
/// `:email` / `:uuid` / `:id`, so `/users/jane@x.com/orders/48213` is recorded as `/users/:email/orders/:id`.
final class NetworkObserver: @unchecked Sendable {
    private struct Pending {
        let start: Date
        let observation: NSKeyValueObservation
    }

    private let timeline: Timeline
    private let ignoredHosts: Set<String>
    private let lock = NSLock()
    private var pending: [ObjectIdentifier: Pending] = [:]

    nonisolated(unsafe) static var current: NetworkObserver?
    private static let installLock = NSLock()
    nonisolated(unsafe) private static var installed = false

    init(timeline: Timeline, ignoredHosts: Set<String>) {
        self.timeline = timeline
        self.ignoredHosts = ignoredHosts
    }

    /// Starts observing. The hook is installed once per process; later calls just swap the observer.
    func install() {
        NetworkObserver.current = self
        NetworkObserver.installLock.lock()
        defer { NetworkObserver.installLock.unlock() }
        guard !NetworkObserver.installed else { return }
        NetworkObserver.installed = true
        NetworkObserver.hookResume()
    }

    func willResume(_ task: URLSessionTask) {
        guard let url = task.currentRequest?.url ?? task.originalRequest?.url,
              let host = url.host, !NetworkObserver.isIgnored(host, ignoredHosts),
              url.scheme == "http" || url.scheme == "https" else { return }
        let id = ObjectIdentifier(task)

        lock.lock()
        let alreadyWatching = pending[id] != nil
        lock.unlock()
        guard !alreadyWatching else { return }

        let method = task.currentRequest?.httpMethod ?? "GET"
        let path = NetworkObserver.redactPath(url.path)
        timeline.record("net.start", ["method": .string(method), "host": .string(host), "path": .string(path)])

        let observation = task.observe(\.state, options: [.new]) { [weak self] task, _ in
            guard task.state == .completed else { return }
            self?.didComplete(task, id: id, method: method, host: host, path: path)
        }
        lock.lock()
        pending[id] = Pending(start: Date(), observation: observation)
        lock.unlock()
    }

    private func didComplete(_ task: URLSessionTask, id: ObjectIdentifier, method: String, host: String, path: String) {
        lock.lock()
        let entry = pending.removeValue(forKey: id)
        lock.unlock()
        guard let entry else { return }
        entry.observation.invalidate()

        var data: [String: TimelineValue] = [
            "method": .string(method),
            "host": .string(host),
            "path": .string(path),
            "ms": .int(Int(Date().timeIntervalSince(entry.start) * 1000)),
            "bytes": .int(Int(task.countOfBytesReceived)),
        ]
        if let status = (task.response as? HTTPURLResponse)?.statusCode { data["status"] = .int(status) }
        if let error = task.error as? URLError {
            data["error"] = .string(error.code == .cancelled ? "cancelled" : "URLError \(error.code.rawValue)")
        } else if let error = task.error {
            data["error"] = .string(String(describing: error))
        }
        timeline.record("net.end", data)
    }

    /// Foundation's concrete task classes (e.g. __NSCFLocalDataTask) implement `resume` themselves, so hooking
    /// URLSessionTask alone misses them. Hook every class in a real task's hierarchy that defines `resume`.
    private static func hookResume() {
        let session = URLSession(configuration: .ephemeral)
        let tasks: [URLSessionTask] = [
            session.dataTask(with: URL(string: "https://mizu.invalid")!),
            session.uploadTask(with: URLRequest(url: URL(string: "https://mizu.invalid")!), from: Data()),
            session.downloadTask(with: URL(string: "https://mizu.invalid")!),
        ]
        let selector = #selector(URLSessionTask.resume)
        var hooked = Set<ObjectIdentifier>()

        for task in tasks {
            var cls: AnyClass? = object_getClass(task)
            while let current = cls, current != NSObject.self {
                if !hooked.contains(ObjectIdentifier(current)), definesMethod(current, selector),
                   let method = class_getInstanceMethod(current, selector) {
                    hooked.insert(ObjectIdentifier(current))
                    typealias Resume = @convention(c) (AnyObject, Selector) -> Void
                    let original = unsafeBitCast(method_getImplementation(method), to: Resume.self)
                    let replacement: @convention(block) (AnyObject) -> Void = { object in
                        if let task = object as? URLSessionTask { NetworkObserver.current?.willResume(task) }
                        original(object, selector)
                    }
                    method_setImplementation(method, imp_implementationWithBlock(replacement))
                }
                cls = class_getSuperclass(current)
            }
        }
        session.invalidateAndCancel()
    }

    /// `api.example.com` is ignored by `example.com` (and by itself).
    static func isIgnored(_ host: String, _ ignored: Set<String>) -> Bool {
        let host = host.lowercased()
        return ignored.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func redactPath(_ path: String) -> String {
        guard !path.isEmpty else { return "/" }
        return path.split(separator: "/", omittingEmptySubsequences: false).map { segment -> String in
            let s = String(segment)
            if s.contains("@") { return ":email" }
            if s.range(of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#, options: .regularExpression) != nil {
                return ":uuid"
            }
            // Long numbers, and long tokens mixing letters and digits (hashes, opaque ids). Short ones like "v1" stay.
            if s.range(of: #"^\d{4,}$"#, options: .regularExpression) != nil { return ":id" }
            if s.count >= 16, s.range(of: #"^[A-Za-z0-9_\-=]+$"#, options: .regularExpression) != nil,
               s.rangeOfCharacter(from: .decimalDigits) != nil { return ":id" }
            return s
        }.joined(separator: "/")
    }

    private static func definesMethod(_ cls: AnyClass, _ selector: Selector) -> Bool {
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(cls, &count) else { return false }
        defer { free(methods) }
        return (0..<Int(count)).contains { method_getName(methods[$0]) == selector }
    }
}
