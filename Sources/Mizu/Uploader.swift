import Foundation

/// Drains the outbox to `POST /v1/reports`, oldest first.
actor Uploader {
    enum Outcome: Equatable {
        /// Everything that was pending is sent (or dropped as unsendable).
        case drained(sent: Int)
        /// Network or server trouble; try again later. Items stay on disk.
        case retryLater(sent: Int)
    }

    private let endpoint: URL
    private let ingestKey: String
    private let outbox: Outbox
    private let session: URLSession
    private var inFlight: Task<Outcome, Never>?

    init(endpoint: URL, ingestKey: String, outbox: Outbox, session: URLSession = Uploader.makeSession()) {
        self.endpoint = endpoint
        self.ingestKey = ingestKey
        self.outbox = outbox
        self.session = session
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = true
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 60
        return URLSession(configuration: config)
    }

    /// Concurrent callers share one pass, so the same item is never uploaded twice at once.
    func flush() async -> Outcome {
        if let inFlight { return await inFlight.value }
        let task = Task { await drain() }
        inFlight = task
        let outcome = await task.value
        inFlight = nil
        return outcome
    }

    private func drain() async -> Outcome {
        var sent = 0
        for item in outbox.pending() {
            var request = URLRequest(url: endpoint.appendingPathComponent(item.path))
            request.httpMethod = "POST"
            request.setValue("Bearer \(ingestKey)", forHTTPHeaderField: "Authorization")

            let body: Data
            if item.path == "v1/reports" {
                var form = Multipart()
                form.addField("meta", value: item.meta)
                for part in item.parts {
                    form.addFile(part.fieldName, filename: part.filename, contentType: part.contentType, data: part.data)
                }
                request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
                body = form.finish()
            } else {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                body = item.meta
            }

            let status: Int
            do {
                let (_, response) = try await session.upload(for: request, from: body)
                status = (response as? HTTPURLResponse)?.statusCode ?? 0
            } catch {
                return .retryLater(sent: sent)
            }

            switch status {
            case 200..<300:
                outbox.remove(item)
                sent += 1
            case 401, 403, 408, 429, 500...:
                // A bad key keeps reports on disk too: once the key is fixed they all go through.
                return .retryLater(sent: sent)
            default:
                // Other 4xx means this item will never succeed (too big, malformed). Drop it rather than block the queue.
                MizuLog.warn("Report \(item.id) rejected with HTTP \(status); dropping it.")
                outbox.remove(item)
            }
        }
        return .drained(sent: sent)
    }
}

enum MizuLog {
    static func warn(_ message: String) {
        #if DEBUG
        print("[Mizu] \(message)")
        #endif
    }
}
