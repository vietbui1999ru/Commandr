# GPT-5.5 Review: PRD-v0.5-local-agent-control-tower.md

Review target: `docs/prds/PRD-v0.5-local-agent-control-tower.md`

Reviewer: GPT-5.5

Date: 2026-05-29

## Verdict

PRD is strong enough to drive `to-issues`, but it needs a tightening pass before implementation. Main risk: several core interfaces are described conceptually but not specified enough for independent agents to implement consistently.

## Findings

### High: Approval gate is not enforceable as written

Lines: 5, 19, 27-31, 62-66, 108-110, 173

The PRD promises a human airlock before agent commits, but the implementation decisions only define approval-token creation. It does not explicitly include the commit hook or guard that checks the token before commit. Without that guard, approval is advisory, not enforced.

Recommended fix: add a `Commit Hook Guard` implementation decision, or weaken the product promise from "before agent commits" to "approval workflow prepares a token for a separate commit hook." Better: keep enforcement in v0.5 and specify token check behavior.

### Medium: Script contracts need exact stdout and exit-code behavior

Lines: 86-98, 130-137

`claim` and `complete` behavior is clear at concept level, but independent implementers need exact command contracts. The PRD mentions `inbox:empty` and claimed paths, but not exit codes, stderr behavior, malformed input behavior, missing directory behavior, or whether `complete` appends event log entries itself.

Recommended fix: add a `Command Contracts` subsection for `claim.sh` and `complete.sh` with success output, empty output, failure output, and exit code rules.

### Medium: Event schema is underspecified

Lines: 100-102, 134-141, 171-173

The PRD requires JSONL, but does not define required fields per event type. Future tooling and tests will depend on stable event names and fields. Current language allows multiple incompatible implementations.

Recommended fix: define minimal v0.5 event shapes for `task_claimed`, `task_complete`, `task_failed`, and `session_end`. Include required fields like `ts`, `event`, `task`, `agent`, `machine`, `path`, `result`, and optional metadata policy.

### Medium: Git tracking policy for `.agents/` runtime files is ambiguous

Lines: 11, 36-37, 76-78, 171-173

The PRD says `.agents/` is committed project state, but v0.5 also creates runtime files: claimed tasks, done tasks, approvals, and event logs. It is unclear whether all runtime files are committed, only directory placeholders are committed, or some paths are gitignored.

Recommended fix: add a `Git Tracking Policy` subsection. Decide which paths are committed by default. Example: commit task files and directory placeholders; ignore approval tokens if ephemeral; decide whether `events.jsonl` is durable repo history or local runtime log.

### Medium: Stop hook integration lacks installation boundary

Lines: 20, 112-114, 140-141

The PRD describes Stop hook event append, but not where hook code lives, how it is patched into existing hooks, or how projects opt in. Since hooks are global while task state is per-project, this boundary matters.

Recommended fix: add an integration contract: global Stop hook detects nearest Commandr-enabled repo, no-ops if `.agents/` missing, appends session-end only when enabled.

### Low: Product vocabulary is useful but not mapped to implementation names

Lines: 23-32

The control-tower metaphor improves coherence, but implementation still uses `.agents/inbox`, `.agents/claimed`, and `.agents/done`. Without a mapping rule, later docs may drift between metaphor and filesystem names.

Recommended fix: add one sentence: product docs may use metaphor terms, while scripts and schemas must use filesystem names.

### Low: `failed` lifecycle is mentioned but not represented in storage

Lines: 100-102, 154-161

The event log includes failure events, but there is no `failed/` lane or failure completion path. That may be intentional, but implementers need to know whether failed tasks stay in claimed, move back to inbox, or only emit an event.

Recommended fix: specify v0.5 failure policy. Minimal option: failed tasks remain in `claimed/` and only `task_failed` is appended.

### Low: Acceptance criteria are implied, not explicit

Lines: 128-152

Testing decisions are useful, but the PRD lacks a concise acceptance-criteria checklist. `to-issues` will work better if it can map acceptance criteria directly to vertical slices.

Recommended fix: add `Acceptance Criteria` before `Testing Decisions` with checkboxes for setup, claim, complete, event log, Kanban, approval, Stop hook, and end-to-end flow.

## Suggested Patch Themes

1. Add exact v0.5 command contracts.
2. Add minimal event schema table.
3. Add commit hook guard or weaken approval promise.
4. Add git tracking policy for `.agents/` runtime files.
5. Add Stop hook opt-in/no-op behavior.
6. Add explicit acceptance criteria.

## To-Issues Readiness

Current PRD can be split into issues, but issue quality will improve after the tightening pass above.

Recommended issue slices after fixes:

1. Bootstrap `.agents/` store and git tracking policy.
2. Implement `claim.sh` with exact command contract.
3. Implement `complete.sh` and failure policy.
4. Implement event log writer and schema tests.
5. Implement `/kanban-status` renderer.
6. Implement approval workflow and commit hook guard.
7. Implement Stop hook adapter.
8. Add end-to-end local lifecycle test.

## Summary

PRD has correct shape and a strong product frame. Main gap is interface precision. Tighten command contracts, event schema, approval enforcement, and `.agents/` tracking policy before generating implementation issues.
