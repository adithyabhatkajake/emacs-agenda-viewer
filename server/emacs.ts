import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { readFile, unlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const execFileAsync = promisify(execFile);

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const EAV_EL_PATH = path.join(__dirname, '..', 'elisp', 'eav.el');

let loaded = false;

async function ensureLoaded(): Promise<void> {
  if (loaded) return;
  try {
    await emacsEval(`(load-file "${EAV_EL_PATH}")`);
    loaded = true;
  } catch {
    loaded = false;
    throw new Error('Failed to load eav.el into Emacs');
  }
}

export async function emacsEval(expr: string): Promise<string> {
  const { stdout } = await execFileAsync('emacsclient', ['--eval', expr], {
    maxBuffer: 50 * 1024 * 1024,
    timeout: 30000,
  });
  return stdout.trim();
}

/**
 * Call an eav elisp function that returns JSON.
 * Writes JSON to a temp file to avoid control character issues
 * with emacsclient's stdout quoting.
 */
async function eavCall<T>(expr: string): Promise<T> {
  await ensureLoaded();
  const tmpFile = path.join(tmpdir(), `eav-${Date.now()}-${Math.random().toString(36).slice(2)}.json`);
  // Have Emacs write JSON directly to a temp file
  await emacsEval(
    `(let ((json-str ${expr})) (with-temp-file "${tmpFile}" (insert json-str)) nil)`
  );
  try {
    const content = await readFile(tmpFile, 'utf-8');
    return JSON.parse(content) as T;
  } finally {
    unlink(tmpFile).catch(() => {});
  }
}

export interface OrgTimestamp {
  raw: string;
  date: string;
  repeater?: {
    type: string;
    value: number;
    unit: string;
  };
  warning?: {
    value: number;
    unit: string;
  };
}

export interface OrgTask {
  id: string;
  title: string;
  todoState?: string;
  priority?: string;
  tags: string[];
  inheritedTags: string[];
  scheduled?: OrgTimestamp;
  deadline?: OrgTimestamp;
  closed?: string;
  category: string;
  level: number;
  file: string;
  pos: number;
  parentId?: string;
  effort?: string;
  notes?: string;
  activeTimestamps?: OrgTimestamp[];
}

export interface AgendaEntry {
  id: string;
  title: string;
  agendaType: string; // "scheduled" | "deadline" | "upcoming-deadline" | "timestamp" | "sexp" | "todo"
  todoState?: string;
  priority?: string;
  tags: string[];
  inheritedTags: string[];
  scheduled?: OrgTimestamp;
  deadline?: OrgTimestamp;
  category: string;
  level: number;
  file: string;
  pos: number;
  effort?: string;
  warntime?: string;
  timeOfDay?: string;
  displayDate?: string;
}

export interface OrgConfig {
  deadlineWarningDays: number;
}

export interface AgendaFile {
  path: string;
  name: string;
  category: string;
}

export interface TodoKeywords {
  sequences: Array<{
    active: string[];
    done: string[];
  }>;
}

export async function getAllTasks(): Promise<OrgTask[]> {
  return eavCall<OrgTask[]>('(eav-extract-all-tasks)');
}

export async function getActiveTasks(): Promise<OrgTask[]> {
  return eavCall<OrgTask[]>('(eav-extract-active-tasks)');
}

export async function getAgendaFiles(): Promise<AgendaFile[]> {
  return eavCall<AgendaFile[]>('(eav-get-agenda-files)');
}

export async function getTodoKeywords(): Promise<TodoKeywords> {
  return eavCall<TodoKeywords>('(eav-get-todo-keywords)');
}

export async function getConfig(): Promise<OrgConfig> {
  return eavCall<OrgConfig>('(eav-get-config)');
}

export interface ClockStatus {
  clocking: boolean;
  file?: string;
  pos?: number;
  heading?: string;
  startTime?: string;
  elapsed?: number;
}

export async function getClockStatus(): Promise<ClockStatus> {
  return eavCall<ClockStatus>('(eav-clock-status)');
}

export async function clockIn(file: string, pos: number): Promise<void> {
  await ensureLoaded();
  await emacsEval(`(eav-clock-in "${file}" ${pos})`);
}

export async function clockOut(): Promise<void> {
  await ensureLoaded();
  await emacsEval('(eav-clock-out)');
}

export async function getHeadingNotes(file: string, pos: number): Promise<string> {
  const result = await eavCall<{ notes: string }>(`(eav-get-heading-notes "${file}" ${pos})`);
  return result.notes;
}

export async function setHeadingNotes(file: string, pos: number, notes: string): Promise<void> {
  await ensureLoaded();
  // Escape the notes for elisp string
  const escaped = notes.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
  await emacsEval(`(eav-set-heading-notes "${file}" ${pos} "${escaped}")`);
}

export async function getAgendaDay(date: string): Promise<AgendaEntry[]> {
  return eavCall<AgendaEntry[]>(`(eav-get-agenda-day "${date}")`);
}

export async function getAgendaRange(startDate: string, endDate: string): Promise<AgendaEntry[]> {
  return eavCall<AgendaEntry[]>(`(eav-get-agenda-range "${startDate}" "${endDate}")`);
}

export async function setTodoState(file: string, pos: number, state: string): Promise<void> {
  await ensureLoaded();
  const escaped = state.replace(/"/g, '\\"');
  await emacsEval(`(eav-set-todo-state "${file}" ${pos} "${escaped}")`);
}

export async function setPriority(file: string, pos: number, priority: string): Promise<void> {
  await ensureLoaded();
  await emacsEval(`(eav-set-priority "${file}" ${pos} "${priority}")`);
}

export async function setTags(file: string, pos: number, tags: string[]): Promise<void> {
  await ensureLoaded();
  const tagList = tags.map(t => `"${t}"`).join(' ');
  await emacsEval(`(eav-set-tags "${file}" ${pos} (list ${tagList}))`);
}

export async function setScheduled(file: string, pos: number, timestamp: string): Promise<void> {
  await ensureLoaded();
  await emacsEval(`(eav-set-scheduled "${file}" ${pos} "${timestamp}")`);
}

export async function setDeadline(file: string, pos: number, timestamp: string): Promise<void> {
  await ensureLoaded();
  await emacsEval(`(eav-set-deadline "${file}" ${pos} "${timestamp}")`);
}

export async function refileTask(
  sourceFile: string,
  sourcePos: number,
  targetFile: string,
  targetPos: number
): Promise<void> {
  await ensureLoaded();
  await emacsEval(
    `(eav-refile-task "${sourceFile}" ${sourcePos} "${targetFile}" ${targetPos})`
  );
}
