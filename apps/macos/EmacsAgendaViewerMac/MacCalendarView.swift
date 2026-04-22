import SwiftUI

struct MacCalendarView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Selection.self) private var selection
    @Environment(CalendarState.self) private var cal
    @Environment(EventKitService.self) private var ek
    let store: TasksStore

    @State private var createDraft: CreateEventDraft?

    private var anchor: Date { cal.anchor }
    private var range: CalendarRange { cal.range }

    private let hourHeight: CGFloat = 64
    private let startHour = 0
    private let endHour = 24
    /// Height reserved for the per-column day header so the hours gutter can
    /// match it and keep the HH:00 labels aligned with their hour rules.
    private var dayHeaderHeight: CGFloat { range == .day ? 34 : 34 }

    var body: some View {
        calendarPane
            .sheet(item: $createDraft) { draft in
                CreateEventSheet(draft: draft)
                    .environment(ek)
            }
            .task(id: settings.serverURLString) { await load() }
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
                let now = Date()
                let snappedStart = snap(now)
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
            .disabled(!ek.hasAccess)
            .help(ek.hasAccess ? "Create event (⌘N)" : "Grant Calendar access in Settings")

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
            let weekday = cal.component(.weekday, from: anchor)
            // Make Monday-first week
            let offsetToMonday = ((weekday - cal.firstWeekday) + 7) % 7
            let monday = cal.date(byAdding: .day, value: -offsetToMonday, to: cal.startOfDay(for: anchor))!
            return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: monday) }
        }
    }

    private var headerTitle: String {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"
        return f.string(from: days.first ?? anchor)
    }

    /// Org-only entries for a day (deduped).
    private func orgEntries(for day: Date) -> [AgendaEntry] {
        let key = DateQuery.string(from: day)
        let pool = (store.today.value ?? []) + (store.upcoming.value ?? [])

        var seen: [String: AgendaEntry] = [:]
        for entry in pool {
            let hasTime = (entry.scheduled?.hasTime ?? false) || (entry.deadline?.hasTime ?? false)
            if let existing = seen[entry.id] {
                let existingHasTime = (existing.scheduled?.hasTime ?? false) || (existing.deadline?.hasTime ?? false)
                if hasTime && !existingHasTime { seen[entry.id] = entry }
            } else {
                seen[entry.id] = entry
            }
        }

        return seen.values.filter { entry in
            let d = entry.scheduled?.start ?? entry.deadline?.start
            guard let comp = d else { return false }
            var dc = DateComponents(); dc.year = comp.year; dc.month = comp.month; dc.day = comp.day
            return DateQuery.string(from: Calendar.current.date(from: dc) ?? Date()) == key
        }
    }

    /// Combined org + EventKit items for a day.
    private func items(for day: Date) -> [CalendarGridItem] {
        // Subscribe to EventKit changes so this view re-renders on EK updates.
        _ = ek.changeToken

        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart

        var result: [CalendarGridItem] = orgEntries(for: day).map { .org($0) }
        if ek.hasAccess {
            result += ek.events(in: DateInterval(start: dayStart, end: dayEnd)).map { .ek($0) }
        }
        return result
    }

    private func timedItems(_ items: [CalendarGridItem]) -> [CalendarGridItem] {
        items.filter { $0.isTimed }
    }

    private func allDayItems(_ items: [CalendarGridItem]) -> [CalendarGridItem] {
        items.filter { !$0.isTimed }
    }

    private func findTask(id: String) -> (any TaskDisplayable)? {
        if let t = store.today.value?.first(where: { $0.id == id }) { return t }
        if let t = store.upcoming.value?.first(where: { $0.id == id }) { return t }
        if let t = store.allTasks.value?.first(where: { $0.id == id }) { return t }
        return nil
    }

    private func schedule(taskId: String, on day: Date, hour: Int?, minute: Int?, durationMinutes: Int? = nil) async {
        guard let client = settings.apiClient,
              let task = findTask(id: taskId) else { return }
        var dc = Calendar.current.dateComponents([.year, .month, .day], from: day)
        if let h = hour { dc.hour = h; dc.minute = minute ?? 0 }
        guard let date = Calendar.current.date(from: dc) else { return }
        let ts = OrgTimestampFormat.string(date: date, includeTime: hour != nil, durationMinutes: durationMinutes)
        await store.setScheduled(taskId: taskId, file: task.file, pos: task.pos, timestamp: ts, using: client)
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
                    .draggable(item.id) {
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
            handleDrop(id: id, on: day, hour: nil, minute: nil)
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
    private func handleDrop(id: String, on day: Date, hour: Int?, minute: Int?) {
        if id.hasPrefix("ek:") {
            let stableId = String(id.dropFirst(3))
            guard let event = ek.findEvent(stableId: stableId) else { return }
            var dc = Calendar.current.dateComponents([.year, .month, .day], from: day)
            dc.hour = hour ?? 0; dc.minute = minute ?? 0
            guard let newStart = Calendar.current.date(from: dc) else { return }
            let duration = event.endDate.timeIntervalSince(event.startDate)
            let newEnd = newStart.addingTimeInterval(duration)
            ek.updateEvent(stableId: stableId, title: event.title ?? "", start: newStart, end: newEnd)
        } else {
            Task { await schedule(taskId: id, on: day, hour: hour, minute: minute) }
        }
    }

    private func handleResize(_ item: CalendarGridItem, on day: Date, durationMinutes: Int) {
        switch item {
        case .org(let entry):
            Task {
                let comp = (entry.scheduled ?? entry.deadline)?.start
                await schedule(
                    taskId: entry.id, on: day,
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
        // a small negative offset so it straddles the hour rule drawn in DayGrid.
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
        let placed = placeItems(timedItems(items(for: day)), on: day)
        VStack(spacing: 0) {
            DayGrid(
                day: day,
                isToday: isToday,
                placed: placed,
                hourHeight: hourHeight,
                startHour: startHour,
                endHour: endHour,
                onTapItem: { handleItemTap($0) },
                onResize: { item, newDur in handleResize(item, on: day, durationMinutes: newDur) },
                onDrop: { id, y in
                    let (h, m) = snappedTime(yPx: y)
                    handleDrop(id: id, on: day, hour: h, minute: m)
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
                snapTime: { snappedTime(yPx: $0) }
            )
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Overlap layout

    struct PlacedItem { let item: CalendarGridItem; let layout: EventLayout; let lane: Int; let groupSize: Int }

    private func placeItems(_ items: [CalendarGridItem], on day: Date) -> [PlacedItem] {
        let pairs: [(CalendarGridItem, EventLayout)] = items
            .compactMap { i in computeLayout(i, on: day).map { (i, $0) } }
            .sorted { $0.1.y < $1.1.y }

        var groups: [[(CalendarGridItem, EventLayout)]] = []
        var current: [(CalendarGridItem, EventLayout)] = []
        var groupBottom: CGFloat = -.greatestFiniteMagnitude
        for pair in pairs {
            if pair.1.y < groupBottom {
                current.append(pair)
                groupBottom = max(groupBottom, pair.1.y + pair.1.height)
            } else {
                if !current.isEmpty { groups.append(current) }
                current = [pair]
                groupBottom = pair.1.y + pair.1.height
            }
        }
        if !current.isEmpty { groups.append(current) }

        var result: [PlacedItem] = []
        for group in groups {
            var laneEnds: [CGFloat] = []
            var assignments: [(Int, CalendarGridItem, EventLayout)] = []
            for (i, l) in group {
                var lane = -1
                for (idx, end) in laneEnds.enumerated() where end <= l.y {
                    lane = idx; break
                }
                if lane == -1 {
                    lane = laneEnds.count
                    laneEnds.append(l.y + l.height)
                } else {
                    laneEnds[lane] = l.y + l.height
                }
                assignments.append((lane, i, l))
            }
            let total = laneEnds.count
            for (lane, i, l) in assignments {
                result.append(PlacedItem(item: i, layout: l, lane: lane, groupSize: total))
            }
        }
        return result
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

    /// Public alias so private helper structs in this file can reference EventLayout.
    typealias EventLayoutRef = EventLayout

    struct EventLayout { let y: CGFloat; let height: CGFloat; let durationMinutes: Int }

    private func computeLayout(_ item: CalendarGridItem, on day: Date) -> EventLayout? {
        guard let s = item.startDate else { return nil }
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        let startSec = s.timeIntervalSince(dayStart)
        let startMin = Int(startSec / 60) - startHour * 60
        let y = CGFloat(startMin) / 60.0 * hourHeight

        var duration = 60
        if let e = item.endDate, e > s {
            let mins = Int(e.timeIntervalSince(s) / 60)
            if mins > 0 { duration = mins }
        }
        let height = max(20, CGFloat(duration) / 60.0 * hourHeight)
        return EventLayout(y: max(0, y), height: height, durationMinutes: duration)
    }

    @ViewBuilder
    private var nowLine: some View {
        let cal = Calendar.current
        let now = Date()
        let hour = cal.component(.hour, from: now)
        let minute = cal.component(.minute, from: now)
        let mins = (hour * 60 + minute) - startHour * 60
        if mins >= 0 && mins <= (endHour - startHour) * 60 {
            let y = CGFloat(mins) / 60.0 * hourHeight
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.priorityA).frame(height: 1.5)
                Circle().fill(Theme.priorityA).frame(width: 6, height: 6).offset(x: -3)
            }
            .offset(y: y)
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
        guard let client = settings.apiClient else { return }
        let cal = Calendar.current
        let first = days.first ?? anchor
        let last = days.last ?? anchor
        let start = DateQuery.string(from: cal.startOfDay(for: first))
        let end = DateQuery.string(from: cal.startOfDay(for: last))
        // Fetch agenda range; reuse upcoming bucket
        do {
            let entries = try await client.fetchAgendaRange(start: start, end: end)
            store.upcoming = .loaded(entries)
        } catch {
            // ignore — list views surface errors
        }
    }
}

private struct DayGrid: View {
    @Environment(AppSettings.self) private var settings
    let day: Date
    let isToday: Bool
    let placed: [MacCalendarView.PlacedItem]
    let hourHeight: CGFloat
    let startHour: Int
    let endHour: Int
    let onTapItem: (CalendarGridItem) -> Void
    let onResize: (CalendarGridItem, Int) -> Void
    let onDrop: (String, CGFloat) -> Void
    let onCreateAt: (CGFloat) -> Void
    let snapTime: (CGFloat) -> (Int, Int)

    @State private var hoverY: CGFloat?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                CalendarDropZone(hoverY: $hoverY) { id, point in
                    onDrop(id, point.y)
                    return true
                }

                VStack(spacing: 0) {
                    ForEach(startHour..<endHour, id: \.self) { _ in
                        ZStack(alignment: .top) {
                            Rectangle()
                                .fill(Theme.background)
                                .frame(height: hourHeight)
                            Rectangle()
                                .frame(height: 0.5)
                                .foregroundStyle(Theme.borderSubtle)
                            Rectangle()
                                .frame(height: 0.5)
                                .foregroundStyle(Theme.borderSubtle.opacity(0.4))
                                .offset(y: hourHeight / 2)
                        }
                    }
                }
                .background(isToday ? Theme.accent.opacity(0.04) : Color.clear)
                .allowsHitTesting(false)

                // Tap-to-create layer (double-click on empty space).
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture(count: 2).onEnded { value in
                        onCreateAt(value.location.y)
                    })

                ForEach(placed, id: \.item.id) { p in
                    let laneWidth = max(20, geo.size.width / CGFloat(p.groupSize))
                    let color = p.item.resolvedColor(using: settings)
                    ResizableEvent(
                        item: p.item,
                        color: color,
                        layout: p.layout,
                        hourHeight: hourHeight,
                        onTap: { onTapItem(p.item) },
                        onResize: { dur in onResize(p.item, dur) }
                    )
                    .frame(width: laneWidth - 2, alignment: .top)
                    .offset(x: 1 + laneWidth * CGFloat(p.lane), y: p.layout.y)
                    .draggable(p.item.id) {
                        EventChip(item: p.item, color: color, compact: false).frame(width: 200, height: 40)
                    }
                }

                if isToday {
                    nowLine(gridWidth: geo.size.width).allowsHitTesting(false)
                }

                if let y = hoverY {
                    snapPreview(at: y, gridWidth: geo.size.width)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width)
        }
        .frame(height: CGFloat(endHour - startHour) * hourHeight)
    }

    @ViewBuilder
    private func nowLine(gridWidth: CGFloat) -> some View {
        let cal = Calendar.current
        let now = Date()
        let hour = cal.component(.hour, from: now)
        let minute = cal.component(.minute, from: now)
        let mins = (hour * 60 + minute) - startHour * 60
        if mins >= 0 && mins <= (endHour - startHour) * 60 {
            let y = CGFloat(mins) / 60.0 * hourHeight
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.priorityA).frame(width: gridWidth, height: 1.5)
                Circle().fill(Theme.priorityA).frame(width: 7, height: 7).offset(x: -3)
            }
            .offset(y: y - 0.75)
        }
    }

    @ViewBuilder
    private func snapPreview(at y: CGFloat, gridWidth: CGFloat) -> some View {
        let (h, m) = snapTime(y)
        let snappedY = CGFloat((h - startHour) * 60 + m) / 60.0 * hourHeight
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Theme.accent)
                .frame(width: gridWidth, height: 2)
            Text(String(format: "%02d:%02d", h, m))
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.accent)
                )
                .foregroundStyle(.white)
                .offset(x: 4, y: -10)
        }
        .offset(y: snappedY - 1)
    }
}

private struct ResizableEvent: View {
    let item: CalendarGridItem
    let color: Color
    let layout: MacCalendarView.EventLayoutRef
    let hourHeight: CGFloat
    let onTap: () -> Void
    let onResize: (Int) -> Void

    @State private var liveHeightDelta: CGFloat = 0
    @State private var hovered = false

    var body: some View {
        let h = max(20, layout.height + liveHeightDelta)
        ZStack(alignment: .bottom) {
            EventChip(item: item, color: color, compact: false)
                .frame(height: h)
                .onTapGesture(perform: onTap)
            ResizeHandle(active: hovered || liveHeightDelta != 0)
                .gesture(resizeGesture)
                .onHover { hovered = $0 }
        }
        .frame(height: h)
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in liveHeightDelta = value.translation.height }
            .onEnded { value in
                let newHeight = max(20, layout.height + value.translation.height)
                let mins = max(15, Int((newHeight / hourHeight) * 60))
                let snapped = (mins / 15) * 15
                liveHeightDelta = 0
                onResize(snapped)
            }
    }
}

private struct ResizeHandle: View {
    let active: Bool
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(active ? 0.5 : 0.001)) // near-transparent but hit-testable
            .frame(height: 8)
            .overlay(
                Capsule()
                    .fill(Color.white.opacity(active ? 0.7 : 0.3))
                    .frame(width: 28, height: 3)
            )
            .contentShape(Rectangle())
            .help("Drag to resize")
    }
}

private struct AllDayChip: View {
    let item: CalendarGridItem
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Rectangle().fill(color).frame(width: 2, height: 10)
            Text(item.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 3).padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color.opacity(0.14))
        )
        .help(item.title)
    }
}

private struct EventChip: View {
    let item: CalendarGridItem
    let color: Color
    let compact: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Rectangle().fill(color).frame(width: 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(compact ? 1 : 2)
                if let t = timeText {
                    Text(t)
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(color.opacity(0.18))
        )
    }

    private var timeText: String? {
        guard let start = item.startDate else { return nil }
        let cal = Calendar.current
        let h = cal.component(.hour, from: start)
        let m = cal.component(.minute, from: start)
        return String(format: "%d:%02d", h, m)
    }
}
