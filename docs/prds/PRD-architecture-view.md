# PRD — Architecture View in DiffViewer (fork of CodeBoarding)

**Status:** Draft — needs-triage
**Date:** 2026-06-15
**Layer:** L5 viewer (DiffViewer). Bus (Commandr L3) untouched by Path A.
**Source of inspiration:** [CodeBoarding/CodeBoarding](https://github.com/CodeBoarding/CodeBoarding) (MIT) — static-analysis → component-graph IR (`analysis.json`) rendered as Mermaid, with an incremental architecture-delta engine (`cluster_delta.py` + `snapshotCommit` baseline).

> This PRD defines **Path A** (buildable now) as the deliverable, and records **Path B** (Commandr-driven, per-change architecture deltas) as a deferred plan. The two were separated deliberately: Path A consumes a pre-produced artifact and changes only the viewer; Path B is where Commandr's bus owns *production* of the artifact and emits change events. The operator wants Path A now and Path B long-term.

---

## Problem Statement

An operator running Claude Code / OpenCode agents through the Commandr bus watches a live stream of **code diffs** per turn in DiffViewer. They can see *what lines changed* but have no view of *how the system is shaped* — which components exist, how they depend on each other, and (eventually) how a change reshaped that structure. Neither Commandr nor DiffViewer has any semantic model of the code; both shuttle raw text diffs. To understand structure today, the operator must hold the architecture in their head or read `docs/ARCHITECTURE.md` ASCII art that drifts from reality.

CodeBoarding already solves the "understand a codebase's structure" problem — it produces a real, regenerable component graph. It is MIT-licensed and its canonical artifact (`analysis.json`) is a clean, IR-first data contract that can be consumed independently of its Python analyzer or its renderers.

## Solution

Add an **Architecture view** to DiffViewer's desktop frontend: a tab beside the diff feed that renders the repository's component graph as a Mermaid diagram.

For the MVP (Path A), DiffViewer does **not** run CodeBoarding. An external step (the operator, a git hook, or CI) runs the CodeBoarding CLI and leaves `analysis.json` in the repo. DiffViewer reads that artifact on demand, transforms its component-graph IR into a Mermaid `graph LR` string server-side, and the browser renders it via the Mermaid CDN — mirroring the existing pattern where the server normalizes and the browser paints.

The operator gets a "single pane of glass": diffs streaming in on one tab, the system's architecture on another, refreshed whenever they re-run CodeBoarding.

---

## User Stories

1. As an operator, I want an "Architecture" tab in the DiffViewer desktop UI, so that I can see my system's structure without leaving the diff viewer.
2. As an operator, I want the architecture diagram rendered as a clear top-level component graph, so that I can grasp the system at a glance.
3. As an operator, I want the diagram to show directional dependencies between components, so that I understand which parts depend on which.
4. As an operator, I want the diagram drawn from CodeBoarding's `analysis.json`, so that it reflects a real static analysis rather than hand-maintained ASCII art.
5. As an operator, I want the Architecture tab to read the artifact when I open it, so that I always see the latest committed analysis without restarting DiffViewer.
6. As an operator, I want DiffViewer to find `analysis.json` at CodeBoarding's native `.codeboarding/` path by default, so that no copy/symlink glue is required.
7. As an operator, I want to override the artifact path via an environment variable, so that I can point DiffViewer at a non-default location.
8. As an operator, I want the diff feed to remain completely unchanged, so that adding the Architecture view never regresses my primary workflow.
9. As an operator, when no `analysis.json` exists yet, I want a clear empty-state message telling me how to generate one, so that I'm not staring at a blank tab wondering if it's broken.
10. As an operator, when `analysis.json` is malformed or unreadable, I want a graceful error in the tab rather than a crashed server, so that a bad artifact never takes down the diff feed.
11. As an operator, I want component names and their relationships labeled on the diagram, so that the graph is readable, not just boxes and arrows.
12. As an operator, I want the diagram to pan and zoom, so that I can navigate a large graph on one screen.
13. As an operator, I want the architecture transform to be unit-tested against a real CodeBoarding fixture, so that I trust it handles the actual field shapes (dotted IDs, expandable components, cluster references).
14. As an operator, I want the rendered tab verified by a screenshot before the feature is called done, so that "the tests pass" can't hide a diagram that fails to render in the browser.
15. As a maintainer, I want the IR→Mermaid transform isolated in a single server-side module with a pure interface, so that I can test it without a browser and reuse it later (e.g. from the bus).
16. As a maintainer, I want the Architecture feature to add no runtime dependency beyond a CDN script, so that DiffViewer keeps its no-build, vanilla-JS identity.
17. As a maintainer, I want the data endpoint namespaced (`/api/architecture`), so that it doesn't collide with the existing root route or any future static page.
18. As a maintainer, I want DiffViewer to remain a pure reader of the artifact (never a writer/runner), so that the L5 viewer identity holds and Path B can later write to the same path without conflict.
19. As an operator, I eventually want to click an expandable component and drill into its sub-components, so that I can explore a large system level by level. *(Phase A.2 — see Out of Scope.)*
20. As an operator, I eventually want changed/added/removed components highlighted on the diagram, so that I can see how a change reshaped the architecture. *(Path B — see Deferred Plan.)*
21. As an operator, I eventually want the bus to regenerate the architecture and push an update automatically when I approve a turn's work, so that the diagram stays live without manual re-runs. *(Path B.)*

---

## Implementation Decisions

### Locked decisions (from design grill)

| # | Decision | Choice |
|---|---|---|
| D1 | Producer boundary | DiffViewer **reads** `analysis.json`; it never runs CodeBoarding (Path A). Production is external (operator / git hook / CI). |
| D2 | Artifact discovery (MVP) | **Lazy load** — the data endpoint reads disk on each request. No file watch in the MVP. |
| D3 | Artifact path | Default to CodeBoarding's native `.codeboarding/analysis.json` under the watched repo root; overridable via env var (e.g. `DIFFVIEWER_ARCH_PATH`). |
| D4 | Transform location | **Server-side (Node).** IR→Mermaid runs in a Node module; the browser only calls the Mermaid renderer. |
| D5 | Render depth | **Top-level component graph only** for MVP. Drill-down is phase A.2 (additive — the IR already nests sub-components per node). |
| D6 | Static vs delta | **Static current-state only.** Added/changed/removed highlighting is deferred to Path B. |
| D7 | UI surface | **Tab toggle in the existing single page** (Diffs ⇄ Architecture). Fallback: a separate static page if tab wiring proves intrusive. |
| D8 | Frontend scope | **Desktop only.** The mobile PWA (approval gate) is untouched. |
| D9 | Data/view split | Data endpoint `GET /api/architecture` returns `{ mermaid, meta }`; the view lives in the desktop static assets. |

### Modules to build / modify

**New — Architecture IR transform (deep module).**
A pure, server-side module: input is CodeBoarding's parsed `analysis.json` object; output is a Mermaid `graph LR` source string plus light metadata (component count, relation count, repo name, generated-at, commit hash). It walks top-level components into Mermaid nodes (label = component name, id = sanitized `component_id`) and `RelationJson` entries (`src_id`→`dst_id`) into directed edges. It owns all IR-quirk handling: dotted hierarchical IDs, `can_expand` flags (ignored for MVP depth, preserved in meta), `source_cluster_ids`, and id sanitization for Mermaid-safe identifiers. This is the one piece genuinely forked from CodeBoarding's `diagram_generator` logic, reimplemented in JS because of the Node/Python split. Pure in → pure out: no I/O, no globals, trivially unit-testable, the interface rarely changes.

**New — Architecture artifact reader.**
A thin module that resolves the artifact path (env override → default `.codeboarding/analysis.json` relative to the repo root), reads + JSON-parses the file, and returns one of: parsed IR, "not found" (→ empty state), or "invalid" (→ error state). Isolates filesystem + parse concerns from the transform so the transform stays pure.

**Modify — HTTP app.**
Add `GET /api/architecture`: call the reader, then the transform; respond `{ mermaid, meta }` on success, a structured empty-state payload when absent, and a 4xx/5xx with a readable message when malformed. No other route changes; the bare root route stays as-is.

**Modify — desktop frontend.**
Add a header nav toggling `#turns` (existing diff feed) and a new `#architecture` section. On tab activation, fetch `/api/architecture`, and on success call the Mermaid renderer on the returned source; render empty/error states inline. Load Mermaid from CDN (matching the existing diff2html-via-CDN pattern). The diff rendering path is not modified.

### Contracts

- **Input contract:** CodeBoarding `UnifiedAnalysisJson` (`metadata`, `components`, `components_relations`, `files`, `methods_index`, `snapshotCommit`). DiffViewer adopts this as its architecture data contract **regardless of producer** — so a different analyzer could later emit the same shape.
- **Endpoint contract:** `GET /api/architecture` → `200 { mermaid: string, meta: { repoName, generatedAt, commitHash, componentCount, relationCount } }` | `200 { mermaid: null, state: "empty", hint: string }` | `4xx/5xx { error: string }`.
- **Invariant:** DiffViewer only ever **reads** the artifact path. Writing/producing it is out of scope for Path A and is Path B's job.

---

## Testing Decisions

**What makes a good test here:** assert on **external behavior**, not internals. For the transform, that means: given an `analysis.json` object, the returned Mermaid string contains the expected nodes and directed edges and is syntactically renderable — not assertions about intermediate data structures. For the endpoint, that means: given a fixture on disk, the HTTP response has the expected shape and status for the present / absent / malformed cases.

**Modules under test:**
- **IR→Mermaid transform** — primary target. Pure function, ideal for Vitest. Tested against **two fixtures**: (1) a hand-authored minimal `analysis.json` (a few components + relations, covering dotted IDs and an expandable node), and (2) a **real golden `analysis.json`** captured by running CodeBoarding once on a small repo and committed. The real fixture guards against field-shape surprises that hand-authored IR misses.
- **Artifact reader** — tested for the three outcomes: valid file → parsed IR; missing file → "not found"; malformed JSON → "invalid". Filesystem fixtures in a temp dir.
- **Endpoint** — request-level test asserting the `{mermaid, meta}` / empty / error response shapes.

**Prior art:** `src/normalizer.js` has an existing Vitest unit suite (`test/normalizer.test.js`, pure transform, fixture-driven) — the IR→Mermaid transform follows the same pattern. The HTTP routes have existing request-level tests under the Hono app harness (`test/app.smoke.test.js`, `test/server.event.test.js`). For the Architecture tab's DOM rendering, `test/browser.render.test.js` is the direct precedent — an existing jsdom-based render test; the tab's success/empty/error rendering should follow it rather than inventing a new harness.

**Hard gate (UI):** unit tests passing is **not** sufficient for the browser portion. The rendered Architecture tab must be verified with a **screenshot** (visual-verifier / Playwright) showing an actual rendered diagram. Mermaid can throw client-side on a string that passed server-side unit tests; no screenshot = not done.

**One-time fixture cost (flagged):** capturing the real golden fixture requires running CodeBoarding once = installing it (Python + an LLM API key). This is a **test-fixture cost only**. Once the golden `analysis.json` is committed, the suite needs neither Python nor a key at runtime or in CI.

---

## Out of Scope

- **Running CodeBoarding from DiffViewer.** Production of `analysis.json` is external in Path A.
- **Live file-watch / SSE push of the architecture artifact.** MVP is lazy-load on tab open. (A watch on the `.codeboarding/` path is the design north-star and the natural Path B surface, but not built now.)
- **Drill-down into sub-components (Phase A.2).** Additive once the top-level view ships — the IR already carries `components` / `components_relations` per expandable node; needs a component-scoped endpoint param and nav/breadcrumb UI.
- **Architecture-delta highlighting (added/changed/removed nodes).** This is Path B's identity — see Deferred Plan.
- **Mobile PWA support.** Desktop only. The endpoint is frontend-agnostic, so mobile can consume it later if wanted.
- **Reimplementing CodeBoarding's static analyzer** (CFG clustering, Leiden community detection). MIT licensing lets us run their CLI/Action as a black box; we fork only the small IR→Mermaid render.

---

## Deferred Plan — Path B (Commandr-driven architecture deltas)

> Recorded here so the door stays open; **not** part of this PRD's deliverable. Path B is the long-term goal: the bus owns production of the artifact and emits per-change architecture events, and DiffViewer highlights the delta on the same Mermaid graph.

**Shape.** An **optional Commandr adapter** runs CodeBoarding *incrementally* and appends an `architecture_changed` event to `.agents/events.jsonl` with the added / changed / dropped components. DiffViewer consumes the event and highlights the affected nodes on the diagram (additive: a Mermaid `classDef` + node-class assignment on top of the Path A renderer).

**Locked deferred decisions:**
- **Trigger = approval/commit boundary, opt-in, debounced.** Regenerate when a turn's work is *approved* (the existing `pre-commit-gate` / approval-token moment), not every turn. The prior approved commit is the natural `snapshotCommit` baseline for CodeBoarding's incremental delta. Skip regen when the diff touches no files in analyzed clusters.
- **Optional adapter, never in the conformance path.** CodeBoarding (Python + LLM + API key) must not become a bus dependency. Commandr's "zero external services" rule (v1 infra decision) holds: the bus emits the *event*; a sidecar adapter produces the payload. The conformance suite must not depend on CodeBoarding being installed.
- **Reuse Path A's transform + endpoint.** The IR→Mermaid module and `/api/architecture` surface built in Path A are the consumption side; Path B adds production + delta metadata, not a parallel renderer.

**Open verification (blocks Path B design, not Path A):** Does CodeBoarding's persisted `analysis.json` **serialize the resolved delta** (added/changed/dropped component sets), or only the `snapshotCommit` *baseline ref*? The `ClusterDelta` lives in `cluster_delta.py`'s in-memory dataclasses (`new_cluster_ids` / `changed_cluster_ids` / `dropped_cluster_ids`); the IR carries `snapshotCommit` as a baseline but it is unconfirmed the resolved set is written to disk. The answer decides whether the adapter can read CodeBoarding's delta directly, or whether Commandr/DiffViewer must retain the prior `analysis.json` and diff the two IRs itself. **Resolve this before committing to a Path B design.**

---

## Further Notes

- **Why fork CodeBoarding at all, vs build from scratch:** its IR is well-designed (recursive component graph, directional weighted relations, methods index), MIT-licensed, and IR-first — so we adopt the *data contract* and one small renderer, and skip the heavy analyzer entirely.
- **Cheapest standalone win, independent of everything above:** adopting `analysis.json` as DiffViewer's architecture data contract gives a stable IR and the option to swap analyzers later — even if Path B never ships.
- **Identity preserved:** Path A touches only L5 (the viewer). The bus contract (`protocol/SPEC.md`), conformance suite, and adapters are unchanged. Per `GUIDE.md`'s living-doc rule, the DiffViewer ingestion contract section and feature-state table should be updated in the same session the Architecture view lands.
