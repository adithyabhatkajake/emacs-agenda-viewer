# Emacs Agenda Viewer — Cross-Platform Design System

The single source of truth for the **design language** shared by the three
clients that render org-agenda data:

- **Web** — React + Tailwind (`src/`). Tokens: `src/index.css` CSS custom
  properties (light `:root` + `.dark`), mapped to utilities in
  `tailwind.config.js`.
- **iOS** — SwiftUI (`apps/macos/EmacsAgendaViewer/`). Tokens: `Theme.swift`
  + `Color+Hex.swift`. Shared visual primitives in `Views/Components/`.
- **Mac** — SwiftUI (`apps/macos/EmacsAgendaViewerMac/`). Reuses `Theme.swift`
  / `Color+Hex.swift` / `AppSettings` from the iOS target but renders its own
  rows (`MacTaskRow.swift`) and a sidebar (`RootView.swift`).

The three surfaces are **intentionally different in idiom** — touch (iOS),
pointer (Mac), responsive web. A bottom tab bar on iOS and a source-list
sidebar on Mac are *correct*, not drift. What must stay coherent is the
**design language**: state/priority/date semantics, color *meaning*,
terminology, and iconography concepts.

> This document is **descriptive of current truth** plus **proposed canonical
> resolutions** for drift. It does not change app code. Bold "→ Canonical:"
> lines are proposals for implementers; everything else is what exists today.

---

## 1. Surfaces & hierarchy

Tier values are RGB. Web stores them as space-separated triples in CSS vars;
Apple stores the identical values in `Theme.swift` as `Color(red:green:blue:)`
fractions. **These match exactly across web and Apple** (verified hex-for-hex).

**Dark mode is high-contrast near-black ("B2", reworked 2026-05-25):** a
**pure-black base** (#000) with content cards/rows **floating on the surface
tier** (#242428). See the *Dark-mode elevation model* note below. **Light mode
is unchanged** and a light-mode rework is deferred to a separate future pass.

| Tier | Web var | Apple token | Light RGB | Dark RGB |
|---|---|---|---|---|
| Background | `--things-bg` | `Theme.background` | 255 255 255 | 0 0 0 |
| Sidebar | `--things-sidebar` | *(web only)* | 245 245 247 | 26 26 28 |
| Sidebar hover | `--things-sidebar-hover` | *(web only)* | 232 232 237 | 52 52 56 |
| Sidebar active | `--things-sidebar-active` | *(web only)* | 221 221 227 | 70 70 74 |
| Surface | `--things-surface` | `Theme.surface` | 240 240 242 | 36 36 40 |
| Surface elevated | *(web: sidebar-hover)* | `Theme.surfaceElevated` | 232 232 237 | 52 52 56 |
| Border | `--things-border` | `Theme.border` | 209 209 214 | 68 68 74 |
| Border subtle | `--things-border-subtle` | `Theme.borderSubtle` | 229 229 234 | 50 50 54 |
| Accent | `--accent` | `Theme.accent` | 52 120 246 | 95 160 244 |
| Accent teal | `--accent-teal` | `Theme.accentTeal` | 0 164 199 | 100 210 255 |

**Sidebar tiers are web-only tokens.** On Mac the source-list background is
the native `List(.sidebar)` material (NSVisualEffect), not an explicit hex.
iOS has no persistent sidebar. This is correct platform idiom — do not port
`--things-sidebar` to Apple.

### Text tiers (match exactly)

| Tier | Web var | Apple token | Light RGB | Dark RGB |
|---|---|---|---|---|
| Primary | `--text-primary` | `Theme.textPrimary` | 29 29 31 | 250 250 252 |
| Secondary | `--text-secondary` | `Theme.textSecondary` | 110 110 115 | 176 176 182 |
| Tertiary | `--text-tertiary` | `Theme.textTertiary` | 174 174 178 | 134 134 140 |

### Dark-mode elevation model (reworked 2026-05-25, user-approved)

Dark mode uses an **OLED-black base + floating-surface** elevation model:

- The base/background is **pure black** (#000) on all three surfaces.
- Content **cards/rows float on the surface tier** (#242428), giving clear
  elevation contrast against the black base.
- **Web** does this via a `.dark .task-card { background: var(--things-surface); }`
  override.
- **Apple** does this by rendering task rows on `Theme.surface` (rows
  previously sat on the window background).

Rationale: OLED-black base plus an explicit elevation step that reads cards as
lifted off the canvas. This is identical in concept and value across web + iOS
+ Mac. *(Light mode does not use a floating-card override; its rework is a
separate future pass.)*

### Category dot palette (web only)

`--dot-{yellow,blue,purple,red,green,orange,gray}` (`src/index.css:42-48`).
Web maps category→dot deterministically (`TaskItem.tsx:82-103`, hashed with
named overrides: inbox=blue, work=purple, personal=green, calendar=orange,
meta=gray). **Mac** renders category as a text capsule pill in `textSecondary`
(`MacTaskRow.swift:467`), not a colored dot. **iOS** renders category as plain
`textTertiary` caption text (`TaskRow.swift:61`), no dot, no pill.
*Drift D7 — see §9.*

---

## 2. TODO-state semantics

Keywords are **user-configurable** via `/api/keywords` → `TodoKeywords`
(`{ sequences: [{ active: [...], done: [...] }] }`). The design contract is the
*mapping rule*, not a fixed keyword list. The done/active partition always
comes from the API sequence the keyword belongs to; never hardcode it.

**Pill treatment (shared intent):** small uppercase label, tinted background at
low opacity, foreground = the state's color. Square-ish corner.

| Property | Web (`TodoStateMenu.tsx`) | iOS (`TodoStatePill.swift`) | Mac (`MacTaskRow.statePill`) |
|---|---|---|---|
| BG opacity | `/12` (0.12) | `0.15` | `0.14` |
| Corner radius | `rounded-md` (~6px) | 4 | 3 |
| Font | bold, 10–11px | `caption2.semibold` | size 10 **heavy monospaced** |
| Border | yes, `/20` | none | none |
| Color source | `resolvedStateColorToken` (user override → grouped-by-meaning default) | `resolvedTodoStateColor` (user override → default map) | same as iOS |

### Keyword → default color

iOS/Mac share `AppSettings.defaultTodoStateColor` (`AppSettings.swift:279`):

| Keyword group | Apple color |
|---|---|
| any **done** state | `doneGreen` |
| `TODO` | `accent` |
| `NEXT STARTED DOING ACTV` | `accentTeal` |
| `WAIT WAITING HOLD BLOCKED SMDY` | `priorityB` (orange) |
| `CANCELLED CANCELED` | `textTertiary` |
| default (unknown active) | `accent` |

Web `resolvedStateColorToken(state, isDone)` (`TodoStateMenu.tsx`) now uses the
**same grouped-by-meaning default** as Apple. The done/active partition is
driven by the live `TodoKeywords` (via the `isDoneState` prop), not a hardcoded
list:

| Keyword group | Web token | Apple color |
|---|---|---|
| any **done** state | `done-green` | `doneGreen` |
| `TODO` | `accent` | `accent` |
| `NEXT STARTED DOING ACTV PROG` | `accent-teal` | `accentTeal` |
| `WAIT WAITING HOLD BLOCKED SMDY` | `priority-b` (orange) | `priorityB` (orange) |
| `CANCELLED CANCELED` | `text-tertiary` | `textTertiary` |
| default (unknown active) | `accent` | `accent` |

**D1 — RESOLVED (2026-05-24).** Web's `TodoStateMenu.tsx` was rewritten to drop
the per-keyword `stateStyle` map and adopt the grouped meaning map above
(started/active = teal, waiting/blocked = orange, cancelled = tertiary), which
generalizes to the user's custom keywords the same way Apple's
`defaultTodoStateColor` does. The web-only `KILL`→red special case was
**dropped** — `KILL` now renders `done-green` like any other done state.
*(Historical: web previously keyed color on individual spellings, so `NEXT`
showed orange and `ACTV` green on web while Apple showed teal for both.)*

**Done-state row affordance (non-color):** all three strike through the title
and dim it. Web `opacity-40` + `line-through` (`TaskItem.tsx:300,383`); iOS/Mac
`.strikethrough` + `textTertiary` (`TaskRow.swift:40`, `MacTaskRow.swift:281`).
Checkbox fills green when done (all three). ✓ conforms.

---

## 3. Priority

Org priorities A/B/C/D; "no priority" is a distinct rendered state.

| Priority | Web var / Apple token | Light RGB | Dark RGB | Meaning label (web) |
|---|---|---|---|---|
| A | `--priority-a` / `Theme.priorityA` | 255 59 48 | 255 69 58 | Urgent |
| B | `--priority-b` / `Theme.priorityB` | 255 149 0 | 255 159 10 | High |
| C | `--priority-c` / `Theme.priorityC` | 52 120 246 | 95 160 244 | Normal |
| D | `--priority-d` / `Theme.priorityD` | 142 142 147 | 99 99 102 | Low |
| none | `text-tertiary` / `textTertiary` | 174 174 178 | 99 99 102 | No priority |

**Color values match exactly across all three surfaces.** ✓

**Shape (D2 — RESOLVED 2026-05-25):**

| | Web (`PriorityMenu.tsx:70`) | iOS (`PriorityBadge.swift`) | Mac (`MacTaskRow.priorityBox`) |
|---|---|---|---|
| Treatment | tinted pill, BG `/12`, colored letter, border | tinted pill, BG `0.15`, colored letter | tinted pill, BG opacity, colored letter |
| Radius | `rounded` (~4px) | 4 | 3 |
| "none" | shows `—` in surface chip | rendered as `textTertiary` (hidden if empty) | not rendered when empty |

All three now render priority as a *tinted* badge (colored letter on faint
tint of the same priority color). Mac previously rendered a solid-filled box
with a white letter — a visually different object for the same datum.

**D2 — RESOLVED (2026-05-25).** Mac `priorityBox` switched from solid-fill /
white-letter to a tinted badge (letter = priority color, background = same
color at 0.15 opacity), matching iOS `PriorityBadge` and web `PriorityMenu`.
(Web C uses `accent` tint while the token `--priority-c` exists and equals
accent's value — cosmetically identical, left as-is.)

Web exposes priority **descriptions** (Urgent/High/Normal/Low) in its picker;
Apple pickers list only the letter. Concept-level nicety, not drift.

---

## 4. Date semantics

Four states with distinct meaning: **scheduled**, **deadline**, **overdue**
(a deadline/scheduled date in the past), **done** (handled in §2). Color must
never be the only signal.

### Scheduled

| | Web | iOS (`DateBadge .scheduled`) | Mac (`scheduledPill`) |
|---|---|---|---|
| Color | `text-tertiary` (plain meta text) | `Theme.textSecondary` | `textSecondary` (neutral) |
| Icon | none | `calendar` | `calendar` |
| Container | none (inline text) | none (icon + text) | icon + text (no container) |

### Deadline (severity-graded)

Severity buckets are **identical logic** across all three surfaces: overdue
(`days<0`), soon (`days<=2`), normal (`else`). Web buckets via the
`deadlineSoon` computation in `TaskItem.tsx` and the three-way `colorClass` in
`ScheduleTray.tsx`.

| Severity | Color (all) | iOS icon | Mac icon | Web |
|---|---|---|---|---|
| overdue | `priorityA` (red) | `exclamationmark.circle` | `exclamationmark.circle` | `priority-a` red, `Nd overdue` / org `extra` |
| soon (≤2d) | `priorityB` (orange) | `exclamationmark.circle` | `exclamationmark.circle` | `priority-b` orange |
| normal | iOS `textSecondary` / Mac `textSecondary` / web `text-tertiary` | `exclamationmark.circle` | `exclamationmark.circle` | `text-tertiary` muted meta text |

**Non-color overdue affordance (all three carry one):** iOS `TaskRow` shows a
leading `exclamationmark.triangle.fill` glyph + accessibility "Overdue"
(`TaskRow.swift:55`). Web prints the literal text `"{n}d overdue"`
(`TaskItem.tsx:70`) — a text affordance. Mac now renders a leading
`exclamationmark.triangle.fill` glyph + `.accessibilityLabel("Overdue")` on
overdue items (`MacTaskRow.swift`), no longer relying on red color alone.

### today / future / past labeling

All three produce relative labels (Today / Tomorrow / Yesterday / weekday /
`MMM d`). iOS/Mac share `DateBadge.relativeLabel` (`DateBadge.swift:53`); web
has parallel logic in `formatTimestamp`/`formatRelativeDate`
(`TaskItem.tsx:57,106`). Minor wording differences (web weekday `Mon`, iOS full
`Monday` for 2–6 days out; web has no "Last Monday" form). ✓ semantically.

**Drifts:**

- **D3 — Deadline icon + overdue affordance (RESOLVED 2026-05-25 — all three).**
  Single deadline glyph everywhere: web renders `WarningCircle` (Phosphor
  exclamation-in-circle), iOS and Mac both use `exclamationmark.circle` (Mac
  swapped `flag.fill` → `exclamationmark.circle`). And all three now carry a
  non-color overdue signal: web's `"{n}d overdue"` text, iOS's
  `exclamationmark.triangle.fill` + "Overdue" a11y label, and Mac's newly-added
  `exclamationmark.triangle.fill` + `.accessibilityLabel("Overdue")`.
- **D4 — Scheduled color (RESOLVED 2026-05-25).** Mac previously tinted
  scheduled in accent-blue (`priorityC`) as a prominent pill + border; it now
  renders a neutral `calendar` icon + relative-date text at `textSecondary`
  with no container, matching iOS `DateBadge .scheduled` and web. Accent stays
  reserved for interactive/selected affordances. Scheduled is neutral on all
  three.
- **D5 — Deadline "soon" bucket on web (RESOLVED 2026-05-25 — all three).**
  Web now buckets deadlines three ways like Apple: overdue (`days<0` →
  `priority-a` red), soon (`0–2d` → `priority-b` orange), normal (else →
  `text-tertiary` muted), via the `deadlineSoon` computation in `TaskItem.tsx`
  and the three-way `colorClass` in `ScheduleTray.tsx`. All three surfaces now
  bucket overdue/soon/normal identically.

---

## 5. Tags

Shared intent: small low-emphasis chip; inherited tags are dimmer than direct
tags.

All three now share the iOS `TagChips` treatment: a **filled capsule, no `#`
prefix**, with inherited tags dimmer than direct tags via two-tier color +
fill. Web and Apple both carry separate `tags` / `inheritedTags` fields and
filter inherited-duplicates.

| | Web (`TaskItem.tsx` row chips) | iOS (`TagChips.swift`) | Mac (`MacTaskRow.tagChip`) |
|---|---|---|---|
| Shape | `Capsule` (filled) | `Capsule` (pill) | `Capsule` (filled) |
| Prefix | none | none | none |
| Direct color | `text-secondary` on `things-surface` | `textSecondary` on `surfaceElevated` 0.8 | `textSecondary` on `surfaceElevated` 0.8 |
| Inherited | `text-tertiary` on `things-sidebar-hover`/40 | `textTertiary` on `surfaceElevated` 0.4 | `textTertiary` on `surfaceElevated` 0.4 |
| Font | 10–11px | `caption2` | `caption2` |

**Drifts:**

- **D6 — Tag chip shape + `#` prefix (RESOLVED 2026-05-25 — all three).** Mac
  `tagChip` switched from a stroked `RoundedRectangle` r=4 + `#` prefix +
  monospaced font to a filled `Capsule` mirroring iOS `TagChips.swift`. Web
  `TaskItem.tsx` now renders per-row tag chips (previously tags showed only in
  the picker / expanded panel, not the row) as the same filled capsule — direct
  = `text-secondary` on `things-surface`, inherited = dimmer `text-tertiary` on
  `things-sidebar-hover`/40, with inherited-duplicates filtered. All three
  render the same filled-capsule, no-prefix, dim-inherited treatment.

Truncation/overflow: none of the three implement explicit tag overflow
collapse (e.g. "+3"). All rely on `lineLimit`/flex wrap. Flagged as a future
concept, not a drift.

---

## 6. Iconography (concept → icon)

Apple uses **SF Symbols**; web now uses **Phosphor Icons**
(`@phosphor-icons/react`), which replaced the former emoji/Unicode glyphs in
the sidebar (`Sidebar.tsx`) and inline. **Cross-platform state convention:**
Phosphor's `regular`/`fill` weights mirror SF Symbols' outline/`.fill` pairing
— **regular = inactive/default, fill = active/selected/done** on every surface.

| Concept | Web (Phosphor) | iOS SF Symbol | Mac SF Symbol |
|---|---|---|---|
| Inbox | `Tray` | `tray` (empty state) | `tray.and.arrow.down.fill` |
| All Tasks | `ListBullets` | `list.bullet` (tab) | `tray.fill` |
| Pinned / My Day | `PushPin` (fill when pinned/active) | `pin.fill` (menu) | `pin.fill` |
| Today | `Star` (fill when active) | `star.fill`* / `sparkles` (empty) | `star.fill` |
| Upcoming | `CalendarBlank` | — (merged into Home) | `list.bullet` |
| Habits | `Repeat` | `arrow.triangle.2.circlepath` | `arrow.triangle.2.circlepath` |
| Eisenhower | `GridFour` | — (no iOS view) | `square.grid.2x2.fill` |
| Calendar | `CalendarDots` | — | `calendar` |
| Logbook | `BookBookmark` | `book.closed.fill` | `book.closed.fill` |
| Capture | `Plus` | `plus`/FAB | `plus.circle` |
| Refile | *(text-only menu item — no glyph)* | `doc.text.magnifyingglass` (empty) | *(text menu "Refile…")* |
| Schedule | `CalendarPlus` | `calendar` / `calendar.badge.plus` | `calendar` |
| Deadline | `WarningCircle` | `exclamationmark.circle` | `exclamationmark.circle` |
| Clock (running / stop) | `Play` / `Stop` | `stopwatch.fill` | `stopwatch.fill` |
| Tag | `Tag` | *(no row icon)* | `#` prefix text |
| Priority | *(letter)* | *(letter badge)* | *(letter box)* |
| Done / checkbox | `Circle` / `CheckCircle` (fill when done) | `circle`/`checkmark.circle.fill` | `circle`/`checkmark.circle.fill` |
| Repeater | `Repeat` | `arrow.triangle.2.circlepath` | `arrow.triangle.2.circlepath` |
| Refresh | `ArrowsClockwise` | pull-to-refresh | SSE + menu |
| Settings | `Gear` | `gearshape.fill` | *(native)* |
| Theme dark / light / auto | `Moon` / `Sun` / `SunHorizon` | — | — |
| Section collapse chevron | `CaretRight` (rotates when expanded) | — | — |
| Streak fire (Habits) | `Fire` (fill) | — | — |
| Close / cancel | `X` | — | — |
| Edit notes | `PencilSimple` | — | — |

`*` iOS Today icon: the Home tab is `house.fill`; "Today" as a concept inside
Home uses `star.fill`/`sparkles`. Mac's dedicated Today sidebar item is
`star.fill`.

**Drifts:**

- **D8 — RESOLVED (2026-05-24).** All three surfaces now agree on the Habits
  glyph. iOS swapped `repeat.circle` → `arrow.triangle.2.circlepath`
  (RootView.swift Habits tab + HabitsView empty state), matching Mac's
  `arrow.triangle.2.circlepath` and web's Phosphor `Repeat` — the canonical
  repeater concept, which ties Habits to the per-task repeater glyph.
- **D9 — Inbox glyph.** iOS `tray` vs Mac `tray.and.arrow.down.fill` (iOS only
  uses it in an empty state, no dedicated Inbox view). Align on
  `tray.and.arrow.down` family when iOS gains an Inbox surface.
- **D10 — RESOLVED (2026-05-24).** All three surfaces now agree on the Logbook
  glyph. iOS swapped `checkmark.seal` → `book.closed.fill` (RootView.swift
  Logbook tab + LogbookView empty state), matching Mac's `book.closed.fill` and
  web's Phosphor `BookBookmark` — the book-of-past-entries metaphor (the old
  `checkmark.seal` read as "verified").
- **D11 — RESOLVED (2026-05-24).** Web adopted **Phosphor Icons**
  (`@phosphor-icons/react`), replacing all emoji/Unicode glyphs in the sidebar
  and inline. Phosphor was chosen over the previously-proposed **lucide-react**
  because its `regular`/`fill` weight pair mirrors SF Symbols' outline/`.fill`
  state pairing — the shipped rule is **regular = inactive/default, fill =
  active/selected/done**, now the cross-platform state convention (see §6
  intro). Concept→Phosphor map is in the §6 table. Note: **Refile** is a
  text-only menu item on web (no glyph), matching the text-menu treatment on
  Mac. *(tsc clean, 68 tests pass, build green.)*

---

## 7. Typography

| Role | Web | iOS | Mac |
|---|---|---|---|
| Family | **Inter** (variable, local woff2) + system fallback | system (SF) | system (SF) |
| Title | 13–14px, snug | `.body` (~17pt) | size 14 regular |
| State pill | 10–11px bold | `caption2.semibold` | size 10 heavy **monospaced** |
| Meta / date | 10–11px | `caption2` | size 11 |
| Section header | 9–11px uppercase tracked | `LargePageHeader` pretitle uppercase | uppercase tracked |
| Tag | — | `caption2` | size 10.5 **monospaced** |

Web ships its own **Inter** typeface; Apple uses the system **SF** font. This
is acceptable platform idiom (a web app can't assume SF). Mac's use of a
*monospaced* state pill / tag font is a Mac-only stylistic choice not mirrored
on iOS or web — noted, low impact, not a tracked drift.

---

## 8. Terminology canon

One spelling, one capitalization, per concept. **The big drift is the Pinned
view's name.**

| Canonical concept | Web sidebar | iOS | Mac sidebar |
|---|---|---|---|
| Today | `Today` | header pretitle `TODAY` (in Home) | `Today` |
| Upcoming | `Upcoming` | (section inside Home) | `Upcoming` |
| Inbox | `Inbox` | *(no view)* | `Inbox` |
| All Tasks | `All Tasks` | `All Tasks` (tab) | `All Tasks` |
| **My Day** | `My Day` | `MY DAY` (section) + "Pin to My Day" action | `My Day` |
| Logbook | `Logbook` | `Logbook` (tab) | `Logbook` |
| Habits | `Habits` | `Habits` (tab) | `Habits` |
| Eisenhower | `Eisenhower` | *(no view)* | `Eisenhower` |
| Calendar | `Calendar` | *(no view)* | `Calendar` |
| Capture | (tooltip "New task") | "Capture" sheet | `Capture` (toolbar) |
| Refile | `Refile` | `Refile` | `Refile…` |
| Clock | `Clock In`/`Clock Out` | clock | `Clock In`/`Clock Out` |

**Drifts:**

- **D12 — RESOLVED (2026-05-24).** Standardized on **"My Day"** for the
  *view/destination* name everywhere (it reads as a place, matching the "Pin
  **to My Day**" verb on all three surfaces). Mac sidebar `Pinned` → `My Day`
  (`RootView.swift`), Mac `MacPinnedView` navigation title + section header
  `PINNED` → `MY DAY`, iOS `HomeView` section header `PINNED` → `MY DAY`. The
  underlying `:PINNED:` property key and the "Pin to My Day" / "Unpin from My
  Day" *action* verbs are unchanged.
- **D13 — RESOLVED (2026-05-24).** Web renamed the clock-stop label
  **"Stop Clock" → "Clock Out"** (TaskItem.tsx button + ClockDock.tsx
  aria-label), pairing with "Clock In" and matching the Apple wording on iOS
  and Mac.

---

## 9. Interaction concepts

Concept-level contracts; the *gesture* is per-platform and correct as-is.

| Concept | Meaning | Web | iOS | Mac |
|---|---|---|---|---|
| Optimistic update | mutate then refetch | `setUpdating` + `onRefresh` | `OptimisticPatch` | `OptimisticPatch` |
| Refresh | re-pull current data | manual / SSE | pull-to-refresh + SSE | SSE + menu |
| Live update | server push | SSE `/api/events` | SSE | SSE (`EventSubscriber`) |
| Context actions | per-task menu | right-click / long-press | swipe + sheet | right-click context menu |
| Expand detail | show notes/dates | inline expand | push `TaskDetailView` | inspector pane |
| Empty state | friendly "nothing here" | text | `EmptyStateView` + symbol | `EmptyStateView` |
| Loading | delayed spinner | text | `DelayedProgressView` | `DelayedProgressView` / `ConnectingStateView` |
| Error | retryable message | console + UI | `ErrorStateView` | `DaemonFailedView`/`ErrorStateView` |

These conform at the concept level. ✓

**Surface coverage gaps (concepts present on one client, missing on another):**

- **G1 — Inbox:** view exists on web + Mac, **absent on iOS** (only an empty-
  state icon). iOS users reach inbox items only via All Tasks.
- **G2 — Eisenhower:** web + Mac, **absent on iOS**.
- **G3 — Calendar:** web + Mac, **absent on iOS**.
- **G4 — Upcoming/Pinned/Today as discrete destinations:** discrete on web +
  Mac; **merged into one "Home" feed on iOS** (intentional touch idiom — a
  single scroll instead of tab-switching). This is a *deliberate* idiom, not a
  bug, but note that iOS cannot deep-link to "Upcoming" alone.
- **G5 — Clock dock:** persistent multi-timer dock on Mac (`MacClockDock`) and
  web (`ClockDock`); iOS shows clock state in the Home header only.

These are scope/feature gaps for the implementer agents (and `contract-keeper`
if a new surface needs new fields), not visual drift.

---

## 10. Per-platform token map (quick reference)

| Design token | Web (CSS var / utility) | iOS / Mac (Theme.swift) |
|---|---|---|
| Background | `--things-bg` / `bg-things-bg` | `Theme.background` |
| Surface | `--things-surface` / `bg-things-surface` | `Theme.surface` |
| Surface elevated | `--things-sidebar-hover` | `Theme.surfaceElevated` |
| Border | `--things-border` | `Theme.border` |
| Border subtle | `--things-border-subtle` | `Theme.borderSubtle` |
| Accent | `--accent` / `text-accent` | `Theme.accent` |
| Accent teal | `--accent-teal` | `Theme.accentTeal` |
| Text primary | `--text-primary` | `Theme.textPrimary` |
| Text secondary | `--text-secondary` | `Theme.textSecondary` |
| Text tertiary | `--text-tertiary` | `Theme.textTertiary` |
| Done | `--done-green` / `text-done-green` | `Theme.doneGreen` |
| Priority A | `--priority-a` | `Theme.priorityA` |
| Priority B | `--priority-b` | `Theme.priorityB` |
| Priority C | `--priority-c` | `Theme.priorityC` |
| Priority D | `--priority-d` | `Theme.priorityD` |
| Category dots | `--dot-*` | *(no equivalent — uses pill/text)* |
| State color (resolved) | `resolvedStateColorToken` (override → grouped default) | `AppSettings.resolvedTodoStateColor` |
| Priority color (resolved) | hardcoded `PRIORITIES` map | `AppSettings.resolvedPriorityColor` |

**G6 — PARTIAL (2026-05-24).** Web now has a **state-color override layer**:
`resolvedStateColorToken(state, isDone)` reads a user override map persisted to
`localStorage` (`eav-todo-state-colors`, guarded by a `VALID_TOKENS` allowlist)
before falling back to the grouped default — the web equivalent of Apple's
`resolvedTodoStateColor`. Still pending: (1) web has **no UI to set** the
overrides yet (deferred — needs a settings-control design), and (2) priority
(`priorityColors`) and category (`categoryColors`) overrides remain
**Apple-only**, so recoloring a priority/category in Apple settings still does
not propagate to web.

---

## Consistency matrix (summary)

Legend: ✓ conforms · ◐ partial · ✗ drift · — n/a / not present.

| Row | Web | iOS | Mac |
|---|---|---|---|
| Surface/text tier values | ✓ | ✓ | ✓ |
| Sidebar tier tokens | ✓ | — | — (native material) |
| Priority colors (A–D) | ✓ | ✓ | ✓ |
| Priority badge shape | ✓ tinted | ✓ tinted | ✓ tinted |
| Priority "none" | ✓ | ✓ | ✓ |
| State pill treatment | ✓ | ✓ | ✓ |
| State→color map (meaning) | ✓ grouped | ✓ grouped | ✓ grouped |
| User color overrides | ◐ state colors only, no editor UI yet (G6) | ✓ | ✓ |
| Done row affordance | ✓ | ✓ | ✓ |
| Scheduled color | ✓ neutral | ✓ neutral | ✓ neutral |
| Deadline severity buckets | ✓ | ✓ | ✓ |
| Deadline icon | ✓ `WarningCircle` | ✓ `excl.circle` | ✓ `excl.circle` |
| Overdue non-color signal | ✓ text | ✓ glyph | ✓ glyph |
| Relative date labels | ✓ | ✓ | ✓ |
| Tag chip shape | ✓ capsule | ✓ capsule | ✓ capsule |
| Category rendering | dot | text | pill (D7) |
| Habits icon | ✓ `Repeat` | ✓ `arrow.triangle.2.circlepath` | ✓ `arrow.triangle.2.circlepath` |
| Logbook icon | ✓ `BookBookmark` | ✓ `book.closed.fill` | ✓ `book.closed.fill` |
| Icon system | ✓ Phosphor | SF Symbols | SF Symbols |
| My Day view name | ✓ "My Day" | ✓ "MY DAY" | ✓ "My Day" |
| Clock-out label | ✓ "Clock Out" | ✓ "Clock Out" | ✓ "Clock Out" |
| Inbox view | ✓ | — (G1) | ✓ |
| Eisenhower view | ✓ | — (G2) | ✓ |
| Calendar view | ✓ | — (G3) | ✓ |
</content>
</invoke>
