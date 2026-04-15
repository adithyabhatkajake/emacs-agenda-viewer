import { useState, useRef, useEffect, useCallback } from 'react';
import { createPortal } from 'react-dom';
import type { OrgTask, AgendaEntry, TodoKeywords } from '../types';
import { updateTodoState, updatePriority, updateScheduled, updateDeadline, updateTitle, fetchRefileTargets, refileTask, fetchNotes, saveNotes, clockIn, clockOutApi, type ClockStatus, type RefileTarget } from '../api/tasks';

function useLongPress(callback: (e: React.TouchEvent) => void, ms = 500) {
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const callbackRef = useRef(callback);
  callbackRef.current = callback;

  const onTouchStart = useCallback((e: React.TouchEvent) => {
    timerRef.current = setTimeout(() => {
      callbackRef.current(e);
      timerRef.current = null;
    }, ms);
  }, [ms]);

  const onTouchEnd = useCallback(() => {
    if (timerRef.current) {
      clearTimeout(timerRef.current);
      timerRef.current = null;
    }
  }, []);

  return { onTouchStart, onTouchEnd, onTouchMove: onTouchEnd };
}
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
  const [editingTitle, setEditingTitle] = useState(false);
  const [titleText, setTitleText] = useState('');
  const [contextMenu, setContextMenu] = useState<{ x: number; y: number } | null>(null);
  const [refileOpen, setRefileOpen] = useState(false);
  const contextRef = useRef<HTMLDivElement>(null);
  const titleInputRef = useRef<HTMLInputElement>(null);
  const done = isDoneState(task.todoState);

  // Long press for mobile context menu
  const longPress = useLongPress((e) => {
    const touch = e.touches?.[0] || e.changedTouches?.[0];
    if (touch) {
      setContextMenu({ x: touch.clientX, y: touch.clientY });
    }
  });

  // Close context menu on outside click
  useEffect(() => {
    if (!contextMenu) return;
    const handler = (e: MouseEvent) => {
      if (contextRef.current && !contextRef.current.contains(e.target as Node)) setContextMenu(null);
    };
    document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
  }, [contextMenu]);

  // Focus title input when editing
  useEffect(() => {
    if (editingTitle && titleInputRef.current) {
      titleInputRef.current.focus();
      titleInputRef.current.select();
    }
  }, [editingTitle]);

  const handleTitleSave = async () => {
    const trimmed = titleText.trim();
    if (!trimmed || trimmed === task.title || updating) return;
    setUpdating(true);
    try {
      await updateTitle(task, trimmed);
      setEditingTitle(false);
      onRefresh();
    } catch (err) {
      console.error('Failed to update title:', err);
    } finally {
      setUpdating(false);
    }
  };

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
    catch (err) { console.error('Failed to set scheduled:', err); onRefresh(); }
    finally { setUpdating(false); }
  };

  const handleDeadlineChange = async (timestamp: string) => {
    if (updating) return;
    setUpdating(true);
    try { await updateDeadline(task, timestamp); onRefresh(); }
    catch (err) { console.error('Failed to set deadline:', err); onRefresh(); }
    finally { setUpdating(false); }
  };

  const handleClearScheduled = async () => {
    if (updating) return;
    setUpdating(true);
    try { await updateScheduled(task, ''); onRefresh(); }
    catch (err) { console.error('Failed to clear scheduled:', err); onRefresh(); }
    finally { setUpdating(false); }
  };

  const handleClearDeadline = async () => {
    if (updating) return;
    setUpdating(true);
    try { await updateDeadline(task, ''); onRefresh(); }
    catch (err) { console.error('Failed to clear deadline:', err); onRefresh(); }
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
      <div className="flex items-center gap-2 px-3 md:px-5 py-2.5 md:py-1.5">
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

        {/* Main content — click to expand, right-click/long-press for context menu */}
        <div
          className="flex-1 min-w-0 cursor-pointer select-none"
          onClick={toggleExpand}
          onContextMenu={(e) => {
            e.preventDefault();
            setContextMenu({ x: e.clientX, y: e.clientY });
          }}
          {...longPress}
        >
          {/* Title + inline metadata */}
          {editingTitle ? (
            <input
              ref={titleInputRef}
              value={titleText}
              onChange={(e) => setTitleText(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter') { e.preventDefault(); handleTitleSave(); }
                if (e.key === 'Escape') { e.preventDefault(); setEditingTitle(false); }
              }}
              onBlur={handleTitleSave}
              onClick={(e) => e.stopPropagation()}
              className="w-full bg-things-bg/80 border border-accent/40 rounded px-2 py-0.5 text-[13px] text-text-primary outline-none focus:ring-1 focus:ring-accent/30"
            />
          ) : (
            <span
              className={`text-[14px] md:text-[13px] leading-snug ${
                done ? 'line-through text-text-tertiary' : 'text-text-primary'
              }`}
            >
              {renderInline(task.title)}
            </span>
          )}
          <span className="flex flex-wrap items-center gap-x-2 gap-y-0.5 mt-0.5 text-[11px] md:text-[10px] text-text-tertiary">
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
        <div className="px-3 md:px-5 pb-2 pt-0 ml-2 md:ml-[62px]">
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
                className="w-full bg-things-bg border border-things-border rounded-md px-3 py-2 text-[12px] text-text-primary font-mono leading-relaxed outline-none focus:border-accent/50 focus:ring-1 focus:ring-accent/30 resize-y min-h-[60px]"
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
                      // Find the Nth checklist item and cycle: [ ] -> [-] -> [X] -> [ ]
                      let count = 0;
                      const newNotes = notes.replace(
                        /^([ \t]*[-+*]\s+\[)([ Xx\-])(\]\s+)/gm,
                        (match, before, check, after) => {
                          if (count++ === index) {
                            const newCheck = check === ' ' ? '-' : check === '-' ? 'X' : ' ';
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
          <div className="flex flex-wrap items-center gap-2 mt-1">
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

      {/* Context menu */}
      {contextMenu && createPortal(
        <div
          ref={contextRef}
          className="fixed z-[9999] bg-things-surface/95 rounded-lg shadow-2xl shadow-black/50 border border-things-border py-1 min-w-[140px]"
          style={{ top: contextMenu.y, left: contextMenu.x, backdropFilter: 'blur(24px)' }}
        >
          <button
            onClick={() => {
              setTitleText(task.title);
              setEditingTitle(true);
              setContextMenu(null);
            }}
            className="w-full text-left px-3 py-1.5 text-[12px] text-text-primary hover:bg-things-sidebar-hover/80 transition-colors"
          >
            Edit title
          </button>
          <button
            onClick={() => {
              setRefileOpen(true);
              setContextMenu(null);
            }}
            className="w-full text-left px-3 py-1.5 text-[12px] text-text-primary hover:bg-things-sidebar-hover/80 transition-colors"
          >
            Refile
          </button>
        </div>,
        document.body
      )}

      {/* Refile picker */}
      {refileOpen && (
        <RefilePicker
          task={task}
          onClose={() => setRefileOpen(false)}
          onRefiled={onRefresh}
        />
      )}
    </div>
  );
}

// ---- Refile Picker ----

function RefilePicker({ task, onClose, onRefiled }: { task: DisplayItem; onClose: () => void; onRefiled: () => void }) {
  const [targets, setTargets] = useState<RefileTarget[] | null>(null);
  const [query, setQuery] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    fetchRefileTargets()
      .then(setTargets)
      .catch(() => setError('Failed to load refile targets'));
  }, []);

  useEffect(() => {
    if (inputRef.current) inputRef.current.focus();
  }, [targets]);

  const filtered = targets?.filter(t => {
    if (!query.trim()) return true;
    const q = query.toLowerCase();
    return t.name.toLowerCase().includes(q);
  }).slice(0, 50); // limit to 50 results

  const handleSelect = async (target: RefileTarget) => {
    if (submitting) return;
    setSubmitting(true);
    try {
      await refileTask(task.file, task.pos, target.file, target.pos);
      onRefiled();
      onClose();
    } catch {
      setError('Failed to refile');
      setSubmitting(false);
    }
  };

  return createPortal(
    <div
      className="fixed inset-0 z-[9999] flex items-start justify-center pt-[15vh]"
      onClick={(e) => { if (e.target === e.currentTarget) onClose(); }}
    >
      <div className="absolute inset-0 bg-black/50" style={{ backdropFilter: 'blur(4px)' }} />
      <div
        className="relative w-full max-w-[520px] mx-4 bg-things-surface/95 rounded-xl shadow-2xl shadow-black/50 border border-things-border overflow-hidden"
        style={{ backdropFilter: 'blur(24px)' }}
      >
        <div className="px-4 pt-4 pb-2 flex items-center justify-between">
          <h2 className="text-[13px] font-semibold text-text-primary">Refile to...</h2>
          <button onClick={onClose} className="text-text-tertiary hover:text-text-secondary text-[18px] leading-none px-1">&times;</button>
        </div>

        {error && <div className="mx-4 mb-2 px-3 py-2 rounded-lg bg-priority-a/10 text-priority-a text-[11px]">{error}</div>}

        <div className="px-4 pb-2">
          <input
            ref={inputRef}
            type="text"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'Escape') { e.preventDefault(); onClose(); }
              if (e.key === 'Enter' && filtered && filtered.length === 1) {
                e.preventDefault();
                handleSelect(filtered[0]);
              }
            }}
            placeholder="Search headings..."
            className="w-full bg-things-bg/80 border border-things-border rounded-lg px-3 py-2 text-[13px] text-text-primary placeholder:text-text-tertiary/60 focus:outline-none focus:ring-1 focus:ring-accent/40 focus:border-accent/40"
          />
        </div>

        <div className="max-h-[40vh] overflow-y-auto px-2 pb-2">
          {!targets ? (
            <div className="py-6 text-center text-text-tertiary text-[12px]">Loading targets...</div>
          ) : filtered && filtered.length === 0 ? (
            <div className="py-6 text-center text-text-tertiary text-[12px]">No matching headings</div>
          ) : (
            filtered?.map((target, i) => (
              <button
                key={`${target.file}::${target.pos}::${i}`}
                onClick={() => handleSelect(target)}
                disabled={submitting}
                className="w-full text-left px-2.5 py-1.5 rounded-lg hover:bg-things-sidebar-hover/80 transition-colors flex items-baseline gap-2 min-w-0"
              >
                <span className="text-[12px] text-text-primary truncate flex-1">{target.name}</span>
                <span className="text-[9px] text-text-tertiary flex-shrink-0 truncate max-w-[120px]">
                  {target.file.split('/').pop()?.replace(/\.org$/, '')}
                </span>
              </button>
            ))
          )}
        </div>
      </div>
    </div>,
    document.body
  );
}
