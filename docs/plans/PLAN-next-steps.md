# Plan: Next Steps — Post Annotation-Loop MVP

**Status:** Planning / ordered backlog.
**Date:** 2026-06-19.
**Scope:** Synthesizes the state after the annotation-loop diff-only MVP landed, folds in the llm-wiki operator-lane research, and orders the next slices. Extends — does not re-open — `PLAN-control-plane-runner-packages.md` (omp/LSP/cockpit-actions backlog) and `PLAN-annotation-loop.md` (annotation post-MVP).

---

## 0. Status snapshot (2026-06-18)

- Annotation loop diff-only MVP: **live end-to-end**. Bus write (`bin/annotate-write` + C28), DiffViewer producer (`POST /annotate` + per-card UI + `sidecarWatcher` auto-open), CC consumer (`UserPromptSubmit` hook + `adapters/lib/annotate.sh`). Commandr conformance **28/0/0**; DiffViewer vitest **136/0** after the direct-steer and flake-fix cleanup.
- `bin/index` symlinked onto `~/.local/bin` → C21–C24 run natively (no more skips).
- Discovered untracked `DiffViewer/nvim/diffviewer.lua` — a Neovim bridge plugin (SSE stream → diff buffer → `git checkout --` decline → `POST /steer`). Realizes the operator-lane pattern from the wiki. Origin: operator experiment, not the annotation work.

---

## 1. Immediate cleanup (loose ends from this session)

| # | Item | Action | Why |
|---|---|---|---|
| 1.1 | CC `UserPromptSubmit` hook wired in project `.claude/settings.json` with hardcoded `/Users/vietquocbui/repos/Commandr/...` path | **DONE (2026-06-18):** switched to `$CLAUDE_PROJECT_DIR/adapters/claude-code/user-prompt-submit-hook.sh` — portable across checkout paths. Home decision: project-scoped (only repos with `.agents/` have anything to inject), documented in GUIDE §5. `Stop`/`SessionEnd` stay a documented global install (§3.3) — the asymmetry is deliberate, not a bug. | Portability + consistency. |
| 1.2 | 6 bus tools (`claim`/`complete`/`pre-commit-gate`/`progress`/`council`/`annotate-write`) still NOT on global PATH — conformance only passes via `*_CMD` env overrides | **DONE (2026-06-18):** symlinked all 7 (incl. `index`) into `~/.local/bin`. Bare `bash protocol/conformance.sh` passes 28/0/0. One collision: `complete` is a bash builtin → `conformance.sh` runs `enable -n complete` so the bus tool shadows it for the test process (documented in GUIDE §6). | A bare `bash protocol/conformance.sh` should pass. |
| 1.3 | DiffViewer uncommitted `src/steer.js` + `test/steer.test.js` + `README.md` (pre-existing, not from annotation work) | **DONE (2026-06-19):** reviewed and committed as `db3f7d2 feat(steer): support direct OpenCode sessions safely`. Added raw OpenCode session IDs, synthetic-card clipboard fallback, and deterministic `sidecarWatcher` waits. Full DiffViewer suite passes 136/136. | Clean working tree before stacking more work. |
| 1.4 | DiffViewer open PRs: #3 (`feat/architecture-view-path-a`), #2 (`feat/mobile-realdevice-hardening`) | **DONE (2026-06-18):** split/merged stale PRs; no open DiffViewer PRs remained before the 2026-06-19 steer cleanup commit. | Pipeline hygiene. |
| 1.5 | `DiffViewer/nvim/diffviewer.lua` untracked | Decision: keep + document as the v0 Neovim bridge, or move to dotfiles. See §3. | It is the first operator-lane artifact. |
| 1.6 | Stale `.claude/worktrees/` | Audit + clean (manual; do not auto-remove). | Housekeeping. |

**Gate:** after 1.1–1.4, both repos have passing verification and only known local runtime/operator artifacts remain (`.agents/`, `.claude/session-state.md`, worktrees/cache, and `DiffViewer/nvim/`).

---

## 2. Annotation loop — post-MVP slices

From `PLAN-annotation-loop.md` "Post-MVP", ordered by value:

1. **Prose capture (immediate next slice).** `checkpoint.sh` writes diff events only; agent text is not on the bus. To render prose cards alongside diff cards: extend `checkpoint.sh` to capture the turn's assistant text (CC hook payload includes transcript path), extend `sidecarWatcher` `ingestFile` to extract `agentText`, add `renderProseCard` in `browser/app.js`, anchor `prose:<turn>`. Independent of diff-only MVP — lands without touching the six done steps.
2. **OpenCode parity — `chat.message` plugin (Path 1).** `~/.config/opencode/plugins/annotate-inject.js` reads `.agents/annotations/<task>/` and prepends pending bodies to the outgoing message. Reuse the reader logic from `adapters/lib/annotate.sh` (JS port). Replaces the manual-echo fallback documented in GUIDE §5.
3. **L4 archive hook (parked).** Copy consumed annotations to `~/.agents/archive/<task>/` at the tail of `annotate.sh`. Parked until the L4 knowledge-layer contract is a separate feature with its own ACs.

---

## 3. Neovim operator lane

Per [[syntheses/neovim-ai-operator-workflow]] and [[concepts/lsp-agent-baseline]] (both created 2026-06-18 in the wiki). The two-lane invariant is the spine:

| Lane | Owner | Startup | Bus state? |
|---|---|---|---|
| Human IDE | Neovim + Mason + lspconfig + nvim-dap | On opening buffers; servers attach by filetype/root | No — never on `.agents/` |
| Agent execution | omp / CC / OpenCode / runner | Lazy, per worktree, only when agent needs code intelligence | No LSP state; neutral progress only |

**Locked invariant (do not re-open):** Commandr does not start Neovim; LSP/DAP/Mason state never enters `.agents/`. The bus records neutral progress + lifecycle outcomes + artifact *references*, never the artifact bodies.

### 3.1 The `nvim/diffviewer.lua` bridge — v0

The discovered plugin already implements half the operator lane:
- SSE consumer (`curl -N http://localhost:3333/stream`) → pending-turn statusline.
- `build_lines(snap)` → diff buffer (`filetype=diff`).
- `d` key → `git checkout -- <path>` (decline file).
- `c` key → `POST /steer` (steer agent).
- `<leader>dv` → open latest turn.

Gaps vs the wiki synthesis:
- No `task_annotation` path yet — operator cannot drop card-anchored notes from Neovim. Should call `bin/annotate-write` (or `POST /annotate`) with `anchor: "nvim:<path>:<line>"`.
- No LSP/DAP evidence handoff.
- Deep-link scheme open (`nvim://file:line` vs terminal command) — [[syntheses/neovim-ai-operator-workflow]] lists this as an open question.
- Hardcoded `localhost:3333`; no auth (acceptable for loopback MVP; matches DiffViewer's loopback model).

**Action (1.5 follow-up):** keep `nvim/diffviewer.lua` in the DiffViewer repo as the v0 bridge; document it in DiffViewer README; add the annotation-write path as the next bridge slice.

### 3.2 Artifact reference types (resolve wiki open questions)

Name two referenced-not-stored artifact types, mirroring the council signal-file shape (one JSON per task per dimension):

| Type | Body lives at | Bus stores |
|---|---|---|
| `lsp-diagnostics-summary` | `.diffviewer/artifacts/<task>.json` or runner worktree | neutral progress line + reference path |
| `dap-debug-session` | runner worktree / DiffViewer artifact | neutral progress line + reference path |

Do **not** add these to SPEC until DiffViewer/Tauri has a concrete consumer (matches `PLAN-control-plane-runner-packages.md` Future Artifact 1 rule: every new action/artifact needs a conformance check before becoming normative).

### 3.3 claude-setup onboarding hook

Per [[syntheses/neovim-ai-operator-workflow]] "Design Implications": when operator IDE is Neovim, record `operator_ide: neovim`, `lsp_manager: mason`, `dap_manager: mason+nvim-dap`, and suppress global duplicate Claude LSP plugins. **Recommend document-only for v1** (keep claude-setup harness-agnostic); decide install-vs-document later.

---

## 4. Verification ladder (wire into the plan)

Per [[concepts/lsp-agent-baseline]] + [[concepts/verification-pipeline]]. Make verification the ralph-loop exit signal.

L2/runner + operator lane → L5 review → L3 bus gates:

1. LSP diagnostics (operator lane + runner L2)
2. typecheck / compiler (runner)
3. unit + integration tests (runner)
4. diff review (DiffViewer L5 — now with annotation loop for HITL notes)
5. council quality gate (bus `bin/council`, `council_verdict`)
6. human approval (bus `.agents/approvals/<task>.approved` → `pre-commit-gate`)

Rule (from [[concepts/verification-pipeline]]): layer-don't-replace, plan-validation gate, merge-before-cleanup, claim-before-resume. Do not build a third parallel gate — the approval token covers commits, council covers quality (per [[concepts/preference-feedback-loop]] human-approval-gate pattern).

---

## 5. Backlog cross-reference (not duplicated here)

`PLAN-control-plane-runner-packages.md` owns:
- Future Artifact 1: bus action vocabulary (`docs/COCKPIT-ACTIONS.md`, starts in DiffViewer repo).
- Future Artifact 2: `agent-control-skills/` (Builder-style `SKILL.md` packages).
- Future Artifact 3: `commandr-omp-runner` (Level 1 wrapper first).
- Future Artifact 4: LSP-aware runner capability (metadata + neutral progress only).
- Steering boundary (steer text is runner-local unless it becomes `annotation.create`).

Pick up §5 only after §1–§3 here close.

---

## 6. Suggested order

1. **§1 cleanup** — hook portability (1.1), bus tools on PATH (1.2), DiffViewer tree + PRs (1.3–1.4), `nvim/` decision (1.5). Gate: clean pushable trees, bare conformance green.
2. **§2.1 prose capture** — highest-value annotation slice; makes the loop carry agent text, not just diffs.
3. **§3.1 nvim bridge annotation-write path** — let the operator drop notes from Neovim; closes the Neovim↔bus loop the `nvim/diffviewer.lua` v0 half-implements.
4. **§2.2 OpenCode `chat.message` plugin** — parity for the non-CC harness.
5. **§3.2 artifact reference types** — only when DiffViewer/Tauri has a consumer.
6. **§5 control-plane/omp/LSP backlog** — starts in DiffViewer repo per `PLAN-control-plane-runner-packages.md`.

---

## Non-Goals

- Re-opening the 11 locked blueprint decisions or the annotation-loop locked decisions.
- Storing LSP/DAP/Mason state or runner transcripts on `.agents/`.
- Making the Neovim bridge the authoritative task queue (Commandr stays lifecycle source of truth).
- Building a third parallel human-gate alongside approval + council.
- Adding artifact types or bus actions to SPEC before a conformance-backed consumer exists.
