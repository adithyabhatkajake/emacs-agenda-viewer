/**
 * CalendarView — Month grid with scheduled-task counts per day.
 *
 * - Header: month + year, prev/next arrows, Today jump.
 * - Each cell: date number + up to 3 chip badges; "+N more" for overflow.
 * - Click a day → popover showing that day's tasks as TaskItem rows.
 * - Drop a task on a day cell → updateScheduled to that date.
 *
 * Week starts on Sunday (matches DatePicker.tsx's MiniCalendar).
 * Mobile: full-screen month grid, prev/next arrows only (no swipe required).
 */

import { useState, useMemo, useRef, useEffect } from 'react';
import { createPortal } from 'react-dom';
import type { OrgTask, TodoKeywords } from '../types';
import type { ClockStatus } from '../api/tasks';
import { updateScheduled } from '../api/tasks';
import { TaskItem } from './TaskItem';
import { renderInline } from './NotesRenderer';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function todayStr(): string {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

function toOrgTimestamp(ymd: string): string {
  const [y, m, d] = ymd.split('-').map(Number);
  const date = new Date(y, m - 1, d);
  const weekdays = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  return `<${ymd} ${weekdays[date.getDay()]}>`;
}

function extractYMD(raw: string | undefined): string | null {
  if (!raw) return null;
  const m = raw.match(/(\d{4}-\d{2}-\d{2})/);
  return m ? m[1] : null;
}

/** Build the 6-row (42-cell) grid for a given year+month. */
function buildCalGrid(year: number, month: number): Array<{ ymd: string; day: number; inMonth: boolean }> {
  const first = new Date(year, month, 1);
  const startDay = first.getDay(); // 0=Sun
  const daysInMonth = new Date(year, month + 1, 0).getDate();
  const prevDaysTotal = new Date(year, month, 0).getDate();

  const cells: Array<{ ymd: string; day: number; inMonth: boolean }> = [];

  // Leading days from previous month
  for (let i = startDay - 1; i >= 0; i--) {
    const d = prevDaysTotal - i;
    const m2 = month === 0 ? 12 : month;
    const y2 = month === 0 ? year - 1 : year;
    cells.push({ ymd: `${y2}-${String(m2).padStart(2, '0')}-${String(d).padStart(2, '0')}`, day: d, inMonth: false });
  }

  // Days in this month
  for (let d = 1; d <= daysInMonth; d++) {
    cells.push({ ymd: `${year}-${String(month + 1).padStart(2, '0')}-${String(d).padStart(2, '0')}`, day: d, inMonth: true });
  }

  // Trailing days from next month
  const trailing = 42 - cells.length;
  for (let d = 1; d <= trailing; d++) {
    const m2 = month + 2 > 12 ? 1 : month + 2;
    const y2 = month + 2 > 12 ? year + 1 : year;
    cells.push({ ymd: `${y2}-${String(m2).padStart(2, '0')}-${String(d).padStart(2, '0')}`, day: d, inMonth: false });
  }

  return cells;
}

// ---------------------------------------------------------------------------
// Drag-and-drop
// ---------------------------------------------------------------------------

const DRAG_KEY = 'eav-drag-task-id';

// ---------------------------------------------------------------------------
// Day popover
// ---------------------------------------------------------------------------

interface DayPopoverProps {
  ymd: string;
  tasks: OrgTask[];
  anchorRect: DOMRect;
  keywords: TodoKeywords | null;
  isDoneState: (s: string | undefined) => boolean;
  clockStatus: ClockStatus;
  allTags: string[];
  onRefresh: () => void;
  onRefreshClock: () => void;
  onClose: () => void;
}

function DayPopover({
  ymd, tasks, anchorRect, keywords, isDoneState, clockStatus, allTags,
  onRefresh, onRefreshClock, onClose,
}: DayPopoverProps) {
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const handler = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) onClose();
    };
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose(); };
    const id = setTimeout(() => {
      document.addEventListener('mousedown', handler);
      document.addEventListener('keydown', onKey);
    }, 0);
    return () => {
      clearTimeout(id);
      document.removeEventListener('mousedown', handler);
      document.removeEventListener('keydown', onKey);
    };
  }, [onClose]);

  // Position: below and left-aligned to anchor, clamped to viewport
  const popW = 320;
  const popMaxH = 400;
  let top = anchorRect.bottom + 6;
  let left = anchorRect.left;
  if (left + popW > window.innerWidth - 8) left = window.innerWidth - popW - 8;
  if (left < 8) left = 8;
  if (top + popMaxH > window.innerHeight - 8) top = anchorRect.top - Math.min(popMaxH, top + popMaxH - window.innerHeight + 8) - 6;

  const [y, m, d] = ymd.split('-').map(Number);
  const date = new Date(y, m - 1, d);
  const label = date.toLocaleDateString('en-US', { weekday: 'long', month: 'long', day: 'numeric' });

  return createPortal(
    <div
      ref={ref}
      className="fixed z-[9999] bg-things-surface/95 rounded-xl shadow-2xl shadow-black/50 border border-things-border overflow-hidden"
      style={{ top, left, width: popW, maxHeight: popMaxH }}
    >
      <div className="px-3 py-2 border-b border-things-border/60 flex items-center justify-between">
        <span className="text-[12px] font-semibold text-text-primary">{label}</span>
        <button onClick={onClose} className="text-text-tertiary hover:text-text-secondary text-[14px] leading-none">{'×'}</button>
      </div>
      <div className="overflow-y-auto" style={{ maxHeight: popMaxH - 40 }}>
        {tasks.length === 0 ? (
          <div className="flex items-center justify-center h-16 text-[12px] text-text-tertiary">No tasks scheduled.</div>
        ) : (
          tasks.map(task => (
            <TaskItem
              key={task.id}
              task={task}
              keywords={keywords}
              isDoneState={isDoneState}
              clockStatus={clockStatus}
              allTags={allTags}
              onRefresh={() => { onRefresh(); onClose(); }}
              onRefreshClock={onRefreshClock}
            />
          ))
        )}
      </div>
    </div>,
    document.body
  );
}

// ---------------------------------------------------------------------------
// CalendarView (public)
// ---------------------------------------------------------------------------

interface CalendarViewProps {
  tasks: OrgTask[];
  keywords: TodoKeywords | null;
  isDoneState: (state: string | undefined) => boolean;
  clockStatus: ClockStatus;
  allTags: string[];
  onRefresh: () => void;
  onRefreshClock: () => void;
}

export function CalendarView({
  tasks, keywords, isDoneState, clockStatus, allTags, onRefresh, onRefreshClock,
}: CalendarViewProps) {
  const today = todayStr();
  const todayDate = new Date();

  const [viewYear, setViewYear] = useState(todayDate.getFullYear());
  const [viewMonth, setViewMonth] = useState(todayDate.getMonth()); // 0-based
  const [popover, setPopover] = useState<{ ymd: string; rect: DOMRect } | null>(null);
  const [dragOver, setDragOver] = useState<string | null>(null); // currently hovered ymd

  const cells = useMemo(() => buildCalGrid(viewYear, viewMonth), [viewYear, viewMonth]);

  // Map ymd → tasks scheduled that day
  const tasksByDay = useMemo(() => {
    const map = new Map<string, OrgTask[]>();
    for (const task of tasks) {
      const ymd = extractYMD(task.scheduled?.raw);
      if (!ymd) continue;
      const bucket = map.get(ymd) ?? [];
      bucket.push(task);
      map.set(ymd, bucket);
    }
    return map;
  }, [tasks]);

  const popoverTasks = popover ? (tasksByDay.get(popover.ymd) ?? []) : [];

  const prevMonth = () => {
    if (viewMonth === 0) { setViewYear(y => y - 1); setViewMonth(11); }
    else setViewMonth(m => m - 1);
  };
  const nextMonth = () => {
    if (viewMonth === 11) { setViewYear(y => y + 1); setViewMonth(0); }
    else setViewMonth(m => m + 1);
  };
  const jumpToday = () => {
    setViewYear(todayDate.getFullYear());
    setViewMonth(todayDate.getMonth());
  };

  const monthLabel = new Date(viewYear, viewMonth).toLocaleDateString('en-US', { month: 'long', year: 'numeric' });

  const handleCellClick = (ymd: string, e: React.MouseEvent) => {
    const rect = (e.currentTarget as HTMLElement).getBoundingClientRect();
    if (popover?.ymd === ymd) { setPopover(null); return; }
    setPopover({ ymd, rect });
  };

  const handleDragOver = (ymd: string, e: React.DragEvent) => {
    e.preventDefault();
    e.dataTransfer.dropEffect = 'move';
    setDragOver(ymd);
  };

  const handleDrop = async (ymd: string, e: React.DragEvent) => {
    e.preventDefault();
    setDragOver(null);
    const id = e.dataTransfer.getData(DRAG_KEY);
    if (!id) return;
    const task = tasks.find(t => t.id === id);
    if (!task) return;
    try {
      await updateScheduled(task, toOrgTimestamp(ymd));
      onRefresh();
    } catch (err) {
      console.error('Calendar drop failed:', err);
    }
  };

  const CHIP_LIMIT = 3;

  return (
    <div className="flex flex-col h-full">
      {/* Header */}
      <div className="flex items-center gap-3 px-4 py-3 border-b border-things-border/60 flex-shrink-0">
        <span className="text-[15px] font-semibold text-text-primary flex-1">{monthLabel}</span>
        <button
          onClick={prevMonth}
          className="w-7 h-7 flex items-center justify-center rounded-md text-text-secondary hover:bg-things-sidebar-hover text-[14px] transition-colors"
          aria-label="Previous month"
        >{'‹'}</button>
        <button
          onClick={jumpToday}
          className="px-2.5 py-1 text-[11px] font-medium text-text-secondary border border-things-border rounded-md hover:bg-things-sidebar-hover transition-colors"
        >Today</button>
        <button
          onClick={nextMonth}
          className="w-7 h-7 flex items-center justify-center rounded-md text-text-secondary hover:bg-things-sidebar-hover text-[14px] transition-colors"
          aria-label="Next month"
        >{'›'}</button>
      </div>

      {/* Day-of-week header */}
      <div className="grid grid-cols-7 border-b border-things-border/40 flex-shrink-0">
        {['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'].map(day => (
          <div key={day} className="text-center py-1.5 text-[9px] font-semibold text-text-tertiary uppercase tracking-wider">
            {day}
          </div>
        ))}
      </div>

      {/* Calendar grid */}
      <div className="flex-1 overflow-y-auto">
        <div className="grid grid-cols-7 h-full" style={{ gridTemplateRows: 'repeat(6, minmax(80px, 1fr))' }}>
          {cells.map(({ ymd, day, inMonth }) => {
            const dayTasks = tasksByDay.get(ymd) ?? [];
            const visible = dayTasks.slice(0, CHIP_LIMIT);
            const overflow = dayTasks.length - visible.length;
            const isToday = ymd === today;
            const isDragTarget = dragOver === ymd;

            return (
              <div
                key={ymd}
                onClick={(e) => handleCellClick(ymd, e)}
                onDragOver={(e) => handleDragOver(ymd, e)}
                onDragLeave={() => setDragOver(null)}
                onDrop={(e) => handleDrop(ymd, e)}
                className={`border-b border-r border-things-border/30 p-1 cursor-pointer transition-colors select-none
                  ${!inMonth ? 'bg-things-sidebar/30' : 'hover:bg-things-sidebar-hover/40'}
                  ${isDragTarget ? 'ring-2 ring-inset ring-accent/60 bg-accent/5' : ''}
                  ${popover?.ymd === ymd ? 'bg-things-sidebar-active/40' : ''}
                `}
              >
                {/* Date number */}
                <div className="flex justify-end mb-0.5">
                  <span
                    className={`text-[11px] font-medium tabular-nums w-5 h-5 flex items-center justify-center rounded-full
                      ${isToday ? 'bg-accent text-white font-bold' : inMonth ? 'text-text-primary' : 'text-text-tertiary/40'}
                    `}
                  >
                    {day}
                  </span>
                </div>

                {/* Task chips */}
                <div className="flex flex-col gap-0.5">
                  {visible.map(task => (
                    <div
                      key={task.id}
                      className="flex items-center gap-1 px-1 py-0.5 rounded bg-accent/10 border border-accent/15 truncate"
                      title={task.title}
                    >
                      {task.priority && (
                        <span className={`text-[8px] font-bold flex-shrink-0 ${
                          task.priority === 'A' ? 'text-priority-a' :
                          task.priority === 'B' ? 'text-priority-b' : 'text-text-tertiary'
                        }`}>{task.priority}</span>
                      )}
                      <span className="text-[9px] text-text-secondary truncate leading-tight">
                        {renderInline(task.title)}
                      </span>
                    </div>
                  ))}
                  {overflow > 0 && (
                    <span className="text-[9px] text-text-tertiary px-1">+{overflow} more</span>
                  )}
                </div>
              </div>
            );
          })}
        </div>
      </div>

      {/* Day popover */}
      {popover && (
        <DayPopover
          ymd={popover.ymd}
          tasks={popoverTasks}
          anchorRect={popover.rect}
          keywords={keywords}
          isDoneState={isDoneState}
          clockStatus={clockStatus}
          allTags={allTags}
          onRefresh={onRefresh}
          onRefreshClock={onRefreshClock}
          onClose={() => setPopover(null)}
        />
      )}
    </div>
  );
}
