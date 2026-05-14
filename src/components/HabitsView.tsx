/**
 * Habits dashboard — web port of MacHabitsView.swift.
 *
 * Groups `:STYLE: habit` headings by cadence (Today / This Week / This Month /
 * This Year / Other). Each row shows: checkbox, title, 14-cell strip, streak,
 * and completion %. Done rows fade to 40% opacity so pending rows command
 * attention.
 */

import { useState } from 'react';
import type { OrgTask, TodoKeywords } from '../types';
import type { ClockStatus } from '../api/tasks';
import { updateTodoState } from '../api/tasks';
import {
  isHabit,
  habitStats,
  habitBuckets,
} from '../utils/habits';
import type { HabitBucket, CellState } from '../utils/habits';
import { renderInline } from './NotesRenderer';

// ---------------------------------------------------------------------------
// Props
// ---------------------------------------------------------------------------

interface HabitsViewProps {
  tasks: OrgTask[];
  keywords: TodoKeywords | null;
  isDoneState: (state: string | undefined) => boolean;
  clockStatus: ClockStatus;
  allTags: string[];
  onRefresh: () => void;
  onRefreshClock: () => void;
}

// ---------------------------------------------------------------------------
// Strip cell
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

// ---------------------------------------------------------------------------
// Strip component — 14 cells on desktop, 7 on mobile
// ---------------------------------------------------------------------------

function HabitStrip({
  cells,
  isMobile,
}: {
  cells: CellState[];
  isMobile: boolean;
}) {
  // On mobile show only the last 7 cells (the most recent periods)
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
// Habit row
// ---------------------------------------------------------------------------

function HabitRow({
  habit,
  onRefresh,
  isMobile,
}: {
  habit: OrgTask;
  onRefresh: () => void;
  isMobile: boolean;
}) {
  const today = new Date();
  const stats = habitStats(habit, today);
  const { doneThisPeriod, currentStreak, longestStreak, cells, completionRate, cadence } = stats;

  const [toggling, setToggling] = useState(false);

  const handleToggle = async () => {
    if (toggling) return;
    setToggling(true);
    try {
      // Mark DONE fires the repeater in Emacs (org-habit advances SCHEDULED).
      // SSE event will refresh the task list automatically.
      await updateTodoState(habit, 'DONE');
      onRefresh();
    } catch (err) {
      console.error('Failed to toggle habit:', err);
    } finally {
      setToggling(false);
    }
  };

  const streakLabel = `${currentStreak}${cadence.label}`;
  const bestLabel = `${longestStreak}${cadence.label}`;

  return (
    <div
      className={`flex items-center gap-2 md:gap-3 px-3 md:px-4 py-2.5 rounded-lg border border-things-border/50 bg-things-surface/40 transition-opacity ${
        doneThisPeriod ? 'opacity-40' : 'opacity-100'
      }`}
    >
      {/* Checkbox */}
      <button
        onClick={handleToggle}
        disabled={toggling}
        title={doneThisPeriod ? 'Done this period' : 'Mark done'}
        className="flex-shrink-0 w-5 h-5 rounded-full flex items-center justify-center transition-colors"
        style={{ minWidth: '1.25rem' }}
      >
        {doneThisPeriod ? (
          <span className="w-5 h-5 rounded-full bg-done-green flex items-center justify-center">
            <svg width="10" height="8" viewBox="0 0 10 8" fill="none">
              <path
                d="M1 4L3.5 6.5L9 1"
                stroke="white"
                strokeWidth="1.8"
                strokeLinecap="round"
                strokeLinejoin="round"
              />
            </svg>
          </span>
        ) : (
          <span className="w-5 h-5 rounded-full border-[1.5px] border-text-tertiary/50" />
        )}
      </button>

      {/* Title */}
      <span
        className={`flex-1 min-w-0 text-[13px] font-medium leading-snug truncate ${
          doneThisPeriod
            ? 'text-text-tertiary line-through'
            : 'text-text-primary'
        }`}
        title={habit.title}
      >
        {renderInline(habit.title)}
      </span>

      {/* Strip — hidden on very small screens, visible at sm+ */}
      <div className="hidden sm:flex flex-shrink-0">
        <HabitStrip cells={cells} isMobile={isMobile} />
      </div>

      {/* Streak */}
      <div className="flex-shrink-0 flex flex-col items-end gap-px">
        <span
          className={`text-[12px] font-semibold tabular-nums font-mono ${
            currentStreak > 0 ? 'text-done-green' : 'text-text-tertiary'
          }`}
          title={`Current streak: ${streakLabel}`}
        >
          {currentStreak > 0 ? '🔥' : ''}{streakLabel}
        </span>
        <span
          className="text-[9px] text-text-tertiary font-mono tabular-nums"
          title={`Best streak: ${bestLabel}`}
        >
          best {bestLabel}
        </span>
      </div>

      {/* Percent */}
      <span
        className="flex-shrink-0 text-[11px] text-text-tertiary font-mono tabular-nums w-9 text-right"
        title="Completion rate over last 14 periods"
      >
        {Math.round(completionRate * 100)}%
      </span>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Bucket section header
// ---------------------------------------------------------------------------

function BucketHeader({
  title,
  doneCount,
  total,
}: {
  title: string;
  doneCount: number;
  total: number;
}) {
  const allDone = doneCount === total && total > 0;
  return (
    <div className="flex items-center gap-2 px-1 pb-1 pt-3">
      <span className="text-[11px] font-bold uppercase tracking-[0.06em] text-text-primary">
        {title}
      </span>
      {allDone ? (
        <span className="flex items-center gap-1 text-[10px] font-medium text-done-green">
          <span>&#x2713;</span>
          <span className="tabular-nums">
            {total} / {total}
          </span>
        </span>
      ) : (
        <span
          className={`text-[10px] font-medium tabular-nums ${
            doneCount > 0 ? 'text-done-green' : 'text-text-tertiary'
          }`}
        >
          {doneCount} / {total} done
        </span>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Bucket section
// ---------------------------------------------------------------------------

function HabitBucketSection({
  bucket,
  onRefresh,
  isMobile,
}: {
  bucket: HabitBucket;
  onRefresh: () => void;
  isMobile: boolean;
}) {
  return (
    <div>
      <BucketHeader
        title={bucket.title}
        doneCount={bucket.doneCount}
        total={bucket.habits.length}
      />
      <div className="flex flex-col gap-1.5">
        {bucket.habits.map(habit => (
          <HabitRow
            key={habit.id}
            habit={habit}
            onRefresh={onRefresh}
            isMobile={isMobile}
          />
        ))}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Main view
// ---------------------------------------------------------------------------

export function HabitsView({
  tasks,
  onRefresh,
}: HabitsViewProps) {
  // Detect mobile viewport (mirrors App.tsx breakpoint at 768px)
  const isMobile = typeof window !== 'undefined' && window.innerWidth < 768;

  const habits = tasks.filter(isHabit);
  const today = new Date();
  const buckets = habitBuckets(habits, today);

  if (habits.length === 0) {
    return (
      <div className="flex flex-col items-center justify-center h-48 gap-2 text-text-tertiary text-sm px-4 text-center">
        <span className="text-3xl opacity-40">🔁</span>
        <span className="font-medium text-text-secondary">No habits yet</span>
        <span className="text-[12px] max-w-[320px]">
          Add{' '}
          <code className="bg-things-surface px-1 rounded text-accent text-[11px]">
            :STYLE: habit
          </code>{' '}
          to a repeating task in Emacs.
        </span>
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-4 px-3 md:px-6 pb-8 pt-2">
      {buckets.map(bucket => (
        <HabitBucketSection
          key={bucket.title}
          bucket={bucket}
          onRefresh={onRefresh}
          isMobile={isMobile}
        />
      ))}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Inline habit group for the Today view
// ---------------------------------------------------------------------------

/**
 * Compact habit group prepended to the Today list when
 * `settings.showHabitsInToday` is true. Renders all habit rows without
 * cadence bucket headers — only a single "Habits" section header.
 */
export function TodayHabitsGroup({
  tasks,
  onRefresh,
  isMobile,
}: {
  tasks: OrgTask[];
  onRefresh: () => void;
  isMobile: boolean;
}) {
  const habits = tasks.filter(isHabit);
  if (habits.length === 0) return null;

  const today = new Date();
  // Sort: undone first, then alphabetical
  const sorted = [...habits].sort((a, b) => {
    const aDone = habitStats(a, today).doneThisPeriod;
    const bDone = habitStats(b, today).doneThisPeriod;
    if (aDone !== bDone) return aDone ? 1 : -1;
    return a.title.localeCompare(b.title);
  });
  const doneCount = sorted.filter(h => habitStats(h, today).doneThisPeriod).length;

  return (
    <div className="px-3 md:px-5 py-2">
      <BucketHeader title="Habits" doneCount={doneCount} total={sorted.length} />
      <div className="task-card flex flex-col gap-1.5">
        {sorted.map(habit => (
          <HabitRow
            key={habit.id}
            habit={habit}
            onRefresh={onRefresh}
            isMobile={isMobile}
          />
        ))}
      </div>
    </div>
  );
}
