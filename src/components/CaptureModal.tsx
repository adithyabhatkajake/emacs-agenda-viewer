import { useState, useEffect, useRef, useCallback } from 'react';
import { createPortal } from 'react-dom';
import type { CaptureTemplate } from '../types';
import { fetchCaptureTemplates, captureTask } from '../api/tasks';

interface CaptureModalProps {
  open: boolean;
  onClose: () => void;
  onCaptured: () => void;
}

const PRIORITIES = [
  { key: 'A', desc: 'Urgent', dot: 'bg-priority-a', bg: 'bg-priority-a/12', text: 'text-priority-a', border: 'border-priority-a/25' },
  { key: 'B', desc: 'High', dot: 'bg-priority-b', bg: 'bg-priority-b/12', text: 'text-priority-b', border: 'border-priority-b/25' },
  { key: 'C', desc: 'Normal', dot: 'bg-accent', bg: 'bg-accent/10', text: 'text-accent', border: 'border-accent/20' },
  { key: 'D', desc: 'Low', dot: 'bg-text-tertiary', bg: 'bg-text-tertiary/10', text: 'text-text-tertiary', border: 'border-text-tertiary/20' },
];

function todayStr() {
  const d = new Date();
  return d.toISOString().slice(0, 10);
}

function tomorrowStr() {
  const d = new Date();
  d.setDate(d.getDate() + 1);
  return d.toISOString().slice(0, 10);
}

function nextWeekStr() {
  const d = new Date();
  d.setDate(d.getDate() + 7);
  return d.toISOString().slice(0, 10);
}

function formatDateLabel(dateStr: string): string {
  const today = todayStr();
  const tomorrow = tomorrowStr();
  if (dateStr === today) return 'Today';
  if (dateStr === tomorrow) return 'Tomorrow';
  const d = new Date(dateStr + 'T00:00:00');
  return d.toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric' });
}

function toOrgTimestamp(dateStr: string, timeStr?: string): string {
  const d = new Date(dateStr + 'T00:00:00');
  const dayNames = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  const day = dayNames[d.getDay()];
  if (timeStr) return `<${dateStr} ${day} ${timeStr}>`;
  return `<${dateStr} ${day}>`;
}

export function CaptureModal({ open, onClose, onCaptured }: CaptureModalProps) {
  const [templates, setTemplates] = useState<CaptureTemplate[] | null>(null);
  const [selected, setSelected] = useState<CaptureTemplate | null>(null);
  const [title, setTitle] = useState('');
  const [priority, setPriority] = useState<string | undefined>();
  const [scheduledDate, setScheduledDate] = useState<string | undefined>();
  const [scheduledTime, setScheduledTime] = useState<string | undefined>();
  const [deadlineDate, setDeadlineDate] = useState<string | undefined>();
  const [deadlineTime, setDeadlineTime] = useState<string | undefined>();
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  // Load templates on first open
  useEffect(() => {
    if (open && !templates) {
      fetchCaptureTemplates()
        .then(setTemplates)
        .catch(() => setError('Failed to load capture templates'));
    }
  }, [open, templates]);

  // Reset state when opening
  useEffect(() => {
    if (open) {
      setSelected(null);
      setTitle('');
      setPriority(undefined);
      setScheduledDate(undefined);
      setScheduledTime(undefined);
      setDeadlineDate(undefined);
      setDeadlineTime(undefined);
      setError(null);
      setSubmitting(false);
    }
  }, [open]);

  // Focus input when template selected
  useEffect(() => {
    if (selected && inputRef.current) {
      inputRef.current.focus();
    }
  }, [selected]);

  // Keyboard handler
  useEffect(() => {
    if (!open) return;
    const handler = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        if (selected) {
          setSelected(null);
          setTitle('');
        } else {
          onClose();
        }
        e.preventDefault();
      }
      if (!selected && templates && e.key.length === 1 && !e.metaKey && !e.ctrlKey) {
        const tmpl = templates.find(t => t.key === e.key && t.webSupported && !t.isGroup);
        if (tmpl) {
          setSelected(tmpl);
          e.preventDefault();
        }
      }
    };
    document.addEventListener('keydown', handler);
    return () => document.removeEventListener('keydown', handler);
  }, [open, selected, templates, onClose]);

  const handleSubmit = useCallback(async () => {
    if (!selected || !title.trim() || submitting) return;
    setSubmitting(true);
    setError(null);
    try {
      const options: { priority?: string; scheduled?: string; deadline?: string } = {};
      if (priority) options.priority = priority;
      if (scheduledDate) options.scheduled = toOrgTimestamp(scheduledDate, scheduledTime);
      if (deadlineDate) options.deadline = toOrgTimestamp(deadlineDate, deadlineTime);
      await captureTask(selected.key, title.trim(), options);
      onCaptured();
      onClose();
    } catch {
      setError('Failed to capture task');
      setSubmitting(false);
    }
  }, [selected, title, priority, scheduledDate, scheduledTime, deadlineDate, deadlineTime, submitting, onCaptured, onClose]);

  if (!open) return null;

  return createPortal(
    <div
      className="fixed inset-0 z-[9999] flex items-start justify-center pt-[15vh]"
      onClick={(e) => { if (e.target === e.currentTarget) onClose(); }}
    >
      <div className="absolute inset-0 bg-black/50" style={{ backdropFilter: 'blur(4px)' }} />

      <div className="relative w-full max-w-[480px] mx-4 bg-things-surface/95 rounded-xl shadow-2xl shadow-black/50 border border-things-border overflow-hidden"
           style={{ backdropFilter: 'blur(24px)' }}>

        {!selected ? (
          <div>
            <div className="px-4 pt-4 pb-2 flex items-center justify-between">
              <h2 className="text-[13px] font-semibold text-text-primary">Capture</h2>
              <button onClick={onClose} className="text-text-tertiary hover:text-text-secondary text-[18px] leading-none px-1">&times;</button>
            </div>
            {error && <div className="mx-4 mb-2 px-3 py-2 rounded-lg bg-priority-a/10 text-priority-a text-[11px]">{error}</div>}
            <div className="px-2 pb-2 max-h-[50vh] overflow-y-auto">
              {!templates ? (
                <div className="py-8 text-center text-text-tertiary text-[12px]">Loading templates...</div>
              ) : (
                <TemplateList templates={templates} onSelect={setSelected} />
              )}
            </div>
          </div>
        ) : (
          <div>
            {/* Header */}
            <div className="px-4 pt-4 pb-2 flex items-center gap-2">
              <button onClick={() => { setSelected(null); setTitle(''); }} className="text-text-tertiary hover:text-text-secondary text-[13px]">&larr;</button>
              <div className="flex items-center gap-2 flex-1 min-w-0">
                <span className="flex-shrink-0 inline-flex items-center justify-center w-5 h-5 rounded bg-accent/15 text-accent text-[10px] font-bold">{selected.key}</span>
                <span className="text-[13px] font-semibold text-text-primary truncate">{selected.description}</span>
              </div>
              <button onClick={onClose} className="text-text-tertiary hover:text-text-secondary text-[18px] leading-none px-1">&times;</button>
            </div>

            {selected.targetFile && (
              <div className="px-4 pb-1">
                <span className="text-[10px] text-text-tertiary">
                  {selected.targetHeadline ? `${selected.targetFile.split('/').pop()} / ${selected.targetHeadline}` : selected.targetFile.split('/').pop()}
                </span>
              </div>
            )}

            {error && <div className="mx-4 mb-2 px-3 py-2 rounded-lg bg-priority-a/10 text-priority-a text-[11px]">{error}</div>}

            <div className="px-4 pb-4 pt-2 flex flex-col gap-3">
              {/* Title input */}
              <input
                ref={inputRef}
                type="text"
                value={title}
                onChange={(e) => setTitle(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
                    e.preventDefault();
                    handleSubmit();
                  }
                }}
                placeholder="What do you want to capture?"
                className="w-full bg-things-bg/80 border border-things-border rounded-lg px-3 py-2.5 text-[13px] text-text-primary placeholder:text-text-tertiary/60 focus:outline-none focus:ring-1 focus:ring-accent/40 focus:border-accent/40"
              />

              {/* Optional metadata row */}
              <div className="flex flex-wrap items-center gap-2">
                {/* Priority picker */}
                <InlinePriorityPicker value={priority} onChange={setPriority} />

                {/* Scheduled picker */}
                <InlineDatePicker
                  label="Scheduled"
                  icon={'\uD83D\uDCC5'}
                  color="text-accent-teal"
                  value={scheduledDate}
                  time={scheduledTime}
                  onDateChange={setScheduledDate}
                  onTimeChange={setScheduledTime}
                  onClear={() => { setScheduledDate(undefined); setScheduledTime(undefined); }}
                />

                {/* Deadline picker */}
                <InlineDatePicker
                  label="Deadline"
                  icon={'\uD83D\uDCC6'}
                  color="text-priority-a"
                  value={deadlineDate}
                  time={deadlineTime}
                  onDateChange={setDeadlineDate}
                  onTimeChange={setDeadlineTime}
                  onClear={() => { setDeadlineDate(undefined); setDeadlineTime(undefined); }}
                />
              </div>

              {/* Submit row */}
              <div className="flex items-center justify-between">
                <span className="text-[10px] text-text-tertiary">{'\u2318'} Enter to capture</span>
                <button
                  onClick={handleSubmit}
                  disabled={!title.trim() || submitting}
                  className={`px-4 py-1.5 rounded-lg text-[12px] font-medium transition-all
                    ${title.trim() && !submitting
                      ? 'bg-accent text-white hover:brightness-110 active:brightness-90'
                      : 'bg-text-tertiary/15 text-text-tertiary cursor-not-allowed'}`}
                >
                  {submitting ? 'Capturing...' : 'Capture'}
                </button>
              </div>
            </div>
          </div>
        )}
      </div>
    </div>,
    document.body
  );
}

// ---- Inline Priority Picker ----

function InlinePriorityPicker({ value, onChange }: { value?: string; onChange: (v: string | undefined) => void }) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const handler = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
  }, [open]);

  const current = PRIORITIES.find(p => p.key === value);

  return (
    <div ref={ref} className="relative">
      <button
        onClick={() => setOpen(!open)}
        className={`flex items-center gap-1.5 px-2 py-1 rounded-md text-[11px] font-medium border transition-all
          ${current
            ? `${current.bg} ${current.text} ${current.border}`
            : 'bg-things-bg/60 text-text-tertiary border-things-border hover:border-text-tertiary/40'}`}
      >
        {current ? (
          <><span className={`w-1.5 h-1.5 rounded-full ${current.dot}`} />{current.key}</>
        ) : (
          <>Priority</>
        )}
      </button>

      {open && (
        <div className="absolute left-0 top-full mt-1 z-50 bg-things-surface/95 rounded-lg shadow-2xl shadow-black/50 border border-things-border py-1 min-w-[140px]"
             style={{ backdropFilter: 'blur(24px)' }}>
          {PRIORITIES.map(p => (
            <button
              key={p.key}
              onClick={() => { onChange(p.key); setOpen(false); }}
              className={`w-full text-left px-2.5 py-[5px] flex items-center gap-2 hover:bg-things-sidebar-hover/80 transition-colors text-[11px]
                ${value === p.key ? 'bg-things-sidebar-hover/60' : ''}`}
            >
              <span className={`w-1.5 h-1.5 rounded-full ${p.dot}`} />
              <span className={`font-bold ${p.text}`}>{p.key}</span>
              <span className="text-text-secondary">{p.desc}</span>
            </button>
          ))}
          {value && (
            <>
              <div className="mx-2 my-0.5 border-t border-things-border/60" />
              <button
                onClick={() => { onChange(undefined); setOpen(false); }}
                className="w-full text-left px-2.5 py-[5px] text-[11px] text-text-tertiary hover:bg-things-sidebar-hover/80 transition-colors"
              >
                Remove
              </button>
            </>
          )}
        </div>
      )}
    </div>
  );
}

// ---- Inline Date Picker ----

function InlineDatePicker({
  label, icon, color, value, time, onDateChange, onTimeChange, onClear,
}: {
  label: string;
  icon: string;
  color: string;
  value?: string;
  time?: string;
  onDateChange: (d: string | undefined) => void;
  onTimeChange: (t: string | undefined) => void;
  onClear: () => void;
}) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const handler = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
  }, [open]);

  return (
    <div ref={ref} className="relative">
      <button
        onClick={() => setOpen(!open)}
        className={`flex items-center gap-1.5 px-2 py-1 rounded-md text-[11px] font-medium border transition-all
          ${value
            ? `bg-things-bg/60 ${color} border-things-border`
            : 'bg-things-bg/60 text-text-tertiary border-things-border hover:border-text-tertiary/40'}`}
      >
        <span className="text-[12px]">{icon}</span>
        {value ? formatDateLabel(value) : label}
        {value && time && <span className="text-[10px] opacity-70">{time}</span>}
      </button>

      {open && (
        <div className="absolute left-0 top-full mt-1 z-50 bg-things-surface/95 rounded-lg shadow-2xl shadow-black/50 border border-things-border py-1 min-w-[180px]"
             style={{ backdropFilter: 'blur(24px)' }}>
          {/* Quick options */}
          {[
            { label: 'Today', val: todayStr() },
            { label: 'Tomorrow', val: tomorrowStr() },
            { label: 'Next Week', val: nextWeekStr() },
          ].map(opt => (
            <button
              key={opt.label}
              onClick={() => { onDateChange(opt.val); setOpen(false); }}
              className={`w-full text-left px-2.5 py-[5px] text-[11px] hover:bg-things-sidebar-hover/80 transition-colors
                ${value === opt.val ? 'text-accent bg-things-sidebar-hover/60' : 'text-text-primary'}`}
            >
              {opt.label}
            </button>
          ))}

          <div className="mx-2 my-1 border-t border-things-border/60" />

          {/* Date input */}
          <div className="px-2.5 py-1">
            <input
              type="date"
              value={value || ''}
              onChange={(e) => onDateChange(e.target.value || undefined)}
              className="w-full bg-things-bg/80 border border-things-border rounded px-2 py-1 text-[11px] text-text-primary focus:outline-none focus:ring-1 focus:ring-accent/40"
            />
          </div>

          {/* Time input */}
          <div className="px-2.5 py-1">
            <input
              type="time"
              value={time || ''}
              onChange={(e) => onTimeChange(e.target.value || undefined)}
              className="w-full bg-things-bg/80 border border-things-border rounded px-2 py-1 text-[11px] text-text-primary focus:outline-none focus:ring-1 focus:ring-accent/40"
            />
          </div>

          {value && (
            <>
              <div className="mx-2 my-0.5 border-t border-things-border/60" />
              <button
                onClick={() => { onClear(); setOpen(false); }}
                className="w-full text-left px-2.5 py-[5px] text-[11px] text-text-tertiary hover:bg-things-sidebar-hover/80 transition-colors"
              >
                Remove
              </button>
            </>
          )}
        </div>
      )}
    </div>
  );
}

// ---- Template List ----

function TemplateList({
  templates,
  onSelect,
}: {
  templates: CaptureTemplate[];
  onSelect: (t: CaptureTemplate) => void;
}) {
  const items: Array<{ type: 'group'; label: string } | { type: 'template'; tmpl: CaptureTemplate }> = [];

  for (const t of templates) {
    if (t.isGroup) {
      items.push({ type: 'group', label: t.description });
    } else {
      items.push({ type: 'template', tmpl: t });
    }
  }

  return (
    <div className="flex flex-col gap-0.5">
      {items.map((item, i) => {
        if (item.type === 'group') {
          return (
            <div key={i} className="px-2 pt-2.5 pb-1 text-[9px] font-semibold text-text-tertiary uppercase tracking-widest">
              {item.label}
            </div>
          );
        }
        const { tmpl } = item;
        const supported = tmpl.webSupported;
        return (
          <button
            key={tmpl.key}
            onClick={() => supported && onSelect(tmpl)}
            disabled={!supported}
            className={`w-full text-left px-2.5 py-2 flex items-center gap-2.5 rounded-lg transition-colors
              ${supported ? 'hover:bg-things-sidebar-hover/80 cursor-pointer' : 'opacity-40 cursor-not-allowed'}`}
          >
            <span className={`flex-shrink-0 inline-flex items-center justify-center w-5 h-5 rounded text-[10px] font-bold
              ${supported ? 'bg-accent/15 text-accent' : 'bg-text-tertiary/10 text-text-tertiary'}`}>
              {tmpl.key}
            </span>
            <span className={`text-[12px] flex-1 min-w-0 truncate ${supported ? 'text-text-primary' : 'text-text-tertiary'}`}>
              {tmpl.description}
            </span>
            {!supported && (
              <span className="flex-shrink-0 text-[9px] text-text-tertiary/70 bg-text-tertiary/8 rounded px-1.5 py-0.5">Emacs only</span>
            )}
            {supported && tmpl.targetHeadline && (
              <span className="flex-shrink-0 text-[9px] text-text-tertiary truncate max-w-[120px]">{tmpl.targetHeadline}</span>
            )}
          </button>
        );
      })}
    </div>
  );
}
