import { useState, useRef, useEffect } from 'react';
import type { TodoKeywords } from '../types';

interface TodoStateMenuProps {
  currentState: string | undefined;
  keywords: TodoKeywords | null;
  isDoneState: (state: string | undefined) => boolean;
  onSelect: (state: string) => void;
  disabled?: boolean;
}

function stateStyle(state: string, isDone: boolean): { bg: string; text: string; border: string; glow: string } {
  if (isDone) {
    if (state === 'KILL') return { bg: 'bg-priority-a/15', text: 'text-priority-a', border: 'border-priority-a/25', glow: 'shadow-priority-a/10' };
    return { bg: 'bg-done-green/15', text: 'text-done-green', border: 'border-done-green/25', glow: 'shadow-done-green/10' };
  }
  switch (state) {
    case 'TODO': return { bg: 'bg-accent/12', text: 'text-accent', border: 'border-accent/20', glow: 'shadow-accent/10' };
    case 'NEXT': return { bg: 'bg-priority-b/12', text: 'text-priority-b', border: 'border-priority-b/20', glow: 'shadow-priority-b/10' };
    case 'WAIT': return { bg: 'bg-dot-yellow/12', text: 'text-dot-yellow', border: 'border-dot-yellow/20', glow: 'shadow-dot-yellow/10' };
    case 'FLLW': return { bg: 'bg-dot-purple/12', text: 'text-dot-purple', border: 'border-dot-purple/20', glow: 'shadow-dot-purple/10' };
    case 'SMDY': return { bg: 'bg-text-tertiary/12', text: 'text-text-secondary', border: 'border-text-tertiary/20', glow: '' };
    case 'ACTV': return { bg: 'bg-done-green/12', text: 'text-done-green', border: 'border-done-green/20', glow: 'shadow-done-green/10' };
    case 'PROJ': return { bg: 'bg-dot-purple/12', text: 'text-dot-purple', border: 'border-dot-purple/20', glow: 'shadow-dot-purple/10' };
    case 'DRFT': return { bg: 'bg-text-tertiary/12', text: 'text-text-secondary', border: 'border-text-tertiary/20', glow: '' };
    case 'PROG': return { bg: 'bg-accent-teal/12', text: 'text-accent-teal', border: 'border-accent-teal/20', glow: 'shadow-accent-teal/10' };
    case '[ ]': return { bg: 'bg-text-tertiary/12', text: 'text-text-secondary', border: 'border-text-tertiary/20', glow: '' };
    case '[-]': return { bg: 'bg-dot-yellow/12', text: 'text-dot-yellow', border: 'border-dot-yellow/20', glow: 'shadow-dot-yellow/10' };
    case '[?]': return { bg: 'bg-priority-b/12', text: 'text-priority-b', border: 'border-priority-b/20', glow: 'shadow-priority-b/10' };
    default: return { bg: 'bg-text-tertiary/12', text: 'text-text-secondary', border: 'border-text-tertiary/20', glow: '' };
  }
}

function findSequence(state: string | undefined, keywords: TodoKeywords) {
  if (!state) return keywords.sequences[0];
  for (const seq of keywords.sequences) {
    if (seq.active.includes(state) || seq.done.includes(state)) {
      return seq;
    }
  }
  return keywords.sequences[0];
}

export function TodoStateMenu({
  currentState,
  keywords,
  isDoneState,
  onSelect,
  disabled,
}: TodoStateMenuProps) {
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

  const done = isDoneState(currentState);
  const seq = keywords ? findSequence(currentState, keywords) : null;
  const style = stateStyle(currentState || '', done);

  return (
    <div className="relative">
      {/* State pill trigger */}
      <button
        ref={triggerRef}
        onClick={() => { if (!disabled && keywords) setOpen(!open); }}
        disabled={disabled}
        className={`mt-px flex-shrink-0 rounded-md px-2.5 md:px-2 py-[5px] md:py-[3px] text-[11px] md:text-[10px] font-bold tracking-wide border transition-all
          ${style.bg} ${style.text} ${style.border}
          ${disabled ? 'opacity-40 cursor-not-allowed' : 'cursor-pointer hover:brightness-125'}
          ${open ? 'ring-1 ring-white/20' : ''}
        `}
      >
        {currentState || '\u2022\u2022\u2022'}
      </button>

      {open && seq && (
        <div
          ref={menuRef}
          className="absolute left-0 top-full mt-1.5 z-50 bg-things-surface/95 rounded-xl shadow-2xl shadow-black/50 border border-things-border py-1 min-w-[170px]"
          style={{ backdropFilter: 'blur(24px)' }}
        >
          {/* Active states */}
          <div className="px-3 pt-1.5 pb-1 text-[9px] font-semibold text-text-tertiary uppercase tracking-widest">
            Active
          </div>
          {seq.active.map(state => {
            const s = stateStyle(state, false);
            const isCurrent = state === currentState;
            return (
              <button
                key={state}
                onClick={() => { onSelect(state); setOpen(false); }}
                className={`w-full text-left px-2.5 py-[5px] flex items-center gap-2 hover:bg-things-sidebar-hover/80 transition-colors rounded-md mx-0.5
                  ${isCurrent ? 'bg-things-sidebar-hover/60' : ''}`}
                style={{ width: 'calc(100% - 4px)' }}
              >
                <span className={`inline-block rounded px-1.5 py-[2px] text-[10px] font-bold border ${s.bg} ${s.text} ${s.border}`}>
                  {state}
                </span>
                {isCurrent && (
                  <span className="text-accent text-[11px] ml-auto font-medium">{'\u2713'}</span>
                )}
              </button>
            );
          })}

          <div className="mx-2.5 my-1 border-t border-things-border/60" />

          {/* Done states */}
          <div className="px-3 pt-1 pb-1 text-[9px] font-semibold text-text-tertiary uppercase tracking-widest">
            Done
          </div>
          {seq.done.map(state => {
            const s = stateStyle(state, true);
            const isCurrent = state === currentState;
            return (
              <button
                key={state}
                onClick={() => { onSelect(state); setOpen(false); }}
                className={`w-full text-left px-2.5 py-[5px] flex items-center gap-2 hover:bg-things-sidebar-hover/80 transition-colors rounded-md mx-0.5
                  ${isCurrent ? 'bg-things-sidebar-hover/60' : ''}`}
                style={{ width: 'calc(100% - 4px)' }}
              >
                <span className={`inline-block rounded px-1.5 py-[2px] text-[10px] font-bold border ${s.bg} ${s.text} ${s.border}`}>
                  {state}
                </span>
                {isCurrent && (
                  <span className="text-accent text-[11px] ml-auto font-medium">{'\u2713'}</span>
                )}
              </button>
            );
          })}

          {/* Other sequences */}
          {keywords && keywords.sequences.length > 1 && (
            <>
              <div className="mx-2.5 my-1 border-t border-things-border/60" />
              <div className="px-3 pt-1 pb-1 text-[9px] font-semibold text-text-tertiary uppercase tracking-widest">
                Other
              </div>
              {keywords.sequences
                .filter(s => s !== seq)
                .map((otherSeq, i) => (
                  <div key={i} className="flex flex-wrap gap-1 px-2.5 py-1">
                    {[...otherSeq.active, ...otherSeq.done].map(state => {
                      const isDone = otherSeq.done.includes(state);
                      const s = stateStyle(state, isDone);
                      return (
                        <button
                          key={state}
                          onClick={() => { onSelect(state); setOpen(false); }}
                          className="hover:brightness-125 rounded transition-all"
                        >
                          <span className={`inline-block rounded px-1 py-[1px] text-[9px] font-bold border ${s.bg} ${s.text} ${s.border}`}>
                            {state}
                          </span>
                        </button>
                      );
                    })}
                  </div>
                ))}
            </>
          )}
        </div>
      )}
    </div>
  );
}
