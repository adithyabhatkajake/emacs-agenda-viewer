import { useState, useRef, useEffect } from 'react';
import { createPortal } from 'react-dom';

interface TagPickerProps {
  currentTags: string[];
  allTags: string[];
  onConfirm: (tags: string[]) => void;
  onClose: () => void;
}

export function TagPicker({ currentTags, allTags, onConfirm, onClose }: TagPickerProps) {
  const [selected, setSelected] = useState<string[]>([...currentTags]);
  const [input, setInput] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (inputRef.current) inputRef.current.focus();
  }, []);

  // Tags to show in the suggestion list: all known tags not already selected,
  // filtered by the current input text.
  const suggestions = allTags.filter(t =>
    !selected.includes(t) && t.toLowerCase().includes(input.toLowerCase())
  );

  const addTag = (tag: string) => {
    const trimmed = tag.trim().replace(/\s+/g, '_');
    if (!trimmed || selected.includes(trimmed)) return;
    setSelected(prev => [...prev, trimmed]);
    setInput('');
  };

  const removeTag = (tag: string) => {
    setSelected(prev => prev.filter(t => t !== tag));
  };

  const handleConfirm = async () => {
    if (submitting) return;
    setSubmitting(true);
    try {
      await onConfirm(selected);
    } finally {
      setSubmitting(false);
    }
  };

  return createPortal(
    <div
      className="fixed inset-0 z-[9999] flex items-end md:items-start md:justify-center md:pt-[15vh]"
      onClick={(e) => { if (e.target === e.currentTarget) onClose(); }}
    >
      <div className="absolute inset-0 bg-black/50" style={{ backdropFilter: 'blur(4px)' }} />
      <div
        className="relative w-full md:max-w-[480px] md:mx-4 bg-things-surface/95 md:rounded-xl rounded-t-xl shadow-2xl shadow-black/50 border border-things-border overflow-hidden"
        style={{ backdropFilter: 'blur(24px)' }}
      >
        {/* Header */}
        <div className="px-4 pt-4 pb-2 flex items-center justify-between border-b border-things-border">
          <h2 className="text-[13px] font-semibold text-text-primary">Edit Tags</h2>
          <button
            onClick={onClose}
            className="text-text-tertiary hover:text-text-secondary text-[18px] leading-none px-1"
          >&times;</button>
        </div>

        <div className="px-4 py-3">
          {/* Current tags as chips */}
          {selected.length > 0 && (
            <div className="flex flex-wrap gap-1.5 mb-3">
              {selected.map(tag => (
                <span
                  key={tag}
                  className="inline-flex items-center gap-1 px-2 py-[3px] rounded-full bg-accent/15 border border-accent/25 text-accent text-[11px] font-medium"
                >
                  #{tag}
                  <button
                    onClick={() => removeTag(tag)}
                    className="text-accent/70 hover:text-accent leading-none text-[13px] ml-0.5"
                    aria-label={`Remove ${tag}`}
                  >&times;</button>
                </span>
              ))}
            </div>
          )}

          {/* Free-text input */}
          <input
            ref={inputRef}
            type="text"
            value={input}
            onChange={(e) => setInput(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'Enter') {
                e.preventDefault();
                if (input.trim()) {
                  addTag(input);
                } else {
                  handleConfirm();
                }
              }
              if (e.key === 'Escape') {
                e.preventDefault();
                onClose();
              }
              if (e.key === ' ' || e.key === ',') {
                e.preventDefault();
                if (input.trim()) addTag(input);
              }
            }}
            placeholder="Add tag... (Enter or Space to add)"
            className="w-full bg-things-bg/80 border border-things-border rounded-lg px-3 py-2 text-[13px] text-text-primary placeholder:text-text-tertiary/60 focus:outline-none focus:ring-1 focus:ring-accent/40 focus:border-accent/40"
          />

          {/* Suggestions from known tags */}
          {input && suggestions.length > 0 && (
            <div className="mt-1.5 max-h-[28vh] overflow-y-auto rounded-lg border border-things-border bg-things-bg/90">
              {suggestions.slice(0, 20).map(tag => (
                <button
                  key={tag}
                  onClick={() => addTag(tag)}
                  className="w-full text-left px-3 py-1.5 text-[12px] text-text-primary hover:bg-things-sidebar-hover/80 transition-colors"
                >
                  #{tag}
                </button>
              ))}
            </div>
          )}

          {/* When no input, show all unselected tags as chips to click */}
          {!input && allTags.filter(t => !selected.includes(t)).length > 0 && (
            <div className="mt-2 flex flex-wrap gap-1.5 max-h-[28vh] overflow-y-auto">
              {allTags.filter(t => !selected.includes(t)).map(tag => (
                <button
                  key={tag}
                  onClick={() => addTag(tag)}
                  className="inline-flex items-center gap-1 px-2 py-[3px] rounded-full bg-things-surface border border-things-border text-text-secondary text-[11px] hover:bg-things-sidebar-hover hover:border-accent/30 hover:text-text-primary transition-colors"
                >
                  #{tag}
                </button>
              ))}
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="px-4 pb-4 flex items-center justify-end gap-2">
          <button
            onClick={onClose}
            className="px-3 py-1.5 rounded-lg bg-things-surface text-text-secondary text-[12px] border border-things-border hover:bg-things-sidebar-hover transition-colors"
          >
            Cancel
          </button>
          <button
            onClick={handleConfirm}
            disabled={submitting}
            className="px-4 py-1.5 rounded-lg bg-accent/20 text-accent text-[12px] font-medium border border-accent/25 hover:bg-accent/30 transition-colors disabled:opacity-50"
          >
            {submitting ? 'Saving...' : 'Save'}
          </button>
        </div>
      </div>
    </div>,
    document.body
  );
}
