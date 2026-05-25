/**
 * Canonical Today-view rule, mirrored across iOS, Mac, and the web client.
 *
 * Source of truth: `apps/macos/EmacsAgendaViewer/State/TodayClassifier.swift`.
 * This file ports the same rules to TypeScript so the web UI doesn't drift.
 *
 * Rules (must match the Swift classifier exactly):
 * - Events (`timestamp` / `block` / `sexp` with no TODO state) go in the
 *   `events` bucket.
 * - `agendaType === 'upcoming-deadline'` is ALWAYS dropped from Today.
 * - A task qualifies for `main` if any of:
 *     * its scheduled timestamp is today
 *     * its deadline timestamp is today
 *     * its scheduled timestamp is in the past (overdue)
 * - Habits are dropped when `hideHabits === true`.
 * - Tasks whose `todoState` is in `doneStates` (case-insensitive) are dropped.
 * - Dedupe by task id. When both a scheduled-today AND a deadline-today entry
 *   exist for the same heading, the deadline variant wins.
 * - Overdue OrgTasks (from `/api/tasks`) not already in `today` are pulled in.
 *   Habits and done tasks are skipped.
 *
 * The function is pure — no DOM, no settings I/O, no fetch. Caller is
 * responsible for fetching both inputs and for any view-specific filtering.
 */

import type { AgendaEntry, OrgTask, OrgTimestamp } from '../types';

const EVENT_TYPES = new Set(['timestamp', 'block', 'sexp']);

/** True for calendar-style entries — diary sexps, ranged blocks, plain
 *  `<YYYY-MM-DD>` timestamps. They render as banners, not task rows. */
function isEvent(entry: AgendaEntry): boolean {
  return EVENT_TYPES.has(entry.agendaType) && !entry.todoState;
}

/** Mirrors OrgTask.isHabit on the Swift side (`:STYLE: habit`). */
function isHabitTask(task: OrgTask): boolean {
  const style = task.properties?.['STYLE'];
  return !!style && style.toLowerCase() === 'habit';
}

/** True when the timestamp component's date is today (local calendar). */
export function matchesToday(comp: OrgTimestamp['start'] | undefined): boolean {
  if (!comp) return false;
  const now = new Date();
  return (
    comp.year === now.getFullYear() &&
    comp.month === now.getMonth() + 1 &&
    comp.day === now.getDate()
  );
}

/** True when the timestamp component's date is strictly before today
 *  (midnight in the local calendar). */
export function isPast(comp: OrgTimestamp['start'] | undefined): boolean {
  if (!comp) return false;
  const cmp = new Date(comp.year, comp.month - 1, comp.day).getTime();
  const now = new Date();
  const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  return cmp < startOfToday;
}

/** True when the row's scheduled date is in the past — used by the row UI
 *  to mark overdue items regardless of source (AgendaEntry or OrgTask). */
export function isOverdue(item: AgendaEntry | OrgTask): boolean {
  return isPast(item.scheduled?.start);
}

export interface TodayItems {
  events: AgendaEntry[];
  /** Heterogeneous list of task rows — `AgendaEntry` for today-anchored
   *  entries, `OrgTask` for overdue rows pulled from `/api/tasks`. */
  main: Array<AgendaEntry | OrgTask>;
}

export function buildTodayItems(
  today: AgendaEntry[],
  all: OrgTask[],
  doneStates: Set<string>,
  hideHabits: boolean,
): TodayItems {
  const events: AgendaEntry[] = [];
  const byId = new Map<string, AgendaEntry>();
  const insertionOrder: string[] = [];

  // Normalize done states to uppercase once so the per-entry check stays cheap.
  const doneUpper = new Set<string>();
  for (const s of doneStates) doneUpper.add(s.toUpperCase());

  for (const entry of today) {
    if (isEvent(entry)) {
      events.push(entry);
      continue;
    }
    // Strict "today only": deadline previews always belong to Upcoming.
    if (entry.agendaType === 'upcoming-deadline') continue;

    const todayScheduled = matchesToday(entry.scheduled?.start);
    const todayDeadline = matchesToday(entry.deadline?.start);
    const overdueScheduled = isPast(entry.scheduled?.start);
    if (!todayScheduled && !todayDeadline && !overdueScheduled) continue;

    if (hideHabits && entry.isHabit) continue;

    const state = entry.todoState;
    if (state && doneUpper.has(state.toUpperCase())) continue;

    const existing = byId.get(entry.id);
    if (existing) {
      // Prefer the deadline variant when both surface for the same heading.
      if (entry.agendaType === 'deadline' && existing.agendaType !== 'deadline') {
        byId.set(entry.id, entry);
      }
    } else {
      byId.set(entry.id, entry);
      insertionOrder.push(entry.id);
    }
  }

  const todayIds = new Set(byId.keys());

  const overdue: OrgTask[] = all.filter((task) => {
    if (hideHabits && isHabitTask(task)) return false;
    const comp = task.scheduled?.start;
    if (!isPast(comp)) return false;
    if (todayIds.has(task.id)) return false;
    const state = task.todoState;
    if (!state) return false;
    if (doneUpper.has(state.toUpperCase())) return false;
    return true;
  });

  const main: Array<AgendaEntry | OrgTask> = [];
  for (const t of overdue) main.push(t);
  for (const id of insertionOrder) {
    const e = byId.get(id);
    if (e) main.push(e);
  }
  return { events, main };
}
