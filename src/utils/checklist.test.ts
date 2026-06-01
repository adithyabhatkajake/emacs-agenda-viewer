import { describe, it, expect } from 'vitest';
import { toggleChecklistLine, countChecklistItems, resetChecklist } from './checklist';

const NOTES = [
  'Some preamble text.',
  '- [ ] Brush (3 min.)',
  '- [X] Make coffee',
  '- [-] Stretch',
  'Trailing note.',
].join('\n');

describe('toggleChecklistLine', () => {
  it('flips unchecked item to checked', () => {
    const result = toggleChecklistLine(NOTES, 0);
    const lines = result.split('\n');
    expect(lines[1]).toBe('- [X] Brush (3 min.)');
  });

  it('flips checked [X] item to unchecked', () => {
    const result = toggleChecklistLine(NOTES, 1);
    const lines = result.split('\n');
    expect(lines[2]).toBe('- [ ] Make coffee');
  });

  it('flips in-progress [-] item to checked', () => {
    const result = toggleChecklistLine(NOTES, 2);
    const lines = result.split('\n');
    expect(lines[3]).toBe('- [X] Stretch');
  });

  it('preserves all non-targeted lines exactly', () => {
    const result = toggleChecklistLine(NOTES, 0);
    const lines = result.split('\n');
    expect(lines[0]).toBe('Some preamble text.');
    expect(lines[2]).toBe('- [X] Make coffee');
    expect(lines[3]).toBe('- [-] Stretch');
    expect(lines[4]).toBe('Trailing note.');
  });

  it('handles lowercase [x] → unchecked', () => {
    const notes = '- [x] Task one';
    expect(toggleChecklistLine(notes, 0)).toBe('- [ ] Task one');
  });

  it('returns original string when index is out of range', () => {
    expect(toggleChecklistLine(NOTES, 99)).toBe(NOTES);
  });

  it('handles single-item notes', () => {
    const notes = '- [ ] Only item';
    expect(toggleChecklistLine(notes, 0)).toBe('- [X] Only item');
  });

  it('handles indented checklist items', () => {
    const notes = '- [ ] Parent\n  - [ ] Child';
    const result = toggleChecklistLine(notes, 1);
    expect(result).toBe('- [ ] Parent\n  - [X] Child');
  });

  it('preserves indentation of toggled line', () => {
    const notes = '  - [ ] Indented';
    const result = toggleChecklistLine(notes, 0);
    expect(result).toBe('  - [X] Indented');
  });

  it('does not affect a second toggle if indices are independent', () => {
    const after0 = toggleChecklistLine(NOTES, 0);
    const after1 = toggleChecklistLine(after0, 1);
    const lines = after1.split('\n');
    expect(lines[1]).toBe('- [X] Brush (3 min.)');
    expect(lines[2]).toBe('- [ ] Make coffee');
  });
});

describe('countChecklistItems', () => {
  it('counts all checklist lines', () => {
    expect(countChecklistItems(NOTES)).toBe(3);
  });

  it('returns 0 for notes with no checklist', () => {
    expect(countChecklistItems('Just plain text.')).toBe(0);
  });

  it('returns 0 for empty string', () => {
    expect(countChecklistItems('')).toBe(0);
  });
});

describe('resetChecklist', () => {
  it('resets [X] to [ ]', () => {
    const notes = '- [X] Done item';
    expect(resetChecklist(notes)).toBe('- [ ] Done item');
  });

  it('resets [x] to [ ]', () => {
    const notes = '- [x] Done item';
    expect(resetChecklist(notes)).toBe('- [ ] Done item');
  });

  it('resets [-] to [ ]', () => {
    const notes = '- [-] In-progress item';
    expect(resetChecklist(notes)).toBe('- [ ] In-progress item');
  });

  it('leaves already-unchecked items unchanged', () => {
    const notes = '- [ ] Unchecked';
    expect(resetChecklist(notes)).toBe('- [ ] Unchecked');
  });

  it('resets all checklist items in a mixed notes block', () => {
    const result = resetChecklist(NOTES);
    const lines = result.split('\n');
    expect(lines[1]).toBe('- [ ] Brush (3 min.)');
    expect(lines[2]).toBe('- [ ] Make coffee');
    expect(lines[3]).toBe('- [ ] Stretch');
    expect(lines[0]).toBe('Some preamble text.');
    expect(lines[4]).toBe('Trailing note.');
  });

  it('preserves non-checklist lines exactly', () => {
    const notes = 'Header\n- [X] Item\nFooter';
    const result = resetChecklist(notes);
    expect(result).toBe('Header\n- [ ] Item\nFooter');
  });

  it('handles empty string', () => {
    expect(resetChecklist('')).toBe('');
  });
});
