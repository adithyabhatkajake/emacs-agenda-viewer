import { useMemo, useState, useEffect, useRef } from 'react';
import { createPortal } from 'react-dom';
import { Check, PushPin, CaretRight, ArrowsClockwise, Fire, DotsThree, Trash, PencilSimple, X, CalendarBlank, Play, Stop } from '@phosphor-icons/react';
import type { OrgTask, AgendaEntry, ViewFilter, TodoKeywords, Habit } from '../types';
import { TaskItem } from './TaskItem';
import { renderInline, NotesRenderer } from './NotesRenderer';
import { type ClockStatus, type CreateHabitBody, loadSettings, completeHabit, uncompleteHabit, skipHabit, rescheduleHabit, updateHabit, deleteHabit, updateScheduled, todayYMD } from '../api/tasks';
import type { ClockManager } from '../hooks/useClockManager';
import { HabitsView, HabitFormModal, formStateFromHabit } from './HabitsView';
import { isHabit, habitStatsFromDB, habitDisplayDate, compactCadenceInterval, habitRelativeDateLabel } from '../utils/habits';
import { buildTodayItems } from '../utils/today';
import { EisenhowerView } from './EisenhowerView';
import { CalendarView } from './CalendarView';
import { toggleChecklistLine, countChecklistItems, resetChecklist } from '../utils/checklist';
import { resolvedStateColorToken } from './TodoStateMenu';

type DisplayItem = OrgTask | AgendaEntry;

interface TaskListProps {
  tasks: OrgTask[];
  habits: Habit[];
  todayEntries: AgendaEntry[];
  upcomingEntries: AgendaEntry[];
  filter: ViewFilter;
  keywords: TodoKeywords | null;
  isDoneState: (state: string | undefined) => boolean;
  clockStatus: ClockStatus;
  clockManager: ClockManager;
  allTags: string[];
  onRefresh: () => void;
  onRefreshHabits: () => void;
  onRefreshClock: () => void;
  onCapture?: () => void;
  sidebarOpen?: boolean;
  onToggleSidebar?: () => void;
  warningDays?: number;
}

type SortKey = 'priority' | 'state' | 'deadline' | 'category' | 'default';
type GroupKey = 'agenda' | 'priority' | 'category' | 'state';

function filterTitle(filter: ViewFilter): string {
  switch (filter.type) {
    case 'all': return 'All Tasks';
    case 'today': return 'Today';
    case 'upcoming': return 'Upcoming';
    case 'logbook': return 'Logbook';
    case 'inbox': return 'Inbox';
    case 'pinned': return 'My Day';
    case 'habits': return 'Habits';
    case 'eisenhower': return 'Eisenhower Matrix';
    case 'calendar': return 'Calendar';
    case 'file': return filter.path.split('/').pop()?.replace('.org', '') || 'File';
    case 'category': return filter.category;
    case 'tag': return `#${filter.tag}`;
  }
}

function priorityOrd(p: string | undefined): number {
  switch (p) { case 'A': return 0; case 'B': return 1; case 'C': return 2; case 'D': return 3; default: return 4; }
}

function priorityLabel(p: string | undefined): string {
  if (!p) return 'No Priority';
  return `Priority ${p}`;
}

function extractDateMs(raw: string | undefined): number {
  if (!raw) return Infinity;
  const m = raw.match(/(\d{4})-(\d{2})-(\d{2})/);
  if (!m) return Infinity;
  return new Date(parseInt(m[1]), parseInt(m[2]) - 1, parseInt(m[3])).getTime();
}

function extractTimeMinutes(item: DisplayItem): number {
  if ('timeOfDay' in item && (item as AgendaEntry).timeOfDay) {
    const t = (item as AgendaEntry).timeOfDay!;
    const m = t.match(/(\d{1,2}):(\d{2})/);
    if (m) return parseInt(m[1]) * 60 + parseInt(m[2]);
  }
  const raw = item.scheduled?.raw || item.deadline?.raw;
  if (raw) {
    const m = raw.match(/(\d{1,2}):(\d{2})/);
    if (m) return parseInt(m[1]) * 60 + parseInt(m[2]);
  }
  return Infinity;
}

function sortItems(items: DisplayItem[], sortKey: SortKey): DisplayItem[] {
  if (sortKey === 'default') return items;
  return [...items].sort((a, b) => {
    let cmp = 0;
    switch (sortKey) {
      case 'priority': cmp = priorityOrd(a.priority) - priorityOrd(b.priority); break;
      case 'state': cmp = (a.todoState || '').localeCompare(b.todoState || ''); break;
      case 'deadline': cmp = (extractDateMs(a.deadline?.raw) || extractDateMs(a.scheduled?.raw)) - (extractDateMs(b.deadline?.raw) || extractDateMs(b.scheduled?.raw)); break;
      case 'category': cmp = a.category.localeCompare(b.category); break;
    }
    if (cmp === 0) cmp = extractTimeMinutes(a) - extractTimeMinutes(b);
    return cmp;
  });
}

function isEventEntry(item: DisplayItem): boolean {
  if (!('agendaType' in item)) return false;
  const e = item as AgendaEntry;
  // org-agenda classifies calendar-style entries with one of these types:
  //   `timestamp' -- single active timestamp in body
  //   `block'     -- ranged `<a>--<b>' timestamp (e.g. Game Night)
  //   `sexp'      -- diary sexp entry
  // All three are events, not TODOs — route them to EventBanners.
  const eventTypes = ['timestamp', 'block', 'sexp'];
  return eventTypes.includes(e.agendaType) && !e.todoState;
}

function isDeadlineEntry(item: DisplayItem): boolean {
  if (!('agendaType' in item)) return !!item.deadline;
  const e = item as AgendaEntry;
  return e.agendaType === 'deadline' || e.agendaType === 'upcoming-deadline';
}

/** Get the group key for an item given a GroupKey dimension */
function getGroupValue(item: DisplayItem, gk: GroupKey): string {
  switch (gk) {
    case 'agenda':
      return isDeadlineEntry(item) ? 'Deadlines' : 'Scheduled';
    case 'priority':
      return item.priority || '_none';
    case 'category':
      return item.category || 'Uncategorized';
    case 'state':
      return item.todoState || '_none';
  }
}

/** Get display label for a group value */
function getGroupLabel(gk: GroupKey, value: string): string {
  if (gk === 'priority') return priorityLabel(value === '_none' ? undefined : value);
  if (gk === 'state' && value === '_none') return 'No State';
  return value;
}

/** Sort order for group values */
function groupSortOrder(gk: GroupKey, a: string, b: string): number {
  if (gk === 'priority') {
    const oa = a === '_none' ? 99 : priorityOrd(a);
    const ob = b === '_none' ? 99 : priorityOrd(b);
    return oa - ob;
  }
  if (gk === 'agenda') {
    // Scheduled before Deadlines
    const order: Record<string, number> = { 'Scheduled': 0, 'Deadlines': 1 };
    return (order[a] ?? 2) - (order[b] ?? 2);
  }
  if (a === '_none') return 1;
  if (b === '_none') return -1;
  return a.localeCompare(b);
}

interface GroupNode {
  label: string;
  depth: number;
  items: DisplayItem[];
  children: GroupNode[];
}

/** Recursively group items by multiple keys */
function multiGroup(items: DisplayItem[], keys: GroupKey[], depth: number = 0): GroupNode[] {
  if (keys.length === 0) {
    return [{ label: '', depth, items, children: [] }];
  }

  const [currentKey, ...restKeys] = keys;

  // Sort items by group key first so same-key items are contiguous
  const sorted = [...items].sort((a, b) =>
    groupSortOrder(currentKey, getGroupValue(a, currentKey), getGroupValue(b, currentKey))
  );

  const groups = new Map<string, DisplayItem[]>();
  const seen: string[] = [];

  for (const item of sorted) {
    const val = getGroupValue(item, currentKey);
    if (!groups.has(val)) { groups.set(val, []); seen.push(val); }
    groups.get(val)!.push(item);
  }

  return seen.map(val => {
    const groupItems = groups.get(val)!;
    const children = restKeys.length > 0 ? multiGroup(groupItems, restKeys, depth + 1) : [];
    return {
      label: getGroupLabel(currentKey, val),
      depth,
      items: restKeys.length > 0 ? [] : groupItems,
      children,
    };
  });
}

function formatDateHeader(dateStr: string) {
  const date = new Date(dateStr + 'T00:00:00');
  const dayNum = date.getDate();
  const weekday = date.toLocaleDateString('en-US', { weekday: 'long' });
  const month = date.toLocaleDateString('en-US', { month: 'long' });
  const today = new Date(); today.setHours(0, 0, 0, 0);
  const isToday = date.getTime() === today.getTime();
  const tomorrow = new Date(today); tomorrow.setDate(tomorrow.getDate() + 1);
  const isTomorrow = date.getTime() === tomorrow.getTime();
  return { dayNum, weekday, month, isToday, isTomorrow };
}

function GroupHeader({ label, depth, collapsed, onToggle, count }: { label: string; depth: number; collapsed: boolean; onToggle: () => void; count: number }) {
  const size = depth === 0 ? 'text-[11px]' : 'text-[10px]';
  const pad = depth === 0 ? 'pt-3 pb-1' : 'pt-2 pb-0.5';
  return (
    <button
      type="button"
      onClick={onToggle}
      aria-expanded={!collapsed}
      className={`w-full px-3 md:px-5 ${pad} flex items-center gap-2 select-none text-left hover:bg-things-sidebar-hover/40 transition-colors`}
    >
      <CaretRight size={11} weight="bold" className={`text-text-secondary transition-transform inline-block w-3 ${collapsed ? '' : 'rotate-90'}`} />
      <span className={`${size} font-semibold text-text-tertiary uppercase tracking-wider`}>
        {label}
      </span>
      <span className="text-[9px] text-text-tertiary/60 tabular-nums">{count}</span>
      <div className="flex-1 border-t border-things-border-subtle/30" />
    </button>
  );
}

function SectionHeader({ title, count }: { title: string; count: number }) {
  return (
    <div className="px-3 md:px-5 pt-4 pb-1.5 flex items-baseline gap-3 border-b border-things-border-subtle/40 sticky top-0 bg-things-bg/95 backdrop-blur-sm z-10">
      <span className="text-[14px] font-bold text-text-primary">{title}</span>
      <span className="text-[10px] text-text-tertiary tabular-nums">{count}</span>
    </div>
  );
}

/** Category → dot color, reused for event bar */
function eventBarColor(category: string | undefined): string {
  const name = (category || '').toLowerCase();
  if (!name) return 'rgb(var(--accent-teal))';
  if (name === 'inbox') return 'rgb(var(--dot-blue))';
  if (name === 'work') return 'rgb(var(--dot-purple))';
  if (name === 'personal') return 'rgb(var(--dot-green))';
  if (name === 'calendar') return 'rgb(var(--dot-orange))';
  if (name === 'meta') return 'rgb(var(--dot-gray))';
  const VARS = ['--dot-blue', '--dot-purple', '--dot-green', '--dot-orange', '--dot-yellow', '--dot-red', '--dot-gray'] as const;
  let h = 0;
  for (let i = 0; i < name.length; i++) h = (h * 31 + name.charCodeAt(i)) >>> 0;
  return `rgb(var(${VARS[h % VARS.length]}))`;
}

/** Dense Things-3-style event card: one tight line per event. */
function EventBanners({ events }: { events: DisplayItem[] }) {
  if (events.length === 0) return null;
  return (
    <div className="px-3 md:px-5 pt-2 pb-1">
      <div className="rounded-lg bg-things-surface border border-things-border-subtle/30 overflow-hidden px-3 py-1">
        {events.map(event => {
          const ae = 'agendaType' in event ? (event as AgendaEntry) : undefined;
          const timeLabel = ae?.timeOfDay || 'all-day';
          return (
            <div
              key={event.id + (ae?.agendaType ?? '')}
              className="flex items-center gap-2 py-[3px]"
            >
              <span
                aria-hidden
                className="flex-shrink-0 w-[3px] h-4 rounded-full"
                style={{ background: eventBarColor(event.category) }}
              />
              <span className="text-[12px] text-text-tertiary tabular-nums w-14 flex-shrink-0">
                {timeLabel}
              </span>
              <span className="text-[13px] text-text-secondary truncate flex-1">
                {renderInline(event.title)}
              </span>
            </div>
          );
        })}
      </div>
    </div>
  );
}

/** Count all leaf items in a GroupNode tree */
function countNodeItems(node: GroupNode): number {
  if (node.children.length > 0) return node.children.reduce((s, c) => s + countNodeItems(c), 0);
  return node.items.length;
}

const DRAG_KEY = 'eav-drag-task-id';

/** Recursively render grouped items with collapsible headers */
function RenderGroups({
  nodes, keywords, isDoneState, clockManager, allTags, onRefresh, onRefreshClock, makeDraggable,
}: {
  nodes: GroupNode[];
  keywords: TodoKeywords | null;
  isDoneState: (s: string | undefined) => boolean;
  clockManager: ClockManager;
  allTags: string[];
  onRefresh: () => void;
  onRefreshClock: () => void;
  /** When true, each leaf TaskItem is wrapped in a draggable div that sets DRAG_KEY. */
  makeDraggable?: boolean;
}) {
  const [collapsed, setCollapsed] = useState<Record<string, boolean>>(() => {
    try { return JSON.parse(localStorage.getItem('eav-collapsed-groups') || '{}'); }
    catch { return {}; }
  });
  const toggle = (key: string) => setCollapsed(prev => {
    const next = { ...prev, [key]: !prev[key] };
    try { localStorage.setItem('eav-collapsed-groups', JSON.stringify(next)); } catch { /* quota */ }
    return next;
  });

  return (
    <>
      {nodes.map(node => {
        const key = `${node.depth}-${node.label}`;
        const isCollapsed = !!collapsed[key];
        const count = countNodeItems(node);

        return (
          <div key={key}>
            {node.label && (
              <GroupHeader
                label={node.label}
                depth={node.depth}
                collapsed={isCollapsed}
                onToggle={() => toggle(key)}
                count={count}
              />
            )}
            {!isCollapsed && (
              node.children.length > 0 ? (
                <RenderGroups nodes={node.children} keywords={keywords} isDoneState={isDoneState} clockManager={clockManager} allTags={allTags} onRefresh={onRefresh} onRefreshClock={onRefreshClock} makeDraggable={makeDraggable} />
              ) : (
                node.items.map(task => {
                  const itemKey = task.id + ('agendaType' in task ? (task as AgendaEntry).agendaType : '');
                  const taskItem = (
                    <TaskItem
                      key={itemKey}
                      task={task}
                      keywords={keywords}
                      isDoneState={isDoneState}
                      clockManager={clockManager}
                      allTags={allTags}
                      onRefresh={onRefresh}
                      onRefreshClock={onRefreshClock}
                    />
                  );
                  if (!makeDraggable) return taskItem;
                  return (
                    <div
                      key={itemKey}
                      draggable
                      onDragStart={(e: React.DragEvent) => {
                        e.dataTransfer.setData(DRAG_KEY, task.id);
                        e.dataTransfer.effectAllowed = 'move';
                      }}
                      className="cursor-grab active:cursor-grabbing"
                    >
                      {taskItem}
                    </div>
                  );
                })
              )
            )}
          </div>
        );
      })}
    </>
  );
}

const ALL_GROUP_KEYS: GroupKey[] = ['agenda', 'priority', 'category', 'state'];

function TodaySchedulePicker({
  onConfirm,
  onClose,
}: {
  onConfirm: (date: string) => void;
  onClose: () => void;
}) {
  const today = new Date();
  const todayStr = `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, '0')}-${String(today.getDate()).padStart(2, '0')}`;
  const [date, setDate] = useState(todayStr);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    inputRef.current?.focus();
  }, []);

  return (
    <div className="px-2.5 py-2 flex flex-col gap-1.5">
      <span className="text-[11px] text-text-tertiary font-medium">Schedule for</span>
      <input
        ref={inputRef}
        type="date"
        value={date}
        onChange={e => setDate(e.target.value)}
        className="w-full bg-things-bg border border-things-border rounded px-2 py-1 text-[12px] text-text-primary outline-none focus:border-accent/50"
        onKeyDown={e => {
          if (e.key === 'Enter' && date) { e.preventDefault(); onConfirm(date); }
          if (e.key === 'Escape') { e.preventDefault(); onClose(); }
        }}
      />
      <div className="flex gap-1.5">
        <button
          onClick={onClose}
          className="flex-1 py-1 rounded text-[11px] text-text-tertiary hover:bg-things-sidebar-hover transition-colors"
        >
          Cancel
        </button>
        <button
          onClick={() => date && onConfirm(date)}
          disabled={!date}
          className="flex-1 py-1 rounded bg-accent/20 text-accent text-[11px] font-medium hover:bg-accent/30 transition-colors disabled:opacity-40"
        >
          Set
        </button>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// HabitStatePill + HabitPriorityBadge (shared with TodayHabitRow)
// ---------------------------------------------------------------------------

function HabitStatePill({ isDone, keywords }: { isDone: boolean; keywords: TodoKeywords | null }) {
  const state = isDone
    ? (keywords?.sequences[0]?.done[0] ?? 'DONE')
    : (keywords?.sequences[0]?.active[0] ?? 'TODO');
  const token = resolvedStateColorToken(state, isDone);
  const tokenClasses: Record<string, { bg: string; text: string; border: string }> = {
    'done-green':    { bg: 'bg-done-green/15',    text: 'text-done-green',    border: 'border-done-green/25' },
    'accent':        { bg: 'bg-accent/12',         text: 'text-accent',        border: 'border-accent/20' },
    'accent-teal':   { bg: 'bg-accent-teal/12',    text: 'text-accent-teal',   border: 'border-accent-teal/20' },
    'priority-b':    { bg: 'bg-priority-b/12',     text: 'text-priority-b',    border: 'border-priority-b/20' },
    'text-tertiary': { bg: 'bg-text-tertiary/12',  text: 'text-text-tertiary', border: 'border-text-tertiary/20' },
  };
  const cls = tokenClasses[token] ?? tokenClasses['accent'];
  return (
    <span className={`mt-px flex-shrink-0 rounded-md px-2 py-[3px] text-[10px] font-bold tracking-wide border ${cls.bg} ${cls.text} ${cls.border}`}>
      {state}
    </span>
  );
}

function HabitPriorityBadge({ priority }: { priority?: string }) {
  if (!priority) return null;
  const styles: Record<string, string> = {
    A: 'bg-priority-a/12 text-priority-a border-priority-a/25',
    B: 'bg-priority-b/12 text-priority-b border-priority-b/25',
    C: 'bg-accent/10 text-accent border-accent/20',
    D: 'bg-text-tertiary/10 text-text-tertiary border-text-tertiary/20',
  };
  const cls = styles[priority.toUpperCase()] ?? 'bg-things-surface text-text-tertiary border-things-border';
  return (
    <span className={`mt-px flex-shrink-0 rounded px-2 py-[3px] text-[10px] font-bold border ${cls}`}>
      {priority}
    </span>
  );
}

function TodayHabitRow({
  habit,
  onRefreshHabits,
  clockManager,
  keywords,
  onEdit,
}: {
  habit: Habit;
  onRefreshHabits: () => void;
  clockManager: ClockManager;
  keywords: TodoKeywords | null;
  onEdit?: (h: Habit) => void;
}) {
  const [toggling, setToggling] = useState(false);
  const [menuOpen, setMenuOpen] = useState(false);
  const [menuPhase, setMenuPhase] = useState<'main' | 'schedule'>('main');
  const [expanded, setExpanded] = useState(false);
  const [localNotes, setLocalNotes] = useState<string | null>(null);
  const [editingNotes, setEditingNotes] = useState(false);
  const [editText, setEditText] = useState('');
  const [savingNotes, setSavingNotes] = useState(false);
  const menuRef = useRef<HTMLDivElement>(null);

  const today = new Date();
  const stats = habitStatsFromDB(habit, today);
  const done = stats.doneThisPeriod;
  const isOverdue = habit.state === 'overdue';

  const effectiveNotes = localNotes ?? (habit.notes ?? '');
  const hasNotes = effectiveNotes.trim().length > 0;
  const hasChecklist = countChecklistItems(effectiveNotes) > 0;
  const isClocked = clockManager.isClocked(habit.id);

  const displayDate = habitDisplayDate(habit);
  const dueDateLabel = displayDate ? habitRelativeDateLabel(displayDate, today) : null;
  const recurrenceLabel = compactCadenceInterval(habit.cadence);

  // Close menu on outside click
  useEffect(() => {
    if (!menuOpen) return;
    const handler = (e: MouseEvent) => {
      if (menuRef.current && !menuRef.current.contains(e.target as Node)) {
        setMenuOpen(false);
        setMenuPhase('main');
      }
    };
    document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
  }, [menuOpen]);

  const handleToggle = async (e: React.MouseEvent) => {
    e.stopPropagation();
    if (toggling) return;
    setToggling(true);
    try {
      if (done) {
        const lastTs = habit.completions[0];
        if (lastTs) {
          await uncompleteHabit(habit.id, lastTs);
          onRefreshHabits();
        }
      } else {
        await completeHabit(habit.id);
        onRefreshHabits();
      }
    } catch (err) {
      console.error('Failed to toggle habit:', err);
    } finally {
      setToggling(false);
    }
  };

  const handleSkip = async () => {
    setMenuOpen(false);
    setMenuPhase('main');
    try {
      await skipHabit(habit.id);
      onRefreshHabits();
    } catch (err) {
      console.error('Failed to skip habit:', err);
    }
  };

  const handleReschedule = async (date: string) => {
    setMenuOpen(false);
    setMenuPhase('main');
    try {
      await rescheduleHabit(habit.id, date);
      onRefreshHabits();
    } catch (err) {
      console.error('Failed to reschedule habit:', err);
    }
  };

  const handleChecklistToggle = async (itemIndex: number) => {
    const current = effectiveNotes;
    const next = toggleChecklistLine(current, itemIndex);
    if (next === current) return;
    setLocalNotes(next);
    try {
      await updateHabit(habit.id, { notes: next });
      onRefreshHabits();
    } catch (err) {
      console.error('Failed to update checklist:', err);
      setLocalNotes(current);
    }
  };

  const handleNotesSave = async () => {
    if (savingNotes) return;
    setSavingNotes(true);
    try {
      await updateHabit(habit.id, { notes: editText });
      setLocalNotes(editText);
      setEditingNotes(false);
      onRefreshHabits();
    } catch (err) {
      console.error('Failed to save notes:', err);
    } finally {
      setSavingNotes(false);
    }
  };

  const handleDelete = async () => {
    setMenuOpen(false);
    if (!confirm(`Delete habit "${habit.title}"?`)) return;
    try {
      await deleteHabit(habit.id);
      onRefreshHabits();
    } catch (err) {
      console.error('Failed to delete habit:', err);
    }
  };

  return (
    <div
      className={`group border-b transition-colors ${
        expanded
          ? 'bg-things-surface/60 border-things-border-subtle/30'
          : 'border-things-border-subtle/30 hover:bg-things-sidebar-hover/30'
      } ${done ? 'opacity-40' : ''}`}
    >
      <div className="flex items-center gap-2 px-3 md:px-5 py-2.5 md:py-1.5">
        {/* Checkbox — round for habits */}
        <button
          type="button"
          role="checkbox"
          aria-checked={done}
          onClick={handleToggle}
          disabled={toggling}
          title={done ? 'Undo completion' : 'Mark done'}
          className={`relative flex-shrink-0 w-4 h-4 rounded-full transition-all ${
            done
              ? 'bg-done-green border-[1.5px] border-done-green'
              : 'bg-transparent border-[1.5px] border-things-border hover:border-accent'
          }`}
        >
          {done && (
            <span
              aria-hidden
              className="absolute"
              style={{
                left: 3,
                top: 1,
                width: 4,
                height: 8,
                borderRight: '1.5px solid white',
                borderBottom: '1.5px solid white',
                transform: 'rotate(45deg)',
              }}
            />
          )}
        </button>

        {/* State pill */}
        <HabitStatePill isDone={done} keywords={keywords} />

        {/* Priority badge */}
        <HabitPriorityBadge priority={habit.priority} />

        {/* Title + meta — click to expand */}
        <div
          className="flex-1 min-w-0 cursor-pointer select-none"
          onClick={() => setExpanded(o => !o)}
        >
          <span className={`block truncate text-[14px] md:text-[13px] leading-snug ${done ? 'line-through text-text-tertiary' : 'text-text-primary'}`}>
            {renderInline(habit.title)}
          </span>
          {/* Meta line */}
          <div className="flex items-center gap-2 mt-0.5 flex-wrap">
            {isOverdue && !done && (
              <span className="text-[9px] font-semibold uppercase tracking-wide text-priority-a">overdue</span>
            )}
            {habit.category && (
              <span className="text-[10px] text-text-tertiary">{habit.category}</span>
            )}
            {dueDateLabel && !done && (
              <span className={`text-[10px] flex items-center gap-0.5 ${isOverdue ? 'text-priority-a' : 'text-text-secondary'}`}>
                <CalendarBlank size={9} weight="regular" aria-hidden />
                {dueDateLabel}
              </span>
            )}
            <span className="text-[10px] text-text-tertiary flex items-center gap-0.5">
              {'↻'}{recurrenceLabel}
            </span>
            {habit.tags.map(tag => (
              <span
                key={tag}
                className="text-[10px] px-1.5 py-[1px] rounded-full bg-things-surface text-text-secondary whitespace-nowrap"
              >
                {tag}
              </span>
            ))}
          </div>
        </div>

        {/* Row menu */}
        <div className="relative flex-shrink-0" ref={menuRef}>
          <button
            onClick={(e) => { e.stopPropagation(); setMenuOpen(o => !o); if (!menuOpen) setMenuPhase('main'); }}
            className="w-6 h-6 flex items-center justify-center rounded text-text-tertiary hover:text-text-secondary hover:bg-things-sidebar-hover transition-colors opacity-0 group-hover:opacity-100 focus:opacity-100"
            title="More options"
          >
            <DotsThree size={16} weight="bold" />
          </button>
          {menuOpen && (
            <div className="absolute right-0 top-7 z-50 w-44 bg-things-bg border border-things-border rounded-lg shadow-xl p-1">
              {menuPhase === 'main' ? (
                <>
                  <button
                    onClick={async (e) => {
                      e.stopPropagation();
                      setMenuOpen(false);
                      setMenuPhase('main');
                      if (done) {
                        const lastTs = habit.completions[0];
                        if (lastTs) { try { await uncompleteHabit(habit.id, lastTs); onRefreshHabits(); } catch (err) { console.error(err); } }
                      } else {
                        try { await completeHabit(habit.id); onRefreshHabits(); } catch (err) { console.error(err); }
                      }
                    }}
                    className="w-full flex items-center gap-2 px-2.5 py-1.5 rounded text-[13px] text-text-primary hover:bg-things-sidebar-hover transition-colors"
                  >
                    {done ? 'Undo Done' : 'Done'}
                  </button>
                  <button
                    onClick={(e) => { e.stopPropagation(); handleSkip(); }}
                    className="w-full flex items-center gap-2 px-2.5 py-1.5 rounded text-[13px] text-text-primary hover:bg-things-sidebar-hover transition-colors"
                  >
                    Skip
                  </button>
                  <button
                    onClick={(e) => { e.stopPropagation(); setMenuPhase('schedule'); }}
                    className="w-full flex items-center gap-2 px-2.5 py-1.5 rounded text-[13px] text-text-primary hover:bg-things-sidebar-hover transition-colors"
                  >
                    Schedule…
                  </button>
                  <button
                    onClick={async (e) => {
                      e.stopPropagation();
                      setMenuOpen(false);
                      setMenuPhase('main');
                      if (isClocked) {
                        const session = clockManager.sessions.find(s => s.taskId === habit.id);
                        if (session) clockManager.stop(session.id);
                      } else {
                        await clockManager.startHabit(habit.id, habit.title);
                      }
                    }}
                    disabled={clockManager.sessions.find(s => s.taskId === habit.id)?.stoppingSince != null}
                    className={`w-full flex items-center gap-2 px-2.5 py-1.5 rounded text-[13px] hover:bg-things-sidebar-hover transition-colors disabled:opacity-40 ${
                      isClocked ? 'text-done-green' : 'text-text-primary'
                    }`}
                  >
                    {isClocked ? <Stop size={13} weight="fill" /> : <Play size={13} weight="fill" />}
                    {isClocked ? 'Clock Out' : 'Clock In'}
                  </button>
                  {countChecklistItems(effectiveNotes) > 0 && (
                    <button
                      onClick={async (e) => {
                        e.stopPropagation();
                        setMenuOpen(false);
                        setMenuPhase('main');
                        const reset = resetChecklist(effectiveNotes);
                        setLocalNotes(reset);
                        try { await updateHabit(habit.id, { notes: reset }); onRefreshHabits(); }
                        catch (err) { console.error('Failed to reset checklist:', err); setLocalNotes(null); }
                      }}
                      className="w-full flex items-center gap-2 px-2.5 py-1.5 rounded text-[13px] text-text-primary hover:bg-things-sidebar-hover transition-colors"
                    >
                      Reset checklist
                    </button>
                  )}
                  <div className="my-1 mx-1 border-t border-things-border" />
                  {onEdit && (
                    <button
                      onClick={(e) => { e.stopPropagation(); setMenuOpen(false); setMenuPhase('main'); onEdit(habit); }}
                      className="w-full flex items-center gap-2 px-2.5 py-1.5 rounded text-[13px] text-text-primary hover:bg-things-sidebar-hover transition-colors"
                    >
                      <PencilSimple size={13} />
                      Edit
                    </button>
                  )}
                  <button
                    onClick={(e) => { e.stopPropagation(); setMenuOpen(false); setMenuPhase('main'); handleDelete(); }}
                    className="w-full flex items-center gap-2 px-2.5 py-1.5 rounded text-[13px] text-red-500 hover:bg-red-500/10 transition-colors"
                  >
                    <Trash size={13} />
                    Delete
                  </button>
                </>
              ) : (
                <TodaySchedulePicker
                  onConfirm={handleReschedule}
                  onClose={() => { setMenuOpen(false); setMenuPhase('main'); }}
                />
              )}
            </div>
          )}
        </div>
      </div>

      {/* Expanded detail panel */}
      {expanded && (
        <div className="px-3 md:px-5 pb-3 pt-0 ml-2 md:ml-[62px]">
          <div className="flex items-center gap-2 mb-1">
            <span className="text-[10px] text-text-tertiary uppercase tracking-wider font-semibold">Notes</span>
            <button
              onClick={() => {
                if (editingNotes) {
                  setEditingNotes(false);
                } else {
                  setEditText(effectiveNotes);
                  setEditingNotes(true);
                }
              }}
              className={`text-[11px] px-1.5 py-0.5 rounded transition-colors ${
                editingNotes ? 'text-accent' : 'text-text-tertiary hover:text-text-secondary'
              }`}
              title={editingNotes ? 'Cancel editing' : 'Edit notes'}
            >
              {editingNotes ? <X size={11} weight="regular" /> : <PencilSimple size={11} weight="regular" />}
            </button>
          </div>

          {editingNotes ? (
            <div className="mb-2">
              <textarea
                value={editText}
                onChange={e => setEditText(e.target.value)}
                className="w-full bg-things-bg border border-things-border rounded-md px-3 py-2 text-[12px] text-text-primary font-mono leading-relaxed outline-none focus:border-accent/50 focus:ring-1 focus:ring-accent/30 resize-y min-h-[60px]"
                rows={Math.max(3, editText.split('\n').length + 1)}
                autoFocus
                spellCheck={false}
              />
              <div className="flex gap-2 mt-1.5">
                <button
                  onClick={handleNotesSave}
                  disabled={savingNotes}
                  className="px-3 py-1 rounded-md bg-accent/20 text-accent text-[11px] font-medium hover:bg-accent/30 transition-colors disabled:opacity-50"
                >
                  {savingNotes ? 'Saving...' : 'Save'}
                </button>
                <button
                  onClick={() => setEditingNotes(false)}
                  className="px-3 py-1 rounded-md bg-things-surface text-text-secondary text-[11px] hover:bg-things-sidebar-hover transition-colors"
                >
                  Cancel
                </button>
              </div>
            </div>
          ) : (
            <>
              {hasNotes && (
                <div className="mb-2">
                  <NotesRenderer
                    content={effectiveNotes}
                    onToggleCheck={hasChecklist ? handleChecklistToggle : undefined}
                  />
                </div>
              )}
              {!hasNotes && (
                <button
                  onClick={() => { setEditText(''); setEditingNotes(true); }}
                  className="text-[11px] text-text-tertiary hover:text-text-secondary mb-2 italic"
                >
                  + Add notes
                </button>
              )}
            </>
          )}

          <div className="text-[10px] text-text-tertiary mt-1">{'↻'}{recurrenceLabel}</div>
        </div>
      )}
    </div>
  );
}

function formatElapsed(seconds: number): string {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = seconds % 60;
  if (h > 0) return `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
  return `${m}:${String(s).padStart(2, '0')}`;
}

// ---------------------------------------------------------------------------
// All Tasks: habit edit modal wrapper
// ---------------------------------------------------------------------------

function AllTasksHabitEditModal({
  habit,
  submitting,
  onClose,
  onSubmit,
}: {
  habit: Habit;
  submitting: boolean;
  onClose: () => void;
  onSubmit: (body: CreateHabitBody) => void;
}) {
  return (
    <HabitFormModal
      initial={formStateFromHabit(habit)}
      onSubmit={onSubmit}
      onClose={onClose}
      submitting={submitting}
      editingId={habit.id}
    />
  );
}

// ---------------------------------------------------------------------------
// All Tasks: combined task + habit list with optional grouping by priority/category
// ---------------------------------------------------------------------------

type AllTasksItem =
  | { kind: 'task'; item: DisplayItem }
  | { kind: 'habit'; item: Habit };

function AllTasksCombinedList({
  items,
  activeGroups,
  keywords,
  isDoneState,
  clockManager,
  allTags,
  onRefresh,
  onRefreshHabits,
  onRefreshClock,
  onEditHabit,
}: {
  items: AllTasksItem[];
  activeGroups: GroupKey[];
  keywords: TodoKeywords | null;
  isDoneState: (s: string | undefined) => boolean;
  clockManager: ClockManager;
  allTags: string[];
  onRefresh: () => void;
  onRefreshHabits: () => void;
  onRefreshClock: () => void;
  onEditHabit: (h: Habit) => void;
}) {
  // Group key helpers for combined items
  const getItemGroupValue = (item: AllTasksItem, gk: GroupKey): string => {
    if (item.kind === 'task') return getGroupValue(item.item, gk);
    const h = item.item as Habit;
    switch (gk) {
      case 'priority': return h.priority || '_none';
      case 'category': return h.category || 'Uncategorized';
      // Habits don't have todoState — put them in a fixed bucket
      case 'state': return '_habit';
      case 'agenda': return 'Scheduled';
    }
  };

  const getItemGroupLabel = (gk: GroupKey, value: string): string => {
    if (value === '_habit') return 'Habits';
    return getGroupLabel(gk, value);
  };

  const renderItem = (item: AllTasksItem) => {
    if (item.kind === 'habit') {
      return (
        <TodayHabitRow
          key={`habit-${item.item.id}`}
          habit={item.item as Habit}
          onRefreshHabits={onRefreshHabits}
          clockManager={clockManager}
          keywords={keywords}
          onEdit={onEditHabit}
        />
      );
    }
    return (
      <TaskItem
        key={item.item.id + ('agendaType' in item.item ? (item.item as AgendaEntry).agendaType : '')}
        task={item.item as OrgTask | AgendaEntry}
        keywords={keywords}
        isDoneState={isDoneState}
        clockManager={clockManager}
        allTags={allTags}
        onRefresh={onRefresh}
        onRefreshClock={onRefreshClock}
      />
    );
  };

  if (activeGroups.length === 0) {
    // Flat list — already sorted by the parent's allTasksCombined memo
    return (
      <div className="task-card">
        {items.map(item => renderItem(item))}
      </div>
    );
  }

  // Group by first active group key
  const gk = activeGroups[0];
  const groupMap = new Map<string, AllTasksItem[]>();
  const seen: string[] = [];
  for (const item of items) {
    const val = getItemGroupValue(item, gk);
    if (!groupMap.has(val)) { groupMap.set(val, []); seen.push(val); }
    groupMap.get(val)!.push(item);
  }

  const sortedKeys = [...seen].sort((a, b) => groupSortOrder(gk, a, b));

  return (
    <AllTasksGroupedList
      groupKeys={sortedKeys}
      groupMap={groupMap}
      gk={gk}
      getItemGroupLabel={getItemGroupLabel}
      renderItem={renderItem}
    />
  );
}

function AllTasksGroupedList({
  groupKeys,
  groupMap,
  gk,
  getItemGroupLabel,
  renderItem,
}: {
  groupKeys: string[];
  groupMap: Map<string, AllTasksItem[]>;
  gk: GroupKey;
  getItemGroupLabel: (gk: GroupKey, val: string) => string;
  renderItem: (item: AllTasksItem) => React.ReactNode;
}) {
  const [collapsed, setCollapsed] = useState<Record<string, boolean>>(() => {
    try { return JSON.parse(localStorage.getItem('eav-collapsed-groups') || '{}'); }
    catch { return {}; }
  });
  const toggle = (key: string) => setCollapsed(prev => {
    const next = { ...prev, [key]: !prev[key] };
    try { localStorage.setItem('eav-collapsed-groups', JSON.stringify(next)); } catch { /* quota */ }
    return next;
  });

  return (
    <>
      {groupKeys.map(val => {
        const items = groupMap.get(val) ?? [];
        const label = getItemGroupLabel(gk, val);
        const collapseKey = `0-${label}`;
        const isCollapsed = !!collapsed[collapseKey];
        return (
          <div key={val}>
            <GroupHeader
              label={label}
              depth={0}
              collapsed={isCollapsed}
              onToggle={() => toggle(collapseKey)}
              count={items.length}
            />
            {!isCollapsed && (
              <div className="task-card">
                {items.map(item => renderItem(item))}
              </div>
            )}
          </div>
        );
      })}
    </>
  );
}

export function TaskList({
  tasks, habits, todayEntries, upcomingEntries, filter, keywords, isDoneState, clockStatus, clockManager, allTags, onRefresh, onRefreshHabits, onRefreshClock, onCapture, sidebarOpen, onToggleSidebar, warningDays = 14,
}: TaskListProps) {
  const [editingAllTasksHabit, setEditingAllTasksHabit] = useState<Habit | null>(null);
  const [allTasksHabitSubmitting, setAllTasksHabitSubmitting] = useState(false);
  const [controlsOpen, setControlsOpen] = useState(false);
  const [controlsAnchor, setControlsAnchor] = useState<{ top: number; right: number } | null>(null);
  const controlsBtnRef = useRef<HTMLButtonElement>(null);
  const controlsMenuRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!controlsOpen) return;
    const handler = (e: MouseEvent) => {
      if (controlsBtnRef.current?.contains(e.target as Node)) return;
      if (controlsMenuRef.current?.contains(e.target as Node)) return;
      setControlsOpen(false);
    };
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') setControlsOpen(false); };
    document.addEventListener('mousedown', handler);
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('mousedown', handler);
      document.removeEventListener('keydown', onKey);
    };
  }, [controlsOpen]);
  const [sortKey, setSortKey] = useState<SortKey>(() => {
    const saved = localStorage.getItem('eav-sort');
    return (saved as SortKey) || 'default';
  });
  const [activeGroups, setActiveGroups] = useState<GroupKey[]>(() => {
    try { return JSON.parse(localStorage.getItem('eav-groups') || '[]'); }
    catch { return []; }
  });
  const [showDone, setShowDone] = useState(() => localStorage.getItem('eav-showDone') === 'true');
  // Upcoming drag-to-reschedule: track which date header is the current drop target
  const [upcomingDragOver, setUpcomingDragOver] = useState<string | null>(null);

  // Persist sort/group/showDone to localStorage
  useEffect(() => { localStorage.setItem('eav-sort', sortKey); }, [sortKey]);
  useEffect(() => { localStorage.setItem('eav-groups', JSON.stringify(activeGroups)); }, [activeGroups]);
  useEffect(() => { localStorage.setItem('eav-showDone', String(showDone)); }, [showDone]);

  // Live clock timer
  const [clockElapsed, setClockElapsed] = useState(0);
  useEffect(() => {
    if (!clockStatus.clocking || !clockStatus.startTime) {
      setClockElapsed(0);
      return;
    }
    const startMs = new Date(clockStatus.startTime).getTime();
    const tick = () => setClockElapsed(Math.floor((Date.now() - startMs) / 1000));
    tick();
    const interval = setInterval(tick, 1000);
    return () => clearInterval(interval);
  }, [clockStatus.clocking, clockStatus.startTime]);

  const toggleGroup = (gk: GroupKey) => {
    setActiveGroups(prev =>
      prev.includes(gk) ? prev.filter(g => g !== gk) : [...prev, gk]
    );
  };

  // ========== TODAY VIEW ==========
  // Today's filter is the canonical iOS rule (see
  // `apps/macos/EmacsAgendaViewer/State/TodayClassifier.swift` and
  // `src/utils/today.ts`). It hides `upcoming-deadline` and done tasks
  // unconditionally — the per-view "show deadlines" / "show completed"
  // toggles do NOT apply here. Other views still honor `showDone` below.
  const { calendarEvents, todaySection } = useMemo(() => {
    if (filter.type !== 'today') return { calendarEvents: [], todaySection: [] };

    // Build the done-state set the classifier expects. `keywords` is null on
    // first paint — fall back to the org default (DONE/KILL) so the classifier
    // still drops obvious done states.
    const doneStates = new Set<string>();
    if (keywords) {
      for (const seq of keywords.sequences) {
        for (const d of seq.done) doneStates.add(d);
      }
    } else {
      doneStates.add('DONE');
      doneStates.add('KILL');
    }

    // Habits are now DB-managed and shown only in the Habits tab.
    // Always hide org-habit entries from the Today feed so they don't
    // double-appear. The `showHabitsInToday` setting is intentionally
    // ignored now that habits are a separate system.
    const { events, main } = buildTodayItems(
      todayEntries,
      tasks,
      doneStates,
      true, // always hide org-habit entries
    );

    return {
      calendarEvents: events,
      todaySection: sortItems(main as DisplayItem[], sortKey),
    };
  }, [todayEntries, tasks, keywords, filter.type, sortKey]);

  // ========== DUE HABITS FOR TODAY ==========
  // Always show habits in Today (per iOS parity). Exclude done-this-period.
  const showHabitsInToday = loadSettings().showHabitsInToday ?? true;
  // All active due/overdue habits
  const allDueHabits = useMemo(
    () => habits.filter(h => h.active && (h.state === 'due' || h.state === 'overdue')),
    [habits],
  );
  // Only undone ones appear in the main list
  const dueHabits = useMemo(
    () => allDueHabits.filter(h => !habitStatsFromDB(h).doneThisPeriod),
    [allDueHabits],
  );
  // Habit chip stats: how many of today's due habits are already done this period
  const habitDoneToday = useMemo(
    () => allDueHabits.filter(h => habitStatsFromDB(h).doneThisPeriod).length,
    [allDueHabits],
  );
  // Best current streak across all active habits
  const bestHabitStreak = useMemo(
    () => habits.reduce((best, h) => {
      const s = habitStatsFromDB(h).currentStreak;
      return s > best ? s : best;
    }, 0),
    [habits],
  );

  // ========== COMBINED TODAY ITEMS (tasks + habits, interleaved by priority) ==========
  // Mirrors iOS HomeView.buildCombinedItems: habit priority sorts alongside task priority.
  type TodayItem =
    | { kind: 'task'; item: DisplayItem }
    | { kind: 'habit'; item: Habit };

  const combinedToday = useMemo((): TodayItem[] => {
    if (filter.type !== 'today' || !showHabitsInToday) {
      return todaySection.map(t => ({ kind: 'task' as const, item: t }));
    }
    const habitPriorityOrd = (p: string | undefined) => {
      switch (p?.toUpperCase()) {
        case 'A': return 0; case 'B': return 1; case 'C': return 2; case 'D': return 3; default: return 4;
      }
    };
    const taskItems: TodayItem[] = todaySection.map(t => ({ kind: 'task' as const, item: t }));
    const habitItems: TodayItem[] = dueHabits.map(h => ({ kind: 'habit' as const, item: h }));
    const all = [...taskItems, ...habitItems];
    if (sortKey === 'default') {
      // Overdue float to top, then sort by priority within each group
      const overdue = all.filter(i =>
        i.kind === 'task'
          ? ('scheduled' in i.item && i.item.scheduled?.start != null && (() => {
              const c = (i.item as AgendaEntry | OrgTask).scheduled!.start!;
              const today2 = new Date(); today2.setHours(0,0,0,0);
              return new Date(c.year, c.month-1, c.day).getTime() < today2.getTime();
            })())
          : (i.item as Habit).state === 'overdue'
      );
      const rest = all.filter(i => !overdue.includes(i));
      const byPriOrd = (a: TodayItem, b: TodayItem) => {
        const pA = a.kind === 'task' ? priorityOrd(a.item.priority) : habitPriorityOrd((a.item as Habit).priority);
        const pB = b.kind === 'task' ? priorityOrd(b.item.priority) : habitPriorityOrd((b.item as Habit).priority);
        return pA - pB;
      };
      return [...overdue.sort(byPriOrd), ...rest.sort(byPriOrd)];
    }
    // Non-default sort: sort the combined list by priority
    return all.sort((a, b) => {
      const pA = a.kind === 'task' ? priorityOrd(a.item.priority) : habitPriorityOrd((a.item as Habit).priority);
      const pB = b.kind === 'task' ? priorityOrd(b.item.priority) : habitPriorityOrd((b.item as Habit).priority);
      if (pA !== pB) return pA - pB;
      return a.item.title.localeCompare(b.item.title);
    });
  }, [filter.type, showHabitsInToday, todaySection, dueHabits, sortKey]);

  // ========== OTHER VIEWS ==========
  const items: DisplayItem[] = useMemo(() => {
    if (filter.type === 'today') return [];
    // These views manage their own rendering
    if (filter.type === 'habits') return [];
    if (filter.type === 'eisenhower') return [];
    if (filter.type === 'calendar') return [];
    let result: DisplayItem[];
    switch (filter.type) {
      // Filter org-habit entries from Upcoming — they're DB-managed now.
      case 'upcoming': result = upcomingEntries.filter(e => !e.isHabit); break;
      case 'all': result = tasks.filter(t => t.todoState && !isHabit(t)); break;
      case 'logbook': result = tasks.filter(t => t.todoState && isDoneState(t.todoState)); break;
      case 'pinned': {
        const ymd = todayYMD();
        result = tasks.filter(t => t.properties?.PINNED === ymd);
        break;
      }
      case 'inbox': result = tasks.filter(t => {
        const basename = t.file.split('/').pop() || '';
        return (
          basename.toLowerCase() === 'inbox.org' ||
          t.category.toLowerCase() === 'inbox'
        );
      }); break;
      case 'file': result = tasks.filter(t => t.file === filter.path); break;
      case 'category': result = tasks.filter(t => t.category === filter.category); break;
      case 'tag': result = tasks.filter(t => t.tags.includes(filter.tag) || t.inheritedTags.includes(filter.tag)); break;
      default: result = tasks;
    }
    if (filter.type !== 'logbook' && !showDone) {
      // The logbook is *defined* as done tasks — never hide them there.
      result = result.filter(t => !isDoneState(t.todoState));
    }
    if (filter.type === 'logbook') {
      // Reverse-chronological by CLOSED is the natural read order; the
      // bucket renderer below collapses items into Today/Yesterday/etc.
      return [...result].sort((a, b) => {
        const ac = (a as OrgTask).closed || '';
        const bc = (b as OrgTask).closed || '';
        return bc.localeCompare(ac);
      });
    }
    return sortItems(result, sortKey);
  }, [tasks, upcomingEntries, filter, sortKey, showDone, isDoneState]);

  // ========== ALL TASKS COMBINED (tasks + active habits) ==========
  // Active habits are interleaved with tasks in All Tasks, sorted by priority.
  const allTasksCombined = useMemo((): AllTasksItem[] => {
    if (filter.type !== 'all') return [];
    const activeHabits = habits.filter(h => h.active);
    const taskItems: AllTasksItem[] = items.map(t => ({ kind: 'task' as const, item: t }));
    const habitItems: AllTasksItem[] = activeHabits.map(h => ({ kind: 'habit' as const, item: h }));
    const all = [...taskItems, ...habitItems];
    // Sort combined list: respect the chosen sortKey
    const habitPriOrd = (p: string | undefined) => {
      switch (p?.toUpperCase()) {
        case 'A': return 0; case 'B': return 1; case 'C': return 2; case 'D': return 3; default: return 4;
      }
    };
    if (sortKey === 'default') {
      // Default: sort by priority then title
      return all.sort((a, b) => {
        const pA = a.kind === 'task' ? priorityOrd(a.item.priority) : habitPriOrd((a.item as Habit).priority);
        const pB = b.kind === 'task' ? priorityOrd(b.item.priority) : habitPriOrd((b.item as Habit).priority);
        if (pA !== pB) return pA - pB;
        return a.item.title.localeCompare(b.item.title);
      });
    }
    return all.sort((a, b) => {
      const pA = a.kind === 'task' ? priorityOrd(a.item.priority) : habitPriOrd((a.item as Habit).priority);
      const pB = b.kind === 'task' ? priorityOrd(b.item.priority) : habitPriOrd((b.item as Habit).priority);
      if (pA !== pB) return pA - pB;
      return a.item.title.localeCompare(b.item.title);
    });
  }, [filter.type, items, habits, sortKey]);

  // Logbook: bucket by CLOSED date — Today / Yesterday / This Week / This
  // Month / Earlier / Unknown. Mirrors the Mac client's groupTasksByClosedDate.
  const logbookBuckets = useMemo(() => {
    if (filter.type !== 'logbook') return null;
    const now = new Date();
    const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
    const day = 86400000;
    const startOfYesterday = startOfToday - day;
    const startOfWeek = startOfToday - 6 * day;
    const startOfMonth = startOfToday - 30 * day;
    const buckets: Array<{ label: string; items: OrgTask[] }> = [
      { label: 'Today', items: [] },
      { label: 'Yesterday', items: [] },
      { label: 'This Week', items: [] },
      { label: 'This Month', items: [] },
      { label: 'Earlier', items: [] },
      { label: 'Unknown Date', items: [] },
    ];
    for (const t of items as OrgTask[]) {
      const ms = extractDateMs(t.closed);
      if (!isFinite(ms)) { buckets[5].items.push(t); continue; }
      if (ms >= startOfToday) buckets[0].items.push(t);
      else if (ms >= startOfYesterday) buckets[1].items.push(t);
      else if (ms >= startOfWeek) buckets[2].items.push(t);
      else if (ms >= startOfMonth) buckets[3].items.push(t);
      else buckets[4].items.push(t);
    }
    return buckets.filter(b => b.items.length > 0);
  }, [items, filter.type]);

  // File view hierarchy
  const { topLevel, children } = useMemo(() => {
    if (filter.type !== 'file') return { topLevel: items, children: new Map<string, DisplayItem[]>() };
    const childMap = new Map<string, DisplayItem[]>();
    const top: DisplayItem[] = [];
    for (const task of items) {
      const parentId = 'parentId' in task ? (task as OrgTask).parentId : undefined;
      if (parentId) {
        const existing = childMap.get(parentId) || [];
        existing.push(task);
        childMap.set(parentId, existing);
      } else { top.push(task); }
    }
    return { topLevel: top, children: childMap };
  }, [items, filter.type]);

  // Upcoming: group by date. The entries come in already sorted by the
  // user's chosen sortKey (priority/category/etc.), which scrambles the
  // date-grouping order because a Map preserves insertion order. Sort the
  // grouped pairs chronologically on the YYYY-MM-DD key before rendering —
  // `Unknown' entries sink to the end.
  const dateGroups = useMemo(() => {
    if (filter.type !== 'upcoming') return null;
    const groups = new Map<string, AgendaEntry[]>();
    for (const entry of items as AgendaEntry[]) {
      const date = entry.displayDate || 'Unknown';
      const existing = groups.get(date) || [];
      existing.push(entry);
      groups.set(date, existing);
    }
    return [...groups.entries()].sort(([a], [b]) => {
      if (a === 'Unknown') return 1;
      if (b === 'Unknown') return -1;
      return a.localeCompare(b);
    });
  }, [items, filter.type]);

  const totalCount = filter.type === 'today'
    ? calendarEvents.length + combinedToday.length
    : filter.type === 'habits'
      ? habits.length
    : filter.type === 'all'
      ? allTasksCombined.length
    : filter.type === 'eisenhower' || filter.type === 'calendar'
      ? tasks.filter(t => t.todoState && !isDoneState(t.todoState)).length
      : items.length;

  const isAgendaView = filter.type === 'today' || filter.type === 'upcoming';
  const sortOptions: SortKey[] = isAgendaView
    ? ['default', 'priority', 'category']
    : ['priority', 'deadline', 'state', 'category'];

  const controlsActive = sortKey !== 'default' || activeGroups.length > 0;

  return (
    <main className="flex-1 flex flex-col h-full overflow-hidden bg-things-bg">
      {/* Header — single-row: title + count, controls + Capture on the right */}
      <div className="sticky top-0 z-10 px-6 md:px-8 pt-6 pb-3.5 flex items-center justify-between gap-4 bg-things-bg/95 backdrop-blur-md">
        <div className="flex items-baseline gap-3 min-w-0">
          {onToggleSidebar && (
            <button
              onClick={onToggleSidebar}
              className="text-text-tertiary hover:text-text-secondary transition-colors text-[14px] self-center"
              title={sidebarOpen ? 'Hide sidebar (\u2318\\)' : 'Show sidebar (\u2318\\)'}
            >
              {sidebarOpen ? '\u25E7' : '\u2630'}
            </button>
          )}
          <h2 className="text-[20px] font-bold text-text-primary tracking-tight truncate">{filterTitle(filter)}</h2>
          <span className="text-[13px] text-text-tertiary tabular-nums whitespace-nowrap">
            {totalCount} item{totalCount === 1 ? '' : 's'}
          </span>
          {clockStatus.clocking && clockStatus.heading && (
            <span className="hidden md:inline-flex items-center gap-1.5 text-[11px] px-2 py-[3px] rounded-full bg-done-green/10 text-done-green border border-done-green/20 self-center">
              <span className="w-1.5 h-1.5 rounded-full bg-done-green animate-pulse" />
              <span className="max-w-[160px] truncate">{renderInline(clockStatus.heading)}</span>
              <span className="text-[9px] text-done-green/70 italic">Emacs</span>
            </span>
          )}
          {filter.type === 'today' && habits.length > 0 && (
            <span className="hidden md:inline-flex items-center gap-1 text-[11px] px-2 py-[3px] rounded-full bg-things-surface border border-things-border-subtle self-center text-text-secondary">
              {bestHabitStreak > 0 && <Fire size={11} weight="fill" className="text-done-green flex-shrink-0" />}
              <span className="tabular-nums">{habitDoneToday}/{dueHabits.length}</span>
              <span className="text-text-tertiary">habits</span>
              {bestHabitStreak > 0 && (
                <span className="text-[9px] text-text-tertiary tabular-nums">{bestHabitStreak}d streak</span>
              )}
            </span>
          )}
        </div>

        <div className="flex items-center gap-2 flex-shrink-0">
          <button
            onClick={() => setShowDone(!showDone)}
            className={`text-[13px] font-medium px-3 py-1.5 rounded-lg transition-colors ${
              showDone ? 'text-done-green bg-done-green/10' : 'text-text-secondary hover:bg-things-sidebar-hover hover:text-text-primary'
            }`}
          >
            {showDone ? 'Hide done' : 'Show done'}
          </button>
          <button
            onClick={onRefresh}
            className="text-[13px] px-2.5 py-1.5 rounded-lg text-text-secondary hover:bg-things-sidebar-hover hover:text-text-primary transition-colors"
            title="Refresh from Emacs"
          ><ArrowsClockwise size={13} weight="regular" /></button>
          <button
            ref={controlsBtnRef}
            onClick={(e) => {
              const rect = e.currentTarget.getBoundingClientRect();
              setControlsAnchor({ top: rect.bottom + 6, right: window.innerWidth - rect.right });
              setControlsOpen(o => !o);
            }}
            className={`text-[13px] px-2.5 py-1.5 rounded-lg transition-colors ${
              controlsActive ? 'text-accent bg-accent/10' : 'text-text-secondary hover:bg-things-sidebar-hover hover:text-text-primary'
            }`}
            title="Sort & group"
          >{'\u22EF'}</button>
          {onCapture && (
            <button
              onClick={onCapture}
              className="text-[13px] font-medium px-3 py-1.5 rounded-lg bg-things-surface text-text-primary border border-things-border hover:bg-things-sidebar-hover transition-colors flex items-center gap-2"
              title="New task (\u2318N)"
            >
              Capture
              <span className="font-mono text-[10px] px-1.5 py-[1px] bg-black/[0.06] dark:bg-white/[0.08] border border-things-border-subtle rounded text-text-tertiary">{'\u2318'}N</span>
            </button>
          )}
        </div>
      </div>

      {/* Content */}
      <div className="flex-1 overflow-y-auto">
        {/* Emacs clock banner (read-only indicator) */}
        {clockStatus.clocking && clockStatus.heading && (
          <div className="mx-3 md:mx-5 mt-3 mb-1 px-3 md:px-4 py-2 rounded-lg bg-done-green/10 border border-done-green/20 flex items-center gap-3">
            <span className="w-2 h-2 rounded-full bg-done-green animate-pulse flex-shrink-0" />
            <span className="text-[12px] text-done-green font-medium flex-1 truncate">
              {renderInline(clockStatus.heading)}
            </span>
            <span className="text-[13px] text-done-green font-bold tabular-nums">
              {formatElapsed(clockElapsed)}
            </span>
            <span className="text-[10px] text-done-green/70 italic">Emacs</span>
          </div>
        )}

        {filter.type === 'habits' ? (
          /* ========== HABITS VIEW ========== */
          <HabitsView
            habits={habits}
            onRefresh={onRefreshHabits}
            clockManager={clockManager}
            keywords={keywords}
          />

        ) : filter.type === 'eisenhower' ? (
          /* ========== EISENHOWER MATRIX VIEW ========== */
          <EisenhowerView
            tasks={tasks}
            keywords={keywords}
            isDoneState={isDoneState}
            clockManager={clockManager}
            allTags={allTags}
            onRefresh={onRefresh}
            onRefreshClock={onRefreshClock}
            warningDays={warningDays}
          />

        ) : filter.type === 'calendar' ? (
          /* ========== CALENDAR MONTH VIEW ========== */
          <CalendarView
            tasks={tasks}
            keywords={keywords}
            isDoneState={isDoneState}
            clockManager={clockManager}
            allTags={allTags}
            onRefresh={onRefresh}
            onRefreshClock={onRefreshClock}
          />

        ) : totalCount === 0 ? (
          <div className="flex flex-col items-center justify-center h-48 gap-2 text-text-tertiary text-sm">
            {filter.type === 'inbox' ? (
              <>
                <Check size={32} weight="bold" className="opacity-40" />
                <span className="font-medium text-text-secondary">Inbox is clear</span>
                <span className="text-[12px] text-center max-w-[260px]">
                  New captures land here. Refile them into project trees to keep this list empty.
                </span>
              </>
            ) : filter.type === 'pinned' ? (
              <>
                <PushPin size={32} weight="regular" className="opacity-40" />
                <span className="font-medium text-text-secondary">Nothing pinned for today</span>
                <span className="text-[12px] text-center max-w-[280px]">
                  Pin a task with {'⌘⇧P'} or right-click &rarr; Pin to My Day.
                </span>
              </>
            ) : (
              <span>No items</span>
            )}
          </div>

        ) : filter.type === 'today' ? (
          /* ========== TODAY VIEW ========== */
          <>
            {/* Events card: compact, rendered on top */}
            <EventBanners events={calendarEvents} />
            {/* Combined task + habit list, interleaved and sorted */}
            {combinedToday.length > 0 && (
              <div className="task-card">
                {combinedToday.map(row =>
                  row.kind === 'habit' ? (
                    <TodayHabitRow
                      key={`habit-${row.item.id}`}
                      habit={row.item as Habit}
                      onRefreshHabits={onRefreshHabits}
                      clockManager={clockManager}
                      keywords={keywords}
                    />
                  ) : (
                    <TaskItem
                      key={row.item.id + ('agendaType' in row.item ? (row.item as AgendaEntry).agendaType : '')}
                      task={row.item as OrgTask | AgendaEntry}
                      keywords={keywords}
                      isDoneState={isDoneState}
                      clockManager={clockManager}
                      allTags={allTags}
                      onRefresh={onRefresh}
                      onRefreshClock={onRefreshClock}
                    />
                  )
                )}
              </div>
            )}
          </>

        ) : dateGroups ? (
          /* ========== UPCOMING VIEW ========== */
          dateGroups.map(([date, entries]) => {
            const { dayNum, weekday, month, isToday, isTomorrow } = formatDateHeader(date);

            // Always split out events as banners
            const dayEvents = entries.filter(isEventEntry);
            const dayTasks = entries.filter(e => !isEventEntry(e));

            // Apply multi-group to the non-event items
            const grouped = multiGroup(dayTasks, activeGroups);
            const isDragTarget = upcomingDragOver === date;

            const handleHeaderDragOver = (e: React.DragEvent) => {
              e.preventDefault();
              e.dataTransfer.dropEffect = 'move';
              setUpcomingDragOver(date);
            };
            const handleHeaderDrop = async (e: React.DragEvent) => {
              e.preventDefault();
              setUpcomingDragOver(null);
              const id = e.dataTransfer.getData(DRAG_KEY);
              if (!id) return;
              // Find the OrgTask from tasks list (upcomingEntries are AgendaEntry, but we need OrgTask for updateScheduled)
              const taskData = tasks.find(t => t.id === id);
              if (!taskData) return;
              const [y, mo, d] = date.split('-').map(Number);
              const dateObj = new Date(y, mo - 1, d);
              const weekdays = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
              const ts = `<${date} ${weekdays[dateObj.getDay()]}>`;
              try {
                await updateScheduled(taskData, ts);
                onRefresh();
              } catch (err) {
                console.error('Upcoming drop failed:', err);
              }
            };

            return (
              <div key={date}>
                <div
                  className={`px-3 md:px-5 pt-4 pb-1 border-b border-things-border-subtle/30 sticky top-0 bg-things-bg/95 backdrop-blur-sm z-10 transition-colors ${
                    isDragTarget ? 'bg-accent/10 ring-1 ring-inset ring-accent/40' : ''
                  }`}
                  onDragOver={handleHeaderDragOver}
                  onDragLeave={() => setUpcomingDragOver(null)}
                  onDrop={handleHeaderDrop}
                >
                  <div className="flex items-baseline gap-2">
                    <span className="text-2xl font-bold text-text-primary tabular-nums leading-none">{dayNum}</span>
                    <span className="text-[12px] font-medium text-text-secondary">
                      {isToday ? 'Today' : isTomorrow ? 'Tomorrow' : weekday}
                    </span>
                    <span className="text-[10px] text-text-tertiary">{month}</span>
                    {isDragTarget && (
                      <span className="ml-auto text-[10px] text-accent font-medium">Drop to reschedule</span>
                    )}
                  </div>
                </div>
                <EventBanners events={dayEvents} />
                {dayTasks.length > 0 && (
                  <div className="task-card">
                    <RenderGroups nodes={grouped} keywords={keywords} isDoneState={isDoneState} clockManager={clockManager} allTags={allTags} onRefresh={onRefresh} onRefreshClock={onRefreshClock} makeDraggable />
                  </div>
                )}
              </div>
            );
          })

        ) : filter.type === 'logbook' && logbookBuckets ? (
          /* ========== LOGBOOK VIEW ========== */
          logbookBuckets.map(bucket => (
            <div key={bucket.label}>
              <SectionHeader title={bucket.label} count={bucket.items.length} />
              <div className="task-card">
                {bucket.items.map(task => (
                  <TaskItem
                    key={task.id}
                    task={task}
                    keywords={keywords}
                    isDoneState={isDoneState}
                    clockManager={clockManager}
                    allTags={allTags}
                    onRefresh={onRefresh}
                    onRefreshClock={onRefreshClock}
                    allowArchive
                  />
                ))}
              </div>
            </div>
          ))

        ) : filter.type === 'all' ? (
          /* ========== ALL TASKS VIEW (tasks + active habits interleaved) ========== */
          <>
            <AllTasksCombinedList
              items={allTasksCombined}
              activeGroups={activeGroups}
              keywords={keywords}
              isDoneState={isDoneState}
              clockManager={clockManager}
              allTags={allTags}
              onRefresh={onRefresh}
              onRefreshHabits={onRefreshHabits}
              onRefreshClock={onRefreshClock}
              onEditHabit={h => setEditingAllTasksHabit(h)}
            />
            {editingAllTasksHabit && (
              <AllTasksHabitEditModal
                habit={editingAllTasksHabit}
                submitting={allTasksHabitSubmitting}
                onClose={() => setEditingAllTasksHabit(null)}
                onSubmit={async (body) => {
                  setAllTasksHabitSubmitting(true);
                  try {
                    await updateHabit(editingAllTasksHabit.id, body);
                    setEditingAllTasksHabit(null);
                    onRefreshHabits();
                  } catch (err) {
                    console.error('Failed to update habit:', err);
                  } finally {
                    setAllTasksHabitSubmitting(false);
                  }
                }}
              />
            )}
          </>

        ) : filter.type === 'file' ? (
          /* ========== FILE VIEW ========== */
          <div className="task-card">
            {topLevel.map(task => (
              <div key={task.id}>
                <TaskItem task={task} keywords={keywords} isDoneState={isDoneState} clockManager={clockManager} allTags={allTags} onRefresh={onRefresh} onRefreshClock={onRefreshClock} />
                {children.get(task.id)?.map(child => (
                  <div key={child.id} className="pl-8">
                    <TaskItem task={child} keywords={keywords} isDoneState={isDoneState} clockManager={clockManager} allTags={allTags} onRefresh={onRefresh} onRefreshClock={onRefreshClock} />
                  </div>
                ))}
              </div>
            ))}
          </div>

        ) : (
          /* ========== OTHER VIEWS ========== */
          <div className="task-card">
            <RenderGroups
              nodes={multiGroup(items, activeGroups)}
              keywords={keywords}
              isDoneState={isDoneState}
              clockManager={clockManager}
              allTags={allTags}
              onRefresh={onRefresh}
              onRefreshClock={onRefreshClock}
            />
          </div>
        )}
      </div>

      {controlsOpen && controlsAnchor && createPortal(
        <div
          ref={controlsMenuRef}
          role="menu"
          className="fixed w-[220px] rounded-lg border border-things-border bg-things-bg shadow-2xl p-1 z-[9999]"
          style={{
            top: controlsAnchor.top,
            right: controlsAnchor.right,
            boxShadow: '0 12px 32px -4px rgba(0,0,0,0.18), 0 2px 6px rgba(0,0,0,0.08)',
          }}
        >
          <div className="px-2.5 pt-2 pb-1 text-[9px] uppercase tracking-widest text-text-secondary font-semibold">Sort by</div>
          {sortOptions.map(key => {
            const sel = sortKey === key;
            return (
              <button
                key={key}
                onClick={() => setSortKey(key)}
                className={`w-full flex items-center justify-between gap-2 px-2.5 py-1.5 rounded-md text-[13px] transition-colors capitalize ${
                  sel ? 'bg-accent/10 text-accent' : 'text-text-primary hover:bg-things-sidebar-hover'
                }`}
              >
                <span>{key === 'default' ? 'Agenda' : key}</span>
                <Check size={11} weight="bold" className={sel ? 'opacity-100' : 'opacity-0'} />
              </button>
            );
          })}
          <div className="my-1 mx-1 border-t border-things-border" />
          <div className="px-2.5 pt-1 pb-1 flex items-center justify-between">
            <span className="text-[9px] uppercase tracking-widest text-text-secondary font-semibold">Group by</span>
            {activeGroups.length > 0 && (
              <button
                onClick={() => setActiveGroups([])}
                className="text-[10px] text-text-tertiary hover:text-priority-a transition-colors font-medium"
                title="Clear all groups"
              >Clear</button>
            )}
          </div>
          {ALL_GROUP_KEYS.map(key => {
            const sel = activeGroups.includes(key);
            return (
              <button
                key={key}
                onClick={() => toggleGroup(key)}
                className={`w-full flex items-center justify-between gap-2 px-2.5 py-1.5 rounded-md text-[13px] transition-colors capitalize ${
                  sel ? 'bg-accent/10 text-accent' : 'text-text-primary hover:bg-things-sidebar-hover'
                }`}
              >
                <span>{key}</span>
                <Check size={11} weight="bold" className={sel ? 'opacity-100' : 'opacity-0'} />
              </button>
            );
          })}
        </div>,
        document.body
      )}
    </main>
  );
}
