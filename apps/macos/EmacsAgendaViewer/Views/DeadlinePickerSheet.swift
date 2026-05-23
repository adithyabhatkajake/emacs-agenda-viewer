#if !os(macOS)
import SwiftUI

struct DeadlinePickerSheet: View {
    let task: any TaskDisplayable
    let store: TasksStore

    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings

    @State private var date: Date
    @State private var time: Date
    @State private var includeTime: Bool
    @State private var isMutating: Bool = false
    @State private var errorMessage: String?

    private var client: APIClient? { settings.apiClient }

    init(task: any TaskDisplayable, store: TasksStore) {
        self.task = task
        self.store = store
        if let dl = task.deadline, let comp = dl.start {
            var dc = DateComponents()
            dc.year = comp.year; dc.month = comp.month; dc.day = comp.day
            dc.hour = comp.hour ?? 9; dc.minute = comp.minute ?? 0
            let resolved = Calendar.current.date(from: dc) ?? Date()
            _date = State(initialValue: resolved)
            _time = State(initialValue: resolved)
            _includeTime = State(initialValue: comp.hour != nil)
        } else {
            let now = Date()
            _date = State(initialValue: now)
            _time = State(initialValue: now)
            _includeTime = State(initialValue: false)
        }
    }

    var body: some View {
        PickerSheetScaffold(
            title: "Deadline",
            isMutating: isMutating,
            saveAction: { await save(clear: false) }
        ) {
            Form {
                Section {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                }

                Section {
                    Toggle("Include time", isOn: $includeTime)
                    if includeTime {
                        DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        Task {
                            let ok = await save(clear: true)
                            if ok { dismiss() }
                        }
                    } label: {
                        Text("Clear deadline")
                    }
                    .disabled(isMutating || client == nil || task.deadline == nil)
                }

                ErrorSection(errorMessage)
            }
        }
    }

    /// Performs the save or clear operation. Returns `true` on success so
    /// callers can dismiss; returns `false` on failure (errorMessage is set).
    private func save(clear: Bool) async -> Bool {
        guard let client else { return false }
        isMutating = true
        errorMessage = nil
        let timestamp = clear ? "" : OrgTimestampFormat.string(
            date: mergedDateTime(day: date, time: time),
            includeTime: includeTime
        )
        let ok = await store.setDeadline(
            taskId: task.id, file: task.file, pos: task.pos,
            timestamp: timestamp, using: client
        )
        isMutating = false
        if !ok { errorMessage = store.lastMutationError ?? "Couldn't save change" }
        return ok
    }
}

private func mergedDateTime(day: Date, time: Date) -> Date {
    var dc = Calendar.current.dateComponents([.year, .month, .day], from: day)
    let tc = Calendar.current.dateComponents([.hour, .minute], from: time)
    dc.hour = tc.hour
    dc.minute = tc.minute
    return Calendar.current.date(from: dc) ?? day
}
#endif
