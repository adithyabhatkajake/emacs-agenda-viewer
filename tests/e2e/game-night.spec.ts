import { test, expect } from '@playwright/test';
import { mockApi } from './fixtures';

// This spec guards the original bug that motivated the backend rewrite:
// the Game Night calendar event was rendering its active-range timestamp as
// raw `<2026-04-18 Sat 19:00>--<2026-04-19 Sun 01:00>` text inside the notes.
// After the fix, the notes renderer receives org-parsed structured timestamps
// and swaps each `raw' occurrence for a formatted chip.

test.beforeEach(async ({ page, isMobile }) => {
  await mockApi(page);
  await page.goto('/');
  // Wait for the initial load to settle — the "Today" heading only appears
  // once `useTasks' has resolved. Without this, the mobile hamburger check
  // below races the loading spinner.
  await expect(page.getByRole('heading', { name: 'Today' })).toBeVisible();

  // On mobile the sidebar starts collapsed — tap the hamburger to open it.
  if (isMobile) {
    await page.getByRole('button', { name: '\u2630' }).click();
    await expect(page.getByRole('heading', { name: 'Agenda' })).toBeVisible();
  }

  // Navigate to the Calendar category — that's the view path that renders
  // Game Night through TaskItem (the Today view puts untimed events in a
  // non-interactive banner strip instead).
  await page.getByRole('button', { name: /Calendar/ }).click();
  await expect(page.getByRole('heading', { name: 'Calendar' })).toBeVisible();
});

test('Game Night renders under Calendar category with its title and location', async ({ page }) => {
  const row = page.getByText('Game Night').first();
  await expect(row).toBeVisible();
  await row.click();
  await expect(page.getByText(/Bissy Common Fremont/)).toBeVisible();
});

test('active-range timestamp renders as a formatted chip, not raw angle-bracket text', async ({ page }) => {
  await page.getByText('Game Night').first().click();

  const chip = page.getByTestId('timestamp-chip');
  await expect(chip).toHaveCount(1);

  // Human-readable range: starts with a weekday, separates start/end with an
  // en-dash, and no raw `<` should slip through.
  const text = (await chip.innerText()).trim();
  expect(text).toMatch(/^Sat,? Apr 18/);
  expect(text).toContain('\u2013');
  expect(text).not.toContain('<');
  expect(text).not.toContain('-->');

  await expect(page.getByText('<2026-04-18 Sat 19:00>')).toHaveCount(0);
});

test('chip title attribute preserves the raw org timestamp for debugging', async ({ page }) => {
  await page.getByText('Game Night').first().click();
  const chip = page.getByTestId('timestamp-chip');
  await expect(chip).toHaveAttribute(
    'title',
    '<2026-04-18 Sat 19:00>--<2026-04-19 Sun 01:00>'
  );
});
