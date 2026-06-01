import SwiftUI

struct DatePickerPopover: View {
    @State private var date: Date
    @State private var hasTime: Bool
    @State private var monthAnchor: Date
    @State private var query: String = ""
    /// True when the user has edited the time field since the popover
    /// opened (or since the last commit). The compact DatePicker writes
    /// `date` on EVERY keystroke — without batching, typing "1030"
    /// fires four daemon round-trips and the task visibly jumps from
    /// 01:00 → 10:00 → 10:03 → 10:30 as digits land. We defer the
    /// commit to popover-close, which is the user's explicit "done"
    /// signal, and flush exactly once.
    @State private var timeDirty: Bool = false
    let tint: Color
    /// Commit a new date. `closing` is true when the popover should auto-dismiss
    /// after this commit (e.g., picking a day, "Today", or "This Evening").
    /// Time-of-day adjustments stay open so the user can keep tweaking.
    let onSet: (_ date: Date, _ hasTime: Bool, _ closing: Bool) -> Void
    let onClear: () -> Void

    init(initialDate: Date, initialHasTime: Bool, tint: Color,
         onSet: @escaping (Date, Bool, Bool) -> Void, onClear: @escaping () -> Void) {
        _date = State(initialValue: initialDate)
        _hasTime = State(initialValue: initialHasTime)
        _monthAnchor = State(initialValue: initialDate)
        self.tint = tint
        self.onSet = onSet
        self.onClear = onClear
    }

    private var cal: Calendar { Calendar.current }
    private var todayStart: Date { cal.startOfDay(for: Date()) }

    var body: some View {
        VStack(spacing: 0) {
            whenField
                .padding(.top, 10)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

            quickRow(
                icon: "star.fill", iconTint: Color(red: 1.0, green: 0.78, blue: 0.18),
                label: "Today",
                checked: cal.isDate(date, inSameDayAs: todayStart),
                action: { selectDay(todayStart) }
            )
            quickRow(
                icon: "moon.fill", iconTint: Color(red: 0.45, green: 0.55, blue: 0.95),
                label: "This Evening",
                checked: hasTime && cal.isDate(date, inSameDayAs: todayStart) && eveningHour == cal.component(.hour, from: date),
                action: {
                    var comps = cal.dateComponents([.year, .month, .day], from: todayStart)
                    comps.hour = eveningHour; comps.minute = 0
                    if let d = cal.date(from: comps) { date = d; monthAnchor = d; hasTime = true; commit(closing: true) }
                }
            )

            monthHeader
                .padding(.top, 8)
                .padding(.horizontal, 12)
            weekHeader
                .padding(.horizontal, 12)
            monthGrid
                .padding(.horizontal, 12)
                .padding(.bottom, 4)

            quickRow(
                icon: "tray", iconTint: .white.opacity(0.6),
                label: "Someday",
                checked: false,
                action: { onClear() }
            )

            timeRow
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

            Button(action: onClear) {
                Text("Clear")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.06))
            }
            .buttonStyle(.plain)
        }
        .frame(width: 220)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(red: 0.15, green: 0.15, blue: 0.17))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .colorScheme(.dark)
        .padding(2)
        // The popover-close event is the user's explicit "I'm done
        // editing" signal — fire the one commit here. timeDirty stays
        // false for picker dismissals that didn't touch the time
        // field, so we don't redundantly re-write the same SCHEDULED
        // line when the user just opens-and-closes the popover.
        .onDisappear {
            if timeDirty { commit(closing: false) }
        }
    }

    private var eveningHour: Int { 18 }

    private var whenField: some View {
        TextField("When", text: $query)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .onSubmit { applyQuery() }
    }

    private func applyQuery() {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        if q == "today" { selectDay(todayStart) }
        else if q == "tomorrow", let d = cal.date(byAdding: .day, value: 1, to: todayStart) { selectDay(d) }
        else if q == "next week", let d = cal.date(byAdding: .day, value: 7, to: todayStart) { selectDay(d) }
    }

    private var monthHeader: some View {
        HStack(spacing: 6) {
            Button { shiftMonth(-1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.7))
            Text(monthLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity)
            Button { shiftMonth(1) } label: {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.bottom, 4)
    }

    private var monthLabel: String {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: monthAnchor)
    }

    private func shiftMonth(_ delta: Int) {
        if let d = cal.date(byAdding: .month, value: delta, to: monthAnchor) { monthAnchor = d }
    }

    private var weekHeader: some View {
        HStack(spacing: 0) {
            ForEach(["Sun","Mon","Tue","Wed","Thu","Fri","Sat"], id: \.self) { d in
                Text(d)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.bottom, 2)
    }

    private var monthGrid: some View {
        let days = monthDays
        return VStack(spacing: 2) {
            ForEach(0..<6, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { col in
                        let idx = row * 7 + col
                        if idx < days.count, let d = days[idx] {
                            dayCell(d)
                        } else {
                            Color.clear.frame(maxWidth: .infinity).frame(height: 22)
                        }
                    }
                }
            }
        }
    }

    private var monthDays: [Date?] {
        let firstOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: monthAnchor)) ?? monthAnchor
        let weekdayOfFirst = cal.component(.weekday, from: firstOfMonth) // 1=Sun
        let leading = weekdayOfFirst - 1
        let range = cal.range(of: .day, in: .month, for: firstOfMonth) ?? 1..<31
        var out: [Date?] = Array(repeating: nil, count: leading)
        for day in range {
            var comps = cal.dateComponents([.year, .month], from: firstOfMonth)
            comps.day = day
            out.append(cal.date(from: comps))
        }
        while out.count < 42 { out.append(nil) }
        return out
    }

    private func dayCell(_ d: Date) -> some View {
        let isSelected = cal.isDate(d, inSameDayAs: date)
        let isToday = cal.isDate(d, inSameDayAs: todayStart)
        let label = String(cal.component(.day, from: d))
        return Button {
            selectDay(d)
        } label: {
            ZStack {
                if isSelected {
                    Circle().fill(tint).frame(width: 22, height: 22)
                }
                if isToday && !isSelected {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.18).opacity(0.85))
                        .offset(y: -1)
                } else {
                    Text(label)
                        .font(.system(size: 11, weight: isToday ? .bold : .regular))
                        .foregroundStyle(isSelected ? Color.white : .white.opacity(0.85))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func selectDay(_ d: Date) {
        var newDate = d
        if hasTime, let h = cal.dateComponents([.hour, .minute], from: date).hour {
            var comps = cal.dateComponents([.year, .month, .day], from: d)
            comps.hour = h
            comps.minute = cal.component(.minute, from: date)
            newDate = cal.date(from: comps) ?? d
        }
        date = newDate
        monthAnchor = newDate
        commit(closing: true)
    }

    private func commit(closing: Bool = false) {
        onSet(date, hasTime, closing)
        timeDirty = false
    }

    @ViewBuilder
    private func quickRow(icon: String, iconTint: Color, label: String, checked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(iconTint)
                    .frame(width: 14)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
                if checked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(checked ? Color.white.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var timeRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
            if hasTime {
                DatePicker("", selection: $date, displayedComponents: [.hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .fixedSize()
                    .onChange(of: date) { _, _ in timeDirty = true }
                Spacer()
                Button {
                    // Local-only state change; the write is batched to the
                    // popover-close commit (see `.onDisappear`). Committing
                    // here would write immediately, and the reindex/SSE
                    // re-render tears down the row that anchors this popover.
                    hasTime = false
                    timeDirty = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Remove time")
            } else {
                Button {
                    // Seed a sensible default time, then flip to the time
                    // editor. Local-only: the write is deferred to the
                    // popover-close commit (see `.onDisappear`). Committing
                    // here would write immediately, and the resulting
                    // reindex/SSE re-render relocates the task row that
                    // anchors this popover — dismissing it before the user
                    // can pick a time.
                    var comps = cal.dateComponents([.year, .month, .day], from: date)
                    let now = cal.dateComponents([.hour, .minute], from: Date())
                    comps.hour = now.hour
                    comps.minute = (now.minute ?? 0) < 30 ? 30 : 0
                    if (comps.minute ?? 0) == 0 { comps.hour = (comps.hour ?? 0) + 1 }
                    if let d = cal.date(from: comps) { date = d }
                    hasTime = true
                    timeDirty = true
                } label: {
                    Text("Add time")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
    }
}
