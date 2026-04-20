import Foundation
import Observation

enum CalendarRange: String, CaseIterable, Identifiable {
    case day, week
    var id: String { rawValue }
    var label: String { self == .day ? "Day" : "Week" }
}

@MainActor
@Observable
final class CalendarState {
    var anchor: Date = Date()
    var range: CalendarRange = .week
}
