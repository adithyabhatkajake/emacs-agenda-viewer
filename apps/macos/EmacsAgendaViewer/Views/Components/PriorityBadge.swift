import SwiftUI

struct PriorityBadge: View {
    let priority: String

    var body: some View {
        HStack(spacing: 1) {
            Image(systemName: "flag.fill")
                .font(.system(size: 9, weight: .semibold))
            Text(priority.uppercased())
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(Theme.priorityColor(priority))
    }
}
