import Foundation

enum SortKey: String, CaseIterable, Identifiable, Sendable {
    case `default`, priority, state, deadline, scheduled, category

    var id: String { rawValue }

    var label: String {
        switch self {
        case .default:   return "Default"
        case .priority:  return "Priority"
        case .state:     return "State"
        case .deadline:  return "Deadline"
        case .scheduled: return "Scheduled"
        case .category:  return "Category"
        }
    }

    /// Allowed options for agenda views (Today / Upcoming).
    static let agendaOptions: [SortKey] = [.default, .priority, .scheduled, .category]

    /// Allowed options for list views (All Tasks). No "default" — there's no
    /// inherent server order to preserve once we filter.
    static let listOptions: [SortKey] = [.priority, .deadline, .state, .category]
}

private func priorityOrd(_ p: String?) -> Int {
    switch p?.uppercased() {
    case "A": return 0
    case "B": return 1
    case "C": return 2
    case "D": return 3
    default: return 4
    }
}

private func extractDateMs(_ raw: String?) -> Double {
    guard let raw else { return .infinity }
    return OrgTimestamp.parseDateString(raw).map { $0.timeIntervalSince1970 * 1000 } ?? .infinity
}

private func extractTimeMinutes(_ item: any TaskDisplayable) -> Int {
    if let entry = item as? AgendaEntry, let t = entry.timeOfDay {
        if let m = t.range(of: #"(\d{1,2}):(\d{2})"#, options: .regularExpression) {
            let parts = t[m].split(separator: ":").compactMap { Int($0) }
            if parts.count == 2 { return parts[0] * 60 + parts[1] }
        }
    }
    let raw = item.scheduled?.raw ?? item.deadline?.raw ?? ""
    if let m = raw.range(of: #"(\d{1,2}):(\d{2})"#, options: .regularExpression) {
        let parts = raw[m].split(separator: ":").compactMap { Int($0) }
        if parts.count == 2 { return parts[0] * 60 + parts[1] }
    }
    return Int.max
}

enum GroupKey: String, CaseIterable, Identifiable, Sendable {
    case none, category, priority, state, file, tag, eisenhower

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none:        return "None"
        case .category:    return "Category"
        case .priority:    return "Priority"
        case .state:       return "State"
        case .file:        return "File"
        case .tag:         return "Tag"
        case .eisenhower:  return "Eisenhower"
        }
    }

    static let all: [GroupKey] = [.none, .category, .priority, .state, .tag, .file, .eisenhower]
}

struct EisenhowerGroupContext: Sendable {
    let urgencyDays: Int
    let importantPriorities: Set<String>

    init(urgencyDays: Int, priorities: OrgPriorities?) {
        self.urgencyDays = urgencyDays
        if let p = priorities {
            let all = p.all
            let count = (all.count + 1) / 2
            self.importantPriorities = Set(all.prefix(max(count, 1)).map { $0.uppercased() })
        } else {
            self.importantPriorities = ["A", "B"]
        }
    }
}

func eisenhowerQuadrant(for task: any TaskDisplayable, context: EisenhowerGroupContext) -> String {
    let isImportant = context.importantPriorities.contains(task.priority?.uppercased() ?? "")
    let isUrgent: Bool
    if let deadlineDate = task.deadline?.parsedDate {
        let today = Calendar.current.startOfDay(for: Date())
        let days = Calendar.current.dateComponents([.day], from: today, to: deadlineDate).day ?? Int.max
        isUrgent = days <= context.urgencyDays
    } else {
        isUrgent = false
    }
    switch (isUrgent, isImportant) {
    case (true, true):   return "Do First"
    case (false, true):  return "Schedule"
    case (true, false):  return "Delegate"
    case (false, false): return "Eliminate"
    }
}

enum EisenhowerSpan: String, CaseIterable, Identifiable, Sendable {
    case today, threeDays, week, twoWeeks, month, all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .today:     return "Today"
        case .threeDays: return "3 Days"
        case .week:      return "1 Week"
        case .twoWeeks:  return "2 Weeks"
        case .month:     return "1 Month"
        case .all:       return "All"
        }
    }

    var days: Int? {
        switch self {
        case .today:     return 0
        case .threeDays: return 3
        case .week:      return 7
        case .twoWeeks:  return 14
        case .month:     return 30
        case .all:       return nil
        }
    }
}

struct TaskGroup<T: TaskDisplayable & Identifiable>: Identifiable {
    let id: String
    let label: String
    let items: [T]
}

func groupTasks<T: TaskDisplayable & Identifiable>(
    _ items: [T],
    by key: GroupKey,
    eisenhower: EisenhowerGroupContext? = nil
) -> [TaskGroup<T>] {
    if key == .none {
        return [TaskGroup(id: "_all", label: "", items: items)]
    }
    var buckets: [String: [T]] = [:]
    var order: [String] = []

    func push(_ key: String, _ item: T) {
        if buckets[key] == nil { buckets[key] = []; order.append(key) }
        buckets[key]?.append(item)
    }

    for item in items {
        switch key {
        case .category:
            push(item.category.isEmpty ? "Uncategorized" : item.category, item)
        case .priority:
            push(item.priority?.isEmpty == false ? "Priority \(item.priority!.uppercased())" : "No Priority", item)
        case .state:
            push((item.todoState?.isEmpty == false ? item.todoState! : "—").uppercased(), item)
        case .file:
            let name = (item.file as NSString).lastPathComponent
            push(name.isEmpty ? "Unknown file" : name, item)
        case .tag:
            let combined = item.tags + item.inheritedTags.filter { !item.tags.contains($0) }
            if combined.isEmpty {
                push("Untagged", item)
            } else {
                for tag in combined { push(tag, item) }
            }
        case .eisenhower:
            if let ctx = eisenhower {
                push(eisenhowerQuadrant(for: item, context: ctx), item)
            } else {
                push("Uncategorized", item)
            }
        case .none:
            break
        }
    }

    let sortedKeys: [String]
    switch key {
    case .priority:
        sortedKeys = order.sorted { lhs, rhs in
            if lhs == "No Priority" { return false }
            if rhs == "No Priority" { return true }
            return lhs < rhs
        }
    case .eisenhower:
        let quadrantOrder = ["Do First", "Schedule", "Delegate", "Eliminate"]
        sortedKeys = order.sorted { lhs, rhs in
            (quadrantOrder.firstIndex(of: lhs) ?? 99) < (quadrantOrder.firstIndex(of: rhs) ?? 99)
        }
    default:
        sortedKeys = order.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
    return sortedKeys.map { TaskGroup(id: $0, label: $0, items: buckets[$0] ?? []) }
}

/// Bucket DONE/KILL tasks by how recently they closed. The Logbook view
/// uses this; everything else groups by category/priority/etc.
///
/// Buckets, in display order:
///   Today, Yesterday, This Week, This Month, Earlier, Unknown
///
/// "Unknown" catches tasks marked done without a CLOSED timestamp — this
/// happens when the user disables `org-log-done`, completes a heading
/// from an external tool, or imports tasks that were already done.
func groupTasksByClosedDate(_ items: [OrgTask]) -> [TaskGroup<OrgTask>] {
    let cal = Calendar.current
    let now = Date()
    let startOfToday = cal.startOfDay(for: now)
    let startOfYesterday = cal.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
    let startOfWeek = cal.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
    let startOfMonth = cal.date(byAdding: .day, value: -30, to: startOfToday) ?? startOfToday

    enum Bucket: Int, CaseIterable {
        case today, yesterday, thisWeek, thisMonth, earlier, unknown
        var label: String {
            switch self {
            case .today:     return "Today"
            case .yesterday: return "Yesterday"
            case .thisWeek:  return "This Week"
            case .thisMonth: return "This Month"
            case .earlier:   return "Earlier"
            case .unknown:   return "Unknown Date"
            }
        }
    }

    var buckets: [Bucket: [OrgTask]] = [:]
    for item in items {
        let ms = extractDateMs(item.closed)
        let bucket: Bucket
        if !ms.isFinite {
            bucket = .unknown
        } else {
            let date = Date(timeIntervalSince1970: ms / 1000)
            if date >= startOfToday { bucket = .today }
            else if date >= startOfYesterday { bucket = .yesterday }
            else if date >= startOfWeek { bucket = .thisWeek }
            else if date >= startOfMonth { bucket = .thisMonth }
            else { bucket = .earlier }
        }
        buckets[bucket, default: []].append(item)
    }

    // Within each bucket, sort by CLOSED descending (most recent first).
    return Bucket.allCases.compactMap { b in
        guard var items = buckets[b], !items.isEmpty else { return nil }
        items.sort { extractDateMs($0.closed) > extractDateMs($1.closed) }
        return TaskGroup(id: "closed_\(b.rawValue)", label: b.label, items: items)
    }
}

/// Collapse duplicate agenda entries by task id, preferring the entry that
/// carries a clock time so the row keeps its scheduled hour.
func dedupeAgendaEntries(_ entries: [AgendaEntry]) -> [AgendaEntry] {
    var seen: [String: AgendaEntry] = [:]
    var order: [String] = []
    for e in entries {
        let hasTime = (e.scheduled?.hasTime ?? false) || (e.deadline?.hasTime ?? false)
        if let existing = seen[e.id] {
            let existingHasTime = (existing.scheduled?.hasTime ?? false) || (existing.deadline?.hasTime ?? false)
            if hasTime && !existingHasTime { seen[e.id] = e }
        } else {
            seen[e.id] = e
            order.append(e.id)
        }
    }
    return order.compactMap { seen[$0] }
}

private struct SortKeys {
    let primary: SortPrimary
    let timeMinutes: Int

    enum SortPrimary {
        case int(Int)
        case double(Double)
        case string(String)
    }
}

private func makeSortKeys<T: TaskDisplayable>(_ item: T, key: SortKey) -> SortKeys {
    let primary: SortKeys.SortPrimary
    switch key {
    case .priority:
        primary = .int(priorityOrd(item.priority))
    case .state:
        primary = .string(item.todoState ?? "")
    case .deadline:
        let dl = extractDateMs(item.deadline?.raw)
        let ms = dl.isFinite ? dl : extractDateMs(item.scheduled?.raw)
        primary = .double(ms)
    case .scheduled:
        primary = .double(extractDateMs(item.scheduled?.raw))
    case .category:
        primary = .string(item.category)
    case .default:
        primary = .int(0)
    }
    return SortKeys(primary: primary, timeMinutes: extractTimeMinutes(item))
}

func sortTasks<T: TaskDisplayable>(_ items: [T], by key: SortKey) -> [T] {
    if key == .default { return items }
    // Schwartzian transform: materialize sort keys once per item so that
    // extractDateMs (regex + parse) and extractTimeMinutes (regex) are not
    // recomputed inside the O(N log N) comparator.
    let keyed = items.map { (makeSortKeys($0, key: key), $0) }
    let sorted = keyed.sorted { lhs, rhs in
        let (la, _) = lhs
        let (ra, _) = rhs
        var cmp = 0
        switch (la.primary, ra.primary) {
        case (.int(let l), .int(let r)):
            cmp = l - r
        case (.double(let l), .double(let r)):
            cmp = l < r ? -1 : (l > r ? 1 : 0)
        case (.string(let l), .string(let r)):
            cmp = l.localizedCompare(r).rawValue
        default:
            cmp = 0
        }
        if cmp == 0 {
            cmp = la.timeMinutes - ra.timeMinutes
        }
        return cmp < 0
    }
    return sorted.map { $0.1 }
}
