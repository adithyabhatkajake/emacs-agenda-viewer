import type { OrgTask, AgendaEntry, AgendaFile, TodoKeywords, OrgConfig, CaptureTemplate } from '../types';

const BASE = '/api';

export async function fetchTasks(all = false): Promise<OrgTask[]> {
  const res = await fetch(`${BASE}/tasks${all ? '?all=true' : ''}`);
  if (!res.ok) throw new Error('Failed to fetch tasks');
  return res.json();
}

export async function fetchFiles(): Promise<AgendaFile[]> {
  const res = await fetch(`${BASE}/files`);
  if (!res.ok) throw new Error('Failed to fetch files');
  return res.json();
}

export async function fetchKeywords(): Promise<TodoKeywords> {
  const res = await fetch(`${BASE}/keywords`);
  if (!res.ok) throw new Error('Failed to fetch keywords');
  return res.json();
}

export async function fetchConfig(): Promise<OrgConfig> {
  const res = await fetch(`${BASE}/config`);
  if (!res.ok) throw new Error('Failed to fetch config');
  return res.json();
}

export async function fetchAgendaDay(date: string): Promise<AgendaEntry[]> {
  const res = await fetch(`${BASE}/agenda/day/${date}`);
  if (!res.ok) throw new Error('Failed to fetch agenda day');
  return res.json();
}

export async function fetchAgendaRange(start: string, end: string): Promise<AgendaEntry[]> {
  const res = await fetch(`${BASE}/agenda/range?start=${start}&end=${end}`);
  if (!res.ok) throw new Error('Failed to fetch agenda range');
  return res.json();
}

export async function fetchNotes(file: string, pos: number): Promise<string> {
  const res = await fetch(`${BASE}/notes?file=${encodeURIComponent(file)}&pos=${pos}`);
  if (!res.ok) throw new Error('Failed to fetch notes');
  const data = await res.json();
  return data.notes;
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
  const res = await fetch(`${BASE}/clock`);
  if (!res.ok) throw new Error('Failed to fetch clock status');
  return res.json();
}

export async function clockIn(file: string, pos: number): Promise<void> {
  const res = await fetch(`${BASE}/clock/in`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ file, pos }),
  });
  if (!res.ok) throw new Error('Failed to clock in');
}

export async function clockOutApi(): Promise<void> {
  const res = await fetch(`${BASE}/clock/out`, { method: 'POST' });
  if (!res.ok) throw new Error('Failed to clock out');
}

export async function saveNotes(file: string, pos: number, notes: string): Promise<void> {
  const res = await fetch(`${BASE}/notes`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ file, pos, notes }),
  });
  if (!res.ok) throw new Error('Failed to save notes');
}

export async function updateTodoState(task: OrgTask, state: string): Promise<void> {
  const res = await fetch(`${BASE}/tasks/${encodeURIComponent(task.id)}/state`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ file: task.file, pos: task.pos, state }),
  });
  if (!res.ok) throw new Error('Failed to update state');
}

export async function updatePriority(task: OrgTask, priority: string): Promise<void> {
  const res = await fetch(`${BASE}/tasks/${encodeURIComponent(task.id)}/priority`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ file: task.file, pos: task.pos, priority }),
  });
  if (!res.ok) throw new Error('Failed to update priority');
}

export async function updateTags(task: OrgTask, tags: string[]): Promise<void> {
  const res = await fetch(`${BASE}/tasks/${encodeURIComponent(task.id)}/tags`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ file: task.file, pos: task.pos, tags }),
  });
  if (!res.ok) throw new Error('Failed to update tags');
}

export async function updateScheduled(task: OrgTask, timestamp: string): Promise<void> {
  const res = await fetch(`${BASE}/tasks/${encodeURIComponent(task.id)}/scheduled`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ file: task.file, pos: task.pos, timestamp }),
  });
  if (!res.ok) throw new Error('Failed to update scheduled');
}

export async function updateDeadline(task: OrgTask, timestamp: string): Promise<void> {
  const res = await fetch(`${BASE}/tasks/${encodeURIComponent(task.id)}/deadline`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ file: task.file, pos: task.pos, timestamp }),
  });
  if (!res.ok) throw new Error('Failed to update deadline');
}

export async function fetchCaptureTemplates(): Promise<CaptureTemplate[]> {
  const res = await fetch(`${BASE}/capture/templates`);
  if (!res.ok) throw new Error('Failed to fetch capture templates');
  return res.json();
}

export async function captureTask(templateKey: string, title: string): Promise<void> {
  const res = await fetch(`${BASE}/capture`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ templateKey, title }),
  });
  if (!res.ok) throw new Error('Failed to capture task');
}
