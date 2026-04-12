import type { ReactNode } from 'react';

interface NotesRendererProps {
  content: string;
  /** Called with the checklist item index (across all checklists) when a checkbox is toggled */
  onToggleCheck?: (index: number) => void;
}

/** Parse inline org markup within a text segment */
export function renderInline(text: string): ReactNode[] {
  const parts: ReactNode[] = [];
  // Match org links [[target][label]] or [[target]], bold *text*, italic /text/, code ~text~ or =text=
  const regex = /\[\[([^\]]+)\]\[([^\]]+)\]\]|\[\[([^\]]+)\]\]|\*([^*]+)\*|\/([^/]+)\/|~([^~]+)~|=([^=]+)=/g;
  let lastIndex = 0;
  let match;

  while ((match = regex.exec(text)) !== null) {
    // Text before this match
    if (match.index > lastIndex) {
      parts.push(text.slice(lastIndex, match.index));
    }

    if (match[1] && match[2]) {
      // [[target][label]]
      parts.push(
        <span key={match.index} className="text-accent">{match[2]}</span>
      );
    } else if (match[3]) {
      // [[target]] — show the target as label
      const label = match[3].replace(/^file:~?\//, '').replace(/\/$/, '').split('/').pop() || match[3];
      parts.push(
        <span key={match.index} className="text-accent">{label}</span>
      );
    } else if (match[4]) {
      // *bold*
      parts.push(<strong key={match.index} className="font-semibold text-text-primary">{match[4]}</strong>);
    } else if (match[5]) {
      // /italic/
      parts.push(<em key={match.index} className="italic">{match[5]}</em>);
    } else if (match[6]) {
      // ~code~
      parts.push(
        <code key={match.index} className="px-1 py-0.5 rounded bg-things-bg text-accent-teal text-[11px] font-mono">{match[6]}</code>
      );
    } else if (match[7]) {
      // =verbatim=
      parts.push(
        <code key={match.index} className="px-1 py-0.5 rounded bg-things-bg text-accent-teal text-[11px] font-mono">{match[7]}</code>
      );
    }

    lastIndex = match.index + match[0].length;
  }

  if (lastIndex < text.length) {
    parts.push(text.slice(lastIndex));
  }

  return parts.length > 0 ? parts : [text];
}

/** Parse and render org notes content */
export function NotesRenderer({ content, onToggleCheck }: NotesRendererProps) {
  const lines = content.split('\n');

  // Group consecutive checklist items together, tracking global index
  const blocks: Array<
    | { type: 'checklist'; items: Array<{ checked: boolean; text: string; globalIndex: number }> }
    | { type: 'text'; lines: string[] }
    | { type: 'created'; date: string }
  > = [];
  let checklistGlobalIndex = 0;

  let currentChecklist: Array<{ checked: boolean; text: string; globalIndex: number }> | null = null;
  let currentText: string[] | null = null;

  const flushChecklist = () => {
    if (currentChecklist && currentChecklist.length > 0) {
      blocks.push({ type: 'checklist', items: [...currentChecklist] });
      currentChecklist = null;
    }
  };

  const flushText = () => {
    if (currentText && currentText.length > 0) {
      blocks.push({ type: 'text', lines: [...currentText] });
      currentText = null;
    }
  };

  for (const line of lines) {
    const trimmed = line.trim();

    // Created timestamp
    const createdMatch = trimmed.match(/^Created:\s*\[(\d{4}-\d{2}-\d{2}\s+\w+)\]$/);
    if (createdMatch) {
      flushChecklist();
      flushText();
      blocks.push({ type: 'created', date: createdMatch[1] });
      continue;
    }

    // Checklist item: - [ ] text or - [X] text
    const checklistMatch = trimmed.match(/^-\s+\[([ Xx])\]\s+(.+)$/);
    if (checklistMatch) {
      flushText();
      if (!currentChecklist) currentChecklist = [];
      currentChecklist.push({
        checked: checklistMatch[1].toLowerCase() === 'x',
        text: checklistMatch[2],
        globalIndex: checklistGlobalIndex++,
      });
      continue;
    }

    // Regular text line
    flushChecklist();
    if (!currentText) currentText = [];
    currentText.push(trimmed);
  }

  flushChecklist();
  flushText();

  // Count checklist progress
  const allCheckItems = blocks
    .filter((b): b is { type: 'checklist'; items: Array<{ checked: boolean; text: string; globalIndex: number }> } => b.type === 'checklist')
    .flatMap(b => b.items);
  const checkedCount = allCheckItems.filter(i => i.checked).length;
  const totalCheck = allCheckItems.length;

  return (
    <div className="flex flex-col gap-2">
      {blocks.map((block, i) => {
        if (block.type === 'created') {
          return (
            <div key={i} className="text-[11px] text-text-tertiary">
              Created: {block.date}
            </div>
          );
        }

        if (block.type === 'checklist') {
          return (
            <div key={i} className="flex flex-col gap-0">
              {/* Progress bar if there are checklist items */}
              {i === blocks.findIndex(b => b.type === 'checklist') && totalCheck > 0 && (
                <div className="flex items-center gap-2 mb-2">
                  <div className="flex-1 h-1.5 bg-things-bg rounded-full overflow-hidden">
                    <div
                      className="h-full bg-done-green rounded-full transition-all"
                      style={{ width: `${totalCheck > 0 ? (checkedCount / totalCheck) * 100 : 0}%` }}
                    />
                  </div>
                  <span className="text-[10px] text-text-tertiary tabular-nums">
                    {checkedCount}/{totalCheck}
                  </span>
                </div>
              )}

              {block.items.map((item, j) => (
                <div key={j} className="flex items-start gap-2.5 py-1">
                  {/* Checkbox — clickable */}
                  <button
                    onClick={() => onToggleCheck?.(item.globalIndex)}
                    className={`mt-0.5 w-4 h-4 rounded flex-shrink-0 border flex items-center justify-center transition-colors ${
                      item.checked
                        ? 'bg-done-green border-done-green hover:bg-done-green/80'
                        : 'border-text-tertiary/50 hover:border-done-green/70'
                    } ${onToggleCheck ? 'cursor-pointer' : 'cursor-default'}`}
                  >
                    {item.checked && (
                      <svg width="10" height="10" viewBox="0 0 10 10" fill="none">
                        <path d="M2 5L4.5 7.5L8 3" stroke="white" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
                      </svg>
                    )}
                  </button>
                  {/* Label */}
                  <span className={`text-[13px] leading-snug ${
                    item.checked ? 'line-through text-text-tertiary' : 'text-text-secondary'
                  }`}>
                    {renderInline(item.text)}
                  </span>
                </div>
              ))}
            </div>
          );
        }

        if (block.type === 'text') {
          // Filter out empty lines at start/end
          const textLines = block.lines;
          const nonEmpty = textLines.filter(l => l.length > 0);
          if (nonEmpty.length === 0) return null;

          return (
            <div key={i} className="text-[13px] text-text-secondary leading-relaxed">
              {textLines.map((line, j) => (
                <div key={j} className={line.length === 0 ? 'h-2' : ''}>
                  {line.length > 0 && renderInline(line)}
                </div>
              ))}
            </div>
          );
        }

        return null;
      })}
    </div>
  );
}
