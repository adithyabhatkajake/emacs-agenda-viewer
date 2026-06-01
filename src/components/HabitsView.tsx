/**
 * Habits dashboard — read-only streak analytics.
 *
 * Summary chips (today done/total, best streak, 30-day rate) at the top.
 * Per-habit read-only stats row: title + 14-cell consistency strip +
 * current streak + best streak + completion %. Sorted by current streak
 * desc, then alphabetically.
 *
 * New Habit button / edit modal are kept for capture. Tapping a row opens
 * the edit modal. All completion/skip/schedule actions live in All Tasks.
 */

import { useState } from 'react';
import { ArrowsClockwise, Plus, X } from '@phosphor-icons/react';
import type { Habit, HabitCadenceSpec, TodoKeywords } from '../types';
import {
  createHabit,
  updateHabit,
  type CreateHabitBody,
} from '../api/tasks';
import {
  habitStatsFromDB,
  compactCadenceInterval,
} from '../utils/habits';
import type { CellState } from '../utils/habits';

// ---------------------------------------------------------------------------
// Cadence label helper
// ---------------------------------------------------------------------------

function cadenceLabel(cadence: HabitCadenceSpec): string {
  const unitLabel: Record<string, string> = { d: 'day', w: 'week', m: 'month', y: 'year' };
  const unit = unitLabel[cadence.unit] ?? cadence.unit;
  const plural = cadence.value !== 1 ? 's' : '';
  if (cadence.maxValue != null) {
    const maxUnit = unitLabel[cadence.maxUnit ?? cadence.unit] ?? (cadence.maxUnit ?? cadence.unit);
    const maxPlural = cadence.maxValue !== 1 ? 's' : '';
    return `every ${cadence.value}–${cadence.maxValue} ${maxUnit}${maxPlural}`;
  }
  return cadence.value === 1 ? `every ${unit}` : `every ${cadence.value} ${unit}${plural}`;
}

// ---------------------------------------------------------------------------
// Strip cell (read-only)
// ---------------------------------------------------------------------------

function HabitCell({ state }: { state: CellState }) {
  switch (state) {
    case 'done':
      return (
        <span
          className="inline-block w-3.5 h-3.5 md:w-4 md:h-4 rounded-sm bg-done-green flex-shrink-0"
          title="Done"
        />
      );
    case 'missed':
      return (
        <span
          className="inline-block w-3.5 h-3.5 md:w-4 md:h-4 rounded-sm bg-text-tertiary/20 flex-shrink-0"
          title="Missed"
        />
      );
    case 'upcoming':
      return (
        <span
          className="inline-block w-3.5 h-3.5 md:w-4 md:h-4 rounded-sm border border-accent/60 flex-shrink-0"
          title="Current period (not done yet)"
        />
      );
  }
}

function HabitStrip({ cells, isMobile }: { cells: CellState[]; isMobile: boolean }) {
  const display = isMobile ? cells.slice(-7) : cells;
  return (
    <div className="flex items-center gap-0.5 md:gap-[3px]">
      {display.map((cell, i) => (
        <HabitCell key={i} state={cell} />
      ))}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Per-habit read-only stats row
// ---------------------------------------------------------------------------

function HabitDashboardRow({
  habit,
  isMobile,
  onEdit,
}: {
  habit: Habit;
  isMobile: boolean;
  onEdit: (h: Habit) => void;
}) {
  const today = new Date();
  const stats = habitStatsFromDB(habit, today);
  const { currentStreak, longestStreak, cells, completionRate } = stats;
  const recurrenceLabel = compactCadenceInterval(habit.cadence);

  return (
    <div
      className="group border-b border-things-border-subtle/30 hover:bg-things-sidebar-hover/30 transition-colors cursor-pointer"
      onClick={() => onEdit(habit)}
      title="Edit habit"
    >
      <div className="flex items-center gap-3 px-3 md:px-5 py-2 md:py-1.5">
        {/* Title + cadence */}
        <div className="flex-1 min-w-0">
          <span className="block truncate text-[14px] md:text-[13px] leading-snug text-text-primary" title={habit.title}>
            {habit.title}
          </span>
          <div className="flex items-center gap-2 mt-0.5">
            {habit.category && (
              <span className="text-[10px] text-text-tertiary">{habit.category}</span>
            )}
            <span className="text-[10px] text-text-tertiary flex items-center gap-0.5">
              {'↻'}{recurrenceLabel}
            </span>
          </div>
        </div>

        {/* Consistency strip */}
        <div className="flex-shrink-0">
          <HabitStrip cells={cells} isMobile={isMobile} />
        </div>

        {/* Stats: current streak / best / completion % */}
        <div className="flex items-center gap-3 flex-shrink-0 text-[11px] tabular-nums">
          <div className="flex flex-col items-center min-w-[28px]">
            <span className={`font-semibold ${currentStreak > 0 ? 'text-done-green' : 'text-text-tertiary'}`}>
              {currentStreak}
            </span>
            <span className="text-[9px] text-text-tertiary">streak</span>
          </div>
          <div className="hidden sm:flex flex-col items-center min-w-[28px]">
            <span className="font-semibold text-text-secondary">{longestStreak}</span>
            <span className="text-[9px] text-text-tertiary">best</span>
          </div>
          <div className="flex flex-col items-center min-w-[32px]">
            <span className="font-semibold text-text-secondary">{Math.round(completionRate * 100)}%</span>
            <span className="text-[9px] text-text-tertiary">rate</span>
          </div>
        </div>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Habit form (create / edit)
// ---------------------------------------------------------------------------

interface HabitFormState {
  title: string;
  cadenceKind: '+' | '++' | '.+';
  cadenceValue: number;
  cadenceUnit: 'd' | 'w' | 'm' | 'y';
  hasMax: boolean;
  maxValue: number;
  maxUnit: 'd' | 'w' | 'm' | 'y';
  category: string;
  priority: string;
  tags: string;
  notes: string;
  resetChecklistOnComplete: boolean;
}

function defaultFormState(): HabitFormState {
  return {
    title: '',
    cadenceKind: '+',
    cadenceValue: 1,
    cadenceUnit: 'd',
    hasMax: false,
    maxValue: 2,
    maxUnit: 'd',
    category: '',
    priority: '',
    tags: '',
    notes: '',
    resetChecklistOnComplete: false,
  };
}

export function formStateFromHabit(habit: Habit): HabitFormState {
  return {
    title: habit.title,
    cadenceKind: (habit.cadence.kind as '+' | '++' | '.+') || '+',
    cadenceValue: habit.cadence.value,
    cadenceUnit: (habit.cadence.unit as 'd' | 'w' | 'm' | 'y') || 'd',
    hasMax: habit.cadence.maxValue != null,
    maxValue: habit.cadence.maxValue ?? 2,
    maxUnit: (habit.cadence.maxUnit as 'd' | 'w' | 'm' | 'y') ?? (habit.cadence.unit as 'd' | 'w' | 'm' | 'y') ?? 'd',
    category: habit.category ?? '',
    priority: habit.priority ?? '',
    tags: habit.tags.join(' '),
    notes: habit.notes ?? '',
    resetChecklistOnComplete: habit.resetChecklistOnComplete,
  };
}

export function HabitFormModal({
  initial,
  onSubmit,
  onClose,
  submitting,
  editingId,
}: {
  initial: HabitFormState;
  onSubmit: (body: CreateHabitBody) => void;
  onClose: () => void;
  submitting: boolean;
  editingId?: string;
}) {
  const [form, setForm] = useState<HabitFormState>(initial);

  const set = <K extends keyof HabitFormState>(key: K, val: HabitFormState[K]) =>
    setForm(f => ({ ...f, [key]: val }));

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!form.title.trim()) return;
    const cadence: HabitCadenceSpec = {
      kind: form.cadenceKind,
      value: form.cadenceValue,
      unit: form.cadenceUnit,
      ...(form.hasMax && form.maxValue > 0
        ? { maxValue: form.maxValue, maxUnit: form.maxUnit }
        : {}),
    };
    const body: CreateHabitBody = {
      title: form.title.trim(),
      cadence,
      ...(form.category.trim() ? { category: form.category.trim() } : {}),
      ...(form.priority.trim() ? { priority: form.priority.trim() } : {}),
      ...(form.tags.trim()
        ? { tags: form.tags.trim().split(/\s+/).filter(Boolean) }
        : {}),
      ...(form.notes.trim() ? { notes: form.notes.trim() } : {}),
      resetChecklistOnComplete: form.resetChecklistOnComplete,
    };
    onSubmit(body);
  };

  const unitOptions: Array<['d' | 'w' | 'm' | 'y', string]> = [
    ['d', 'days'],
    ['w', 'weeks'],
    ['m', 'months'],
    ['y', 'years'],
  ];

  const inputCls =
    'w-full bg-things-surface border border-things-border rounded-lg px-3 py-1.5 text-[13px] text-text-primary placeholder:text-text-tertiary focus:outline-none focus:border-accent transition-colors';

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 backdrop-blur-sm"
      onClick={e => { if (e.target === e.currentTarget) onClose(); }}
    >
      <div className="bg-things-bg border border-things-border rounded-xl shadow-2xl w-full max-w-md mx-4 overflow-hidden">
        {/* Header */}
        <div className="flex items-center justify-between px-5 py-4 border-b border-things-border">
          <span className="text-[15px] font-semibold text-text-primary">
            {editingId ? 'Edit Habit' : 'New Habit'}
          </span>
          <button
            onClick={onClose}
            className="w-7 h-7 flex items-center justify-center rounded-lg text-text-tertiary hover:text-text-secondary hover:bg-things-sidebar-hover transition-colors"
          >
            <X size={16} weight="bold" />
          </button>
        </div>

        <form onSubmit={handleSubmit} className="p-5 flex flex-col gap-4 max-h-[80vh] overflow-y-auto">
          {/* Title */}
          <div>
            <label className="block text-[11px] font-medium text-text-secondary uppercase tracking-wider mb-1">Title</label>
            <input
              className={inputCls}
              placeholder="e.g. Morning exercise"
              value={form.title}
              onChange={e => set('title', e.target.value)}
              autoFocus
              required
            />
          </div>

          {/* Cadence kind */}
          <div>
            <label className="block text-[11px] font-medium text-text-secondary uppercase tracking-wider mb-1">Cadence type</label>
            <div className="flex gap-1.5">
              {(['+', '++', '.+'] as const).map(k => (
                <button
                  key={k}
                  type="button"
                  onClick={() => set('cadenceKind', k)}
                  className={`flex-1 py-1.5 rounded-lg text-[13px] font-mono border transition-colors ${
                    form.cadenceKind === k
                      ? 'bg-accent/15 border-accent/40 text-accent'
                      : 'border-things-border text-text-secondary hover:bg-things-sidebar-hover'
                  }`}
                >
                  {k}
                </button>
              ))}
            </div>
            <p className="text-[10px] text-text-tertiary mt-1">
              {form.cadenceKind === '+'
                ? '+ : schedule relative to completion date'
                : form.cadenceKind === '++'
                  ? '++ : cumulative — skipped repetitions stack'
                  : '.+ : catch-up — only one instance can be overdue'}
            </p>
          </div>

          {/* Cadence value + unit */}
          <div>
            <label className="block text-[11px] font-medium text-text-secondary uppercase tracking-wider mb-1">Repeat every</label>
            <div className="flex gap-2">
              <input
                type="number"
                min={1}
                className={`${inputCls} w-24`}
                value={form.cadenceValue}
                onChange={e => set('cadenceValue', Math.max(1, parseInt(e.target.value) || 1))}
              />
              <select
                className={`${inputCls} flex-1`}
                value={form.cadenceUnit}
                onChange={e => set('cadenceUnit', e.target.value as 'd' | 'w' | 'm' | 'y')}
              >
                {unitOptions.map(([v, label]) => (
                  <option key={v} value={v}>{label}</option>
                ))}
              </select>
            </div>
          </div>

          {/* Relaxed range toggle */}
          <div>
            <label className="flex items-center gap-2 cursor-pointer">
              <input
                type="checkbox"
                checked={form.hasMax}
                onChange={e => set('hasMax', e.target.checked)}
                className="rounded accent-accent"
              />
              <span className="text-[12px] text-text-secondary">Relaxed range (max interval)</span>
            </label>
            {form.hasMax && (
              <div className="flex gap-2 mt-2">
                <input
                  type="number"
                  min={1}
                  className={`${inputCls} w-24`}
                  value={form.maxValue}
                  onChange={e => set('maxValue', Math.max(1, parseInt(e.target.value) || 1))}
                />
                <select
                  className={`${inputCls} flex-1`}
                  value={form.maxUnit}
                  onChange={e => set('maxUnit', e.target.value as 'd' | 'w' | 'm' | 'y')}
                >
                  {unitOptions.map(([v, label]) => (
                    <option key={v} value={v}>{label}</option>
                  ))}
                </select>
              </div>
            )}
          </div>

          {/* Optional fields */}
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="block text-[11px] font-medium text-text-secondary uppercase tracking-wider mb-1">Category</label>
              <input
                className={inputCls}
                placeholder="Optional"
                value={form.category}
                onChange={e => set('category', e.target.value)}
              />
            </div>
            <div>
              <label className="block text-[11px] font-medium text-text-secondary uppercase tracking-wider mb-1">Priority</label>
              <select
                className={inputCls}
                value={form.priority}
                onChange={e => set('priority', e.target.value)}
              >
                <option value="">None</option>
                <option value="A">A</option>
                <option value="B">B</option>
                <option value="C">C</option>
              </select>
            </div>
          </div>

          <div>
            <label className="block text-[11px] font-medium text-text-secondary uppercase tracking-wider mb-1">Tags (space-separated)</label>
            <input
              className={inputCls}
              placeholder="e.g. health fitness"
              value={form.tags}
              onChange={e => set('tags', e.target.value)}
            />
          </div>

          <div>
            <label className="block text-[11px] font-medium text-text-secondary uppercase tracking-wider mb-1">Notes</label>
            <textarea
              className={`${inputCls} resize-none font-mono text-[12px]`}
              rows={3}
              placeholder="Optional. Use - [ ] Item for checklists."
              value={form.notes}
              onChange={e => set('notes', e.target.value)}
            />
          </div>

          {/* Reset checklist on completion */}
          <label className="flex items-center gap-2 cursor-pointer">
            <input
              type="checkbox"
              checked={form.resetChecklistOnComplete}
              onChange={e => set('resetChecklistOnComplete', e.target.checked)}
              className="rounded accent-accent"
            />
            <span className="text-[12px] text-text-secondary">Reset checklist on completion</span>
          </label>

          {/* Actions */}
          <div className="flex gap-2 pt-1">
            <button
              type="button"
              onClick={onClose}
              className="flex-1 py-2 rounded-lg border border-things-border text-[13px] text-text-secondary hover:bg-things-sidebar-hover transition-colors"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={submitting || !form.title.trim()}
              className="flex-1 py-2 rounded-lg bg-accent text-white text-[13px] font-medium hover:bg-accent/80 transition-colors disabled:opacity-50"
            >
              {submitting ? 'Saving…' : editingId ? 'Save' : 'Create'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Main view
// ---------------------------------------------------------------------------

interface HabitsViewProps {
  habits: Habit[];
  onRefresh: () => void;
  clockManager?: unknown;
  keywords?: TodoKeywords | null;
}

export function HabitsView({ habits, onRefresh }: HabitsViewProps) {
  const isMobile = typeof window !== 'undefined' && window.innerWidth < 768;
  const today = new Date();

  const [formOpen, setFormOpen] = useState(false);
  const [editingHabit, setEditingHabit] = useState<Habit | null>(null);
  const [submitting, setSubmitting] = useState(false);

  // Summary stats
  const doneToday = habits.filter(h => habitStatsFromDB(h, today).doneThisPeriod).length;
  const bestStreak = habits.reduce((best, h) => {
    const s = habitStatsFromDB(h, today).currentStreak;
    return s > best ? s : best;
  }, 0);
  // 30-day rate: cells are always 14 periods wide; use all cells across habits
  const allCells = habits.flatMap(h => habitStatsFromDB(h, today).cells);
  const rate = allCells.length > 0
    ? Math.round(allCells.filter(c => c === 'done').length / allCells.length * 100)
    : 0;

  // Sort by current streak desc, then alphabetically
  const sorted = [...habits].sort((a, b) => {
    const sA = habitStatsFromDB(a, today).currentStreak;
    const sB = habitStatsFromDB(b, today).currentStreak;
    if (sB !== sA) return sB - sA;
    return a.title.localeCompare(b.title);
  });

  const handleCreate = async (body: CreateHabitBody) => {
    setSubmitting(true);
    try {
      await createHabit(body);
      setFormOpen(false);
      onRefresh();
    } catch (err) {
      console.error('Failed to create habit:', err);
    } finally {
      setSubmitting(false);
    }
  };

  const handleUpdate = async (body: CreateHabitBody) => {
    if (!editingHabit) return;
    setSubmitting(true);
    try {
      await updateHabit(editingHabit.id, body);
      setEditingHabit(null);
      onRefresh();
    } catch (err) {
      console.error('Failed to update habit:', err);
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div className="flex flex-col pb-8 pt-2">
      {/* Summary chips + New Habit button */}
      <div className="flex items-center justify-between px-3 md:px-6 pt-1 pb-3 gap-3">
        {habits.length > 0 && (
          <div className="flex items-center gap-2 flex-wrap">
            <span className="text-[11px] px-2 py-1 rounded-full bg-things-surface border border-things-border-subtle text-text-secondary tabular-nums">
              {doneToday}/{habits.length} today
            </span>
            {bestStreak > 0 && (
              <span className="text-[11px] px-2 py-1 rounded-full bg-things-surface border border-things-border-subtle text-done-green tabular-nums">
                {bestStreak} streak
              </span>
            )}
            <span className="text-[11px] px-2 py-1 rounded-full bg-things-surface border border-things-border-subtle text-text-secondary tabular-nums">
              {rate}% rate
            </span>
          </div>
        )}
        <div className="ml-auto">
          <button
            onClick={() => setFormOpen(true)}
            className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-accent/10 text-accent border border-accent/20 text-[13px] font-medium hover:bg-accent/20 transition-colors"
          >
            <Plus size={14} weight="bold" />
            New Habit
          </button>
        </div>
      </div>

      {/* Column headers */}
      {habits.length > 0 && (
        <div className="flex items-center gap-3 px-3 md:px-5 pb-1 border-b border-things-border-subtle/40">
          <span className="flex-1 text-[9px] uppercase tracking-widest text-text-tertiary font-semibold">Habit</span>
          <span className="flex-shrink-0 text-[9px] uppercase tracking-widest text-text-tertiary font-semibold">
            {isMobile ? '7-period' : '14-period'}
          </span>
          <div className="flex items-center gap-3 flex-shrink-0 text-[9px] uppercase tracking-widest text-text-tertiary font-semibold">
            <span className="min-w-[28px] text-center">now</span>
            <span className="hidden sm:block min-w-[28px] text-center">best</span>
            <span className="min-w-[32px] text-center">%</span>
          </div>
        </div>
      )}

      {habits.length === 0 ? (
        <div className="flex flex-col items-center justify-center h-48 gap-2 text-text-tertiary text-sm px-4 text-center">
          <ArrowsClockwise size={32} weight="regular" className="opacity-40" />
          <span className="font-medium text-text-secondary">No habits yet</span>
          <span className="text-[12px] max-w-[320px]">
            Create your first habit with the "New Habit" button above.
          </span>
        </div>
      ) : (
        <div className="task-card">
          {sorted.map(habit => (
            <HabitDashboardRow
              key={habit.id}
              habit={habit}
              isMobile={isMobile}
              onEdit={h => setEditingHabit(h)}
            />
          ))}
        </div>
      )}

      {formOpen && (
        <HabitFormModal
          initial={defaultFormState()}
          onSubmit={handleCreate}
          onClose={() => setFormOpen(false)}
          submitting={submitting}
        />
      )}

      {editingHabit && (
        <HabitFormModal
          initial={formStateFromHabit(editingHabit)}
          onSubmit={handleUpdate}
          onClose={() => setEditingHabit(null)}
          submitting={submitting}
          editingId={editingHabit.id}
        />
      )}
    </div>
  );
}
