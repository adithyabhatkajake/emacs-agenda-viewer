import { describe, it, expect } from 'vitest';
import { buildTodayItems } from './today';
import type { AgendaEntry, OrgTask, OrgTimestamp } from '../types';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function todayComp(): { year: number; month: number; day: number } {
  const d = new Date();
  return { year: d.getFullYear(), month: d.getMonth() + 1, day: d.getDate() };
}

function yesterdayComp(): { year: number; month: number; day: number } {
  const d = new Date();
  d.setDate(d.getDate() - 1);
  return { year: d.getFullYear(), month: d.getMonth() + 1, day: d.getDate() };
}

function ts(comp: { year: number; month: number; day: number }): OrgTimestamp {
  const raw = `<${comp.year}-${String(comp.month).padStart(2, '0')}-${String(comp.day).padStart(2, '0')}>`;
  return {
    raw,
    date: raw,
    start: comp,
    type: 'active',
  };
}

function entry(over: Partial<AgendaEntry> & Pick<AgendaEntry, 'id'>): AgendaEntry {
  return {
    title: over.title ?? `Entry ${over.id}`,
    agendaType: 'scheduled',
    todoState: 'TODO',
    tags: [],
    inheritedTags: [],
    category: 'Test',
    level: 1,
    file: '/test.org',
    pos: 1,
    ...over,
  };
}

function task(over: Partial<OrgTask> & Pick<OrgTask, 'id'>): OrgTask {
  return {
    title: over.title ?? `Task ${over.id}`,
    todoState: 'TODO',
    tags: [],
    inheritedTags: [],
    category: 'Test',
    level: 1,
    file: '/test.org',
    pos: 1,
    ...over,
  };
}

const DONE_STATES = new Set(['DONE', 'KILL']);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('buildTodayItems', () => {
  it('includes today-scheduled task in main', () => {
    const e = entry({ id: 't1', scheduled: ts(todayComp()) });
    const { main, events } = buildTodayItems([e], [], DONE_STATES, false);
    expect(main).toHaveLength(1);
    expect(main[0].id).toBe('t1');
    expect(events).toHaveLength(0);
  });

  it('includes today-deadline task in main', () => {
    const e = entry({ id: 't2', agendaType: 'deadline', deadline: ts(todayComp()) });
    const { main } = buildTodayItems([e], [], DONE_STATES, false);
    expect(main).toHaveLength(1);
    expect(main[0].id).toBe('t2');
  });

  it('drops upcoming-deadline unconditionally', () => {
    const e = entry({
      id: 't3',
      agendaType: 'upcoming-deadline',
      deadline: ts(todayComp()),
    });
    const { main } = buildTodayItems([e], [], DONE_STATES, false);
    expect(main).toHaveLength(0);
  });

  it('drops done state', () => {
    const e = entry({ id: 't4', todoState: 'DONE', scheduled: ts(todayComp()) });
    const { main } = buildTodayItems([e], [], DONE_STATES, false);
    expect(main).toHaveLength(0);
  });

  it('drops habit when hideHabits is true', () => {
    const e = entry({ id: 'h1', scheduled: ts(todayComp()), isHabit: true });
    const { main } = buildTodayItems([e], [], DONE_STATES, true);
    expect(main).toHaveLength(0);
  });

  it('includes habit when hideHabits is false', () => {
    const e = entry({ id: 'h2', scheduled: ts(todayComp()), isHabit: true });
    const { main } = buildTodayItems([e], [], DONE_STATES, false);
    expect(main).toHaveLength(1);
  });

  it('pulls overdue task from `all` into main', () => {
    const t = task({ id: 'o1', scheduled: ts(yesterdayComp()) });
    const { main } = buildTodayItems([], [t], DONE_STATES, false);
    expect(main).toHaveLength(1);
    expect(main[0].id).toBe('o1');
  });

  it('does not duplicate a task present in both today and all', () => {
    const e = entry({ id: 'dup', scheduled: ts(todayComp()) });
    const t = task({ id: 'dup', scheduled: ts(yesterdayComp()) });
    const { main } = buildTodayItems([e], [t], DONE_STATES, false);
    expect(main).toHaveLength(1);
    expect(main[0].id).toBe('dup');
  });

  it('prefers deadline variant when both scheduled and deadline entries exist', () => {
    const s = entry({ id: 'x', agendaType: 'scheduled', scheduled: ts(todayComp()) });
    const d = entry({ id: 'x', agendaType: 'deadline', deadline: ts(todayComp()) });
    for (const [a, b] of [
      [s, d],
      [d, s],
    ] as const) {
      const { main } = buildTodayItems([a, b], [], DONE_STATES, false);
      expect(main).toHaveLength(1);
      expect((main[0] as AgendaEntry).agendaType).toBe('deadline');
    }
  });

  it('routes calendar events to the events bucket, not main', () => {
    const e = entry({
      id: 'evt',
      agendaType: 'timestamp',
      todoState: undefined,
      scheduled: ts(todayComp()),
    });
    const { main, events } = buildTodayItems([e], [], DONE_STATES, false);
    expect(events).toHaveLength(1);
    expect(events[0].id).toBe('evt');
    expect(main).toHaveLength(0);
  });

  it('pulls an overdue habit OrgTask when hideHabits is false', () => {
    const t = task({
      id: 'habit-overdue',
      scheduled: ts(yesterdayComp()),
      properties: { STYLE: 'habit' },
    });
    const { main } = buildTodayItems([], [t], DONE_STATES, false);
    expect(main).toHaveLength(1);
    expect(main[0].id).toBe('habit-overdue');
  });

  it('drops an overdue habit OrgTask when hideHabits is true', () => {
    const t = task({
      id: 'habit-overdue',
      scheduled: ts(yesterdayComp()),
      properties: { STYLE: 'habit' },
    });
    const { main } = buildTodayItems([], [t], DONE_STATES, true);
    expect(main).toHaveLength(0);
  });

  it('does not pull a done OrgTask as overdue', () => {
    const t = task({ id: 'done-overdue', todoState: 'DONE', scheduled: ts(yesterdayComp()) });
    const { main } = buildTodayItems([], [t], DONE_STATES, false);
    expect(main).toHaveLength(0);
  });
});
