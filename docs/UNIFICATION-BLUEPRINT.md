# Unification Blueprint — One Platform from a Fragmented AI-Coding Toolchain

**Status:** Decisions locked (do not re-grill). Execution not started.
**Date:** 2026-06-09
**Provenance:** Reconstructed from the 2026-06-09 grill session (`llm-wiki/.claude/session-state.md`). The 11 decisions, placement, and migration phase names/sequence are verbatim-locked. Phase gate descriptions (§6 Gate column) and sections marked *(reconstructed)* were re-derived from repo evidence and the locked decisions, because the original conversation detail was not persisted.

---

## 1. Problem

Four harnesses (Claude Code, OpenCode, Codex, Pi) across three repos (DiffViewer, Commandr, llm-wiki) plus dotfiles have accreted overlapping infrastructure. A 6-agent exploration mapped the fragmentation.

**Core finding: the complexity is DUPLICATION, not missing features.**

Duplicated subsystems *(reconstructed enumeration — counts are locked, membership re-derived)*:

- **3 council implementations:** `review-council` skill (llm-wiki/claude-setup), `delegate-pi` council mode, `council.py` (llm-wiki/templates, also wired into CI as `council-review.yml`).
- **4 task stores:** `.agents/` inbox/claimed/done queue, `ralph-structured` `tasks.json`, Claude Code native task list, GitHub issues via `to-issues`.
- **3 session-state formats:** `.claude/session-state.md` (save-session skill), `.agents/claimed/*.state.md` agent state files, harness-native session storage (CC / OpenCode / Pi each have their own).

Every new tool re-implements queueing, review, and state instead of plugging into a shared contract.

## 2. The 5-Layer Model

| Layer | Role | Owner |
|---|---|---|
| **L1 Driver** | Orchestrating harness (Claude Code, OpenCode) | dotfiles (adapters + portable config) |
| **L2 Execution** | Worker substrate — multi-provider models, parallel workers | Pi (`~/.pi`): workers, pueue, council subprocess |
| **L3 Bus** | The one contract: task queue + neutral progress + approvals + events | **Commandr** (protocol + bin/) |
| **L4 Knowledge** | Wiki, search, code graph | llm-wiki: wiki + qmd + CGC + (optional) LightRAG |
| **L5 UI** | Thin viewer over the bus | DiffViewer (browser now, Tauri later) |

Shape: **thin waist.** L1/L2/L5 talk to each other only through L3's filesystem contract. Harnesses stay swappable because the contract is plain files, not any tool's API.

### 2026-06-18 Addendum: new sources, same boundary

Recent synthesis from Agent-Native, Builder Skills, and omp sharpens the roadmap without changing the 11 locked decisions:

| Source | Adopt | Do not adopt |
|---|---|---|
| Agent-Native | Shared action vocabulary for UI/agent operations | Its shared SQL runtime as source of truth |
| Builder Skills | Portable `SKILL.md` workflow packages for agents | Skill internals as bus lifecycle state |
| omp + LSP | L2 worker quality: hashline edits, language-server diagnostics/symbols, DAP, eval kernels, custom tools | omp/LSP session state as the bus |

Commandr remains L3: claim, progress, approvals, events, annotations, council verdicts, derived index. Runner-local state, UI state, and skill internals stay outside `.agents/`. Implementation plan: `docs/plans/PLAN-control-plane-runner-packages.md`.

## 3. The 11 Locked Decisions

1. **Driver:** model-freedom + cost matter → **decouple, don't migrate**. Keep the harness swappable; commit to no single vendor loop.
2. **Shape:** **thin waist** — the `.agents/` bus is the one contract everything plugs into.
3. **Bus location:** **per-repo `.agents/` is the source of truth** + a global `~/.agents/index.json` derived cache for cross-repo views.
4. **Bus scope:** **queue + neutral progress only.** Cross-harness and human→bus communication go through the bus; loop-internal chatter stays harness-local (projected to the bus, not stored there). This retires the session-state duplication.
5. **UI:** **thin viewer** — DiffViewer reads the BUS, not Claude Code hooks. Browser now, Tauri later.
6. **Council:** **one engine** — `council.py` becomes `council` on PATH; verdicts are bus-native files. `review-council` and `delegate-pi` council mode become thin wrappers over it.
7. **Context:** **qmd (knowledge) + CodeGraphContext on KuzuDB, session-scoped (code graph)**. LightRAG optional. Pi context-mode stays harness-local.
8. **Pi:** **L2 execution substrate** — multi-provider workers, pueue, pi-diff-review gate, council subprocess. The model-freedom engine. **Not** an L1 orchestrator.
9. **Human gate:** **async review + harness-INDEPENDENT git pre-commit gate** (`.agents/approvals/<task-id>.approved`). `pi-diff-review` demotes to opt-in babysitting.
10. **Day-one driver:** **dual-primary** — Claude Code *and* OpenCode adapters, both validated against **one conformance test first**. (User overrode the CC-first recommendation.)
11. **Bus home:** **Commandr becomes the bus.** It gets the code. Its identity is waist + services — not a monolith app.

## 4. Placement — Who Owns What

| Repo | Layer | Owns | Sheds / Changes |
|---|---|---|---|
| **Commandr** | L3 | `protocol/SPEC.md` + `protocol/conformance.sh`; `bin/`: `claim`, `complete`, `index`, `council`, `pre-commit-gate` | Goes from 0 code → critical path. Dependency hub. |
| **DiffViewer** | L5 | Browser server (Tauri later), pi-extension | Input re-homed from CC hooks → bus watching. Merge stale `design/v0.5-spec` branch. |
| **llm-wiki** | L4 | wiki + qmd + CGC + LightRAG — knowledge ONLY | **Sheds `claude-setup/` → dotfiles.** Stops double-duty as config distribution. |
| **dotfiles** | L1 | Harness adapters + portable config (rules, AGENTS.md, agent fleet, env-routing); deploy via stow + sync-agent-rules | Receives `claude-setup/` from llm-wiki. |
| **~/.pi** | L2 | Workers, pueue, council subprocess | **Action:** create `~/.pi/agent/AGENTS.md` (tier routing — confirmed missing; top Pi gap). |

## 5. Delete / Move / Build *(reconstructed from locked decisions)*

### Build (new)
- `Commandr/protocol/SPEC.md` — the minimal bus contract (Phase-0 gate).
- `Commandr/protocol/conformance.sh` — the one conformance test; definition of done for every adapter.
- `Commandr/bin/claim`, `bin/complete`, `bin/index`, `bin/council`, `bin/pre-commit-gate` — bus services on PATH. Phase 0 needs `claim`/`complete`/`pre-commit-gate` (SPEC v0.1 contracts); `index` and `council` land with Phase 3 services (contracts deferred to SPEC v0.2).
- `~/.agents/index.json` — global derived cache (written by `bin/index`, never authoritative).
- `~/.pi/agent/AGENTS.md` — Pi tier routing.
- CC + OpenCode adapters (dotfiles) — both conform to SPEC before anything else builds on the bus.

### Move
- `council.py`: llm-wiki/templates → Commandr `bin/council` (one engine; decision 6).
- `claude-setup/`: llm-wiki → dotfiles (decision: llm-wiki is L4 knowledge only).
- DiffViewer input source: CC hook ingestion → bus watching (decision 5).
- Per-repo claim/complete scripts (`scripts/claim.sh` pattern in ARCHITECTURE.md) → Commandr `bin/` on PATH. *Supersedes ARCHITECTURE.md's per-project script placement.*

### Delete / retire
- Session-state duplication: `.claude/session-state.md` + agent `.state.md` formats retire in favor of bus queue + neutral progress (decision 4). Harness-local session files remain harness-local.
- `review-council` and `delegate-pi` council internals — gutted to thin wrappers over `council` (decision 6).
- `pi-diff-review` as a mandatory gate — demoted to opt-in babysitting (decision 9).
- CC-hook-driven DiffViewer input path — replaced by bus watching (decision 5).

## 6. Migration Phases

| Phase | Content | Gate |
|---|---|---|
| **0** | Define the waist: Commandr `protocol/SPEC.md` + `bin/` + conformance test **FIRST** | conformance.sh passes against reference impl |
| **1** | Dual adapters (CC + OpenCode) converge on the schema | both adapters pass the same conformance test |
| **2** | Re-home DiffViewer to the bus | **first big payoff** — UI works for any harness |
| **3** | Services: `council` on PATH; `~/.pi/agent/AGENTS.md`; CGC → KuzuDB session-scoped | wrappers (review-council, delegate-pi) delegate to `council` |
| **4** | Shed llm-wiki double-duty: `claude-setup/` → dotfiles | llm-wiki contains knowledge only |
| **5** | *(later)* Tauri UI; multi-machine claim (`mv` → git-ref race) | — |

## 7. Risks & Mitigations *(first risk locked in session state; the other two reconstructed from decisions 10 and 4)*

- **Commandr goes 0 → critical path.** Mitigation: Phase-0 conformance test is the definition of done; nothing builds on the bus until it passes. Cut the v0.5 PRD surface to minimal queue + approval + events if it drags (it was flagged over-specified / "not to-issues ready", then patched).
- **Dual-primary adapters double Phase-1 work.** Accepted by explicit user override (decision 10); the single conformance test bounds the cost.
- **Bus scope creep.** Decision 4 is the fence: loop-internal state never lands on the bus.

## 8. Relationship to Existing Docs

- `docs/prds/PRD-v0.5-local-agent-control-tower.md` — remains the v0.5 *implementation* spec (single-machine local loop). The protocol SPEC extracts its data-format contracts as the harness-neutral subset; where they diverge, **SPEC.md wins** for cross-harness behavior.
- `docs/ARCHITECTURE.md` — component map still valid except script placement (per-project `scripts/` superseded by Commandr `bin/` on PATH) and the council section (now `bin/council`, decision 6).
- `docs/PRD.md` — long-horizon vision (multi-machine, registry, council, hosted observability). Phase 3 maps roughly to its v1 (council; registry deferred); Phase 5's multi-machine claim maps to its v2. Phase 4 (llm-wiki shed) and Phase 5's Tauri UI have no PRD.md equivalent — they are unification-specific.

## Related

- llm-wiki: `[[concepts/shared-task-queue]]` (claim protocol prior art), `[[syntheses/control-plane-expansion-plan]]` (gap analysis this supersedes in part), `[[concepts/council-pattern]]`, `[[concepts/agent-harness]]`.
