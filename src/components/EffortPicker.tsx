import { useState, useRef, useEffect } from 'react';
import { createPortal } from 'react-dom';

interface EffortPickerProps {
  currentEffort: string | undefined;
  onConfirm: (value: string) => void;
  onClose: () => void;
}

const PRESETS = ['0:05', '0:15', '0:30', '1:00', '2:00', '4:00'];

/** Basic HH:MM format validation */
function isValidEffort(s: string): boolean {
  return /^\d+:\d{2}$/.test(s.trim());
}

export function EffortPicker({ currentEffort, onConfirm, onClose }: EffortPickerProps) {
  const [custom, setCustom] = useState(currentEffort || '');
  const [submitting, setSubmitting] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (inputRef.current) inputRef.current.focus();
  }, []);

  const handleSelect = async (value: string) => {
    if (submitting) return;
    setSubmitting(true);
    try {
      await onConfirm(value);
    } finally {
      setSubmitting(false);
    }
  };

  const handleCustomConfirm = () => {
    const trimmed = custom.trim();
    if (!trimmed) return;
    if (!isValidEffort(trimmed)) return;
    handleSelect(trimmed);
  };

  return createPortal(
    <div
      className="fixed inset-0 z-[9999] flex items-end md:items-start md:justify-center md:pt-[15vh]"
      onClick={(e) => { if (e.target === e.currentTarget) onClose(); }}
    >
      <div className="absolute inset-0 bg-black/50" style={{ backdropFilter: 'blur(4px)' }} />
      <div
        className="relative w-full md:max-w-[380px] md:mx-4 bg-things-surface/95 md:rounded-xl rounded-t-xl shadow-2xl shadow-black/50 border border-things-border overflow-hidden"
        style={{ backdropFilter: 'blur(24px)' }}
      >
        {/* Header */}
        <div className="px-4 pt-4 pb-2 flex items-center justify-between border-b border-things-border">
          <h2 className="text-[13px] font-semibold text-text-primary">Set Effort</h2>
          <button
            onClick={onClose}
            className="text-text-tertiary hover:text-text-secondary text-[18px] leading-none px-1"
          >&times;</button>
        </div>

        <div className="px-4 py-3">
          {/* Preset chips */}
          <div className="flex flex-wrap gap-1.5 mb-3">
            {PRESETS.map(preset => {
              const isCurrent = currentEffort === preset;
              return (
                <button
                  key={preset}
                  onClick={() => handleSelect(preset)}
                  disabled={submitting}
                  className={`px-3 py-1.5 rounded-lg border text-[12px] font-medium transition-colors disabled:opacity-50 ${
                    isCurrent
                      ? 'bg-accent/20 border-accent/30 text-accent'
                      : 'bg-things-surface border-things-border text-text-primary hover:bg-things-sidebar-hover hover:border-accent/20'
                  }`}
                >
                  {preset}
                  {isCurrent && <span className="ml-1 text-[10px]">{'✓'}</span>}
                </button>
              );
            })}
          </div>

          {/* Custom HH:MM input */}
          <div className="flex items-center gap-2">
            <input
              ref={inputRef}
              type="text"
              value={custom}
              onChange={(e) => setCustom(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter') { e.preventDefault(); handleCustomConfirm(); }
                if (e.key === 'Escape') { e.preventDefault(); onClose(); }
              }}
              placeholder="Custom HH:MM"
              className="flex-1 bg-things-bg/80 border border-things-border rounded-lg px-3 py-2 text-[13px] text-text-primary placeholder:text-text-tertiary/60 focus:outline-none focus:ring-1 focus:ring-accent/40 focus:border-accent/40 font-mono"
            />
            <button
              onClick={handleCustomConfirm}
              disabled={submitting || !isValidEffort(custom)}
              className="px-3 py-2 rounded-lg bg-accent/20 text-accent text-[12px] font-medium border border-accent/25 hover:bg-accent/30 transition-colors disabled:opacity-40"
            >
              Set
            </button>
          </div>
          {custom && !isValidEffort(custom) && (
            <p className="text-[10px] text-priority-a mt-1">Format must be HH:MM (e.g. 1:30)</p>
          )}

          {/* Clear option */}
          {currentEffort && (
            <button
              onClick={() => handleSelect('')}
              disabled={submitting}
              className="mt-2 text-[11px] text-text-tertiary hover:text-priority-a transition-colors"
            >
              Clear effort
            </button>
          )}
        </div>
      </div>
    </div>,
    document.body
  );
}
