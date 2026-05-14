# Agents

This repo uses six specialized Claude Code subagents to keep work scoped to the right surface and to avoid drift across the four languages (Rust, Swift, TypeScript, Elisp) that share one wire format.

Definitions live in `.claude/agents/<name>.md`. Each agent has its own tool allowlist, test invocation, and deploy authority. Generic Claude (no agent) is fine for one-off questions; when work touches code, pick a specialist.

## TL;DR

| Agent | Owns | Tests with | Deploy? | Invoke when |
|---|---|---|---|---|
| `rust-daemon` | `daemon/` (7 crates) | `cargo test --workspace` | No | Parsing, indexing, agenda eval, HTTP routes, SSE, the Rust bridge client. |
| `emacs-bridge` | `elisp/` (eav.el + eav-bridge.el) | `ert` via batch emacs | No | New bridge methods, org-mode mutations, recursion-depth recovery. |
| `mac-app` | `apps/macos/` | `swift test`, `xcodebuild` | No | SwiftUI views, @Observable stores, EventKit, DaemonHost. |
| `web-app` | `src/`, `tests/e2e/` | `tsc`, Playwright, `vite build` | No | React components, hooks, API client, Playwright. |
| `contract-keeper` | wire types in 4 files | rust dump + tsc + swift build | No | Adding/changing fields on `OrgTask` / `AgendaEntry` / `OrgTimestamp` / any eav-core type. |
| `release-conductor` | `deploy*.sh`, `scripts/install-daemon.sh`, CI, `CHANGELOG.org` | n/a — runs the deploy | **Yes** | Version bump, `./deploy.sh`, visa-nonsoe sync, GitHub release. |

## Decision tree

Start at the top, descend until one applies:

1. **Am I changing a field on a wire type** (`OrgTask`, `AgendaEntry`, `OrgTimestamp`, `OrgConfig`, `CaptureTemplate`, `TodoKeywords`, `AgendaFile`, `HeadingNotes`, `RefileTarget`, or any type defined in `daemon/crates/eav-core/`)?
   → **contract-keeper FIRST.** It updates the four mirrored files atomically. After it lands, downstream specialists handle business logic in parallel.

2. **Am I shipping** (version bump, `./deploy.sh`, GH release, restarting daemons on visa-nonsoe)?
   → **release-conductor only.** It has ssh and launchctl/brew authority; specialists don't.

3. **Otherwise**: pick the surface specialist whose path I'm editing.
   - Files under `daemon/` → `rust-daemon`.
   - Files under `elisp/` → `emacs-bridge`.
   - Files under `apps/macos/` → `mac-app`.
   - Files under `src/`, `tests/e2e/`, `vite.config.ts`, `playwright.config.ts`, `package.json` → `web-app`.

If multiple specialists are needed (e.g. new bridge method + Rust client + UI), invoke them in parallel **after** contract-keeper has landed any wire change.

## Worked examples

### 1. Single-surface — "Add tag editing on the row context menu"

The API (`PATCH /api/tasks/:id/tags`) already exists. No wire change.

→ Invoke `web-app` with the task. It adds a tag picker in `TaskItem.tsx`, wires to `setTags()` in `src/api/tasks.ts`, runs `tsc --noEmit` + `playwright test tests/e2e/tag-editing.spec.ts`, builds, reports.

### 2. Cross-surface — "Add a `pinned` boolean to tasks"

The field doesn't exist anywhere yet. Wire change.

1. `contract-keeper` ← "Add `pinned: bool` to OrgTask, default false." It edits:
   - `daemon/crates/eav-core/src/lib.rs` (`pub pinned: bool`)
   - `apps/macos/EmacsAgendaViewer/Models/Models.swift` (`var pinned: Bool`)
   - `src/types.ts` (`pinned: boolean;`)
   - `elisp/eav.el` JSON encoder for tasks (`(cons 'pinned (...))`)
   - Verifies with `cargo build`, `tsc --noEmit`, `swift build`, `curl /api/tasks | jq '.[0].pinned'`.
2. **Then in parallel:**
   - `emacs-bridge` ← "Add `write.set-pinned` bridge method that sets a `:PINNED:` property."
   - `rust-daemon` ← "Add `PATCH /api/tasks/:id/pinned` route that calls the new bridge method, and have eav-parse populate `pinned` from `:PINNED:`."
   - `web-app` ← "Add a pin icon button on the task row, calls `setPinned()`."
   - `mac-app` ← "Add a pin context-menu action on `MacTaskRow`."
3. Once all green: `release-conductor` ← "Cut v0.5.1."

### 3. Release — "Cut 0.5.0"

→ `release-conductor` only. It:
- Verifies all specialists' tests are green.
- Bumps `daemon/Cargo.toml` + `apps/macos/project.yml` to `0.5.0`.
- Updates `CHANGELOG.org`.
- Runs `./deploy.sh` (local + visa-nonsoe).
- `curl /api/debug` on both targets.
- `git tag v0.5.0 && git push --tags`.
- `gh release create v0.5.0` with CHANGELOG section.

## Memory dependencies

Each agent's system prompt cites entries from the user's auto-memory at `~/.claude/projects/-Users-hermitsage-Github-Emacs-Agenda-Viewer/memory/`. If you rename or delete a memory file, update the corresponding agent prompt to match.

| Agent | Cites memory |
|---|---|
| `rust-daemon` | (none specific — uses general project knowledge) |
| `emacs-bridge` | `feedback_use_org_apis.md` (must delegate to org APIs, never reimplement) |
| `mac-app` | (none specific) |
| `web-app` | (none specific) |
| `contract-keeper` | `feedback_no_claude_coauthor.md` (commit trailer) |
| `release-conductor` | `feedback_brew_services.md` (prefer brew services), `reference_visa_nonsoe.md` (remote layout), `feedback_no_claude_coauthor.md` |

All agents that produce commits honor `feedback_no_claude_coauthor.md` — no `Co-Authored-By: Claude` trailer (a hook blocks them).

## Boundaries (what no agent does)

- **No "diagnostic doctor" agent.** Cold-boot debugging (stale bridge socket, recursion-depth deadlock, launchd quirks) is handled ad-hoc by `emacs-bridge` + `release-conductor`. The diagnostic flow doesn't reuse enough between incidents to justify its own definition.
- **No split inside `rust-daemon`.** The 7 crates form one Cargo workspace; one agent reasons about the whole pipeline. Splitting into parser/server adds handoff overhead with no upside.
- **No split inside `mac-app`.** The @Observable state seam is too central to separate from views/networking.
- **Generic Claude is fine for** questions ("what does this code do?"), reviewing PRs, exploratory research, and anything that doesn't write code.

## Adding a new agent

1. Copy `.claude/agents/web-app.md` as a template (it has all the standard sections).
2. Fill in: `name`, `description`, `tools`, `model`, `Scope`, `Test invocations`, `Build authority`, `Contract boundary`, `Known gotchas`, `Commit style`, `Reporting`.
3. Add a row to the TL;DR table above and a line to "Memory dependencies" if applicable.
4. Smoke-test with one trivial prompt before relying on it.

Keep the agent count small. Six is a working set the user can hold in their head; ten would not be. The bar for a new agent is "this work is meaningfully different from any existing surface AND will recur often enough that the per-agent context is worth maintaining."
