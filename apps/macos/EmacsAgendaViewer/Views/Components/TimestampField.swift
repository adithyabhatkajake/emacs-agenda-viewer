#if !os(macOS)
import SwiftUI

/// Shared scheduled/deadline toggle+date+time block used by both
/// `EditTaskSheet` and `CaptureSheet`. Keeps picker style and keyboard
/// behaviour identical in both sheets with a single source of truth.
///
/// - Parameters:
///   - label: Section header text ("Scheduled" / "Deadline").
///   - toggleLabel: Toggle label ("Schedule this task" / "Set deadline").
///   - isEnabled: Whether the timestamp is active.
///   - date: The calendar date value.
///   - time: The time-of-day value (only used when `includeTime` is true).
///   - includeTime: Whether to include an HH:MM component.
struct TimestampField: View {
    let label: String
    let toggleLabel: String
    @Binding var isEnabled: Bool
    @Binding var date: Date
    @Binding var time: Date
    @Binding var includeTime: Bool

    var body: some View {
        Section(label) {
            Toggle(toggleLabel, isOn: $isEnabled)
                .tint(Theme.accent)
            if isEnabled {
                DatePicker("Date", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.compact)
                Toggle("Include time", isOn: $includeTime)
                    .tint(Theme.accent)
                if includeTime {
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                }
            }
        }
    }
}
#endif
