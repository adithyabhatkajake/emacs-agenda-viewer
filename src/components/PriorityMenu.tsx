import { useState, useRef, useEffect } from 'react';

interface PriorityMenuProps {
  currentPriority: string | undefined;
  onSelect: (priority: string) => void;
  disabled?: boolean;
}

const PRIORITIES = [
  { key: 'A', label: 'Priority A', desc: 'Urgent', bg: 'bg-priority-a/12', text: 'text-priority-a', border: 'border-priority-a/25', dot: 'bg-priority-a' },
  { key: 'B', label: 'Priority B', desc: 'High', bg: 'bg-priority-b/12', text: 'text-priority-b', border: 'border-priority-b/25', dot: 'bg-priority-b' },
  { key: 'C', label: 'Priority C', desc: 'Normal', bg: 'bg-accent/10', text: 'text-accent', border: 'border-accent/20', dot: 'bg-accent' },
  { key: 'D', label: 'Priority D', desc: 'Low', bg: 'bg-text-tertiary/10', text: 'text-text-tertiary', border: 'border-text-tertiary/20', dot: 'bg-text-tertiary' },
];

export function PriorityMenu({ currentPriority, onSelect, disabled }: PriorityMenuProps) {
  const [open, setOpen] = useState(false);
  const menuRef = useRef<HTMLDivElement>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    if (!open) return;
    const handler = (e: MouseEvent) => {
      if (
        menuRef.current && !menuRef.current.contains(e.target as Node) &&
        triggerRef.current && !triggerRef.current.contains(e.target as Node)
      ) {
        setOpen(false);
      }
    };
    document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
  }, [open]);

  useEffect(() => {
    if (!open) return;
    const handler = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setOpen(false);
    };
    document.addEventListener('keydown', handler);
    return () => document.removeEventListener('keydown', handler);
  }, [open]);

  const current = PRIORITIES.find(p => p.key === currentPriority);

  return (
    <div className="relative">
      <button
        ref={triggerRef}
        onClick={() => { if (!disabled) setOpen(!open); }}
        disabled={disabled}
        className={`mt-px flex-shrink-0 rounded px-1.5 py-[3px] text-[10px] font-bold border transition-all
          ${current ? `${current.bg} ${current.text} ${current.border}` : 'bg-things-surface text-text-tertiary border-things-border'}
          ${disabled ? 'opacity-40 cursor-not-allowed' : 'cursor-pointer hover:brightness-125'}
          ${open ? 'ring-1 ring-white/20' : ''}
        `}
      >
        {currentPriority || '\u2014'}
      </button>

      {open && (
        <div
          ref={menuRef}
          className="absolute left-0 top-full mt-1.5 z-50 bg-things-surface/95 rounded-xl shadow-2xl shadow-black/50 border border-things-border py-1.5 min-w-[180px]"
          style={{ backdropFilter: 'blur(24px)' }}
        >
          <div className="px-3 pt-1 pb-1.5 text-[9px] font-semibold text-text-tertiary uppercase tracking-widest">
            Set Priority
          </div>

          {PRIORITIES.map(p => {
            const isCurrent = p.key === currentPriority;
            return (
              <button
                key={p.key}
                onClick={() => { onSelect(p.key); setOpen(false); }}
                className={`w-full text-left px-2.5 py-[6px] flex items-center gap-2.5 hover:bg-things-sidebar-hover/80 transition-colors rounded-md mx-0.5
                  ${isCurrent ? 'bg-things-sidebar-hover/60' : ''}`}
                style={{ width: 'calc(100% - 4px)' }}
              >
                <span className={`w-2 h-2 rounded-full flex-shrink-0 ${p.dot}`} />
                <span className={`rounded px-1.5 py-[2px] text-[10px] font-bold border ${p.bg} ${p.text} ${p.border}`}>
                  {p.key}
                </span>
                <span className="text-[12px] text-text-secondary flex-1">{p.desc}</span>
                {isCurrent && (
                  <span className="text-accent text-[11px] font-medium">{'\u2713'}</span>
                )}
              </button>
            );
          })}

          {/* Remove priority option */}
          <div className="mx-2.5 my-1 border-t border-things-border/60" />
          <button
            onClick={() => { onSelect(' '); setOpen(false); }}
            className={`w-full text-left px-2.5 py-[6px] flex items-center gap-2.5 hover:bg-things-sidebar-hover/80 transition-colors rounded-md mx-0.5
              ${!currentPriority ? 'bg-things-sidebar-hover/60' : ''}`}
            style={{ width: 'calc(100% - 4px)' }}
          >
            <span className="w-2 h-2 rounded-full flex-shrink-0 bg-things-border" />
            <span className="text-[12px] text-text-tertiary">No priority</span>
            {!currentPriority && (
              <span className="text-accent text-[11px] ml-auto font-medium">{'\u2713'}</span>
            )}
          </button>
        </div>
      )}
    </div>
  );
}
