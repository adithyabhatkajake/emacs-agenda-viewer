import SwiftUI

// MARK: - Template Parser

struct ParsedTemplate {
    var headingLevel: Int = 1
    var todoState: String?
    var priority: String?
    var titlePattern: String = "%?"
    var tags: [String] = []
    var scheduledInBody: Bool = false
    var deadlineInBody: Bool = false
    var bodyLines: [String] = []
    var entryType: String = "entry"
}

private enum TemplateParser {
    static func parse(_ tpl: CaptureTemplate, keywords: TodoKeywords?) -> ParsedTemplate {
        var result = ParsedTemplate()
        result.entryType = tpl.type ?? "entry"

        guard let raw = tpl.template else { return result }
        let lines = raw.components(separatedBy: "\n")

        guard let heading = lines.first else { return result }

        if result.entryType == "entry" {
            parseHeadingLine(heading, into: &result, keywords: keywords)
        } else {
            result.titlePattern = heading
        }

        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("SCHEDULED:") {
                result.scheduledInBody = true
            } else if trimmed.hasPrefix("DEADLINE:") {
                result.deadlineInBody = true
            }
            result.bodyLines.append(line)
        }

        return result
    }

    private static func parseHeadingLine(_ line: String, into result: inout ParsedTemplate, keywords: TodoKeywords?) {
        var remaining = line[line.startIndex...]

        // Stars
        let stars = remaining.prefix(while: { $0 == "*" })
        if !stars.isEmpty {
            result.headingLevel = stars.count
            remaining = remaining.dropFirst(stars.count)
            remaining = remaining.drop(while: { $0 == " " })
        }

        // Tags at end: :tag1:tag2:
        if let tagRange = remaining.range(of: #"\s+(:[a-zA-Z0-9_@#%:]+:)\s*$"#, options: .regularExpression) {
            let tagStr = String(remaining[tagRange]).trimmingCharacters(in: .whitespaces)
            result.tags = tagStr.split(separator: ":").map(String.init).filter { !$0.isEmpty }
            remaining = remaining[remaining.startIndex..<tagRange.lowerBound]
        }

        let rest = String(remaining)
        let allKeywords = (keywords?.allActive ?? ["TODO"]) + (keywords?.allDone ?? ["DONE"])

        // TODO state
        for kw in allKeywords {
            if rest.hasPrefix(kw + " ") || rest.hasPrefix(kw + "\t") || rest == kw {
                result.todoState = kw
                remaining = remaining.dropFirst(kw.count)
                remaining = remaining.drop(while: { $0 == " " })
                break
            }
        }

        // Priority [#X]
        let priStr = String(remaining)
        if let match = priStr.range(of: #"^\[#([A-Z])\]\s*"#, options: .regularExpression) {
            let inner = priStr[priStr.index(priStr.startIndex, offsetBy: 2)..<priStr.index(priStr.startIndex, offsetBy: 3)]
            result.priority = String(inner)
            remaining = remaining.dropFirst(priStr.distance(from: priStr.startIndex, to: match.upperBound))
        }

        result.titlePattern = String(remaining)
    }
}

// MARK: - Entry Builder

private enum EntryBuilder {
    static func build(
        parsed: ParsedTemplate,
        title: String,
        todoState: String?,
        priority: String?,
        tags: [String],
        scheduled: String?,
        deadline: String?,
        promptAnswers: [String],
        prompts: [CapturePrompt]
    ) -> String {
        var lines: [String] = []

        if parsed.entryType == "entry" {
            let stars = String(repeating: "*", count: parsed.headingLevel)
            var heading = stars
            if let state = todoState, !state.isEmpty {
                heading += " \(state)"
            }
            if let pri = priority, !pri.isEmpty {
                heading += " [#\(pri)]"
            }
            heading += " \(title)"
            if !tags.isEmpty {
                heading += " :\(tags.joined(separator: ":")):"
            }
            lines.append(heading)
        } else if parsed.entryType == "checkitem" {
            lines.append("- [ ] \(title)")
        } else if parsed.entryType == "item" {
            lines.append("- \(title)")
        } else {
            lines.append(title)
        }

        // Properties from prompts
        var properties: [(String, String)] = []
        for (idx, prompt) in prompts.enumerated() where prompt.type == "property" {
            let value = idx < promptAnswers.count ? promptAnswers[idx] : ""
            if !value.isEmpty && !prompt.name.isEmpty {
                properties.append((prompt.name, value))
            }
        }
        if !properties.isEmpty {
            lines.append("  :PROPERTIES:")
            for (key, value) in properties {
                lines.append("  :\(key): \(value)")
            }
            lines.append("  :END:")
        }

        if let sch = scheduled, !sch.isEmpty, !parsed.scheduledInBody {
            lines.append("  SCHEDULED: \(sch)")
        }
        if let dl = deadline, !dl.isEmpty, !parsed.deadlineInBody {
            lines.append("  DEADLINE: \(dl)")
        }

        for line in parsed.bodyLines {
            let expanded = expandLine(line, promptAnswers: promptAnswers, prompts: prompts,
                                      scheduled: scheduled, deadline: deadline)
            let stripped = expanded.trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty { continue }
            lines.append(expanded)
        }

        // Inactive timestamp if body had %u/%U and nothing else added it
        return lines.joined(separator: "\n")
    }

    private static func expandLine(
        _ line: String,
        promptAnswers: [String],
        prompts: [CapturePrompt],
        scheduled: String?,
        deadline: String?
    ) -> String {
        var result = line

        // %^{...} prompts — replace in order
        var promptIdx = 0
        while let range = result.range(of: #"%\^(?:\{[^}]*\})?[gGtTuUpCL]?"#, options: .regularExpression) {
            let match = String(result[range])
            let answer = promptIdx < promptAnswers.count ? promptAnswers[promptIdx] : ""
            promptIdx += 1

            if match.hasSuffix("p") {
                result = result.replacingCharacters(in: range, with: "")
                continue
            }
            if match.hasSuffix("g") || match.hasSuffix("G") {
                result = result.replacingCharacters(in: range, with: "")
                continue
            }
            if match.hasSuffix("t") || match.hasSuffix("T") {
                let ts = answer.isEmpty ? orgTimestamp(active: true) : "<\(answer)>"
                result = result.replacingCharacters(in: range, with: ts)
                continue
            }
            if match.hasSuffix("u") || match.hasSuffix("U") {
                let ts = answer.isEmpty ? orgTimestamp(active: false) : "[\(answer)]"
                result = result.replacingCharacters(in: range, with: ts)
                continue
            }
            result = result.replacingCharacters(in: range, with: answer)
        }

        // SCHEDULED: / DEADLINE: lines with their own timestamp
        if result.trimmingCharacters(in: .whitespaces).hasPrefix("SCHEDULED:") {
            if let sch = scheduled, !sch.isEmpty {
                result = "  SCHEDULED: \(sch)"
            } else {
                result = "  SCHEDULED: \(orgTimestamp(active: true))"
            }
            return result
        }
        if result.trimmingCharacters(in: .whitespaces).hasPrefix("DEADLINE:") {
            if let dl = deadline, !dl.isEmpty {
                result = "  DEADLINE: \(dl)"
            } else {
                result = "  DEADLINE: \(orgTimestamp(active: true))"
            }
            return result
        }

        // %<format> — Emacs format-time-string patterns
        while let range = result.range(of: #"%<[^>]+>"#, options: .regularExpression) {
            let pattern = String(result[range])
            let fmt = String(pattern.dropFirst(2).dropLast(1))
            let expanded = emacsFormatTime(fmt)
            result = result.replacingCharacters(in: range, with: expanded)
        }

        // Non-interactive codes
        result = result.replacingOccurrences(of: "%?", with: "")
        result = result.replacingOccurrences(of: "%U", with: orgTimestamp(active: false, includeTime: true))
        result = result.replacingOccurrences(of: "%u", with: orgTimestamp(active: false))
        result = result.replacingOccurrences(of: "%T", with: orgTimestamp(active: true, includeTime: true))
        result = result.replacingOccurrences(of: "%t", with: orgTimestamp(active: true))
        result = result.replacingOccurrences(of: "%a", with: "")
        result = result.replacingOccurrences(of: "%i", with: "")

        return result
    }

    static func emacsFormatTime(_ fmt: String, date: Date = Date()) -> String {
        let cal = Calendar.current
        let dc = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
        let shortDays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let fullDays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let shortMonths = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let fullMonths = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]

        var result = fmt
        result = result.replacingOccurrences(of: "%Y", with: String(format: "%04d", dc.year!))
        result = result.replacingOccurrences(of: "%m", with: String(format: "%02d", dc.month!))
        result = result.replacingOccurrences(of: "%d", with: String(format: "%02d", dc.day!))
        result = result.replacingOccurrences(of: "%H", with: String(format: "%02d", dc.hour!))
        result = result.replacingOccurrences(of: "%M", with: String(format: "%02d", dc.minute!))
        result = result.replacingOccurrences(of: "%S", with: String(format: "%02d", dc.second!))
        result = result.replacingOccurrences(of: "%a", with: shortDays[(dc.weekday! - 1)])
        result = result.replacingOccurrences(of: "%A", with: fullDays[(dc.weekday! - 1)])
        result = result.replacingOccurrences(of: "%b", with: shortMonths[(dc.month! - 1)])
        result = result.replacingOccurrences(of: "%B", with: fullMonths[(dc.month! - 1)])
        result = result.replacingOccurrences(of: "%e", with: String(format: "%2d", dc.day!))
        return result
    }

    static func orgTimestamp(active: Bool, includeTime: Bool = false, date: Date = Date()) -> String {
        let cal = Calendar.current
        let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let dc = cal.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: date)
        let day = dayNames[(dc.weekday ?? 1) - 1]
        let open = active ? "<" : "["
        let close = active ? ">" : "]"
        if includeTime {
            return String(format: "%@%04d-%02d-%02d %@ %02d:%02d%@",
                          open, dc.year!, dc.month!, dc.day!, day, dc.hour!, dc.minute!, close)
        }
        return String(format: "%@%04d-%02d-%02d %@%@",
                      open, dc.year!, dc.month!, dc.day!, day, close)
    }
}

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
                    binding.wrappedValue = EntryBuilder.orgTimestamp(active: true, date: Date())
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
        guard let client = settings.apiClient, let tpl = selected, let p = parsed else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        guard !trimmedTitle.isEmpty else { return }
        guard let file = tpl.targetFile else { return }

        submitting = true
        errorMessage = nil

        let sch = scheduledDate.map {
            OrgTimestampFormat.string(date: $0, includeTime: scheduledHasTime)
        }
        let dl = deadlineDate.map {
            OrgTimestampFormat.string(date: $0, includeTime: deadlineHasTime)
        }

        let tagList = tags.split(separator: ":").map(String.init).filter { !$0.isEmpty }

        let entryText = EntryBuilder.build(
            parsed: p,
            title: trimmedTitle,
            todoState: todoState.isEmpty ? nil : todoState,
            priority: priority.isEmpty ? nil : priority,
            tags: tagList,
            scheduled: sch,
            deadline: dl,
            promptAnswers: promptValues,
            prompts: tpl.prompts ?? []
        )

        let targetType = tpl.targetType ?? "file"

        // For file+olp, the headline field contains just the first heading;
        // deeper paths aren't exposed yet, so use headline for file+headline.
        let headline = tpl.targetHeadline
        let olp: [String]? = nil

        do {
            try await client.insertEntry(
                file: file, targetType: targetType, entryText: entryText,
                headline: headline, olp: olp
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
