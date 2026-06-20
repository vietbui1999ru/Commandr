# Plan: Control-Plane Runner and Skill Packages

**Status:** Level 1 = bus-integrated omp subprocess wrapper live in `adapters/omp/` with 13/13 smoke passing. Level 2 = schema designed, unimplemented, blocked on `omp --mode rpc` adoption. **Non-normative:** `approval_requested`, `artifact_created`, `.agents/approvals/<task>.pending`, `.denied`, and `workspaces/` are NOT in SPEC v0.3 and MUST NOT be emitted/written until added via a conformance-backed SPEC change.
**Date:** 2026-06-20 (Level 1 relocated into Commandr; prior 2026-06-19 revision corrected false completion claims, dropped the blocking turn-time approval gate, fenced SPEC-forbidden events).
**Purpose:** Record the Agent-Native + Builder Skills + omp synthesis for future Commandr agents without reopening the locked L3 bus decisions.

See also: `docs/BUILDERIO-FIT.md` for the concrete fit verdict and action/artifact boundary.

---

## Boundary

Commandr remains the L3 thin waist. It owns lifecycle facts that every harness, worker, UI, or human tool must agree on:

- task claim / complete / fail
- neutral progress
- approvals
- append-only events
- annotations
- council verdicts
- derived cross-repo index

Commandr must not own:

- runner-local session transcripts
- token/tool-call traces
- UI layout state
- skill implementation internals
- omp private memory, schemes, or eval-kernel state

Anything added here must pass the same rule as existing SPEC language: if multiple tools need to coordinate on it, it can be bus state; if only one runner or UI needs it, it stays outside `.agents/` and is projected as neutral progress or artifacts.

---

## New Source Mapping

| Source | Layer impact | Commandr interpretation |
|---|---|---|
| Agent-Native | L5 action/state philosophy | Define bus-safe action names that UI and agents can both invoke, but keep `.agents/` authoritative. |
| Builder Skills | L1/L4 workflow packaging | Package reusable workflows as `SKILL.md` directories; skills call Commandr tools instead of becoming bus state. |
| omp | L2 execution substrate | Add an omp runner wrapper first; later expose Commandr actions as omp RPC host tools (language-agnostic: Python, Rust, Go, bash). |
| LSP | L2 code intelligence | Treat language servers as runner capabilities for diagnostics/symbols/references; never as bus state. |

DiffViewer mirrors this plan in `docs/V0.7-CONTROL-PLANE-COCKPIT-PLAN.md`. Treat that document as the L5 cockpit plan and this document as the L3 boundary plan.

Fit verdict: adopt Builder.io's action/artifact discipline, not its runtime authority model. Commandr stays a filesystem bus; DiffViewer/Tauri may use SQLite and rich UI state as derived projection only.

---

## Future Artifact 1: Bus Action Vocabulary

Create `docs/COCKPIT-ACTIONS.md` or a SPEC appendix only after the action names are used by DiffViewer/Tauri.

Initial vocabulary:

| Action | Commandr side effect |
|---|---|
| `task.claim` | Move packet from `inbox/` to `claimed/`; append `task_claimed`. |
| `task.progress` | Append `task_progress`. |
| `task.complete` | Move packet to `done/`; append `task_complete`. |
| `task.complete_fail` | `bin/complete <claimed-path> fail` for normal completion with unmet acceptance criteria. |
| `task.failed` | Supervisor emits `task_failed` for abnormal termination. |
| `approval.request` | Create/display a local approval proposal artifact outside committed bus state. |
| `approval.approve` | Write `.agents/approvals/<task>.approved`. |
| `approval.deny` | Do not write token; append neutral progress only if useful. |
| `annotation.create` | Write `.agents/annotations/<task>/<turn>-<seq>.json`; append `task_annotation`. |
| `council.run` | Run `bin/council`; write verdict and append `council_verdict`. |
| `artifact.emit` | Candidate future SPEC event; do not add until DiffViewer/Tauri has a concrete consumer. |

Implementation rule: every new action needs a conformance check before it becomes normative SPEC.

---

## Future Artifact 2: `agent-control-skills/`

Builder-style skills are useful packaging for agent workflows. Keep them outside `.agents/`.

Candidate skills:

| Skill | Calls |
|---|---|
| `commandr-task` | `claim`, `progress`, `complete`, `pre-commit-gate` |
| `evidence-package` | DiffViewer/Tauri artifact export + `task_progress` summary |
| `review-package` | `council --diff` + DiffViewer snapshots + residual-risk summary |
| `runner-adapter` | Claim task, launch runner, stream logs, complete/fail |
| `approval-policy` | Explain approval token state and commit-gate outcome |
| `bus-debugger` | Validate layout, events, stale claimed packets, missing tokens |

Definition of done for any skill: it must call public Commandr commands or read SPEC-defined files only. It must not parse private adapter state.

---

## Future Artifact 3: `commandr-omp-runner`

Start with a wrapper, not a deep omp extension.

Integration ladder (updated post-research + post-verification):

| Level | Shape | Status |
|---|---|---|
| 0 | Manual subprocess: `omp -p "<task packet>"` | Smoke test only |
| 1 | `commandr-omp-runner` wrapper | **Complete (2026-06-20)** — lives at `adapters/omp/`; pre-claimed packet contract (`--claimed <path>`), exports `AGENTS_TASK_ID`, calls `PROGRESS_CMD` for neutral milestones, calls `COMPLETE_CMD pass/fail` on exit, policy scan (neutral progress + workspace artifact, no blocking gate), `OMP_BIN/PROGRESS_CMD/COMPLETE_CMD` seams, 13-case smoke test (all pass). |
| 2 | RPC host tools | **Schema designed (non-normative)** — `commandr_progress`, `commandr_request_approval`, `commandr_emit_artifact`, `commandr_complete`, `commandr_fail` via `omp --mode rpc`. Blocked on RPC mode adoption. |
| 3 | omp extension/hooks | Future — intercept events directly |

**Level 1 complete (2026-06-20).** `adapters/omp/runner.sh` is the live runner; all acceptance criteria met.

Level 1 acceptance criteria (all met):

- ☑ Claims exactly one task or accepts pre-claimed packet path — **`--claimed <abs-path>` contract; extracts id from YAML frontmatter; documented in runner.sh header.**
- ☑ Sets `AGENTS_TASK_ID` for child processes — **`export AGENTS_TASK_ID="$TASK_ID"` before omp launch.**
- ☑ Appends neutral `task_progress` milestones via `PROGRESS_CMD`; no tool-call transcripts on the bus — **3 milestones: started, policy hit (if any), complete/failed.**
- ☑ Maps normal success to `task_complete` and abnormal failure to `task_failed` — **via `$COMPLETE_CMD <path> pass/fail`.**
- ☑ Leaves omp private state outside `.agents/` — **workspace is runner-local; bus writes go through PROGRESS_CMD/COMPLETE_CMD only.**
- ☑ Has deterministic test seam for `omp` command — **`OMP_BIN/PROGRESS_CMD/COMPLETE_CMD` env vars, all default to path-lookup; 13-case smoke test at `test/smoke.sh`, all pass.**

Level 2: RPC host tools (schema in `adapters/omp/HOST-TOOLS.md` — a design doc, not implemented code).

Why RPC host tools instead of TypeScript plugins:
- Language-agnostic: host can be Python, Rust, Go, bash — any JSON-lines process
- Bidirectional: agent calls host tools; host steers agent (`steer`, `abort`, `set_model`)
- Real-time: events stream as they happen
- No TypeScript lock-in

Host tool call schema (5 tools; the runner invokes these, they are runner-local calls — the bus side-effect shape is defined in HOST-TOOLS.md and uses SPEC §6 `ts`/`event` keys):

```json
{"toolName":"commandr_progress","arguments":{"task":"TASK-001","milestone":"LSP diagnostics clean","metadata":{"files_changed":["src/auth.ts"]}}}
{"toolName":"commandr_request_approval","arguments":{"task":"TASK-001","action":"destructive bash blocked (high risk)","risk":"high","reason":"rm -rf in workspace root","artifact_ref":"workspaces/TASK-001/artifacts/policy-0001.json"}}
{"toolName":"commandr_emit_artifact","arguments":{"task":"TASK-001","artifact_type":"diff","path":"artifacts/auth-refactor.patch","summary":"+142/-89 lines"}}
{"toolName":"commandr_complete","arguments":{"task":"TASK-001","result":"success","summary":"Refactor complete","next_steps":"Deploy to staging"}}
{"toolName":"commandr_fail","arguments":{"task":"TASK-001","reason":"Type mismatch in JWT payload","recoverable":true,"suggested_retry":"Fix src/jwt.ts:42"}}
```

Policy table (runner-local, agent-aware; the bus never sees the raw command, only a neutral risk note + artifact reference):

| Pattern | Risk | Action |
|---|---|---|
| `bash` with `rm -rf`, `sudo` | High | Emit neutral progress + artifact ref |
| `bash` with `docker run/exec/rm`, `git push` | Medium | Emit neutral progress + artifact ref |
| `write` to `.env`, `~/.ssh/` | High | Emit neutral progress + artifact ref |
| `read`, `edit` | Low | Allow |

**Approval gate decision (must-fix): the blocking turn-time gate is DROPPED.** The enforceable human gate stays the commit-time `pre-commit-gate` (SPEC §7, `.agents/approvals/<task>.approved`, live C11). Council stays advisory (SPEC §12, "MUST NOT block the approval gate"). This plan does NOT introduce a third parallel gate — that was a Non-Goal in `PLAN-next-steps.md` and a brush against locked decision 9. Revised behavior:

- **Level 1 behavior:** runner detects a policy hit → emits a NEUTRAL `task_progress` milestone (e.g. `"policy: destructive bash blocked (high risk)"`) and writes the full action details to a runner-local workspace artifact, referenced by the progress line. Does NOT emit `approval_requested`. Does NOT block. The human reviews in DiffViewer; the commit gate enforces.
- **Level 2 behavior (RPC):** same neutral-progress + artifact-ref projection, plus real-time streaming + bidirectional steer. RPC mode does NOT add a second blocking gate. `.agents/approvals/<task>.pending` and `.denied` are NOT introduced — approval remains `.approved`-only (SPEC §7 APPROVAL-1: denial writes nothing).

**Do not add `commandr_emit_artifact` OR `approval_requested` OR `artifact_created` to SPEC until DiffViewer/Tauri has a concrete consumer and a conformance case.** This hold is now symmetric across all three event types (previously only `commandr_emit_artifact` was held; `approval_requested`/`artifact_created` were inconsistent). `workspaces/` is a runner convention, not a bus contract — no SPEC change needed or wanted for it.

---

## Future Artifact 4: LSP-Aware Runner Capability

LSP should become a baseline for code-changing runners, but Commandr should only model it as capability metadata and neutral progress.

Good bus-safe examples:

- `task_progress`: `LSP diagnostics clean for TypeScript workspace`
- `task_progress`: `LSP reported 3 diagnostics; see review package artifact`
- future artifact reference: diagnostics summary file generated by DiffViewer/Tauri or runner

Bad bus examples:

- raw language-server caches under `.agents/`
- long diagnostic streams in `events.jsonl`
- per-symbol server state as Commandr lifecycle data

Startup policy for Commandr-runner integrations:

1. Read project profile or detect stack from files.
2. Select only matching servers (`vtsls`, `pyright`, `gopls`, `rust-analyzer`, `clangd`, etc.).
3. Start lazily on first code task, not on every chat/session start.
4. Scope one server instance to one workspace/worktree.
5. Let the runner own cleanup; Commandr only records neutral status and lifecycle outcome.

If the operator uses Neovim+Mason, keep that as a separate human IDE lane:

- Mason/lspconfig starts LSPs when human opens buffers.
- nvim-dap starts debug adapters on demand.
- Commandr does not start Neovim or Mason as part of generic session startup.
- Commandr can record neutral progress such as `operator captured DAP reproduction evidence` or future artifact references.

Verification ladder for code tasks remains: LSP diagnostics, typecheck/compiler, tests, diff review, human approval.

---

## Steering Boundary

Steering an active agent session is not Commandr bus state. It is a runner/session control operation owned by L1/L2/L5 adapters.

Current shape:

- DiffViewer can copy steer text to the clipboard.
- DiffViewer can direct-steer OpenCode by calling that OpenCode server's `POST /session/:id/prompt_async` when it has a real OpenCode session id.
- Commandr may record neutral progress before or after a steer if useful, but the steer text itself is runner-local unless it becomes an explicit `annotation.create` bus event.

Do not add a generic `.agents/steer/` queue without a conformance-backed consumer contract. Free-form steer text is not the same thing as a bus action proposal.

---

## Suggested Implementation Order

1. ~~Draft `docs/COCKPIT-ACTIONS.md` in DiffViewer/Tauri repo~~ — DiffViewer V0.7 plan already has action registry.
2. ~~Add non-normative Commandr mapping table~~ — Done in this doc and `HOST-TOOLS.md`.
3. ~~Implement `commandr-omp-runner` Level 1 for real~~ — Done in `adapters/omp/runner.sh`; verified by `adapters/omp/test/smoke.sh` (13/13).
4. Add lazy LSP capability detection to runner metadata or review artifacts, without adding raw LSP state to SPEC.
5. **Next (after Level 1 is genuinely met):** Level 2 — RPC mode with host tools.
   - Requires `omp --mode rpc` adoption (verify it ships before depending on it; consider a JSON-mode sidecar fallback that parses omp tool-call frames so Level 2 is not single-point-blocked on RPC).
   - Register host tools on startup.
   - Handle `host_tool_call` frames.
   - Implement the runner-local policy table; project hits as neutral progress + artifact refs (NOT `approval_requested` events, NOT a blocking gate).
   - Test with actual task packets.
6. Add adapter/conformance coverage for runner lifecycle if it becomes a supported Commandr command.
7. Only then design omp extensions/hooks and any new SPEC event types (`approval_requested`/`artifact_created` need SPEC §6 + §11 divergence + conformance cases BEFORE any emission).

---

## Should-Fix TODOs (documented, not blocking)

These are smells tracked here so they are not lost:

- **Non-RPC Level-2 fallback:** Level 2 is single-point-blocked on `omp --mode rpc` shipping. A JSON-mode sidecar fallback de-risks the schedule.

## Non-Goals

- Replacing `.agents/` with a database.
- Storing full runner transcripts on the bus.
- Making Commandr a UI or dashboard.
- Making skills a second task queue.
- Letting omp own task lifecycle.
- Treating Neovim/Mason state as Commandr bus state.
