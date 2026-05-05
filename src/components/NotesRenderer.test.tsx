import { describe, it, expect } from 'vitest';
import { isValidElement, type ReactNode } from 'react';
import {
  renderInline,
  parseNoteBlocks,
  formatTimestamp,
  formatComponentDate,
  formatComponentTime,
} from './NotesRenderer';
import type { OrgTimestamp, OrgTimestampComponent } from '../types';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Extract the visible text from a ReactNode[], stripping JSX wrappers. */
function textOf(nodes: ReactNode[]): string {
  return nodes.map(n => {
    if (typeof n === 'string') return n;
    if (isValidElement(n) && n.props.children != null) {
      const children = n.props.children;
      if (typeof children === 'string') return children;
      if (Array.isArray(children)) return textOf(children);
      return String(children);
    }
    return '';
  }).join('');
}

/** Return the JSX element types produced by renderInline (e.g. "strong", "em", "code"). */
function elementTypes(nodes: ReactNode[]): string[] {
  return nodes
    .filter(n => isValidElement(n))
    .map(n => (isValidElement(n) ? (n.type as string) : ''));
}

// ---------------------------------------------------------------------------
// Inline Markup — Emphasis (org spec §11.7)
// ---------------------------------------------------------------------------

describe('renderInline — Emphasis (org spec §11.7)', () => {
  it('renders bold *text*', () => {
    const nodes = renderInline('This is *bold* text');
    expect(textOf(nodes)).toBe('This is bold text');
    expect(elementTypes(nodes)).toContain('strong');
  });

  it('renders italic /text/', () => {
    const nodes = renderInline('This is /italic/ text');
    expect(textOf(nodes)).toBe('This is italic text');
    expect(elementTypes(nodes)).toContain('em');
  });

  it('renders code ~text~', () => {
    const nodes = renderInline('Run ~git status~');
    expect(textOf(nodes)).toBe('Run git status');
    expect(elementTypes(nodes)).toContain('code');
  });

  it('renders verbatim =text=', () => {
    const nodes = renderInline('Use =org-mode= here');
    expect(textOf(nodes)).toBe('Use org-mode here');
    expect(elementTypes(nodes)).toContain('code');
  });

  it('renders multi-word bold *multiple words*', () => {
    const nodes = renderInline('*bold and long*');
    expect(textOf(nodes)).toBe('bold and long');
  });

  it('handles multiple markup types in one line', () => {
    const nodes = renderInline('*Bold* and /italic/ and =code=');
    expect(textOf(nodes)).toBe('Bold and italic and code');
  });

  it('renders markup at start of line', () => {
    expect(textOf(renderInline('*bold* rest'))).toBe('bold rest');
  });

  it('renders markup at end of line', () => {
    expect(textOf(renderInline('text *bold*'))).toBe('text bold');
  });

  it('does not match empty emphasis: ** nothing', () => {
    expect(textOf(renderInline('** nothing'))).toBe('** nothing');
  });

  it('unmatched single marker is literal', () => {
    expect(textOf(renderInline('*unclosed text'))).toBe('*unclosed text');
  });
});

// ---------------------------------------------------------------------------
// Inline Markup — Boundary Rules (org spec §11.7 pre/post constraints)
// ---------------------------------------------------------------------------

describe('renderInline — Boundary Rules', () => {
  // The web regex currently does NOT enforce org-spec boundaries.
  // These tests document the expected behavior per spec.

  it('should not match bold inside words: ab*cd*ef', () => {
    // org spec: emphasis markers must not be adjacent to word characters
    expect(textOf(renderInline('ab*cd*ef'))).toBe('ab*cd*ef');
  });

  it('should not match italic inside words: ab/cd/ef', () => {
    expect(textOf(renderInline('ab/cd/ef'))).toBe('ab/cd/ef');
  });

  it('should not match code inside words: ab~cd~ef', () => {
    expect(textOf(renderInline('ab~cd~ef'))).toBe('ab~cd~ef');
  });

  it('should not match verbatim inside words: ab=cd=ef', () => {
    expect(textOf(renderInline('ab=cd=ef'))).toBe('ab=cd=ef');
  });
});

// ---------------------------------------------------------------------------
// Inline Markup — Code/Verbatim Precedence (org spec §11.7)
// ---------------------------------------------------------------------------

describe('renderInline — Code/Verbatim Precedence', () => {
  it('markup inside verbatim is literal: =*not bold*=', () => {
    const nodes = renderInline('=*not bold*=');
    expect(textOf(nodes)).toBe('*not bold*');
    expect(elementTypes(nodes)).toEqual(['code']);
  });

  it('markup inside code is literal: ~/not italic/~', () => {
    const nodes = renderInline('~/not italic/~');
    expect(textOf(nodes)).toBe('/not italic/');
    expect(elementTypes(nodes)).toEqual(['code']);
  });

  it('verbatim multi-word: =git commit -m "fix"=', () => {
    expect(textOf(renderInline("=git commit -m 'fix'="))).toBe("git commit -m 'fix'");
  });
});

// ---------------------------------------------------------------------------
// Inline Markup — Links (org spec §4.2)
// ---------------------------------------------------------------------------

describe('renderInline — Links (org spec §4.2)', () => {
  it('renders labeled link [[url][label]]', () => {
    const nodes = renderInline('Visit [[https://example.com][Example]]');
    expect(textOf(nodes)).toBe('Visit Example');
  });

  it('renders bare link [[url]]', () => {
    const nodes = renderInline('See [[https://example.com]]');
    const t = textOf(nodes);
    // Bare links extract filename from file: paths or show raw URL
    expect(t).toContain('example.com');
  });

  it('renders multiple links', () => {
    const nodes = renderInline('[[https://a.com][A]] and [[https://b.com][B]]');
    expect(textOf(nodes)).toBe('A and B');
  });

  it('renders link with special chars in URL', () => {
    const nodes = renderInline('[[https://example.com/path?q=1&r=2][Search]]');
    expect(textOf(nodes)).toBe('Search');
  });

  it('renders file: link with path simplification', () => {
    const nodes = renderInline('[[file:~/org/notes.org]]');
    expect(textOf(nodes)).toBe('notes.org');
  });
});

// ---------------------------------------------------------------------------
// formatTimestamp
// ---------------------------------------------------------------------------

describe('formatTimestamp', () => {
  const mkTs = (overrides: Partial<OrgTimestamp> = {}): OrgTimestamp => ({
    raw: '<2026-04-18 Sat>',
    date: '2026-04-18',
    ...overrides,
  });

  const mkComp = (overrides: Partial<OrgTimestampComponent> = {}): OrgTimestampComponent => ({
    year: 2026, month: 4, day: 18,
    ...overrides,
  });

  it('date-only timestamp renders human date', () => {
    const result = formatTimestamp(mkTs({ start: mkComp() }));
    expect(result).toMatch(/Apr/);
    expect(result).toMatch(/18/);
  });

  it('timestamp with time includes time', () => {
    const result = formatTimestamp(mkTs({
      start: mkComp({ hour: 14, minute: 30 }),
    }));
    expect(result).toMatch(/2:30/);
  });

  it('same-day time range shows "start – end-time"', () => {
    const result = formatTimestamp(mkTs({
      type: 'active-range',
      rangeType: 'timerange',
      start: mkComp({ hour: 14, minute: 30 }),
      end: mkComp({ hour: 16, minute: 0 }),
    }));
    expect(result).toContain('–'); // en-dash
    expect(result).toMatch(/2:30/);
    expect(result).toMatch(/4:00/);
  });

  it('multi-day range shows "start-date – end-date"', () => {
    const result = formatTimestamp(mkTs({
      type: 'active-range',
      rangeType: 'daterange',
      start: mkComp(),
      end: mkComp({ day: 22 }),
    }));
    expect(result).toContain('–');
    expect(result).toMatch(/18/);
    expect(result).toMatch(/22/);
  });

  it('cross-day range with times shows full dates + times', () => {
    const result = formatTimestamp(mkTs({
      type: 'active-range',
      rangeType: 'daterange',
      start: mkComp({ hour: 19, minute: 0 }),
      end: mkComp({ day: 19, hour: 1, minute: 0 }),
    }));
    expect(result).toContain('–');
    expect(result).toMatch(/7:00/);
    expect(result).toMatch(/1:00/);
  });

  it('returns raw string when start is missing', () => {
    const result = formatTimestamp(mkTs({ start: undefined }));
    expect(result).toBe('<2026-04-18 Sat>');
  });

  it('non-range timestamp without end returns just start', () => {
    const result = formatTimestamp(mkTs({
      type: 'active',
      start: mkComp({ hour: 9, minute: 0 }),
    }));
    expect(result).not.toContain('–');
  });
});

// ---------------------------------------------------------------------------
// formatComponentDate / formatComponentTime
// ---------------------------------------------------------------------------

describe('formatComponentDate', () => {
  it('formats a date component', () => {
    const result = formatComponentDate({ year: 2026, month: 4, day: 18 });
    expect(result).toMatch(/Apr/);
    expect(result).toMatch(/18/);
  });
});

describe('formatComponentTime', () => {
  it('formats a time component', () => {
    const result = formatComponentTime({ year: 2026, month: 4, day: 18, hour: 14, minute: 30 });
    expect(result).toMatch(/2:30/);
  });

  it('returns null when no hour/minute', () => {
    expect(formatComponentTime({ year: 2026, month: 4, day: 18 })).toBeNull();
  });

  it('handles midnight', () => {
    const result = formatComponentTime({ year: 2026, month: 4, day: 18, hour: 0, minute: 0 });
    expect(result).toBeTruthy();
    expect(result).toMatch(/12:00/);
  });
});

// ---------------------------------------------------------------------------
// parseNoteBlocks — Plain Lists (org spec §5.3)
// ---------------------------------------------------------------------------

describe('parseNoteBlocks — Plain Lists', () => {
  it('parses unchecked checkbox: - [ ] text', () => {
    const blocks = parseNoteBlocks('- [ ] Task one');
    expect(blocks).toHaveLength(1);
    expect(blocks[0].type).toBe('checklist');
    if (blocks[0].type === 'checklist') {
      expect(blocks[0].items).toHaveLength(1);
      expect(blocks[0].items[0].state).toBe(' ');
      expect(blocks[0].items[0].text).toBe('Task one');
    }
  });

  it('parses checked checkbox: - [X] text', () => {
    const blocks = parseNoteBlocks('- [X] Done');
    if (blocks[0].type === 'checklist') {
      expect(blocks[0].items[0].state).toBe('X');
    }
  });

  it('parses lowercase checked: - [x] text', () => {
    const blocks = parseNoteBlocks('- [x] Done');
    if (blocks[0].type === 'checklist') {
      expect(blocks[0].items[0].state).toBe('x');
    }
  });

  it('parses in-progress checkbox: - [-] text', () => {
    const blocks = parseNoteBlocks('- [-] In progress');
    if (blocks[0].type === 'checklist') {
      expect(blocks[0].items[0].state).toBe('-');
    }
  });

  it('parses plus bullet checkbox: + [ ] text', () => {
    const blocks = parseNoteBlocks('+ [ ] Task');
    expect(blocks[0].type).toBe('checklist');
  });

  it('parses star bullet checkbox: * [ ] text', () => {
    const blocks = parseNoteBlocks('* [ ] Task');
    expect(blocks[0].type).toBe('checklist');
  });

  it('parses ordered numeric dot: 1. [ ] text', () => {
    const blocks = parseNoteBlocks('1. [ ] First');
    expect(blocks[0].type).toBe('checklist');
  });

  it('parses ordered numeric paren: 1) [ ] text', () => {
    const blocks = parseNoteBlocks('1) [ ] First');
    expect(blocks[0].type).toBe('checklist');
  });

  it('parses alpha bullet: a. [ ] text', () => {
    const blocks = parseNoteBlocks('a. [ ] First');
    expect(blocks[0].type).toBe('checklist');
  });

  it('parses alpha paren: a) [ ] text', () => {
    const blocks = parseNoteBlocks('a) [ ] First');
    expect(blocks[0].type).toBe('checklist');
  });

  it('groups consecutive checklist items', () => {
    const blocks = parseNoteBlocks('- [ ] A\n- [X] B\n- [-] C');
    expect(blocks).toHaveLength(1);
    if (blocks[0].type === 'checklist') {
      expect(blocks[0].items).toHaveLength(3);
      expect(blocks[0].items[0].globalIndex).toBe(0);
      expect(blocks[0].items[1].globalIndex).toBe(1);
      expect(blocks[0].items[2].globalIndex).toBe(2);
    }
  });

  it('tracks indentation for nested items', () => {
    const blocks = parseNoteBlocks('- [ ] Parent\n  - [ ] Child');
    if (blocks[0].type === 'checklist') {
      expect(blocks[0].items[0].indent).toBe(0);
      expect(blocks[0].items[1].indent).toBe(2);
    }
  });

  it('plain text becomes text block', () => {
    const blocks = parseNoteBlocks('Hello, world!');
    expect(blocks).toHaveLength(1);
    expect(blocks[0].type).toBe('text');
    if (blocks[0].type === 'text') {
      expect(blocks[0].lines).toEqual(['Hello, world!']);
    }
  });

  it('blank lines are preserved in text blocks', () => {
    const blocks = parseNoteBlocks('Line one\n\nLine two');
    expect(blocks).toHaveLength(1);
    if (blocks[0].type === 'text') {
      expect(blocks[0].lines).toEqual(['Line one', '', 'Line two']);
    }
  });

  it('Created: timestamp is its own block', () => {
    const blocks = parseNoteBlocks('Created: [2026-04-18 Sat]');
    expect(blocks).toHaveLength(1);
    expect(blocks[0].type).toBe('created');
    if (blocks[0].type === 'created') {
      expect(blocks[0].date).toBe('2026-04-18 Sat');
    }
  });

  it('text after checklist is continuation (no blank line separator)', () => {
    const blocks = parseNoteBlocks('Intro text\n- [ ] Task\nConclusion');
    const types = blocks.map(b => b.type);
    expect(types).toEqual(['text', 'checklist']);
    if (blocks[1].type === 'checklist') {
      expect(blocks[1].items[0].text).toContain('Conclusion');
    }
  });

  it('blank line separates checklist from following text', () => {
    const blocks = parseNoteBlocks('- [ ] Task\n\nConclusion');
    const types = blocks.map(b => b.type);
    expect(types).toEqual(['checklist', 'text']);
  });

  it('appends sub-item text to last checklist item', () => {
    const blocks = parseNoteBlocks('- [ ] Parent\n  - Sub detail');
    if (blocks[0].type === 'checklist') {
      expect(blocks[0].items[0].text).toContain('Sub detail');
    }
  });

  it('globalIndex increments within a single checklist block', () => {
    const blocks = parseNoteBlocks('- [ ] A\n- [ ] B\n- [ ] C');
    if (blocks[0].type === 'checklist') {
      expect(blocks[0].items[0].globalIndex).toBe(0);
      expect(blocks[0].items[1].globalIndex).toBe(1);
      expect(blocks[0].items[2].globalIndex).toBe(2);
    }
  });
});

// ---------------------------------------------------------------------------
// Edge cases
// ---------------------------------------------------------------------------

describe('Edge cases', () => {
  it('empty string produces single empty text block', () => {
    const blocks = parseNoteBlocks('');
    expect(blocks).toHaveLength(1);
    expect(blocks[0].type).toBe('text');
  });

  it('renderInline with empty string returns the string', () => {
    const nodes = renderInline('');
    expect(textOf(nodes)).toBe('');
  });

  it('renderInline with plain text returns it unchanged', () => {
    const nodes = renderInline('Hello, world!');
    expect(textOf(nodes)).toBe('Hello, world!');
  });
});
