import SwiftUI

// MARK: - Capture Sheet

struct CaptureSheet: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    let store: TasksStore
    let onCaptured: () -> Void

    @State private var templates: [CaptureTemplate] = []
    @State private var loading = true
    @State private var submitting = false
    @State private var errorMessage: String?

    @State private var selectedKey: String = ""
    @State private var title: String = ""
    @State private var todoState: String = ""
    @State private var priority: String = ""
    @State private var tags: String = ""
    @State private var scheduledDate: Date?
    @State private var scheduledHasTime = false
    @State private var deadlineDate: Date?
    @State private var deadlineHasTime = false
    @State private var promptValues: [String] = []

    private var selected: CaptureTemplate? {
        templates.first { $0.key == selectedKey && !$0.isGroup }
    }

    private var parsed: ParsedTemplate? {
        guard let tpl = selected else { return nil }
        return TemplateParser.parse(tpl, keywords: store.keywords)
    }

    private var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && selected != nil
            && selected?.targetFile != nil
            && !submitting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if loading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(minHeight: 200)
            } else if templates.filter({ !$0.isGroup && $0.webSupported }).isEmpty {
                emptyState
            } else {
                ScrollView {
                    formContent.padding(20)
                }
            }
            Divider()
            footer
        }
        .frame(width: 500)
        .frame(minHeight: 320)
        .task { await loadTemplates() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(Theme.accent)
            Text("Capture").font(.headline)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundStyle(Theme.textTertiary)
            Text("No capture templates found")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Text("Configure org-capture-templates in your Emacs config.")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 200)
    }

    // MARK: - Form

    @ViewBuilder
    private var formContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            templatePicker

            if selected != nil {
                titleField
                stateAndPriority

                if let tpl = selected, let prompts = tpl.prompts, !prompts.isEmpty {
                    promptFields(prompts)
                }

                if let p = parsed {
                    if !p.tags.isEmpty {
                        tagsField
                    }

                    dateRow(label: "Scheduled", icon: "calendar", tint: Theme.accent,
                            date: $scheduledDate, hasTime: $scheduledHasTime)
                    dateRow(label: "Deadline", icon: "flag.fill", tint: Theme.priorityA,
                            date: $deadlineDate, hasTime: $deadlineHasTime)
                }

                if let tpl = selected {
                    targetInfo(tpl)
                }
            }

            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(Theme.priorityA)
            }
        }
    }

    private var templatePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TEMPLATE")
                .font(.system(size: 9, weight: .bold)).tracking(0.6)
                .foregroundStyle(Theme.textTertiary)
            Picker("", selection: $selectedKey) {
                Text("Select a template…").tag("")
                ForEach(groupedTemplates, id: \.id) { item in
                    switch item {
                    case .group(let g):
                        Text(g.description).tag("").disabled(true)
                    case .template(let t):
                        templateLabel(t).tag(t.key)
                    }
                }
            }
            .labelsHidden()
            .onChange(of: selectedKey) { _, _ in prefillFromTemplate() }
        }
    }

    @ViewBuilder
    private func templateLabel(_ t: CaptureTemplate) -> some View {
        let prefix = t.key.count > 1 ? "  " : ""
        Text("\(prefix)\(t.description)")
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TITLE")
                .font(.system(size: 9, weight: .bold)).tracking(0.6)
                .foregroundStyle(Theme.textTertiary)
            TextField("Task title", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14))
                .onSubmit { if canSubmit { Task { await submit() } } }
        }
    }

    private var stateAndPriority: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("STATE")
                    .font(.system(size: 9, weight: .bold)).tracking(0.6)
                    .foregroundStyle(Theme.textTertiary)
                Picker("", selection: $todoState) {
                    Text("—").tag("")
                    ForEach(store.keywords?.allActive ?? ["TODO"], id: \.self) { s in
                        Text(s).tag(s)
                    }
                    ForEach(store.keywords?.allDone ?? ["DONE"], id: \.self) { s in
                        Text(s).tag(s)
                    }
                }
                .labelsHidden()
                .frame(minWidth: 100)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("PRIORITY")
                    .font(.system(size: 9, weight: .bold)).tracking(0.6)
                    .foregroundStyle(Theme.textTertiary)
                HStack(spacing: 4) {
                    ForEach(["", "A", "B", "C", "D"], id: \.self) { p in
                        Button { priority = p } label: {
                            Text(p.isEmpty ? "—" : p)
                                .font(.system(size: 11, weight: p.isEmpty ? .medium : .bold))
                                .frame(width: 24, height: 22)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(priority == p ? .white : Theme.textSecondary)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(priority == p
                                      ? (p.isEmpty ? Theme.textTertiary : settings.resolvedPriorityColor(for: p))
                                      : Theme.surfaceElevated)
                        )
                    }
                }
            }
            Spacer()
        }
    }

    private var tagsField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TAGS")
                .font(.system(size: 9, weight: .bold)).tracking(0.6)
                .foregroundStyle(Theme.textTertiary)
            TextField("tag1:tag2", text: $tags)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
        }
    }

    @ViewBuilder
    private func promptFields(_ prompts: [CapturePrompt]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TEMPLATE FIELDS")
                .font(.system(size: 9, weight: .bold)).tracking(0.6)
                .foregroundStyle(Theme.textTertiary)
            ForEach(Array(prompts.enumerated()), id: \.offset) { idx, prompt in
                promptField(idx: idx, prompt: prompt)
            }
        }
    }

    @ViewBuilder
    private func promptField(idx: Int, prompt: CapturePrompt) -> some View {
        let binding = Binding<String>(
            get: { idx < promptValues.count ? promptValues[idx] : "" },
            set: { newVal in
                while promptValues.count <= idx { promptValues.append("") }
                promptValues[idx] = newVal
            }
        )
        let label = prompt.name.isEmpty ? "Field \(idx + 1)" : prompt.name

        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            switch prompt.type {
            case "date":
                promptDateField(binding: binding)
            case "tags":
                TextField("tag1:tag2:tag3", text: binding)
                    .textFieldStyle(.roundedBorder).font(.system(size: 13))
            case "property":
                TextField("Value", text: binding)
                    .textFieldStyle(.roundedBorder).font(.system(size: 13))
            default:
                if prompt.options.isEmpty {
                    TextField("", text: binding)
                        .textFieldStyle(.roundedBorder).font(.system(size: 13))
                } else {
                    HStack {
                        TextField("", text: binding)
                            .textFieldStyle(.roundedBorder).font(.system(size: 13))
                        Menu {
                            ForEach(prompt.options, id: \.self) { opt in
                                Button(opt) { binding.wrappedValue = opt }
                            }
                        } label: {
                            Image(systemName: "chevron.down.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func promptDateField(binding: Binding<String>) -> some View {
        HStack(spacing: 8) {
            if binding.wrappedValue.isEmpty {
                Button("Pick date") {
                    // Strip angle brackets — daemon accepts bare date strings for %^{...} prompts.
                    let ts = OrgTimestampFormat.string(date: Date(), includeTime: false)
                    binding.wrappedValue = ts
                        .replacingOccurrences(of: "<", with: "")
                        .replacingOccurrences(of: ">", with: "")
                }
                .controlSize(.small)
            } else {
                Text(binding.wrappedValue)
                    .font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                Button { binding.wrappedValue = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func dateRow(label: String, icon: String, tint: Color,
                         date: Binding<Date?>, hasTime: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Label(label, systemImage: icon)
                .font(.system(size: 12)).foregroundStyle(tint)
            Spacer()
            if let d = date.wrappedValue {
                DatePicker("", selection: Binding(
                    get: { d }, set: { date.wrappedValue = $0 }
                ), displayedComponents: hasTime.wrappedValue ? [.date, .hourAndMinute] : [.date])
                .labelsHidden().datePickerStyle(.compact)
                Toggle("Time", isOn: hasTime).toggleStyle(.checkbox).controlSize(.small)
                Button { date.wrappedValue = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }.buttonStyle(.plain)
            } else {
                Button("Add") { date.wrappedValue = Calendar.current.startOfDay(for: Date()) }
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func targetInfo(_ tpl: CaptureTemplate) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "doc.text")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
            if let file = tpl.targetFile {
                Text(abbreviatePath(file))
                    .font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
            }
            if let hl = tpl.targetHeadline {
                Text("→").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                Text(hl).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(submitting ? "Capturing…" : "Capture") {
                Task { await submit() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSubmit)
        }
        .padding(16)
    }

    // MARK: - Grouping

    private enum TemplateItem: Identifiable {
        case group(CaptureTemplate)
        case template(CaptureTemplate)
        var id: String {
            switch self {
            case .group(let t): return "g:\(t.key)"
            case .template(let t): return t.key
            }
        }
    }

    private var groupedTemplates: [TemplateItem] {
        templates.compactMap { t in
            if t.isGroup { return .group(t) }
            if t.webSupported { return .template(t) }
            return nil
        }
    }

    // MARK: - Actions

    private func loadTemplates() async {
        guard let client = settings.apiClient else { loading = false; return }
        do {
            templates = try await client.fetchCaptureTemplates()
            if let first = templates.first(where: { $0.webSupported }) {
                selectedKey = first.key
                prefillFromTemplate()
            }
        } catch {
            errorMessage = "Failed to load templates: \(error.localizedDescription)"
        }
        loading = false
    }

    private func prefillFromTemplate() {
        guard let tpl = selected else { return }
        let p = TemplateParser.parse(tpl, keywords: store.keywords)
        todoState = p.todoState ?? ""
        priority = p.priority ?? ""
        tags = p.tags.joined(separator: ":")

        let prefix = p.titlePattern.replacingOccurrences(of: "%?", with: "")
        title = prefix.isEmpty ? "" : prefix

        scheduledDate = p.scheduledInBody ? Date() : nil
        scheduledHasTime = false
        deadlineDate = p.deadlineInBody ? Date() : nil
        deadlineHasTime = false

        let count = tpl.prompts?.count ?? 0
        promptValues = Array(repeating: "", count: count)

        // Pre-fill default values from prompt options
        if let prompts = tpl.prompts {
            for (idx, prompt) in prompts.enumerated() {
                if !prompt.options.isEmpty {
                    promptValues[idx] = prompt.options[0]
                }
            }
        }
    }

    private func submit() async {
        guard let client = settings.apiClient, let tpl = selected else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        guard !trimmedTitle.isEmpty else { return }
        guard tpl.targetFile != nil else { return }

        submitting = true
        errorMessage = nil

        let sch = scheduledDate.map {
            OrgTimestampFormat.string(date: $0, includeTime: scheduledHasTime)
        }
        let dl = deadlineDate.map {
            OrgTimestampFormat.string(date: $0, includeTime: deadlineHasTime)
        }

        let expectedPrompts = tpl.prompts?.count ?? 0
        var answers = promptValues
        while answers.count < expectedPrompts { answers.append("") }
        if answers.count > expectedPrompts { answers = Array(answers.prefix(expectedPrompts)) }

        do {
            try await client.captureTask(
                templateKey: tpl.key,
                title: trimmedTitle,
                priority: priority.isEmpty ? nil : priority,
                scheduled: sch,
                deadline: dl,
                promptAnswers: expectedPrompts == 0 ? nil : answers
            )
            submitting = false
            onCaptured()
            dismiss()
        } catch {
            errorMessage = "Capture failed: \(error.localizedDescription)"
            submitting = false
        }
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return (path as NSString).lastPathComponent
    }
}
