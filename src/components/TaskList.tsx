import { useMemo, useState, useEffect } from 'react';
import type { OrgTask, AgendaEntry, ViewFilter, TodoKeywords } from '../types';
import { TaskItem } from './TaskItem';
import { renderInline } from './NotesRenderer';
import { type ClockStatus, clockOutApi } from '../api/tasks';

type DisplayItem = OrgTask | AgendaEntry;

interface TaskListProps {
  tasks: OrgTask[];
  todayEntries: AgendaEntry[];
  upcomingEntries: AgendaEntry[];
  filter: ViewFilter;
  keywords: TodoKeywords | null;
  isDoneState: (state: string | undefined) => boolean;
  clockStatus: ClockStatus;
  onRefresh: () => void;
  onRefreshClock: () => void;
  sidebarOpen?: boolean;
  onToggleSidebar?: () => void;
}

type SortKey = 'priority' | 'state' | 'deadline' | 'category' | 'default';
type GroupKey = 'agenda' | 'priority' | 'category' | 'state';

function filterTitle(filter: ViewFilter): string {
  switch (filter.type) {
    case 'all': return 'All Tasks';
    case 'today': return 'Today';
    case 'upcoming': return 'Upcoming';
    case 'file': return filter.path.split('/').pop()?.replace('.org', '') || 'File';
    case 'category': return filter.category;
    case 'tag': return `#${filter.tag}`;
  }
}

function priorityOrd(p: string | undefined): number {
  switch (p) { case 'A': return 0; case 'B': return 1; case 'C': return 2; case 'D': return 3; default: return 4; }
}

function priorityLabel(_p: string | undefined): string {
  return '';
}

function extractDateMs(raw: string | undefined): number {
  if (!raw) return Infinity;
  const m = raw.match(/(\d{4})-(\d{2})-(\d{2})/);
  if (!m) return Infinity;
  return new Date(parseInt(m[1]), parseInt(m[2]) - 1, parseInt(m[3])).getTime();
}

function sortItems(items: DisplayItem[], sortKey: SortKey): DisplayItem[] {
  if (sortKey === 'default') return items;
  return [...items].sort((a, b) => {
    switch (sortKey) {
      case 'priority': return priorityOrd(a.priority) - priorityOrd(b.priority);
      case 'state': return (a.todoState || '').localeCompare(b.todoState || '');
      case 'deadline': return (extractDateMs(a.deadline?.raw) || extractDateMs(a.scheduled?.raw)) - (extractDateMs(b.deadline?.raw) || extractDateMs(b.scheduled?.raw));
      case 'category': return a.category.localeCompare(b.category);
      default: return 0;
    }
  });
}

function isEventEntry(item: DisplayItem): boolean {
  if (!('agendaType' in item)) return false;
  const e = item as AgendaEntry;
  return (e.agendaType === 'timestamp' || e.agendaType === 'sexp') && !e.todoState;
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
    <div
      className={`px-3 md:px-5 ${pad} flex items-center gap-2 cursor-pointer select-none group/hdr`}
      onClick={onToggle}
    >
      <span className={`text-[9px] text-text-tertiary transition-transform ${collapsed ? '' : 'rotate-90'}`}>{'\u25B6'}</span>
      <span className={`${size} font-semibold text-text-tertiary uppercase tracking-wider`}>
        {label}
      </span>
      <span className="text-[9px] text-text-tertiary/60 tabular-nums">{count}</span>
      <div className="flex-1 border-t border-things-border-subtle/30" />
    </div>
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

/** Recursively render grouped items with collapsible headers */
function RenderGroups({
  nodes, keywords, isDoneState, clockStatus, onRefresh, onRefreshClock,
}: {
  nodes: GroupNode[];
  keywords: TodoKeywords | null;
  isDoneState: (s: string | undefined) => boolean;
  clockStatus: ClockStatus;
  onRefresh: () => void;
  onRefreshClock: () => void;
}) {
  const [collapsed, setCollapsed] = useState<Record<string, boolean>>({});
  const toggle = (key: string) => setCollapsed(prev => ({ ...prev, [key]: !prev[key] }));

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
                <RenderGroups nodes={node.children} keywords={keywords} isDoneState={isDoneState} clockStatus={clockStatus} onRefresh={onRefresh} onRefreshClock={onRefreshClock} />
              ) : (
                node.items.map(task => (
                  <TaskItem
                    key={task.id + ('agendaType' in task ? (task as AgendaEntry).agendaType : '')}
                    task={task}
                    keywords={keywords}
                    isDoneState={isDoneState}
                    clockStatus={clockStatus}
                    onRefresh={onRefresh}
                    onRefreshClock={onRefreshClock}
                  />
                ))
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
  tasks, todayEntries, upcomingEntries, filter, keywords, isDoneState, clockStatus, onRefresh, onRefreshClock, sidebarOpen, onToggleSidebar,
}: TaskListProps) {
  const [sortKey, setSortKey] = useState<SortKey>('default');
  const [activeGroups, setActiveGroups] = useState<GroupKey[]>([]);
  const [showDone, setShowDone] = useState(false);

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

    const events = todayEntries.filter(isEventEntry);
    let todayItems = todayEntries.filter(e =>
      !isEventEntry(e) && e.agendaType !== 'upcoming-deadline'
    );
    if (!showDone) todayItems = todayItems.filter(t => !isDoneState(t.todoState));

    return {
      calendarEvents: events,
      todaySection: sortItems(todayItems, sortKey) as AgendaEntry[],
    };
  }, [todayEntries, filter.type, sortKey, showDone, isDoneState]);

  // ========== OTHER VIEWS ==========
  const items: DisplayItem[] = useMemo(() => {
    if (filter.type === 'today') return [];
    let result: DisplayItem[];
    switch (filter.type) {
      case 'upcoming': result = upcomingEntries; break;
      case 'all': result = tasks.filter(t => t.todoState); break;
      case 'file': result = tasks.filter(t => t.file === filter.path); break;
      case 'category': result = tasks.filter(t => t.category === filter.category); break;
      case 'tag': result = tasks.filter(t => t.tags.includes(filter.tag) || t.inheritedTags.includes(filter.tag)); break;
      default: result = tasks;
    }
    if (!showDone) result = result.filter(t => !isDoneState(t.todoState));
    return sortItems(result, sortKey);
  }, [tasks, upcomingEntries, filter, sortKey, showDone, isDoneState]);

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

  // Upcoming: group by date
  const dateGroups = useMemo(() => {
    if (filter.type !== 'upcoming') return null;
    const groups = new Map<string, AgendaEntry[]>();
    for (const entry of items as AgendaEntry[]) {
      const date = entry.displayDate || 'Unknown';
      const existing = groups.get(date) || [];
      existing.push(entry);
      groups.set(date, existing);
    }
    return groups;
  }, [items, filter.type]);

  const totalCount = filter.type === 'today'
    ? calendarEvents.length + todaySection.length
    : items.length;

  const isAgendaView = filter.type === 'today' || filter.type === 'upcoming';
  const sortOptions: SortKey[] = isAgendaView
    ? ['default', 'priority', 'category']
    : ['priority', 'deadline', 'state', 'category'];

  return (
    <main className="flex-1 flex flex-col h-full overflow-hidden bg-things-bg">
      {/* Header */}
      <div className="px-4 md:px-5 py-3 border-b border-things-border">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-3">
            {onToggleSidebar && (
              <button
                onClick={onToggleSidebar}
                className="text-text-tertiary hover:text-text-secondary transition-colors text-[14px]"
                title={sidebarOpen ? 'Hide sidebar (\u2318\\)' : 'Show sidebar (\u2318\\)'}
              >
                {sidebarOpen ? '\u25E7' : '\u2630'}
              </button>
            )}
            <h2 className="text-lg md:text-xl font-bold text-text-primary tracking-tight">{filterTitle(filter)}</h2>
          </div>
          <div className="flex items-center gap-2 md:gap-3">
            <button
              onClick={() => setShowDone(!showDone)}
              className={`text-[11px] px-2 md:px-2.5 py-1 rounded-md transition-colors ${
                showDone ? 'bg-done-green/15 text-done-green' : 'bg-things-surface text-text-secondary hover:bg-things-sidebar-hover'
              }`}
            >
              {showDone ? 'Hide done' : 'Show done'}
            </button>
            <button
              onClick={onRefresh}
              className="text-[11px] px-2 md:px-2.5 py-1 rounded-md bg-things-surface text-text-secondary hover:bg-things-sidebar-hover transition-colors"
              title="Refresh from Emacs"
            >{'\u21BB'}</button>
            <span className="text-[11px] text-text-tertiary tabular-nums">{totalCount}</span>
          </div>
        </div>

        {/* Sort & Group controls — second row on mobile */}
        <div className="flex flex-wrap items-center gap-2 md:gap-3 mt-2">
          {/* Sort */}
          <div className="flex items-center gap-1 md:gap-1.5 text-xs text-text-tertiary">
            <span className="text-[10px] md:text-xs">Sort:</span>
            {sortOptions.map(key => (
              <button
                key={key}
                onClick={() => setSortKey(key)}
                className={`px-2 md:px-2.5 py-1 rounded-md transition-colors capitalize text-[11px] ${
                  sortKey === key
                    ? 'bg-accent/20 text-accent'
                    : 'bg-things-surface hover:bg-things-sidebar-hover text-text-secondary'
                }`}
              >
                {key === 'default' ? 'agenda' : key}
              </button>
            ))}
          </div>

          <div className="w-px h-4 bg-things-border hidden md:block" />
          <div className="w-full md:hidden" />

          {/* Group — multi-select toggles */}
          <div className="flex items-center gap-1 md:gap-1.5 text-xs text-text-tertiary">
            <span className="text-[10px] md:text-xs">Group:</span>
            {ALL_GROUP_KEYS.map(key => (
              <button
                key={key}
                onClick={() => toggleGroup(key)}
                className={`px-2 md:px-2.5 py-1 rounded-md transition-colors capitalize text-[11px] ${
                  activeGroups.includes(key)
                    ? 'bg-dot-purple/20 text-dot-purple'
                    : 'bg-things-surface hover:bg-things-sidebar-hover text-text-secondary'
                }`}
              >
                {key}
              </button>
            ))}
            {activeGroups.length > 0 && (
              <button
                onClick={() => setActiveGroups([])}
                className="px-1.5 py-1 rounded-md text-[10px] text-text-tertiary hover:text-priority-a transition-colors"
                title="Clear all groups"
              >
                {'\u2715'}
              </button>
            )}
          </div>
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

        {totalCount === 0 ? (
          <div className="flex items-center justify-center h-48 text-text-tertiary text-sm">No items</div>

        ) : filter.type === 'today' ? (
          /* ========== TODAY VIEW ========== */
          <>
            <EventBanners events={calendarEvents} />
            {todaySection.length > 0 && (
              <>
                <SectionHeader title="Today" count={todaySection.length} />
                <RenderGroups
                  nodes={multiGroup(todaySection, activeGroups)}
                  keywords={keywords}
                  isDoneState={isDoneState}
                  clockStatus={clockStatus}
                  onRefresh={onRefresh}
                  onRefreshClock={onRefreshClock}
                />
              </>
            )}
          </>

        ) : dateGroups ? (
          /* ========== UPCOMING VIEW ========== */
          Array.from(dateGroups.entries()).map(([date, entries]) => {
            const { dayNum, weekday, month, isToday, isTomorrow } = formatDateHeader(date);

            // Always split out events as banners
            const dayEvents = entries.filter(isEventEntry);
            const dayTasks = entries.filter(e => !isEventEntry(e));

            // Apply multi-group to the non-event items
            const grouped = multiGroup(dayTasks, activeGroups);

            return (
              <div key={date}>
                <div className="px-3 md:px-5 pt-4 pb-1 border-b border-things-border-subtle/30 sticky top-0 bg-things-bg/95 backdrop-blur-sm z-10">
                  <div className="flex items-baseline gap-2">
                    <span className="text-2xl font-bold text-text-primary tabular-nums leading-none">{dayNum}</span>
                    <span className="text-[12px] font-medium text-text-secondary">
                      {isToday ? 'Today' : isTomorrow ? 'Tomorrow' : weekday}
                    </span>
                    <span className="text-[10px] text-text-tertiary">{month}</span>
                  </div>
                </div>
                <EventBanners events={dayEvents} />
                <RenderGroups nodes={grouped} keywords={keywords} isDoneState={isDoneState} clockStatus={clockStatus} onRefresh={onRefresh} onRefreshClock={onRefreshClock} />
              </div>
            );
          })

        ) : filter.type === 'file' ? (
          /* ========== FILE VIEW ========== */
          topLevel.map(task => (
            <div key={task.id}>
              <TaskItem task={task} keywords={keywords} isDoneState={isDoneState} clockStatus={clockStatus} onRefresh={onRefresh} onRefreshClock={onRefreshClock} />
              {children.get(task.id)?.map(child => (
                <div key={child.id} className="pl-8">
                  <TaskItem task={child} keywords={keywords} isDoneState={isDoneState} clockStatus={clockStatus} onRefresh={onRefresh} onRefreshClock={onRefreshClock} />
                </div>
              ))}
            </div>
          ))

        ) : (
          /* ========== OTHER VIEWS ========== */
          <RenderGroups
            nodes={multiGroup(items, activeGroups)}
            keywords={keywords}
            isDoneState={isDoneState}
            clockStatus={clockStatus}
            onRefresh={onRefresh}
            onRefreshClock={onRefreshClock}
          />
        )}
      </div>
    </main>
  );
}
