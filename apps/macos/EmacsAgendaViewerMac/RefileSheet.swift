import SwiftUI

struct RefileSheet: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    let store: TasksStore
    let task: any TaskDisplayable

    @State private var query = ""
    @State private var submitting = false
    @State private var errorMessage: String?
    @FocusState private var searchFocused: Bool

    private var filtered: [RefileTarget] {
        guard !query.isEmpty else { return store.refileTargets }
        return orderlessMatch(store.refileTargets, query: query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            searchBar
            Divider()
            targetList
            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(Theme.priorityA)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
        }
        .frame(width: 480)
        .frame(minHeight: 400, maxHeight: 600)
        .task { await loadTargetsIfNeeded() }
        .onAppear { searchFocused = true }
    }

    private var header: some View {
        HStack {
            Image(systemName: "arrow.turn.right.down")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Refile").font(.headline)
                Text(task.title)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
            TextField("Search targets…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var targetList: some View {
        Group {
            if !store.refileTargetsLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 24))
                        .foregroundStyle(Theme.textTertiary)
                    Text(query.isEmpty ? "No refile targets" : "No matches")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { target in
                            targetRow(target)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func targetRow(_ target: RefileTarget) -> some View {
        Button {
            Task { await refile(to: target) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    highlightedName(target.name)
                        .font(.system(size: 13))
                        .lineLimit(3)
                    Text(abbreviatePath(target.file))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .help("\(target.name)\n\(target.file)")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.clear)
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    private func highlightedName(_ name: String) -> Text {
        guard !query.isEmpty else {
            return Text(name).foregroundStyle(Theme.textPrimary)
        }
        let tokens = query.lowercased().split(separator: " ").map(String.init)
        let lower = name.lowercased()
        var attributed = AttributedString(name)
        for token in tokens {
            var search = lower.startIndex
            while let range = lower.range(of: token, range: search..<lower.endIndex) {
                if let lo = AttributedString.Index(range.lowerBound, within: attributed),
                   let hi = AttributedString.Index(range.upperBound, within: attributed) {
                    attributed[lo..<hi].foregroundColor = Color(Theme.accent)
                    attributed[lo..<hi].font = .system(size: 13, weight: .semibold)
                }
                search = range.upperBound
            }
        }
        return Text(attributed).foregroundStyle(Theme.textPrimary)
    }

    // MARK: - Actions

    private func loadTargetsIfNeeded() async {
        guard !store.refileTargetsLoaded, let client = settings.apiClient else { return }
        await store.loadRefileTargets(using: client)
    }

    private func refile(to target: RefileTarget) async {
        guard let client = settings.apiClient else { return }
        submitting = true
        errorMessage = nil
        let ok = await store.refile(sourceFile: task.file, sourcePos: task.pos,
                                    target: target, using: client)
        if ok {
            dismiss()
        } else {
            errorMessage = store.lastMutationError
            submitting = false
        }
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return (path as NSString).lastPathComponent
    }
}

// MARK: - Orderless matching

private func orderlessMatch(_ targets: [RefileTarget], query: String) -> [RefileTarget] {
    let tokens = query.lowercased().split(separator: " ").map(String.init)
    guard !tokens.isEmpty else { return targets }

    return targets.filter { target in
        let haystack = "\(target.name) \(target.file)".lowercased()
        return tokens.allSatisfy { haystack.contains($0) }
    }.sorted { lhs, rhs in
        let lName = lhs.name.lowercased()
        let rName = rhs.name.lowercased()
        let lPrefix = tokens.contains(where: { lName.hasPrefix($0) })
        let rPrefix = tokens.contains(where: { rName.hasPrefix($0) })
        if lPrefix != rPrefix { return lPrefix }
        return lhs.name.count < rhs.name.count
    }
}
