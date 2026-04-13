import path from 'path';
import { fileURLToPath } from 'url';
import express from 'express';
import cors from 'cors';
import {
  getActiveTasks,
  getAllTasks,
  getAgendaFiles,
  getAgendaDay,
  getAgendaRange,
  getTodoKeywords,
  getConfig,
  setTodoState,
  setPriority,
  setTags,
  setScheduled,
  setDeadline,
  refileTask,
  getHeadingNotes,
  setHeadingNotes,
  getClockStatus,
  clockIn,
  clockOut,
  getCaptureTemplates,
  executeCapture,
} from './emacs.js';

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

// GET /api/notes - get heading notes by file+pos
app.get('/api/notes', async (req, res) => {
  try {
    const { file, pos } = req.query;
    if (!file || !pos) {
      res.status(400).json({ error: 'file and pos query params required' });
      return;
    }
    const notes = await getHeadingNotes(file as string, parseInt(pos as string));
    res.json({ notes });
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
    await setHeadingNotes(file, pos, notes || '');
    res.json({ success: true });
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
    const { templateKey, title } = req.body;
    if (!templateKey || !title) {
      res.status(400).json({ error: 'templateKey and title are required' });
      return;
    }
    await executeCapture(templateKey, title);
    res.json({ success: true });
  } catch (err) {
    console.error('Failed to capture:', err);
    res.status(500).json({ error: 'Failed to capture task' });
  }
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
