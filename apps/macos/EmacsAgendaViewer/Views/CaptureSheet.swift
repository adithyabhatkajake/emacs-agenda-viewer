#if !os(macOS)
import SwiftUI

/// Minimal iOS capture flow. Picks an org-capture template, takes a title,
/// optionally attaches a scheduled / deadline timestamp + priority, then
/// POSTs to /api/capture. The full Mac CaptureSheet handles %^{prompt}
/// templates with arbitrary prompt types; on iOS we deliberately keep the
/// surface small. If a template requires prompt answers we don't support,
/// the daemon returns an error and the sheet shows it inline.
struct CaptureSheet: View {
    let store: TasksStore

    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings

    @State private var templates: [CaptureTemplate] = []
    @State private var templatesLoading: Bool = true
    @State private var templatesError: String?

    @State private var selectedKey: String = ""
    @State private var title: String = ""

    @State private var includeScheduled: Bool = false
    @State private var scheduledDate: Date = Date()
    @State private var includeScheduledTime: Bool = false

    @State private var includeDeadline: Bool = false
    @State private var deadlineDate: Date = Date()
    @State private var includeDeadlineTime: Bool = false

    @State private var priority: String = ""

    /// One entry per `%^{prompt}` in the selected template, in declaration
    /// order. Reset whenever the user picks a different template so a
    /// previously-typed value doesn't leak across templates.
    @State private var promptAnswers: [String] = []

    @State private var isSaving: Bool = false
    @State private var errorMessage: String?
    @FocusState private var titleFocused: Bool
    @FocusState private var anyFieldFocused: Bool

    private var client: APIClient? { settings.apiClient }

    /// Concrete templates only — drop is-group entries (org-capture parent
    /// nodes that just open a sub-menu of templates).
    private var captureTargets: [CaptureTemplate] {
        templates.filter { !$0.isGroup }
    }

    private var selected: CaptureTemplate? {
        captureTargets.first { $0.key == selectedKey }
    }

    private var canSave: Bool {
        !isSaving && client != nil && selected != nil
        && !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                if templatesLoading {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Loading capture templates\u{2026}")
                            .foregroundStyle(Theme.textSecondary)
                    }
                } else if let err = templatesError {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.priorityA)
                        Button("Retry") { Task { await loadTemplates() } }
                    }
                } else if captureTargets.isEmpty {
                    Text("No capture templates configured. Add some via `org-capture-templates` in Emacs.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Section("Template") {
                        Picker("Capture as", selection: $selectedKey) {
                            ForEach(captureTargets) { t in
                                Text(t.description.isEmpty ? t.key : t.description)
                                    .tag(t.key)
                            }
                        }
                        if let t = selected, let target = formatTarget(t) {
                            Text(target)
                                .font(.caption2)
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }

                    Section("Title") {
                        TextField("What needs doing?", text: $title, axis: .vertical)
                            .lineLimit(1...3)
                            .focused($titleFocused)
                            .submitLabel(.done)
                    }

                    if let prompts = selected?.prompts, !prompts.isEmpty {
                        Section("Template fields") {
                            ForEach(Array(prompts.enumerated()), id: \.offset) { idx, prompt in
                                promptField(idx: idx, prompt: prompt)
                            }
                        }
                    }

                    Section("Priority") {
                        Picker("Priority", selection: $priority) {
                            Text("None").tag("")
                            ForEach(priorityChoices, id: \.self) { p in
                                Text(p).tag(p)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    TimestampField(
                        label: "Scheduled",
                        toggleLabel: "Add scheduled date",
                        isEnabled: $includeScheduled,
                        date: $scheduledDate,
                        time: $scheduledDate,
                        includeTime: $includeScheduledTime
                    )

                    TimestampField(
                        label: "Deadline",
                        toggleLabel: "Add deadline",
                        isEnabled: $includeDeadline,
                        date: $deadlineDate,
                        time: $deadlineDate,
                        includeTime: $includeDeadlineTime
                    )

                    if let err = errorMessage {
                        Section {
                            Text(err).foregroundStyle(Theme.priorityA).font(.footnote)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            // Interactive dismiss so the user can scroll to Save without
            // manually tapping outside the keyboard first.
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("New Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(!canSave)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        titleFocused = false
                        anyFieldFocused = false
                    }
                }
            }
        }
        .task { await loadTemplates() }
        .onChange(of: selectedKey) { _, _ in
            // Re-size the answer array to the new template's prompt count
            // and clear values — answers from the previous template don't
            // map onto a different prompt schema.
            promptAnswers = Array(repeating: "", count: selected?.prompts?.count ?? 0)
        }
    }

    // MARK: - Prompt UI

    @ViewBuilder
    private func promptField(idx: Int, prompt: CapturePrompt) -> some View {
        let binding = Binding<String>(
            get: { idx < promptAnswers.count ? promptAnswers[idx] : "" },
            set: { newValue in
                while promptAnswers.count <= idx { promptAnswers.append("") }
                promptAnswers[idx] = newValue
            }
        )
        let label = prompt.name.isEmpty ? "Field \(idx + 1)" : prompt.name

        switch prompt.type {
        case "date":
            promptDateRow(label: label, binding: binding)
        case "tags":
            HStack {
                Text(label).foregroundStyle(Theme.textPrimary)
                Spacer()
                TextField("tag1:tag2", text: binding)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        case "property":
            HStack {
                Text(label).foregroundStyle(Theme.textPrimary)
                Spacer()
                TextField("Value", text: binding)
                    .multilineTextAlignment(.trailing)
            }
        default:
            if prompt.options.isEmpty {
                HStack {
                    Text(label).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    TextField("", text: binding)
                        .multilineTextAlignment(.trailing)
                }
            } else {
                // Free-text + preset options: a Picker for the listed values,
                // a separate text field below for an override. Mirrors the
                // Mac behavior where the user can pick from suggestions or
                // type anything they like.
                Picker(label, selection: binding) {
                    if !prompt.options.contains(binding.wrappedValue) && !binding.wrappedValue.isEmpty {
                        Text(binding.wrappedValue).tag(binding.wrappedValue)
                    }
                    Text("\u{2014}").tag("")
                    ForEach(prompt.options, id: \.self) { opt in
                        Text(opt).tag(opt)
                    }
                }
                HStack {
                    Text("\(label) (custom)")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                    TextField("\u{2014}", text: binding)
                        .font(.caption)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    @ViewBuilder
    private func promptDateRow(label: String, binding: Binding<String>) -> some View {
        // Org-style timestamp helpers — strip <...> from prior answers so the
        // DatePicker can round-trip. Daemon accepts either form.
        let parsedDate: Binding<Date> = Binding(
            get: { Self.parseOrgDate(binding.wrappedValue) ?? Date() },
            set: { binding.wrappedValue = Self.formatOrgDate($0) }
        )
        let isSet = !binding.wrappedValue.isEmpty

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).foregroundStyle(Theme.textPrimary)
                Spacer()
                if isSet {
                    Button { binding.wrappedValue = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button("Pick date") {
                        binding.wrappedValue = Self.formatOrgDate(Date())
                    }
                    .buttonStyle(.borderless)
                }
            }
            if isSet {
                DatePicker("", selection: parsedDate, displayedComponents: .date)
                    .labelsHidden()
            }
        }
    }

    private static func parseOrgDate(_ raw: String) -> Date? {
        let stripped = raw
            .replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: ">", with: "")
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .trimmingCharacters(in: .whitespaces)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd EEE HH:mm", "yyyy-MM-dd EEE", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: stripped) { return d }
        }
        return nil
    }

    private static func formatOrgDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd EEE"
        return f.string(from: d)
    }

    // MARK: - Data

    private func loadTemplates() async {
        templatesLoading = true
        templatesError = nil
        guard let client else {
            templatesError = "No server configured"
            templatesLoading = false
            return
        }
        do {
            let fetched = try await client.fetchCaptureTemplates()
            templates = fetched
            let usable = fetched.filter { !$0.isGroup }
            // Restore the user's last-used template if it still exists,
            // otherwise default to the first concrete entry.
            if let last = settings.lastCaptureTemplateKey,
               usable.contains(where: { $0.key == last }) {
                selectedKey = last
            } else if let first = usable.first {
                selectedKey = first.key
            }
            templatesLoading = false
            // Auto-focus the title field once data has settled so the user
            // can just type immediately on tap-FAB.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                titleFocused = true
            }
        } catch {
            templatesError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            templatesLoading = false
        }
    }

    private func save() async {
        guard let client, let template = selected else { return }
        isSaving = true
        errorMessage = nil
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        do {
            // Pad / trim promptAnswers to the template's declared prompt
            // count. Daemon expects one answer per declared prompt; sending
            // a short array surfaces as "missing %^{} substitution" errors.
            let expectedPrompts = template.prompts?.count ?? 0
            var answers = promptAnswers
            while answers.count < expectedPrompts { answers.append("") }
            if answers.count > expectedPrompts {
                answers = Array(answers.prefix(expectedPrompts))
            }

            try await client.captureTask(
                templateKey: template.key,
                title: trimmed,
                priority: priority.isEmpty ? nil : priority,
                scheduled: includeScheduled
                    ? OrgTimestampFormat.string(date: scheduledDate, includeTime: includeScheduledTime)
                    : nil,
                deadline: includeDeadline
                    ? OrgTimestampFormat.string(date: deadlineDate, includeTime: includeDeadlineTime)
                    : nil,
                promptAnswers: expectedPrompts == 0 ? nil : answers
            )
            settings.lastCaptureTemplateKey = template.key
            await store.refreshLoaded(using: client)
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
        isSaving = false
    }

    // MARK: - Helpers

    private var priorityChoices: [String] {
        let server = store.priorities?.all ?? []
        return server.isEmpty ? ["A", "B", "C"] : server
    }

    private func formatTarget(_ t: CaptureTemplate) -> String? {
        var parts: [String] = []
        if let f = t.targetFile, !f.isEmpty {
            parts.append(URL(fileURLWithPath: f).lastPathComponent)
        }
        if let h = t.targetHeadline, !h.isEmpty {
            parts.append(h)
        }
        return parts.isEmpty ? nil : "\u{2192} " + parts.joined(separator: " \u{203A} ")
    }

}
#endif
