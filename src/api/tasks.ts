import type { OrgTask, OrgTimestamp, AgendaEntry, AgendaFile, TodoKeywords, OrgConfig, CaptureTemplate, Clock, Habit, HabitCadenceSpec } from '../types';

const FALLBACK_BASE = '/api';

export interface EavSettings {
  serverURL?: string;
  hideDeadlinesInToday?: boolean;
  showHabitsInToday?: boolean;
  themeMode?: string;
}

export function loadSettings(): EavSettings {
  try {
    return JSON.parse(localStorage.getItem('eav-settings') || '{}') as EavSettings;
  } catch {
    return {};
  }
}

export function saveSettings(patch: Partial<EavSettings>): EavSettings {
  const current = loadSettings();
  const next = { ...current, ...patch };
  localStorage.setItem('eav-settings', JSON.stringify(next));
  return next;
}

export function getApiBase(): string {
  try {
    const s = loadSettings();
    if (s.serverURL && s.serverURL.trim()) {
      return s.serverURL.replace(/\/$/, '') + '/api';
    }
  } catch { /* ignore */ }
  return FALLBACK_BASE;
}

export async function fetchTasks(all = false): Promise<OrgTask[]> {
  const res = await fetch(`${getApiBase()}/tasks${all ? '?all=true' : ''}`);
  if (!res.ok) throw new Error('Failed to fetch tasks');
  return res.json();
}

export async function fetchFiles(): Promise<AgendaFile[]> {
  const res = await fetch(`${getApiBase()}/files`);
  if (!res.ok) throw new Error('Failed to fetch files');
  return res.json();
}

export async function fetchKeywords(): Promise<TodoKeywords> {
  const res = await fetch(`${getApiBase()}/keywords`);
  if (!res.ok) throw new Error('Failed to fetch keywords');
  return res.json();
}

export async function fetchConfig(): Promise<OrgConfig> {
  const res = await fetch(`${getApiBase()}/config`);
  if (!res.ok) throw new Error('Failed to fetch config');
  return res.json();
}

export async function fetchAgendaDay(date: string): Promise<AgendaEntry[]> {
  const res = await fetch(`${getApiBase()}/agenda/day/${date}`);
  if (!res.ok) throw new Error('Failed to fetch agenda day');
  return res.json();
}

export async function fetchAgendaRange(start: string, end: string): Promise<AgendaEntry[]> {
  const res = await fetch(`${getApiBase()}/agenda/range?start=${start}&end=${end}`);
  if (!res.ok) throw new Error('Failed to fetch agenda range');
  return res.json();
}

export interface HeadingNotes {
  notes: string;
  activeTimestamps: OrgTimestamp[];
}

export async function fetchNotes(file: string, pos: number): Promise<HeadingNotes> {
  const res = await fetch(`${getApiBase()}/notes?file=${encodeURIComponent(file)}&pos=${pos}`);
  if (!res.ok) throw new Error('Failed to fetch notes');
  const data = await res.json();
  return { notes: data.notes ?? '', activeTimestamps: data.activeTimestamps ?? [] };
}

export interface ClockStatus {
  clocking: boolean;
  file?: string;
  pos?: number;
  heading?: string;
  startTime?: string;
  elapsed?: number;
}

export async function fetchClockStatus(): Promise<ClockStatus> {
  const res = await fetch(`${getApiBase()}/clock`);
  if (!res.ok) throw new Error('Failed to fetch clock status');
  return res.json();
}

export async function logClockEntry(
  apiBase: string,
  file: string,
  pos: number,
  start: number,
  end: number,
): Promise<void> {
  const res = await fetch(`${apiBase}/clock/log`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ file, pos, start, end }),
  });
  if (!res.ok) throw new Error('Failed to log clock entry');
}

export async function clockIn(file: string, pos: number, title?: string): Promise<Clock> {
  const res = await fetch(`${getApiBase()}/clock/in`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ file, pos, title }),
  });
  if (!res.ok) throw new Error('Failed to clock in');
  return res.json();
}

export async function clockInHabit(id: string, title?: string): Promise<Clock> {
  const res = await fetch(`${getApiBase()}/clock/in`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ taskId: id, title }),
  });
  if (!res.ok) throw new Error('Failed to clock in habit');
  return res.json();
}

export async function clockOut(id: number): Promise<void> {
  const res = await fetch(`${getApiBase()}/clock/out`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ id }),
  });
  if (!res.ok) throw new Error('Failed to clock out');
}

export async function fetchActiveClocks(): Promise<Clock[]> {
  const res = await fetch(`${getApiBase()}/clock/active`);
  if (!res.ok) throw new Error('Failed to fetch active clocks');
  return res.json();
}

export async function cancelClock(id: number): Promise<void> {
  const res = await fetch(`${getApiBase()}/clock/${id}`, {
    method: 'DELETE',
  });
  if (!res.ok) throw new Error('Failed to cancel clock');
}

export interface CreateHabitBody {
  title: string;
  cadence: HabitCadenceSpec;
  category?: string;
  priority?: string;
  tags?: string[];
  notes?: string;
  anchorDate?: string;
  resetChecklistOnComplete?: boolean;
}

export async function fetchHabits(): Promise<Habit[]> {
  const res = await fetch(`${getApiBase()}/habits`);
  if (!res.ok) throw new Error('Failed to fetch habits');
  return res.json();
}

export async function createHabit(body: CreateHabitBody): Promise<Habit> {
  const res = await fetch(`${getApiBase()}/habits`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error('Failed to create habit');
  return res.json();
}

export async function updateHabit(id: string, body: Partial<CreateHabitBody>): Promise<Habit> {
  const res = await fetch(`${getApiBase()}/habits/${encodeURIComponent(id)}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error('Failed to update habit');
  return res.json();
}

export async function deleteHabit(id: string): Promise<void> {
  const res = await fetch(`${getApiBase()}/habits/${encodeURIComponent(id)}`, {
    method: 'DELETE',
  });
  if (!res.ok) throw new Error('Failed to delete habit');
}

export async function completeHabit(id: string, ts?: string): Promise<Habit> {
  const res = await fetch(`${getApiBase()}/habits/${encodeURIComponent(id)}/complete`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(ts ? { ts } : {}),
  });
  if (!res.ok) throw new Error('Failed to complete habit');
  return res.json();
}

export async function uncompleteHabit(id: string, ts: string): Promise<Habit> {
  const res = await fetch(`${getApiBase()}/habits/${encodeURIComponent(id)}/uncomplete`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ ts }),
  });
  if (!res.ok) throw new Error('Failed to uncomplete habit');
  return res.json();
}

export async function skipHabit(id: string): Promise<Habit> {
  const res = await fetch(`${getApiBase()}/habits/${encodeURIComponent(id)}/skip`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({}),
  });
  if (!res.ok) throw new Error('Failed to skip habit');
  return res.json();
}

export async function rescheduleHabit(id: string, date: string): Promise<Habit> {
  const res = await fetch(`${getApiBase()}/habits/${encodeURIComponent(id)}/reschedule`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ date }),
  });
  if (!res.ok) throw new Error('Failed to reschedule habit');
  return res.json();
}

export async function saveNotes(file: string, pos: number, notes: string): Promise<string> {
  const res = await fetch(`${getApiBase()}/notes`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ file, pos, notes }),
  });
  if (!res.ok) throw new Error('Failed to save notes');
  const data = await res.json();
  return data.notes ?? notes;
}

export interface RefileTarget {
  name: string;
  file: string;
  pos: number;
}

export async function fetchRefileTargets(): Promise<RefileTarget[]> {
  const res = await fetch(`${getApiBase()}/refile/targets`);
  if (!res.ok) throw new Error('Failed to fetch refile targets');
  return res.json();
}

export async function refileTask(
  sourceFile: string, sourcePos: number, targetFile: string, targetPos: number,
): Promise<void> {
  const res = await fetch(`${getApiBase()}/refile`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ sourceFile, sourcePos, targetFile, targetPos }),
  });
  if (!res.ok) throw new Error('Failed to refile task');
}

export async function archiveTask(task: OrgTask | { id: string; file: string; pos: number }): Promise<void> {
  const res = await fetch(`${getApiBase()}/tasks/${encodeURIComponent(task.id)}/archive`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ file: task.file, pos: task.pos }),
  });
  if (!res.ok) throw new Error('Failed to archive task');
}

export async function updateTitle(task: OrgTask | { file: string; pos: number; id: string }, title: string): Promise<void> {
  const res = await fetch(`${getApiBase()}/tasks/${encodeURIComponent(task.id)}/title`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ file: task.file, pos: task.pos, title }),
  });
  if (!res.ok) throw new Error('Failed to update title');
}

export async function updateTodoState(task: OrgTask, state: string): Promise<void> {
  const res = await fetch(`${getApiBase()}/tasks/${encodeURIComponent(task.id)}/state`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ file: task.file, pos: task.pos, state }),
  });
  if (!res.ok) throw new Error('Failed to update state');
}

export async function updatePriority(task: OrgTask, priority: string): Promise<void> {
  const res = await fetch(`${getApiBase()}/tasks/${encodeURIComponent(task.id)}/priority`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ file: task.file, pos: task.pos, priority }),
  });
  if (!res.ok) throw new Error('Failed to update priority');
}

export async function updateTags(task: OrgTask, tags: string[]): Promise<void> {
  const res = await fetch(`${getApiBase()}/tasks/${encodeURIComponent(task.id)}/tags`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ file: task.file, pos: task.pos, tags }),
  });
  if (!res.ok) throw new Error('Failed to update tags');
}

export async function updateScheduled(task: OrgTask, timestamp: string): Promise<void> {
  const res = await fetch(`${getApiBase()}/tasks/${encodeURIComponent(task.id)}/scheduled`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ file: task.file, pos: task.pos, timestamp }),
  });
  if (!res.ok) throw new Error('Failed to update scheduled');
}

export async function updateDeadline(task: OrgTask, timestamp: string): Promise<void> {
  const res = await fetch(`${getApiBase()}/tasks/${encodeURIComponent(task.id)}/deadline`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ file: task.file, pos: task.pos, timestamp }),
  });
  if (!res.ok) throw new Error('Failed to update deadline');
}

export async function fetchCaptureTemplates(): Promise<CaptureTemplate[]> {
  const res = await fetch(`${getApiBase()}/capture/templates`);
  if (!res.ok) throw new Error('Failed to fetch capture templates');
  return res.json();
}

export async function captureTask(
  templateKey: string,
  title: string,
  options?: { priority?: string; scheduled?: string; deadline?: string },
): Promise<void> {
  const res = await fetch(`${getApiBase()}/capture`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ templateKey, title, ...options }),
  });
  if (!res.ok) throw new Error('Failed to capture task');
}

export async function setEffort(task: OrgTask | { id: string; file: string; pos: number }, value: string): Promise<void> {
  const res = await fetch(`${getApiBase()}/tasks/${encodeURIComponent(task.id)}/property`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ file: task.file, pos: task.pos, name: 'EFFORT', value }),
  });
  if (!res.ok) throw new Error('Failed to set effort');
}

/** Returns today's date as YYYY-MM-DD in local time, matching how the user reads dates in org files. */
export function todayYMD(): string {
  const d = new Date();
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return `${y}-${m}-${day}`;
}

export async function setPinned(task: OrgTask | { id: string; file: string; pos: number }, pinned: boolean): Promise<void> {
  const value = pinned ? todayYMD() : '';
  const res = await fetch(`${getApiBase()}/tasks/${encodeURIComponent(task.id)}/property`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ file: task.file, pos: task.pos, name: 'PINNED', value }),
  });
  if (!res.ok) throw new Error('Failed to set pinned');
}
