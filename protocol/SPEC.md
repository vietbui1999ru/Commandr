# `.agents/` Bus Protocol — SPEC v0.3 (draft)

The thin-waist contract for cross-harness agent coordination. Any driver harness (Claude Code, OpenCode, Codex, Pi), worker, UI, or human tooling interoperates with the bus exclusively through the on-disk formats defined here.

**Scope (v0.1):** task queue + neutral progress + approvals + events. Single machine, single repo.
**Added in v0.2:** the council quality gate (§12) — `bin/council`, the `council_verdict` event, conformance C15–C20; and the index fold (§13) — `bin/index`, the derived `~/.agents/index.json` cache, conformance C21–C24.
**Added in v0.3:** the annotation loop (§14) — per-turn human notes injected as next-prompt context; the `task_annotation` event; `.agents/annotations/` on the bus. Conformance **C28** drives the bus tool `bin/annotate-write` via `ANNOT_WRITE_CMD` (mirroring how `COUNCIL_CMD` points at `bin/council`); the suite is now **28/0**.
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
  annotations/  # per-turn human annotation notes (§14, v0.3)
```

- **LAYOUT-1**: The bus MUST live in the main checkout, never inside a worktree. From any worktree it is resolved as `$(dirname "$(git rev-parse --git-common-dir)")/.agents`.
- **LAYOUT-2**: `inbox/`, `claimed/`, `done/`, `approvals/` MUST exist (`.gitkeep` permitted) before any bus operation.
- **LAYOUT-3**: Git tracking policy: `inbox/*.md`, `done/*.md`, `.gitkeep` committed; `claimed/`, `approvals/`, `events.jsonl`, `council/`, `annotations/` gitignored.

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
{"ts": "<ISO8601>", "event": "task_annotation", "task": "<task-id>", "turn": 0, "anchor": "<anchor>", "author": "<author>", "seq": 0}
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
| `.agents/annotations/` | per-turn annotation notes — `<task-id>/<turn>-<seq>.json`: `{task, turn, anchor, ts, author, body, consumed}`. Contract live in §14 (v0.3). |
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
| C25 council diff bus-less | COUNCIL-12, COUNCIL-14 (range mode → verdict JSON on stdout; no `.agents/` file or event created) |
| C26 council diff stdin | COUNCIL-13, COUNCIL-14 (stdin diff; seam invoked 3×; exactly three Vote objects) |
| C27 council diff edges | COUNCIL-15 (empty diff → all-ABSTAIN FAIL, exit 0; unresolvable range → exit 1, nothing on stdout) |
| C28 annotation loop | ANNOT-1..7 (exclusive-create; next-seq; event append; `annotations/` allowlist; EVENT-2/3; consumed flag). Drives `bin/annotate-write` via `ANNOT_WRITE_CMD`. |

Not mechanically testable — verified by design review, not by this script: ADAPTER-1 (constrains adapter reasoning, not filesystem output), EVENT-6 (filesystem locality), EVENT-4 beyond C09's heuristic.

Modes: `conformance.sh` (test bus tools alone) · `conformance.sh --adapter <cmd>` (additionally drives a harness adapter through the C13 lifecycle: claim → turn-end projections (§8, EVENT-4 heuristic) → complete → session_end where the harness supports exit hooks. Driver verbs: `capabilities`, `turn-end <dir>`, `session-end <dir> <sid>`).

## 11. Divergences from PRD v0.5

1. Adds `task_progress` (decision 4). PRD's "writers must not emit undefined types" now refers to THIS spec's event set.
2. Claim/complete live in Commandr `bin/` on PATH, not per-project `scripts/` (supersedes ARCHITECTURE.md Placement section and PRD v0.5 §Command Contracts paths).
3. Event-emission responsibility restated as an invariant (CLAIM-4/COMPLETE-2) rather than "caller appends" — same behavior, testable cross-harness.
4. Claimed-filename separator is `_`, not `-` (supersedes PRD v0.5 §Claimed Filename Format and the ARCHITECTURE.md claim.sh sketch): left-splitting on `-` is ambiguous because hostnames (`ip-10-0-1-100`) and task ids (`TASK-001`) both contain dashes.
5. OpenCode auto-injection of annotation context (§14) is not native to the bus. The annotation artifact is harness-neutral — any harness can read `.agents/annotations/<task>/<turn>-<seq>.json` and prepend `body` fields to the next user prompt. Claude Code implements this via a `UserPromptSubmit` hook; OpenCode's MVP fallback is a manual skill-echo, with full parity reachable post-MVP via a `chat.message` plugin or an HTTP proxy in front of `opencode --serve`. Neither requires forking OpenCode.

## 12. Council Quality Gate

**Added in v0.2.** `bin/council` is the one council engine on PATH (blueprint decision 6). It has two invocation modes that share a single engine (the evaluator seam §12.2, the dimensions §12.3, the majority rule §12.4): **packet mode** (§12.1) is the bus gate; **diff mode** (§12.7) is bus-less and is what the `review-council` / `delegate-pi` wrappers build on. Because `review-council`'s reviewers are Claude-harness subagents — which a shell evaluator seam cannot spawn — `delegate-pi` council mode is a literal `council --diff` wrapper, while `review-council` is a *contract-conformant client*: it keeps its own subagent dispatch but adopts this section's vote format, majority rule, and verdict vocabulary. Council is **advisory**: it MUST NOT write or delete approval tokens and MUST NOT block the approval gate (§7). The human git gate is authoritative (decision 9). Every MUST below has a conformance ID (§10).

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

### 12.7 Diff mode (bus-less evaluation)

`review-council` and `delegate-pi` review a working diff, not a bus packet, and must not touch any repo's `.agents/`. Diff mode is the seam that lets them reuse the one council engine (decision 6) without becoming bus writers.

```
council --diff <ref-range>
council --diff -
```

`<ref-range>` is any argument accepted by `git diff` (e.g. `HEAD`, `HEAD~1..HEAD`); `-` reads a unified diff from stdin. The evaluator seam (§12.2), the three dimensions (§12.3), and the majority rule (§12.4) are identical to packet mode — only the input and the output differ. (The `acceptance-criteria` dimension still runs even though a diff carries no packet criteria; the evaluator judges it against the diff. Keeping all three dimensions makes the engine identical across modes.)

- **COUNCIL-12**: In `--diff` mode `council` MUST NOT resolve or require a bus, MUST NOT write a verdict file, and MUST NOT append any event. It is a pure function from a diff to a verdict on stdout — no `.agents/` side effect of any kind (decision-4 fence; the wrappers operate outside the bus). *(C25)*
- **COUNCIL-13**: The evaluator prompt MUST be built from the diff text alone (there is no packet). The seam is still invoked exactly three times in parallel, once per dimension, with vote-line parsing and ABSTAIN handling exactly as COUNCIL-5 / COUNCIL-6. *(C26)*
- **COUNCIL-14**: On normal completion `--diff` mode MUST print exactly one JSON object to stdout and exit 0: `{"mode":"diff","verdict":"PASS|FAIL","votes":[…]}`, where `votes` is an array of exactly three Vote objects (COUNCIL-10 shape: `dimension`, `vote`, `reason`) and `verdict` follows the majority rule (COUNCIL-8). No other stdout is produced. *(C25, C26)*
- **COUNCIL-15**: A `<ref-range>` that `git diff` cannot resolve MUST exit 1 with nothing on stdout (cf. §12.1). An empty diff (a valid range with no changes, or empty stdin) is NOT an error: the seam MUST NOT be dispatched and the run MUST resolve to `verdict` `"FAIL"` with all three votes `ABSTAIN` (fail-safe, COUNCIL-8), exit 0. *(C27)*

### 12.8 Deferred to v0.3

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

### 13.5 Deferred to v0.4

A registry-management verb (`index add` / `index list`); incremental refresh keyed on `events_mtime`; a `stale` flag computed against bus mtimes; per-repo task counts; a watching/daemonized refresh.

## 14. Annotation Loop

**Added in v0.3.** The annotation loop lets a human attach card-anchored notes to a rendered agent turn in the DiffViewer browser pane; the next prompt the agent receives carries those notes as prepended context. The bus artifact is harness-neutral. Injection is a harness-side convenience layered on top of the artifact; the bus makes no assumptions about which harness consumes it or how. Conformance for this section is case **C28** (§10), which drives the bus tool `bin/annotate-write` through the `ANNOT_WRITE_CMD` seam (mirroring how `COUNCIL_CMD` points at `bin/council`). Each MUST below cites C28 as its check.

### 14.1 Artifact layout

```
<main-checkout>/.agents/annotations/
  <task-id>/
    <turn>-<seq>.json      # one file per annotation
```

- `<task-id>` — the frontmatter `id` of the task being annotated (PACKET-1 / COUNCIL-3 precedent; never the filename).
- `<turn>` — zero-padded 4-digit decimal turn counter matching the turn index the annotated diff was captured from (e.g. `0003`).
- `<seq>` — zero-padded 4-digit decimal sequence number within a turn, starting at `0000`, allowing multiple annotations on the same turn from the same or different authors.

- **ANNOT-1**: The `.agents/annotations/` directory is gitignored and derived (same policy as `.agents/council/` per LAYOUT-3). Its contents MUST NOT be committed. *(C28)*

### 14.2 Artifact shape

Each annotation file MUST be valid JSON containing exactly these top-level fields and no others:

| Field | Type | Description |
|---|---|---|
| `task` | string | Task id (COUNCIL-3 precedent). |
| `turn` | integer | Turn index the annotation targets. |
| `anchor` | string | Card-level anchor, e.g. `"card:src/pay.ts"` or `"general"`. |
| `ts` | string | ISO 8601 UTC write timestamp. |
| `author` | string | Free-form author identifier (e.g. `"human"`, a username). |
| `body` | string | Markdown annotation text. MAY be empty string. |
| `consumed` | boolean | `false` on write; flipped to `true` by the injecting hook after the note has been prepended to a prompt. |

```json
{
  "task": "TASK-001",
  "turn": 3,
  "anchor": "card:src/pay.ts",
  "ts": "2026-06-15T09:00:00Z",
  "author": "human",
  "body": "The retry logic here should cap at 3 attempts — see ADR-12.",
  "consumed": false
}
```

- **ANNOT-2**: Readers MUST tolerate unknown fields (PACKET-2 precedent); writers MUST NOT add fields beyond those listed (decision-4 fence). *(C28)*
- **ANNOT-3**: The annotation set is **additive** — each write creates a new file; existing annotation files MUST NOT be overwritten or deleted by the write path (exclusive-create `O_CREAT|O_EXCL` / `wx`). This is distinct from the council verdict (COUNCIL-9), which is idempotent by overwrite. Annotations accumulate; verdicts replace. *(C28)*
- **ANNOT-4**: There is **no digest-binding**. Annotations are course-correction hints, not decisive gates; a stale note is less harmful than a blocked write path. The write helper MUST NOT reject an annotation because the underlying diff has changed.

### 14.3 Write path

The canonical writer is the bus tool **`bin/annotate-write`** (Commandr), alongside `claim`/`complete`/`council`/`index` — writing a bus artifact is bus-layer work. The DiffViewer `POST /annotate` endpoint and any other surface (mobile, future UIs) shell to it (the bus-tools-on-PATH convention). Conformance drives it directly through `ANNOT_WRITE_CMD` (§10, the same pattern as `COUNCIL_CMD` → `bin/council`).

- **ANNOT-5**: The write helper MUST create the annotation file with exclusive-create semantics (`O_CREAT|O_EXCL` or equivalent), then — in the same logical operation — append exactly one `task_annotation` event (§6, ANNOT-7) to `.agents/events.jsonl`. If the exclusive-create fails (file already exists), the writer MUST retry with the next `<seq>` until the write succeeds or a bounded retry limit is reached (implementations SHOULD allow at least 16 retries; beyond that the request MUST be rejected with an error). The event append MUST follow a successful file write, never precede it. *(C28)*
- **ANNOT-6**: The writer is a single bus tool, shared by every surface (desktop `POST /annotate`, mobile, future UIs) by being invoked as a subprocess. The bus path (`.agents/annotations/<task>/`) MUST be resolved from the writer's `--bus` argument (the `.agents` directory) or from the task id + bus root (LAYOUT-1), never hardcoded. *(C28)*
- **ANNOT-7**: The `task_annotation` event (§6) MUST carry `task`, `turn` (integer), `anchor`, `author`, and `seq` (integer — the `<seq>` that was written). The `body` MUST NOT appear in the event (decision-4 fence: full content lives in the artifact file). `task_annotation` is a defined event type (EVENT-3). *(C28)*

### 14.4 Injection (harness-side, advisory)

Injection is not enforced by conformance — it is a harness-side convention layered on the neutral artifact, documented so adapters implement it consistently.

The injecting hook (e.g. Claude Code `UserPromptSubmit`):

1. Scans `.agents/annotations/<task>/` for files where `"consumed": false`.
2. Prepends each matching `body` to the human's outgoing prompt, in ascending `<turn>-<seq>` file order, as a clearly-labelled context block.
3. Rewrites `"consumed": true` in-place in each consumed file.
4. Emits the modified prompt to the harness.

- **ANNOT-8**: The injecting hook MUST write `"consumed": true` only after the body has actually been injected (for synchronous hooks, immediately before returning the modified prompt). A crash between dispatch and the consumed-flip leaves a note unconsumed and eligible for re-injection — acceptable (additive, idempotent hint) and preferred to silent loss.
- **ANNOT-9**: The injecting hook MUST NOT write new annotation files, MUST NOT append events, and MUST NOT alter any field other than `consumed`. The hook is a reader+consumer, not a bus writer.

### 14.5 Auto-open policy

The DiffViewer sidecar surfaces the browser pane in response to a bus signal (the arrival of a new turn for a task). It MUST NOT be driven by the harness directly (decision 5: the viewer reacts to the bus; the harness stays out).

Policy **OPEN-ONCE-THEN-NOTIFY**: on the first turn the sidecar observes for a given session it opens and focuses the DiffViewer tab; on every subsequent turn in the same session it sends an OS notification (and badge where supported) instead of stealing focus. This is implementation guidance, not a conformance requirement, and carries no conformance case.

### 14.6 Deferred to v0.4

Cross-session note archive (the "it learns me" L4 knowledge-layer feature — an optional hook that copies consumed notes to a persistent store); prose/conversational turn capture (requires a per-turn bus artifact carrying the agent's full turn text, which does not exist today); annotation expiry / garbage collection; multi-author conflict resolution.
