import { useState, useRef, useEffect, useMemo } from 'react';
import { createPortal } from 'react-dom';

interface DatePickerProps {
  label: string;
  currentDate: string | undefined;
  onSelect: (timestamp: string) => void;
  onClear: () => void;
  disabled?: boolean;
  color: 'scheduled' | 'deadline';
}

function extractDate(raw: string | undefined): string | null {
  if (!raw) return null;
  const m = raw.match(/(\d{4}-\d{2}-\d{2})/);
  return m ? m[1] : null;
}

function extractTime(raw: string | undefined): string | null {
  if (!raw) return null;
  const m = raw.match(/\d{4}-\d{2}-\d{2}\s+\w+\s+(\d{1,2}:\d{2})/);
  return m ? m[1] : null;
}

function formatDisplayDate(raw: string | undefined): string | null {
  const dateStr = extractDate(raw);
  if (!dateStr) return null;
  const [y, m, d] = dateStr.split('-').map(Number);
  const date = new Date(y, m - 1, d);
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  const diff = Math.floor((date.getTime() - today.getTime()) / 86400000);

  let label: string;
  if (diff === 0) label = 'Today';
  else if (diff === 1) label = 'Tomorrow';
  else if (diff === -1) label = 'Yesterday';
  else if (diff < -1) label = `${Math.abs(diff)}d ago`;
  else label = date.toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric' });

  const time = extractTime(raw);
  if (time) label += ` ${time}`;
  return label;
}

function toOrgTimestamp(dateStr: string, time: string | null): string {
  const [y, m, d] = dateStr.split('-').map(Number);
  const date = new Date(y, m - 1, d);
  const weekdays = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  const dayName = weekdays[date.getDay()];
  if (time) return `<${dateStr} ${dayName} ${time}>`;
  return `<${dateStr} ${dayName}>`;
}

function todayStr(): string {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

function addDays(dateStr: string, days: number): string {
  const [y, m, d] = dateStr.split('-').map(Number);
  const date = new Date(y, m - 1, d + days);
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
}

function MiniCalendar({ selectedDate, onSelect }: { selectedDate: string | null; onSelect: (d: string) => void }) {
  const today = todayStr();
  const [viewDate, setViewDate] = useState(() => {
    if (selectedDate) {
      const [y, m] = selectedDate.split('-').map(Number);
      return { year: y, month: m - 1 };
    }
    const d = new Date();
    return { year: d.getFullYear(), month: d.getMonth() };
  });

  const calDays = useMemo(() => {
    const first = new Date(viewDate.year, viewDate.month, 1);
    const startDay = first.getDay();
    const daysInMonth = new Date(viewDate.year, viewDate.month + 1, 0).getDate();
    const days: { dateStr: string; day: number; inMonth: boolean }[] = [];

    const prevDays = new Date(viewDate.year, viewDate.month, 0).getDate();
    for (let i = startDay - 1; i >= 0; i--) {
      const d = prevDays - i;
      const m = viewDate.month === 0 ? 12 : viewDate.month;
      const y = viewDate.month === 0 ? viewDate.year - 1 : viewDate.year;
      days.push({ dateStr: `${y}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`, day: d, inMonth: false });
    }
    for (let d = 1; d <= daysInMonth; d++) {
      days.push({ dateStr: `${viewDate.year}-${String(viewDate.month + 1).padStart(2, '0')}-${String(d).padStart(2, '0')}`, day: d, inMonth: true });
    }
    const remaining = 42 - days.length;
    for (let d = 1; d <= remaining; d++) {
      const m = viewDate.month + 2 > 12 ? 1 : viewDate.month + 2;
      const y = viewDate.month + 2 > 12 ? viewDate.year + 1 : viewDate.year;
      days.push({ dateStr: `${y}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`, day: d, inMonth: false });
    }
    return days;
  }, [viewDate]);

  const monthLabel = new Date(viewDate.year, viewDate.month).toLocaleDateString('en-US', { month: 'long', year: 'numeric' });

  return (
    <div className="px-2 py-1">
      <div className="flex items-center justify-between px-1 py-1">
        <button onClick={() => setViewDate(v => ({ year: v.month === 0 ? v.year - 1 : v.year, month: v.month === 0 ? 11 : v.month - 1 }))} className="w-6 h-6 flex items-center justify-center rounded hover:bg-things-sidebar-hover text-text-secondary text-sm">{'\u2039'}</button>
        <span className="text-[11px] font-semibold text-text-primary">{monthLabel}</span>
        <button onClick={() => setViewDate(v => ({ year: v.month === 11 ? v.year + 1 : v.year, month: v.month === 11 ? 0 : v.month + 1 }))} className="w-6 h-6 flex items-center justify-center rounded hover:bg-things-sidebar-hover text-text-secondary text-sm">{'\u203A'}</button>
      </div>
      <div className="grid grid-cols-7 gap-0">
        {['Su', 'Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa'].map(d => (
          <div key={d} className="text-[9px] font-semibold text-text-tertiary text-center py-1">{d}</div>
        ))}
      </div>
      <div className="grid grid-cols-7 gap-0">
        {calDays.map(({ dateStr, day, inMonth }) => (
          <button
            key={dateStr}
            onClick={() => onSelect(dateStr)}
            className={`w-7 h-7 text-[11px] rounded-md flex items-center justify-center transition-colors
              ${!inMonth ? 'text-text-tertiary/40' : 'text-text-secondary hover:bg-things-sidebar-hover'}
              ${dateStr === today ? 'ring-1 ring-accent/50 text-accent font-bold' : ''}
              ${dateStr === selectedDate ? 'bg-accent text-white font-bold' : ''}
            `}
          >
            {day}
          </button>
        ))}
      </div>
    </div>
  );
}

/** The dropdown content, rendered via portal */
function DatePickerDropdown({
  triggerRect,
  currentDate,
  label,
  onSelect,
  onClear,
  onClose,
}: {
  triggerRect: DOMRect;
  currentDate: string | undefined;
  label: string;
  onSelect: (ts: string) => void;
  onClear: () => void;
  onClose: () => void;
}) {
  const menuRef = useRef<HTMLDivElement>(null);
  const [pendingDate, setPendingDate] = useState<string | null>(extractDate(currentDate));
  const [pendingTime, setPendingTime] = useState<string>(extractTime(currentDate) || '');
  const today = todayStr();
  const hasDate = !!currentDate;

  // Close on outside click
  useEffect(() => {
    const handler = (e: MouseEvent) => {
      if (menuRef.current && !menuRef.current.contains(e.target as Node)) {
        onClose();
      }
    };
    // Delay to avoid the trigger click from immediately closing
    const id = setTimeout(() => document.addEventListener('mousedown', handler), 0);
    return () => { clearTimeout(id); document.removeEventListener('mousedown', handler); };
  }, [onClose]);

  useEffect(() => {
    const handler = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose(); };
    document.addEventListener('keydown', handler);
    return () => document.removeEventListener('keydown', handler);
  }, [onClose]);

  // Position: anchor below the trigger, align right edge, keep on screen
  const style = useMemo(() => {
    const dropW = 248;
    const dropMaxH = 450;
    let top = triggerRect.bottom + 6;
    let left = triggerRect.right - dropW;
    if (left < 8) left = 8;
    if (left + dropW > window.innerWidth - 8) left = window.innerWidth - dropW - 8;
    if (top + dropMaxH > window.innerHeight - 8) {
      top = triggerRect.top - dropMaxH - 6;
      if (top < 8) top = 8;
    }
    return { position: 'fixed' as const, top, left, width: dropW, zIndex: 9999 };
  }, [triggerRect]);

  const confirmAndClose = (dateStr: string, time: string | null) => {
    onSelect(toOrgTimestamp(dateStr, time && time.trim() ? time.trim() : null));
    onClose();
  };

  const handleQuickPick = (dateStr: string) => {
    confirmAndClose(dateStr, pendingTime || null);
  };

  const handleCalendarPick = (dateStr: string) => {
    setPendingDate(dateStr);
    if (!pendingTime) {
      confirmAndClose(dateStr, null);
    }
  };

  return createPortal(
    <div
      ref={menuRef}
      style={style}
      className="bg-things-surface/95 rounded-xl shadow-2xl shadow-black/50 border border-things-border py-1.5 max-h-[450px] overflow-y-auto"
    >
      {/* Quick options */}
      <div className="px-1.5 pb-1">
        <button onClick={() => handleQuickPick(today)} className="w-full text-left px-2.5 py-[6px] flex items-center gap-2.5 hover:bg-things-sidebar-hover/80 rounded-md transition-colors">
          <span className="text-dot-yellow text-sm">{'\u2605'}</span>
          <span className="text-[12px] text-text-primary">Today</span>
        </button>
        <button onClick={() => handleQuickPick(addDays(today, 1))} className="w-full text-left px-2.5 py-[6px] flex items-center gap-2.5 hover:bg-things-sidebar-hover/80 rounded-md transition-colors">
          <span className="text-priority-b text-sm">{'\u{1F319}'}</span>
          <span className="text-[12px] text-text-primary">Tomorrow</span>
        </button>
        <button onClick={() => { const d = new Date(); handleQuickPick(addDays(today, (8 - d.getDay()) % 7 || 7)); }} className="w-full text-left px-2.5 py-[6px] flex items-center gap-2.5 hover:bg-things-sidebar-hover/80 rounded-md transition-colors">
          <span className="text-accent text-sm">{'\u{1F4C6}'}</span>
          <span className="text-[12px] text-text-primary">Next Week</span>
        </button>
      </div>

      <div className="mx-2 my-0.5 border-t border-things-border/60" />

      {/* Time input */}
      <div className="px-3 py-2 flex items-center gap-2">
        <span className="text-accent-teal text-sm">{'\u{1F552}'}</span>
        <input
          type="time"
          value={pendingTime}
          onChange={(e) => setPendingTime(e.target.value)}
          onKeyDown={(e) => { if (e.key === 'Enter' && pendingDate) confirmAndClose(pendingDate, pendingTime || null); }}
          className="flex-1 bg-things-bg border border-things-border rounded-md px-2 py-1 text-[12px] text-text-primary outline-none focus:border-accent/50 focus:ring-1 focus:ring-accent/30 transition-colors [color-scheme:dark]"
        />
        {pendingTime && (
          <button onClick={() => setPendingTime('')} className="text-text-tertiary hover:text-text-secondary text-[10px]" title="Clear time">{'\u2715'}</button>
        )}
      </div>

      {/* Confirm button when time is set */}
      {pendingTime && pendingDate && (
        <div className="px-3 pb-1">
          <button
            onClick={() => confirmAndClose(pendingDate, pendingTime)}
            className="w-full py-1.5 rounded-md bg-accent/20 text-accent text-[11px] font-semibold hover:bg-accent/30 transition-colors"
          >
            Set {pendingDate === today ? 'Today' : pendingDate === addDays(today, 1) ? 'Tomorrow' : pendingDate} at {pendingTime}
          </button>
        </div>
      )}

      <div className="mx-2 my-0.5 border-t border-things-border/60" />

      {/* Calendar */}
      <MiniCalendar
        selectedDate={pendingDate}
        onSelect={handleCalendarPick}
      />

      {/* Remove */}
      {hasDate && (
        <>
          <div className="mx-2 my-0.5 border-t border-things-border/60" />
          <div className="px-1.5 pt-0.5 pb-0.5">
            <button onClick={() => { onClear(); onClose(); }} className="w-full text-left px-2.5 py-[6px] flex items-center gap-2.5 hover:bg-things-sidebar-hover/80 rounded-md transition-colors">
              <span className="text-priority-a text-sm">{'\u2715'}</span>
              <span className="text-[12px] text-priority-a">Remove {label.toLowerCase()}</span>
            </button>
          </div>
        </>
      )}
    </div>,
    document.body
  );
}

export function DatePicker({ label, currentDate, onSelect, onClear, disabled, color }: DatePickerProps) {
  const [open, setOpen] = useState(false);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const [triggerRect, setTriggerRect] = useState<DOMRect | null>(null);

  const handleOpen = () => {
    if (disabled) return;
    if (triggerRef.current) {
      setTriggerRect(triggerRef.current.getBoundingClientRect());
    }
    setOpen(!open);
  };

  const displayDate = formatDisplayDate(currentDate);
  const hasDate = !!currentDate;

  return (
    <>
      <button
        ref={triggerRef}
        onClick={handleOpen}
        disabled={disabled}
        className={`flex items-center gap-1.5 text-[11px] rounded-md px-2 py-[3px] transition-all border
          ${hasDate
            ? `${color === 'deadline' ? 'bg-priority-a/8 text-priority-a border-priority-a/15' : 'bg-accent/8 text-accent border-accent/15'}`
            : 'bg-things-surface text-text-tertiary border-things-border hover:text-text-secondary'
          }
          ${disabled ? 'opacity-40 cursor-not-allowed' : 'cursor-pointer hover:brightness-110'}
          ${open ? 'ring-1 ring-white/20' : ''}
        `}
      >
        <span className={hasDate ? (color === 'deadline' ? 'text-priority-a' : 'text-accent') : 'text-text-tertiary'}>
          {color === 'deadline' ? '\u{1F3F4}' : '\u{1F4C5}'}
        </span>
        {hasDate ? displayDate : label}
      </button>

      {open && triggerRect && (
        <DatePickerDropdown
          triggerRect={triggerRect}
          currentDate={currentDate}
          label={label}
          onSelect={onSelect}
          onClear={onClear}
          onClose={() => setOpen(false)}
        />
      )}
    </>
  );
}
