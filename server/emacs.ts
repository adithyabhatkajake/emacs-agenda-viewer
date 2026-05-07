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
function isVoidFunctionError(err: unknown): boolean {
  const msg = err instanceof Error ? err.message : String(err);
  return /void-function|Symbol.s function definition is void/i.test(msg);
}

async function eavCall<T>(expr: string): Promise<T> {
  return withReloadRetry(async () => {
    await ensureLoaded();
    const tmpFile = path.join(tmpdir(), `eav-${Date.now()}-${Math.random().toString(36).slice(2)}.json`);
    await emacsEval(
      `(let ((json-str ${expr})) (with-temp-file "${tmpFile}" (insert json-str)) nil)`
    );
    try {
      const content = await readFile(tmpFile, 'utf-8');
      return JSON.parse(content) as T;
    } finally {
      unlink(tmpFile).catch(() => {});
    }
  });
}

export async function withReloadRetry<T>(fn: () => Promise<T>): Promise<T> {
  try {
    return await fn();
  } catch (err) {
    if (!isVoidFunctionError(err)) throw err;
    loaded = false;
    return fn();
  }
}

async function eavExec(expr: string): Promise<void> {
  await withReloadRetry(async () => {
    await ensureLoaded();
    await emacsEval(expr);
  });
}

export interface OrgTimestampComponent {
  year: number;
  month: number;
  day: number;
  hour?: number;
  minute?: number;
}

export interface OrgTimestamp {
  raw: string;
  date: string;
  type?: string;
  rangeType?: string;
  start?: OrgTimestampComponent;
  end?: OrgTimestampComponent;
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
  properties?: Record<string, string>;
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

export interface OrgPriorities {
  highest: string;
  lowest: string;
  default: string;
}

export async function getPriorities(): Promise<OrgPriorities> {
  return eavCall<OrgPriorities>('(eav-get-priorities)');
}

export async function getConfig(): Promise<OrgConfig> {
  return eavCall<OrgConfig>('(eav-get-config)');
}

export interface OrgListConfig {
  allowAlphabetical: boolean;
}

export async function getListConfig(): Promise<OrgListConfig> {
  return eavCall<OrgListConfig>('(eav-get-list-config)');
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
  await eavExec(`(eav-clock-in "${file}" ${pos})`);
}

export async function clockOut(): Promise<void> {
  await eavExec('(eav-clock-out)');
}

export async function addClockEntry(
  file: string, pos: number, startEpoch: number, endEpoch: number,
): Promise<void> {
  await eavExec(
    `(eav-add-clock-entry "${file}" ${pos} ${Math.floor(startEpoch)} ${Math.floor(endEpoch)})`
  );
}

export async function tidyClocks(file: string, pos: number): Promise<number> {
  let movedOut = 0;
  await withReloadRetry(async () => {
    await ensureLoaded();
    const out = await emacsEval(`(eav-tidy-clocks "${file}" ${pos})`);
    try {
      const parsed = JSON.parse(out);
      movedOut = Number(parsed?.moved ?? 0);
    } catch {
      movedOut = 0;
    }
  });
  return movedOut;
}

export interface HeadingNotes {
  notes: string;
  activeTimestamps: OrgTimestamp[];
}

export async function getHeadingNotes(file: string, pos: number): Promise<HeadingNotes> {
  const result = await eavCall<HeadingNotes>(`(eav-get-heading-notes "${file}" ${pos})`);
  return { notes: result.notes ?? '', activeTimestamps: result.activeTimestamps ?? [] };
}

export interface OutlinePath {
  file: string;
  headings: string[];
}

export async function getOutlinePath(file: string, pos: number): Promise<OutlinePath> {
  const result = await eavCall<OutlinePath>(`(eav-get-outline-path "${file}" ${pos})`);
  return { file: result.file ?? '', headings: result.headings ?? [] };
}

export async function setHeadingNotes(file: string, pos: number, notes: string): Promise<string> {
  const escaped = notes.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
  const result = await eavCall<{ success: boolean; notes: string }>(
    `(eav-set-heading-notes "${file}" ${pos} "${escaped}")`
  );
  return result.notes;
}

export async function getAgendaDay(date: string): Promise<AgendaEntry[]> {
  return eavCall<AgendaEntry[]>(`(eav-get-agenda-day "${date}")`);
}

export async function getAgendaRange(startDate: string, endDate: string): Promise<AgendaEntry[]> {
  return eavCall<AgendaEntry[]>(`(eav-get-agenda-range "${startDate}" "${endDate}")`);
}

export interface RefileTarget {
  name: string;
  file: string;
  pos: number;
}

export async function getRefileTargets(): Promise<RefileTarget[]> {
  return eavCall<RefileTarget[]>('(eav-get-refile-targets)');
}

export async function refileToTarget(
  sourceFile: string, sourcePos: number, targetFile: string, targetPos: number,
): Promise<void> {
  await eavExec(`(eav-refile-to-target "${sourceFile}" ${sourcePos} "${targetFile}" ${targetPos})`);
}

export async function setTitle(file: string, pos: number, title: string): Promise<void> {
  const escaped = title.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
  await eavExec(`(eav-set-title "${file}" ${pos} "${escaped}")`);
}

export async function setTodoState(file: string, pos: number, state: string): Promise<void> {
  const escaped = state.replace(/"/g, '\\"');
  await eavExec(`(eav-set-todo-state "${file}" ${pos} "${escaped}")`);
}

export async function setPriority(file: string, pos: number, priority: string): Promise<void> {
  await eavExec(`(eav-set-priority "${file}" ${pos} "${priority}")`);
}

export async function setTags(file: string, pos: number, tags: string[]): Promise<void> {
  const tagList = tags.map(t => `"${t}"`).join(' ');
  await eavExec(`(eav-set-tags "${file}" ${pos} (list ${tagList}))`);
}

export async function setScheduled(file: string, pos: number, timestamp: string): Promise<void> {
  await eavExec(`(eav-set-scheduled "${file}" ${pos} "${timestamp}")`);
}

export async function setDeadline(file: string, pos: number, timestamp: string): Promise<void> {
  await eavExec(`(eav-set-deadline "${file}" ${pos} "${timestamp}")`);
}

export async function setProperty(file: string, pos: number, key: string, value: string): Promise<void> {
  // Escape double quotes in value/key
  const esc = (s: string) => s.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
  await eavExec(`(eav-set-property "${file}" ${pos} "${esc(key)}" "${esc(value)}")`);
}

export async function refileTask(
  sourceFile: string,
  sourcePos: number,
  targetFile: string,
  targetPos: number
): Promise<void> {
  await eavExec(
    `(eav-refile-task "${sourceFile}" ${sourcePos} "${targetFile}" ${targetPos})`
  );
}

export async function insertEntry(
  file: string, targetType: string, entryText: string,
  headline?: string, olp?: string[], prepend?: boolean,
): Promise<void> {
  const esc = (s: string) => s.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
  const headlineArg = headline ? `"${esc(headline)}"` : 'nil';
  const olpArg = olp && olp.length > 0
    ? `(list ${olp.map(h => `"${esc(h)}"`).join(' ')})`
    : 'nil';
  const prependArg = prepend ? 't' : 'nil';
  await eavExec(
    `(eav-insert-entry "${esc(file)}" "${esc(targetType)}" "${esc(entryText)}" ${headlineArg} ${olpArg} ${prependArg})`
  );
}

// ---- Capture ----

export interface CapturePrompt {
  name: string;
  type: 'string' | 'date' | 'tags' | 'property';
  options: string[];
}

export interface CaptureTemplate {
  key: string;
  description: string;
  type?: string;
  isGroup: boolean;
  targetType?: string;
  targetFile?: string;
  targetHeadline?: string;
  template?: string;
  templateIsFunction?: boolean;
  prompts?: CapturePrompt[];
  webSupported: boolean;
}

export async function getCaptureTemplates(): Promise<CaptureTemplate[]> {
  return eavCall<CaptureTemplate[]>('(eav-get-capture-templates)');
}

export async function executeCapture(
  templateKey: string,
  title: string,
  priority?: string,
  scheduled?: string,
  deadline?: string,
  promptAnswers?: string[],
): Promise<void> {
  const esc = (s: string) => s.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
  const priArg = priority ? `"${esc(priority)}"` : 'nil';
  const schArg = scheduled ? `"${esc(scheduled)}"` : 'nil';
  const dlArg = deadline ? `"${esc(deadline)}"` : 'nil';
  const answersArg = promptAnswers && promptAnswers.length > 0
    ? `(list ${promptAnswers.map(a => `"${esc(a)}"`).join(' ')})`
    : 'nil';
  await eavExec(`(eav-capture "${esc(templateKey)}" "${esc(title)}" ${priArg} ${schArg} ${dlArg} ${answersArg})`);
}
