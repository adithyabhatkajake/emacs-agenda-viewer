/**
 * Habit statistics — adapted to work with the DB-backed Habit type.
 *
 * All computation is pure (no side-effects, no network). The math
 * collapses completion timestamps into "periods" sized to match the
 * habit's cadence. A daily habit uses day-periods, a weekly habit uses
 * week-periods, and so on — so streak, strip, and percent are always
 * expressed in the cadence's own unit.
 */

import type { OrgTask, Habit } from '../types';

// ---------------------------------------------------------------------------
// Cadence
// ---------------------------------------------------------------------------

export type CadenceUnit = 'daily' | 'weekly' | 'monthly' | 'yearly' | 'other';

export interface HabitCadence {
  unit: CadenceUnit;
  /** How many of that unit per period (almost always 1). */
  value: number;
  /** Short label used for display: "d" / "w" / "mo" / "y". */
  label: string;
}

export function habitCadenceFromRepeater(
  repeater: { unit: string; value: number } | undefined,
): HabitCadence {
  if (!repeater || repeater.value <= 0) {
    return { unit: 'daily', value: 1, label: 'd' };
  }
  const v = Math.max(1, repeater.value);
  switch (repeater.unit.toLowerCase()) {
    case 'h':
    case 'd':
      return { unit: 'daily', value: v, label: 'd' };
    case 'w':
      return { unit: 'weekly', value: v, label: 'w' };
    case 'm':
      return { unit: 'monthly', value: v, label: 'mo' };
    case 'y':
      return { unit: 'yearly', value: v, label: 'y' };
    default:
      return { unit: 'other', value: v, label: repeater.unit };
  }
}

/** Map cadence unit string from DB (`d`/`w`/`m`/`y`) to internal CadenceUnit. */
export function habitCadenceFromSpec(unit: string, value: number): HabitCadence {
  const v = Math.max(1, value);
  switch (unit.toLowerCase()) {
    case 'd': return { unit: 'daily', value: v, label: 'd' };
    case 'w': return { unit: 'weekly', value: v, label: 'w' };
    case 'm': return { unit: 'monthly', value: v, label: 'mo' };
    case 'y': return { unit: 'yearly', value: v, label: 'y' };
    default:  return { unit: 'other', value: v, label: unit };
  }
}

// ---------------------------------------------------------------------------
// Detection (org-task path, still used by today.ts)
// ---------------------------------------------------------------------------

/** True when the org heading carries `:STYLE: habit` (case-insensitive). */
export function isHabit(task: OrgTask): boolean {
  const style = task.properties?.['STYLE'];
  if (!style) return false;
  return style.toLowerCase() === 'habit';
}

/** Derive the cadence bucket from the task's scheduled (or deadline) repeater. */
export function habitCadence(task: OrgTask): HabitCadence {
  const repeater =
    task.scheduled?.repeater ?? task.deadline?.repeater;
  return habitCadenceFromRepeater(repeater);
}

// ---------------------------------------------------------------------------
// Period helpers
// ---------------------------------------------------------------------------

/**
 * Parse the leading YYYY-MM-DD from an org timestamp string.
 * Handles: `2026-05-11 Mon 14:32` and bare `2026-05-11`.
 * Returns null on parse failure.
 */
export function parseOrgDate(raw: string): Date | null {
  const prefix = raw.slice(0, 10);
  const parts = prefix.split('-');
  if (parts.length !== 3) return null;
  const [ys, ms, ds] = parts;
  const y = parseInt(ys, 10);
  const m = parseInt(ms, 10);
  const d = parseInt(ds, 10);
  if (isNaN(y) || isNaN(m) || isNaN(d)) return null;
  return new Date(y, m - 1, d);
}

/**
 * Truncate `date` to the start of the period it falls in, using the
 * given cadence. The returned Date uses local midnight.
 *
 * Weekly periods start on Monday (ISO-8601), matching HabitStats.swift.
 */
export function periodStart(date: Date, cadence: HabitCadence): Date {
  switch (cadence.unit) {
    case 'daily':
      return new Date(date.getFullYear(), date.getMonth(), date.getDate());
    case 'weekly': {
      // ISO week: Monday = 0, ..., Sunday = 6
      const dow = (date.getDay() + 6) % 7; // 0=Mon .. 6=Sun
      return new Date(
        date.getFullYear(),
        date.getMonth(),
        date.getDate() - dow,
      );
    }
    case 'monthly':
      return new Date(date.getFullYear(), date.getMonth(), 1);
    case 'yearly':
      return new Date(date.getFullYear(), 0, 1);
    case 'other':
      return new Date(date.getFullYear(), date.getMonth(), date.getDate());
  }
}

/** Add `n * cadence.value` periods to `date`. Returns a new Date. */
function addPeriods(date: Date, cadence: HabitCadence, n: number): Date {
  const d = new Date(date);
  const steps = n * cadence.value;
  switch (cadence.unit) {
    case 'daily':
    case 'other':
      d.setDate(d.getDate() + steps);
      break;
    case 'weekly':
      d.setDate(d.getDate() + steps * 7);
      break;
    case 'monthly':
      d.setMonth(d.getMonth() + steps);
      break;
    case 'yearly':
      d.setFullYear(d.getFullYear() + steps);
      break;
  }
  return d;
}

function dateKey(d: Date): number {
  return d.getTime();
}

// ---------------------------------------------------------------------------
// Strip cell state
// ---------------------------------------------------------------------------

export type CellState = 'done' | 'missed' | 'upcoming';

// ---------------------------------------------------------------------------
// Stats — DB-backed Habit
// ---------------------------------------------------------------------------

export interface HabitStats {
  cadence: HabitCadence;
  currentStreak: number;
  longestStreak: number;
  /** Oldest at index 0, current period at the end. Length = WINDOW. */
  cells: CellState[];
  /** [0, 1] fraction of window cells that are 'done'. */
  completionRate: number;
  /** Whether the current period is already completed. */
  doneThisPeriod: boolean;
}

const WINDOW = 14;

/**
 * Compute habit stats for a DB-backed Habit.
 *
 * `completions` — org-style timestamp strings from the server, newest-first.
 * `today`       — injectable for testing; defaults to now.
 */
export function habitStatsFromDB(
  habit: Habit,
  today: Date = new Date(),
): HabitStats {
  const cadence = habitCadenceFromSpec(habit.cadence.unit, habit.cadence.value);

  // completions are newest-first per API contract; parse all of them.
  const rawDates: Date[] = habit.completions.flatMap(s => {
    const d = parseOrgDate(s);
    return d ? [d] : [];
  });

  // --- Build done-set keyed by period start --------------------------------
  const doneSet = new Set<number>();
  for (const d of rawDates) {
    doneSet.add(dateKey(periodStart(d, cadence)));
  }

  const currentPeriod = periodStart(today, cadence);
  const currentKey = dateKey(currentPeriod);

  // --- Build cells (oldest first) ------------------------------------------
  const cells: CellState[] = [];
  for (let offset = WINDOW - 1; offset >= 0; offset--) {
    const cellStart = addPeriods(currentPeriod, cadence, -offset);
    const k = dateKey(periodStart(cellStart, cadence));
    if (doneSet.has(k)) {
      cells.push('done');
    } else if (k === currentKey) {
      cells.push('upcoming');
    } else {
      cells.push('missed');
    }
  }

  // --- Current streak ------------------------------------------------------
  let currentStreak = 0;
  let cursor = addPeriods(currentPeriod, cadence, -1);
  while (doneSet.has(dateKey(periodStart(cursor, cadence)))) {
    currentStreak++;
    cursor = addPeriods(cursor, cadence, -1);
  }
  if (doneSet.has(currentKey)) {
    currentStreak++;
  }

  // --- Longest streak ------------------------------------------------------
  const sortedKeys = [...doneSet].sort((a, b) => a - b);
  let longestStreak = 0;
  let run = 0;
  let prevKey: number | null = null;
  for (const k of sortedKeys) {
    const expectedKey: number | null = prevKey !== null
      ? dateKey(addPeriods(new Date(prevKey), cadence, 1))
      : null;
    if (expectedKey !== null && k === expectedKey) {
      run++;
    } else {
      run = 1;
    }
    if (run > longestStreak) longestStreak = run;
    prevKey = k;
  }

  // --- Completion rate -----------------------------------------------------
  const doneCount = cells.filter(c => c === 'done').length;
  const completionRate = cells.length > 0 ? doneCount / cells.length : 0;

  const doneThisPeriod = doneSet.has(currentKey);

  return {
    cadence,
    currentStreak,
    longestStreak,
    cells,
    completionRate,
    doneThisPeriod,
  };
}

/**
 * Compute habit stats for an OrgTask (legacy/org-habit path).
 *
 * `completions`  — raw org timestamp strings from the daemon (may be undefined).
 * `lastRepeat`   — value of the `:LAST_REPEAT:` property.
 * `today`        — injectable for testing; defaults to now.
 */
export function habitStats(
  task: OrgTask,
  today: Date = new Date(),
): HabitStats {
  const cadence = habitCadence(task);
  const completions = task.completions;
  const lastRepeat = task.properties?.['LAST_REPEAT'];

  // --- Gather all completion dates ----------------------------------------
  const rawDates: Date[] = (completions ?? []).flatMap(s => {
    const d = parseOrgDate(s);
    return d ? [d] : [];
  });
  if (lastRepeat) {
    const stripped = lastRepeat.trim().replace(/^\[/, '').replace(/\]$/, '');
    const d = parseOrgDate(stripped);
    if (d) rawDates.push(d);
  }

  // --- Build done-set keyed by period start --------------------------------
  const doneSet = new Set<number>();
  for (const d of rawDates) {
    doneSet.add(dateKey(periodStart(d, cadence)));
  }

  const currentPeriod = periodStart(today, cadence);
  const currentKey = dateKey(currentPeriod);

  // --- Build cells (oldest first) ------------------------------------------
  const cells: CellState[] = [];
  for (let offset = WINDOW - 1; offset >= 0; offset--) {
    const cellStart = addPeriods(currentPeriod, cadence, -offset);
    const k = dateKey(periodStart(cellStart, cadence));
    if (doneSet.has(k)) {
      cells.push('done');
    } else if (k === currentKey) {
      cells.push('upcoming');
    } else {
      cells.push('missed');
    }
  }

  // --- Current streak ------------------------------------------------------
  let currentStreak = 0;
  let cursor = addPeriods(currentPeriod, cadence, -1);
  while (doneSet.has(dateKey(periodStart(cursor, cadence)))) {
    currentStreak++;
    cursor = addPeriods(cursor, cadence, -1);
  }
  if (doneSet.has(currentKey)) {
    currentStreak++;
  }

  // --- Longest streak ------------------------------------------------------
  const sortedKeys = [...doneSet].sort((a, b) => a - b);
  let longestStreak = 0;
  let run = 0;
  let prevKey: number | null = null;
  for (const k of sortedKeys) {
    const expectedKey: number | null = prevKey !== null
      ? dateKey(addPeriods(new Date(prevKey), cadence, 1))
      : null;
    if (expectedKey !== null && k === expectedKey) {
      run++;
    } else {
      run = 1;
    }
    if (run > longestStreak) longestStreak = run;
    prevKey = k;
  }

  // --- Completion rate -----------------------------------------------------
  const doneCount = cells.filter(c => c === 'done').length;
  const completionRate = cells.length > 0 ? doneCount / cells.length : 0;

  const doneThisPeriod = doneSet.has(currentKey);

  return {
    cadence,
    currentStreak,
    longestStreak,
    cells,
    completionRate,
    doneThisPeriod,
  };
}

// ---------------------------------------------------------------------------
// Bucket helpers — DB-backed Habit
// ---------------------------------------------------------------------------

export interface HabitBucket {
  title: string;
  habits: Habit[];
  doneCount: number;
}

/**
 * Group DB habits into cadence buckets, sorted undone-first within each bucket.
 * Empty buckets are omitted.
 */
export function habitBucketsFromDB(habits: Habit[], today: Date = new Date()): HabitBucket[] {
  const daily: Habit[] = [];
  const weekly: Habit[] = [];
  const monthly: Habit[] = [];
  const yearly: Habit[] = [];
  const other: Habit[] = [];

  for (const h of habits) {
    const c = habitCadenceFromSpec(h.cadence.unit, h.cadence.value);
    switch (c.unit) {
      case 'daily':   daily.push(h);   break;
      case 'weekly':  weekly.push(h);  break;
      case 'monthly': monthly.push(h); break;
      case 'yearly':  yearly.push(h);  break;
      default:        other.push(h);   break;
    }
  }

  const prioritize = (items: Habit[]): Habit[] =>
    [...items].sort((a, b) => {
      const aDone = habitStatsFromDB(a, today).doneThisPeriod;
      const bDone = habitStatsFromDB(b, today).doneThisPeriod;
      if (aDone !== bDone) return aDone ? 1 : -1;
      return a.title.localeCompare(b.title);
    });

  const makeBucket = (title: string, items: Habit[]): HabitBucket | null => {
    if (items.length === 0) return null;
    const sorted = prioritize(items);
    const doneCount = sorted.filter(h => habitStatsFromDB(h, today).doneThisPeriod).length;
    return { title, habits: sorted, doneCount };
  };

  return [
    makeBucket('Today', daily),
    makeBucket('This Week', weekly),
    makeBucket('This Month', monthly),
    makeBucket('This Year', yearly),
    makeBucket('Other', other),
  ].filter((b): b is HabitBucket => b !== null);
}

// ---------------------------------------------------------------------------
// Due-state bucketing (mirrors HabitsGroupingNew.dueStateBuckets in Swift)
// ---------------------------------------------------------------------------

function habitPriorityOrd(p: string | undefined): number {
  switch (p?.toUpperCase()) {
    case 'A': return 0;
    case 'B': return 1;
    case 'C': return 2;
    case 'D': return 3;
    default:  return 4;
  }
}

const byPriority = (a: Habit, b: Habit): number => {
  const rA = habitPriorityOrd(a.priority);
  const rB = habitPriorityOrd(b.priority);
  if (rA !== rB) return rA - rB;
  const ndA = a.nextDue ?? '';
  const ndB = b.nextDue ?? '';
  if (ndA !== ndB) return ndA < ndB ? -1 : 1;
  return a.title.localeCompare(b.title);
};

/**
 * Group habits by due state: Overdue / Today / Upcoming / Done.
 * Done-this-period habits are always placed in the Done bucket regardless
 * of the server state field. Within each bucket, habits sort by priority
 * (A first), then by nextDue, then by title.
 */
export function habitDueStateBuckets(habits: Habit[], today: Date = new Date()): HabitBucket[] {
  const overdue: Habit[] = [];
  const dueToday: Habit[] = [];
  const upcoming: Habit[] = [];
  const done: Habit[] = [];

  for (const h of habits) {
    if (habitStatsFromDB(h, today).doneThisPeriod) {
      done.push(h);
      continue;
    }
    switch (h.state) {
      case 'overdue': overdue.push(h); break;
      case 'due':     dueToday.push(h); break;
      default:        upcoming.push(h); break;
    }
  }

  const makeBucket = (title: string, items: Habit[]): HabitBucket | null => {
    if (items.length === 0) return null;
    const sorted = [...items].sort(byPriority);
    const doneCount = sorted.filter(h => habitStatsFromDB(h, today).doneThisPeriod).length;
    return { title, habits: sorted, doneCount };
  };

  return [
    makeBucket('Overdue', overdue),
    makeBucket('Today', dueToday),
    makeBucket('Upcoming', upcoming),
    makeBucket('Done', done),
  ].filter((b): b is HabitBucket => b !== null);
}

// ---------------------------------------------------------------------------
// Display-date helper (mirrors habitDisplayDate in HabitExpandableRow.swift)
// ---------------------------------------------------------------------------

/**
 * Compute the display date for a habit's meta line.
 * For relaxed cadences, returns nextDue + (maxInterval - minInterval) in days,
 * which is the last day before the habit is considered missed.
 * Returns null when nextDue is absent or unparseable.
 */
export function habitDisplayDate(habit: Habit): Date | null {
  if (!habit.nextDue) return null;
  const base = parseOrgDate(habit.nextDue);
  if (!base) return null;

  const { value, unit, maxValue, maxUnit } = habit.cadence;
  if (maxValue != null && maxUnit != null) {
    const addDays = (d: Date, days: number): Date => {
      const r = new Date(d);
      r.setDate(r.getDate() + days);
      return r;
    };
    const addInterval = (d: Date, v: number, u: string): Date => {
      const r = new Date(d);
      switch (u.toLowerCase()) {
        case 'd': r.setDate(r.getDate() + v); break;
        case 'w': r.setDate(r.getDate() + v * 7); break;
        case 'm': r.setMonth(r.getMonth() + v); break;
        case 'y': r.setFullYear(r.getFullYear() + v); break;
      }
      return r;
    };
    const minEnd = addInterval(base, value, unit);
    const maxEnd = addInterval(base, maxValue, maxUnit);
    const extraMs = maxEnd.getTime() - minEnd.getTime();
    const extraDays = Math.round(extraMs / 86400000);
    return addDays(base, extraDays);
  }
  return base;
}

// ---------------------------------------------------------------------------
// Compact cadence string (↻ glyph + interval)
// ---------------------------------------------------------------------------

/**
 * Returns a compact cadence interval string like "1d", "2w", "1–2w".
 * Used with a ↻ glyph to replicate the iOS recurrence label.
 */
export function compactCadenceInterval(cadence: Habit['cadence']): string {
  const unitMap: Record<string, string> = { d: 'd', w: 'w', m: 'mo', y: 'y' };
  const u = unitMap[cadence.unit] ?? cadence.unit;
  const min = `${cadence.value}${u}`;
  if (cadence.maxValue != null && cadence.maxUnit != null) {
    const mu = unitMap[cadence.maxUnit] ?? cadence.maxUnit;
    return `${min}–${cadence.maxValue}${mu}`;
  }
  return min;
}

/**
 * Return a relative-date label for a Date (same scale as formatTimestamp).
 * "Today" / "Tomorrow" / "Yesterday" / weekday name / "Jan 5" / etc.
 */
export function habitRelativeDateLabel(date: Date, today: Date = new Date()): string {
  const t = new Date(today.getFullYear(), today.getMonth(), today.getDate());
  const d = new Date(date.getFullYear(), date.getMonth(), date.getDate());
  const diff = Math.floor((d.getTime() - t.getTime()) / 86400000);
  if (diff === 0) return 'Today';
  if (diff === 1) return 'Tomorrow';
  if (diff === -1) return 'Yesterday';
  if (diff < -1) return `${Math.abs(diff)}d ago`;
  if (diff <= 6) return date.toLocaleDateString('en-US', { weekday: 'short' });
  return date.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
}
