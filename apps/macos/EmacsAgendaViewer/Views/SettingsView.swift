import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    let store: TasksStore
    let notifications: NotificationService

    @State private var urlText: String = ""
    @State private var testState: TestState = .idle

    @State private var todoStates: (active: [String], done: [String]) = ([], [])
    @State private var priorityList: [String] = []
    @State private var loadingStates = false

    @State private var categories: [String] = []
    @State private var loadingCategories = false

    @State private var newHiddenTagText: String = ""

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
        NavigationStack {
            Form {
                serverSection
                appearanceSection
                todaySection(bindable: bindable)
                hiddenEventTagsSection(bindable: bindable)
                notificationsSection(bindable: bindable)
                sortSection(bindable: bindable)
                rowHighlightSection(bindable: bindable)
                progressSection(bindable: bindable)
                todoColorsSection
                priorityColorsSection
                categoryColorsSection
                cachesSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Settings")
        }
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

    // MARK: - Server

    @ViewBuilder
    private var serverSection: some View {
        Section {
            TextField("http://mac.tailnet.ts.net:3001", text: $urlText)
                .textContentType(.URL)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { save() }
            Button("Save") { save() }
                .disabled(urlText.trimmingCharacters(in: .whitespaces) == settings.serverURLString)
            Button("Test connection") { Task { await testConnection() } }
                .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
            testResult
        } header: {
            Text("Server URL")
        } footer: {
            Text("URL of your Emacs Agenda Viewer server. Reachable over Tailscale or local Wi-Fi. Include the port (default 3001).")
        }
    }

    // MARK: - Appearance

    @ViewBuilder
    private var appearanceSection: some View {
        @Bindable var bindable = settings
        Section("Appearance") {
            Picker("Theme", selection: $bindable.appearance) {
                ForEach(AppearancePreference.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Today filters

    @ViewBuilder
    private func todaySection(bindable: AppSettings) -> some View {
        @Bindable var b = bindable
        Section {
            Toggle("Hide upcoming deadlines", isOn: $b.hideUpcomingDeadlines)
                .tint(Theme.accent)
            Toggle("Hide habits in Today", isOn: $b.hideHabitsInToday)
                .tint(Theme.accent)
        } header: {
            Text("Today")
        } footer: {
            Text("Filters that trim what appears in the Today list. Hidden habits still appear in the Habits tab.")
        }
    }

    // MARK: - Hidden event tags

    @ViewBuilder
    private func hiddenEventTagsSection(bindable: AppSettings) -> some View {
        let tags = bindable.hiddenEventTags.sorted()
        Section {
            if tags.isEmpty {
                Text("No calendars hidden. Long-press a calendar event in Today or Upcoming to hide all events with that tag, or add one below.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(tags, id: \.self) { tag in
                    HStack {
                        Image(systemName: "eye.slash")
                            .foregroundStyle(Theme.textTertiary)
                        Text(tag)
                            .font(.system(size: 14, design: .monospaced))
                        Spacer()
                        Button("Show") { bindable.showEventTag(tag) }
                            .buttonStyle(.borderless)
                    }
                }
            }
            HStack {
                TextField("Add tag\u{2026}", text: $newHiddenTagText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit(addHiddenTag)
                Button("Add", action: addHiddenTag)
                    .disabled(newHiddenTagText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Hide Calendars / Tags")
        } footer: {
            Text("Calendar events (org timestamps with no TODO state) whose direct or inherited tag matches anything in this list are hidden from the Events list.")
        }
    }

    private func addHiddenTag() {
        let trimmed = newHiddenTagText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        settings.hideEventTag(trimmed)
        newHiddenTagText = ""
    }

    // MARK: - Notifications

    @ViewBuilder
    private func notificationsSection(bindable: AppSettings) -> some View {
        @Bindable var b = bindable
        Section {
            Toggle("Task reminders", isOn: $b.notificationsEnabled)
                .tint(Theme.accent)

            if settings.notificationsEnabled {
                notificationStatusRow
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Local reminders fire at each task's scheduled time. Only tasks with a scheduled time (not just a date) are notified. iOS caps pending reminders at 60 — the soonest scheduled win.")
        }
    }

    @ViewBuilder
    private var notificationStatusRow: some View {
        switch notifications.authStatus {
        case .denied:
            Label {
                Text("Denied in iOS Settings → Notifications → Agenda")
                    .font(.footnote)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.priorityA)
            }
        case .notDetermined:
            Button("Allow notifications") {
                Task { _ = await notifications.requestAuthorization() }
            }
        case .authorized, .provisional, .ephemeral:
            Label {
                Text("Reminders active")
                    .font(.footnote)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.doneGreen)
            }
        @unknown default:
            EmptyView()
        }
        if let err = notifications.lastError {
            Text(err).font(.caption).foregroundStyle(Theme.priorityA)
        }
    }

    // MARK: - Default Sort

    @ViewBuilder
    private func sortSection(bindable: AppSettings) -> some View {
        @Bindable var b = bindable
        Section("Default Sort") {
            Picker("Today / Upcoming", selection: $b.agendaSort) {
                ForEach(SortKey.agendaOptions) { Text($0.label).tag($0) }
            }
            Picker("All Tasks", selection: $b.listSort) {
                ForEach(SortKey.listOptions) { Text($0.label).tag($0) }
            }
        }
    }

    // MARK: - Row highlight

    @ViewBuilder
    private func rowHighlightSection(bindable: AppSettings) -> some View {
        @Bindable var b = bindable
        Section {
            Picker("Highlight by", selection: $b.rowHighlightMode) {
                ForEach(RowHighlightMode.allCases) { Text($0.label).tag($0) }
            }
            if settings.rowHighlightMode != .none {
                Picker("Style", selection: $b.rowHighlightStyle) {
                    ForEach(RowHighlightStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        } header: {
            Text("Row Highlight")
        } footer: {
            Text(highlightHelp)
        }
    }

    // MARK: - Checklist progress

    @ViewBuilder
    private func progressSection(bindable: AppSettings) -> some View {
        @Bindable var b = bindable
        Section {
            Picker("Progress style", selection: $b.rowProgressStyle) {
                ForEach(RowProgressStyle.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Checklist Progress")
        } footer: {
            Text("How task rows show their checklist completion.")
        }
    }

    // MARK: - TODO state colors

    @ViewBuilder
    private var todoColorsSection: some View {
        Section {
            if todoStates.active.isEmpty && todoStates.done.isEmpty {
                colorsEmptyRow(loading: loadingStates, label: "TODO states")
            } else {
                if !todoStates.active.isEmpty {
                    Text("Active").font(.caption).foregroundStyle(Theme.textSecondary)
                    ForEach(todoStates.active, id: \.self) { state in
                        todoStateRow(state, isDone: false)
                    }
                    .id(settings.colorRevision)
                }
                if !todoStates.done.isEmpty {
                    Text("Done").font(.caption).foregroundStyle(Theme.textSecondary)
                    ForEach(todoStates.done, id: \.self) { state in
                        todoStateRow(state, isDone: true)
                    }
                    .id(settings.colorRevision)
                }
                HStack {
                    Spacer()
                    Button("Refresh") { Task { await loadStatesAndPriorities() } }
                    Button("Reset all") { settings.clearTodoStateColors() }
                }
            }
        } header: {
            Text("TODO State Colors")
        } footer: {
            Text("Customize the color for each TODO state. New states from Emacs are detected on startup.")
        }
    }

    // MARK: - Priority colors

    @ViewBuilder
    private var priorityColorsSection: some View {
        Section {
            if priorityList.isEmpty {
                colorsEmptyRow(loading: loadingStates, label: "priorities")
            } else {
                ForEach(priorityList, id: \.self) { priorityRow($0) }
                    .id(settings.colorRevision)
                HStack {
                    Spacer()
                    Button("Refresh") { Task { await loadStatesAndPriorities() } }
                    Button("Reset all") { settings.clearPriorityColors() }
                }
            }
        } header: {
            Text("Priority Colors")
        } footer: {
            Text("Customize the color for each priority level. Stored per server URL.")
        }
    }

    // MARK: - Category colors

    @ViewBuilder
    private var categoryColorsSection: some View {
        Section {
            if categories.isEmpty {
                colorsEmptyRow(loading: loadingCategories, label: "categories")
            } else {
                ForEach(categories, id: \.self) { categoryRow($0) }
                    .id(settings.colorRevision)
                HStack {
                    Spacer()
                    Button("Refresh") { Task { await loadCategories() } }
                    Button("Reset all") { settings.clearCategoryColors() }
                }
            }
        } header: {
            Text("Category Colors")
        } footer: {
            Text("Override the auto-assigned color for each category. Stored per server URL.")
        }
    }

    // MARK: - Caches

    @ViewBuilder
    private var cachesSection: some View {
        Section {
            Button("Refresh All Data") { Task { await refreshAll() } }
                .disabled(!settings.isConfigured)
        } header: {
            Text("Caches")
        } footer: {
            Text("Force a full reload of tasks, metadata, refile targets, and capture templates from the Emacs server.")
        }
    }

    // MARK: - About

    @ViewBuilder
    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: Bundle.main.shortVersion)
            LabeledContent("Build", value: Bundle.main.buildVersion)
        }
    }

    // MARK: - Color rows

    @ViewBuilder
    private func colorsEmptyRow(loading: Bool, label: String) -> some View {
        HStack {
            if loading {
                ProgressView().controlSize(.small)
                Text("Loading \(label)\u{2026}")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            } else {
                Text("No \(label) found. Save a server URL to fetch.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button("Refresh") {
                Task {
                    await loadCategories()
                    await loadStatesAndPriorities()
                }
            }
            .disabled(!settings.isConfigured)
        }
    }

    @ViewBuilder
    private func todoStateRow(_ state: String, isDone: Bool) -> some View {
        let currentHex = settings.todoStateColorHex(for: state)
        let currentColor = currentHex.flatMap { Color(hex: $0) }
            ?? AppSettings.defaultTodoStateColor(state, isDone: isDone)
        ColorEditRow(
            currentHex: currentHex,
            currentColor: currentColor,
            defaultIndicator: "default",
            pickerLabel: state,
            onSet: { settings.setTodoStateColorHex($0, for: state) },
            onReset: { settings.setTodoStateColorHex(nil, for: state) }
        ) {
            Text(state)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(currentColor)
        }
    }

    @ViewBuilder
    private func priorityRow(_ priority: String) -> some View {
        let currentHex = settings.priorityColorHex(for: priority)
        let currentColor = currentHex.flatMap { Color(hex: $0) }
            ?? AppSettings.defaultPriorityColor(priority)
        ColorEditRow(
            currentHex: currentHex,
            currentColor: currentColor,
            defaultIndicator: "default",
            pickerLabel: "Priority \(priority)",
            onSet: { settings.setPriorityColorHex($0, for: priority) },
            onReset: { settings.setPriorityColorHex(nil, for: priority) }
        ) {
            HStack(spacing: 6) {
                Circle().fill(currentColor).frame(width: 10, height: 10)
                Text(priority).font(.system(size: 14, weight: .semibold))
            }
        }
    }

    @ViewBuilder
    private func categoryRow(_ category: String) -> some View {
        let currentHex = settings.categoryColorHex(for: category)
        // iOS doesn't have CalendarGridItem.color; fall back to a deterministic
        // hash-based default so the picker has a sensible starting value.
        let currentColor = (currentHex.flatMap { Color(hex: $0) })
            ?? defaultCategoryColor(category)
        ColorEditRow(
            currentHex: currentHex,
            currentColor: currentColor,
            defaultIndicator: "auto",
            pickerLabel: category,
            onSet: { settings.setCategoryColorHex($0, for: category) },
            onReset: { settings.setCategoryColorHex(nil, for: category) }
        ) {
            Text(category)
                .font(.system(size: 14))
        }
    }

    /// Stable category color derived from a small palette via title hash.
    /// Used only as a starting value for the picker — the Mac uses
    /// `CalendarGridItem.color(forCategory:)`, which lives in the Mac target.
    private func defaultCategoryColor(_ category: String) -> Color {
        let palette: [Color] = [
            Theme.accent, Theme.accentTeal, Theme.priorityB, Theme.doneGreen,
            Color(red: 175/255, green: 82/255, blue: 222/255), // purple
            Color(red: 255/255, green: 204/255, blue: 0/255),  // yellow
            Color(red: 142/255, green: 142/255, blue: 147/255) // gray
        ]
        let idx = abs(category.hashValue) % palette.count
        return palette[idx]
    }

    // MARK: - Test result

    @ViewBuilder
    private var testResult: some View {
        switch testState {
        case .idle: EmptyView()
        case .testing:
            HStack { ProgressView().controlSize(.small); Text("Testing\u{2026}") }
                .foregroundStyle(Theme.textSecondary)
        case .success(let msg):
            Label(msg, systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.doneGreen)
        case .failure(let msg):
            Label(msg, systemImage: "xmark.octagon.fill")
                .foregroundStyle(Theme.priorityA)
        }
    }

    // MARK: - Actions

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

    private func refreshAll() async {
        guard let client = settings.apiClient else { return }
        await store.loadMetadata(using: client, settings: settings)
        await store.refreshLoaded(using: client)
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
}

private extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
    }
    var buildVersion: String {
        (infoDictionary?["CFBundleVersion"] as? String) ?? "—"
    }
}
