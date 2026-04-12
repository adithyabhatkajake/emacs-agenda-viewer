import { useState } from 'react';
import type { OrgTask, AgendaEntry, TodoKeywords } from '../types';
import { updateTodoState, updatePriority, updateScheduled, updateDeadline, fetchNotes, saveNotes, clockIn, clockOutApi, type ClockStatus } from '../api/tasks';
import { TodoStateMenu } from './TodoStateMenu';
import { PriorityMenu } from './PriorityMenu';
import { DatePicker } from './DatePicker';
import { NotesRenderer, renderInline } from './NotesRenderer';

type DisplayItem = OrgTask | AgendaEntry;

interface TaskItemProps {
  task: DisplayItem;
  keywords: TodoKeywords | null;
  isDoneState: (state: string | undefined) => boolean;
  clockStatus: ClockStatus;
  onRefresh: () => void;
  onRefreshClock: () => void;
  agendaType?: string;
}

function formatTimestamp(ts: { raw: string; date: string; repeater?: { type: string; value: number; unit: string } } | undefined): string | null {
  if (!ts) return null;
  const match = ts.raw.match(/(\d{4})-(\d{2})-(\d{2})\s+\w+/);
  if (!match) return ts.raw;
  const date = new Date(parseInt(match[1]), parseInt(match[2]) - 1, parseInt(match[3]));
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  const diffDays = Math.floor((date.getTime() - today.getTime()) / 86400000);

  let dateStr: string;
  if (diffDays === 0) dateStr = 'Today';
  else if (diffDays === 1) dateStr = 'Tomorrow';
  else if (diffDays === -1) dateStr = 'Yesterday';
  else if (diffDays < -1) dateStr = `${Math.abs(diffDays)}d overdue`;
  else if (diffDays <= 7) dateStr = date.toLocaleDateString('en-US', { weekday: 'short' });
  else dateStr = date.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });

  if (ts.repeater) {
    const unitLabel: Record<string, string> = { h: 'hr', d: 'day', w: 'wk', m: 'mo', y: 'yr' };
    dateStr += ` \u21BB${ts.repeater.value}${unitLabel[ts.repeater.unit] || ts.repeater.unit}`;
  }

  return dateStr;
}

function isOverdue(ts: { raw: string } | undefined): boolean {
  if (!ts) return false;
  const match = ts.raw.match(/(\d{4})-(\d{2})-(\d{2})/);
  if (!match) return false;
  const date = new Date(parseInt(match[1]), parseInt(match[2]) - 1, parseInt(match[3]));
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  return date < today;
}

export function TaskItem({ task, keywords, isDoneState, clockStatus, onRefresh, onRefreshClock, agendaType }: TaskItemProps) {
  const [updating, setUpdating] = useState(false);
  const [expanded, setExpanded] = useState(false);
  const [notes, setNotes] = useState<string | null>(null);
  const [loadingNotes, setLoadingNotes] = useState(false);
  const [editing, setEditing] = useState(false);
  const [editText, setEditText] = useState('');
  const [saving, setSaving] = useState(false);
  const done = isDoneState(task.todoState);

  const toggleExpand = async () => {
    if (expanded) {
      setExpanded(false);
      setEditing(false);
      return;
    }
    setExpanded(true);
    if (notes === null && task.file && task.pos) {
      setLoadingNotes(true);
      try {
        const n = await fetchNotes(task.file, task.pos);
        setNotes(n);
      } catch {
        setNotes('');
      } finally {
        setLoadingNotes(false);
      }
    }
  };

  const handleStateChange = async (newState: string) => {
    if (updating || newState === task.todoState) return;
    setUpdating(true);
    try { await updateTodoState(task, newState); onRefresh(); }
    catch (err) { console.error('Failed to set state:', err); }
    finally { setUpdating(false); }
  };

  const handlePriorityChange = async (newPriority: string) => {
    if (updating) return;
    setUpdating(true);
    try { await updatePriority(task, newPriority); onRefresh(); }
    catch (err) { console.error('Failed to set priority:', err); }
    finally { setUpdating(false); }
  };

  const handleScheduledChange = async (timestamp: string) => {
    if (updating) return;
    setUpdating(true);
    try { await updateScheduled(task, timestamp); onRefresh(); }
    catch (err) { console.error('Failed to set scheduled:', err); }
    finally { setUpdating(false); }
  };

  const handleDeadlineChange = async (timestamp: string) => {
    if (updating) return;
    setUpdating(true);
    try { await updateDeadline(task, timestamp); onRefresh(); }
    catch (err) { console.error('Failed to set deadline:', err); }
    finally { setUpdating(false); }
  };

  const handleClearScheduled = async () => {
    if (updating) return;
    setUpdating(true);
    try { await updateScheduled(task, ''); onRefresh(); }
    catch (err) { console.error('Failed to clear scheduled:', err); }
    finally { setUpdating(false); }
  };

  const handleClearDeadline = async () => {
    if (updating) return;
    setUpdating(true);
    try { await updateDeadline(task, ''); onRefresh(); }
    catch (err) { console.error('Failed to clear deadline:', err); }
    finally { setUpdating(false); }
  };

  const scheduledStr = formatTimestamp(task.scheduled);
  const deadlineStr = formatTimestamp(task.deadline);
  const deadlineOverdue = isOverdue(task.deadline);
  const isAgenda = 'agendaType' in task;
  const agendaEntry = isAgenda ? (task as AgendaEntry) : undefined;
  const timeOfDay = agendaEntry?.timeOfDay;
  const effectiveAgendaType = agendaType || agendaEntry?.agendaType;
  const orgExtra = agendaEntry?.extra;
  const tsDate = agendaEntry?.tsDate;
  const isClocked = clockStatus.clocking && clockStatus.file === task.file && clockStatus.pos === task.pos;

  return (
    <div
      className={`group border-b transition-colors ${
        isClocked ? 'border-done-green/20 bg-done-green/5' :
        expanded ? 'bg-things-surface/60 border-things-border-subtle/30' : 'border-things-border-subtle/30 hover:bg-things-sidebar-hover/30'
      } ${done ? 'opacity-40' : ''}`}
    >
      {/* Main row */}
      <div className="flex items-center gap-2 px-5 py-1.5">
        {/* State pill */}
        {task.todoState ? (
          <TodoStateMenu
            currentState={task.todoState}
            keywords={keywords}
            isDoneState={isDoneState}
            onSelect={handleStateChange}
            disabled={updating}
          />
        ) : (
          <span className="mt-px flex-shrink-0 rounded-md px-2 py-[3px] text-[10px] font-bold tracking-wide bg-text-tertiary/8 text-text-tertiary/60 border border-text-tertiary/10">
            {'\u2014'}
          </span>
        )}

        {/* Priority pill */}
        <PriorityMenu
          currentPriority={task.priority}
          onSelect={handlePriorityChange}
          disabled={updating}
        />

        {/* Main content — click to expand */}
        <div className="flex-1 min-w-0 cursor-pointer" onClick={toggleExpand}>
          {/* Title + inline metadata */}
          <span
            className={`text-[13px] leading-snug ${
              done ? 'line-through text-text-tertiary' : 'text-text-primary'
            }`}
          >
            {renderInline(task.title)}
          </span>
          <span className="flex items-center gap-2 mt-0.5 text-[10px] text-text-tertiary">
            {isAgenda && effectiveAgendaType && (
              <span className={
                effectiveAgendaType === 'deadline' ? 'text-priority-a' :
                effectiveAgendaType === 'upcoming-deadline' ? 'text-priority-b' :
                effectiveAgendaType === 'scheduled' ? 'text-accent' :
                ''
              }>
                {orgExtra || effectiveAgendaType}
              </span>
            )}
            {timeOfDay && <span className="text-accent-teal">{timeOfDay}</span>}
            {isAgenda && tsDate && <span>{(() => { const [y,m,d] = tsDate.split('-').map(Number); return new Date(y,m-1,d).toLocaleDateString('en-US',{month:'short',day:'numeric'}); })()}</span>}
            {!isAgenda && scheduledStr && <span>{scheduledStr}</span>}
            {!isAgenda && deadlineStr && <span className={deadlineOverdue ? 'text-priority-a' : ''}>{deadlineStr}</span>}
            {task.effort && <span>{task.effort}</span>}
            <span>{task.category}</span>
          </span>
        </div>
      </div>

      {/* Expanded detail panel */}
      {expanded && (
        <div className="px-5 pb-2 pt-0 ml-[62px]">
          {/* Notes header with edit toggle */}
          <div className="flex items-center gap-2 mb-1">
            <span className="text-[10px] text-text-tertiary uppercase tracking-wider font-semibold">Notes</span>
            <button
              onClick={() => {
                if (editing) {
                  setEditing(false);
                } else {
                  setEditText(notes || '');
                  setEditing(true);
                }
              }}
              className={`text-[11px] px-1.5 py-0.5 rounded transition-colors ${
                editing ? 'text-accent' : 'text-text-tertiary hover:text-text-secondary'
              }`}
              title={editing ? 'Cancel editing' : 'Edit notes'}
            >
              {editing ? '\u2715' : '\u270E'}
            </button>
          </div>

          {/* Notes display or editor */}
          {loadingNotes && (
            <p className="text-[11px] text-text-tertiary italic mb-2">Loading...</p>
          )}
          {editing ? (
            <div className="mb-2">
              <textarea
                value={editText}
                onChange={e => setEditText(e.target.value)}
                className="w-full bg-things-bg border border-things-border rounded-md px-3 py-2 text-[12px] text-text-primary font-mono leading-relaxed outline-none focus:border-accent/50 focus:ring-1 focus:ring-accent/30 resize-y min-h-[60px] [color-scheme:dark]"
                rows={Math.max(3, editText.split('\n').length + 1)}
                autoFocus
              />
              <div className="flex gap-2 mt-1.5">
                <button
                  onClick={async () => {
                    if (saving) return;
                    setSaving(true);
                    try {
                      await saveNotes(task.file, task.pos, editText);
                      setNotes(editText);
                      setEditing(false);
                    } catch (err) {
                      console.error('Failed to save notes:', err);
                    } finally {
                      setSaving(false);
                    }
                  }}
                  disabled={saving}
                  className="px-3 py-1 rounded-md bg-accent/20 text-accent text-[11px] font-medium hover:bg-accent/30 transition-colors disabled:opacity-50"
                >
                  {saving ? 'Saving...' : 'Save'}
                </button>
                <button
                  onClick={() => setEditing(false)}
                  className="px-3 py-1 rounded-md bg-things-surface text-text-secondary text-[11px] hover:bg-things-sidebar-hover transition-colors"
                >
                  Cancel
                </button>
              </div>
            </div>
          ) : (
            <>
              {notes !== null && notes.length > 0 && (
                <div className="mb-2">
                  <NotesRenderer
                    content={notes}
                    onToggleCheck={async (index) => {
                      if (!notes) return;
                      // Find the Nth checklist item in the raw text and toggle it
                      let count = 0;
                      const newNotes = notes.replace(
                        /^([ \t]*-\s+\[)([ Xx])(\]\s+)/gm,
                        (match, before, check, after) => {
                          if (count++ === index) {
                            const newCheck = check.toLowerCase() === 'x' ? ' ' : 'X';
                            return `${before}${newCheck}${after}`;
                          }
                          return match;
                        }
                      );
                      setNotes(newNotes);
                      try {
                        await saveNotes(task.file, task.pos, newNotes);
                      } catch (err) {
                        console.error('Failed to save checkbox toggle:', err);
                        setNotes(notes); // revert on failure
                      }
                    }}
                  />
                </div>
              )}
              {notes !== null && notes.length === 0 && !loadingNotes && (
                <button
                  onClick={() => { setEditText(''); setEditing(true); }}
                  className="text-[11px] text-text-tertiary hover:text-text-secondary mb-2 italic"
                >
                  + Add notes
                </button>
              )}
            </>
          )}

          {/* Date pickers + Clock */}
          <div className="flex items-center gap-2 mt-1">
            <DatePicker
              label="Scheduled"
              currentDate={task.scheduled?.raw}
              onSelect={handleScheduledChange}
              onClear={handleClearScheduled}
              disabled={updating}
              color="scheduled"
            />
            <DatePicker
              label="Deadline"
              currentDate={task.deadline?.raw}
              onSelect={handleDeadlineChange}
              onClear={handleClearDeadline}
              disabled={updating}
              color="deadline"
            />
            {task.todoState && (
              <button
                onClick={async () => {
                  try {
                    if (isClocked) {
                      await clockOutApi();
                    } else {
                      await clockIn(task.file, task.pos);
                    }
                    onRefreshClock();
                  } catch (err) {
                    console.error('Clock error:', err);
                  }
                }}
                className={`flex items-center gap-1.5 text-[11px] rounded-md px-2 py-[3px] border transition-all ${
                  isClocked
                    ? 'bg-done-green/15 text-done-green border-done-green/20 hover:bg-done-green/25'
                    : 'bg-things-surface text-text-tertiary border-things-border hover:text-text-secondary'
                }`}
              >
                <span>{isClocked ? '\u23F9' : '\u25B6'}</span>
                {isClocked ? 'Stop Clock' : 'Clock In'}
              </button>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
