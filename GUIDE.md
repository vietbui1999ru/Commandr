# Commandr — Workflow Guide

How to start and run the Commandr toolchain as it exists **today**.

> **Maintenance policy — read this first.**
> This file is a living document. Any change to `bin/` tools, `protocol/SPEC.md`,
> `adapters/`, conformance behavior, or the DiffViewer ingestion contract MUST be
> reflected here in the same session that lands the change. Revisit the
> "Current feature state" table at the end of every working session. If this guide
> and the code disagree, the code (and `protocol/SPEC.md`) win — then fix the guide.

Last updated: 2026-06-12 (SPEC v0.2 §12.7 council diff mode landed — `bin/council --diff <range>|-` is bus-less; emits a verdict JSON on stdout with no `.agents/` side effect, the seam the `review-council` / `delegate-pi` wrappers build on; conformance C25–C27; suite now 27/0). Prior: §13 index fold (`bin/index` + C21–C24); §12 council gate (`bin/council` + `council_verdict` event + C15–C20); Mobile companion MVP-0 in DiffViewer — loopback `:3334` approval listener + PWA, Tailscale-only, verified end-to-end across the bus, operator pairing guide in DiffViewer README, per issue #1).

## 1. What you are starting

Commandr is the L3 **bus** of a 5-layer toolchain (`docs/UNIFICATION-BLUEPRINT.md`):
a filesystem contract (`.agents/` per repo) for task queueing, progress events, and
human approval — plus the `bin/` tools that operate it. Harnesses (Claude Code,
OpenCode) plug in through adapters; DiffViewer renders diffs as the L5 UI.

| Piece | Where | Role |
|---|---|---|
| Bus contract | `protocol/SPEC.md` (v0.1) | authoritative data shapes + invariants |
| Bus tools | `bin/claim`, `bin/complete`, `bin/progress`, `bin/pre-commit-gate` | operate the bus from any repo |
| Services | `bin/council` (advisory quality gate, §12), `bin/index` (derived cross-repo cache, §13) | run over the bus, never gate it |
| Conformance | `protocol/conformance.sh` | definition of done (C01–C27) |
| Harness adapters | `adapters/claude-code/`, `adapters/opencode/` (+ shared `adapters/lib/`) | project turn checkpoints / session end onto the bus |
| Diff UI | `~/repos/DiffViewer` | watches `.diffviewer/turns/` sidecars, renders per-turn diff cards |

## 2. Prerequisites

- bash, git, jq, curl
- python3 (conformance `--adapter` mode hard-requires it)
- Node 20+ (DiffViewer server, OpenCode plugins)
- OpenCode ≥ v1.15.x if using the OC adapters (verified against v1.15.10 SDK)

## 3. One-time setup

### 3.1 Bus tools on PATH

```sh
export PATH="$HOME/repos/Commandr/bin:$PATH"   # add to ~/.zshrc
```

Alternative (no PATH change): every consumer accepts env overrides —
`CLAIM_CMD`, `COMPLETE_CMD`, `GATE_CMD`, `PROGRESS_CMD`, `COUNCIL_CMD`, `INDEX_CMD`.

### 3.2 Bootstrap a repo onto the bus

In each repo that should carry tasks (LAYOUT-2 — directories must exist first):

```sh
mkdir -p .agents/{inbox,claimed,done,approvals,council}
touch .agents/events.jsonl
```

`.agents/` always lives in the **main checkout**; all tools resolve it correctly
from worktrees via `git rev-parse --git-common-dir` (LAYOUT-1).

### 3.3 Claude Code adapters (hooks)

Wire into `~/.claude/settings.json` hooks:

- `Stop` → `~/repos/Commandr/adapters/claude-code/stop-hook.sh` (per-turn bus checkpoint)
- `SessionEnd` → `~/repos/Commandr/adapters/claude-code/session-end-hook.sh` (`session_end` event)

DiffViewer's hooks are separate and installed by its own installer (idempotent
sibling-entry merge, safe alongside the above):

```sh
cd ~/repos/DiffViewer && npm install && bash scripts/install.sh
# patches PostToolUse + Stop hooks; adds .diffviewer/ to global git excludes
```

### 3.4 OpenCode adapters (plugins)

```sh
ln -s ~/repos/Commandr/adapters/opencode/checkpoint.js  ~/.config/opencode/plugins/commandr-checkpoint.js
ln -s ~/repos/DiffViewer/adapters/opencode/diffviewer.js ~/.config/opencode/plugins/diffviewer.js
```

### 3.5 Commit gate per repo

In every repo where agents commit (APPROVAL-2 — works with git + files only):

```sh
printf '#!/bin/sh\nexec pre-commit-gate\n' > .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit
```

## 4. The daily loop

### 4.1 Queue a task

Drop a mission packet into the inbox — `.agents/inbox/TASK-001.md`:

```markdown
---
id: TASK-001
type: implementation
blocking: []
blocked-by: []
scope: src/payments/
---
## Context
Full context — no prior conversation assumed.
## Acceptance criteria
- [ ] ...
## Files to touch
## Do not touch
```

### 4.2 Claim and work

```sh
claim          # atomic mv inbox/ → claimed/hostname_pid_TASK-001.md ('_' separator, SPEC §11.4)
               # stdout: claimed:{path} + packet body; "inbox:empty" when nothing to do
```

Work the task on a branch named `agent/<task-id>` (or export `AGENTS_TASK_ID`) —
that is how the commit gate resolves task identity (APPROVAL-3).

Progress happens two ways:

- **Automatic:** adapter checkpoints fire per turn-end (CC Stop hook / OC idle) and
  append deduped `task_progress` events.
- **Manual milestones:** `progress <task-id> "<one-line note>"` — milestones only,
  never tool calls or harness internals (EVENT-4).

### 4.3 Approve and commit

The pre-commit hook blocks agent commits until a human drops the token:

```sh
touch .agents/approvals/TASK-001.approved    # or use the approval-workflow skill
```

Commits without task identity are allowed as human commits (APPROVAL-4, with a
warning if agents hold claims).

### 4.4 Complete

```sh
complete .agents/claimed/<host>_<pid>_TASK-001.md pass   # or fail
# fail = finished but acceptance criteria unmet; crashes are task_failed,
# emitted by the supervisor, never by complete (COMPLETE-2)
```

### 4.5 Observe

- Kanban board: `/kanban-status` skill (reads inbox/claimed/done + events).
- Event log: `tail -f .agents/events.jsonl` — append-only, one JSON object per line.
- Cross-repo view: `index refresh ~/repos/A ~/repos/B` folds many per-repo buses
  into one derived cache at `~/.agents/index.json` (state, owner, council verdict,
  last progress note per task). With no args it reads the registry `~/.agents/repos`
  (one repo path per line). The cache is **derived, never source of truth** (SPEC §13) —
  re-run to rebuild; reconcile against the repo bus when correctness matters.

## 5. DiffViewer (L5 UI)

```sh
cd ~/repos/DiffViewer
node server.js ~/repos/<repo-being-edited> [...more roots]
# or: DIFFVIEWER_WATCH_ROOTS=/path/a:/path/b node server.js
open http://localhost:3333
```

Ingestion is sidecar-based since v0.6 (`docs/V0.6-SIDECAR-SPEC.md` in DiffViewer):
harness adapters write `<repo>/.diffviewer/turns/<session>/turn-N.json` per turn;
the server watches those directories, renders grouped diff cards over SSE, and
consumes (unlinks) each snapshot after broadcast. Works identically for Claude Code
and OpenCode sessions. Steer is clipboard-based (`POST /steer` → pbcopy).

## 6. Verifying the install

```sh
cd ~/repos/Commandr
# Bus tools (explicit env form works without PATH setup):
CLAIM_CMD=$PWD/bin/claim COMPLETE_CMD=$PWD/bin/complete \
GATE_CMD=$PWD/bin/pre-commit-gate PROGRESS_CMD=$PWD/bin/progress \
COUNCIL_CMD=$PWD/bin/council INDEX_CMD=$PWD/bin/index \
protocol/conformance.sh

# Adapter conformance (drives C13 through the driver verbs).
# Driver paths MUST be absolute — conformance.sh cd's into a throwaway
# fixture repo, so relative paths fail with "No such file or directory":
CLAIM_CMD=$PWD/bin/claim COMPLETE_CMD=$PWD/bin/complete \
GATE_CMD=$PWD/bin/pre-commit-gate PROGRESS_CMD=$PWD/bin/progress \
COUNCIL_CMD=$PWD/bin/council INDEX_CMD=$PWD/bin/index \
protocol/conformance.sh --adapter "$PWD/adapters/claude-code/conformance-driver.sh"

CLAIM_CMD=$PWD/bin/claim COMPLETE_CMD=$PWD/bin/complete \
GATE_CMD=$PWD/bin/pre-commit-gate PROGRESS_CMD=$PWD/bin/progress \
COUNCIL_CMD=$PWD/bin/council INDEX_CMD=$PWD/bin/index \
protocol/conformance.sh --adapter "$PWD/adapters/opencode/conformance-driver.sh"
```

Expected: 27 pass, 0 fail. DiffViewer: `npx vitest run` (52 tests) plus
`bash test/hooks.sh` and `bash test/install.sh`.

## 7. Current feature state — UPDATE THIS TABLE EVERY SESSION

| Capability | Status | Since |
|---|---|---|
| Bus tools (`claim`/`complete`/`progress`/`pre-commit-gate`) | live, SPEC v0.1 | Phase 0 |
| Conformance C01–C27 incl. `--adapter` drive | live; fails closed on any skip (0 stubs remain) | Phase 1 / 3 |
| CC adapter (turn checkpoint + `session_end`) | live | Phase 1 |
| OC adapter (turn checkpoint via idle) | live | Phase 1 |
| OC `session_end` mapping | **deferred** — no verified per-session shutdown event | — |
| DiffViewer sidecar ingestion (both harnesses) | live at test level; live e2e not yet exercised | Phase 2 |
| Mobile companion MVP-0 (touch diff approve/reject) | desktop chain verified e2e (DiffViewer `c1d16b9`+`c5fbd08`): sidecar→ingest→WS push→approve→bus token→`pre-commit-gate` flips block→pass; reject + stale-digest (409) write nothing. Physical-phone+Tailscale leg operator-driven (README). Loopback `:3334`, Tailscale-only, single shared token | 2026-06-10 |
| Adapters installed user-side (§3.3/3.4) | **pending** | — |
| GitHub remote (Commandr → `vietbui1999ru/Commandr`, pushed) | live | 2026-06-09 |
| DiffViewer remote (main ahead of origin, unpushed) | **pending user decision** | — |
| Quality Gate CI (markdownlint loose, aislop, conformance ×3, Copilot review on PRs) | live — `.github/workflows/quality-gate.yml` | 2026-06-09 |
| `bin/council` (SPEC §12 advisory gate; `COUNCIL_EVALUATOR_CMD` seam; C15–C20) | live | Phase 3 |
| `bin/council --diff <range>\|-` (SPEC §12.7 bus-less diff mode; verdict JSON on stdout; C25–C27) | live | 2026-06-12 |
| `review-council` / `delegate-pi` rewired as thin wrappers over `bin/council` (decision 6) | not started — wrappers live in dotfiles, not this repo | — |
| `bin/index` (SPEC §13 derived cross-repo cache; `AGENTS_INDEX_REPOS`/`AGENTS_INDEX_FILE` seam; C21–C24) | live | 2026-06-12 |
| `~/.pi/agent/AGENTS.md`, CGC→KuzuDB | not started (Phase 3) | — |
| llm-wiki sheds `claude-setup/` → dotfiles | not started (Phase 4) | — |
| Tauri UI, multi-machine git-ref claims | not started (Phase 5) | — |
