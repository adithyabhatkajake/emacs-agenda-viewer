import Foundation

/// Subscribes to the daemon's SSE event channel (`GET /api/events`) and
/// forwards events to the app via a callback.
///
/// The Express server doesn't expose `/api/events`, so the subscriber treats
/// connection errors as a soft "no daemon" signal — it just stays idle. This
/// lets the same code path run regardless of the configured backend.
@MainActor
final class EventSubscriber {
    private let baseURL: URL
    private var task: Task<Void, Never>?
    private(set) var isConnected: Bool = false

    /// Callback per parsed event. Runs on the main actor so callers can write
    /// directly to `@Observable` state.
    typealias Handler = @MainActor (DaemonEvent) -> Void

    init?(baseURLString: String) {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let url = URL(string: withScheme) else { return nil }
        self.baseURL = url
    }

    /// Start listening. The handler runs on the main actor for each event.
    /// Calling `start` while already running is a no-op.
    func start(handler: @escaping Handler) {
        guard task == nil else { return }
        let url = baseURL.appendingPathComponent("api/events")
        task = Task { [weak self] in
            // Keep reconnecting on disconnect — daemon restarts during dev are
            // expected and shouldn't require a manual re-tap of the toggle.
            while !Task.isCancelled {
                guard let self else { return }
                await self.runOnce(url: url, handler: handler)
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isConnected = false
    }

    private func runOnce(url: URL, handler: @escaping Handler) async {
        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = TimeInterval.infinity
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                self.isConnected = false
                return
            }
            self.isConnected = true
            var currentEvent: String?
            var currentDataLines: [String] = []

            for try await line in bytes.lines {
                if Task.isCancelled { break }
                if line.isEmpty {
                    // Dispatch the buffered event.
                    if !currentDataLines.isEmpty {
                        let payload = currentDataLines.joined(separator: "\n")
                        if let event = DaemonEvent(name: currentEvent ?? "message", payload: payload) {
                            handler(event)
                        }
                    }
                    currentEvent = nil
                    currentDataLines.removeAll(keepingCapacity: true)
                    continue
                }
                if line.hasPrefix(":") { continue } // SSE comment
                if line.hasPrefix("event:") {
                    currentEvent = line.dropFirst("event:".count).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("data:") {
                    let data = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                    currentDataLines.append(String(data))
                }
            }
        } catch {
            self.isConnected = false
        }
    }
}

enum DaemonEvent: Sendable {
    case taskChanged(id: String, file: String, pos: Int)
    case fileChanged(file: String)
    case clockChanged(file: String?, pos: Int?, clocking: Bool)
    case configChanged

    init?(name: String, payload: String) {
        struct Decoded: Decodable {
            let kind: String?
            let id: String?
            let file: String?
            let pos: Int?
            let clocking: Bool?
        }
        guard let data = payload.data(using: .utf8) else { return nil }
        let decoded = (try? JSONDecoder().decode(Decoded.self, from: data)) ?? Decoded(
            kind: name, id: nil, file: nil, pos: nil, clocking: nil
        )
        switch decoded.kind ?? name {
        case "task-changed":
            guard let id = decoded.id, let file = decoded.file, let pos = decoded.pos else { return nil }
            self = .taskChanged(id: id, file: file, pos: pos)
        case "file-changed":
            guard let file = decoded.file else { return nil }
            self = .fileChanged(file: file)
        case "clock-changed":
            self = .clockChanged(file: decoded.file, pos: decoded.pos, clocking: decoded.clocking ?? false)
        case "config-changed":
            self = .configChanged
        default:
            return nil
        }
    }
}
