import Foundation

// MARK: - OrgTimestamp convenience init

extension OrgTimestamp {
    /// Build a minimal OrgTimestamp from a raw org timestamp string.
    /// Used by optimistic patch so date fields update immediately without
    /// waiting for a round-trip. The full structured parse happens after the
    /// server reconcile; this only needs to carry `raw` and `date` forward
    /// so row formatters have something non-nil to display.
    init?(rawString: String) {
        guard let date = OrgTimestamp.parseDateString(rawString)
        else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: date)
        self.raw = rawString
        self.date = dateStr
        self.start = nil
        self.end = nil
        self.type = nil
        self.repeater = nil
        self.warning = nil
    }
}

// MARK: - AgendaEntry memberwise init (extension)
//
// AgendaEntry defines init(from decoder:) in its struct body, which suppresses
// the compiler-synthesized memberwise init. We provide our own here so
// patching(_:) can construct copies without touching Models.swift.

extension AgendaEntry {
    init(id: String, title: String, agendaType: String,
         todoState: String?, priority: String?,
         tags: [String], inheritedTags: [String],
         scheduled: OrgTimestamp?, deadline: OrgTimestamp?,
         category: String, level: Int, file: String, pos: Int,
         effort: String?, warntime: String?, timeOfDay: String?,
         displayDate: String?, tsDate: String?, extra: String?,
         isHabit: Bool, notes: String?) {
        self.id = id
        self.title = title
        self.agendaType = agendaType
        self.todoState = todoState
        self.priority = priority
        self.tags = tags
        self.inheritedTags = inheritedTags
        self.scheduled = scheduled
        self.deadline = deadline
        self.category = category
        self.level = level
        self.file = file
        self.pos = pos
        self.effort = effort
        self.warntime = warntime
        self.timeOfDay = timeOfDay
        self.displayDate = displayDate
        self.tsDate = tsDate
        self.extra = extra
        self.isHabit = isHabit
        self.notes = notes
    }
}

// MARK: - OrgTask optimistic patch

extension OrgTask {
    /// Return a copy of the task with one field replaced. Used exclusively by
    /// TasksStore's optimistic-update layer — not general mutation.
    func patching(_ field: TasksStore.OptimisticField) -> OrgTask {
        switch field {
        case .todoState(let s):
            return OrgTask(id: id, title: title, todoState: s, priority: priority,
                           tags: tags, inheritedTags: inheritedTags,
                           scheduled: scheduled, deadline: deadline, closed: closed,
                           completions: completions, category: category, level: level,
                           file: file, pos: pos, parentId: parentId, effort: effort,
                           notes: notes, activeTimestamps: activeTimestamps,
                           properties: properties)
        case .priority(let p):
            return OrgTask(id: id, title: title, todoState: todoState, priority: p,
                           tags: tags, inheritedTags: inheritedTags,
                           scheduled: scheduled, deadline: deadline, closed: closed,
                           completions: completions, category: category, level: level,
                           file: file, pos: pos, parentId: parentId, effort: effort,
                           notes: notes, activeTimestamps: activeTimestamps,
                           properties: properties)
        case .scheduled(let ts):
            return OrgTask(id: id, title: title, todoState: todoState, priority: priority,
                           tags: tags, inheritedTags: inheritedTags,
                           scheduled: ts, deadline: deadline, closed: closed,
                           completions: completions, category: category, level: level,
                           file: file, pos: pos, parentId: parentId, effort: effort,
                           notes: notes, activeTimestamps: activeTimestamps,
                           properties: properties)
        case .deadline(let ts):
            return OrgTask(id: id, title: title, todoState: todoState, priority: priority,
                           tags: tags, inheritedTags: inheritedTags,
                           scheduled: scheduled, deadline: ts, closed: closed,
                           completions: completions, category: category, level: level,
                           file: file, pos: pos, parentId: parentId, effort: effort,
                           notes: notes, activeTimestamps: activeTimestamps,
                           properties: properties)
        case .property(let key, let value):
            var updated = properties ?? [:]
            // An empty value means "remove" — mirrors eav-set-property semantics.
            if value.isEmpty {
                updated.removeValue(forKey: key)
            } else {
                updated[key] = value
            }
            return OrgTask(id: id, title: title, todoState: todoState, priority: priority,
                           tags: tags, inheritedTags: inheritedTags,
                           scheduled: scheduled, deadline: deadline, closed: closed,
                           completions: completions, category: category, level: level,
                           file: file, pos: pos, parentId: parentId, effort: effort,
                           notes: notes, activeTimestamps: activeTimestamps,
                           properties: updated)
        }
    }
}

// MARK: - AgendaEntry optimistic patch

extension AgendaEntry {
    /// Return a copy of the entry with one field replaced. `property` is a
    /// no-op because AgendaEntry has no properties dict.
    func patching(_ field: TasksStore.OptimisticField) -> AgendaEntry {
        switch field {
        case .todoState(let s):
            return AgendaEntry(id: id, title: title, agendaType: agendaType,
                               todoState: s, priority: priority,
                               tags: tags, inheritedTags: inheritedTags,
                               scheduled: scheduled, deadline: deadline,
                               category: category, level: level, file: file, pos: pos,
                               effort: effort, warntime: warntime, timeOfDay: timeOfDay,
                               displayDate: displayDate, tsDate: tsDate, extra: extra,
                               isHabit: isHabit, notes: notes)
        case .priority(let p):
            return AgendaEntry(id: id, title: title, agendaType: agendaType,
                               todoState: todoState, priority: p,
                               tags: tags, inheritedTags: inheritedTags,
                               scheduled: scheduled, deadline: deadline,
                               category: category, level: level, file: file, pos: pos,
                               effort: effort, warntime: warntime, timeOfDay: timeOfDay,
                               displayDate: displayDate, tsDate: tsDate, extra: extra,
                               isHabit: isHabit, notes: notes)
        case .scheduled(let ts):
            return AgendaEntry(id: id, title: title, agendaType: agendaType,
                               todoState: todoState, priority: priority,
                               tags: tags, inheritedTags: inheritedTags,
                               scheduled: ts, deadline: deadline,
                               category: category, level: level, file: file, pos: pos,
                               effort: effort, warntime: warntime, timeOfDay: timeOfDay,
                               displayDate: displayDate, tsDate: tsDate, extra: extra,
                               isHabit: isHabit, notes: notes)
        case .deadline(let ts):
            return AgendaEntry(id: id, title: title, agendaType: agendaType,
                               todoState: todoState, priority: priority,
                               tags: tags, inheritedTags: inheritedTags,
                               scheduled: scheduled, deadline: ts,
                               category: category, level: level, file: file, pos: pos,
                               effort: effort, warntime: warntime, timeOfDay: timeOfDay,
                               displayDate: displayDate, tsDate: tsDate, extra: extra,
                               isHabit: isHabit, notes: notes)
        case .property:
            // AgendaEntry has no properties dict; patch is a no-op.
            return self
        }
    }
}
