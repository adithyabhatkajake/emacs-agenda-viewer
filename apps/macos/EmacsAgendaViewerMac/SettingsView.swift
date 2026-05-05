import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(EventKitService.self) private var eventKit
    @State private var urlText: String = ""
    @State private var testState: TestState = .idle
    @State private var categories: [String] = []
    @State private var loadingCategories = false
    @State private var todoStates: (active: [String], done: [String]) = ([], [])
    @State private var priorityList: [String] = []
    @State private var loadingStates = false

    enum TestState: Equatable {
        case idle, testing, success(String), failure(String)
    }

    private var highlightHelp: String {
        switch settings.rowHighlightMode {
        case .none: return "Tasks render with no extra emphasis."
        case .priority: return "Tasks pick up their priority color (A red · B orange · C blue · D gray)."
        case .todoState: return "Tasks pick up their TODO-state color from the keyword palette."
        }
    }

    var body: some View {
        @Bindable var bindable = settings
        Form {
            Section {
                TextField("Server URL", text: $urlText, prompt: Text("http://mac.tailnet.ts.net:3001"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onSubmit { save() }

                HStack {
                    Button("Save") { save() }
                        .disabled(urlText.trimmingCharacters(in: .whitespaces) == settings.serverURLString)
                    Button("Test connection") {
                        Task { await testConnection() }
                    }
                    .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                    Spacer()
                }

                testResult
            } header: {
                Text("Server")
            } footer: {
                Text("URL of your Emacs Agenda Viewer server. Reachable over Tailscale or local network. Include the port (default 3001).")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            Section("Appearance") {
                Picker("Theme", selection: $bindable.appearance) {
                    ForEach(AppearancePreference.allCases) { pref in
                        Text(pref.label).tag(pref)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Row Highlight") {
                Picker("Highlight by", selection: $bindable.rowHighlightMode) {
                    ForEach(RowHighlightMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                if settings.rowHighlightMode != .none {
                    Picker("Style", selection: $bindable.rowHighlightStyle) {
                        ForEach(RowHighlightStyle.allCases) { s in
                            Text(s.label).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Text(highlightHelp)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            Section("Checklist Progress") {
                Picker("Progress style", selection: $bindable.rowProgressStyle) {
                    ForEach(RowProgressStyle.allCases) { s in
                        Text(s.label).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                Text("How task rows show their checklist completion.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            Section("Default Sort") {
                Picker("Today / Upcoming", selection: $bindable.agendaSort) {
                    ForEach(SortKey.agendaOptions) { key in
                        Text(key.label).tag(key)
                    }
                }
                Picker("All Tasks", selection: $bindable.listSort) {
                    ForEach(SortKey.listOptions) { key in
                        Text(key.label).tag(key)
                    }
                }
            }

            Section("Calendar Sync (EventKit)") {
                if !eventKit.hasAccess {
                    Text("Connect to macOS Calendar to push events into Apple, Google, or iCloud calendars.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Button("Grant Calendar Access") {
                        Task { await eventKit.requestAccess() }
                    }
                } else {
                    Picker("Default calendar", selection: Binding(
                        get: { settings.eventKitCalendarIdentifier ?? "" },
                        set: { settings.eventKitCalendarIdentifier = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("System default").tag("")
                        ForEach(eventKit.calendars, id: \.calendarIdentifier) { c in
                            HStack {
                                Circle().fill(Color(c.color)).frame(width: 10, height: 10)
                                Text(c.title)
                            }
                            .tag(c.calendarIdentifier)
                        }
                    }
                    Button("Refresh calendars") { eventKit.reloadCalendars() }
                        .controlSize(.small)
                }
                if let err = eventKit.lastError {
                    Text(err).font(.caption).foregroundStyle(Theme.priorityA)
                }
            }

            if eventKit.hasAccess {
                Section {
                    ForEach(eventKit.allCalendars.sorted(by: { $0.title < $1.title }),
                            id: \.calendarIdentifier) { cal in
                        @Bindable var bindable = settings
                        Toggle(isOn: Binding(
                            get: { !settings.hiddenCalendarIds.contains(cal.calendarIdentifier) },
                            set: { visible in
                                if visible {
                                    settings.hiddenCalendarIds.remove(cal.calendarIdentifier)
                                } else {
                                    settings.hiddenCalendarIds.insert(cal.calendarIdentifier)
                                }
                            }
                        )) {
                            HStack(spacing: 6) {
                                Circle().fill(Color(cal.color)).frame(width: 10, height: 10)
                                Text(cal.title)
                                    .font(.system(size: 12))
                                Text(cal.source.title)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                } header: {
                    Text("Visible Calendars")
                } footer: {
                    Text("Unchecked calendars are hidden from the calendar grid. Events from hidden calendars won't appear.")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }

            Section {
                if todoStates.active.isEmpty && todoStates.done.isEmpty {
                    HStack {
                        if loadingStates {
                            ProgressView().controlSize(.small)
                            Text("Loading states…").font(.caption).foregroundStyle(Theme.textSecondary)
                        } else {
                            Text("No TODO states found. Save a server URL to fetch.")
                                .font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Button("Refresh") { Task { await loadStatesAndPriorities() } }
                            .controlSize(.small)
                            .disabled(!settings.isConfigured || loadingStates)
                    }
                } else {
                    if !todoStates.active.isEmpty {
                        Text("Active").font(.caption).foregroundStyle(Theme.textSecondary)
                        ForEach(todoStates.active, id: \.self) { state in
                            todoStateRow(state, isDone: false)
                        }
                    }
                    if !todoStates.done.isEmpty {
                        Text("Done").font(.caption).foregroundStyle(Theme.textSecondary)
                        ForEach(todoStates.done, id: \.self) { state in
                            todoStateRow(state, isDone: true)
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Refresh") { Task { await loadStatesAndPriorities() } }
                            .controlSize(.small)
                        Button("Reset all") { settings.clearTodoStateColors() }
                            .controlSize(.small)
                    }
                }
            } header: {
                Text("TODO State Colors")
            } footer: {
                Text("Customize the color for each TODO state. New states from Emacs are detected on startup.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }

            Section {
                if priorityList.isEmpty {
                    HStack {
                        if loadingStates {
                            ProgressView().controlSize(.small)
                            Text("Loading priorities…").font(.caption).foregroundStyle(Theme.textSecondary)
                        } else {
                            Text("No priorities found. Save a server URL to fetch.")
                                .font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Button("Refresh") { Task { await loadStatesAndPriorities() } }
                            .controlSize(.small)
                            .disabled(!settings.isConfigured || loadingStates)
                    }
                } else {
                    ForEach(priorityList, id: \.self) { priority in
                        priorityRow(priority)
                    }
                    HStack {
                        Spacer()
                        Button("Refresh") { Task { await loadStatesAndPriorities() } }
                            .controlSize(.small)
                        Button("Reset all") { settings.clearPriorityColors() }
                            .controlSize(.small)
                    }
                }
            } header: {
                Text("Priority Colors")
            } footer: {
                Text("Customize the color for each priority level. Stored per server URL.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }

            Section {
                if categories.isEmpty {
                    HStack {
                        if loadingCategories {
                            ProgressView().controlSize(.small)
                            Text("Loading categories…").font(.caption).foregroundStyle(Theme.textSecondary)
                        } else {
                            Text("No categories found. Save a server URL to fetch.")
                                .font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Button("Refresh") { Task { await loadCategories() } }
                            .controlSize(.small)
                            .disabled(!settings.isConfigured || loadingCategories)
                    }
                } else {
                    ForEach(categories, id: \.self) { cat in
                        categoryRow(cat)
                    }
                    HStack {
                        Spacer()
                        Button("Refresh") { Task { await loadCategories() } }
                            .controlSize(.small)
                        Button("Reset all") { settings.clearCategoryColors() }
                            .controlSize(.small)
                    }
                }
            } header: {
                Text("Category Colors")
            } footer: {
                Text("Override the auto-assigned color for each category. Stored per server URL.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }

            Section {
                Button("Refresh All Data") {
                    NotificationCenter.default.post(name: .eav_refreshAll, object: nil)
                }
                .help("Clears cached data and reloads tasks, metadata, and refile targets from the server.")
            } header: {
                Text("Caches")
            } footer: {
                Text("Force a full reload of all tasks, metadata, refile targets, and capture templates from the Emacs server.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.shortVersion)
                LabeledContent("Build", value: Bundle.main.buildVersion)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .onAppear {
            urlText = settings.serverURLString
            if let cached = settings.cachedTodoKeywords {
                todoStates = (cached.allActive, cached.allDone)
            }
            if let cached = settings.cachedPriorities {
                priorityList = cached.all
            }
            Task {
                await loadCategories()
                await loadStatesAndPriorities()
            }
        }
        .onChange(of: settings.serverURLString) { _, _ in
            categories = []
            todoStates = ([], [])
            priorityList = []
            Task {
                await loadCategories()
                await loadStatesAndPriorities()
            }
        }
    }

    @ViewBuilder
    private func categoryRow(_ category: String) -> some View {
        // Read the revision so the row re-renders when the user changes a color elsewhere.
        let _ = settings.colorRevision
        let currentHex = settings.categoryColorHex(for: category)
        let currentColor = (currentHex.flatMap { Color(hex: $0) })
            ?? CalendarGridItem.color(forCategory: category)

        HStack {
            ColorPicker("", selection: Binding(
                get: { currentColor },
                set: { newValue in
                    if let hex = newValue.hexString() {
                        settings.setCategoryColorHex(hex, for: category)
                    }
                }
            ), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 36)

            Text(category)
                .font(.system(size: 12))

            Spacer()

            if currentHex != nil {
                Text("custom")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                Button("Reset") { settings.setCategoryColorHex(nil, for: category) }
                    .controlSize(.small)
            } else {
                Text("auto")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    @ViewBuilder
    private func todoStateRow(_ state: String, isDone: Bool) -> some View {
        let _ = settings.colorRevision
        let currentHex = settings.todoStateColorHex(for: state)
        let currentColor = currentHex.flatMap { Color(hex: $0) }
            ?? AppSettings.defaultTodoStateColor(state, isDone: isDone)

        HStack {
            ColorPicker("", selection: Binding(
                get: { currentColor },
                set: { newValue in
                    if let hex = newValue.hexString() {
                        settings.setTodoStateColorHex(hex, for: state)
                    }
                }
            ), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 36)

            Text(state)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(currentColor)

            Spacer()

            if currentHex != nil {
                Text("custom")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                Button("Reset") { settings.setTodoStateColorHex(nil, for: state) }
                    .controlSize(.small)
            } else {
                Text("default")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    @ViewBuilder
    private func priorityRow(_ priority: String) -> some View {
        let _ = settings.colorRevision
        let currentHex = settings.priorityColorHex(for: priority)
        let currentColor = currentHex.flatMap { Color(hex: $0) }
            ?? AppSettings.defaultPriorityColor(priority)

        HStack {
            ColorPicker("", selection: Binding(
                get: { currentColor },
                set: { newValue in
                    if let hex = newValue.hexString() {
                        settings.setPriorityColorHex(hex, for: priority)
                    }
                }
            ), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 36)

            HStack(spacing: 4) {
                Circle().fill(currentColor).frame(width: 8, height: 8)
                Text(priority)
                    .font(.system(size: 12, weight: .semibold))
            }

            Spacer()

            if currentHex != nil {
                Text("custom")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                Button("Reset") { settings.setPriorityColorHex(nil, for: priority) }
                    .controlSize(.small)
            } else {
                Text("default")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func loadStatesAndPriorities() async {
        guard let client = settings.apiClient else { return }
        loadingStates = true
        defer { loadingStates = false }
        async let kwResult = try? client.fetchKeywords()
        async let prResult = try? client.fetchPriorities()
        if let kw = await kwResult {
            let active = Array(Set(kw.allActive)).sorted()
            let done = Array(Set(kw.allDone)).sorted()
            todoStates = (active, done)
            settings.cachedTodoKeywords = kw
        } else if let cached = settings.cachedTodoKeywords {
            todoStates = (cached.allActive, cached.allDone)
        }
        if let pr = await prResult {
            priorityList = pr.all
            settings.cachedPriorities = pr
        } else if let cached = settings.cachedPriorities {
            priorityList = cached.all
        }
    }

    private func loadCategories() async {
        guard let client = settings.apiClient else { return }
        loadingCategories = true
        defer { loadingCategories = false }
        do {
            let files = try await client.fetchFiles()
            let unique = Array(Set(files.map(\.category).filter { !$0.isEmpty })).sorted()
            categories = unique
        } catch {
            // Keep existing list on failure.
        }
    }

    @ViewBuilder
    private var testResult: some View {
        switch testState {
        case .idle: EmptyView()
        case .testing:
            HStack { ProgressView().controlSize(.small); Text("Testing…") }
                .foregroundStyle(Theme.textSecondary)
        case .success(let msg):
            Label(msg, systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.doneGreen)
        case .failure(let msg):
            Label(msg, systemImage: "xmark.octagon.fill")
                .foregroundStyle(Theme.priorityA)
        }
    }

    private func save() {
        settings.serverURLString = urlText.trimmingCharacters(in: .whitespaces)
    }

    private func testConnection() async {
        let trimmed = urlText.trimmingCharacters(in: .whitespaces)
        guard let client = APIClient(baseURLString: trimmed) else {
            testState = .failure("Invalid URL")
            return
        }
        testState = .testing
        do {
            let config = try await client.fetchConfig()
            testState = .success("Connected (deadline warning: \(config.deadlineWarningDays) days)")
            if trimmed != settings.serverURLString {
                settings.serverURLString = trimmed
            }
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            testState = .failure(msg)
        }
    }
}

private extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
    }
    var buildVersion: String {
        (infoDictionary?["CFBundleVersion"] as? String) ?? "—"
    }
}
