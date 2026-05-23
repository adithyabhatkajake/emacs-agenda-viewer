import SwiftUI

struct MacCalendarView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Selection.self) private var selection
    @Environment(CalendarState.self) private var cal
    @Environment(EventKitService.self) private var ek
    let store: TasksStore

    @State private var createDraft: CreateEventDraft?
    @State private var calendarEntries: [AgendaEntry] = []

    private var anchor: Date { cal.anchor }
    private var range: CalendarRange { cal.range }

    private let hourHeight: CGFloat = 64
    private let startHour = 0
    private let endHour = 24
    /// Height reserved for the per-column day header so the hours gutter can
    /// match it and keep the HH:00 labels aligned with their hour rules.
    private var dayHeaderHeight: CGFloat { range == .day ? 34 : 34 }

    var body: some View {
        HStack(spacing: 0) {
            calendarPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            MacScheduleTray(store: store)
                .frame(width: 340)
                .background(Theme.surface)
        }
        .sheet(item: $createDraft) { draft in
            CreateEventSheet(draft: draft)
                .environment(ek)
        }
        .task(id: settings.serverURLString) { await load() }
        .task { await ek.listenForChanges() }
        .onChange(of: ek.calendarAccess) { _, access in
            if access.canRead { Task { await load() } }
        }
        .onChange(of: cal.anchor) { _, _ in Task { await load() } }
        .onChange(of: cal.range)  { _, _ in Task { await load() } }
    }

    @ViewBuilder
    private var calendarPane: some View {
        VStack(spacing: 0) {
            calendarHeader
            Divider().background(Theme.borderSubtle)
            daysHeaderRow
            Divider().background(Theme.borderSubtle)
            allDayStrip
            Divider().background(Theme.borderSubtle)
            ScrollViewReader { proxy in
                ScrollView {
                    gridContent
                }
                .background(Theme.background)
                .task {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    // Scroll so that the current hour sits roughly a third
                    // from the top — two hours of past context above, then the
                    // rest of the day below. Anchoring on (h-2) with .top also
                    // avoids the scroll being clamped to the content end when
                    // h is near midnight.
                    let now = Calendar.current.component(.hour, from: Date())
                    let target = max(startHour, min(endHour - 1, now - 2))
                    withAnimation(.none) { proxy.scrollTo("hour-\(target)", anchor: .top) }
                }
            }
        }
        .background(Theme.background)
    }

    @ViewBuilder
    private var calendarHeader: some View {
        @Bindable var bindable = cal
        HStack(spacing: 12) {
            Text(headerTitle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            Spacer(minLength: 12)

            HStack(spacing: 2) {
                Button { shift(-1) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Previous")

                Button("Today") { cal.anchor = Date() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Theme.borderSubtle, lineWidth: 1)
                    )

                Button { shift(1) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Next")
            }

            Picker("", selection: $bindable.range) {
                ForEach(CalendarRange.allCases) { r in Text(r.label).tag(r) }
            }
            .pickerStyle(.segmented)
            .frame(width: 120)
            .labelsHidden()

            Button {
                // Base on the visible anchor day, not the current clock time,
                // so creating an event from a past or future view lands on the
                // right day. Preserve the +1h convention within that day.
                let visibleDay = days.first ?? anchor
                let now = Date()
                let todayDC = Calendar.current.dateComponents([.hour, .minute], from: now)
                var dc = Calendar.current.dateComponents([.year, .month, .day], from: visibleDay)
                dc.hour = todayDC.hour
                dc.minute = todayDC.minute
                let base = Calendar.current.date(from: dc) ?? visibleDay
                let snappedStart = snap(base)
                createDraft = CreateEventDraft(
                    start: snappedStart,
                    end: snappedStart.addingTimeInterval(60 * 60),
                    calendarId: settings.eventKitCalendarIdentifier
                )
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: .command)
            .disabled(!ek.canWrite)
            .help(ek.canWrite ? "Create event (⌘N)" : "Grant Calendar access in System Settings")

            Button { Task { await load() } } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(!settings.isConfigured)
            .help("Reload")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Data

    private var days: [Date] {
        let cal = Calendar.current
        switch range {
        case .day:
            return [cal.startOfDay(for: anchor)]
        case .week:
            return CalendarWeekMath.weekDays(for: anchor, calendar: cal)
        }
    }

    private var headerTitle: String {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"
        return f.string(from: days.first ?? anchor)
    }

    /// Org-only entries for a day (deduped).
    private func orgEntries(for day: Date) -> [AgendaEntry] {
        let key = DateQuery.string(from: day)
        let pool = (store.today.value ?? []) + calendarEntries
        let deduped = dedupeAgendaEntries(pool)

        return deduped.filter { entry in
            let d = entry.scheduled?.start ?? entry.deadline?.start
            guard let comp = d else { return false }
            var dc = DateComponents(); dc.year = comp.year; dc.month = comp.month; dc.day = comp.day
            return DateQuery.string(from: Calendar.current.date(from: dc) ?? Date()) == key
        }
    }

    /// Combined org + EventKit items for a day.
    private func items(for day: Date) -> [CalendarGridItem] {
        var result: [CalendarGridItem] = orgEntries(for: day).map { .org($0) }
        result += ek.events(for: day).map { .ek($0) }
        return result
    }

    private func timedItems(_ items: [CalendarGridItem]) -> [CalendarGridItem] {
        items.filter { $0.isTimed }
    }

    private func allDayItems(_ items: [CalendarGridItem]) -> [CalendarGridItem] {
        items.filter { !$0.isTimed }
    }

    private func schedule(taskId: String, file: String, pos: Int, on day: Date, hour: Int?, minute: Int?, durationMinutes: Int? = nil) async {
        guard let client = settings.apiClient else { return }
        var dc = Calendar.current.dateComponents([.year, .month, .day], from: day)
        if let h = hour { dc.hour = h; dc.minute = minute ?? 0 }
        guard let date = Calendar.current.date(from: dc) else { return }
        // Duration is only meaningful when a time is set; discard it for all-day drops.
        let effectiveDuration = hour != nil ? durationMinutes : nil
        let ts = OrgTimestampFormat.string(date: date, includeTime: hour != nil, durationMinutes: effectiveDuration)
        await store.setScheduled(taskId: taskId, file: file, pos: pos, timestamp: ts, using: client)
    }

    /// Convert a y-offset within the time grid into snapped (hour, minute).
    private func snappedTime(yPx: CGFloat) -> (Int, Int) {
        let totalMin = startHour * 60 + Int(yPx / hourHeight * 60)
        let snapped = max(startHour * 60, min(endHour * 60 - 30, (totalMin / 30) * 30))
        return (snapped / 60, snapped % 60)
    }

    // MARK: - Layout

    @State private var allDayExpanded = false
    private let allDayCollapsedRows = 2
    private let allDayExpandedRows = 12

    /// Row height used to size the all-day strip deterministically. Chip is
    /// ~13pt tall; add a bit of breathing room.
    private let allDayRowHeight: CGFloat = 16

    @ViewBuilder
    private var allDayStrip: some View {
        let maxCount = days.map { allDayItems(items(for: $0)).count }.max() ?? 0
        let limit = allDayExpanded
            ? min(maxCount, allDayExpandedRows)
            : min(maxCount, allDayCollapsedRows)
        // Number of rows of chrome we need room for per column. When there's
        // overflow in collapsed mode, the "+N more" button is an extra row.
        let overflowRows = (!allDayExpanded && maxCount > allDayCollapsedRows) ? 1 : 0
        let visualRows = max(1, limit) + overflowRows
        let stripHeight = CGFloat(visualRows) * allDayRowHeight + 8 // content + vertical padding

        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .trailing, spacing: 2) {
                Text("all-day")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.textTertiary)
                if maxCount > allDayCollapsedRows {
                    Button { allDayExpanded.toggle() } label: {
                        Image(systemName: allDayExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help(allDayExpanded ? "Collapse" : "Show all (\(maxCount))")
                }
            }
            .frame(width: 44, alignment: .trailing)
            .padding(.trailing, 6)
            .padding(.top, 2)

            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(days.enumerated()), id: \.element) { idx, day in
                    if idx > 0 {
                        Rectangle()
                            .fill(Theme.borderSubtle)
                            .frame(width: 1, height: stripHeight)
                    }
                    dayAllDayColumn(day, limit: limit)
                }
            }
        }
        .frame(height: stripHeight)
        .padding(.vertical, 2)
        .background(Theme.background)
    }

    @ViewBuilder
    private func dayAllDayColumn(_ day: Date, limit: Int) -> some View {
        let allDay = allDayItems(items(for: day))
        let visible = Array(allDay.prefix(limit))
        let overflow = allDay.count - visible.count
        VStack(alignment: .leading, spacing: 1) {
            ForEach(visible) { item in
                let color = item.resolvedColor(using: settings)
                AllDayChip(item: item, color: color)
                    .onTapGesture { handleItemTap(item) }
                    .draggable(item.dragPayload) {
                        AllDayChip(item: item, color: color).frame(width: 180)
                    }
            }
            if overflow > 0 {
                Button { allDayExpanded = true } label: {
                    Text("+\(overflow) more")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            handleDrop(payloadString: id, on: day, hour: nil, minute: nil)
            return true
        }
    }

    private func handleItemTap(_ item: CalendarGridItem) {
        switch item {
        case .org(let entry): selection.taskId = entry.id
        case .ek: break // could open inspector for EK in future
        }
    }

    /// Routes a drag-drop. Org task → reschedule via server. EK event → move via EventKit.
    private func handleDrop(payloadString: String, on day: Date, hour: Int?, minute: Int?) {
        guard let payload = CalendarDragPayload.decode(from: payloadString) else { return }
        switch payload.kind {
        case .ek:
            guard let event = ek.findEvent(stableId: payload.id) else { return }
            var dc = Calendar.current.dateComponents([.year, .month, .day], from: day)
            dc.hour = hour ?? 0; dc.minute = minute ?? 0
            guard let newStart = Calendar.current.date(from: dc) else { return }
            let duration = event.endDate.timeIntervalSince(event.startDate)
            let newEnd = newStart.addingTimeInterval(duration)
            ek.updateEvent(stableId: payload.id, title: event.title ?? "", start: newStart, end: newEnd)
        case .org:
            let pool = (store.today.value ?? []) + calendarEntries
            let entry = pool.first(where: { $0.id == payload.id })
            let dur: Int? = {
                guard let ts = entry?.scheduled ?? entry?.deadline,
                      let s = ts.start, let sh = s.hour,
                      let e = ts.end, let eh = e.hour else { return nil }
                let startMin = sh * 60 + (s.minute ?? 0)
                let endMin = eh * 60 + (e.minute ?? 0)
                return endMin > startMin ? endMin - startMin : nil
            }()
            Task { await schedule(taskId: payload.id, file: payload.file, pos: payload.pos, on: day, hour: hour, minute: minute, durationMinutes: dur) }
        }
    }

    private func handleResize(_ item: CalendarGridItem, on day: Date, durationMinutes: Int) {
        switch item {
        case .org(let entry):
            Task {
                let comp = (entry.scheduled ?? entry.deadline)?.start
                await schedule(
                    taskId: entry.id, file: entry.file, pos: entry.pos,
                    on: day,
                    hour: comp?.hour, minute: comp?.minute,
                    durationMinutes: durationMinutes
                )
            }
        case .ek(let event):
            let stableId = CalendarGridItem.stableId(of: event)
            let newEnd = event.startDate.addingTimeInterval(TimeInterval(durationMinutes * 60))
            ek.updateEvent(stableId: stableId, title: event.title ?? "", start: event.startDate, end: newEnd)
        }
    }

    @ViewBuilder
    private var daysHeaderRow: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: hourGutterWidth, height: dayHeaderHeight)
            ForEach(Array(days.enumerated()), id: \.element) { idx, day in
                if idx > 0 {
                    Rectangle().fill(Theme.borderSubtle).frame(width: 1, height: dayHeaderHeight)
                }
                dayHeader(day: day, isToday: Calendar.current.isDateInToday(day))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: dayHeaderHeight)
    }

    @ViewBuilder
    private var gridContent: some View {
        HStack(alignment: .top, spacing: 0) {
            hoursGutter
            ForEach(Array(days.enumerated()), id: \.element) { idx, day in
                if idx > 0 {
                    Rectangle().fill(Theme.borderSubtle).frame(width: 1)
                }
                dayColumnBody(day)
            }
        }
        .padding(.bottom, 24)
    }

    private let hourGutterWidth: CGFloat = 50

    @ViewBuilder
    private var hoursGutter: some View {
        // Each hour is its own VStack row of `hourHeight` so ScrollViewReader
        // can target it by id. The label sits at the top-right of the row with
        // a small negative offset so it straddles the hour rule drawn in CalendarDayGrid.
        VStack(spacing: 0) {
            ForEach(startHour..<endHour, id: \.self) { h in
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Text(String(format: "%02d:00", h))
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.trailing, 6)
                        .offset(y: -5)
                }
                .frame(width: hourGutterWidth, height: hourHeight, alignment: .top)
                .id("hour-\(h)")
            }
        }
        .frame(width: hourGutterWidth)
    }

    @ViewBuilder
    private func dayColumnBody(_ day: Date) -> some View {
        let isToday = Calendar.current.isDateInToday(day)
        let placed = CalendarOverlap.placeItems(
            timedItems(items(for: day)),
            on: day,
            hourHeight: hourHeight,
            startHour: startHour
        )
        VStack(spacing: 0) {
            CalendarDayGrid(
                day: day,
                isToday: isToday,
                placed: placed,
                hourHeight: hourHeight,
                startHour: startHour,
                endHour: endHour,
                onTapItem: { handleItemTap($0) },
                onResize: { item, newDur in handleResize(item, on: day, durationMinutes: newDur) },
                onDrop: { payloadString, y in
                    let (h, m) = snappedTime(yPx: y)
                    handleDrop(payloadString: payloadString, on: day, hour: h, minute: m)
                },
                onCreateAt: { y in
                    let (h, m) = snappedTime(yPx: y)
                    var dc = Calendar.current.dateComponents([.year, .month, .day], from: day)
                    dc.hour = h; dc.minute = m
                    if let date = Calendar.current.date(from: dc) {
                        createDraft = CreateEventDraft(
                            start: date,
                            end: date.addingTimeInterval(60 * 60),
                            calendarId: settings.eventKitCalendarIdentifier
                        )
                    }
                },
                onCreateRange: { startY, endY in
                    let topY = min(startY, endY)
                    let botY = max(startY, endY)
                    let (sh, sm) = snappedTime(yPx: topY)
                    let (eh, em) = snappedTime(yPx: botY)
                    var startDC = Calendar.current.dateComponents([.year, .month, .day], from: day)
                    startDC.hour = sh; startDC.minute = sm
                    guard let startDate = Calendar.current.date(from: startDC) else { return }
                    var endDC = Calendar.current.dateComponents([.year, .month, .day], from: day)
                    endDC.hour = eh; endDC.minute = em
                    guard var endDate = Calendar.current.date(from: endDC) else { return }
                    if endDate <= startDate {
                        endDate = startDate.addingTimeInterval(30 * 60)
                    }
                    createDraft = CreateEventDraft(
                        start: startDate,
                        end: endDate,
                        calendarId: settings.eventKitCalendarIdentifier
                    )
                },
                snapTime: { snappedTime(yPx: $0) }
            )
        }
        .frame(maxWidth: .infinity)
    }

    private func dayHeaderText(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = range == .day ? "EEEE, MMM d" : "EEE d"
        return f.string(from: d)
    }

    private static let weekdayShortFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE"; return f
    }()

    @ViewBuilder
    private func dayHeader(day: Date, isToday: Bool) -> some View {
        let dayNum = Calendar.current.component(.day, from: day)
        if range == .day {
            HStack(spacing: 6) {
                Text(dayHeaderText(day))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isToday ? Theme.accent : Theme.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(isToday ? Theme.accent.opacity(0.06) : Color.clear)
        } else {
            VStack(spacing: 1) {
                Text(Self.weekdayShortFmt.string(from: day).uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(isToday ? Theme.accent : Theme.textTertiary)
                    .lineLimit(1)
                Text("\(dayNum)")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isToday ? .white : Theme.textPrimary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 0.5)
                    .background(
                        Capsule().fill(isToday ? Theme.accent : Color.clear)
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(isToday ? Theme.accent.opacity(0.06) : Color.clear)
        }
    }

    // MARK: - Actions

    private func snap(_ date: Date) -> Date {
        let cal = Calendar.current
        var dc = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let m = dc.minute ?? 0
        dc.minute = (m / 30) * 30
        return cal.date(from: dc) ?? date
    }

    private func shift(_ direction: Int) {
        let days = range == .day ? 1 : 7
        cal.anchor = Calendar.current.date(byAdding: .day, value: direction * days, to: anchor) ?? anchor
    }

    private func load() async {
        ek.refreshAccessIfNeeded()
        ek.hiddenCalendarIds = settings.hiddenCalendarIds
        let cal = Calendar.current
        let first = days.first ?? anchor
        let last = days.last ?? anchor

        let dayStart = cal.startOfDay(for: first)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: last)) ?? dayStart
        ek.fetchEvents(in: DateInterval(start: dayStart, end: dayEnd))

        guard let client = settings.apiClient else { return }
        let start = DateQuery.string(from: dayStart)
        let end = DateQuery.string(from: cal.startOfDay(for: last))
        do {
            calendarEntries = try await client.fetchAgendaRange(start: start, end: end)
        } catch {
            // ignore — list views surface errors
        }
    }
}
