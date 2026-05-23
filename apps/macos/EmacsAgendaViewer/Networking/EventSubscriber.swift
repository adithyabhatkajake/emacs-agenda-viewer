import Foundation

/// Subscribes to the daemon's SSE event channel (`GET /api/events`) and
/// forwards events to the app via a callback.
///
/// The Express server doesn't expose `/api/events`, so the subscriber treats
/// connection errors as a soft "no daemon" signal — it just stays idle. This
/// lets the same code path run regardless of the configured backend.
///
/// ## SSE fields handled
/// - `event: <name>` — sets the event type for the buffered block.
/// - `data: <text>` — appends a line to the data buffer.
/// - `id: <value>` — stores the last-event-ID; sent as `Last-Event-ID` on reconnect.
/// - `retry: <ms>` — sets the minimum backoff floor for the next reconnect (integer ms).
/// - `:` prefix — comment line, ignored.
/// - blank line — dispatches the buffered event. Fires when either a name was set OR
///   data is present, so name-only events like `event: ping\n\n` are not silently dropped.
///
/// ## Backoff
/// Reconnect delay starts at 1 s, doubles each failed attempt, caps at 30 s,
/// with ±20 % random jitter. A successful connection that stays up for ≥ 30 s
/// resets the attempt counter. The `retry:` SSE field sets the floor for the
/// delay after the connection on which it was received.
@MainActor
final class EventSubscriber {
    private let baseURL: URL
    private var task: Task<Void, Never>?
    private(set) var isConnected: Bool = false

    // Dedicated session so we never mutate URLSession.shared.
    // 5-minute request timeout: long enough to avoid spurious drops on idle
    // SSE streams during normal health-check intervals, short enough that a
    // fully-hung TCP connection eventually releases the Task.
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = .infinity
        return URLSession(configuration: cfg)
    }()

    // SSE reconnect state — persisted across runOnce calls.
    private var lastEventID: String?
    // retryHintMs is set by the server via `retry:` fields. nil means use pure backoff.
    private var retryHintMs: Int?
    private var failedAttempts: Int = 0

    /// Callback per parsed event. Runs on the main actor for each event.
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
            while !Task.isCancelled {
                guard let self else { return }

                let delay = EventSubscriber.backoffDelay(
                    attempt: self.failedAttempts,
                    retryHintMs: self.retryHintMs
                )
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    if Task.isCancelled { break }
                }

                let connectTime = Date()
                let result = await self.runOnce(url: url, handler: handler)

                switch result {
                case .success:
                    let uptime = Date().timeIntervalSince(connectTime)
                    // Reset backoff if the connection stayed healthy for a while.
                    if uptime >= 30 {
                        self.failedAttempts = 0
                        self.retryHintMs = nil
                    } else {
                        self.failedAttempts += 1
                    }
                case .failure:
                    self.failedAttempts += 1
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isConnected = false
    }

    // MARK: - Backoff

    /// Exponential backoff with ±20 % jitter.
    ///
    /// - Parameters:
    ///   - attempt: Number of consecutive failed/short-lived attempts so far.
    ///   - retryHintMs: Server-supplied `retry:` value in milliseconds, or nil.
    /// - Returns: Seconds to wait before the next connect attempt. 0 on the
    ///   first attempt (attempt == 0) unless retryHintMs raises the floor.
    nonisolated static func backoffDelay(attempt: Int, retryHintMs: Int?) -> TimeInterval {
        guard attempt > 0 else {
            // First attempt: honour a server retry hint if present.
            if let hint = retryHintMs {
                return applyJitter(Double(hint) / 1000.0)
            }
            return 0
        }
        let base: Double = 1.0
        let cap: Double = 30.0
        let exponential = min(base * pow(2.0, Double(attempt - 1)), cap)
        let floor = retryHintMs.map { Double($0) / 1000.0 } ?? 0
        return applyJitter(max(exponential, floor))
    }

    nonisolated private static func applyJitter(_ seconds: TimeInterval) -> TimeInterval {
        let jitter = seconds * 0.2 * (Double.random(in: 0 ..< 1) * 2 - 1)
        return max(0, seconds + jitter)
    }

    // MARK: - Single connection run

    private enum RunResult { case success, failure }

    private func runOnce(url: URL, handler: @escaping Handler) async -> RunResult {
        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let eid = lastEventID {
            request.setValue(eid, forHTTPHeaderField: "Last-Event-ID")
        }

        do {
            let (bytes, response) = try await EventSubscriber.session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                self.isConnected = false
                return .failure
            }
            self.isConnected = true

            var parser = SSEParser()
            for try await line in bytes.lines {
                if Task.isCancelled { break }
                if let (name, payload, eventID, retryMs) = parser.feed(line) {
                    if let id = eventID { lastEventID = id }
                    if let ms = retryMs { retryHintMs = ms }
                    if let event = DaemonEvent(name: name, payload: payload) {
                        handler(event)
                    }
                }
            }
            self.isConnected = false
            return .success
        } catch {
            self.isConnected = false
            return .failure
        }
    }
}

// MARK: - SSEParser

/// Stateful line-by-line SSE parser. Shared between the live subscriber and tests.
///
/// Call `feed(_:)` with each text line (without line terminator). On a blank line
/// (the SSE dispatch signal), returns a tuple `(eventName, payload, lastEventID, retryMs)`.
/// Returns nil for non-dispatch lines.
///
/// The returned `lastEventID` is non-nil only when an `id:` field was seen in
/// the current block. `retryMs` is non-nil only when a `retry:` field was seen.
struct SSEParser {
    private var currentEvent: String?
    private var currentDataLines: [String] = []
    private var pendingID: String?
    private var pendingRetryMs: Int?

    /// Feed one line to the parser.
    /// - Returns: `(eventName, payload, idToStore, retryMsToStore)` when a blank
    ///   line triggers dispatch; `nil` otherwise.
    mutating func feed(_ line: String) -> (String, String, String?, Int?)? {
        if line.isEmpty {
            // Dispatch when we have a name OR data (not just data).
            // This handles name-only events like `event: ping\n\n`.
            guard currentEvent != nil || !currentDataLines.isEmpty else {
                // No content at all — reset any accumulated id/retry and continue.
                pendingID = nil
                pendingRetryMs = nil
                return nil
            }
            let name = currentEvent ?? "message"
            let payload = currentDataLines.joined(separator: "\n")
            let id = pendingID
            let retry = pendingRetryMs

            currentEvent = nil
            currentDataLines.removeAll(keepingCapacity: true)
            pendingID = nil
            pendingRetryMs = nil

            return (name, payload, id, retry)
        }

        if line.hasPrefix(":") { return nil } // comment

        if line.hasPrefix("event:") {
            currentEvent = String(line.dropFirst("event:".count).trimmingCharacters(in: .whitespaces))
        } else if line.hasPrefix("data:") {
            currentDataLines.append(String(line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)))
        } else if line.hasPrefix("id:") {
            let value = String(line.dropFirst("id:".count).trimmingCharacters(in: .whitespaces))
            // SSE spec: empty id clears last-event-id (represented as nil).
            pendingID = value.isEmpty ? nil : value
        } else if line.hasPrefix("retry:") {
            let value = String(line.dropFirst("retry:".count).trimmingCharacters(in: .whitespaces))
            if let ms = Int(value), ms >= 0 {
                pendingRetryMs = ms
            }
        }
        return nil
    }
}

// MARK: - DaemonEvent

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
        // Empty payload is valid for name-only events like config-changed.
        let data = payload.data(using: .utf8) ?? Data()
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
