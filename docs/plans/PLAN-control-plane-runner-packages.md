# Plan: Control-Plane Runner and Skill Packages

**Status:** Future refactor / implementation backlog.
**Date:** 2026-06-18.
**Purpose:** Record the Agent-Native + Builder Skills + omp synthesis for future Commandr agents without reopening the locked L3 bus decisions.

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
| omp | L2 execution substrate | Add an omp runner wrapper first; later expose Commandr actions as omp custom tools. |
| LSP | L2 code intelligence | Treat language servers as runner capabilities for diagnostics/symbols/references; never as bus state. |

DiffViewer mirrors this plan in `docs/V0.7-CONTROL-PLANE-COCKPIT-PLAN.md`. Treat that document as the L5 cockpit plan and this document as the L3 boundary plan.

---

## Future Artifact 1: Bus Action Vocabulary

Create `docs/COCKPIT-ACTIONS.md` or a SPEC appendix only after the action names are used by DiffViewer/Tauri.

Initial vocabulary:

| Action | Commandr side effect |
|---|---|
| `task.claim` | Move packet from `inbox/` to `claimed/`; append `task_claimed`. |
| `task.progress` | Append `task_progress`. |
| `task.complete` | Move packet to `done/`; append `task_complete`. |
| `task.fail` | Preserve failure artifact if needed; append `task_failed`. |
| `approval.request` | Create/display a pending approval artifact outside committed bus state. |
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
| `approval-policy` | Explain approval state and pending gate outcome |
| `bus-debugger` | Validate layout, events, stale claimed packets, missing tokens |

Definition of done for any skill: it must call public Commandr commands or read SPEC-defined files only. It must not parse private adapter state.

---

## Future Artifact 3: `commandr-omp-runner`

Start with a wrapper, not a deep omp extension.

Integration ladder:

| Level | Shape | Gate |
|---|---|---|
| 0 | Manual subprocess: `omp -p "<task packet>"` | Captures stdout/stderr; no bus writes except human-managed completion. |
| 1 | `commandr-omp-runner` wrapper | Claims packet, creates worktree/session, runs omp, streams logs, emits progress, completes/fails. |
| 2 | omp custom tools | `commandr_progress`, `commandr_request_approval`, `commandr_emit_artifact`, `commandr_complete`. |
| 3 | omp extension | Intercepts omp events/tool calls and writes bus-safe projections directly. |

Recommended first implementation is Level 1.

Level 1 acceptance criteria:

- It can claim exactly one task or accept a pre-claimed packet path.
- It sets `AGENTS_TASK_ID` for child processes.
- It appends neutral `task_progress` milestones only; no tool-call transcripts in `events.jsonl`.
- It maps normal success to `task_complete` and abnormal runner failure to `task_failed`.
- It leaves omp private state outside `.agents/`.
- It has a deterministic test seam for the `omp` command.

Level 2 candidate tool schemas:

```json
{"name":"commandr_progress","input":{"task":"TASK-001","note":"one-line neutral status"}}
{"name":"commandr_request_approval","input":{"task":"TASK-001","action":"commit","reason":"why human gate is needed"}}
{"name":"commandr_emit_artifact","input":{"task":"TASK-001","type":"review-package","path":".diffviewer/artifacts/TASK-001.json","summary":"one-line summary"}}
{"name":"commandr_complete","input":{"task":"TASK-001","result":"pass"}}
```

Do not add `commandr_emit_artifact` to SPEC until DiffViewer/Tauri has an actual artifact store consumer and a conformance case.

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

1. Draft `docs/COCKPIT-ACTIONS.md` in DiffViewer/Tauri repo first, because L5 owns the action registry UI.
2. Add non-normative Commandr mapping table from cockpit actions to existing commands/events.
3. Implement `commandr-omp-runner` Level 1 with a fake `OMP_CMD` test seam.
4. Add lazy LSP capability detection to runner metadata or review artifacts, without adding raw LSP state to SPEC.
5. Add adapter/conformance coverage for runner lifecycle if it becomes a supported Commandr command.
6. Only then design omp custom tools and any new SPEC event types.

---

## Non-Goals

- Replacing `.agents/` with a database.
- Storing full runner transcripts on the bus.
- Making Commandr a UI or dashboard.
- Making skills a second task queue.
- Letting omp own task lifecycle.
- Treating Neovim/Mason state as Commandr bus state.
