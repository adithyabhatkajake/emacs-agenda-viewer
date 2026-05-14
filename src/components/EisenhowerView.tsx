/**
 * EisenhowerView — 2×2 matrix of tasks organised by urgency × importance.
 *
 * Importance: priority A or B.
 * Urgency: scheduled <= today OR deadline <= today + warningDays.
 *
 * Desktop: 2×2 CSS grid.
 * Mobile (<768 px): stacked accordion (each quadrant collapsible).
 *
 * Drag-to-reschedule: HTML5 drag-and-drop between quadrants.
 * Drop on a quadrant → set priority + scheduled appropriately.
 */

import { useState } from 'react';
import type { OrgTask, TodoKeywords } from '../types';
import type { ClockStatus } from '../api/tasks';
import { updatePriority, updateScheduled } from '../api/tasks';
import { TaskItem } from './TaskItem';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function todayStr(): string {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

function addDays(ymd: string, days: number): string {
  const [y, m, d] = ymd.split('-').map(Number);
  const date = new Date(y, m - 1, d + days);
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
}

function toOrgTimestamp(ymd: string): string {
  const [y, m, d] = ymd.split('-').map(Number);
  const date = new Date(y, m - 1, d);
  const weekdays = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  return `<${ymd} ${weekdays[date.getDay()]}>`;
}

/** Extract YYYY-MM-DD from an org raw timestamp string. */
function extractYMD(raw: string | undefined): string | null {
  if (!raw) return null;
  const m = raw.match(/(\d{4}-\d{2}-\d{2})/);
  return m ? m[1] : null;
}

/** True if the date string is today or in the past. */
function isUrgentDate(ymd: string): boolean {
  const today = todayStr();
  return ymd <= today;
}

/** True if the deadline date is within warningDays from today. */
function isUrgentDeadline(deadlineRaw: string | undefined, warningDays: number): boolean {
  const ymd = extractYMD(deadlineRaw);
  if (!ymd) return false;
  const cutoff = addDays(todayStr(), warningDays);
  return ymd <= cutoff;
}

function isImportant(task: OrgTask): boolean {
  return task.priority === 'A' || task.priority === 'B';
}

function isUrgent(task: OrgTask, warningDays: number): boolean {
  const schYmd = extractYMD(task.scheduled?.raw);
  if (schYmd && isUrgentDate(schYmd)) return true;
  if (isUrgentDeadline(task.deadline?.raw, warningDays)) return true;
  return false;
}

type Quadrant = 'do-first' | 'schedule' | 'delegate' | 'eliminate';

function classify(task: OrgTask, warningDays: number): Quadrant {
  const imp = isImportant(task);
  const urg = isUrgent(task, warningDays);
  if (imp && urg) return 'do-first';
  if (imp && !urg) return 'schedule';
  if (!imp && urg) return 'delegate';
  return 'eliminate';
}

// ---------------------------------------------------------------------------
// Drag-and-drop
// ---------------------------------------------------------------------------

const DRAG_KEY = 'eav-drag-task-id';

function startDrag(e: React.DragEvent, taskId: string) {
  e.dataTransfer.setData(DRAG_KEY, taskId);
  e.dataTransfer.effectAllowed = 'move';
}

async function applyDrop(
  quadrant: Quadrant,
  task: OrgTask,
  onRefresh: () => void,
): Promise<void> {
  const today = todayStr();
  const nextWeek = addDays(today, 7);

  try {
    switch (quadrant) {
      case 'do-first':
        if (!isImportant(task)) await updatePriority(task, 'A');
        await updateScheduled(task, toOrgTimestamp(today));
        break;
      case 'schedule':
        if (!isImportant(task)) await updatePriority(task, 'A');
        await updateScheduled(task, toOrgTimestamp(nextWeek));
        break;
      case 'delegate':
        if (isImportant(task)) await updatePriority(task, 'D');
        await updateScheduled(task, toOrgTimestamp(today));
        break;
      case 'eliminate':
        if (isImportant(task)) await updatePriority(task, 'D');
        // Clear scheduled — send empty string; the server interprets "" as clear
        await updateScheduled(task, '');
        break;
    }
    onRefresh();
  } catch (err) {
    console.error('Eisenhower drop failed:', err);
  }
}

// ---------------------------------------------------------------------------
// Quadrant metadata
// ---------------------------------------------------------------------------

interface QuadrantMeta {
  id: Quadrant;
  label: string;
  subtitle: string;
  accentClass: string;       // Tailwind ring/border color
  bgClass: string;           // tinted background
  labelColorClass: string;   // text color for the label
}

const QUADRANTS: QuadrantMeta[] = [
  {
    id: 'do-first',
    label: 'Do First',
    subtitle: 'Urgent & Important',
    accentClass: 'border-priority-a/40',
    bgClass: 'bg-priority-a/5',
    labelColorClass: 'text-priority-a',
  },
  {
    id: 'schedule',
    label: 'Schedule',
    subtitle: 'Important, Not Urgent',
    accentClass: 'border-accent/40',
    bgClass: 'bg-accent/5',
    labelColorClass: 'text-accent',
  },
  {
    id: 'delegate',
    label: 'Delegate',
    subtitle: 'Urgent, Not Important',
    accentClass: 'border-priority-b/40',
    bgClass: 'bg-priority-b/5',
    labelColorClass: 'text-priority-b',
  },
  {
    id: 'eliminate',
    label: 'Eliminate',
    subtitle: 'Neither',
    accentClass: 'border-things-border',
    bgClass: 'bg-things-surface/20',
    labelColorClass: 'text-text-tertiary',
  },
];

// ---------------------------------------------------------------------------
// QuadrantCell
// ---------------------------------------------------------------------------

interface QuadrantCellProps {
  meta: QuadrantMeta;
  tasks: OrgTask[];
  allTasks: OrgTask[];      // full list for drag-source lookup
  keywords: TodoKeywords | null;
  isDoneState: (s: string | undefined) => boolean;
  clockStatus: ClockStatus;
  allTags: string[];
  onRefresh: () => void;
  onRefreshClock: () => void;
  isMobile: boolean;
  warningDays: number;
}

function QuadrantCell({
  meta, tasks, allTasks, keywords, isDoneState, clockStatus, allTags,
  onRefresh, onRefreshClock, isMobile, warningDays,
}: QuadrantCellProps) {
  const [collapsed, setCollapsed] = useState(false);
  const [dragOver, setDragOver] = useState(false);

  const handleDragOver = (e: React.DragEvent) => {
    e.preventDefault();
    e.dataTransfer.dropEffect = 'move';
    setDragOver(true);
  };

  const handleDragLeave = () => setDragOver(false);

  const handleDrop = async (e: React.DragEvent) => {
    e.preventDefault();
    setDragOver(false);
    const id = e.dataTransfer.getData(DRAG_KEY);
    if (!id) return;
    const task = allTasks.find(t => t.id === id);
    if (!task) return;
    await applyDrop(meta.id, task, onRefresh);
  };

  const header = (
    <div
      className={`flex items-center gap-2 px-3 py-2 ${meta.bgClass} border-b ${meta.accentClass}`}
    >
      {isMobile && (
        <button
          onClick={() => setCollapsed(c => !c)}
          className="text-[10px] text-text-tertiary transition-transform"
          aria-expanded={!collapsed}
        >
          <span className={`inline-block transition-transform ${collapsed ? '' : 'rotate-90'}`}>{'▶'}</span>
        </button>
      )}
      <span className={`text-[12px] font-semibold ${meta.labelColorClass}`}>{meta.label}</span>
      <span className="text-[10px] text-text-tertiary">{meta.subtitle}</span>
      <span className="ml-auto text-[10px] text-text-tertiary tabular-nums">{tasks.length}</span>
    </div>
  );

  return (
    <div
      className={`flex flex-col border rounded-lg overflow-hidden transition-colors ${meta.accentClass} ${
        dragOver ? 'ring-2 ring-accent/60 bg-accent/5' : ''
      }`}
      onDragOver={handleDragOver}
      onDragLeave={handleDragLeave}
      onDrop={handleDrop}
    >
      {header}
      {(!isMobile || !collapsed) && (
        <div className="flex-1 overflow-y-auto max-h-[360px] md:max-h-none">
          {tasks.length === 0 ? (
            <div className="flex items-center justify-center h-16 text-[12px] text-text-tertiary/50">
              Nothing here.
            </div>
          ) : (
            tasks.map(task => (
              <div
                key={task.id}
                draggable
                onDragStart={(e) => startDrag(e, task.id)}
                className="cursor-grab active:cursor-grabbing"
              >
                <TaskItem
                  task={task}
                  keywords={keywords}
                  isDoneState={isDoneState}
                  clockStatus={clockStatus}
                  allTags={allTags}
                  onRefresh={onRefresh}
                  onRefreshClock={onRefreshClock}
                />
              </div>
            ))
          )}
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// EisenhowerView (public)
// ---------------------------------------------------------------------------

interface EisenhowerViewProps {
  tasks: OrgTask[];
  keywords: TodoKeywords | null;
  isDoneState: (state: string | undefined) => boolean;
  clockStatus: ClockStatus;
  allTags: string[];
  onRefresh: () => void;
  onRefreshClock: () => void;
  warningDays: number;
}

export function EisenhowerView({
  tasks, keywords, isDoneState, clockStatus, allTags, onRefresh, onRefreshClock, warningDays,
}: EisenhowerViewProps) {
  const isMobile = window.innerWidth < 768;

  // Only include tasks with a todoState (active tasks only); exclude done
  const activeTasks = tasks.filter(t => t.todoState && !isDoneState(t.todoState));

  const grouped = new Map<Quadrant, OrgTask[]>([
    ['do-first', []],
    ['schedule', []],
    ['delegate', []],
    ['eliminate', []],
  ]);

  for (const task of activeTasks) {
    grouped.get(classify(task, warningDays))!.push(task);
  }

  if (isMobile) {
    // Stacked 1×4 on mobile
    return (
      <div className="flex flex-col gap-2 p-3">
        {QUADRANTS.map(meta => (
          <QuadrantCell
            key={meta.id}
            meta={meta}
            tasks={grouped.get(meta.id)!}
            allTasks={activeTasks}
            keywords={keywords}
            isDoneState={isDoneState}
            clockStatus={clockStatus}
            allTags={allTags}
            onRefresh={onRefresh}
            onRefreshClock={onRefreshClock}
            isMobile
            warningDays={warningDays}
          />
        ))}
      </div>
    );
  }

  // 2×2 grid on desktop — equal height rows via grid-rows
  return (
    <div className="grid grid-cols-2 gap-2 p-4 h-full" style={{ gridTemplateRows: '1fr 1fr' }}>
      {QUADRANTS.map(meta => (
        <QuadrantCell
          key={meta.id}
          meta={meta}
          tasks={grouped.get(meta.id)!}
          allTasks={activeTasks}
          keywords={keywords}
          isDoneState={isDoneState}
          clockStatus={clockStatus}
          allTags={allTags}
          onRefresh={onRefresh}
          onRefreshClock={onRefreshClock}
          isMobile={false}
          warningDays={warningDays}
        />
      ))}
    </div>
  );
}
