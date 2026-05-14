/**
 * Habit detection and statistics — ported from HabitStats.swift.
 *
 * All computation is pure (no side-effects, no network). The math
 * collapses completion timestamps into "periods" sized to match the
 * heading's scheduled repeater. A daily habit uses day-periods, a
 * weekly habit uses week-periods, and so on — so streak, strip, and
 * percent are always expressed in the cadence's own unit.
 */

import type { OrgTask } from '../types';

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

// ---------------------------------------------------------------------------
// Detection
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
// Stats
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
 * Compute habit stats for one task.
 *
 * `completions`  — raw org timestamp strings from the daemon (may be undefined).
 * `lastRepeat`   — value of the `:LAST_REPEAT:` property (brackets included),
 *                  e.g. `[2026-05-12 Tue 09:52]`. On `.+` / `++` repeaters
 *                  org-habit writes this instead of (or in addition to) a
 *                  State "DONE" LOGBOOK line, so we must include it.
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
    // Strip surrounding brackets: `[2026-05-12 Tue 09:52]` → `2026-05-12 Tue 09:52`
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
  // Walk backward from the last *closed* period. The open current period
  // doesn't break a streak — you just haven't done it yet.
  let currentStreak = 0;
  let cursor = addPeriods(currentPeriod, cadence, -1);
  while (doneSet.has(dateKey(periodStart(cursor, cadence)))) {
    currentStreak++;
    cursor = addPeriods(cursor, cadence, -1);
  }
  // If the current period is already done, prepend it.
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
// Bucket helpers
// ---------------------------------------------------------------------------

export interface HabitBucket {
  title: string;
  habits: OrgTask[];
  doneCount: number;
}

/**
 * Group habits into cadence buckets, sorted undone-first within each bucket.
 * Empty buckets are omitted.
 */
export function habitBuckets(habits: OrgTask[], today: Date = new Date()): HabitBucket[] {
  const daily: OrgTask[] = [];
  const weekly: OrgTask[] = [];
  const monthly: OrgTask[] = [];
  const yearly: OrgTask[] = [];
  const other: OrgTask[] = [];

  for (const h of habits) {
    const c = habitCadence(h);
    switch (c.unit) {
      case 'daily':   daily.push(h);   break;
      case 'weekly':  weekly.push(h);  break;
      case 'monthly': monthly.push(h); break;
      case 'yearly':  yearly.push(h);  break;
      default:        other.push(h);   break;
    }
  }

  const prioritize = (tasks: OrgTask[]): OrgTask[] =>
    [...tasks].sort((a, b) => {
      const aDone = habitStats(a, today).doneThisPeriod;
      const bDone = habitStats(b, today).doneThisPeriod;
      if (aDone !== bDone) return aDone ? 1 : -1;
      return a.title.localeCompare(b.title);
    });

  const makeBucket = (title: string, tasks: OrgTask[]): HabitBucket | null => {
    if (tasks.length === 0) return null;
    const sorted = prioritize(tasks);
    const doneCount = sorted.filter(t => habitStats(t, today).doneThisPeriod).length;
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
