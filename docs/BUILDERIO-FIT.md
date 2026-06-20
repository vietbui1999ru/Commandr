# Builder.io Fit for Commandr

Status: guidance / non-normative.
Date: 2026-06-19.
Source context: Builder.io Agent-Native, Builder.io Skills, `protocol/SPEC.md` v0.3, and `docs/plans/PLAN-control-plane-runner-packages.md`.

## Decision

Builder.io's design fits Commandr as a **pattern source**, not as a runtime replacement.

Use it for:

- A shared action vocabulary that UI clicks, agent proposals, runner adapters, and future MCP/RPC tools can all target.
- Skill packaging for reusable workflows such as visual plans, visual recaps, bus debugging, and review package generation.
- Artifact-first planning and review, where plans and recaps become inspectable files instead of chat prose.

Do not use it for:

- Replacing `.agents/` with SQL state.
- Adding a second task queue.
- Storing skill internals, runner transcripts, tool-call streams, or UI layout state under `.agents/`.
- Emitting non-SPEC events before conformance covers them.

Commandr remains the L3 thin waist. Builder.io ideas improve the action and artifact layer around the bus.

## Layer Mapping

| Builder.io idea | Commandr interpretation |
|---|---|
| Agent-Native `defineAction` | Name bus-safe verbs with schemas, then route mutations through Commandr `bin/` tools. |
| Shared UI/agent state | Useful for DiffViewer/Tauri local cache; not authoritative Commandr state. |
| `/visual-plan` | Produces a planning artifact outside `.agents/`; optional `task_progress` can point to it. |
| `/visual-recap` | Produces a review package outside `.agents/`; Commandr may later reference it if SPEC adds artifact refs. |
| `/agent-watchdog` | Reads packets, events, diffs, sidecars, and artifacts to audit another agent's work. |
| `/plan-arbiter` | Compares competing plans and writes the chosen direction into a packet, annotation, or plan artifact. |
| `/efficient-frontier` | Reinforces model routing: expensive models judge; cheaper agents scan, edit, test, and summarize. |

## Action Boundary

Live actions are only the ones already backed by SPEC v0.3 and conformance.

| Action | Commandr side effect | Status |
|---|---|---|
| `task.claim` | `bin/claim`; move `inbox/` to `claimed/`; append `task_claimed`. | Live SPEC |
| `task.progress` | `bin/progress`; append neutral `task_progress`. | Live SPEC |
| `task.complete` | `bin/complete <claimed-path> pass`; move to `done/`; append `task_complete`. | Live SPEC |
| `task.complete_fail` | `bin/complete <claimed-path> fail`; normal completion with unmet acceptance criteria. | Live SPEC |
| `task.failed` | Supervising adapter appends `task_failed` for abnormal termination. | Live SPEC |
| `annotation.create` | `bin/annotate-write`; write annotation JSON and append `task_annotation`. | Live SPEC |
| `approval.approve` | Create `.agents/approvals/<task-id>.approved`. | Live SPEC |
| `approval.deny` | Write nothing. Optional neutral progress note only. | Live SPEC behavior |
| `council.run` | `bin/council`; write verdict and append `council_verdict`. | Live SPEC |

Non-SPEC actions are local projections until promoted by a SPEC change:

| Action | Current home |
|---|---|
| `approval.request` | DiffViewer UI or runner artifact; no `.pending` file. |
| `artifact.create` | `.diffviewer/artifacts/<task>/` or runner workspace. |
| `review.generate` | DiffViewer review package generator. |
| `runner.start` | Runner adapter, which then uses Commandr actions. |

Do not emit `approval_requested`, `artifact_created`, or `artifact_ref` from Commandr until `protocol/SPEC.md` defines them and `protocol/conformance.sh` tests them.

## Skill Packaging

Builder.io's skills fit as workflow packages outside `.agents/`.

Candidate packages:

| Skill | Allowed inputs | Allowed outputs |
|---|---|---|
| `commandr-task` | packet path, task id, public `bin/` tools | claim/progress/complete through commands only |
| `visual-plan` | packet, qmd/wiki context, code graph | plan artifact outside `.agents/`; optional neutral progress |
| `visual-recap` | git diff, events, council verdict, sidecars | review package outside `.agents/`; optional neutral progress |
| `agent-watchdog` | packet, events, diff, artifacts | audit report; optional neutral progress |
| `bus-debugger` | `.agents/` layout, events, conformance output | diagnostic report; no lifecycle mutation unless explicit |

Skill rule: a skill can call public Commandr commands or read SPEC-defined files. It cannot treat runner-private state as authority.

## Promotion Rule

New bus state must satisfy all checks before entering SPEC:

| Check | Requirement |
|---|---|
| Multi-consumer need | At least two independent consumers need the same fact. |
| Neutral shape | Event/file does not contain runner-private or UI-private state. |
| Rebuildability | Derived caches can be rebuilt from authoritative bus facts. |
| Conformance | Add tests before any adapter or UI depends on it. |
| Backward compatibility | Existing readers tolerate unknown fields/events per SPEC rules. |

Artifact references are the most likely future SPEC candidate, but they should wait until DiffViewer's local review packages prove useful.

## Fit Verdict

Builder.io fits the project if we adopt the **action/artifact discipline** and reject the **runtime replacement** path.

Best near-term sequence:

1. DiffViewer creates `.diffviewer/artifacts/<task>/review-package.json` without SPEC changes.
2. DiffViewer adds a local action dispatcher that shells to Commandr `bin/` tools for lifecycle changes.
3. Commandr keeps documenting action names but does not promote non-SPEC actions.
4. If review packages become first-class across tools, add a conformance-backed artifact reference event in a future SPEC.

## Related Docs

- `protocol/SPEC.md` - authoritative bus contract.
- `docs/plans/PLAN-control-plane-runner-packages.md` - runner and skill package plan.
- `../../DiffViewer/docs/BUILDERIO-FIT.md` - L5 UI fit and artifact contract.
- `~/repos/llm-wiki/wiki/syntheses/builderio-control-plane-integration.md` - broader synthesis.
