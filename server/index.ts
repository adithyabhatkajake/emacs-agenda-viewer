import path from 'path';
import { fileURLToPath } from 'url';
import express from 'express';
import cors from 'cors';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import {
  getActiveTasks,
  getAllTasks,
  getAgendaFiles,
  getAgendaDay,
  getAgendaRange,
  getTodoKeywords,
  getPriorities,
  getConfig,
  getListConfig,
  getRefileTargets,
  refileToTarget,
  setTitle,
  setTodoState,
  setPriority,
  setTags,
  setScheduled,
  setDeadline,
  setProperty,
  refileTask,
  getHeadingNotes,
  setHeadingNotes,
  getClockStatus,
  clockIn,
  clockOut,
  addClockEntry,
  tidyClocks,
  getCaptureTemplates,
  executeCapture,
  insertEntry,
  emacsEval,
} from './emacs.js';

const execFileAsync = promisify(execFile);

const app = express();
app.use(cors());
app.use(express.json());

// GET /api/tasks - get active tasks
app.get('/api/tasks', async (_req, res) => {
  try {
    const showAll = _req.query.all === 'true';
    const tasks = showAll ? await getAllTasks() : await getActiveTasks();
    res.json(tasks);
  } catch (err) {
    console.error('Failed to fetch tasks:', err);
    res.status(500).json({ error: 'Failed to fetch tasks from Emacs' });
  }
});

// GET /api/files - get agenda files
app.get('/api/files', async (_req, res) => {
  try {
    const files = await getAgendaFiles();
    res.json(files);
  } catch (err) {
    console.error('Failed to fetch files:', err);
    res.status(500).json({ error: 'Failed to fetch agenda files' });
  }
});

// GET /api/keywords - get TODO keywords config
app.get('/api/keywords', async (_req, res) => {
  try {
    const keywords = await getTodoKeywords();
    res.json(keywords);
  } catch (err) {
    console.error('Failed to fetch keywords:', err);
    res.status(500).json({ error: 'Failed to fetch TODO keywords' });
  }
});

// GET /api/priorities - get priority range config
app.get('/api/priorities', async (_req, res) => {
  try {
    const priorities = await getPriorities();
    res.json(priorities);
  } catch (err) {
    console.error('Failed to fetch priorities:', err);
    res.status(500).json({ error: 'Failed to fetch priorities' });
  }
});

// GET /api/config - get org configuration
app.get('/api/config', async (_req, res) => {
  try {
    const config = await getConfig();
    res.json(config);
  } catch (err) {
    console.error('Failed to fetch config:', err);
    res.status(500).json({ error: 'Failed to fetch org config' });
  }
});

// GET /api/list-config - get org plain-list configuration
app.get('/api/list-config', async (_req, res) => {
  try {
    const config = await getListConfig();
    res.json(config);
  } catch (err) {
    console.error('Failed to fetch list config:', err);
    res.status(500).json({ error: 'Failed to fetch list config' });
  }
});

// GET /api/notes - get heading notes by file+pos
app.get('/api/notes', async (req, res) => {
  try {
    const { file, pos } = req.query;
    if (!file || !pos) {
      res.status(400).json({ error: 'file and pos query params required' });
      return;
    }
    const result = await getHeadingNotes(file as string, parseInt(pos as string));
    res.json(result);
  } catch (err) {
    console.error('Failed to fetch notes:', err);
    res.status(500).json({ error: 'Failed to fetch notes' });
  }
});

// GET /api/clock - get current clock status
app.get('/api/clock', async (_req, res) => {
  try {
    const status = await getClockStatus();
    res.json(status);
  } catch (err) {
    console.error('Failed to get clock status:', err);
    res.status(500).json({ error: 'Failed to get clock status' });
  }
});

// POST /api/clock/in - clock in to a task
app.post('/api/clock/in', async (req, res) => {
  try {
    const { file, pos } = req.body;
    await clockIn(file, pos);
    res.json({ success: true });
  } catch (err) {
    console.error('Failed to clock in:', err);
    res.status(500).json({ error: 'Failed to clock in' });
  }
});

// POST /api/clock/log - append a completed clock entry to a task's LOGBOOK
app.post('/api/clock/log', async (req, res) => {
  try {
    const { file, pos, start, end } = req.body;
    if (!file || pos === undefined || !start || !end) {
      res.status(400).json({ error: 'file, pos, start, end (epoch seconds) required' });
      return;
    }
    await addClockEntry(file, pos, Number(start), Number(end));
    res.json({ success: true });
  } catch (err) {
    console.error('Failed to log clock entry:', err);
    res.status(500).json({ error: 'Failed to log clock entry' });
  }
});

// POST /api/clock/tidy - sweep loose CLOCK lines on a heading into LOGBOOK
app.post('/api/clock/tidy', async (req, res) => {
  try {
    const { file, pos } = req.body;
    if (!file || pos === undefined) {
      res.status(400).json({ error: 'file, pos required' });
      return;
    }
    const moved = await tidyClocks(file, Number(pos));
    res.json({ success: true, moved });
  } catch (err) {
    console.error('Failed to tidy clocks:', err);
    res.status(500).json({ error: 'Failed to tidy clocks' });
  }
});

// POST /api/clock/out - clock out
app.post('/api/clock/out', async (_req, res) => {
  try {
    await clockOut();
    res.json({ success: true });
  } catch (err) {
    console.error('Failed to clock out:', err);
    res.status(500).json({ error: 'Failed to clock out' });
  }
});

// PUT /api/notes - set heading notes
app.put('/api/notes', async (req, res) => {
  try {
    const { file, pos, notes } = req.body;
    if (!file || pos === undefined) {
      res.status(400).json({ error: 'file and pos required' });
      return;
    }
    const finalNotes = await setHeadingNotes(file, pos, notes || '');
    res.json({ success: true, notes: finalNotes });
  } catch (err) {
    console.error('Failed to set notes:', err);
    res.status(500).json({ error: 'Failed to set notes' });
  }
});

// GET /api/agenda/day/:date - get agenda entries for a specific day (uses org-agenda machinery)
app.get('/api/agenda/day/:date', async (req, res) => {
  try {
    const entries = await getAgendaDay(req.params.date);
    res.json(entries);
  } catch (err) {
    console.error('Failed to fetch agenda day:', err);
    res.status(500).json({ error: 'Failed to fetch agenda day' });
  }
});

// GET /api/agenda/range?start=YYYY-MM-DD&end=YYYY-MM-DD
app.get('/api/agenda/range', async (req, res) => {
  try {
    const { start, end } = req.query;
    if (!start || !end) {
      res.status(400).json({ error: 'start and end query params required' });
      return;
    }
    const entries = await getAgendaRange(start as string, end as string);
    res.json(entries);
  } catch (err) {
    console.error('Failed to fetch agenda range:', err);
    res.status(500).json({ error: 'Failed to fetch agenda range' });
  }
});

// GET /api/refile/targets - get refile targets
app.get('/api/refile/targets', async (_req, res) => {
  try {
    const targets = await getRefileTargets();
    res.json(targets);
  } catch (err) {
    console.error('Failed to get refile targets:', err);
    res.status(500).json({ error: 'Failed to get refile targets' });
  }
});

// POST /api/refile - refile a task
app.post('/api/refile', async (req, res) => {
  try {
    const { sourceFile, sourcePos, targetFile, targetPos } = req.body;
    if (!sourceFile || sourcePos === undefined || !targetFile || targetPos === undefined) {
      res.status(400).json({ error: 'sourceFile, sourcePos, targetFile, targetPos required' });
      return;
    }
    await refileToTarget(sourceFile, sourcePos, targetFile, targetPos);
    res.json({ success: true });
  } catch (err) {
    console.error('Failed to refile:', err);
    res.status(500).json({ error: 'Failed to refile task' });
  }
});

// PATCH /api/tasks/:id/title - change heading title
app.patch('/api/tasks/:id/title', async (req, res) => {
  try {
    const { file, pos, title } = req.body;
    await setTitle(file, pos, title);
    res.json({ success: true });
  } catch (err) {
    console.error('Failed to set title:', err);
    res.status(500).json({ error: 'Failed to set title' });
  }
});

// PATCH /api/tasks/:id/state - change TODO state
app.patch('/api/tasks/:id/state', async (req, res) => {
  try {
    const { file, pos, state } = req.body;
    await setTodoState(file, pos, state);
    res.json({ success: true });
  } catch (err) {
    console.error('Failed to set state:', err);
    res.status(500).json({ error: 'Failed to set TODO state' });
  }
});

// PATCH /api/tasks/:id/priority - change priority
app.patch('/api/tasks/:id/priority', async (req, res) => {
  try {
    const { file, pos, priority } = req.body;
    await setPriority(file, pos, priority);
    res.json({ success: true });
  } catch (err) {
    console.error('Failed to set priority:', err);
    res.status(500).json({ error: 'Failed to set priority' });
  }
});

// PATCH /api/tasks/:id/tags - change tags
app.patch('/api/tasks/:id/tags', async (req, res) => {
  try {
    const { file, pos, tags } = req.body;
    await setTags(file, pos, tags);
    res.json({ success: true });
  } catch (err) {
    console.error('Failed to set tags:', err);
    res.status(500).json({ error: 'Failed to set tags' });
  }
});

// PATCH /api/tasks/:id/scheduled - set scheduled date
app.patch('/api/tasks/:id/scheduled', async (req, res) => {
  try {
    const { file, pos, timestamp } = req.body;
    await setScheduled(file, pos, timestamp);
    res.json({ success: true });
  } catch (err) {
    console.error('Failed to set scheduled:', err);
    res.status(500).json({ error: 'Failed to set scheduled date' });
  }
});

// PATCH /api/tasks/:id/property - set/clear a custom org property
app.patch('/api/tasks/:id/property', async (req, res) => {
  try {
    const { file, pos, key, value } = req.body;
    if (!file || pos === undefined || !key) {
      res.status(400).json({ error: 'file, pos, key required' });
      return;
    }
    await setProperty(file, pos, key, value || '');
    res.json({ success: true });
  } catch (err) {
    console.error('Failed to set property:', err);
    res.status(500).json({ error: 'Failed to set property' });
  }
});

// PATCH /api/tasks/:id/deadline - set deadline
app.patch('/api/tasks/:id/deadline', async (req, res) => {
  try {
    const { file, pos, timestamp } = req.body;
    await setDeadline(file, pos, timestamp);
    res.json({ success: true });
  } catch (err) {
    console.error('Failed to set deadline:', err);
    res.status(500).json({ error: 'Failed to set deadline' });
  }
});

// POST /api/tasks/:id/refile - refile task
app.post('/api/tasks/:id/refile', async (req, res) => {
  try {
    const { sourceFile, sourcePos, targetFile, targetPos } = req.body;
    await refileTask(sourceFile, sourcePos, targetFile, targetPos);
    res.json({ success: true });
  } catch (err) {
    console.error('Failed to refile:', err);
    res.status(500).json({ error: 'Failed to refile task' });
  }
});

// GET /api/capture/templates - get capture templates
app.get('/api/capture/templates', async (_req, res) => {
  try {
    const templates = await getCaptureTemplates();
    res.json(templates);
  } catch (err) {
    console.error('Failed to fetch capture templates:', err);
    res.status(500).json({ error: 'Failed to fetch capture templates' });
  }
});

// POST /api/capture - execute a capture
app.post('/api/capture', async (req, res) => {
  try {
    const { templateKey, title, priority, scheduled, deadline, promptAnswers } = req.body;
    if (!templateKey || !title) {
      res.status(400).json({ error: 'templateKey and title are required' });
      return;
    }
    await executeCapture(templateKey, title, priority, scheduled, deadline, promptAnswers);
    res.json({ success: true });
  } catch (err) {
    console.error('Failed to capture:', err);
    res.status(500).json({ error: 'Failed to capture task' });
  }
});

// POST /api/insert-entry - insert a pre-built org entry at a target location
app.post('/api/insert-entry', async (req, res) => {
  try {
    const { file, targetType, entryText, headline, olp, prepend } = req.body;
    if (!file || !targetType || !entryText) {
      res.status(400).json({ error: 'file, targetType, and entryText are required' });
      return;
    }
    await insertEntry(file, targetType, entryText, headline, olp, prepend);
    res.json({ success: true });
  } catch (err) {
    console.error('Failed to insert entry:', err);
    res.status(500).json({ error: 'Failed to insert entry' });
  }
});

// GET /api/debug - system diagnostics for verifying deployment parity
app.get('/api/debug', async (_req, res) => {
  async function shellCmd(cmd: string, args: string[]): Promise<string> {
    try {
      const { stdout } = await execFileAsync(cmd, args, { timeout: 5000 });
      return stdout.trim();
    } catch {
      return 'unavailable';
    }
  }

  const [emacsVersion, emacsPlusVersion, doomCommit, nodeVersion] = await Promise.all([
    emacsEval('(emacs-version)').catch(() => 'unavailable'),
    shellCmd('brew', ['list', '--versions', 'emacs-plus@30']),
    shellCmd('git', ['-C', path.join(process.env.HOME || '', '.config', 'emacs'), 'rev-parse', '--short', 'HEAD']),
    process.version,
  ]);

  res.json({
    emacsVersion,
    emacsPlusVersion,
    doomCommit,
    nodeVersion,
    platform: process.platform,
    arch: process.arch,
    pid: process.pid,
    uptime: Math.floor(process.uptime()),
  });
});

// Serve built frontend in production
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const distPath = path.join(__dirname, '..', 'dist');
app.use(express.static(distPath));
app.get('/{*path}', (_req, res) => {
  res.sendFile(path.join(distPath, 'index.html'));
});

const PORT = process.env.PORT || 3001;
const HOST = process.env.HOST || '0.0.0.0';
app.listen(Number(PORT), HOST, () => {
  console.log(`EAV server running on http://${HOST}:${PORT}`);
});
