/**
 * Utilities for editing org-style checklist items in a raw notes string.
 */

/** Regex that matches a checklist item line (with leading indent). */
const CHECKLIST_LINE_RE = /^(\s*(?:[-+*]|(?:[0-9]+|[A-Za-z])[.)]) +)\[([ Xx\-])\](\s.*)$/;

/**
 * Toggle the nth checklist item (0-based) in `notes`.
 *
 * - `[ ]` / blank  → `[X]`
 * - `[X]` / `[x]`  → `[ ]`
 * - `[-]`           → `[X]`
 *
 * All other lines (non-checklist) are preserved verbatim. If `index` is out
 * of range the original string is returned unchanged.
 */
export function toggleChecklistLine(notes: string, index: number): string {
  const lines = notes.split('\n');
  let seen = -1;
  const result = lines.map(line => {
    const m = line.match(CHECKLIST_LINE_RE);
    if (!m) return line;
    seen++;
    if (seen !== index) return line;
    const state = m[2];
    const next = state.toLowerCase() === 'x' ? ' ' : 'X';
    return `${m[1]}[${next}]${m[3]}`;
  });
  return result.join('\n');
}

/**
 * Returns the number of checklist items (matched by `CHECKLIST_LINE_RE`)
 * in `notes`.
 */
export function countChecklistItems(notes: string): number {
  return notes.split('\n').filter(l => CHECKLIST_LINE_RE.test(l)).length;
}

/**
 * Reset all checklist items in `notes` to unchecked (`[ ]`).
 * Turns `[X]`, `[x]`, and `[-]` → `[ ]`. Non-checklist lines are unchanged.
 */
export function resetChecklist(notes: string): string {
  return notes.split('\n').map(line => {
    const m = line.match(CHECKLIST_LINE_RE);
    if (!m) return line;
    return `${m[1]}[ ]${m[3]}`;
  }).join('\n');
}
