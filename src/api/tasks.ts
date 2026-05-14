import type { OrgTask, OrgTimestamp, AgendaEntry, AgendaFile, TodoKeywords, OrgConfig, CaptureTemplate } from '../types';

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

export async function clockIn(file: string, pos: number): Promise<void> {
  const res = await fetch(`${getApiBase()}/clock/in`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ file, pos }),
  });
  if (!res.ok) throw new Error('Failed to clock in');
}

export async function clockOutApi(): Promise<void> {
  const res = await fetch(`${getApiBase()}/clock/out`, { method: 'POST' });
  if (!res.ok) throw new Error('Failed to clock out');
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
