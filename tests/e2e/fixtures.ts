import type { Page } from '@playwright/test';

// Frozen "today" for deterministic rendering. Matches the Game Night event
// (<2026-04-18 Sat 19:00>--<2026-04-19 Sun 01:00>) that's at the heart of
// the rendering fix these tests guard.
export const TODAY = '2026-04-18';
export const EVENT_FILE = '/fake/cal.org';
export const EVENT_POS = 100;

const gameNightAgendaEntry = {
  id: `${EVENT_FILE}::${EVENT_POS}`,
  title: 'Game Night',
  agendaType: 'timestamp',
  tags: [],
  inheritedTags: [],
  category: 'Calendar',
  level: 1,
  file: EVENT_FILE,
  pos: EVENT_POS,
  timeOfDay: '19:00',
  extra: '(1/2):',
  tsDate: TODAY,
};

// Game Night also shows up in the `tasks' collection because it's an org
// heading (no TODO state). The category view renders it through TaskItem,
// which is the path that expands notes — that's where the timestamp chip
// rendering needs to hold up.
const gameNightTask = {
  id: `${EVENT_FILE}::${EVENT_POS}`,
  title: 'Game Night',
  tags: [],
  inheritedTags: [],
  category: 'Calendar',
  level: 1,
  file: EVENT_FILE,
  pos: EVENT_POS,
};

const gameNightNotes = {
  notes:
    '<2026-04-18 Sat 19:00>--<2026-04-19 Sun 01:00>\n' +
    '39784 Bissy Common Fremont, CA 94548',
  activeTimestamps: [
    {
      raw: '<2026-04-18 Sat 19:00>--<2026-04-19 Sun 01:00>',
      date: '<2026-04-18 Sat 19:00>',
      type: 'active-range',
      rangeType: 'daterange',
      start: { year: 2026, month: 4, day: 18, hour: 19, minute: 0 },
      end: { year: 2026, month: 4, day: 19, hour: 1, minute: 0 },
    },
  ],
};

// Install mocks for every /api/* route the client touches. The frontend only
// needs a static Vite server; there's no backend here.
export async function mockApi(page: Page): Promise<void> {
  // Freeze the client's notion of "today" so `todayStr()` in useTasks lines up
  // with the fixture date (and the agenda day request hits a predictable URL).
  await page.clock.install({ time: new Date(`${TODAY}T10:00:00`) });

  const json = (body: unknown) => ({
    status: 200,
    contentType: 'application/json',
    body: JSON.stringify(body),
  });

  // IMPORTANT: match only /api/X at the path root (with an optional query
  // string), never a Vite-served source file like /src/api/tasks.ts. A glob
  // like `**/api/tasks**` will silently intercept the module and break HMR.
  await page.route(/\/api\/tasks(\?|$)/, (r) => r.fulfill(json([gameNightTask])));
  await page.route(/\/api\/files(\?|$)/, (r) =>
    r.fulfill(json([{ path: EVENT_FILE, name: 'cal', category: 'Calendar' }]))
  );
  await page.route(/\/api\/keywords(\?|$)/, (r) =>
    r.fulfill(json({ sequences: [{ active: ['TODO', 'WAIT'], done: ['DONE', 'KILL'] }] }))
  );
  await page.route(/\/api\/config(\?|$)/, (r) =>
    r.fulfill(json({ deadlineWarningDays: 7 }))
  );
  await page.route(/\/api\/clock(\?|$)/, (r) =>
    r.fulfill(json({ clocking: false }))
  );
  await page.route(/\/api\/agenda\/day\//, (r) =>
    r.fulfill(json([gameNightAgendaEntry]))
  );
  await page.route(/\/api\/agenda\/range(\?|$)/, (r) =>
    r.fulfill(json([]))
  );
  await page.route(/\/api\/notes(\?|$)/, (r) =>
    r.fulfill(json(gameNightNotes))
  );
}
