import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var urlText: String = ""
    @State private var testState: TestState = .idle

    enum TestState: Equatable {
        case idle, testing, success(String), failure(String)
    }

    var body: some View {
        @Bindable var settingsBindable = settings
        NavigationStack {
            Form {
                Section {
                    TextField("http://mac.tailnet.ts.net:3001", text: $urlText)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { save() }
                    Button("Save") { save() }
                        .disabled(urlText.trimmingCharacters(in: .whitespaces) == settings.serverURLString)
                    Button("Test connection") {
                        Task { await testConnection() }
                    }
                    .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                    testResult
                } header: {
                    Text("Server URL")
                } footer: {
                    Text("The URL of your Emacs Agenda Viewer server. Reachable over Tailscale or local Wi-Fi. Include the port (default 3001).")
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.shortVersion)
                    LabeledContent("Build", value: Bundle.main.buildVersion)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Settings")
        }
        .onAppear { urlText = settings.serverURLString }
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
