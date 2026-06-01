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

    private static let decoder = JSONDecoder()
    private static let encoder = JSONEncoder()

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
        if !query.isEmpty {
            components.queryItems = query
            // URLComponents percent-encodes query values but leaves '+' bare.
            // Servers (and old Express path) following form-encoding rules treat
            // bare '+' as a space. Org repeaters like "+1w" must survive the
            // round-trip, so encode '+' as '%2B' after the fact.
            if let pq = components.percentEncodedQuery {
                components.percentEncodedQuery = pq.replacingOccurrences(of: "+", with: "%2B")
            }
        }
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
        request.httpBody = try Self.encoder.encode(body)
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
            // Safer than `as! T` — `as?` returns nil if the bridge fails for
            // some bizarre reason and we throw a decoding error instead of
            // trapping. In practice `EmptyResponse` always matches when T is
            // EmptyResponse.self, but defensive code costs nothing here.
            if let empty = EmptyResponse() as? T { return empty }
            throw APIError.decoding(NSError(domain: "EAV", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "EmptyResponse bridge failure"]))
        }
        do {
            return try Self.decoder.decode(T.self, from: data)
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

    func fetchPriorities() async throws -> OrgPriorities {
        try await get("/api/priorities")
    }

    func fetchListConfig() async throws -> OrgListConfig {
        try await get("/api/list-config")
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

    struct OutlinePathResponse: Decodable, Sendable {
        let file: String
        let headings: [String]
    }

    func fetchOutlinePath(file: String, pos: Int) async throws -> OutlinePathResponse {
        try await get("/api/outline", query: [
            URLQueryItem(name: "file", value: file),
            URLQueryItem(name: "pos", value: String(pos)),
        ])
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

    private func patchTask<Body: Encodable>(_ id: String, path: String, body: Body) async throws {
        try await send("PATCH", taskPath(id, suffix: path), body: body)
    }

    func setState(taskId: String, file: String, pos: Int, state: String) async throws {
        struct Body: Encodable { let file: String; let pos: Int; let state: String }
        try await patchTask(taskId, path: "state", body: Body(file: file, pos: pos, state: state))
    }

    func setPriority(taskId: String, file: String, pos: Int, priority: String) async throws {
        struct Body: Encodable { let file: String; let pos: Int; let priority: String }
        try await patchTask(taskId, path: "priority", body: Body(file: file, pos: pos, priority: priority))
    }

    func setTitle(taskId: String, file: String, pos: Int, title: String) async throws {
        struct Body: Encodable { let file: String; let pos: Int; let title: String }
        try await patchTask(taskId, path: "title", body: Body(file: file, pos: pos, title: title))
    }

    func setTags(taskId: String, file: String, pos: Int, tags: [String]) async throws {
        struct Body: Encodable { let file: String; let pos: Int; let tags: [String] }
        try await patchTask(taskId, path: "tags", body: Body(file: file, pos: pos, tags: tags))
    }

    func setScheduled(taskId: String, file: String, pos: Int, timestamp: String) async throws {
        struct Body: Encodable { let file: String; let pos: Int; let timestamp: String }
        try await patchTask(taskId, path: "scheduled", body: Body(file: file, pos: pos, timestamp: timestamp))
    }

    func setDeadline(taskId: String, file: String, pos: Int, timestamp: String) async throws {
        struct Body: Encodable { let file: String; let pos: Int; let timestamp: String }
        try await patchTask(taskId, path: "deadline", body: Body(file: file, pos: pos, timestamp: timestamp))
    }

    func setProperty(taskId: String, file: String, pos: Int, key: String, value: String) async throws {
        struct Body: Encodable { let file: String; let pos: Int; let key: String; let value: String }
        try await patchTask(taskId, path: "property", body: Body(file: file, pos: pos, key: key, value: value))
    }

    /// Start a server-side clock for the given task. Returns the open Clock row.
    func clockIn(file: String, pos: Int, title: String? = nil) async throws -> Clock {
        struct Body: Encodable { let file: String; let pos: Int; let title: String? }
        let url = try makeURL(path: "/api/clock/in")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(Body(file: file, pos: pos, title: title))
        return try await execute(request)
    }

    /// Start a server-side clock for a DB-backed habit (clocked by id, not file/pos).
    func clockInHabit(id: String, title: String? = nil) async throws -> Clock {
        struct Body: Encodable { let taskId: String; let title: String? }
        let url = try makeURL(path: "/api/clock/in")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(Body(taskId: id, title: title))
        return try await execute(request)
    }

    /// Stop a server-side clock by its row id.
    func clockOut(id: Int64) async throws {
        struct Body: Encodable { let id: Int64 }
        try await send("POST", "/api/clock/out", body: Body(id: id))
    }

    /// Return all currently running (end == nil) server-side clocks.
    func fetchActiveClocks() async throws -> [Clock] {
        try await get("/api/clock/active")
    }

    /// Cancel a clock row without persisting an interval.
    func cancelClock(id: Int64) async throws {
        struct DeleteResponse: Decodable { let success: Bool }
        let url = try makeURL(path: "/api/clock/\(id)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 30
        let _: DeleteResponse = try await execute(request)
    }

    // MARK: - Habit API (DB-backed)

    private func habitPath(_ id: String, suffix: String = "") -> String {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: Self.pathComponentAllowed) ?? id
        return suffix.isEmpty ? "/api/habits/\(encoded)" : "/api/habits/\(encoded)/\(suffix)"
    }

    func fetchHabits() async throws -> [Habit] {
        try await get("/api/habits")
    }

    func createHabit(
        title: String,
        cadence: HabitCadenceSpec,
        category: String? = nil,
        priority: String? = nil,
        tags: [String]? = nil,
        notes: String? = nil,
        anchorDate: String? = nil,
        resetChecklistOnComplete: Bool? = nil
    ) async throws -> Habit {
        struct Body: Encodable {
            let title: String
            let cadence: HabitCadenceSpec
            let category: String?
            let priority: String?
            let tags: [String]?
            let notes: String?
            let anchorDate: String?
            let resetChecklistOnComplete: Bool?
        }
        let url = try makeURL(path: "/api/habits")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(
            Body(title: title, cadence: cadence, category: category,
                 priority: priority, tags: tags, notes: notes, anchorDate: anchorDate,
                 resetChecklistOnComplete: resetChecklistOnComplete)
        )
        return try await execute(request)
    }

    /// PATCH a habit. The daemon clears a field only on an explicit JSON
    /// `null`; a synthesized Encodable omits nil optionals (= "keep"), so
    /// `clearsPriority` / `clearsNotes` force an explicit null to clear the
    /// field (e.g. setting a habit's priority to None).
    func updateHabit(
        id: String,
        title: String? = nil,
        cadence: HabitCadenceSpec? = nil,
        category: String? = nil,
        priority: String? = nil,
        tags: [String]? = nil,
        notes: String? = nil,
        anchorDate: String? = nil,
        active: Bool? = nil,
        resetChecklistOnComplete: Bool? = nil,
        clearsPriority: Bool = false,
        clearsNotes: Bool = false
    ) async throws -> Habit {
        struct Body: Encodable {
            let title: String?
            let cadence: HabitCadenceSpec?
            let category: String?
            let priority: String?
            let tags: [String]?
            let notes: String?
            let anchorDate: String?
            let active: Bool?
            let resetChecklistOnComplete: Bool?
            let clearsPriority: Bool
            let clearsNotes: Bool
            enum CodingKeys: String, CodingKey {
                case title, cadence, category, priority, tags, notes
                case anchorDate, active, resetChecklistOnComplete
            }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encodeIfPresent(title, forKey: .title)
                try c.encodeIfPresent(cadence, forKey: .cadence)
                try c.encodeIfPresent(category, forKey: .category)
                if clearsPriority { try c.encodeNil(forKey: .priority) }
                else { try c.encodeIfPresent(priority, forKey: .priority) }
                try c.encodeIfPresent(tags, forKey: .tags)
                if clearsNotes { try c.encodeNil(forKey: .notes) }
                else { try c.encodeIfPresent(notes, forKey: .notes) }
                try c.encodeIfPresent(anchorDate, forKey: .anchorDate)
                try c.encodeIfPresent(active, forKey: .active)
                try c.encodeIfPresent(resetChecklistOnComplete, forKey: .resetChecklistOnComplete)
            }
        }
        let url = try makeURL(path: habitPath(id))
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(
            Body(title: title, cadence: cadence, category: category,
                 priority: priority, tags: tags, notes: notes,
                 anchorDate: anchorDate, active: active,
                 resetChecklistOnComplete: resetChecklistOnComplete,
                 clearsPriority: clearsPriority, clearsNotes: clearsNotes)
        )
        return try await execute(request)
    }

    func deleteHabit(id: String) async throws {
        struct DeleteResp: Decodable { let success: Bool }
        let url = try makeURL(path: habitPath(id))
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 30
        let _: DeleteResp = try await execute(request)
    }

    /// Record a habit completion in the DB. `ts` is an optional ISO-8601 or
    /// org-style timestamp; nil means "now" on the server.
    func completeHabit(id: String, ts: String? = nil) async throws -> Habit {
        struct Body: Encodable { let ts: String? }
        let url = try makeURL(path: habitPath(id, suffix: "complete"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(Body(ts: ts))
        return try await execute(request)
    }

    /// Remove a habit completion from the DB.
    /// `ts` is the org-style timestamp string from `habit.completions`.
    func uncompleteHabit(id: String, ts: String) async throws -> Habit {
        struct Body: Encodable { let ts: String }
        let url = try makeURL(path: habitPath(id, suffix: "uncomplete"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(Body(ts: ts))
        return try await execute(request)
    }

    /// Skip the current due period (advance next-due, no credit).
    func skipHabit(id: String) async throws -> Habit {
        struct Body: Encodable {}
        let url = try makeURL(path: habitPath(id, suffix: "skip"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(Body())
        return try await execute(request)
    }

    /// Set the next-due date for a habit explicitly.
    func rescheduleHabit(id: String, date: String) async throws -> Habit {
        struct Body: Encodable { let date: String }
        let url = try makeURL(path: habitPath(id, suffix: "reschedule"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(Body(date: date))
        return try await execute(request)
    }

    /// Sweep loose CLOCK: lines under a heading into a :LOGBOOK: drawer.
    func tidyClocks(file: String, pos: Int) async throws {
        struct Body: Encodable { let file: String; let pos: Int }
        try await send("POST", "/api/clock/tidy", body: Body(file: file, pos: pos))
    }

    func fetchRefileTargets() async throws -> [RefileTarget] {
        try await get("/api/refile/targets")
    }

    func refileTask(sourceFile: String, sourcePos: Int,
                    targetFile: String, targetPos: Int) async throws {
        struct Body: Encodable {
            let sourceFile: String; let sourcePos: Int
            let targetFile: String; let targetPos: Int
        }
        try await send("POST", "/api/refile",
                       body: Body(sourceFile: sourceFile, sourcePos: sourcePos,
                                  targetFile: targetFile, targetPos: targetPos))
    }

    func archiveTask(id: String, file: String, pos: Int) async throws {
        struct Body: Encodable { let file: String; let pos: Int }
        // Task IDs are `<absolute-file-path>::<pos>`, which contain `/` and
        // sometimes spaces. `.urlPathAllowed` leaves slashes intact, which
        // would split the id across multiple path segments and produce a
        // 404 against axum's `:id` matcher. Use the shared
        // `pathComponentAllowed` set (alphanumerics + `-_.~`) so the id
        // becomes a single opaque segment.
        try await send("POST", taskPath(id, suffix: "archive"), body: Body(file: file, pos: pos))
    }

    func fetchCaptureTemplates() async throws -> [CaptureTemplate] {
        try await get("/api/capture/templates")
    }

    func insertEntry(file: String, targetType: String, entryText: String,
                     headline: String? = nil, olp: [String]? = nil,
                     prepend: Bool = false) async throws {
        struct Body: Encodable {
            let file: String; let targetType: String; let entryText: String
            let headline: String?; let olp: [String]?; let prepend: Bool?
        }
        try await send("POST", "/api/insert-entry",
                       body: Body(file: file, targetType: targetType, entryText: entryText,
                                  headline: headline, olp: olp,
                                  prepend: prepend ? true : nil))
    }

    func captureTask(templateKey: String, title: String, priority: String?,
                     scheduled: String?, deadline: String?,
                     promptAnswers: [String]?) async throws {
        struct Body: Encodable {
            let templateKey: String; let title: String
            let priority: String?; let scheduled: String?; let deadline: String?
            let promptAnswers: [String]?
        }
        try await send("POST", "/api/capture",
                       body: Body(templateKey: templateKey, title: title,
                                  priority: priority, scheduled: scheduled,
                                  deadline: deadline, promptAnswers: promptAnswers))
    }

    func setNotes(file: String, pos: Int, notes: String) async throws -> String {
        struct Body: Encodable { let file: String; let pos: Int; let notes: String }
        struct Resp: Decodable { let success: Bool; let notes: String? }
        let url = try makeURL(path: "/api/notes")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(Body(file: file, pos: pos, notes: notes))
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
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func string(from date: Date) -> String {
        // Refresh timezone on every call so DST crossings and zone changes
        // that occur without a relaunch are picked up immediately.
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

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
            // durationMinutes is only meaningful for timed timestamps
            if let dur = durationMinutes, dur > 0 {
                let total = hour * 60 + minute + dur
                let endH = (total / 60) % 24
                let endM = total % 60
                return String(format: "<%@ %@ %02d:%02d-%02d:%02d>",
                              dateStr, day, hour, minute, endH, endM)
            }
            return String(format: "<%@ %@ %02d:%02d>", dateStr, day, hour, minute)
        }
        // durationMinutes is silently ignored for date-only timestamps
        return "<\(dateStr) \(day)>"
    }
}
