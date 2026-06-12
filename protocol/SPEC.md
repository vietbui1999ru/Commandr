# `.agents/` Bus Protocol — SPEC v0.2 (draft)

The thin-waist contract for cross-harness agent coordination. Any driver harness (Claude Code, OpenCode, Codex, Pi), worker, UI, or human tooling interoperates with the bus exclusively through the on-disk formats defined here.

**Scope (v0.1):** task queue + neutral progress + approvals + events. Single machine, single repo.
**Added in v0.2:** the council quality gate (§12) — `bin/council`, the `council_verdict` event, conformance C15–C20; and the index fold (§13) — `bin/index`, the derived `~/.agents/index.json` cache, conformance C21–C24.
**Out of scope:** multi-machine claiming (git-ref race, reserved), agent registry, dependency scheduling, timeout recovery, Windows.

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
{"ts": "<ISO8601>", "event": "council_verdict", "task": "<task-id>", "verdict": "PASS" | "FAIL", "evaluator_count": 3, "abstentions": 0}
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
| `.agents/council/` | council verdicts — one file per task, `<task-id>.json`: `{task, verdict, ts, votes[]}`. Contract is now live in §12 (v0.2). Supersedes ARCHITECTURE.md's two divergent sketches (per-task `.result` vs per-evaluator files). |
| `.agents/registry.json` | agent fleet registry (v1) |
| `~/.agents/index.json` | global derived cache across repos — written by `bin/index`, NEVER source of truth. Contract is now live in §13 (v0.2). |
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
| C15 council happy path | COUNCIL-1..5, COUNCIL-9..11 (3 PASS → verdict PASS, file shape, event) |
| C16 council majority math | COUNCIL-8 (2-1 → PASS; 1-2 → FAIL; 0-3 → FAIL) |
| C17 council abstain | COUNCIL-6, COUNCIL-8 (crash/silent evaluators → ABSTAIN; all-abstain → FAIL) |
| C18 council idempotent re-run | COUNCIL-9 (second run overwrites verdict; two `council_verdict` events) |
| C19 council bus resolution | COUNCIL-2, COUNCIL-3 (CWD-independent; verdict + event land in main checkout) |
| C20 council harness independence | COUNCIL-2 (runs with harness binaries stripped from PATH) |
| C21 index fold | INDEX-1..4 (verb, stdout, bus resolution, task projection across two buses) |
| C22 index derived-only | INDEX-5 (no cache inside repo buses; task shape is exactly the projection) |
| C23 index bad repo | INDEX-6 (one missing/unreadable repo recorded, not fatal; good repos still fold) |
| C24 index write discipline | INDEX-7 (creates missing dir; atomic, no tmp residue; provenance; idempotent) |

Not mechanically testable — verified by design review, not by this script: ADAPTER-1 (constrains adapter reasoning, not filesystem output), EVENT-6 (filesystem locality), EVENT-4 beyond C09's heuristic.

Modes: `conformance.sh` (test bus tools alone) · `conformance.sh --adapter <cmd>` (additionally drives a harness adapter through the C13 lifecycle: claim → turn-end projections (§8, EVENT-4 heuristic) → complete → session_end where the harness supports exit hooks. Driver verbs: `capabilities`, `turn-end <dir>`, `session-end <dir> <sid>`).

## 11. Divergences from PRD v0.5

1. Adds `task_progress` (decision 4). PRD's "writers must not emit undefined types" now refers to THIS spec's event set.
2. Claim/complete live in Commandr `bin/` on PATH, not per-project `scripts/` (supersedes ARCHITECTURE.md Placement section and PRD v0.5 §Command Contracts paths).
3. Event-emission responsibility restated as an invariant (CLAIM-4/COMPLETE-2) rather than "caller appends" — same behavior, testable cross-harness.
4. Claimed-filename separator is `_`, not `-` (supersedes PRD v0.5 §Claimed Filename Format and the ARCHITECTURE.md claim.sh sketch): left-splitting on `-` is ambiguous because hostnames (`ip-10-0-1-100`) and task ids (`TASK-001`) both contain dashes.

## 12. Council Quality Gate

**Added in v0.2.** `bin/council` is the one council engine on PATH (blueprint decision 6); `review-council` and `delegate-pi` council mode are thin wrappers over it. Council is **advisory**: it MUST NOT write or delete approval tokens and MUST NOT block the approval gate (§7). The human git gate is authoritative (decision 9). Every MUST below has a conformance ID (§10).

### 12.1 Invocation

```
council <claimed-or-done-path>
```

`<claimed-or-done-path>` is the absolute path to a packet in `.agents/claimed/` or `.agents/done/`. Council is invoked explicitly; it is NOT called automatically by `claim`, `complete`, or `pre-commit-gate`.

- stdout on normal completion (any verdict): `council:<task-id>:<PASS|FAIL>\n`, exit 0 — a FAIL verdict is a normal outcome, not an error.
- exit 1: runtime error (bus unresolvable, packet unreadable, verdict write failed). On exit 1 the verdict file MUST NOT exist or be left partially written.
- exit 2: usage error (wrong argument count; packet not under `.agents/`).

- **COUNCIL-1**: Council is advisory. It MUST NOT create, delete, or alter `.agents/approvals/` tokens, and its verdict MUST NOT gate `pre-commit-gate`. *(C15)*
- **COUNCIL-2**: `council` MUST resolve the bus as the grandparent of the packet's containing directory (same pattern as `complete`), MUST NOT depend on `$CWD`, and MUST NOT require any harness to be installed or running (cf. APPROVAL-2). *(C19, C20)*
- **COUNCIL-3**: The task id MUST be read from the packet's frontmatter `id:` field, never derived from the filename. *(C19)*

### 12.2 Evaluator interface (the testability seam)

- **COUNCIL-4**: `council` MUST read `COUNCIL_EVALUATOR_CMD`. When set to a non-empty value it MUST be used as the evaluator command for all three invocations; when unset or empty `council` falls back to its built-in Haiku-backed evaluator. This override is the deterministic seam used by conformance. *(C15)*
- **COUNCIL-5**: `council` MUST invoke the evaluator exactly three times, in parallel, one per dimension (§12.3), as `$COUNCIL_EVALUATOR_CMD <prompt-file> <dimension>`. A valid vote is exit 0 with a stdout line matching `^VOTE: (PASS|FAIL)$`; an optional following line `REASON: <single-line>` MAY be supplied. All other stdout is ignored. *(C15)*
- **COUNCIL-6**: A non-zero exit, a missing `VOTE:` line, or a timeout (implementations SHOULD default to 120 s) MUST be recorded as `"vote": "ABSTAIN"`. An ABSTAIN is a normal vote outcome, not a `council` error. *(C17)*
- **COUNCIL-7**: `council` MUST remove the temporary prompt files it creates before exiting on the normal path. *(C15)*

### 12.3 Dimensions

`council` MUST run exactly these three dimensions, passed as the second argument; they are not runtime-configurable in v0.2:

| Dimension | Lens |
|---|---|
| `acceptance-criteria` | Do all acceptance criteria in the packet pass? |
| `code-quality` | Does the diff introduce correctness, error-handling, or API-misuse issues? |
| `style` | Are types, naming, and formatting consistent with the surrounding code? |

### 12.4 Majority

Let P = count of `PASS` votes.

- **COUNCIL-8**: `verdict = "PASS"` if and only if `P >= 2`; otherwise `verdict = "FAIL"`. ABSTAIN votes count as non-votes; a tie or all-ABSTAIN run resolves to `"FAIL"` (fail-safe). *(C16, C17)*

### 12.5 Verdict file

- **COUNCIL-9**: On normal completion `council` MUST write exactly one file at `.agents/council/<task-id>.json` (LAYOUT-3: gitignored, derived). The write MUST be atomic (temp file on the same filesystem, then `mv`). An existing verdict file for the same task MUST be overwritten — re-runs are idempotent. *(C18)*
- **COUNCIL-10**: The verdict file MUST contain exactly these top-level fields and no others: `task` (string, COUNCIL-3), `verdict` (`"PASS"|"FAIL"`), `ts` (ISO 8601 UTC), `votes` (array of exactly three Vote objects). A Vote object has `dimension` (one of §12.3), `vote` (`"PASS"|"FAIL"|"ABSTAIN"`), and `reason` (string; MAY be empty for ABSTAIN). Readers MUST tolerate unknown fields (PACKET-2 precedent); writers MUST NOT add fields beyond those listed (decision-4 fence). *(C15)*

```json
{"task":"TASK-001","verdict":"PASS","ts":"2026-06-10T12:00:00Z","votes":[
  {"dimension":"acceptance-criteria","vote":"PASS","reason":"All criteria satisfied."},
  {"dimension":"code-quality","vote":"PASS","reason":"No issues found."},
  {"dimension":"style","vote":"FAIL","reason":"Missing type annotation on webhook.ts:42."}
]}
```

### 12.6 Event

- **COUNCIL-11**: After writing the verdict file and before printing the stdout line, `council` MUST append exactly one `council_verdict` event (§6) carrying `task`, `verdict`, `evaluator_count` (always `3` in v0.2), and `abstentions` (integer). Per-evaluator reasoning MUST NOT appear in the event (decision-4 fence). `council_verdict` is a defined event type (EVENT-3). *(C15, C18)*

### 12.7 Deferred to v0.3

Strict fail-closed coupling (gate the approval token on a present-and-PASS verdict — the §7 APPROVAL-4 open question); a `council_start` event; a `model` field in the verdict file; `COUNCIL_EVAL_TIMEOUT` as a normative knob; runtime-configurable dimensions.

## 13. Index Fold (derived cross-repo cache)

**Added in v0.2.** `bin/index` folds many per-repo buses into one global cache at `~/.agents/index.json` for cross-repo views (blueprint decision 3). The cache is **strictly derived**: every field projects a fact that already exists on some repo's bus. It is NEVER a source of truth — consumers MUST treat it as possibly-stale and reconcile against the repo bus when correctness matters; re-running rebuilds it from scratch. Every MUST below has a conformance ID (§10).

### 13.1 Invocation

```
index refresh [repo ...]
```

- **INDEX-1**: The only verb is `refresh`; any other verb, or a missing verb, MUST exit 2 (usage). The repo list is the positional arguments when any are given, otherwise the registry file (one repo path per line; blank lines and `#`-comments skipped). The registry path defaults to `~/.agents/repos` and the output path to `~/.agents/index.json`; both are overridable via `AGENTS_INDEX_REPOS` / `AGENTS_INDEX_FILE` — the conformance seam, mirroring `COUNCIL_EVALUATOR_CMD`. *(C21)*
- **INDEX-2**: On success `index` MUST print `index:<output-path>\n` and exit 0. *(C21)*
- **INDEX-3**: For each repo the bus MUST be resolved exactly as everywhere else (LAYOUT-1): `$(dirname "$(git rev-parse --git-common-dir)")/.agents` when the path is inside a git work tree, else `<repo>/.agents`. *(C21)*

### 13.2 Projection

The cache has two arrays. `repos[]` records each scanned repo: `path`, `scanned_at` (ISO 8601 UTC), `ok` (bool), and — when the bus was read — `events_mtime`; an unreadable repo additionally carries `error`. `tasks[]` records one object per indexable packet.

- **INDEX-4**: Each task object MUST project, and project only, these bus facts:
  - `repo` — the repo's basename.
  - `id` — the packet frontmatter `id:` (never the filename; PACKET-1 / COUNCIL-3 precedent).
  - `state` — `inbox` | `claimed` | `done`, from the packet's containing directory.
  - `owner` — `{host}_{pid}` parsed from the claimed/done filename (CLAIM-2), or `null` in `inbox`.
  - `verdict` — `PASS` | `FAIL` from `.agents/council/<id>.json` (§12.5), or `null` if none.
  - `last_event_ts` — the `ts` of the last `events.jsonl` line naming this task, or `null`.
  - `last_note` — the `note` of the last `task_progress` line naming this task, or `null`.
  An absent value MUST render as JSON `null`, never be omitted, so the projection shape is fixed. *(C21)*

### 13.3 Derived-only fence

- **INDEX-5**: `index` MUST NOT write the cache — or any other file — into any scanned repo's `.agents/` (decision 3: the per-repo bus is the source of truth; the cache lives under `~/.agents/`). A task object MUST carry only the seven fields in INDEX-4 — no loop-internal or harness-private state (decision-4 fence). *(C22)*
- **INDEX-6**: A listed repo that is missing, has no `.agents/`, or is unreadable MUST be recorded as `{"ok": false, …, "error": …}` with its tasks omitted, and MUST NOT fail the run — one bad repo never aborts the fold (exit 0). *(C23)*

### 13.4 Write discipline

- **INDEX-7**: The output MUST be written atomically (temp file on the same filesystem, then `mv` over the destination), creating the output directory when absent, and leaving no temp residue on the normal path. The fold MUST be idempotent: re-running over unchanged buses reproduces the same task projection. The output MUST carry provenance — a top-level `generated_at` and `tool`, plus per-repo `scanned_at` (and `events_mtime` when a log was read). *(C24)*

### 13.5 Deferred to v0.3

A registry-management verb (`index add` / `index list`); incremental refresh keyed on `events_mtime`; a `stale` flag computed against bus mtimes; per-repo task counts; a watching/daemonized refresh.
