import SwiftUI

extension Notification.Name {
    static let eav_refreshAll = Notification.Name("eav_refreshAll")
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case today, upcoming, inbox, all, logbook, habits, eisenhower, calendar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Today"
        case .upcoming: return "Upcoming"
        case .inbox: return "Inbox"
        case .all: return "All Tasks"
        case .logbook: return "Logbook"
        case .habits: return "Habits"
        case .eisenhower: return "Eisenhower"
        case .calendar: return "Calendar"
        }
    }

    var systemImage: String {
        switch self {
        case .today: return "star.fill"
        case .upcoming: return "list.bullet"
        case .inbox: return "tray.and.arrow.down.fill"
        case .all: return "tray.fill"
        case .logbook: return "book.closed.fill"
        case .habits: return "arrow.triangle.2.circlepath"
        case .eisenhower: return "square.grid.2x2.fill"
        case .calendar: return "calendar"
        }
    }
}

@MainActor
@Observable
final class Selection {
    var taskId: String?
    var refileTask: (any TaskDisplayable)?
    var editingTaskId: String?
    var editingTitle: String = ""
    /// One-shot signal: when set, the active list view should scroll this
    /// task's row into view, then clear it. Driven today by clock-dock
    /// clicks — set by `RootView.revealTask(_:)`, consumed by
    /// `MacAllTasksView`'s ScrollViewReader.
    var revealTaskId: String?
}

struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DaemonHost.self) private var daemonHost
    @State private var store = TasksStore()
    @State private var selection: SidebarItem = .today
    @State private var taskSelection = Selection()
    @State private var clocks = ClockManager()
    @State private var calendarState = CalendarState()
    @State private var eventKit = EventKitService()
    @State private var calendarSync: CalendarSync?
    @State private var showCapture = false
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .automatic
    @State private var eventSubscriber: EventSubscriber?

    var body: some View {
        // Render the main split only once `calendarSync` has been initialized
        // in `.task` below. Previously we initialized it lazily during `body`
        // via `calendarSync ?? makeSync()`, which mutated `@State` mid-body —
        // technically undefined per Apple's docs even though it happened to
        // work in practice. Initial paint is delayed by one frame; harmless.
        Group {
            if let calendarSync {
                NavigationSplitView(columnVisibility: $sidebarVisibility) {
                    sidebar
                } detail: {
                    detailArea
                }
                .environment(taskSelection)
                .environment(clocks)
                .environment(calendarState)
                .environment(eventKit)
                .environment(calendarSync)
            } else {
                Color.clear
            }
        }
        .task {
            if calendarSync == nil {
                calendarSync = CalendarSync(store: store, settings: settings, ek: eventKit)
            }
        }
        // Re-fire on either URL change OR daemon-phase transition. The
        // phase part covers cold launch: the persisted URL is non-empty
        // so this .task fires immediately, fails silently while eavd is
        // still binding the port, and then re-fires once phase flips to
        // `.ready`. Without the phase in the id, metadata + SSE would
        // both stay broken until the user manually refreshed.
        .task(id: "\(settings.serverURLString)|\(daemonHost.phase)") {
            guard daemonHost.phase != .starting else { return }
            guard let client = settings.apiClient else { return }
            store.initialized = false
            await store.loadMetadata(using: client, settings: settings)

            // Re-attach the SSE subscriber whenever the server URL changes.
            // Falls silent when the configured backend doesn't expose
            // /api/events (i.e. the legacy Express server).
            eventSubscriber?.stop()
            let sub = EventSubscriber(baseURLString: settings.serverURLString)
            sub?.start { [weak store] event in
                guard let store else { return }
                Task { @MainActor in
                    guard let client = settings.apiClient else { return }
                    switch event {
                    case .taskChanged(_, let file, let pos):
                        await store.invalidate(taskId: "\(file)::\(pos)", file: file, pos: pos, using: client)
                    case .fileChanged(let file):
                        await store.invalidate(file: file, using: client)
                    case .clockChanged:
                        await store.refreshClock(using: client)
                    case .configChanged:
                        await store.invalidateConfig(using: client, settings: settings)
                    }
                }
            }
            eventSubscriber = sub
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCapture = true
                } label: {
                    Label("Capture", systemImage: "plus.circle")
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .help("Capture new task (⇧⌘N)")
                .disabled(!settings.isConfigured)
            }
        }
        .sheet(isPresented: $showCapture) {
            CaptureSheet(store: store) {
                Task {
                    guard let client = settings.apiClient else { return }
                    await store.refreshLoaded(using: client)
                }
            }
            .environment(settings)
        }
        .onReceive(NotificationCenter.default.publisher(for: .eav_refreshAll)) { _ in
            Task {
                guard let client = settings.apiClient else { return }
                store.notesCache.removeAll()
                store.refileTargetsLoaded = false
                store.refileTargets = []
                await store.loadMetadata(using: client, settings: settings)
                await store.refreshLoaded(using: client)
                await store.loadRefileTargets(using: client)
            }
        }
        .sheet(item: Binding(
            get: { taskSelection.refileTask.map { RefileSheetItem(task: $0) } },
            set: { if $0 == nil { taskSelection.refileTask = nil } }
        )) { item in
            RefileSheet(store: store, task: item.task)
                .environment(settings)
        }
    }

    @ViewBuilder
    private var detailArea: some View {
        mainPane
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var mainPane: some View {
        VStack(spacing: 0) {
            MacClockDock(store: store, onReveal: revealClocked)
            // Show a single connecting overlay across the whole detail
            // pane while the bundled daemon is booting. Without this, each
            // list view's `.task` fires against the not-yet-bound :3002
            // and renders "Couldn't load" before the daemon is ready —
            // the persisted server URL guarantees that race on every
            // cold launch. We swap to the real content the moment the
            // phase transitions to `.ready` and kick a refresh so any
            // pre-ready failed loads recover.
            Group {
                switch daemonHost.phase {
                case .idle, .starting:
                    ConnectingStateView()
                case .failedToStart(let reason):
                    DaemonFailedView(kind: .failedToStart, reason: reason) {
                        await daemonHost.restart()
                    }
                case .crashed(let reason):
                    // Distinct from failedToStart: the daemon WAS healthy
                    // and then died, so we surface the signal/exit + stderr
                    // tail captured by the termination handler. Same retry
                    // path; different copy.
                    DaemonFailedView(kind: .crashed, reason: reason) {
                        await daemonHost.restart()
                    }
                case .ready:
                    detailContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background)
    }

    /// Clock-dock click handler: select the task and request a scroll in
    /// whichever list view is currently active. We deliberately don't
    /// switch the sidebar — the user already chose what they're looking
    /// at; if their current view contains the row, it scrolls into view,
    /// otherwise the request silently no-ops.
    /// The session id is the file::pos snapshot from clock-in time; if
    /// CLOCK lines have shifted the heading we try to re-resolve through
    /// already-loaded lists, falling back to the original.
    private func revealClocked(_ session: ClockManager.Session) {
        let resolved = resolveSessionId(session) ?? session.id
        taskSelection.taskId = resolved
        taskSelection.revealTaskId = resolved
    }

    private func resolveSessionId(_ session: ClockManager.Session) -> String? {
        func search<T: TaskDisplayable>(_ tasks: [T]?) -> String? {
            tasks?.first(where: {
                $0.id == session.id || ($0.file == session.file && $0.title == session.title)
            })?.id
        }
        return search(store.allTasks.value)
            ?? search(store.today.value)
            ?? search(store.upcoming.value)
    }

    private var sidebar: some View {
        List(SidebarItem.allCases, selection: $selection) { item in
            NavigationLink(value: item) {
                HStack(spacing: 6) {
                    Label(item.title, systemImage: item.systemImage)
                        .font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 4)
                    if let count = sidebarCount(item) {
                        CountPill(count: count, tint: sidebarTint(item))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        // simultaneousGesture fires alongside the List's row-selection
        // gesture, so clicks on empty sidebar area, on rows, or anywhere on
        // the sidebar column all dismiss the inspector. .background or
        // .onTapGesture alone don't reach NSTableView-backed sidebar items
        // on macOS.
        .simultaneousGesture(
            TapGesture().onEnded { taskSelection.taskId = nil }
        )
    }

    /// Count for the pill badge. Nil → no pill. Computed lazily from
    /// whatever the store already has loaded; we deliberately don't kick a
    /// fetch from here, so sidebar items don't gain numbers until their
    /// view has been visited (matches what the user is actually looking at).
    /// Today / Upcoming / All come from already-paged lists; Inbox is
    /// derived from `allTasks` because we don't have a dedicated endpoint.
    private func sidebarCount(_ item: SidebarItem) -> Int? {
        switch item {
        case .today:
            // Match what the view actually renders: dedupe (scheduled +
            // deadline of the same heading collapse into one row),
            // drop calendar events (the dayHead shows them separately
            // as "N events"), and drop done-state entries. Without
            // this filter the pill counted everything in the raw
            // agenda payload, so a day with 5 events and 1 task read
            // "8" instead of "1".
            guard let entries = store.today.value else { return nil }
            return dedupeAgendaEntries(entries)
                .filter { !AgendaEntryClassification.isEvent($0)
                    && !store.isDoneState($0.todoState) }
                .count
        case .upcoming:
            guard let entries = store.upcoming.value else { return nil }
            return dedupeAgendaEntries(entries)
                .filter { !AgendaEntryClassification.isEvent($0)
                    && !store.isDoneState($0.todoState) }
                .count
        case .inbox:
            guard let tasks = store.allTasks.value else { return nil }
            return tasks.filter {
                $0.category.caseInsensitiveCompare("Inbox") == .orderedSame
                    && !store.isDoneState($0.todoState)
            }.count
        case .all:
            return store.allTasks.value.map { $0.count }
        case .logbook:
            // Counts done states currently held in allTasks — only accurate
            // after the Logbook view has been visited (it force-loads with
            // includeDone=true). Before then this is nil → no pill, which
            // is honest about the unknown state.
            guard let tasks = store.allTasks.value else { return nil }
            let count = tasks.filter { store.isDoneState($0.todoState) }.count
            return count > 0 ? count : nil
        case .habits:
            guard let tasks = store.allTasks.value else { return nil }
            let count = tasks.filter { $0.isHabit }.count
            return count > 0 ? count : nil
        case .eisenhower, .calendar:
            return nil
        }
    }

    /// One neutral tint for every count pill.
    ///
    /// Earlier this returned per-item colors (red Today, blue Upcoming,
    /// orange Inbox, gray All) but that scheme fights whatever the user's
    /// macOS system accent is — the sidebar's selected-row background
    /// follows `NSColor.controlAccentColor`, which can be any of Apple's
    /// preset accents. A red pill on a green system-accent selection was
    /// genuinely ugly. Uniform muted gray keeps the chrome quiet so the
    /// user's accent choice can lead.
    private func sidebarTint(_ item: SidebarItem) -> Color {
        switch item {
        case .today, .upcoming, .inbox, .all, .logbook, .habits,
             .eisenhower, .calendar: return Theme.textTertiary
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selection {
        case .today: MacTodayView(store: store)
        case .upcoming: MacUpcomingView(store: store)
        case .inbox: MacInboxView(store: store)
        case .all: MacAllTasksView(store: store)
        case .logbook: MacLogbookView(store: store)
        case .habits: MacHabitsView(store: store)
        case .eisenhower: MacEisenhowerView(store: store)
        case .calendar: MacCalendarView(store: store)
        }
    }

    private struct RefileSheetItem: Identifiable {
        let task: any TaskDisplayable
        var id: String { task.id }
    }
}

/// Square count pill rendered on the trailing side of a sidebar row.
/// Tinted background at a low opacity with the tint as the foreground —
/// matches the look of the priority and state pills already used in
/// `TaskRow`, just compacter for the sidebar's smaller font.
private struct CountPill: View {
    let count: Int
    let tint: Color

    var body: some View {
        Text("\(count)")
            .font(.system(size: 11, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .frame(minWidth: 22, alignment: .center)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(tint.opacity(0.18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(tint.opacity(0.25), lineWidth: 0.5)
            )
    }
}
