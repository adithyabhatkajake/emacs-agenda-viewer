import SwiftUI
import EventKit

struct CreateEventDraft: Identifiable {
    let id = UUID()
    var start: Date
    var end: Date
    var calendarId: String?
    var title: String = ""
}

struct CreateEventSheet: View {
    @Environment(EventKitService.self) private var ek
    @Environment(\.dismiss) private var dismiss
    @State var draft: CreateEventDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "calendar.badge.plus")
                    .foregroundStyle(Theme.accent)
                Text("New Calendar Event").font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }

            TextField("Title (e.g. Pickleball)", text: $draft.title)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14))
                .onSubmit { save() }

            HStack {
                Text("Calendar").font(.caption).foregroundStyle(Theme.textSecondary)
                Spacer()
                Picker("", selection: Binding(
                    get: { draft.calendarId ?? "" },
                    set: { draft.calendarId = $0.isEmpty ? nil : $0 }
                )) {
                    Text("System default").tag("")
                    ForEach(ek.calendars, id: \.calendarIdentifier) { c in
                        HStack {
                            Circle().fill(Color(c.color)).frame(width: 9, height: 9)
                            Text(c.title)
                        }
                        .tag(c.calendarIdentifier)
                    }
                }
                .labelsHidden()
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start").font(.caption).foregroundStyle(Theme.textSecondary)
                    DatePicker("", selection: $draft.start)
                        .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("End").font(.caption).foregroundStyle(Theme.textSecondary)
                    DatePicker("", selection: $draft.end, in: draft.start...)
                        .labelsHidden()
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { ek.reloadCalendars() }
    }

    private func save() {
        let title = draft.title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        _ = ek.createEvent(title: title, start: draft.start, end: draft.end, calendarId: draft.calendarId)
        dismiss()
    }
}
