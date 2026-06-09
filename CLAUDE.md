# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

Commandr is a multi-agent, multi-machine Claude Code command center. It provides:
- A Kanban board of agent tasks (inbox / claimed / done)
- Atomic task claiming via POSIX `mv` (single-machine) or git refs (multi-machine)
- An append-only event log
- A human approval gate before agent commits
- A council quality gate (3 parallel Haiku evaluators, majority vote)

**Status**: Phase 1 complete (2026-06-09) — gate met: both adapters pass the same conformance run via `--adapter` drivers (`adapters/*/conformance-driver.sh`; verbs: `capabilities`, `turn-end <dir>`, `session-end <dir> <sid>`). Conformance fully live: 14 pass, 0 fail. Bus tools: `bin/claim`, `bin/complete`, `bin/pre-commit-gate`, `bin/progress` per SPEC v0.1. Adapters share `adapters/lib/` (checkpoint + session-end cores): Claude Code (`adapters/claude-code/stop-hook.sh` per-turn checkpoint, `session-end-hook.sh` SessionEnd → `session_end`) and OpenCode (`adapters/opencode/checkpoint.js`, listens `session.status` idle + deprecated `session.idle` twin behind an in-flight guard; verified against installed v1.15.10 SDK types). OpenCode `session_end` mapping deferred — no verified per-session shutdown event. Run: `CLAIM_CMD=$PWD/bin/claim COMPLETE_CMD=$PWD/bin/complete GATE_CMD=$PWD/bin/pre-commit-gate PROGRESS_CMD=$PWD/bin/progress protocol/conformance.sh`. Next: adapter-mode C13 drive (`--adapter` harness in conformance.sh). Run: `CLAIM_CMD=$PWD/bin/claim COMPLETE_CMD=$PWD/bin/complete GATE_CMD=$PWD/bin/pre-commit-gate protocol/conformance.sh`.

## Read These First (they supersede anything below that conflicts)

1. `docs/UNIFICATION-BLUEPRINT.md` — Commandr's adopted identity: the L3 **bus** (thin waist) of a 5-layer toolchain. 11 locked decisions — do NOT re-grill them.
2. `protocol/SPEC.md` — the `.agents/` bus contract v0.1. **Wins over PRD v0.5, ARCHITECTURE.md, and this file** for cross-harness behavior (declared divergences in SPEC §11).
3. `protocol/conformance.sh` — definition of done for bus tools and every harness adapter. Runs today: C01 passes, C02–C14 are TODO stubs with exact assertions spelled out.

Key supersessions to not trip over: claimed-filename separator is `_` not `-` (SPEC §11.4 — dash parsing is ambiguous); claim/complete/pre-commit-gate live in Commandr `bin/` on PATH, not per-project `scripts/` (SPEC §11.2); council verdict is one `.agents/council/<task-id>.json` per task (SPEC §9).

## Architecture

### Component Map

```
Developer / Orchestrator
  scripts/spawn-agents.sh   →  pre-claims tasks from .agents/inbox/ → spawns claude --bg per task
  /kanban-status skill      →  reads .agents/{inbox,claimed,done,registry.json} → renders terminal board

Claude Code Agent (per session)
  claim-task skill          →  runs scripts/claim.sh → reads task file (pull-model alternative)
  Stop hook                 →  appends session_end to .agents/events.jsonl; emits summary
  commit hook               →  checks .agents/approvals/<task>.approved before proceeding

Approval workflow skill     →  renders diff + context → blocks on stdin [y/n/diff] → writes approval token
Council quality gate        →  spawns 3 Haiku evaluators in parallel → majority vote → signal file

.agents/  (always in main checkout, never in a worktree)
  inbox/                    ←  unclaimed task .md files
  claimed/                  ←  atomically renamed here; filename: hostname_pid_task.md (SPEC CLAIM-2)
  done/                     ←  renamed here on completion
  events.jsonl              ←  append-only event log
  registry.json             ←  agent fleet state (v1+)
  approvals/                ←  <task>.approved tokens
  council/                  ←  <task>-<dimension>.json vote files
```

### File Placement

> Superseded by SPEC §11.2: claim/complete/pre-commit-gate are Commandr `bin/` tools on PATH, not per-project scripts. Layout below kept for historical context.

Skills are **global** (live in `~/dotfiles/.claude/skills/`). Task state and scripts are **per-project** (committed to each repo that uses Commandr).

```
~/dotfiles/.claude/skills/kanban-status/   →  ~/.claude/skills/kanban-status/
~/dotfiles/.claude/skills/approval/        →  ~/.claude/skills/approval/
~/dotfiles/.claude/hooks/stop.sh           →  event log append (patched in)
<project-repo>/.agents/                    →  per-project task state
<project-repo>/scripts/claim.sh            →  per-project claim script
<project-repo>/scripts/spawn-agents.sh     →  per-project orchestrator
```

### Key Data Shapes

**Task file** (`.agents/inbox/TASK-001.md`):
```markdown
---
id: TASK-001
type: implementation
blocking: []
blocked-by: []
scope: src/payments/
---
## Context
[full context — no prior conversation assumed]
## Acceptance criteria
- [ ] ...
## Files to touch
## Do not touch
```

**Event log entry** (`.agents/events.jsonl`, one JSON object per line):
```json
{"ts": "...", "event": "task_claimed", "task": "TASK-001", "agent": "session-abc", "machine": "hostname"}
{"ts": "...", "event": "session_end", "session": "session-abc", "files_changed": 3, "exit_status": 0}
```

**Council signal file** (`.agents/council/<task>-<dimension>.json`):
```json
{"evaluator": "acceptance-criteria", "vote": "PASS", "reason": "..."}
```

## Critical Implementation Decisions

| Decision | Choice | Must not change |
|---|---|---|
| Single-machine claim atomicity | POSIX `mv inbox/T → claimed/T` | No lock files. Race: first `mv` wins. |
| Multi-machine claim atomicity (v2) | `git push origin HEAD:refs/tasks/<id>` | Git ref creation is atomic by protocol. |
| Find main repo from worktree | `dirname "$(git rev-parse --git-common-dir)"` | Required in claim.sh — worktrees must resolve to main checkout. |
| Event log append | `echo '{...}' >> events.jsonl` | POSIX append is atomic per-line. Never rewrite the file. |
| Approval token | File at `.agents/approvals/<task>.approved` | Commit hook reads existence of this file. |
| v1 infra | Zero external services | Files + git + skills only. |

## Staged Roadmap

### v0.5 — First deliverable (start here)
- `.agents/` directory structure (`inbox/`, `claimed/`, `done/`, `approvals/`)
- `scripts/claim.sh` + `scripts/complete.sh`
- `.agents/events.jsonl` + Stop hook extension
- `/kanban-status` skill
- Approval workflow skill

### v1 — Registry + council
- `.agents/registry.json` written by orchestrator on spawn and Stop hook on completion
- Council quality gate: 3 parallel Haiku evaluators + majority vote signal file
- `blocked-by` dependency enforcement in `spawn-agents.sh`

### v2 — Multi-machine coordination
- Git ref claim replaces POSIX `mv` for cross-machine atomicity
- Timeout recovery for stale claimed refs

### v3 — Hosted observability
- GitHub Projects sync for Kanban UI
- Langfuse traces per agent session

## Design Docs

- `docs/UNIFICATION-BLUEPRINT.md` — adopted identity, 11 locked decisions, migration phases 0–5 (read first)
- `protocol/SPEC.md` + `protocol/conformance.sh` — the bus contract and its gate (authoritative)
- `docs/prds/PRD-v0.5-local-agent-control-tower.md` — v0.5 implementation detail (separator + script paths superseded by SPEC §11)
- `docs/PRD.md` — long-horizon problem statement, user stories, testing decisions
- `docs/ARCHITECTURE.md` — component map, data shapes, claim protocol pseudocode, spawn pattern, council pattern (placement + council shape superseded by SPEC)
