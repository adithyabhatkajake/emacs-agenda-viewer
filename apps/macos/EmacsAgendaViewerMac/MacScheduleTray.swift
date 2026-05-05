import SwiftUI

private enum TrayRange: String, CaseIterable, Identifiable {
    case day, week, month
    var id: String { rawValue }
    var label: String {
        switch self {
        case .day:   return "Day"
        case .week:  return "7 Days"
        case .month: return "Month"
        }
    }
    /// Number of days from anchor (inclusive of anchor day).
    var dayCount: Int {
        switch self {
        case .day:   return 1
        case .week:  return 7
        case .month: return 30
        }
    }
}

struct MacScheduleTray: View {
    @Environment(AppSettings.self) private var settings
    @Environment(CalendarState.self) private var cal
    @Environment(Selection.self) private var selection
    @Environment(ClockManager.self) private var clocks
    @Environment(CalendarSync.self) private var sync
    let store: TasksStore

    @State private var range: TrayRange = .day
    @State private var includeDeadlines: Bool = true
    @State private var excludeScheduled: Bool = false
    @State private var query: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            controls
            searchField
            Divider().background(Theme.borderSubtle)
            listAndInspector
        }
        .background(Theme.surface)
        .task(id: settings.serverURLString) { await loadIfNeeded() }
    }


    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar.badge.plus")
                .foregroundStyle(Theme.accent)
                .font(.system(size: 11))
            Text("SCHEDULE")
                .font(.system(size: 10, weight: .bold)).tracking(0.6)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Button { Task { await reload() } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $range) {
                ForEach(TrayRange.allCases) { r in
                    Text(r.label).tag(r)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Text(rangeSubtitle)
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
            }
            HStack(spacing: 12) {
                Toggle("Include deadlines", isOn: $includeDeadlines)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .font(.caption2)
                Toggle("Exclude scheduled", isOn: $excludeScheduled)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .font(.caption2)
                    .help("Hide tasks that are already scheduled (only show ones still needing a slot)")
                Spacer()
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            TextField("Filter", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Theme.surfaceElevated.opacity(0.7))
        )
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    // MARK: - List

    private var listAndInspector: some View {
        let factory = RowActionFactory(
            store: store, settings: settings,
            selection: selection, clocks: clocks, sync: sync
        )
        return ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                let doneStates = Set((store.keywords?.allDone ?? []).map { $0.uppercased() })
                ForEach(filtered) { task in
                    TrayRow(task: task, anchor: rangeStart)
                    if selection.taskId == task.id {
                        TaskExpandedCard(
                            store: store,
                            task: task,
                            actions: factory.make(for: task),
                            doneStates: doneStates
                        )
                        .id(task.id)
                    }
                }
                if filtered.isEmpty {
                    Text(query.isEmpty ? "Nothing in this range" : "No matches")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                }
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 6).padding(.top, 6)
        }
    }

    // MARK: - Range / filter

    private var allActive: [OrgTask] { store.allTasks.value ?? [] }

    private var rangeStart: Date {
        Calendar.current.startOfDay(for: cal.anchor)
    }

    private var rangeEnd: Date {
        Calendar.current.date(byAdding: .day, value: range.dayCount, to: rangeStart) ?? rangeStart
    }

    private var rangeSubtitle: String {
        let f = DateFormatter(); f.dateFormat = "MMM d"
        let start = f.string(from: rangeStart)
        if range == .day { return start }
        let last = Calendar.current.date(byAdding: .day, value: range.dayCount - 1, to: rangeStart) ?? rangeStart
        return "\(start) – \(f.string(from: last))"
    }

    private func inRange(_ d: Date) -> Bool {
        d >= rangeStart && d < rangeEnd
    }

    /// Show what actually falls in the visible window. When the window starts
    /// at today, also surface past-due scheduled & deadlines so they don't get
    /// silently lost. We do NOT add future warning-period deadlines — Day means
    /// today only; switch to 7 Days / Month for a wider view.
    private var filtered: [OrgTask] {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let isWindowAtToday = cal.isDate(rangeStart, inSameDayAs: todayStart)

        let base = allActive.filter { task in
            // Scheduled match.
            let scheduledMatch: Bool = {
                if let s = task.scheduled?.parsedDate, inRange(s) { return true }
                if isWindowAtToday, let s = task.scheduled?.parsedDate, s < rangeStart {
                    return true
                }
                return false
            }()
            // Deadline match (when toggle is on).
            let deadlineMatch: Bool = includeDeadlines ? {
                if let d = task.deadline?.parsedDate {
                    if inRange(d) { return true }
                    if isWindowAtToday && d < rangeStart { return true }
                }
                return false
            }() : false

            if excludeScheduled {
                // Hide only tasks that already have a specific time slot on
                // the calendar. Tasks scheduled for the day without a time
                // still need a slot and stay visible.
                if let s = task.scheduled, s.hasTime { return false }
            }
            return scheduledMatch || deadlineMatch
        }
        let sorted = base.sorted { lhs, rhs in
            primaryDate(lhs) < primaryDate(rhs)
        }
        guard !query.isEmpty else { return sorted }
        let needle = query.lowercased()
        return sorted.filter { t in
            t.title.lowercased().contains(needle)
                || t.category.lowercased().contains(needle)
                || t.tags.contains(where: { $0.lowercased().contains(needle) })
        }
    }

    private func primaryDate(_ t: OrgTask) -> Date {
        if let s = t.scheduled?.parsedDate, inRange(s) { return s }
        if let d = t.deadline?.parsedDate, inRange(d) { return d }
        return .distantFuture
    }

    // MARK: - Loads

    private func loadIfNeeded() async {
        guard store.allTasks.value == nil else { return }
        await reload()
    }

    private func reload() async {
        guard let client = settings.apiClient else { return }
        await store.loadAllTasks(using: client, includeDone: false)
    }
}

private struct TrayRow: View {
    @Environment(Selection.self) private var selection
    let task: OrgTask
    let anchor: Date
    @State private var isHovering = false

    private var isSelected: Bool { selection.taskId == task.id }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 5, height: 5)

            Text(task.title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 6)

            if let label = dateLabel {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(dateColor)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(rowBackground)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            selection.taskId = (selection.taskId == task.id) ? nil : task.id
        }
        .help(helpText)
        .draggable(task.dragPayload) {
            Text(task.title)
                .font(.system(size: 12))
                .padding(8)
                .background(Theme.surface)
                .cornerRadius(6)
        }
    }

    /// True if this task is showing because of a deadline (no in-range scheduled).
    private var showingAsDeadline: Bool {
        task.scheduled?.parsedDate == nil && task.deadline?.parsedDate != nil
    }

    private var rowBackground: Color {
        if isSelected { return Theme.accent.opacity(0.18) }
        if isHovering { return Theme.surfaceElevated.opacity(0.7) }
        return .clear
    }

    private var dotColor: Color {
        showingAsDeadline ? Theme.priorityA : Theme.accent
    }

    private var dateLabel: String? {
        let date = task.scheduled?.parsedDate ?? task.deadline?.parsedDate
        return date.map { DateBadge.relativeLabel(for: $0) }
    }

    private var dateColor: Color {
        guard let date = task.scheduled?.parsedDate ?? task.deadline?.parsedDate else {
            return Theme.textTertiary
        }
        if showingAsDeadline {
            let cal = Calendar.current
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: date)).day ?? 0
            if days < 0 { return Theme.priorityA }
            if days <= 2 { return Theme.priorityB }
        }
        return Theme.textSecondary
    }

    private var helpText: String {
        var parts: [String] = []
        if !task.category.isEmpty { parts.append(task.category) }
        if let p = task.priority, !p.isEmpty { parts.append("Priority \(p.uppercased())") }
        if showingAsDeadline, let dl = task.deadline?.raw { parts.append("Deadline \(dl)") }
        if let s = task.scheduled?.raw, !s.isEmpty { parts.append("Scheduled \(s)") }
        return parts.joined(separator: " · ")
    }
}
