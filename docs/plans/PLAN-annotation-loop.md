# Implementation Plan: Annotation Loop (Tracer-Bullet, Diff-Only MVP)

**Feature:** The Annotation Loop — auto-surfaced browser pane renders each agent turn; human drops card-anchored notes; the next prompt carries them back as injected context, course-correcting that turn.

**Scope:** Diff-only MVP. Prose/conversational capture (which requires per-turn bus artifacts for agent text) is the immediate next slice and is explicitly out of scope here.

**Status:** Pre-implementation. All locked decisions recorded below. Do not re-open them.

---

## Locked Decisions (do not re-open)

| # | Decision | Resolved to |
|---|---|---|
| 1 | Persistence | One-session context injection only. Cross-session L4 archive = parked optional hook, not MVP. |
| 2 | What you annotate | Per-turn agent output (diff cards that already render). Not commit-gate-only, not mid-flight. |
| 3 | Annotation surface | DiffViewer browser, port 3333. Inline per-card annotation boxes. Vanilla JS — no framework. |
| 4 | Agent pickup | Claude Code `UserPromptSubmit` hook reads `consumed=false` notes, prepends bodies to the prompt, flips `consumed=true`. Bus artifact is harness-neutral. OpenCode MVP fallback = manual skill-echo. Post-MVP path = `chat.message` plugin (Path 1). |
| 5 | Format and anchor | Structured JSON. Path: `.agents/annotations/<task>/<turn>-<seq>.json`. Shape: `{task, turn, anchor, ts, author, body, consumed}`. Body is markdown. Anchor is e.g. `"card:src/pay.ts"` or `"general"`. Follows SPEC §9 artifact template (council-verdict pattern). |
| 6 | Auto-open | `sidecarWatcher.js` opens/focuses the browser tab off bus events. Policy: open-once-then-notify (open on session's first turn; OS notification + badge thereafter; no per-turn focus stealing). |
| 7 | Write path | Desktop `POST /annotate` on port 3333. Exclusive-create (`wx`) only; no digest-binding. Appends `task_annotation` event to `.agents/events.jsonl`. |
| 8 | MVP scope | Diff cards only. Prose capture = next slice. |
| 9 | Harness neutrality | `UserPromptSubmit` hook wires Claude Code; OpenCode parity deferred to `chat.message` plugin (post-MVP). This is recorded as a SPEC §11 divergence entry. |

---

## Data Flow

```
agent turn ends
  └─► checkpoint.sh writes .diffviewer/turns/<sessionId>/turn-N.json
        └─► sidecarWatcher.js detects new file via fs.watch()
              └─► ingestFile() → registry.add() → registry.flush() → broadcaster.emit(snapshot)
                    └─► [FIRST TURN] open/focus browser tab   [SUBSEQUENT] OS notify + badge
                          └─► browser receives turn-complete SSE event
                                └─► renderTurnCard() renders diff cards
                                      └─► per-card annotation box: human types note
                                            └─► POST /annotate  {task, turn, anchor, body, author}
                                                  └─► desktop server wx-creates
                                                      .agents/annotations/<task>/<turn>-<seq>.json
                                                        └─► appends task_annotation to events.jsonl

human types next prompt + Enter
  └─► Claude Code fires UserPromptSubmit hook
        └─► user-prompt-submit-hook.sh reads .agents/annotations/<task>/
              finds consumed=false notes
              └─► prepends bodies to the hook's prompt output
                    └─► flips consumed=true on each note file
                          └─► agent receives prompt WITH annotations injected as context
```

---

## Step 1: SPEC v0.3 Merge — New Event Type and Directory Allowlist

**Goal:** Unblock all subsequent steps. EVENT-3 forbids emitting `task_annotation` until SPEC defines it. The C13 allowlist must list `.agents/annotations/` before any tool writes to it (added in Step 6 with the write-helper). The SPEC merge keeps conformance green at **27 pass / 0 fail / 0 skip**; the suite reaches 28 only in Step 6, when C28 + the write-helper land.

**Gate:** This step is split into review (1a) and merge (1b). The live `protocol/SPEC.md` and `protocol/conformance.sh` MUST NOT be edited until the draft is signed off — until then, C28 and the v0.3 additions live only in `protocol/SPEC-v0.3-annotation-loop.draft.md`.

**Step 1a — Review the draft (no live edits):**
- `/Users/vietquocbui/repos/Commandr/protocol/SPEC-v0.3-annotation-loop.draft.md` — review the proposed §14, the `task_annotation` event shape, the §2 layout + §9 namespaces + C13 allowlist additions, the §11 divergence, and the C28 shell case. Confirm section/case numbers are still free (§14, C28).

**Step 1b — Merge to live files (only after sign-off):**
- `/Users/vietquocbui/repos/Commandr/protocol/SPEC.md` — apply the draft: bump header to v0.3, add the `task_annotation` row to the §6 event-shape table, add `.agents/annotations/` to the §2 directory layout + §9 reserved namespaces, add the `ANNOT-*` constraints as §14, add the C28 row to the §10 table **marked reserved**. *(Done — merged; live suite still 27/0/0.)*
- **Do NOT touch `protocol/conformance.sh` here.** C28 drives a real write-helper via `ANNOT_WRITE_CMD`; if added now it would `skip` (no helper yet) and `conformance.sh:882` fail-closes on any skip → red. The executable C28 case + the `annotations` C13-allowlist entry land in **Step 6**, after the write-helper and its CLI shim exist.

**Pattern to mirror:** `council_verdict` was added in v0.2 by adding a row to the §6 event-shapes table at `/Users/vietquocbui/repos/Commandr/protocol/SPEC.md` line 83 and a corresponding entry in the §10 conformance table. Follow the same pattern for `task_annotation`.

**SPEC additions required:**

In §3 directory layout table — add:
```
| `.agents/annotations/` | per-turn annotation files — `<task>/<turn>-<seq>.json`; gitignored (ANNOTATION-1) |
```

In §6 event shapes — add:
```
{"ts": "<ISO8601>", "event": "task_annotation", "task": "<task-id>", "turn": <int>, "anchor": "<string>", "author": "<string>", "seq": <int>}
```

In §10 conformance table — add:
```
| C28 | annotations gitignored | ANNOTATION-1 (`.agents/annotations/` in `.gitignore`) |
```

In §11 divergences — add:
```
10. `UserPromptSubmit` hook is Claude Code-specific. OpenCode parity post-MVP via `chat.message` plugin. Bus artifact (annotation JSON) is harness-neutral (ANNOTATION-2).
```

**Acceptance criteria:**
- *(1a)* Draft reviewed and approved; §14 and C28 confirmed free (highest existing §13 / C27).
- *(1b, post-merge)* SPEC header reads `v0.3`; `task_annotation` appears in the §6 event shapes; `.agents/annotations/` appears in the §2 layout + §9 namespaces; C28 appears in the §10 table.
- *(1b, post-merge)* `protocol/conformance.sh` still exits 0 with **27 pass, 0 fail, 0 skip** — unchanged, because the SPEC merge does not edit it. C28 reaches 28 in Step 6.

**Test:** *(after 1b only)* `bash /Users/vietquocbui/repos/Commandr/protocol/conformance.sh` → 27 pass, 0 fail, 0 skip (unchanged; C28 lands in Step 6).

---

## Step 2: Shared Write-Helper, Desktop `POST /annotate`, and Event Append

**Goal:** Implement the write path end-to-end — the desktop server accepts annotations from the browser and durably records them on the bus.

**Files to touch:**
- `/Users/vietquocbui/repos/Commandr/bin/annotate-write` — **new bus tool (bash)**; the canonical annotation writer, alongside `bin/council`/`bin/progress`. Args `--bus <.agents-dir> --task <id> --turn <n> [--anchor <a>] [--author <a>] [--body <text>]`. Mirrors `bin/council` conventions: JSON-escape (backslash then quote), `date -u +%Y-%m-%dT%H:%M:%SZ`, zero-padded `<turn>-<seq>`, exclusive-create via `set -o noclobber` with server-side seq retry (≤16), `task_annotation` event appended **after** the file write. `stdout: annotation:<path>`. (SPEC §14.3, ANNOT-1..7.) This is what conformance points `ANNOT_WRITE_CMD` at.
- `/Users/vietquocbui/repos/DiffViewer/src/annotate.js` — new file; `makeAnnotateHandler(exec)` (mirrors `steer.js`). Validates `{task, turn, anchor, author, bodyText}`; default `exec` shells to `annotate-write` (resolving `--bus` from the task's repo root), injectable for tests.
- `/Users/vietquocbui/repos/DiffViewer/src/app.js` — wire `app.post('/annotate', makeAnnotateHandler(deps.annotateExec))` after the `/steer` line (~29); expose `app._annotateExec` for test symmetry.
- `/Users/vietquocbui/repos/Commandr/.gitignore` — add `.agents/annotations/` (LAYOUT-3: gitignored / derived).

**Pattern to mirror:**

`/annotate` handler in `annotate.js` mirrors `makeSteerHandler` in `/Users/vietquocbui/repos/DiffViewer/src/steer.js`:

```js
// annotate.js
export function makeAnnotateHandler(exec = defaultAnnotateExec) {
  return async (c) => {
    let body;
    try { body = await c.req.json(); } catch { return c.json({ error: 'invalid body' }, 400); }
    const { task, turn, anchor, author, bodyText } = body ?? {};
    if (typeof task !== 'string' || !task) return c.json({ error: 'task required' }, 400);
    if (typeof turn !== 'number') return c.json({ error: 'turn required' }, 400);
    try {
      await exec({ task, turn, anchor: anchor ?? 'general', author: author ?? 'human', body: bodyText ?? '' });
    } catch {
      return c.json({ error: 'exec failed' }, 500);
    }
    return c.body(null, 200);
  };
}
```

The writer `bin/annotate-write` mirrors `bin/council`'s file+event discipline (create the artifact, then append the event after the file exists — ANNOT-5):

```bash
# server-side seq: start at the count of existing <turn4>-*.json, retry on collision
printf -v turn4 '%04d' "$turn"; seq=$(ls "$dir/$turn4-"*.json 2>/dev/null | wc -l | tr -d ' ')
start=$seq
while :; do
  printf -v seq4 '%04d' "$seq"; f="$dir/$turn4-$seq4.json"
  if ( set -o noclobber; printf '%s\n' "$record" > "$f" ) 2>/dev/null; then break; fi
  seq=$((seq+1)); [ "$seq" -lt $((start+17)) ] || exit 1     # ANNOT-5 bounded retry (≤16)
done
printf '{...,"event":"task_annotation",...,"seq":%d}\n' "$seq" >> "$bus/events.jsonl"
```

`<turn>` and `<seq>` are zero-padded to 4 digits (e.g. `0003-0000.json`); seq is 0-based. Free-text fields (`anchor`, `author`, `body`) are escaped backslash-then-quote and stripped of control bytes, exactly as `bin/progress` / `bin/council` do.

App wiring in `app.js` mirrors line 28 exactly:
```js
import { makeAnnotateHandler } from './annotate.js';
// ...
app.post('/annotate', makeAnnotateHandler(deps.annotateExec));
```

And `app._annotateExec = deps.annotateExec` for test injection symmetry.

**Acceptance criteria:**
- `POST /annotate` with `{task, turn, anchor, bodyText}` returns 200 with empty body.
- File appears at `.agents/annotations/<task>/<turn>-0000.json` (turn and seq zero-padded to 4 digits; first seq is `0000`) with `consumed: false`.
- A second POST on the same turn creates `<turn>-0001.json` (server-assigned next seq); the first note (`<turn>-0000.json`) is never overwritten (ANNOT-3).
- `.agents/events.jsonl` gains a `task_annotation` line with correct fields.
- `POST /annotate` with missing `task` returns 400.

**Test:** Unit test in `/Users/vietquocbui/repos/DiffViewer/test/annotate.test.js` — borrow the `beforeEach`/`afterEach` `mkdtempSync`/`rmSync` harness style from `/Users/vietquocbui/repos/DiffViewer/test/mobile.approvals.test.js`, test IDs `ANN-01` through `ANN-05`: fresh write creates `<turn>-0000.json`; a second write on the same turn creates `<turn>-0001.json` with the first file intact (additive, not idempotent — ANNOT-3); missing `task` returns 400; the `task_annotation` event is appended to `events.jsonl`; `consumed` defaults to `false`.

---

## Step 3: Claude Code `UserPromptSubmit` Hook and OpenCode Fallback Documentation

**Goal:** Implement the pickup side — when the human submits the next prompt, pending annotations are injected as context prefix and marked consumed.

**Files to touch:**
- `/Users/vietquocbui/repos/Commandr/adapters/claude-code/user-prompt-submit-hook.sh` — new shim (transport only, same contract as `stop-hook.sh`: every exit path 0, diagnostics to stderr).
- `/Users/vietquocbui/repos/Commandr/adapters/lib/annotate.sh` — new shared core (mirrors `adapters/lib/checkpoint.sh` structure); reads task identity, scans `.agents/annotations/<task>/`, collects `consumed=false` files, prepends bodies to the hook's `prompt` field, flips `consumed=true` on each.
- `/Users/vietquocbui/repos/Commandr/.claude/settings.json` — register the `UserPromptSubmit` hook (add entry under `hooks` key following the same wiring pattern as the `Stop` hook comment in `/Users/vietquocbui/repos/Commandr/adapters/claude-code/stop-hook.sh` lines 8–14).
- `/Users/vietquocbui/repos/Commandr/GUIDE.md` — document the OpenCode manual-echo fallback in the DiffViewer / adapters section.

**Pattern to mirror:**

`user-prompt-submit-hook.sh` mirrors `stop-hook.sh` structure:

```bash
#!/usr/bin/env bash
# user-prompt-submit-hook.sh — Claude Code adapter shim: UserPromptSubmit → annotation inject.
# Transport only. Reads prompt from stdin JSON; delegates to adapters/lib/annotate.sh.
# Every exit path is 0; diagnostics go to stderr only.
set -u

cwd=$(python3 -c 'import json,sys
try: d=json.load(sys.stdin); print(d.get("cwd",""))
except: pass' 2>/dev/null)
[ -n "$cwd" ] || cwd=$PWD

"$(dirname "$0")/../lib/annotate.sh" "$cwd" || \
  printf 'user-prompt-submit-hook: inject failed for %s\n' "$cwd" >&2
exit 0
```

Hook registration in `.claude/settings.json` mirrors the `Stop` pattern:
```json
"hooks": {
  "UserPromptSubmit": [{ "hooks": [{ "type": "command",
    "command": "/path/to/adapters/claude-code/user-prompt-submit-hook.sh" }] }]
}
```

The `UserPromptSubmit` hook receives a JSON payload on stdin that includes a `prompt` field; the hook outputs modified JSON to stdout with the annotation bodies prepended. If the payload's `prompt` field cannot be patched (unsupported shape), the hook exits 0 with the original payload unchanged (fail-open: annotation injection is best-effort, never a gate).

Task identity resolution in `annotate.sh` mirrors `checkpoint.sh`: check `$AGENTS_TASK_ID`, then fall back to `agent/<task-id>` branch name.

**OpenCode manual-echo fallback documentation (add to `GUIDE.md` §5 DiffViewer section):**

> **OpenCode annotation pickup (MVP fallback):** OpenCode has no `UserPromptSubmit` hook. To inject pending annotations manually before a turn, run `bin/echo-annotations <task>` (or use the `/claim-task` skill which surfaces pending notes). Automatic injection via a `chat.message` plugin is the post-MVP path.

**Acceptance criteria:**
- `adapters/claude-code/user-prompt-submit-hook.sh` exists, passes `bash -n` syntax check.
- `adapters/lib/annotate.sh` exists, passes `bash -n`.
- A synthetic annotation JSON at `.agents/annotations/TASK-TEST/0001-0000.json` (consumed: false) is prepended to a mock prompt string and the file's `consumed` field is set to `true` after the script runs.
- Hook exits 0 in all cases: no annotations, consumed annotations, missing task directory, not-a-repo directory.
- `.claude/settings.json` contains the `UserPromptSubmit` entry.

**Test:** Shell integration test in `test/annotate-hook.sh` — create a temp `.agents/annotations/` tree, invoke `adapters/lib/annotate.sh` with a mock payload, assert output contains annotation body, assert `consumed: true` in the JSON file.

---

## Step 4: DiffViewer Per-Card Annotation Boxes (Vanilla JS)

**Goal:** Add inline annotation UI to each diff file-card in the browser. No framework. No new build step.

**Files to touch:**
- `/Users/vietquocbui/repos/DiffViewer/browser/app.js` — add `renderAnnotationBox(ev, snapshot, doc)` helper; call it inside `renderFileCard()` to append the box below the diff body; add click handler that POSTs to `/annotate`.
- `/Users/vietquocbui/repos/DiffViewer/browser/style.css` — add annotation box styles (textarea + submit button, minimal; hide until the diff body is visible or user hovers the card).
- `/Users/vietquocbui/repos/DiffViewer/browser/index.html` — no change expected unless a new element is needed in the shell HTML.

**Pattern to mirror:** The steer box in `renderTurnCard()` at `/Users/vietquocbui/repos/DiffViewer/browser/app.js` lines 51–70. The annotation box follows the same `el()` builder pattern and the same `fetch('/annotate', ...)` call shape:

```js
// Inside renderFileCard(ev, doc), after building `card`:
function renderAnnotationBox(ev, snapshot, doc) {
  const textarea = el(doc, 'textarea', {
    className: 'annotation-input',
    placeholder: 'Annotate this file…',
  });
  const btn = el(doc, 'button', { textContent: 'Note', className: 'annotation-send' });
  btn.addEventListener('click', async () => {
    const body = textarea.value.trim();
    if (!body) return;
    await fetch('/annotate', {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        task: snapshot.task,
        turn: snapshot.turnNumber,
        anchor: `card:${ev.path}`,
        bodyText: body,
        author: 'human',
      }),
    });
    textarea.value = '';
    btn.textContent = 'Noted';
    setTimeout(() => { btn.textContent = 'Note'; }, 1500);
  });
  return el(doc, 'div', { className: 'annotation' }, [textarea, btn]);
}
```

The annotation box is appended to each `file-card` after the `diff-body` div. It is visible only when `diff-body` is not hidden (toggled by the same header click handler).

**Note:** `snapshot.task` is already propagated through `sidecarWatcher.js` into the snapshot at the `snapshot.task = parsed.task` line. The `renderTurnCard` function receives the full snapshot, so `task` is available when constructing per-card elements.

**Acceptance criteria:**
- Each rendered file-card shows an annotation textarea and "Note" button when the diff body is expanded.
- Clicking "Note" fires `POST /annotate` with the correct `anchor: "card:<path>"`.
- The textarea clears and the button shows "Noted" briefly on success.
- If `snapshot.task` is null (session without a bus task), the `POST /annotate` is suppressed or degraded gracefully (show a "no task active" tooltip; do not fire).
- No new npm dependencies added.

**Test:** Unit test in `/Users/vietquocbui/repos/DiffViewer/test/app.test.js` (existing test file) — add `ANN-UI-01`: render a turn card with a known snapshot and verify the DOM contains an `annotation-input` textarea inside each `file-card`. Mock `fetch` to assert the correct payload shape. Use the existing jsdom pattern from that test file.

---

## Step 5: `sidecarWatcher.js` Auto-Open (Open-Once-Then-Notify)

**Goal:** When the daemon sees a new session's first turn broadcast, open/focus the browser tab automatically. Subsequent turns on the same session send an OS notification and update the tab badge; they do not steal focus.

**Files to touch:**
- `/Users/vietquocbui/repos/DiffViewer/src/sidecarWatcher.js` — add `openedSessions` Set to the watcher closure; after `broadcaster.emit(snapshot)` inside `ingestFile`, if `snapshot.sessionId` is not in the set, call the injected `onFirstTurn(sessionId)` callback and add to the set; otherwise call the injected `onSubsequentTurn(sessionId, snapshot)` callback.
- `/Users/vietquocbui/repos/DiffViewer/server.js` — pass `onFirstTurn` and `onSubsequentTurn` to `createSidecarWatcher`. `onFirstTurn` calls `open` (the `open` npm package) to launch `http://localhost:3333`. `onSubsequentTurn` calls `node-notifier` or a shell `osascript` one-liner for the OS notification. Both callbacks are no-ops if no package is available (best-effort, not a gate).

**Pattern to mirror:** The grounding specifies: "For 'open-once-then-notify': `ingestFile` returns `true` on first successful broadcast; you can track a `Set<sessionId>` of already-opened sessions in the watcher closure and call your open/notify function inside the `if (snapshot)` block after `broadcaster.emit`." This is the exact pattern to implement — the Set lives in the `createSidecarWatcher` closure, not in `ingestFile` itself, so the callbacks are injected as deps alongside `registry` and `broadcaster`.

Modified `createSidecarWatcher` signature:
```js
export function createSidecarWatcher(roots, deps = {}) {
  // ...
  const openedSessions = new Set();
  const onFirstTurn = deps.onFirstTurn ?? (() => {});
  const onSubsequentTurn = deps.onSubsequentTurn ?? (() => {});
  // Inside the ingestFile success block:
  //   if (!openedSessions.has(snapshot.sessionId)) {
  //     openedSessions.add(snapshot.sessionId);
  //     onFirstTurn(snapshot.sessionId);
  //   } else {
  //     onSubsequentTurn(snapshot.sessionId, snapshot);
  //   }
}
```

The callbacks are passed from `server.js` and are no-ops in tests, so no test changes are required for the existing sidecar test suite.

**Acceptance criteria:**
- First `broadcaster.emit` for session `S` triggers `onFirstTurn('S')` exactly once.
- Second and subsequent emits for session `S` trigger `onSubsequentTurn`.
- A second session `S2` triggers `onFirstTurn('S2')` independently of S.
- Startup scan (pre-existing turns) does not trigger `onFirstTurn` (the scan runs before the watcher adds sessions to the Set; this is inherent since `openedSessions` starts empty and the scan path calls `ingestFile` directly).

**Test:** Unit test in `/Users/vietquocbui/repos/DiffViewer/test/sidecarWatcher.test.js` — add `SW-OPEN-01` through `SW-OPEN-03`: inject spy callbacks via `deps.onFirstTurn` and `deps.onSubsequentTurn`, emit two turn files for the same session, assert `onFirstTurn` called once and `onSubsequentTurn` called once. Use the existing `mkdtempSync` pattern from that file.

---

## Step 6: Tests, Conformance Case, and GUIDE Feature-State Row

**Goal:** Confirm all acceptance criteria are machine-verifiable; conformance stays green; GUIDE reflects the new capability.

**Files to touch:**
- `/Users/vietquocbui/repos/DiffViewer/test/annotate.test.js` — new file; ANN-01 through ANN-05 (wx invariant: fresh write, idempotent second write, missing task field returns error, event append, consumed flag default).
- `/Users/vietquocbui/repos/DiffViewer/test/sidecarWatcher.test.js` — add SW-OPEN-01 through SW-OPEN-03 (open-once-then-notify callback invariants).
- `/Users/vietquocbui/repos/DiffViewer/test/app.test.js` — add ANN-UI-01 (annotation box present in rendered card DOM).
- `/Users/vietquocbui/repos/Commandr/protocol/conformance.sh` — **add the C28 case here** (from the SPEC draft) and add `annotations` to the C13 allowlist (the `case` arms near lines 539 and 551–552). Run with `ANNOT_WRITE_CMD=$PWD/.../bin/annotate-write`. This is the step where the suite goes 27 → 28.
- `/Users/vietquocbui/repos/Commandr/GUIDE.md` — add row to the `## 7. Current feature state` table.

**Conformance verification:** `bash /Users/vietquocbui/repos/Commandr/protocol/conformance.sh` → 28 pass, 0 fail.

**DiffViewer test verification:** `npx vitest run` in `/Users/vietquocbui/repos/DiffViewer` → all tests pass (previously 52; new count includes `ANN-*` and `SW-OPEN-*` additions).

**GUIDE feature-state row to add:**

```
| Annotation Loop MVP (diff-card inline notes → UserPromptSubmit inject) | live | SPEC v0.3 |
```

Place it after the `Mobile companion MVP-0` row.

**Acceptance criteria:**
- All new test IDs pass.
- `conformance.sh` exits 0 with 28 pass, 0 fail.
- `npx vitest run` exits 0.
- GUIDE table updated in the same session per the living-doc rule in `GUIDE.md` lines 6–9.

---

## Post-MVP / Next Slices

### Prose Capture (Immediate Next Slice)

Per-turn agent text is not currently captured into any bus artifact. `checkpoint.sh` only writes diff events. To render prose cards alongside diff cards, a new `turn-N.json` field (e.g. `agentText`) must be written by the Claude Code adapter's stop hook and read by `sidecarWatcher.js`. This requires:

1. Extend `checkpoint.sh` to capture the turn's assistant text (Claude Code hook payload includes transcript path).
2. Extend `sidecarWatcher.js`'s `ingestFile` to extract `agentText` and pass it to the broadcaster.
3. Add a `renderProseCard` function in `browser/app.js`.
4. Annotation anchor for prose cards: `"prose:<turn>"` rather than `"card:<path>"`.

This slice is independent of the diff-only MVP and can land without touching any of the six steps above.

### OpenCode Parity — `chat.message` Plugin (Path 1)

OpenCode's plugin system supports a `chat.message` event that fires before a turn is sent. A plugin at `~/.config/opencode/plugins/annotate-inject.js` can read `.agents/annotations/<task>/` and prepend pending bodies to the outgoing message — the same behavior as the `UserPromptSubmit` hook, but for OpenCode without any proxy infrastructure. This is the recommended post-MVP path (designated Path 1 in the locked decisions). The plugin should reuse the annotation-reader logic from `adapters/lib/annotate.sh` (or a JS port of it).

### L4 Archive Hook (Parked)

The one-session injection model means annotations are consumed and gone. A minimal archive hook — appended at the end of `adapters/lib/annotate.sh` — could copy consumed annotations to `~/.agents/archive/<task>/` for future retrieval. This is deliberately parked: it requires defining the L4 knowledge-layer contract, which is a separate feature with separate acceptance criteria. The hook insertion point is documented here so it does not require re-designing `annotate.sh`.
