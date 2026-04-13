import { useState, useEffect, useRef, useCallback } from 'react';
import { createPortal } from 'react-dom';
import type { CaptureTemplate } from '../types';
import { fetchCaptureTemplates, captureTask } from '../api/tasks';

interface CaptureModalProps {
  open: boolean;
  onClose: () => void;
  onCaptured: () => void;
}

export function CaptureModal({ open, onClose, onCaptured }: CaptureModalProps) {
  const [templates, setTemplates] = useState<CaptureTemplate[] | null>(null);
  const [selected, setSelected] = useState<CaptureTemplate | null>(null);
  const [title, setTitle] = useState('');
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
      // In template picker phase, press template key to select
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
      await captureTask(selected.key, title.trim());
      onCaptured();
      onClose();
    } catch {
      setError('Failed to capture task');
      setSubmitting(false);
    }
  }, [selected, title, submitting, onCaptured, onClose]);

  if (!open) return null;

  return createPortal(
    <div
      className="fixed inset-0 z-[9999] flex items-start justify-center pt-[15vh]"
      onClick={(e) => { if (e.target === e.currentTarget) onClose(); }}
    >
      {/* Backdrop */}
      <div className="absolute inset-0 bg-black/50" style={{ backdropFilter: 'blur(4px)' }} />

      {/* Modal */}
      <div className="relative w-full max-w-[480px] mx-4 bg-things-surface/95 rounded-xl shadow-2xl shadow-black/50 border border-things-border overflow-hidden"
           style={{ backdropFilter: 'blur(24px)' }}>

        {!selected ? (
          // Phase 1: Template picker
          <div>
            <div className="px-4 pt-4 pb-2 flex items-center justify-between">
              <h2 className="text-[13px] font-semibold text-text-primary">Capture</h2>
              <button
                onClick={onClose}
                className="text-text-tertiary hover:text-text-secondary text-[18px] leading-none px-1"
              >
                &times;
              </button>
            </div>

            {error && (
              <div className="mx-4 mb-2 px-3 py-2 rounded-lg bg-priority-a/10 text-priority-a text-[11px]">
                {error}
              </div>
            )}

            <div className="px-2 pb-2 max-h-[50vh] overflow-y-auto">
              {!templates ? (
                <div className="py-8 text-center text-text-tertiary text-[12px]">Loading templates...</div>
              ) : (
                <TemplateList templates={templates} onSelect={setSelected} />
              )}
            </div>
          </div>
        ) : (
          // Phase 2: Input form
          <div>
            <div className="px-4 pt-4 pb-2 flex items-center gap-2">
              <button
                onClick={() => { setSelected(null); setTitle(''); }}
                className="text-text-tertiary hover:text-text-secondary text-[13px]"
              >
                &larr;
              </button>
              <div className="flex items-center gap-2 flex-1 min-w-0">
                <span className="flex-shrink-0 inline-flex items-center justify-center w-5 h-5 rounded bg-accent/15 text-accent text-[10px] font-bold">
                  {selected.key}
                </span>
                <span className="text-[13px] font-semibold text-text-primary truncate">
                  {selected.description}
                </span>
              </div>
              <button
                onClick={onClose}
                className="text-text-tertiary hover:text-text-secondary text-[18px] leading-none px-1"
              >
                &times;
              </button>
            </div>

            {selected.targetFile && (
              <div className="px-4 pb-1">
                <span className="text-[10px] text-text-tertiary">
                  {selected.targetHeadline
                    ? `${selected.targetFile.split('/').pop()} / ${selected.targetHeadline}`
                    : selected.targetFile.split('/').pop()}
                </span>
              </div>
            )}

            {error && (
              <div className="mx-4 mb-2 px-3 py-2 rounded-lg bg-priority-a/10 text-priority-a text-[11px]">
                {error}
              </div>
            )}

            <div className="px-4 pb-4 pt-2">
              <input
                ref={inputRef}
                type="text"
                value={title}
                onChange={(e) => setTitle(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === 'Enter' && !e.shiftKey) {
                    e.preventDefault();
                    handleSubmit();
                  }
                }}
                placeholder="What do you want to capture?"
                className="w-full bg-things-bg/80 border border-things-border rounded-lg px-3 py-2.5 text-[13px] text-text-primary placeholder:text-text-tertiary/60 focus:outline-none focus:ring-1 focus:ring-accent/40 focus:border-accent/40"
              />

              <div className="flex items-center justify-between mt-3">
                <span className="text-[10px] text-text-tertiary">
                  {'\u23CE'} Enter to capture
                </span>
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

function TemplateList({
  templates,
  onSelect,
}: {
  templates: CaptureTemplate[];
  onSelect: (t: CaptureTemplate) => void;
}) {
  // Group templates by prefix (group headers)
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
              ${supported
                ? 'hover:bg-things-sidebar-hover/80 cursor-pointer'
                : 'opacity-40 cursor-not-allowed'}`}
          >
            <span className={`flex-shrink-0 inline-flex items-center justify-center w-5 h-5 rounded text-[10px] font-bold
              ${supported
                ? 'bg-accent/15 text-accent'
                : 'bg-text-tertiary/10 text-text-tertiary'}`}>
              {tmpl.key}
            </span>
            <span className={`text-[12px] flex-1 min-w-0 truncate
              ${supported ? 'text-text-primary' : 'text-text-tertiary'}`}>
              {tmpl.description}
            </span>
            {!supported && (
              <span className="flex-shrink-0 text-[9px] text-text-tertiary/70 bg-text-tertiary/8 rounded px-1.5 py-0.5">
                Emacs only
              </span>
            )}
            {supported && tmpl.targetHeadline && (
              <span className="flex-shrink-0 text-[9px] text-text-tertiary truncate max-w-[120px]">
                {tmpl.targetHeadline}
              </span>
            )}
          </button>
        );
      })}
    </div>
  );
}
