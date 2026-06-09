# `.agents/` Bus Protocol — SPEC v0.1 (draft)

The thin-waist contract for cross-harness agent coordination. Any driver harness (Claude Code, OpenCode, Codex, Pi), worker, UI, or human tooling interoperates with the bus exclusively through the on-disk formats defined here.

**Scope (v0.1):** task queue + neutral progress + approvals + events. Single machine, single repo.
**Out of scope (v0.1):** multi-machine claiming (git-ref race, reserved), agent registry, council verdict aggregation (namespace reserved), dependency scheduling, timeout recovery, Windows.

Normative keywords MUST / MUST NOT / SHOULD / MAY follow RFC 2119. Every MUST has a conformance check ID (§10).

## 1. Terms

- **Bus** — the `.agents/` directory in a repo's main checkout, plus the formats in this spec.
- **Adapter** — harness-specific glue that makes one harness speak the bus (claim at session start, project progress, request approval, emit events).
- **Mission packet** — a self-contained task file. The packet is the agent contract; chat history is not.
- **Task id** — the `id` field in packet frontmatter (e.g. `TASK-001`). All cross-references (events, approvals) use the task id, never the filename.
- **Claiming party** — whichever process performs the claim: an adapter (pull model) or an orchestrator (pre-claim model).

## 2. Directory Layout

```
<main-checkout>/.agents/
  inbox/        # unclaimed mission packets (*.md)
  claimed/      # claimed packets, renamed with owner identity
  done/         # completed packets
  approvals/    # <task-id>.approved tokens
  events.jsonl  # append-only event log
  council/      # RESERVED (v0.2) — verdict files
```

- **LAYOUT-1**: The bus MUST live in the main checkout, never inside a worktree. From any worktree it is resolved as `$(dirname "$(git rev-parse --git-common-dir)")/.agents`.
- **LAYOUT-2**: `inbox/`, `claimed/`, `done/`, `approvals/` MUST exist (`.gitkeep` permitted) before any bus operation.
- **LAYOUT-3**: Git tracking policy: `inbox/*.md`, `done/*.md`, `.gitkeep` committed; `claimed/`, `approvals/`, `events.jsonl`, `council/` gitignored.

## 3. Mission Packet

Markdown with YAML frontmatter:

| Field | Type | Status |
|---|---|---|
| `id` | string | Required. Unique. Approval token basename. |
| `type` | enum: `implementation` \| `research` \| `review` | Required |
| `scope` | string (glob) | Required |
| `blocking` | string[] | Reserved — default `[]` |
| `blocked-by` | string[] | Reserved — default `[]` |

- **PACKET-1**: A packet missing `id`, `type`, or `scope` is invalid; tooling MUST NOT claim it and SHOULD report it.
- **PACKET-2**: Unknown frontmatter fields MUST be ignored, not rejected.
- **PACKET-3**: The body MUST contain: context sufficient for a fresh session, acceptance criteria, files to touch, files not to touch.

## 4. Claim Protocol

Claim = atomic POSIX `mv` from `inbox/` to `claimed/`. Exactly one concurrent claimer succeeds; losers get `ENOENT` and try the next packet.

- **CLAIM-1**: Claiming MUST be a single `rename(2)`-class operation within the same filesystem. No lock files, no daemons.
- **CLAIM-2**: Claimed filename MUST be `{hostname}_{pid}_{original-filename}` (e.g. `mbp_12345_TASK-001.md`). Separator is `_` because it cannot appear in an RFC-1123 hostname and `pid` is all digits; writers MUST replace any `_` in the local hostname with `-` before composing. Readers parse owner identity by splitting on `_`, max 3 parts from the left; the remainder is the original filename (which may itself contain `_` or `-`).
- **CLAIM-3**: A claim command MUST print `claimed:{absolute-path}\n` followed by the packet contents on success; `inbox:empty\n` when no claimable packet exists. Both exit 0 — empty inbox is not an error.
- **CLAIM-4**: After a successful claim and before work begins, the claiming party MUST append a `task_claimed` event (§6). Which component writes it (claim tool or adapter) is an implementation detail; the invariant is the event exists.

## 5. Completion

Completion records lifecycle landing. It is not a commit and not an approval.

- **COMPLETE-1**: Completion MUST move the claimed file to `done/`, preserving the claimed filename, printing `done:{absolute-path}\n`, exit 0. A missing claimed path MUST exit non-zero with no stdout.
- **COMPLETE-2**: The completing party MUST append a `task_complete` (or `task_failed`) event. The two are not interchangeable: `task_failed` signals abnormal termination (crash, timeout, unrecoverable error); `task_complete` with `result: "fail"` signals normal completion whose acceptance criteria were not met.

## 6. Event Log

`events.jsonl`: one JSON object per line, appended with O_APPEND semantics. Timestamps ISO 8601 UTC.

- **EVENT-1**: The log is append-only. Implementations MUST NOT rewrite, reorder, or compact it.
- **EVENT-2**: Every non-empty line MUST parse as a standalone JSON object with at least `ts` and `event`. Writers MUST NOT emit blank lines; readers MUST skip them.
- **EVENT-3**: Writers MUST NOT emit event types not defined here. Readers MUST tolerate unknown event types (forward compatibility).

Defined events:

```json
{"ts": "<ISO8601>", "event": "task_claimed",  "task": "<task-id>", "agent": "<agent-id>", "machine": "<hostname>"}
{"ts": "<ISO8601>", "event": "task_progress", "task": "<task-id>", "note": "<one-line neutral status>", "agent?": "<agent-id>"}
{"ts": "<ISO8601>", "event": "task_complete", "task": "<task-id>", "result": "pass" | "fail"}
{"ts": "<ISO8601>", "event": "task_failed",   "task": "<task-id>", "agent": "<agent-id>", "reason": "<description>"}
{"ts": "<ISO8601>", "event": "session_end",   "session": "<session-id>", "task?": "<task-id>", "files_changed?": 0, "tests_summary?": "<string>", "exit_status?": 0}
```

- **EVENT-4** (*neutral progress*): `task_progress` notes MUST be harness-neutral — human-readable status a viewer can render without knowing the harness. Loop-internal state (tool calls, token counts, harness session structure) MUST NOT be written to the bus; adapters project milestones only.
- **EVENT-5**: Fields marked `?` are omitted when unavailable, never written as `null`.
- **EVENT-6**: The bus MUST reside on a local filesystem (not NFS or other network mounts) — O_APPEND per-write atomicity is not guaranteed remotely. Writers MUST emit each event as a single `write(2)` of one complete line.

> `task_progress` is new in this spec — it extends the PRD v0.5 event set (decision 4: bus scope = queue + neutral progress).

## 7. Approval Gate

Human airlock before agent commits. Token = file existence.

- **APPROVAL-1**: Approval writes `.agents/approvals/{task-id}.approved` where `task-id` is the frontmatter `id`, never a filename-derived value. Denial MUST NOT create the token.
- **APPROVAL-2** (*harness independence*): The gate is a git `pre-commit` hook (installed per worktree) that shells to `pre-commit-gate` on PATH. It MUST NOT depend on any harness being installed or running.
- **APPROVAL-3**: Task identity resolution order: (1) `$AGENTS_TASK_ID`, if set to a non-empty, non-whitespace value (empty or whitespace-only is NOT a resolution); (2) current branch name exactly equal to `agent/<task-id>` (full-string, case-sensitive — `agent/TASK-001-hotfix` does NOT resolve as `TASK-001`). If both resolve and disagree, the hook SHOULD warn; strict implementations MAY block on mismatch. If a task resolves and its token is absent, the hook MUST exit non-zero and block the commit.
- **APPROVAL-4**: If no task identity resolves, the hook MUST allow the commit and SHOULD print a warning — prominently when `claimed/` is non-empty (humans share the repo). **OPEN QUESTION:** a strict fail-closed mode (block all commits without token when `claimed/` is non-empty) is desirable for unattended fleets — deferred to v0.2.

## 8. Adapter Obligations

A conformant adapter, per session: claim (or receive pre-claimed packet) → emit `task_claimed` → project `task_progress` at milestones → request approval before committing → complete → emit `task_complete`/`task_failed` → emit `session_end` at shutdown when the harness supports exit hooks.

- **ADAPTER-1**: Adapters MUST treat the packet as the complete work specification.
- **ADAPTER-2**: Adapters MUST NOT store harness-private state under `.agents/` (decision 4 fence).

## 9. Reserved Namespaces (do not repurpose)

| Path / ref | Reserved for |
|---|---|
| `.agents/council/` | council verdicts (v0.2) — one file per task, `<task-id>.json`: `{task, verdict, votes[]}`. Supersedes ARCHITECTURE.md's two divergent sketches (per-task `.result` vs per-evaluator files). |
| `.agents/registry.json` | agent fleet registry (v1) |
| `~/.agents/index.json` | global derived cache across repos — written by `index` tool (contract deferred to v0.2), NEVER source of truth |
| `refs/tasks/*` | multi-machine claim race (v2) |

## 10. Conformance

`protocol/conformance.sh` is the definition of done for the bus and for every adapter (blueprint decision 10: both day-one adapters validate against this one test before anything builds on the bus).

| Check | Covers |
|---|---|
| C01 layout | LAYOUT-1..3 (all four gitignore entries; worktree resolution) |
| C02 packet validation | PACKET-1..3 |
| C03 claim happy path | CLAIM-2, CLAIM-3 (prefix line, packet contents follow, exit 0) |
| C04 empty inbox | CLAIM-3 |
| C05 claim atomicity race | CLAIM-1 |
| C06 claim event invariant | CLAIM-4 |
| C07 complete | COMPLETE-1 (incl. no-stdout-on-failure), COMPLETE-2 |
| C08 event log validity | EVENT-2, EVENT-3 (writer side: defined types only), EVENT-5 |
| C09 progress neutrality | EVENT-4 (heuristic) |
| C10 approval token | APPROVAL-1 |
| C11 gate blocks commit | APPROVAL-2..3 |
| C12 gate allows humans | APPROVAL-4 |
| C13 end-to-end lifecycle | full inbox→claimed→done with parseable log; ADAPTER-2 (no harness-private files under `.agents/`) |
| C14 log integrity | EVENT-1 (append-only), EVENT-3 (reader side: tolerate unknown types) |

Not mechanically testable — verified by design review, not by this script: ADAPTER-1 (constrains adapter reasoning, not filesystem output), EVENT-6 (filesystem locality), EVENT-4 beyond C09's heuristic.

Modes: `conformance.sh` (test bus tools alone) · `conformance.sh --adapter <cmd>` (drive a harness adapter through C03–C14; flag is parsed today, the driving harness in C13 is still TODO).

## 11. Divergences from PRD v0.5

1. Adds `task_progress` (decision 4). PRD's "writers must not emit undefined types" now refers to THIS spec's event set.
2. Claim/complete live in Commandr `bin/` on PATH, not per-project `scripts/` (supersedes ARCHITECTURE.md Placement section and PRD v0.5 §Command Contracts paths).
3. Event-emission responsibility restated as an invariant (CLAIM-4/COMPLETE-2) rather than "caller appends" — same behavior, testable cross-harness.
4. Claimed-filename separator is `_`, not `-` (supersedes PRD v0.5 §Claimed Filename Format and the ARCHITECTURE.md claim.sh sketch): left-splitting on `-` is ambiguous because hostnames (`ip-10-0-1-100`) and task ids (`TASK-001`) both contain dashes.
