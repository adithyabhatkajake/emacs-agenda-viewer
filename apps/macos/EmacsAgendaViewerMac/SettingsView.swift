import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(EventKitService.self) private var eventKit
    @State private var urlText: String = ""
    @State private var testState: TestState = .idle
    @State private var categories: [String] = []
    @State private var loadingCategories = false

    enum TestState: Equatable {
        case idle, testing, success(String), failure(String)
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
            Task { await loadCategories() }
        }
        .onChange(of: settings.serverURLString) { _, _ in
            categories = []
            Task { await loadCategories() }
        }
    }

    @ViewBuilder
    private func categoryRow(_ category: String) -> some View {
        // Read the revision so the row re-renders when the user changes a color elsewhere.
        let _ = settings.categoryColorsRevision
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
