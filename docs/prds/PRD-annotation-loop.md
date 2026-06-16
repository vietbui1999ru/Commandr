# PRD: Commandr — The Annotation Loop

## Problem Statement

Agent output in the terminal is hard to read, hard to navigate, and impossible to annotate in context. Long diffs wrap, scroll off screen, and cannot be selected cleanly. When a developer wants to steer the next turn — "that migration looked right but the rollback path is wrong" — they have no mechanism that keeps their note attached to the specific code card they are reacting to. The workaround is a markdown file kept open in a split editor: manual, friction-heavy, and abandoned after one or two turns.

The deeper problem is that the human approval loop is a bottleneck with no channel back in. The developer reads output, spots a problem, and must remember it long enough to retype it into the next prompt. The note detaches from its anchor the moment they stop looking at the diff.

## Solution

The Annotation Loop is a context-injection feature that closes this channel. When an agent turn ends, the diff is rendered as cards in the DiffViewer browser pane (already live on port 3333). The developer annotates individual diff cards in-browser — a text box per card, no separate tool needed. Before the next agent prompt is submitted, a UserPromptSubmit hook reads the pending notes, prepends them to the prompt as injected context, and marks them consumed. The agent receives the original prompt plus the human's card-anchored observations without the developer having to manually copy anything.

This is **context injection for a single session**, not learning. No weights change. Notes enter the agent's input context for exactly one turn and are then consumed. Persistence across sessions and cross-session learning are explicitly out of scope for this release.

## Product Vocabulary

- **Annotation**: A card-anchored human note written in the DiffViewer browser pane.
- **Anchor**: The card identifier the annotation is attached to (e.g., `card:src/payments/pay.ts` or `general`).
- **Annotation artifact**: The JSON file written to `.agents/annotations/<task>/<turn>-<seq>.json` after a POST /annotate.
- **Pending note**: An annotation whose `consumed` field is `false`; eligible for injection.
- **Injection**: Prepending pending note bodies to the human's next prompt before it reaches the agent.
- **Consumed**: An annotation whose `consumed` field is `true`; it has been injected and will not be repeated.
- **Open-once-then-notify**: DiffViewer auto-open policy — focus the browser on the first turn of a session; send OS notification and badge on subsequent turns without stealing focus.
- **wx guard**: Exclusive-create file write (`O_EXCL` / `wx` flag) used by POST /annotate to prevent annotation overwrites.

## Acceptance Criteria

- [ ] SPEC v0.3 defines the `task_annotation` event, the `.agents/annotations/` path, and conformance case C28 (reserved). The SPEC merge keeps the live suite green at **27 pass / 0 fail / 0 skip** (it does not touch `conformance.sh`); C28 reaches **28 pass** once the write-helper and its CLI shim land (Steps 2 + 6).
- [ ] `POST /annotate` on port 3333 shells to `bin/annotate-write`, which exclusive-creates `.agents/annotations/<task>/<turn>-<seq>.json` and appends a `task_annotation` event to `.agents/events.jsonl`.
- [ ] A second annotation on the same turn creates a new file (`<turn>-0001.json`); the write helper assigns the next sequence number server-side and exclusive-create never overwrites the first (`<turn>-0000.json`).
- [ ] The bus tool `bin/annotate-write` performs the write (exclusive-create, server-side seq, event append); desktop and mobile `POST /annotate` shell to it — one writer, reused.
- [ ] The Claude Code UserPromptSubmit hook reads all pending annotations for the current task, prepends their bodies to the outbound prompt, and flips `consumed` to `true` on each.
- [ ] OpenCode MVP fallback is documented: a manual `/skill-echo` command surfaces pending notes for copy-paste; no native hook required at MVP.
- [ ] DiffViewer diff cards render an inline annotation text box below each card. The box is empty by default and submits via `POST /annotate` on blur or explicit send.
- [ ] `sidecarWatcher.js` opens the browser tab on the first turn it observes for a session and sends an OS notification (no focus steal) on subsequent turns.
- [ ] GUIDE feature-state table is updated to include the Annotation Loop row.
- [ ] End-to-end scenario: agent turn ends → diff renders in browser → developer writes annotation on a card → developer submits next prompt → injected context is visible in the agent's received message → annotation is marked consumed.

## User Stories

1. As a developer reviewing a diff in the browser, I want to type a note on a specific changed file's card and have it automatically included in my next prompt, so that I can steer the agent without mentally tracking my observations between turns.

2. As a developer mid-session, I want the DiffViewer tab to open automatically on the first turn and then notify me (without stealing focus) on later turns, so that I can annotate at my own pace without being interrupted.

3. As a developer using OpenCode, I want a documented manual fallback that lets me surface pending notes and paste them into my next message, so that I can use the annotation workflow even before native hook integration lands.

## Functional Requirements

The functional requirements below are derived directly from the eight locked decisions.

### F1 — Annotation Artifact (Locked Decision 5)

Each annotation is stored as a JSON file at:

```
.agents/annotations/<task>/<turn>-<seq>.json
```

The shape follows the SPEC §9 artifact template (council-verdict pattern):

```json
{
  "task":     "<task-id>",
  "turn":     <turn-number>,
  "anchor":   "card:src/payments/pay.ts",
  "ts":       "<ISO8601>",
  "author":   "human",
  "body":     "<markdown text>",
  "consumed": false
}
```

The `anchor` field is either `"card:<file-path>"` for a diff-card annotation or `"general"` for an unanchored note. The `body` field is free-form markdown. In the filename, `<turn>` and `<seq>` are zero-padded 4-digit decimals (e.g. `0003-0000.json`); `seq` starts at `0000` and is assigned server-side by the write helper.

### F2 — Write Path: POST /annotate (Locked Decision 7)

The desktop DiffViewer server adds `POST /annotate` on port 3333 (alongside the existing `POST /steer`). The handler validates the payload (`task`, `turn`, `anchor`, `author`, `bodyText`) and **shells to the bus tool `bin/annotate-write`** (resolving `--bus` from the task's repo root). It returns HTTP 200 on success / 400 on a bad payload / 500 if the writer fails (mirrors the `/steer` handler; the SPEC does not pin the status code).

All bus-touching logic — the artifact path `.agents/annotations/<task>/<turn>-<seq>.json`, the zero-padded server-side `<seq>` with exclusive-create + retry (ANNOT-5), and the `task_annotation` event append — lives in `bin/annotate-write`, NOT in the handler. There is no digest-binding (annotations are additive — no stale-409 dance). Mobile and any future surface shell to the same tool, so there is one writer and one place the invariants are enforced.

### F3 — Agent Pickup: UserPromptSubmit Hook (Locked Decision 4)

A Claude Code UserPromptSubmit hook fires before every prompt submission. The hook:

1. Identifies the current task from `.agents/claimed/` (filename parse, same as stop-hook pattern).
2. Reads all `.agents/annotations/<task>/*.json` files where `consumed === false`.
3. Prepends each note's `body` to the human's outbound prompt, separated by a clearly labelled header (e.g., `--- Annotation [card:src/pay.ts] ---`).
4. Flips `consumed: true` in each consumed artifact file.
5. Passes the modified prompt to the agent.

The bus artifact (`consumed` field) is harness-neutral. The hook is the Claude Code-specific convenience layer. OpenCode does not have a native equivalent at MVP — the documented fallback is a manual skill (`/skill-echo` or equivalent) that reads pending annotations and prints them for copy-paste into the next message. Post-MVP, OpenCode can reach annotation injection via a `chat.message` plugin (recommended Path 1) or an HTTP proxy in front of `opencode --serve` (Path 3). This split — neutral artifact, harness-specific convenience — is a SPEC §11 divergence and must be recorded there.

### F4 — DiffViewer Annotation UI (Locked Decision 3)

The DiffViewer browser pane (vanilla JS, no framework) renders an annotation text box below each diff card. The box:

- Is empty on load.
- Submits its content via `POST /annotate` with the card's file path as the anchor, on blur or an explicit "Add note" button.
- Shows a lightweight confirmation (e.g., checkmark badge) after successful submit.
- Is read-only if the annotation is already consumed.

MVP scope is **diff cards only** (Locked Decision 8). Prose and conversational turn capture require a per-turn bus artifact for non-diff output — that artifact does not exist today and is deferred to the next slice.

### F5 — Auto-Open Policy (Locked Decision 6)

`sidecarWatcher.js` observes new turn artifacts as they arrive (today via `fs.watch` on the DiffViewer turn directory; SPEC §14.5 frames this neutrally as reacting to a new-turn bus signal). On the **first turn it observes for a session**, it opens (or focuses) the DiffViewer browser tab. On every subsequent turn in the same session, it sends an OS notification and increments a badge counter — it does not steal focus. This is the open-once-then-notify policy. The sidecar reacts to the bus; the harness plays no role in tab management, which keeps Decision 5 (viewer reacts to bus) intact and works identically for Claude Code and OpenCode.

## Data Flow

```
agent turn ends
  → sidecar writes turn-N.json (diff artifact)
  → sidecarWatcher.js detects the new turn artifact
  → opens browser tab (first turn) or sends OS notification (subsequent turns)
  → human reads rendered diff cards in DiffViewer browser pane
  → human types note in a card's annotation box, submits
  → POST /annotate
  → desktop server wx-creates .agents/annotations/<task>/<turn>-<seq>.json
  → appends task_annotation to .agents/events.jsonl
  → human types next prompt + Enter
  → UserPromptSubmit hook fires (Claude Code)
  → hook reads pending annotations (consumed=false)
  → prepends note bodies to prompt
  → flips consumed=true on each artifact
  → agent receives enriched prompt
  → agent course-corrects output on next turn
```

## MVP Scope

MVP is a diff-only tracer-bullet:

- Annotate diff cards that already render in DiffViewer.
- Full round-trip: write annotation → inject on next prompt → mark consumed.
- Claude Code hook only; OpenCode fallback is manual and documented.
- Open-once-then-notify auto-open.

**Deferred to next slice:**

- Prose and conversational turn capture (requires per-turn non-diff bus artifact).
- Cross-session annotation archives (L4 knowledge layer, parked as an optional one-line archive hook).
- Native OpenCode injection (plugin or proxy, post-MVP).
- Mobile annotation UI (mobile server already shares the write-helper lib; UI work deferred).

## Build Order

The following sequencing is dependency-strict. No step may begin until its prerequisite is complete, and EVENT-3 (the bus contract) must be resolved before any `task_annotation` event is emitted.

1. **SPEC v0.3** — Add the `task_annotation` event definition, reserve `.agents/annotations/`, and define conformance case C28 (reserved). The live suite stays green at 27 (the SPEC merge does not touch `conformance.sh`). C28 and the C13-allowlist entry are added with the write-helper (Steps 2 + 6).
2. **Shared write-helper + POST /annotate** — Extract write logic into `adapters/lib/`, implement desktop POST /annotate with wx guard and events append.
3. **UserPromptSubmit hook** — Claude Code hook reads/injects/marks-consumed. Document OpenCode manual-echo fallback in GUIDE.
4. **DiffViewer annotation UI** — Per-card text boxes, POST /annotate call, consumed state indicator.
5. **sidecarWatcher auto-open** — Open-once-then-notify logic off new-turn signals.
6. **Tests + GUIDE update** — wx invariant test, hook injection test, new conformance case passing, feature-state table row added.

## Layer Ownership

| Layer | Owner | Responsibility |
|---|---|---|
| L5 DiffViewer | DiffViewer repo | Render diff cards, annotation UI, `POST /annotate` endpoint (shells to `bin/annotate-write`) |
| L3 Commandr bus | Commandr repo | The writer **`bin/annotate-write`**, the neutral artifact (`.agents/annotations/`), the `task_annotation` event, SPEC definition |
| L2 Hook bridge | Claude Code adapter | UserPromptSubmit hook (read, inject, mark consumed) |
| OpenCode bridge | Post-MVP | `chat.message` plugin (Path 1) or HTTP proxy (Path 3) |

The bus artifact is harness-neutral. The hook is the bridge. DiffViewer owns the human-facing surface. This separation keeps the Commandr bus clean of harness-specific logic and allows OpenCode to adopt annotations without forking any core artifact.

## Implementation Decisions

### SPEC Prerequisite (EVENT-3)

`task_annotation` must not be emitted until SPEC v0.3 defines it. The conformance suite is the gate. Any implementation that emits `task_annotation` before the SPEC update will cause the conformance run to fail on the new C-case. Build order step 1 is not optional.

### Exclusive-Create Guard

`bin/annotate-write` creates the file with `O_EXCL` (`set -o noclobber` in the bash tool). This prevents silent overwrites when two annotation writes race for the same `<turn>-<seq>` path. On collision the **writer** increments `<seq>` and retries (per ANNOT-5, at least 16 attempts before erroring) — sequence assignment is server-side, so the caller never sees a 409 in normal operation. There is no digest-based stale check — annotations are additive observations, not version-controlled decisions.

### Sequence Number Generation

The `seq` component of the artifact filename is a monotonically increasing integer per (task, turn) pair, assigned **server-side**: the write helper scans `.agents/annotations/<task>/` for `<turn>-*.json`, takes `seq = count` (0-based — the first note is `0000`), and writes `<turn>-<seq>.json` zero-padded to 4 digits. On `wx` collision (a racing writer took that seq) the helper increments `<seq>` and retries (ANNOT-5). The client sends only `{task, turn, anchor, body, author}` — never a seq — so it never needs to handle a 409.

### Consumed-State Write

When the UserPromptSubmit hook marks an annotation consumed, it does an in-place JSON rewrite of the artifact file (read → mutate `consumed: true` → write). This is a full file rewrite, not an append. The annotation artifact is small (< 2 KB typical), so rewrite cost is negligible. The hook must tolerate a file that is already `consumed: true` without error (idempotent).

### OpenCode Parity Path

OpenCode does not expose a UserPromptSubmit equivalent at MVP. The documented MVP fallback is a manual skill or slash command that reads all pending annotations for the current task and prints their bodies. The developer copies the output into their next message. This is mechanism 2 (manual skill-echo). Post-MVP, the recommended path is a `chat.message` plugin (Path 1), which OpenCode's plugin API supports. An HTTP proxy in front of `opencode --serve` (Path 3) is a valid but heavier alternative. Forking OpenCode is not an acceptable path.

### Auto-Open: Focus Stealing Rejected

Per-turn browser focus stealing was evaluated and rejected. It interrupts developer flow when the agent is running fast and the developer is doing other work. Open-once-then-notify is the policy: one intentional focus on session start, then OS-level notifications that respect notification settings.

### gitignore Policy

`.agents/annotations/` follows the same gitignore policy as `.agents/council/` — runtime ephemeral artifacts, gitignored. Individual annotation files are not committed. The `.gitignore` entry is:

```
.agents/annotations/
```

### Data Format Contracts

#### Annotation Artifact Schema

```json
{
  "task":     "<task-id>",
  "turn":     <integer>,
  "anchor":   "card:<file-path>" | "general",
  "ts":       "<ISO8601>",
  "author":   "human",
  "body":     "<markdown string>",
  "consumed": <boolean>
}
```

All fields are required. `consumed` must be a boolean (not a string). Writers must not add additional fields at MVP.

#### task_annotation Event Shape

```json
{
  "ts":     "<ISO8601>",
  "event":  "task_annotation",
  "task":   "<task-id>",
  "turn":   <integer>,
  "anchor": "card:<file-path>" | "general",
  "author": "<author>",
  "seq":    <integer>
}
```

The event does not embed the annotation body (bodies live in the artifact file, not the event log). The `seq` field allows event consumers to locate the corresponding artifact.

## Success Criteria

| Metric | Target |
|---|---|
| Conformance suite | 0 regressions; new annotation case passes |
| wx collision test | concurrent POST on same turn → server assigns next `<seq>`, both notes written, neither overwritten (ANNOT-3) |
| Hook injection coverage | All pending (consumed=false) notes prepended; all flipped consumed=true after one prompt |
| Round-trip latency | Annotation written → injected into next prompt < 200 ms for typical session (< 20 pending notes) |
| Focus-steal count | 0 per-turn focus grabs after the session's first turn |

## Risks and Mitigations

| Risk | Mitigation |
|---|---|
| EVENT-3 sequencing violated — `task_annotation` emitted before SPEC v0.3 | Build order is strict; conformance gate fails fast if event is emitted pre-SPEC |
| OpenCode parity gap at MVP creates user friction | Manual skill-echo fallback is documented in GUIDE and presented as a first-class path, not a gap |
| Focus stealing breaks developer flow | Open-once-then-notify policy locked in Decision 6; sidecarWatcher must not call `focus()` after session's first event |
| wx collision causes dropped annotations | Server-side seq assignment + retry (ANNOT-5, ≥16 attempts) — the write helper increments `<seq>` and re-writes; no annotation dropped, no client-facing 409 in normal operation |
| Consumed-state rewrite races with concurrent hook invocations | UserPromptSubmit hook is single-threaded per Claude Code session; concurrent invocations are not expected at MVP |
| Annotation artifact path collides with council artifact path | Paths are distinct: `.agents/annotations/` vs `.agents/council/`; no overlap possible |

## Non-Goals

- **Fine-tuning or weight updates.** Annotations are input-context only. Nothing in this feature changes model weights.
- **Cross-session learning.** The L4 knowledge layer (parked). An optional one-line archive hook is the migration path if this is later wanted.
- **Prose and conversational turn capture.** Requires a per-turn non-diff bus artifact that does not exist today. Deferred to the next slice.
- **Mid-flight injection.** Annotations are injected at prompt-submit time only. There is no mechanism to inject context while an agent turn is in progress.
- **Digest-binding on annotations.** Annotations are additive and not version-controlled decisions. No stale-check dance.
- **Native OpenCode injection at MVP.** Documented as a post-MVP path via `chat.message` plugin.
- **Mobile annotation UI at MVP.** The write-helper lib is shared, but the mobile UI work is deferred.
- **Windows support.** Consistent with the broader Commandr non-goal.

## Out of Scope

- GitHub Projects sync for annotation history.
- Hosted annotation observability (Langfuse or equivalent).
- Slack or push notifications for annotations.
- Annotation editing or deletion post-submit (append-only at MVP; the wx guard enforces this).
- Multi-author annotations (single `"author": "human"` at MVP; multi-author is a post-MVP extension).
