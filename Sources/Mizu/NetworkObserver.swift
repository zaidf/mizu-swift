import Foundation
import ObjectiveC

/// Records every URLSession request's method, host, path, status, size and duration.
///
/// It only watches: it hooks `resume()` and observes the task's `state`, so it never sits in the data path
/// and can't break streaming responses. Query strings and bodies are never recorded (they carry keys and user data).
final class NetworkObserver: @unchecked Sendable {
    private struct Pending {
        let start: Date
        let observation: NSKeyValueObservation
    }

    private let timeline: Timeline
    private let ignoredHost: String?
    private let lock = NSLock()
    private var pending: [ObjectIdentifier: Pending] = [:]

    nonisolated(unsafe) static var current: NetworkObserver?
    private static let installLock = NSLock()
    nonisolated(unsafe) private static var installed = false

    init(timeline: Timeline, ignoredHost: String?) {
        self.timeline = timeline
        self.ignoredHost = ignoredHost
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
              let host = url.host, host != ignoredHost,
              url.scheme == "http" || url.scheme == "https" else { return }
        let id = ObjectIdentifier(task)

        lock.lock()
        let alreadyWatching = pending[id] != nil
        lock.unlock()
        guard !alreadyWatching else { return }

        let method = task.currentRequest?.httpMethod ?? "GET"
        let path = url.path.isEmpty ? "/" : url.path
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

    private static func definesMethod(_ cls: AnyClass, _ selector: Selector) -> Bool {
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(cls, &count) else { return false }
        defer { free(methods) }
        return (0..<Int(count)).contains { method_getName(methods[$0]) == selector }
    }
}
