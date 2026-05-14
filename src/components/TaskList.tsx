import { useMemo, useState, useEffect, useRef } from 'react';
import { createPortal } from 'react-dom';
import type { OrgTask, AgendaEntry, ViewFilter, TodoKeywords } from '../types';
import { TaskItem } from './TaskItem';
import { renderInline } from './NotesRenderer';
import { type ClockStatus, clockOutApi, loadSettings, updateScheduled } from '../api/tasks';
import { HabitsView, TodayHabitsGroup } from './HabitsView';
import { isHabit } from '../utils/habits';
import { EisenhowerView } from './EisenhowerView';
import { CalendarView } from './CalendarView';

type DisplayItem = OrgTask | AgendaEntry;

interface TaskListProps {
  tasks: OrgTask[];
  todayEntries: AgendaEntry[];
  upcomingEntries: AgendaEntry[];
  filter: ViewFilter;
  keywords: TodoKeywords | null;
  isDoneState: (state: string | undefined) => boolean;
  clockStatus: ClockStatus;
  allTags: string[];
  onRefresh: () => void;
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
      <span className={`text-[11px] leading-none text-text-secondary transition-transform inline-block w-3 ${collapsed ? '' : 'rotate-90'}`}>{'\u25B6'}</span>
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

/** Render event banners */
function EventBanners({ events }: { events: DisplayItem[] }) {
  if (events.length === 0) return null;
  return (
    <div className="px-3 md:px-5 pt-2 pb-1 flex flex-col gap-0.5">
      {events.map(event => (
        <div
          key={event.id + ('agendaType' in event ? (event as AgendaEntry).agendaType : '')}
          className="flex items-center gap-2 px-3 py-1.5 rounded-md bg-things-surface/60 border border-things-border-subtle/20"
        >
          <span className="w-[3px] h-4 rounded-full bg-accent-teal flex-shrink-0" />
          <span className="text-[12px] text-text-primary flex-1">{renderInline(event.title)}</span>
          {'timeOfDay' in event && (event as AgendaEntry).timeOfDay && (
            <span className="text-[10px] text-accent-teal font-medium">{(event as AgendaEntry).timeOfDay}</span>
          )}
        </div>
      ))}
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
  nodes, keywords, isDoneState, clockStatus, allTags, onRefresh, onRefreshClock, makeDraggable,
}: {
  nodes: GroupNode[];
  keywords: TodoKeywords | null;
  isDoneState: (s: string | undefined) => boolean;
  clockStatus: ClockStatus;
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
                <RenderGroups nodes={node.children} keywords={keywords} isDoneState={isDoneState} clockStatus={clockStatus} allTags={allTags} onRefresh={onRefresh} onRefreshClock={onRefreshClock} makeDraggable={makeDraggable} />
              ) : (
                node.items.map(task => {
                  const itemKey = task.id + ('agendaType' in task ? (task as AgendaEntry).agendaType : '');
                  const taskItem = (
                    <TaskItem
                      key={itemKey}
                      task={task}
                      keywords={keywords}
                      isDoneState={isDoneState}
                      clockStatus={clockStatus}
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

function formatElapsed(seconds: number): string {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = seconds % 60;
  if (h > 0) return `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
  return `${m}:${String(s).padStart(2, '0')}`;
}

export function TaskList({
  tasks, todayEntries, upcomingEntries, filter, keywords, isDoneState, clockStatus, allTags, onRefresh, onRefreshClock, onCapture, sidebarOpen, onToggleSidebar, warningDays = 14,
}: TaskListProps) {
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
  const { calendarEvents, todaySection } = useMemo(() => {
    if (filter.type !== 'today') return { calendarEvents: [], todaySection: [] };

    const settings = loadSettings();
    const hideDeadlines = !!settings.hideDeadlinesInToday;

    const events = todayEntries.filter(isEventEntry);
    let todayItems = todayEntries.filter(e =>
      !isEventEntry(e) && e.agendaType !== 'upcoming-deadline'
    );
    if (hideDeadlines) todayItems = todayItems.filter(e => e.agendaType !== 'deadline');
    if (!showDone) todayItems = todayItems.filter(t => !isDoneState(t.todoState));

    return {
      calendarEvents: events,
      todaySection: sortItems(todayItems, sortKey) as AgendaEntry[],
    };
  }, [todayEntries, filter.type, sortKey, showDone, isDoneState]);

  // ========== OTHER VIEWS ==========
  const items: DisplayItem[] = useMemo(() => {
    if (filter.type === 'today') return [];
    // These views manage their own rendering
    if (filter.type === 'habits') return [];
    if (filter.type === 'eisenhower') return [];
    if (filter.type === 'calendar') return [];
    let result: DisplayItem[];
    switch (filter.type) {
      case 'upcoming': result = upcomingEntries; break;
      case 'all': result = tasks.filter(t => t.todoState); break;
      case 'logbook': result = tasks.filter(t => t.todoState && isDoneState(t.todoState)); break;
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
    ? calendarEvents.length + todaySection.length
    : filter.type === 'habits'
      ? tasks.filter(isHabit).length
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
              <button
                onClick={async () => { try { await clockOutApi(); onRefreshClock(); } catch (err) { console.error('Failed to clock out:', err); } }}
                className="text-done-green hover:brightness-125"
                title="Stop clock"
              >{'\u23F9'}</button>
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
          >{'\u21BB'}</button>
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
        {/* Clock banner */}
        {clockStatus.clocking && clockStatus.heading && (
          <div className="mx-3 md:mx-5 mt-3 mb-1 px-3 md:px-4 py-2 rounded-lg bg-done-green/10 border border-done-green/20 flex items-center gap-3">
            <span className="w-2 h-2 rounded-full bg-done-green animate-pulse flex-shrink-0" />
            <span className="text-[12px] text-done-green font-medium flex-1 truncate">
              {renderInline(clockStatus.heading)}
            </span>
            <span className="text-[13px] text-done-green font-bold tabular-nums">
              {formatElapsed(clockElapsed)}
            </span>
            <button
              onClick={async () => {
                try { await clockOutApi(); onRefreshClock(); }
                catch (err) { console.error('Failed to clock out:', err); }
              }}
              className="text-[10px] px-2 py-0.5 rounded bg-done-green/20 text-done-green hover:bg-done-green/30 transition-colors font-medium"
            >
              Stop
            </button>
          </div>
        )}

        {filter.type === 'habits' ? (
          /* ========== HABITS VIEW ========== */
          <HabitsView
            tasks={tasks}
            keywords={keywords}
            isDoneState={isDoneState}
            clockStatus={clockStatus}
            allTags={allTags}
            onRefresh={onRefresh}
            onRefreshClock={onRefreshClock}
          />

        ) : filter.type === 'eisenhower' ? (
          /* ========== EISENHOWER MATRIX VIEW ========== */
          <EisenhowerView
            tasks={tasks}
            keywords={keywords}
            isDoneState={isDoneState}
            clockStatus={clockStatus}
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
            clockStatus={clockStatus}
            allTags={allTags}
            onRefresh={onRefresh}
            onRefreshClock={onRefreshClock}
          />

        ) : totalCount === 0 ? (
          <div className="flex flex-col items-center justify-center h-48 gap-2 text-text-tertiary text-sm">
            {filter.type === 'inbox' ? (
              <>
                <span className="text-3xl opacity-40">{'✓'}</span>
                <span className="font-medium text-text-secondary">Inbox is clear</span>
                <span className="text-[12px] text-center max-w-[260px]">
                  New captures land here. Refile them into project trees to keep this list empty.
                </span>
              </>
            ) : (
              <span>No items</span>
            )}
          </div>

        ) : filter.type === 'today' ? (
          /* ========== TODAY VIEW ========== */
          <>
            <EventBanners events={calendarEvents} />
            {loadSettings().showHabitsInToday && (
              <TodayHabitsGroup
                tasks={tasks}
                onRefresh={onRefresh}
                isMobile={window.innerWidth < 768}
              />
            )}
            {todaySection.length > 0 && (
              <>
                <SectionHeader title="Today" count={todaySection.length} />
                <div className="task-card">
                  <RenderGroups
                    nodes={multiGroup(todaySection, activeGroups)}
                    keywords={keywords}
                    isDoneState={isDoneState}
                    clockStatus={clockStatus}
                    allTags={allTags}
                    onRefresh={onRefresh}
                    onRefreshClock={onRefreshClock}
                  />
                </div>
              </>
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
                    <RenderGroups nodes={grouped} keywords={keywords} isDoneState={isDoneState} clockStatus={clockStatus} allTags={allTags} onRefresh={onRefresh} onRefreshClock={onRefreshClock} makeDraggable />
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
                    clockStatus={clockStatus}
                    allTags={allTags}
                    onRefresh={onRefresh}
                    onRefreshClock={onRefreshClock}
                    allowArchive
                  />
                ))}
              </div>
            </div>
          ))

        ) : filter.type === 'file' ? (
          /* ========== FILE VIEW ========== */
          <div className="task-card">
            {topLevel.map(task => (
              <div key={task.id}>
                <TaskItem task={task} keywords={keywords} isDoneState={isDoneState} clockStatus={clockStatus} allTags={allTags} onRefresh={onRefresh} onRefreshClock={onRefreshClock} />
                {children.get(task.id)?.map(child => (
                  <div key={child.id} className="pl-8">
                    <TaskItem task={child} keywords={keywords} isDoneState={isDoneState} clockStatus={clockStatus} allTags={allTags} onRefresh={onRefresh} onRefreshClock={onRefreshClock} />
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
              clockStatus={clockStatus}
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
                <span className={`text-[11px] ${sel ? 'opacity-100' : 'opacity-0'}`}>{'✓'}</span>
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
                <span className={`text-[11px] ${sel ? 'opacity-100' : 'opacity-0'}`}>{'✓'}</span>
              </button>
            );
          })}
        </div>,
        document.body
      )}
    </main>
  );
}
