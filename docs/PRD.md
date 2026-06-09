# PRD: Commandr — Multi-Machine Agent Command Center

## Problem Statement

When running multiple Claude Code agents across sessions and machines, there is no unified view of work in progress. Task state lives in scattered shell sessions, agent status is invisible unless you attach to each session individually, and coordination across machines requires a shared filesystem — which breaks down the moment you add a second machine. There is no approval step before agents commit, no event history, and no Kanban-style view of what is queued, running, and done.

## Solution

A command center for multi-agent, multi-session, multi-machine Claude Code work. Commandr provides a Kanban board of agent tasks, atomic cross-machine task claiming via git refs, an append-only event log, a human approval gate before commits, and a council quality gate for high-stakes work. No external services in v1 — everything is files, git, and skills.

## User Stories

1. As an orchestrator, I want to see all tasks across inbox / claimed / done in a single Kanban view, so that I can triage and prioritize without attaching to individual sessions.
2. As an orchestrator, I want tasks stored in `.agents/` as committed files, so that task state survives restarts and is auditable in git history.
3. As an agent, I want to atomically claim the next available task, so that two agents never work on the same task even when running on different machines.
4. As an agent, I want my task file to contain all context I need to start work, so that I never depend on conversation history from another session.
5. As a developer, I want an append-only event log of all task state changes, so that I can reconstruct what happened in a session after the fact.
6. As a developer, I want a human approval gate before any agent auto-commit, so that I can review diffs and block bad changes before they land.
7. As a developer, I want the approval gate to show the diff, the agent identity, and the task, so that I have full context for the decision.
8. As a developer, I want the Stop hook to emit a structured session summary, so that I know what changed, what tests ran, and whether the task completed.
9. As a developer, I want agents on a second machine to claim tasks without a shared filesystem, so that I can distribute work across machines.
10. As a developer, I want a council quality gate for high-stakes tasks — spawning parallel evaluator agents that vote PASS/FAIL — so that a single agent's judgment is not the last word.
11. As a developer, I want the council to run acceptance criteria, code quality, and style checks in parallel, so that evaluation is faster than running a single sequential reviewer.
12. As a developer (v2), I want an agent registry showing which session is running which task on which machine, so that I can track the full agent fleet at a glance.
13. As a developer (v2), I want tasks to have `blocked-by` dependency fields, so that the orchestrator knows what is claimable without manual sequencing.
14. As a developer (v3), I want GitHub Projects as the Kanban UI, so that I get a hosted board with no infra cost.
15. As a developer (v3), I want Langfuse traces for all agent sessions, so that I can observe token usage, latency, and errors across the fleet.

## Implementation Decisions

### Modules

**Shared Task Queue** — `.agents/` directory in main repo root
- `inbox/` — unclaimed task files; agents pull from here
- `claimed/` — atomically renamed here on claim; filename includes `hostname-pid-taskname`
- `done/` — renamed here on completion
- Located in main checkout, not in any worktree; found via `git rev-parse --git-common-dir`
- POSIX `mv` is atomic within the same filesystem — two agents racing to claim: exactly one succeeds

**Task File** — self-contained markdown with YAML frontmatter
- Fields: `id`, `type`, `blocking`, `blocked-by`, `scope`
- Body: context, acceptance criteria, files to touch, do-not-touch list
- Agent receives only its task file — no shared conversation history needed

**Claim Script** — `scripts/claim.sh`
- Iterates `inbox/`; attempts `mv` to `claimed/`; returns `claimed:<path>` or `inbox:empty`
- Called by agent at session start via `claim-task` skill or pre-claimed by orchestrator spawn script

**Complete Script** — `scripts/complete.sh <claimed-path>`
- `mv` from `claimed/` to `done/`; triggered by agent on task completion

**Event Log** — `.agents/events.jsonl` (append-only)
- One JSON object per line: `{ ts, event, task, agent, machine, result }`
- Events: `task_claimed`, `task_complete`, `task_failed`, `session_end`
- Stop hook appends `session_end` with files changed and exit status

**`/kanban-status` Skill**
- Reads `inbox/`, `claimed/`, `done/`, `registry.json`
- Renders a three-column terminal board: INBOX / CLAIMED / DONE
- Shows agent identity and machine in CLAIMED column

**Approval Workflow Skill** — invoked before any agent auto-commit
- Renders: agent identity, task ID, files changed with line counts
- Blocks on stdin: `[y/n/diff]`
- On approval: writes token to `.agents/approvals/<task>.approved`
- Agent commit hook checks for token before proceeding

**Stop Hook Extension** — appended to `hooks/stop.sh`
- Emits structured summary: session ID, task ID, files changed, test results, status
- Appends `session_end` event to `.agents/events.jsonl`

### Architecture Decisions

- Task state: committed files — auditable, survives restarts, no external DB
- Claim atomicity (single-machine): POSIX `mv` — no lock files, no polling
- Claim atomicity (multi-machine): `git push origin HEAD:refs/tasks/<id>` — first pusher wins; others get ref conflict error; no shared filesystem needed
- Task inbox: main checkout only — worktrees find it via `git rev-parse --git-common-dir`
- Agent startup: orchestrator pre-claims before spawning (reliable) OR `claim-task` skill (agent pull model)
- Approval gate: file token (`.agents/approvals/<task>.approved`) — commit hook reads it; no server required
- Council gate: 3 Haiku evaluators in parallel (acceptance criteria / code quality / style); majority vote; result written to signal file
- v1: no external services — all files, scripts, skills, and hooks

## Testing Decisions

| Module | What to test |
|---|---|
| Claim script | Concurrent claim: only one succeeds; `inbox:empty` when no tasks; claimed filename includes hostname+pid |
| Complete script | File moves from claimed to done; idempotent on missing file |
| Event log | Append writes valid JSON; multiple agents don't corrupt (append is atomic per POSIX) |
| Kanban skill | Renders correct counts per lane; handles empty inbox; handles agent registry missing |
| Approval workflow | Renders diff summary; `y` writes approval token; `n` aborts; `diff` shows full diff |
| Stop hook | Appends session_end event; includes file count and exit status |
| Multi-machine claim | Git ref creation race: exactly one succeeds per task |

## Staged Roadmap

### v0.5 — Single-machine, no external services
- `.agents/inbox/`, `claimed/`, `done/` directory structure
- `claim.sh` + `complete.sh` scripts
- `.agents/events.jsonl` event log
- Stop hook extension (session_end event + summary)
- `/kanban-status` skill
- Approval workflow skill

### v1 — Registry + council quality gate
- `.agents/registry.json` agent registry (orchestrator writes on spawn, Stop hook writes on completion)
- Council quality gate: 3 parallel Haiku evaluators, majority vote signal file
- Task `blocked-by` dependency enforcement in orchestrator spawn logic
- Schema validation for task files

### v2 — Multi-machine coordination
- Git ref claim: `git push origin HEAD:refs/tasks/<id>` replaces POSIX `mv` for cross-machine atomicity
- Task inbox becomes git ref namespace: orchestrator pulls `refs/tasks/*`, claims unclaimed
- Timeout recovery: refs older than threshold returned to inbox

### v3 — Hosted observability + Kanban UI
- GitHub Projects as Kanban UI (task files sync to GH Project items)
- Langfuse for agent session traces (token usage, latency, errors per session)
- Cross-session replay from `.agents/events.jsonl`

## Out of Scope

- Web UI or dashboard (v1 is terminal-only)
- Auth or network exposure (local filesystem + git only)
- Windows support (POSIX `mv` atomicity assumed)
- LangGraph or external workflow orchestration (v3+ candidate)
- Real-time push notifications to mobile/Slack (v3+ candidate)
