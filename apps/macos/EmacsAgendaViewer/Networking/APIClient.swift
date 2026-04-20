import Foundation

enum APIError: LocalizedError {
    case noServerURL
    case invalidURL
    case badStatus(Int, body: String?)
    case decoding(Error)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .noServerURL:
            return "Server URL not configured. Open Settings to set it."
        case .invalidURL:
            return "Server URL is invalid."
        case .badStatus(let code, let body):
            return "Server returned \(code)\(body.map { ": \($0)" } ?? "")"
        case .decoding(let err):
            return "Failed to decode response: \(err.localizedDescription)"
        case .transport(let err):
            return "Network error: \(err.localizedDescription)"
        }
    }
}

struct APIClient {
    let baseURL: URL

    init?(baseURLString: String) {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let url = URL(string: withScheme) else { return nil }
        self.baseURL = url
    }

    private func makeURL(path: String, query: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        // Preserve any percent-encoding the caller already applied (e.g. encoded task IDs).
        let basePath = components.percentEncodedPath
        let joiner = (basePath.hasSuffix("/") || path.hasPrefix("/")) ? "" : "/"
        components.percentEncodedPath = basePath + joiner + path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw APIError.invalidURL }
        return url
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let url = try makeURL(path: path, query: query)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        return try await execute(request)
    }

    private func send<Body: Encodable>(
        _ method: String,
        _ path: String,
        body: Body
    ) async throws {
        let url = try makeURL(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let _: EmptyResponse = try await execute(request)
    }

    private func execute<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.transport(error)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw APIError.badStatus(http.statusCode, body: String(data: data, encoding: .utf8))
        }
        if T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    // MARK: - Reads

    func fetchTasks(includeAll: Bool = false) async throws -> [OrgTask] {
        let query = includeAll ? [URLQueryItem(name: "all", value: "true")] : []
        return try await get("/api/tasks", query: query)
    }

    func fetchFiles() async throws -> [AgendaFile] {
        try await get("/api/files")
    }

    func fetchKeywords() async throws -> TodoKeywords {
        try await get("/api/keywords")
    }

    func fetchConfig() async throws -> OrgConfig {
        try await get("/api/config")
    }

    func fetchAgendaDay(_ date: String) async throws -> [AgendaEntry] {
        try await get("/api/agenda/day/\(date)")
    }

    func fetchAgendaRange(start: String, end: String) async throws -> [AgendaEntry] {
        try await get("/api/agenda/range", query: [
            URLQueryItem(name: "start", value: start),
            URLQueryItem(name: "end", value: end),
        ])
    }

    func fetchClockStatus() async throws -> ClockStatus {
        try await get("/api/clock")
    }

    func fetchNotes(file: String, pos: Int) async throws -> String {
        struct NotesResponse: Decodable { let notes: String }
        let r: NotesResponse = try await get("/api/notes", query: [
            URLQueryItem(name: "file", value: file),
            URLQueryItem(name: "pos", value: String(pos)),
        ])
        return r.notes
    }

    // MARK: - Mutations

    /// Mirrors JS `encodeURIComponent`: alphanumerics + unreserved RFC3986 chars.
    private static let pathComponentAllowed: CharacterSet = {
        var c = CharacterSet.alphanumerics
        c.insert(charactersIn: "-_.~")
        return c
    }()

    private func taskPath(_ id: String, suffix: String) -> String {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: Self.pathComponentAllowed) ?? id
        return "/api/tasks/\(encoded)/\(suffix)"
    }

    func setState(taskId: String, file: String, pos: Int, state: String) async throws {
        struct Body: Encodable { let file: String; let pos: Int; let state: String }
        try await send("PATCH", taskPath(taskId, suffix: "state"),
                       body: Body(file: file, pos: pos, state: state))
    }

    func setPriority(taskId: String, file: String, pos: Int, priority: String) async throws {
        struct Body: Encodable { let file: String; let pos: Int; let priority: String }
        try await send("PATCH", taskPath(taskId, suffix: "priority"),
                       body: Body(file: file, pos: pos, priority: priority))
    }

    func setTitle(taskId: String, file: String, pos: Int, title: String) async throws {
        struct Body: Encodable { let file: String; let pos: Int; let title: String }
        try await send("PATCH", taskPath(taskId, suffix: "title"),
                       body: Body(file: file, pos: pos, title: title))
    }

    func setTags(taskId: String, file: String, pos: Int, tags: [String]) async throws {
        struct Body: Encodable { let file: String; let pos: Int; let tags: [String] }
        try await send("PATCH", taskPath(taskId, suffix: "tags"),
                       body: Body(file: file, pos: pos, tags: tags))
    }

    func setScheduled(taskId: String, file: String, pos: Int, timestamp: String) async throws {
        struct Body: Encodable { let file: String; let pos: Int; let timestamp: String }
        try await send("PATCH", taskPath(taskId, suffix: "scheduled"),
                       body: Body(file: file, pos: pos, timestamp: timestamp))
    }

    func setDeadline(taskId: String, file: String, pos: Int, timestamp: String) async throws {
        struct Body: Encodable { let file: String; let pos: Int; let timestamp: String }
        try await send("PATCH", taskPath(taskId, suffix: "deadline"),
                       body: Body(file: file, pos: pos, timestamp: timestamp))
    }

    func setProperty(taskId: String, file: String, pos: Int, key: String, value: String) async throws {
        struct Body: Encodable { let file: String; let pos: Int; let key: String; let value: String }
        try await send("PATCH", taskPath(taskId, suffix: "property"),
                       body: Body(file: file, pos: pos, key: key, value: value))
    }

    func clockIn(file: String, pos: Int) async throws {
        struct Body: Encodable { let file: String; let pos: Int }
        try await send("POST", "/api/clock/in", body: Body(file: file, pos: pos))
    }

    func clockOut() async throws {
        try await send("POST", "/api/clock/out", body: EmptyBody())
    }

    /// Appends a completed `CLOCK: [start]--[end] => H:MM` line to the task's LOGBOOK.
    /// `start` and `end` are Unix epoch seconds.
    func logClockEntry(file: String, pos: Int, start: Int, end: Int) async throws {
        struct Body: Encodable { let file: String; let pos: Int; let start: Int; let end: Int }
        try await send("POST", "/api/clock/log", body: Body(file: file, pos: pos, start: start, end: end))
    }

    func setNotes(file: String, pos: Int, notes: String) async throws -> String {
        struct Body: Encodable { let file: String; let pos: Int; let notes: String }
        struct Resp: Decodable { let success: Bool; let notes: String? }
        let url = try makeURL(path: "/api/notes")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(file: file, pos: pos, notes: notes))
        let resp: Resp = try await execute(request)
        return resp.notes ?? notes
    }
}

private struct EmptyBody: Encodable {}
private struct EmptyResponse: Decodable { init() {} }

enum DateQuery {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func string(from date: Date) -> String { formatter.string(from: date) }

    static func today() -> String { string(from: Date()) }

    static func offset(days: Int, from date: Date = Date()) -> String {
        let d = Calendar.current.date(byAdding: .day, value: days, to: date) ?? date
        return string(from: d)
    }
}

/// Builds an org-style timestamp string: `<2026-04-21 Tue>` or `<2026-04-21 Tue 14:30>`.
enum OrgTimestampFormat {
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    static func string(date: Date, includeTime: Bool, durationMinutes: Int? = nil) -> String {
        let cal = Calendar.current
        let dateStr = dateFormatter.string(from: date)
        let weekday = cal.component(.weekday, from: date)
        let day = dayNames[weekday - 1]
        if includeTime {
            let hour = cal.component(.hour, from: date)
            let minute = cal.component(.minute, from: date)
            if let dur = durationMinutes, dur > 0 {
                let total = hour * 60 + minute + dur
                let endH = (total / 60) % 24
                let endM = total % 60
                return String(format: "<%@ %@ %02d:%02d-%02d:%02d>",
                              dateStr, day, hour, minute, endH, endM)
            }
            return String(format: "<%@ %@ %02d:%02d>", dateStr, day, hour, minute)
        }
        return "<\(dateStr) \(day)>"
    }
}
