import SwiftUI

enum EisenhowerQuadrant: CaseIterable {
    case doFirst, schedule, delegate, eliminate

    var label: String {
        switch self {
        case .doFirst:  return "Do First"
        case .schedule: return "Schedule"
        case .delegate: return "Delegate"
        case .eliminate: return "Eliminate"
        }
    }

    var subtitle: String {
        switch self {
        case .doFirst:  return "Urgent & Important"
        case .schedule: return "Important, Not Urgent"
        case .delegate: return "Urgent, Not Important"
        case .eliminate: return "Neither"
        }
    }

    var color: Color {
        switch self {
        case .doFirst:  return Theme.priorityA
        case .schedule: return Theme.accent
        case .delegate: return Theme.priorityB
        case .eliminate: return Theme.priorityD
        }
    }

    var systemImage: String {
        switch self {
        case .doFirst:  return "flame.fill"
        case .schedule: return "calendar.badge.clock"
        case .delegate: return "person.2.fill"
        case .eliminate: return "xmark.bin"
        }
    }
}

struct MacEisenhowerView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Selection.self) private var selection
    @Environment(ClockManager.self) private var clocks
    @Environment(CalendarSync.self) private var sync
    let store: TasksStore

    @State private var searchText = ""

    var body: some View {
        content
            .navigationTitle("Eisenhower Matrix")
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search tasks")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    spanMenu
                }
                ToolbarItem(placement: .primaryAction) {
                    urgencyMenu
                }
                ToolbarItem(placement: .primaryAction) {
                    ReloadButton(action: { Task { await load() } }, disabled: !settings.isConfigured)
                }
            }
            .task(id: settings.serverURLString) { await loadIfNeeded() }
    }

    private var spanMenu: some View {
        Menu {
            ForEach(EisenhowerSpan.allCases) { span in
                Button {
                    settings.eisenhowerSpan = span
                } label: {
                    if settings.eisenhowerSpan == span {
                        Label(span.label, systemImage: "checkmark")
                    } else {
                        Text(span.label)
                    }
                }
            }
        } label: {
            Label("Span: \(settings.eisenhowerSpan.label)",
                  systemImage: "calendar.day.timeline.left")
        }
        .help("Only show tasks with deadlines or scheduled dates within this window")
    }

    private var urgencyMenu: some View {
        Menu {
            ForEach([3, 5, 7, 14, 21, 30], id: \.self) { days in
                Button {
                    settings.eisenhowerUrgencyDays = days
                } label: {
                    if settings.eisenhowerUrgencyDays == days {
                        Label("\(days) days", systemImage: "checkmark")
                    } else {
                        Text("\(days) days")
                    }
                }
            }
        } label: {
            Label("Urgent within: \(settings.eisenhowerUrgencyDays)d",
                  systemImage: "clock.badge.exclamationmark")
        }
        .help("Tasks with deadlines within this many days are considered urgent")
    }

    @ViewBuilder
    private var content: some View {
        if !settings.isConfigured {
            UnconfiguredStateView()
        } else if let tasks = store.allTasks.value {
            matrix(filter(tasks))
        } else if store.allTasks.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let msg = store.allTasks.error {
            ErrorStateView(message: msg) { Task { await load() } }
        } else {
            Color.clear
        }
    }

    // MARK: - Classification

    private var eisenhowerContext: EisenhowerGroupContext {
        EisenhowerGroupContext(urgencyDays: settings.eisenhowerUrgencyDays, priorities: store.priorities)
    }

    private func classify(_ task: OrgTask) -> EisenhowerQuadrant {
        let label = eisenhowerQuadrant(for: task, context: eisenhowerContext)
        return EisenhowerQuadrant.allCases.first { $0.label == label } ?? .eliminate
    }

    // MARK: - Filtering

    private func filter(_ tasks: [OrgTask]) -> [OrgTask] {
        let doneStates = Set((store.keywords?.allDone ?? []).map { $0.uppercased() })
        var result = tasks.filter { task in
            guard let state = task.todoState, !state.isEmpty else { return true }
            return !doneStates.contains(state.uppercased())
        }
        if let maxDays = settings.eisenhowerSpan.days {
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            let cutoff = cal.date(byAdding: .day, value: maxDays, to: today)!
            result = result.filter { task in
                if let dl = task.deadline?.parsedDate {
                    return dl < today || dl <= cutoff
                }
                if let sch = task.scheduled?.parsedDate {
                    return sch <= cutoff
                }
                return false
            }
        }
        if !searchText.isEmpty {
            let needle = searchText.lowercased()
            result = result.filter { task in
                task.title.lowercased().contains(needle)
                    || task.tags.contains(where: { $0.lowercased().contains(needle) })
                    || task.category.lowercased().contains(needle)
            }
        }
        return result
    }

    // MARK: - Layout

    private func matrix(_ tasks: [OrgTask]) -> some View {
        let classified = Dictionary(grouping: tasks, by: classify)
        let doneStates = Set((store.keywords?.allDone ?? []).map { $0.uppercased() })
        let factory = RowActionFactory(
            store: store, settings: settings,
            selection: selection, clocks: clocks, sync: sync
        )

        return VStack(spacing: 1) {
            HStack(spacing: 1) {
                quadrantCell(.doFirst,
                             tasks: sortTasks(classified[.doFirst] ?? [], by: .deadline),
                             doneStates: doneStates, factory: factory)
                quadrantCell(.schedule,
                             tasks: sortTasks(classified[.schedule] ?? [], by: .priority),
                             doneStates: doneStates, factory: factory)
            }
            HStack(spacing: 1) {
                quadrantCell(.delegate,
                             tasks: sortTasks(classified[.delegate] ?? [], by: .deadline),
                             doneStates: doneStates, factory: factory)
                quadrantCell(.eliminate,
                             tasks: sortTasks(classified[.eliminate] ?? [], by: .priority),
                             doneStates: doneStates, factory: factory)
            }
        }
        .background(
            Theme.border
                .onTapGesture { selection.taskId = nil }
        )
    }

    private func quadrantCell(
        _ quadrant: EisenhowerQuadrant,
        tasks: [OrgTask],
        doneStates: Set<String>,
        factory: RowActionFactory
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: quadrant.systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(quadrant.color)
                Text(quadrant.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(quadrant.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Text("\(tasks.count)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(quadrant.color.opacity(0.08))

            if tasks.isEmpty {
                VStack {
                    Spacer()
                    Text("No tasks")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(tasks, id: \.id) { task in
                            let actions = factory.make(for: task)
                            if selection.taskId == task.id {
                                TaskExpandedCard(
                                    store: store,
                                    task: task,
                                    actions: actions,
                                    doneStates: doneStates
                                )
                                .id(task.id)
                            } else {
                                MacTaskRow(
                                    task: task,
                                    isClocked: factory.isClocked(task),
                                    isSelected: false,
                                    doneStates: doneStates,
                                    actions: actions,
                                    progress: factory.progress(for: task),
                                    onAppear: factory.prefetch(for: task)
                                )
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .background(Theme.background)
    }

    // MARK: - Data

    private func load() async {
        guard let client = settings.apiClient else { return }
        await store.ensureInitialized(using: client, settings: settings)
        await store.loadAllTasks(using: client)
    }

    private func loadIfNeeded() async {
        if store.allTasks.value == nil { await load() }
    }
}
