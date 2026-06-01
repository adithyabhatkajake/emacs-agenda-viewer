#if !os(macOS)
import SwiftUI

/// Wraps `TaskRow` with the iOS interaction model the user picked:
///  - **Tap the row body** → toggles inline expansion of the rendered
///    notes (checklists + prose). Lazy-loaded from `task.notes`.
///  - **Tap the checkbox** → toggles the task's done state.
///  - **Long-press the row** → context menu (`TaskRowMenu`) with Edit /
///    Mark Done / Clock / Pin. "Edit…" opens `EditTaskSheet` for full
///    field editing in one place.
///
/// There is no push-to-detail anymore — every edit path lives in the
/// long-press menu or the inline expansion. `TaskDetailView.swift`
/// remains in the project as dead code per user decision.
struct ExpandableTaskRow: View {
    let task: any TaskDisplayable
    let doneStates: Set<String>
    let store: TasksStore
    @Binding var isExpanded: Bool

    @Environment(AppSettings.self) private var settings

    @State private var notesText: String = ""
    @State private var notesLoading: Bool = false
    @State private var notesLoaded: Bool = false
    // blocks is the single parse cache for this row. All reads go through
    // inlineBlocks (which returns blocks directly); all writes call
    // NotesParser.parse exactly once and store the result here.
    @State private var blocks: [NoteBlock] = []
    @State private var showEditor: Bool = false
    @State private var showEditSheet: Bool = false
    @State private var showScheduleSheet: Bool = false

    // Haptic triggers — one Bool per action type. Flipped to true to fire
    // the feedback, then reset so the same gesture can re-trigger next time.
    @State private var hapticDone: Bool = false
    @State private var hapticPin: Bool = false
    @State private var hapticClock: Bool = false

    /// Cached parse result. `blocks` is seeded from `sourceNotes()` on
    /// appear (via `.task(id:)`) and kept up to date by every mutation path,
    /// so this never triggers a parse during a SwiftUI re-render.
    private var inlineBlocks: [NoteBlock] { blocks }

    /// Only checklist items, filtered from `inlineBlocks`. These render
    /// always (in the meta area) so the user can tick without expanding.
    private var inlineChecklists: [NoteBlock] {
        inlineBlocks.filter {
            if case .checklist = $0 { return true }
            return false
        }
    }

    /// True when the task has any renderable notes — checklists, prose, or
    /// bullets. The chevron is the single toggle for the whole expanded
    /// view (per the original "row stays one-line by default; chevron
    /// reveals notes + checklists" design). Pure-blank notes count as
    /// nothing to show.
    private var hasExpandableContent: Bool {
        inlineBlocks.contains { block in
            if case .blank = block { return false }
            return true
        }
    }

    private var client: APIClient? { settings.apiClient }
    private var notesKey: String { "\(task.file)::\(task.pos)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                // Checkbox stays an independent Button so its tap toggles
                // done without also flipping the expansion.
                checkboxButton
                    .padding(.top, 11)

                // The title area is the tap-to-toggle target. Only shows
                // the chevron / responds to taps when there's something to
                // reveal (checklists, bullets, or prose). Tap on a
                // notes-less row is a no-op so the user doesn't get
                // confused why nothing happens.
                Button {
                    guard hasExpandableContent else { return }
                    isExpanded.toggle()
                    if isExpanded { seedNotesSync() }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        TaskRow(
                            task: task, doneStates: doneStates,
                            onToggleDone: nil, showsCheckbox: false
                        )
                        if hasExpandableContent {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                                .padding(.top, 14)
                                .padding(.trailing, 8)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(hasExpandableContent
                    ? (isExpanded ? "Tap to hide notes" : "Tap to show notes")
                    : "")
            }

            if isExpanded {
                expandedNotesBlock
                    .padding(.leading, 38)
                    .padding(.trailing, 12)
                    .padding(.bottom, 10)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                // Reuses the same mutation path as the checkbox so the two
                // entry points stay in sync through a single code path.
                toggleDone()
            } label: {
                let isDone: Bool = {
                    guard let s = task.todoState else { return false }
                    return doneStates.contains(s.uppercased())
                }()
                Label(isDone ? "Reopen" : "Done",
                      systemImage: isDone ? "arrow.uturn.backward.circle" : "checkmark.circle")
            }
            .tint(Theme.doneGreen)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                showScheduleSheet = true
            } label: {
                Label("Schedule", systemImage: "calendar.badge.plus")
            }
            .tint(Theme.accent)

            Button {
                makeActions().togglePin()
                hapticPin.toggle()
            } label: {
                let pinned = makeActions().isPinnedToday
                Label(pinned ? "Unpin" : "Pin",
                      systemImage: pinned ? "pin.slash" : "pin")
            }
            .tint(Theme.priorityB)
        }
        .sensoryFeedback(.success, trigger: hapticDone)
        .sensoryFeedback(.impact, trigger: hapticPin)
        .sensoryFeedback(.impact, trigger: hapticClock)
        .contextMenu {
            TaskRowMenu(
                task: task, store: store, doneStates: doneStates,
                onEdit: { showEditSheet = true },
                onEditNotes: {
                    // Seed notesText so the editor opens with the latest
                    // body even if the row was never expanded (inline taps
                    // can fire without ensureNotesLoaded running).
                    if notesText.isEmpty { notesText = sourceNotes() }
                    showEditor = true
                },
                onClockToggle: { hapticClock.toggle() },
                onPinToggle: { hapticPin.toggle() }
            )
        }
        .sheet(isPresented: $showScheduleSheet) {
            SchedulePickerSheet(task: task, store: store)
        }
        .sheet(isPresented: $showEditSheet) {
            EditTaskSheet(task: task, store: store)
        }
        .sheet(isPresented: $showEditor) {
            NotesEditorSheet(
                task: task, store: store,
                initialNotes: notesText.isEmpty ? sourceNotes() : notesText
            ) { saved in
                notesText = saved
                blocks = NotesParser.parse(saved)
            }
        }
        .task(id: task.id) {
            // Seed blocks from the inline notes field so inlineBlocks/
            // hasExpandableContent never call NotesParser.parse in the
            // view body. Skipped if a mutation path already populated
            // notesText+blocks. Re-runs when the row is recycled for a
            // different task (task.id changes).
            guard notesText.isEmpty else { return }
            let text = sourceNotes()
            if !text.isEmpty {
                blocks = NotesParser.parse(text)
            }
        }
    }

    private func makeActions() -> TaskQuickActions {
        TaskQuickActions(task: task, store: store, client: client)
    }

    @ViewBuilder
    private var checkboxButton: some View {
        let isTaskDone: Bool = {
            guard let s = task.todoState else { return false }
            return doneStates.contains(s.uppercased())
        }()
        ProgressCheckbox(
            progress: checklistProgress(from: blocks),
            isDone: isTaskDone,
            onTap: toggleDone
        )
    }

    @ViewBuilder
    private var expandedNotesBlock: some View {
        if notesLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading notes\u{2026}")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if notesText.isEmpty {
            Text("No notes — long-press the row to add")
                .font(.caption)
                .italic()
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onLongPressGesture { showEditor = true }
        } else {
            NotesRenderedView(blocks: blocks, onToggleChecklist: handleChecklistToggle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onLongPressGesture { showEditor = true }
        }
    }

    private func toggleDone() {
        guard let client else { return }
        hapticDone.toggle()
        Task {
            _ = await store.toggleDone(task, file: task.file, pos: task.pos, using: client)
            // On failure store.lastMutationError is set (e.g. blocked-by-sub-tasks
            // from the bridge); RootView's banner surfaces it.
        }
    }

    /// Populate `notesText` / `blocks` on the same frame as the toggle so
    /// the expanded view renders the right content immediately — no "No
    /// notes" flash while the async loader runs. Kicks off the async
    /// path as fallback for tasks whose `notes` field wasn't in
    /// `/api/tasks`.
    private func seedNotesSync() {
        if !notesLoaded {
            let body = sourceNotes()
            if !body.isEmpty {
                notesText = body
                blocks = NotesParser.parse(body)
                notesLoaded = true
            }
        }
        Task { await ensureNotesLoaded() }
    }

    /// Best-effort notes lookup that doesn't trigger a network fetch —
    /// reads the inline `notes` field directly from the task value.
    /// Resolution order: OrgTask.notes → AgendaEntry.notes → allTasks
    /// cross-reference (last-resort for surfaces where the daemon hasn't
    /// populated notes yet).
    private func sourceNotes() -> String {
        if let org = task as? OrgTask, let n = org.notes { return n }
        if let entry = task as? AgendaEntry, let n = entry.notes { return n }
        if let match = store.allTasks.value?.first(where: { $0.id == task.id }),
           let n = match.notes { return n }
        return ""
    }

    private func ensureNotesLoaded() async {
        guard let client else { return }
        // Honor cache without re-fetching; otherwise hit /api/notes once.
        if let cached = store.cachedNotes(file: task.file, pos: task.pos) {
            notesText = cached
            blocks = NotesParser.parse(cached)
            notesLoaded = true
            return
        }
        if notesLoaded { return }
        notesLoading = true
        let body = await store.loadNotes(file: task.file, pos: task.pos, using: client)
        notesText = body
        blocks = NotesParser.parse(body)
        notesLoaded = true
        notesLoading = false
    }

    /// Cycle the checkbox at `lineIndex` then PUT the full body. On
    /// failure, revert the local copy so the rendered view doesn't lie.
    private func handleChecklistToggle(_ lineIndex: Int) {
        guard let client else { return }
        // Inline taps fire before any chevron-expand, so notesText may
        // still be empty even though the row IS displaying parsed
        // checklists from `task.notes`. Seed from the same source the
        // inline render reads from.
        let current = notesText.isEmpty ? sourceNotes() : notesText
        guard let next = NotesMutation.toggleChecklist(in: current, lineIndex: lineIndex)
        else { return }
        let previous = current
        notesText = next
        blocks = NotesParser.parse(next)
        Task {
            let ok = await store.setNotes(
                file: task.file, pos: task.pos,
                notes: next, using: client
            )
            if !ok {
                await MainActor.run {
                    notesText = previous
                    blocks = NotesParser.parse(previous)
                }
            } else {
                // setNotes returns the body the daemon wrote; keep ours in
                // sync in case org auto-cookies (`[2/3]`) restyled the line.
                if let saved = store.cachedNotes(file: task.file, pos: task.pos) {
                    await MainActor.run {
                        notesText = saved
                        blocks = NotesParser.parse(saved)
                    }
                }
            }
        }
    }
}
#endif
