# Architecture

## Component Map

```
Developer / Orchestrator
  spawn-agents.sh       →  pre-claims tasks from .agents/inbox/ → spawns claude --bg per task
  /kanban-status skill  →  reads .agents/{inbox,claimed,done,registry.json} → renders terminal board

Claude Code Agent (per session)
  claim-task skill      →  runs claim.sh → reads task file (pull model alternative to pre-claim)
  Stop hook             →  appends session_end to .agents/events.jsonl; emits summary
  commit hook           →  checks .agents/approvals/<task>.approved before proceeding

Approval workflow skill →  renders diff + context → blocks on stdin [y/n/diff] → writes approval token
Council quality gate    →  spawns 3 Haiku evaluators in parallel → majority vote → signal file

.agents/  (main checkout, not in any worktree)
  inbox/                ←  unclaimed task .md files
  claimed/              ←  atomically renamed here; hostname-pid-task.md
  done/                 ←  renamed here on completion
  events.jsonl          ←  append-only event log
  registry.json         ←  agent fleet state (v1+)
  approvals/            ←  <task>.approved tokens written by approval workflow
```

## Data Shapes

### Task File (`.agents/inbox/TASK-001.md`)
```markdown
---
id: TASK-001
type: implementation
blocking: []
blocked-by: []
scope: src/payments/
---

# Implement Stripe Webhook Handler

## Context
[full context for a fresh agent — no prior conversation assumed]

## Acceptance criteria
- [ ] /api/webhooks/stripe handles checkout.session.completed
- [ ] Tests pass: npm test -- --testPathPattern=stripe
- [ ] No new TypeScript errors

## Files to touch
src/payments/webhook.ts (create)
tests/payments/webhook.test.ts (create)

## Do not touch
src/auth/ — another agent owns this
```

### Event Log Entry (`.agents/events.jsonl`)
```json
{"ts": "2026-05-19T10:00:00Z", "event": "task_claimed", "task": "TASK-001", "agent": "session-abc", "machine": "hostname"}
{"ts": "2026-05-19T10:45:00Z", "event": "task_complete", "task": "TASK-001", "result": "pass"}
{"ts": "2026-05-19T10:45:01Z", "event": "session_end", "session": "session-abc", "task": "TASK-001", "files_changed": 3, "tests_summary": "47 passed, 0 failed", "exit_status": 0}
```

### Agent Registry (`.agents/registry.json`)
```json
{
  "agents": [
    {
      "id": "session-abc",
      "task": "TASK-001",
      "status": "running",
      "started_at": "2026-05-19T10:00:00Z",
      "machine": "hostname"
    }
  ]
}
```

### Council Signal File (`.agents/council/<task>.result`)
```json
{
  "task": "TASK-001",
  "verdict": "PASS",
  "votes": [
    {"evaluator": "acceptance-criteria", "vote": "PASS", "reason": "All criteria met"},
    {"evaluator": "code-quality", "vote": "PASS", "reason": "No issues found"},
    {"evaluator": "style", "vote": "FAIL", "reason": "Missing type annotation on line 42"}
  ],
  "majority": "PASS"
}
```

## Key Implementation Decisions

| Decision | Choice | Reason |
|---|---|---|
| Task state storage | Committed `.agents/` files | Auditable, survives restarts, no DB |
| Single-machine claim atomicity | POSIX `mv inbox/T → claimed/T` | Atomic on POSIX; no lock files needed |
| Multi-machine claim atomicity | `git push origin HEAD:refs/tasks/<id>` | Git ref creation is atomic by protocol; first pusher wins, others get conflict |
| Worktree → main repo path | `dirname $(git rev-parse --git-common-dir)` | Works from any worktree depth |
| Agent startup model | Orchestrator pre-claims (default) OR `claim-task` skill (pull) | Pre-claim is more reliable; pull model is lighter for simple setups |
| Approval token | File at `.agents/approvals/<task>.approved` | Commit hook reads it; no server required |
| Council evaluators | 3 × Haiku (parallel) | Cost: ~15K tokens vs ~1K single; use only for high-stakes tasks |
| Council composition | acceptance-criteria + code-quality + style | Three orthogonal lenses; majority vote prevents deadlock |
| Event log append | `echo '{...}' >> events.jsonl` | POSIX append is atomic per-line; no corruption risk |
| v1 infra | Zero external services | Files + git + skills covers all coordination needs |

## Claim Protocol (Single-Machine)

```bash
#!/usr/bin/env bash
# scripts/claim.sh

MAIN_REPO=$(dirname "$(git rev-parse --git-common-dir)")
INBOX="${MAIN_REPO}/.agents/inbox"
CLAIMED="${MAIN_REPO}/.agents/claimed"

for task_file in "${INBOX}"/*.md; do
  [ -f "$task_file" ] || { echo "inbox:empty"; exit 0; }
  task_name=$(basename "$task_file")
  claimed_name="$(hostname)-$$-${task_name}"
  if mv "${task_file}" "${CLAIMED}/${claimed_name}" 2>/dev/null; then
    echo "claimed:${CLAIMED}/${claimed_name}"
    cat "${CLAIMED}/${claimed_name}"
    exit 0
  fi
done
echo "inbox:empty"
```

## Claim Protocol (Multi-Machine, v2)

```bash
# Claim = race to create a git ref; first pusher wins
git push origin HEAD:refs/tasks/claimed/TASK-001
# → succeeds for first claimer
# → "cannot lock ref" for all others (atomic by git protocol)
```

Task inbox becomes a git ref namespace:
- Unclaimed: `refs/tasks/TASK-001`
- Claimed: `refs/tasks/claimed/TASK-001`
- Done: `refs/tasks/done/TASK-001`

Orchestrator lists unclaimed tasks: `git ls-remote origin 'refs/tasks/*'` minus `refs/tasks/claimed/*`.

## Kanban Board Rendering (`/kanban-status`)

```
INBOX          CLAIMED                    DONE
────────────   ──────────────────────     ────────────
TASK-003       TASK-001 @session-abc      TASK-002 ✓
TASK-004         machine: hostname        TASK-006 ✓
               TASK-005 @session-def
                 machine: hostname2
```

Skill reads:
- `inbox/` → unclaimed task filenames
- `claimed/` → parse `hostname-pid-task.md` filenames
- `registry.json` → cross-reference session IDs if present
- `done/` → completed task count

## Orchestrator Spawn Pattern

```bash
#!/usr/bin/env bash
# scripts/spawn-agents.sh
MAIN_REPO=$(git rev-parse --show-toplevel)
INBOX="${MAIN_REPO}/.agents/inbox"
CLAIMED="${MAIN_REPO}/.agents/claimed"

for task_file in "${INBOX}"/*.md; do
  [ -f "$task_file" ] || continue
  task_name=$(basename "$task_file")
  mv "${task_file}" "${CLAIMED}/${task_name}" 2>/dev/null || continue

  WORKTREE="${MAIN_REPO}/.trees/${task_name%.md}"
  git worktree add -b "agent/${task_name%.md}" "$WORKTREE" origin/main

  # Task baked into prompt — no inbox discovery in agent needed
  claude --bg "$(cat "${CLAIMED}/${task_name}")" &
done
wait
```

## Council Quality Gate Pattern

```bash
# Spawn 3 Haiku evaluators in parallel
claude --bg "Evaluate acceptance criteria for TASK-001. Read .agents/claimed/TASK-001.md and git diff HEAD. Output: PASS or FAIL with one-line reason. Write to .agents/council/TASK-001-acceptance.json" &
claude --bg "Evaluate code quality for TASK-001. Read changed files. Output: PASS or FAIL. Write to .agents/council/TASK-001-quality.json" &
claude --bg "Evaluate style and types for TASK-001. Output: PASS or FAIL. Write to .agents/council/TASK-001-style.json" &
wait

# Orchestrator reads votes and computes majority
```

## Staged Roadmap

### v0.5 — Single-machine, no external services
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
- Timeout recovery: orchestrator scans claimed refs older than threshold and force-pushes back to unclaimed namespace

### v3 — Hosted observability
- GitHub Projects sync: task files → GH Project items (via `gh` CLI)
- Langfuse traces: agent session token usage, latency, errors
- Cross-session replay from `events.jsonl`

## Placement

```
~/dotfiles/.claude/skills/kanban-status/   →  ~/.claude/skills/kanban-status/
~/dotfiles/.claude/skills/approval/        →  ~/.claude/skills/approval/
~/dotfiles/.claude/hooks/stop.sh           →  event log append (patched in)
<project-repo>/.agents/                    →  per-project task state
<project-repo>/scripts/claim.sh            →  per-project claim script
<project-repo>/scripts/spawn-agents.sh     →  per-project orchestrator
```

Skills are global (dotfiles). Task state and scripts are per-project (committed to each repo that uses Commandr).
