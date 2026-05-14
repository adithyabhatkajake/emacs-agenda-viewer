import { useRef, useEffect, useMemo, useState } from 'react';
import { createPortal } from 'react-dom';
import type { OrgTask } from '../types';
import { DatePicker } from './DatePicker';

// ---------------------------------------------------------------------------
// Helpers (mirrors DatePicker.tsx internals but kept local to this module)
// ---------------------------------------------------------------------------

function todayStr(): string {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

function dateStr(d: Date): string {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

function toOrgTimestamp(ymd: string, time: string | null): string {
  const [y, m, d] = ymd.split('-').map(Number);
  const date = new Date(y, m - 1, d);
  const weekdays = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  const dayName = weekdays[date.getDay()];
  if (time) return `<${ymd} ${dayName} ${time}>`;
  return `<${ymd} ${dayName}>`;
}

/** Next Saturday from today (or today if today is Saturday). */
function nextSaturday(): string {
  const d = new Date();
  const day = d.getDay(); // 0=Sun … 6=Sat
  const diff = day === 6 ? 7 : (6 - day);
  d.setDate(d.getDate() + diff);
  return dateStr(d);
}

/** Monday of next week. */
function nextMonday(): string {
  const d = new Date();
  const day = d.getDay(); // 0=Sun … 6=Sat
  const diff = day === 0 ? 1 : (8 - day); // next Mon
  d.setDate(d.getDate() + diff);
  return dateStr(d);
}

// ---------------------------------------------------------------------------
// Presets
// ---------------------------------------------------------------------------

type PresetId = 'today' | 'evening' | 'tomorrow' | 'weekend' | 'next-week' | 'someday' | 'custom';

interface Preset {
  id: PresetId;
  label: string;
  icon: string;
  sublabel?: string;
}

const PRESETS: Preset[] = [
  { id: 'today',     label: 'Today',        icon: '★' },
  { id: 'evening',   label: 'This Evening', icon: '🌙', sublabel: '18:00' },
  { id: 'tomorrow',  label: 'Tomorrow',     icon: '☀️' },
  { id: 'weekend',   label: 'This Weekend', icon: '🏖️' },
  { id: 'next-week', label: 'Next Week',    icon: '📆' },
  { id: 'someday',   label: 'Someday',      icon: '⤵️' },
];

// ---------------------------------------------------------------------------
// Dropdown content (portalled)
// ---------------------------------------------------------------------------

interface TrayDropdownProps {
  triggerRect: DOMRect;
  task: OrgTask;
  field: 'scheduled' | 'deadline';
  onSelect: (ts: string) => void;
  onClose: () => void;
}

function TrayDropdown({ triggerRect, task, field, onSelect, onClose }: TrayDropdownProps) {
  const menuRef = useRef<HTMLDivElement>(null);
  const [showCustom, setShowCustom] = useState(false);

  // Close on outside click
  useEffect(() => {
    const handler = (e: MouseEvent) => {
      if (menuRef.current && !menuRef.current.contains(e.target as Node)) {
        onClose();
      }
    };
    const id = setTimeout(() => document.addEventListener('mousedown', handler), 0);
    return () => { clearTimeout(id); document.removeEventListener('mousedown', handler); };
  }, [onClose]);

  useEffect(() => {
    const handler = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose(); };
    document.addEventListener('keydown', handler);
    return () => document.removeEventListener('keydown', handler);
  }, [onClose]);

  const style = useMemo(() => {
    const dropW = 220;
    const dropMaxH = 380;
    let top = triggerRect.bottom + 6;
    let left = triggerRect.left;
    if (left + dropW > window.innerWidth - 8) left = window.innerWidth - dropW - 8;
    if (left < 8) left = 8;
    if (top + dropMaxH > window.innerHeight - 8) {
      top = triggerRect.top - dropMaxH - 6;
      if (top < 8) top = 8;
    }
    return { position: 'fixed' as const, top, left, width: dropW, zIndex: 9999 };
  }, [triggerRect]);

  const handlePreset = (id: PresetId) => {
    const today = todayStr();
    switch (id) {
      case 'today':
        onSelect(toOrgTimestamp(today, null));
        onClose();
        break;
      case 'evening':
        onSelect(toOrgTimestamp(today, '18:00'));
        onClose();
        break;
      case 'tomorrow': {
        const d = new Date(); d.setDate(d.getDate() + 1);
        onSelect(toOrgTimestamp(dateStr(d), null));
        onClose();
        break;
      }
      case 'weekend':
        onSelect(toOrgTimestamp(nextSaturday(), null));
        onClose();
        break;
      case 'next-week':
        onSelect(toOrgTimestamp(nextMonday(), null));
        onClose();
        break;
      case 'someday':
        onSelect('');
        onClose();
        break;
      case 'custom':
        setShowCustom(true);
        break;
    }
  };

  // When the user is on mobile, render as a bottom sheet
  const isMobile = window.innerWidth < 768;

  if (isMobile) {
    return createPortal(
      <div
        className="fixed inset-0 z-[9999] flex flex-col justify-end"
        onClick={(e) => { if (e.target === e.currentTarget) onClose(); }}
      >
        <div className="absolute inset-0 bg-black/50" />
        <div
          ref={menuRef}
          className="relative w-full bg-things-surface/95 rounded-t-2xl shadow-2xl border-t border-things-border"
          style={{ backdropFilter: 'blur(24px)' }}
        >
          <div className="w-12 h-1 rounded-full bg-things-border mx-auto mt-3 mb-2" />
          <div className="px-3 pb-4">
            <p className="text-[11px] uppercase tracking-wider font-semibold text-text-tertiary px-2 py-2">
              {field === 'deadline' ? 'Set Deadline' : 'Schedule'}
            </p>
            {PRESETS.map(preset => (
              <button
                key={preset.id}
                onClick={() => handlePreset(preset.id)}
                className="w-full text-left px-3 py-3 flex items-center gap-3 hover:bg-things-sidebar-hover/80 rounded-xl transition-colors"
              >
                <span className="text-lg w-6 text-center">{preset.icon}</span>
                <span className="text-[14px] text-text-primary flex-1">{preset.label}</span>
                {preset.sublabel && (
                  <span className="text-[12px] text-text-tertiary">{preset.sublabel}</span>
                )}
              </button>
            ))}
            <button
              onClick={() => handlePreset('custom')}
              className="w-full text-left px-3 py-3 flex items-center gap-3 hover:bg-things-sidebar-hover/80 rounded-xl transition-colors"
            >
              <span className="text-lg w-6 text-center">{'📅'}</span>
              <span className="text-[14px] text-text-primary flex-1">Custom…</span>
            </button>
          </div>
          {/* Custom DatePicker rendered inline on mobile */}
          {showCustom && (
            <div className="px-3 pb-6">
              <DatePicker
                label={field === 'deadline' ? 'Deadline' : 'Scheduled'}
                currentDate={field === 'deadline' ? task.deadline?.raw : task.scheduled?.raw}
                onSelect={(ts) => { onSelect(ts); onClose(); }}
                onClear={() => { onSelect(''); onClose(); }}
                color={field}
              />
            </div>
          )}
        </div>
      </div>,
      document.body
    );
  }

  return createPortal(
    <div
      ref={menuRef}
      style={style}
      className="bg-things-surface/95 rounded-xl shadow-2xl shadow-black/50 border border-things-border py-1.5"
      aria-label="Schedule quick-pick"
    >
      <p className="px-3 pt-1 pb-1.5 text-[9px] uppercase tracking-wider font-semibold text-text-tertiary">
        {field === 'deadline' ? 'Set Deadline' : 'Schedule'}
      </p>
      {PRESETS.map(preset => (
        <button
          key={preset.id}
          onClick={() => handlePreset(preset.id)}
          className="w-full text-left px-2.5 py-[6px] flex items-center gap-2.5 hover:bg-things-sidebar-hover/80 rounded-md mx-1 transition-colors"
          style={{ width: 'calc(100% - 8px)' }}
        >
          <span className="text-sm w-5 text-center flex-shrink-0">{preset.icon}</span>
          <span className="text-[12px] text-text-primary flex-1">{preset.label}</span>
          {preset.sublabel && (
            <span className="text-[10px] text-text-tertiary">{preset.sublabel}</span>
          )}
        </button>
      ))}
      <div className="mx-2 my-1 border-t border-things-border/60" />
      {/* Custom — falls through to the full DatePicker */}
      {!showCustom ? (
        <button
          onClick={() => handlePreset('custom')}
          className="w-full text-left px-2.5 py-[6px] flex items-center gap-2.5 hover:bg-things-sidebar-hover/80 rounded-md mx-1 transition-colors"
          style={{ width: 'calc(100% - 8px)' }}
        >
          <span className="text-sm w-5 text-center flex-shrink-0">{'📅'}</span>
          <span className="text-[12px] text-text-primary">Custom…</span>
        </button>
      ) : (
        <div className="px-2 py-2">
          <DatePicker
            label={field === 'deadline' ? 'Deadline' : 'Scheduled'}
            currentDate={field === 'deadline' ? task.deadline?.raw : task.scheduled?.raw}
            onSelect={(ts) => { onSelect(ts); onClose(); }}
            onClear={() => { onSelect(''); onClose(); }}
            color={field}
          />
        </div>
      )}
    </div>,
    document.body
  );
}

// ---------------------------------------------------------------------------
// Public component: the date chip that opens the tray
// ---------------------------------------------------------------------------

interface ScheduleTrayProps {
  task: OrgTask;
  field: 'scheduled' | 'deadline';
  /** The formatted string shown on the chip (e.g. "Today", "Tomorrow", "Mon") */
  label: string;
  /** Color variant */
  overdue?: boolean;
  onSelect: (ts: string) => void;
  disabled?: boolean;
}

export function ScheduleTray({ task, field, label, overdue, onSelect, disabled }: ScheduleTrayProps) {
  const [open, setOpen] = useState(false);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const [triggerRect, setTriggerRect] = useState<DOMRect | null>(null);

  const handleOpen = (e: React.MouseEvent) => {
    e.stopPropagation();
    if (disabled) return;
    if (triggerRef.current) {
      setTriggerRect(triggerRef.current.getBoundingClientRect());
    }
    setOpen(prev => !prev);
  };

  const colorClass = field === 'deadline'
    ? (overdue ? 'text-priority-a' : 'text-priority-b')
    : 'text-accent';

  return (
    <>
      <button
        ref={triggerRef}
        type="button"
        onClick={handleOpen}
        disabled={disabled}
        className={`text-[11px] md:text-[10px] tabular-nums whitespace-nowrap underline decoration-dotted underline-offset-2 transition-opacity hover:opacity-70 ${colorClass} ${disabled ? 'opacity-40 cursor-not-allowed' : 'cursor-pointer'}`}
        title={`Reschedule ${field}`}
      >
        {label}
      </button>
      {open && triggerRect && (
        <TrayDropdown
          triggerRect={triggerRect}
          task={task}
          field={field}
          onSelect={onSelect}
          onClose={() => setOpen(false)}
        />
      )}
    </>
  );
}
