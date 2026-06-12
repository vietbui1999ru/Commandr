#!/usr/bin/env bash
# conformance.sh — the one conformance test for the .agents/ bus (SPEC v0.1).
# Definition of done for the bus tools and for every harness adapter.
#
# Modes:
#   ./conformance.sh                  # test bus tools (claim/complete on PATH or via env)
#   ./conformance.sh --adapter <cmd>  # also drive a harness adapter through C13
#                                     # (driver verbs: capabilities, turn-end <dir>,
#                                     #  session-end <dir> <sid> — see c13_adapter)
#
# Status: C01-C24 live, including the adapter-mode C13 drive, the §12 council gate,
# and the §13 index fold.
#
# Env overrides: CLAIM_CMD (default: claim), COMPLETE_CMD (default: complete),
#                GATE_CMD (default: pre-commit-gate), PROGRESS_CMD (default: progress),
#                COUNCIL_CMD (default: council), INDEX_CMD (default: index)
set -u

CLAIM_CMD=${CLAIM_CMD:-claim}
COMPLETE_CMD=${COMPLETE_CMD:-complete}
GATE_CMD=${GATE_CMD:-pre-commit-gate}
PROGRESS_CMD=${PROGRESS_CMD:-progress}
COUNCIL_CMD=${COUNCIL_CMD:-council}
INDEX_CMD=${INDEX_CMD:-index}
export PROGRESS_CMD   # adapters resolve their emitter through this in adapter mode
ADAPTER_CMD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --adapter) ADAPTER_CMD=${2:?--adapter requires a command}; shift 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
PASS=0; FAIL=0; SKIP=0

ok()   { PASS=$((PASS+1)); printf 'PASS %s: %s\n' "$1" "$2"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL %s: %s\n' "$1" "$2"; }
skip() { SKIP=$((SKIP+1)); printf 'SKIP %s: %s\n' "$1" "$2"; }
have() { command -v "$1" >/dev/null 2>&1; }

# --- fixture: throwaway git repo with a bootstrapped bus ---------------------
FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/agents-conformance.XXXXXX")
FIXTURE=$(cd "$FIXTURE" && pwd -P)   # resolve symlinks (macOS /var -> /private/var) so path comparisons hold
# §13 index fixtures live OUTSIDE the git FIXTURE: index resolves a repo's bus via
# `git rev-parse --git-common-dir`, so any bus nested under the git fixture would
# redirect to FIXTURE's own .agents. A separate non-git root exercises the
# $repo/.agents fallback that real per-repo buses take.
IDX=$(mktemp -d "${TMPDIR:-/tmp}/agents-index.XXXXXX")
IDX=$(cd "$IDX" && pwd -P)
trap 'rm -rf "$FIXTURE" "$FIXTURE-wt" "$IDX"' EXIT
cd "$FIXTURE"
git init -q -b main .
mkdir -p .agents/{inbox,claimed,done,approvals}
printf '.agents/claimed/\n.agents/approvals/\n.agents/events.jsonl\n.agents/council/\n' > .gitignore
git add -A && git -c user.email=conf@test -c user.name=conformance commit -qm 'fixture'

make_packet() { # make_packet <id>
  cat > ".agents/inbox/$1.md" <<EOF
---
id: $1
type: implementation
scope: src/**
blocking: []
blocked-by: []
---
# $1
## Context
Conformance fixture task.
## Acceptance criteria
- [ ] none
## Files to touch
src/x
## Do not touch
docs/
EOF
}

# Deterministic council evaluator stubs (the §12.2 testability seam). Each is a
# command invoked as `<stub> <prompt-file> <dimension>`; none spends a token.
council_stubs() { # -> echoes the stub dir
  local d="$FIXTURE/stubs"
  [ -x "$d/pass" ] && { printf '%s' "$d"; return; }
  mkdir -p "$d"
  printf '#!/usr/bin/env bash\necho "VOTE: PASS"; echo "REASON: stub"\n'  > "$d/pass"
  printf '#!/usr/bin/env bash\necho "VOTE: FAIL"; echo "REASON: stub"\n'  > "$d/fail"
  printf '#!/usr/bin/env bash\nexit 1\n'                                  > "$d/crash"
  printf '#!/usr/bin/env bash\nexit 0\n'                                  > "$d/silent"
  printf '#!/usr/bin/env bash\ncase "$2" in style) echo "VOTE: FAIL";; *) echo "VOTE: PASS";; esac\n' > "$d/2p1f"
  printf '#!/usr/bin/env bash\ncase "$2" in acceptance-criteria) echo "VOTE: PASS";; *) echo "VOTE: FAIL";; esac\n' > "$d/1p2f"
  chmod +x "$d"/*
  printf '%s' "$d"
}

# A landed (done/) packet for council to evaluate, with a claimed-style filename.
council_packet() { # council_packet <task-id>  -> echoes relative done path
  local id=$1 p=".agents/done/host_1_$id.md"
  cat > "$p" <<EOF
---
id: $id
type: implementation
scope: src/**
---
# $id
## Context
Council fixture.
## Acceptance criteria
- [ ] none
EOF
  printf '%s' "$p"
}

# A standalone §13 bus with one task per state, plus a council verdict and a
# progress note — the raw material `index` folds. Built under IDX (no git), so
# index takes the $repo/.agents fallback. owner is encoded in the claimed/done
# filename ({host}_{pid}_{id}); the verdict and the "halfway" note are the bus
# facts index must project verbatim.
index_packet() { # index_packet <path> <id>
  cat > "$1" <<EOF
---
id: $2
type: implementation
scope: src/**
---
# $2
EOF
}

index_make() { # index_make <repo-dir>
  local b="$1/.agents"
  mkdir -p "$b"/{inbox,claimed,done,council}
  index_packet "$b/inbox/IX-IN.md"          IX-IN
  index_packet "$b/claimed/box_77_IX-CL.md" IX-CL
  index_packet "$b/done/box_88_IX-DN.md"    IX-DN
  printf '{"task":"IX-DN","verdict":"PASS","ts":"2026-01-01T00:00:00Z","votes":[]}\n' \
    > "$b/council/IX-DN.json"
  {
    printf '{"ts":"2026-01-01T00:00:01Z","event":"task_claimed","task":"IX-CL","agent":"box_77"}\n'
    printf '{"ts":"2026-01-01T00:00:02Z","event":"task_progress","task":"IX-CL","agent":"box_77","note":"halfway"}\n'
    printf '{"ts":"2026-01-01T00:00:03Z","event":"task_claimed","task":"IX-DN","agent":"box_88"}\n'
    printf '{"ts":"2026-01-01T00:00:04Z","event":"task_complete","task":"IX-DN","agent":"box_88"}\n'
  } > "$b/events.jsonl"
}

# --- C01 layout (LAYOUT-1..3) ------------------------------------------------
c01() {
  local id="C01-layout"
  for d in inbox claimed done approvals; do
    [ -d ".agents/$d" ] || { bad "$id" "missing .agents/$d"; return; }
  done
  # LAYOUT-3: all four runtime paths gitignored
  local entry
  for entry in '.agents/claimed/' '.agents/approvals/' '.agents/events.jsonl' '.agents/council/'; do
    grep -qxF "$entry" .gitignore || { bad "$id" "$entry not gitignored (LAYOUT-3)"; return; }
  done
  # LAYOUT-1: resolution from an actual worktree, not just the main checkout
  git worktree add -q "$FIXTURE-wt" HEAD || { bad "$id" "cannot create worktree"; return; }
  local main
  main=$(cd "$FIXTURE-wt" && dirname "$(git rev-parse --git-common-dir)")
  git worktree remove --force "$FIXTURE-wt"
  [ "$main" = "$FIXTURE" ] && [ -d "$main/.agents" ] \
    && ok "$id" "layout + 4 gitignore entries + worktree resolution" \
    || bad "$id" "worktree resolved '$main', expected '$FIXTURE' (LAYOUT-1)"
}

# --- C03 claim happy path (CLAIM-2, CLAIM-3) ----------------------------------
c03() {
  local id="C03-claim"
  have "$CLAIM_CMD" || { skip "$id" "$CLAIM_CMD not on PATH"; return; }
  make_packet TASK-C03
  local out rc
  out=$("$CLAIM_CMD"); rc=$?
  [ $rc -eq 0 ] || { bad "$id" "claim exited $rc on success path (CLAIM-3)"; return; }
  case "$out" in
    claimed:*) ;;
    *) bad "$id" "stdout must start with 'claimed:' (got: ${out%%$'\n'*})"; return ;;
  esac
  # CLAIM-3: packet contents follow the claimed: line
  case "$out" in
    *"id: TASK-C03"*) ;;
    *) bad "$id" "packet contents missing after claimed: line (CLAIM-3)"; return ;;
  esac
  local path=${out%%$'\n'*}; path=${path#claimed:}
  local base; base=$(basename "$path")
  # CLAIM-2: {hostname}_{pid}_{original-filename}, hostname sanitized of '_'
  local host; host=$(hostname | tr '_' '-')
  case "$base" in
    "${host}"_[0-9]*_TASK-C03.md) ok "$id" "exit 0 + claimed path + contents + filename format" ;;
    *) bad "$id" "claimed filename '$base' violates CLAIM-2 ({hostname}_{pid}_{original})" ;;
  esac
}

# --- C04 empty inbox (CLAIM-3) -------------------------------------------------
c04() {
  local id="C04-empty"
  have "$CLAIM_CMD" || { skip "$id" "$CLAIM_CMD not on PATH"; return; }
  rm -f .agents/inbox/*.md
  local out; out=$("$CLAIM_CMD"); local rc=$?
  [ "$out" = "inbox:empty" ] && [ $rc -eq 0 ] && ok "$id" "inbox:empty, exit 0" \
                                              || bad "$id" "got '$out' rc=$rc"
}

# --- C05 claim atomicity race (CLAIM-1) ----------------------------------------
c05() {
  local id="C05-race"
  have "$CLAIM_CMD" || { skip "$id" "$CLAIM_CMD not on PATH"; return; }
  rm -f .agents/inbox/*.md .agents/claimed/*.md
  make_packet TASK-C05
  local wins=0 i
  for i in 1 2 3 4; do "$CLAIM_CMD" > "race.$i.out" 2>/dev/null & done
  wait
  wins=$(grep -l '^claimed:' race.*.out 2>/dev/null | wc -l | tr -d ' ')
  [ "$wins" = "1" ] && ok "$id" "exactly one of 4 racers claimed" \
                    || bad "$id" "$wins racers claimed (expected 1)"
}

# --- C08 event log validity (EVENT-2, EVENT-3 writer side, EVENT-5) ------------
c08() {
  local id="C08-events"
  [ -f .agents/events.jsonl ] || { skip "$id" "no events.jsonl produced yet (needs CLAIM-4 impl)"; return; }
  have python3 || { skip "$id" "python3 unavailable"; return; }
  python3 - <<'PY' .agents/events.jsonl && ok "$id" "lines parse, ts+event present, defined types only, no nulls" || bad "$id" "invalid event line"
import json, sys
DEFINED = {"task_claimed","task_progress","task_complete","task_failed","session_end"}
for line in open(sys.argv[1]):
    if not line.strip(): continue   # readers skip blanks (EVENT-2)
    o = json.loads(line)
    assert "ts" in o and "event" in o          # EVENT-2
    assert o["event"] in DEFINED               # EVENT-3 (writer side)
    assert not any(v is None for v in o.values())  # EVENT-5
PY
}

# --- C02 packet validation (PACKET-1..3) ---------------------------------------
c02() {
  local id="C02-packet"
  have "$CLAIM_CMD" || { skip "$id" "$CLAIM_CMD not on PATH"; return; }
  rm -f .agents/inbox/*.md .agents/claimed/*.md
  # (a) PACKET-1: missing scope — must not be claimable, SHOULD be reported
  cat > .agents/inbox/BAD-C02.md <<'EOF'
---
id: BAD-C02
type: implementation
---
# bad packet — no scope
EOF
  local out rc
  out=$("$CLAIM_CMD" 2>c02.err); rc=$?
  [ "$out" = "inbox:empty" ] && [ $rc -eq 0 ] \
    || { bad "$id" "invalid packet claimable or claim errored: '$out' rc=$rc (PACKET-1)"; return; }
  [ -f .agents/inbox/BAD-C02.md ] || { bad "$id" "invalid packet removed from inbox/ (PACKET-1)"; return; }
  grep -q . c02.err || { bad "$id" "invalid packet not reported on stderr (PACKET-1)"; return; }
  rm -f .agents/inbox/BAD-C02.md
  # (b) PACKET-2: unknown frontmatter field must still claim
  cat > .agents/inbox/TASK-C02.md <<'EOF'
---
id: TASK-C02
type: implementation
scope: src/**
x-unknown-field: must be ignored
---
# TASK-C02
## Context
x
## Acceptance criteria
- [ ] none
## Files to touch
src/x
## Do not touch
docs/
EOF
  out=$("$CLAIM_CMD" 2>/dev/null)
  case "$out" in
    claimed:*) ;;
    *) bad "$id" "unknown frontmatter field rejected (PACKET-2): '$out'"; return ;;
  esac
  # (c) PACKET-3: missing required body sections flagged (claim may still stand —
  # only PACKET-1 fields make a packet unclaimable)
  cat > .agents/inbox/TASK-C02B.md <<'EOF'
---
id: TASK-C02B
type: implementation
scope: src/**
---
# TASK-C02B — body has none of the required sections
EOF
  "$CLAIM_CMD" >/dev/null 2>c02b.err
  grep -qi 'section' c02b.err \
    && ok "$id" "PACKET-1 unclaimable+reported, PACKET-2 tolerated, PACKET-3 flagged" \
    || bad "$id" "missing body sections not flagged on stderr (PACKET-3)"
  rm -f c02.err c02b.err .agents/claimed/*.md
}

# --- C06 claim event invariant (CLAIM-4) ----------------------------------------
c06() {
  local id="C06-claimevt"
  have "$CLAIM_CMD" || { skip "$id" "$CLAIM_CMD not on PATH"; return; }
  rm -f .agents/inbox/*.md .agents/claimed/*.md
  make_packet TASK-C06
  "$CLAIM_CMD" >/dev/null 2>&1 || { bad "$id" "claim failed"; return; }
  # event exists after claim, before any work; keyed by task id (grep is
  # key-order-agnostic: same line must carry both)
  grep '"task_claimed"' .agents/events.jsonl 2>/dev/null | grep -q '"TASK-C06"' \
    && ok "$id" "task_claimed event present after claim" \
    || bad "$id" "no task_claimed event for TASK-C06 (CLAIM-4)"
}

# --- C07 complete (COMPLETE-1..2) -----------------------------------------------
c07() {
  local id="C07-complete"
  have "$CLAIM_CMD" || { skip "$id" "$CLAIM_CMD not on PATH"; return; }
  have "$COMPLETE_CMD" || { skip "$id" "$COMPLETE_CMD not on PATH"; return; }
  rm -f .agents/inbox/*.md .agents/claimed/*.md
  make_packet TASK-C07
  local out rc path base
  out=$("$CLAIM_CMD" 2>/dev/null) || { bad "$id" "claim failed"; return; }
  path=${out%%$'\n'*}; path=${path#claimed:}
  base=$(basename "$path")
  out=$("$COMPLETE_CMD" "$path"); rc=$?
  [ $rc -eq 0 ] || { bad "$id" "complete exited $rc on success path (COMPLETE-1)"; return; }
  [ "$out" = "done:$FIXTURE/.agents/done/$base" ] \
    || { bad "$id" "stdout '$out', expected done:$FIXTURE/.agents/done/$base (COMPLETE-1)"; return; }
  [ -f ".agents/done/$base" ] || { bad "$id" "claimed filename not preserved in done/ (COMPLETE-1)"; return; }
  grep -e '"task_complete"' -e '"task_failed"' .agents/events.jsonl 2>/dev/null | grep -q '"TASK-C07"' \
    || { bad "$id" "no completion event for TASK-C07 (COMPLETE-2)"; return; }
  # missing claimed path: exit non-zero AND no stdout
  out=$("$COMPLETE_CMD" ".agents/claimed/nohost_1_TASK-NONE.md" 2>/dev/null); rc=$?
  [ $rc -ne 0 ] && [ -z "$out" ] \
    && ok "$id" "move + done: line + exit 0; missing path non-zero and silent" \
    || bad "$id" "missing path: rc=$rc stdout='$out' (COMPLETE-1)"
}
# --- C09 progress neutrality (EVENT-4, heuristic) -------------------------------
# Neutrality is not mechanically provable; this tests the testable subset:
# event shape, single-line discipline, malformed-note rejection, and a
# denylist scan for harness-vocabulary leakage in every task_progress note.
c09() {
  local id="C09-neutral"
  have "$PROGRESS_CMD" || { skip "$id" "$PROGRESS_CMD not on PATH"; return; }
  rm -f .agents/events.jsonl
  # (a) valid one-line milestone note: exit 0, event appended with full shape
  "$PROGRESS_CMD" TASK-C09 "acceptance criteria 2/4 done, parser implemented" \
    || { bad "$id" "emitter failed on valid note"; return; }
  local line
  line=$(grep '"task_progress"' .agents/events.jsonl 2>/dev/null | grep '"TASK-C09"')
  [ -n "$line" ] || { bad "$id" "no task_progress event for TASK-C09"; return; }
  printf '%s\n' "$line" | python3 -c '
import json, sys
e = json.load(sys.stdin)
assert e["event"] == "task_progress" and e["ts"] and e["task"] == "TASK-C09"
assert isinstance(e["note"], str) and e["note"].strip() and "\n" not in e["note"]
' 2>/dev/null || { bad "$id" "event shape invalid: $line"; return; }
  # (b) multi-line note must be rejected: non-zero exit, nothing appended (§6 one-line)
  local before after rc
  before=$(wc -l < .agents/events.jsonl)
  "$PROGRESS_CMD" TASK-C09 "line one
line two" 2>/dev/null; rc=$?
  after=$(wc -l < .agents/events.jsonl)
  { [ $rc -ne 0 ] && [ "$before" = "$after" ]; } \
    || { bad "$id" "multi-line note not rejected (rc=$rc, lines $before->$after)"; return; }
  # (c) empty/whitespace note must be rejected
  "$PROGRESS_CMD" TASK-C09 "   " 2>/dev/null \
    && { bad "$id" "whitespace-only note accepted"; return; }
  # (c2) control characters in a note are invalid JSON bytes (EVENT-2)
  "$PROGRESS_CMD" TASK-C09 "$(printf 'tab\there')" 2>/dev/null \
    && { bad "$id" "control character in note accepted (EVENT-2)"; return; }
  # (c3) a task id carrying JSON-special bytes must be rejected, not interpolated
  "$PROGRESS_CMD" 'TASK"-C09' "valid note" 2>/dev/null \
    && { bad "$id" "JSON-special byte in task id accepted (EVENT-2)"; return; }
  # (d) heuristic neutrality scan: no harness-internal vocabulary in any note
  # (EVENT-4: no tool calls, token counts, or harness session structure)
  python3 - <<'PY' .agents/events.jsonl || { bad "$id" "harness-internal vocabulary in a task_progress note (EVENT-4)"; return; }
import json, re, sys
deny = re.compile(r'tool_use|tool call|token count|transcript|session_id|stop_hook|PostToolUse|PreToolUse', re.I)
for line in open(sys.argv[1]):
    if not line.strip(): continue
    e = json.loads(line)
    if e.get("event") == "task_progress" and deny.search(e.get("note", "")):
        sys.exit(1)
PY
  ok "$id" "shape valid, one-line enforced, malformed rejected, notes pass neutrality scan"
}
# --- C10 approval token semantics (APPROVAL-1, consumer side) -------------------
# Writer side (interactive approval workflow writes the token; denial writes
# nothing) is adapter/skill scope — verified in adapter mode, not testable here.
c10() {
  local id="C10-token"
  have "$GATE_CMD" || { skip "$id" "$GATE_CMD not on PATH"; return; }
  rm -f .agents/approvals/*.approved
  # a filename-derived token MUST NOT satisfy the gate — tokens key on frontmatter id
  : > ".agents/approvals/$(hostname | tr '_' '-')_999_TASK-C10.md.approved"
  if AGENTS_TASK_ID=TASK-C10 "$GATE_CMD" >/dev/null 2>&1; then
    bad "$id" "filename-derived token satisfied the gate (APPROVAL-1)"
    rm -f .agents/approvals/*.approved; return
  fi
  : > .agents/approvals/TASK-C10.approved
  AGENTS_TASK_ID=TASK-C10 "$GATE_CMD" >/dev/null 2>&1 \
    && ok "$id" "token keyed by task id, never filename" \
    || bad "$id" "id-keyed token did not satisfy the gate (APPROVAL-1)"
  rm -f .agents/approvals/*.approved
}

# --- C11 gate blocks commit (APPROVAL-2..3) --------------------------------------
c11() {
  local id="C11-gate"
  have "$GATE_CMD" || { skip "$id" "$GATE_CMD not on PATH"; return; }
  local gate_abs; gate_abs=$(command -v "$GATE_CMD")
  # APPROVAL-2: a real git pre-commit hook shelling to the gate on PATH
  printf '#!/bin/sh\nexec %s\n' "$gate_abs" > .git/hooks/pre-commit
  chmod +x .git/hooks/pre-commit
  rm -f .agents/approvals/*.approved
  git checkout -qb agent/TASK-C11
  echo c11 > c11.txt && git add c11.txt
  local commit="git -c user.email=conf@test -c user.name=conformance commit -qm c11"
  c11_cleanup() {
    git checkout -q main 2>/dev/null; git branch -qD agent/TASK-C11 2>/dev/null
    rm -f .git/hooks/pre-commit .agents/approvals/*.approved c11.txt
  }
  # branch resolves agent/TASK-C11, no token -> blocked
  if $commit >/dev/null 2>&1; then
    bad "$id" "commit allowed without approval token (APPROVAL-3)"; c11_cleanup; return
  fi
  # whitespace-only AGENTS_TASK_ID is NOT a resolution -> branch still governs -> blocked
  if AGENTS_TASK_ID='   ' $commit >/dev/null 2>&1; then
    bad "$id" "whitespace-only AGENTS_TASK_ID treated as a resolution (APPROVAL-3)"; c11_cleanup; return
  fi
  # env wins over branch: branch token present, env task has none -> blocked
  : > .agents/approvals/TASK-C11.approved
  if AGENTS_TASK_ID=TASK-C11-ENV $commit >/dev/null 2>&1; then
    bad "$id" "AGENTS_TASK_ID did not take priority over branch (APPROVAL-3)"; c11_cleanup; return
  fi
  # branch resolution + token -> allowed
  if $commit >/dev/null 2>&1; then
    ok "$id" "hook blocks without token; env-over-branch priority; whitespace env ignored"
  else
    bad "$id" "commit blocked despite approval token (APPROVAL-3)"
  fi
  c11_cleanup
}

# --- C12 gate allows humans (APPROVAL-4) -----------------------------------------
c12() {
  local id="C12-human"
  have "$GATE_CMD" || { skip "$id" "$GATE_CMD not on PATH"; return; }
  rm -f .agents/claimed/*.md .agents/approvals/*.approved
  # no task identity, nothing claimed -> allow
  env -u AGENTS_TASK_ID "$GATE_CMD" >/dev/null 2>&1 \
    || { bad "$id" "human commit blocked with no task identity (APPROVAL-4)"; return; }
  # no task identity, claimed/ non-empty -> still allow, but warn
  printf 'placeholder\n' > ".agents/claimed/otherhost_1_TASK-C12.md"
  local err rc
  err=$(env -u AGENTS_TASK_ID "$GATE_CMD" 2>&1 >/dev/null); rc=$?
  rm -f .agents/claimed/*.md
  [ $rc -eq 0 ] || { bad "$id" "human commit blocked while claimed/ non-empty (APPROVAL-4)"; return; }
  printf '%s' "$err" | grep -qi 'warn' \
    && ok "$id" "allows humans; warns when agents have claims" \
    || bad "$id" "no warning while claimed/ non-empty (APPROVAL-4)"
}

# --- C13 end-to-end lifecycle (full claim->done; ADAPTER-2; §8 in adapter mode) ----
# Adapter mode drives a harness adapter through the lifecycle via a driver
# command that translates neutral verbs into harness-specific hook firing:
#   <driver> capabilities            -> supported verbs, one per line
#   <driver> turn-end <dir>          -> simulate the harness's turn-end hook
#   <driver> session-end <dir> <sid> -> simulate harness session shutdown
# Conformance asserts bus effects only; how the driver fires its harness is
# the adapter's business. session-end is optional (SPEC §8: "when the
# harness supports exit hooks").
c13_adapter() {
  local id="C13-e2e"
  have "$CLAIM_CMD" || { skip "$id" "$CLAIM_CMD not on PATH"; return; }
  have "$COMPLETE_CMD" || { skip "$id" "$COMPLETE_CMD not on PATH"; return; }
  # Hard requirement in adapter mode: without python3 the parse and EVENT-4
  # checks would silently vanish, letting a malformed-but-grep-matching
  # emitter pass the whole drive.
  have python3 || { bad "$id" "python3 required for adapter-mode C13"; return; }
  rm -f .agents/inbox/*.md .agents/claimed/*.md
  make_packet TASK-C13A
  local out path caps
  out=$("$CLAIM_CMD" 2>/dev/null) || { bad "$id" "claim failed"; return; }
  path=${out%%$'\n'*}; path=${path#claimed:}
  # agent does some work, then the harness turn ends — twice, unchanged
  echo work > c13a-work.txt
  AGENTS_TASK_ID=TASK-C13A "$ADAPTER_CMD" turn-end "$FIXTURE" \
    || { bad "$id" "driver turn-end failed"; return; }
  AGENTS_TASK_ID=TASK-C13A "$ADAPTER_CMD" turn-end "$FIXTURE" \
    || { bad "$id" "driver turn-end (repeat) failed"; return; }
  grep '"task_progress"' .agents/events.jsonl 2>/dev/null | grep -q '"TASK-C13A"' \
    || { bad "$id" "no task_progress projected after turn-end (SPEC §8)"; return; }
  # work state changes -> the next turn end must eventually project it
  echo more > c13a-work2.txt
  AGENTS_TASK_ID=TASK-C13A "$ADAPTER_CMD" turn-end "$FIXTURE" \
    || { bad "$id" "driver turn-end (after change) failed"; return; }
  [ "$(grep '"task_progress"' .agents/events.jsonl | grep -c '"TASK-C13A"')" -ge 2 ] \
    || { bad "$id" "changed work state not projected as a new milestone (SPEC §8)"; return; }
  # EVENT-4 heuristic: adapter-produced notes carry no harness vocabulary
  if have python3; then
    python3 - <<'PY' .agents/events.jsonl || { bad "$id" "harness vocabulary in adapter note (EVENT-4)"; return; }
import json, re, sys
deny = re.compile(r'tool_use|tool call|token count|transcript|session_id|stop_hook|PostToolUse|PreToolUse', re.I)
for line in open(sys.argv[1]):
    if not line.strip(): continue
    e = json.loads(line)
    if e.get("event") == "task_progress" and e.get("task") == "TASK-C13A" \
       and deny.search(e.get("note", "")):
        sys.exit(1)
PY
  fi
  "$COMPLETE_CMD" "$path" >/dev/null || { bad "$id" "complete failed"; return; }
  ls .agents/done/*_TASK-C13A.md >/dev/null 2>&1 || { bad "$id" "packet did not land in done/"; return; }
  # session_end, where the harness has exit hooks
  local note="adapter lifecycle: claim->progress->complete"
  caps=$("$ADAPTER_CMD" capabilities 2>/dev/null) || caps=""
  case "$caps" in
    *session-end*)
      "$ADAPTER_CMD" session-end "$FIXTURE" ses-c13 \
        || { bad "$id" "driver session-end failed"; return; }
      grep '"session_end"' .agents/events.jsonl 2>/dev/null | grep -q '"ses-c13"' \
        || { bad "$id" "no session_end for ses-c13 (SPEC §8)"; return; }
      note="$note->session_end" ;;
    *) note="$note (session-end not supported by harness)" ;;
  esac
  c13_shared_asserts "$id" "$note"
}

# log parses + ADAPTER-2 dir scan — shared by both C13 modes
c13_shared_asserts() { # c13_shared_asserts <id> <ok-note>
  local id=$1 note=$2
  if have python3; then
    python3 - <<'PY' .agents/events.jsonl || { bad "$id" "event log unparseable after lifecycle"; return; }
import json, sys
for line in open(sys.argv[1]):
    if line.strip(): json.loads(line)
PY
  fi
  # ADAPTER-2: nothing harness-private under .agents/ — only the SPEC §2 entries
  local f b
  for f in .agents/* .agents/.[!.]*; do
    [ -e "$f" ] || continue
    b=$(basename "$f")
    case "$b" in
      inbox|claimed|done|approvals|council|events.jsonl|registry.json) ;;
      *) bad "$id" "unexpected entry under .agents/: $b (ADAPTER-2)"; return ;;
    esac
  done
  # ...and nothing smuggled INSIDE the spec'd directories: no subdirectories,
  # and every nested file must match its directory's content type.
  local viol
  viol=$(find .agents -mindepth 2 -type d 2>/dev/null | head -1)
  [ -n "$viol" ] && { bad "$id" "unexpected directory under .agents/: $viol (ADAPTER-2)"; return; }
  viol=$(find .agents -mindepth 2 -type f 2>/dev/null | while read -r p; do
    case "$p" in
      .agents/inbox/*.md|.agents/claimed/*.md|.agents/done/*.md) ;;
      .agents/approvals/*.approved|.agents/council/*.json) ;;
      *) printf '%s\n' "$p" ;;
    esac
  done | head -1)
  [ -n "$viol" ] && { bad "$id" "unexpected file under .agents/: $viol (ADAPTER-2)"; return; }
  ok "$id" "$note"
}

c13() {
  local id="C13-e2e"
  if [ -n "$ADAPTER_CMD" ]; then
    c13_adapter
    return
  fi
  have "$CLAIM_CMD" || { skip "$id" "$CLAIM_CMD not on PATH"; return; }
  have "$COMPLETE_CMD" || { skip "$id" "$COMPLETE_CMD not on PATH"; return; }
  rm -f .agents/inbox/*.md .agents/claimed/*.md
  make_packet TASK-C13
  local out path
  out=$("$CLAIM_CMD" 2>/dev/null) || { bad "$id" "claim failed"; return; }
  path=${out%%$'\n'*}; path=${path#claimed:}
  "$COMPLETE_CMD" "$path" >/dev/null || { bad "$id" "complete failed"; return; }
  ls .agents/claimed/*.md >/dev/null 2>&1 && { bad "$id" "packet left behind in claimed/"; return; }
  ls .agents/done/*_TASK-C13.md >/dev/null 2>&1 || { bad "$id" "packet did not land in done/"; return; }
  c13_shared_asserts "$id" "inbox->claimed->done, parseable log, no harness-private files"
}

# --- C14 log integrity (EVENT-1; EVENT-3 reader side) ------------------------------
c14() {
  local id="C14-integrity"
  have "$CLAIM_CMD" || { skip "$id" "$CLAIM_CMD not on PATH"; return; }
  have "$COMPLETE_CMD" || { skip "$id" "$COMPLETE_CMD not on PATH"; return; }
  [ -f .agents/events.jsonl ] || { skip "$id" "no events.jsonl produced yet"; return; }
  # (a) EVENT-1: a lifecycle only appends — prior bytes stay identical
  cp .agents/events.jsonl c14.snapshot
  rm -f .agents/inbox/*.md
  make_packet TASK-C14A
  local out path
  out=$("$CLAIM_CMD" 2>/dev/null); path=${out%%$'\n'*}; path=${path#claimed:}
  "$COMPLETE_CMD" "$path" >/dev/null 2>&1
  head -c "$(wc -c < c14.snapshot | tr -d ' ')" .agents/events.jsonl | cmp -s - c14.snapshot \
    || { bad "$id" "prior log bytes changed after lifecycle (EVENT-1)"; rm -f c14.snapshot; return; }
  rm -f c14.snapshot
  # (b) EVENT-3 reader side: tools must keep operating with a foreign/unknown
  # event type in the log. (A true reader check lands with `index` in v0.2.)
  printf '{"ts":"2026-01-01T00:00:00Z","event":"x_vendor_extension","note":"injected by conformance"}\n' \
    >> .agents/events.jsonl
  make_packet TASK-C14B
  out=$("$CLAIM_CMD" 2>/dev/null) || { bad "$id" "claim broke on unknown event type (EVENT-3)"; return; }
  path=${out%%$'\n'*}; path=${path#claimed:}
  "$COMPLETE_CMD" "$path" >/dev/null 2>&1 \
    && ok "$id" "append-only verified; tools tolerate unknown event types" \
    || bad "$id" "complete broke on unknown event type (EVENT-3)"
}

c15() { # COUNCIL-1..5, 9..11: happy path, file shape, event
  local id="C15-council-happy"
  have "$COUNCIL_CMD" || { skip "$id" "$COUNCIL_CMD not on PATH"; return; }
  have python3 || { skip "$id" "python3 unavailable"; return; }
  local d p out rc f; d=$(council_stubs); p=$(council_packet TASK-C15)
  out=$(COUNCIL_EVALUATOR_CMD="$d/pass" "$COUNCIL_CMD" "$p"); rc=$?
  [ $rc -eq 0 ] || { bad "$id" "exit $rc on happy path (COUNCIL-1)"; return; }
  [ "$out" = "council:TASK-C15:PASS" ] || { bad "$id" "stdout '$out' (§12.1)"; return; }
  f=".agents/council/TASK-C15.json"
  [ -f "$f" ] || { bad "$id" "no verdict file (COUNCIL-9)"; return; }
  python3 - "$f" <<'PY' || { bad "$id" "verdict file shape (COUNCIL-10)"; return; }
import json,sys
d=json.load(open(sys.argv[1]))
assert set(d)=={"task","verdict","ts","votes"}, d.keys()              # exactly these fields (decision-4 fence)
assert d["task"]=="TASK-C15" and d["verdict"]=="PASS"
assert len(d["votes"])==3
assert {v["dimension"] for v in d["votes"]}=={"acceptance-criteria","code-quality","style"}
assert all(set(v)=={"dimension","vote","reason"} and v["vote"]=="PASS" for v in d["votes"])
PY
  # COUNCIL-7: no leftover prompt temp dirs from this run
  grep '"event":"council_verdict"' .agents/events.jsonl | grep '"TASK-C15"' | grep -q '"evaluator_count":3' \
    && ok "$id" "3 PASS -> PASS; {task,verdict,ts,votes} shape; council_verdict event" \
    || bad "$id" "missing/!=3-evaluator council_verdict event for TASK-C15 (COUNCIL-11)"
}

c16() { # COUNCIL-8: majority math
  local id="C16-council-majority"
  have "$COUNCIL_CMD" || { skip "$id" "$COUNCIL_CMD not on PATH"; return; }
  local d; d=$(council_stubs)
  [ "$(COUNCIL_EVALUATOR_CMD="$d/2p1f" "$COUNCIL_CMD" "$(council_packet TASK-C16A)")" = "council:TASK-C16A:PASS" ] \
    || { bad "$id" "2-1 must be PASS (COUNCIL-8)"; return; }
  [ "$(COUNCIL_EVALUATOR_CMD="$d/1p2f" "$COUNCIL_CMD" "$(council_packet TASK-C16B)")" = "council:TASK-C16B:FAIL" ] \
    || { bad "$id" "1-2 must be FAIL (COUNCIL-8)"; return; }
  [ "$(COUNCIL_EVALUATOR_CMD="$d/fail" "$COUNCIL_CMD" "$(council_packet TASK-C16C)")" = "council:TASK-C16C:FAIL" ] \
    && ok "$id" "2-1 PASS; 1-2 FAIL; 0-3 FAIL (COUNCIL-8)" \
    || bad "$id" "0-3 must be FAIL (COUNCIL-8)"
}

c17() { # COUNCIL-6, 8: abstentions are fail-safe
  local id="C17-council-abstain"
  have "$COUNCIL_CMD" || { skip "$id" "$COUNCIL_CMD not on PATH"; return; }
  local d p out n; d=$(council_stubs)
  for st in crash silent; do
    p=$(council_packet "TASK-C17-$st")
    out=$(COUNCIL_EVALUATOR_CMD="$d/$st" "$COUNCIL_CMD" "$p") || { bad "$id" "$st run errored"; return; }
    [ "$out" = "council:TASK-C17-$st:FAIL" ] || { bad "$id" "$st must FAIL via ABSTAIN (COUNCIL-6/8)"; return; }
    n=$(grep -o '"vote":"ABSTAIN"' ".agents/council/TASK-C17-$st.json" | wc -l | tr -d ' ')
    [ "$n" = "3" ] || { bad "$id" "$st: expected 3 ABSTAIN votes, got $n (COUNCIL-6)"; return; }
    grep '"TASK-C17-'"$st"'"' .agents/events.jsonl | grep -q '"abstentions":3' \
      || { bad "$id" "$st: event must report abstentions:3 (COUNCIL-11)"; return; }
  done
  ok "$id" "crash + silent evaluators -> 3 ABSTAIN -> FAIL; abstentions:3 in event"
}

c18() { # COUNCIL-9: idempotent re-run overwrites; events append
  local id="C18-council-overwrite"
  have "$COUNCIL_CMD" || { skip "$id" "$COUNCIL_CMD not on PATH"; return; }
  local d p f n; d=$(council_stubs); p=$(council_packet TASK-C18); f=".agents/council/TASK-C18.json"
  COUNCIL_EVALUATOR_CMD="$d/pass" "$COUNCIL_CMD" "$p" >/dev/null || { bad "$id" "first run failed"; return; }
  grep -q '"verdict":"PASS"' "$f" || { bad "$id" "first run not PASS"; return; }
  COUNCIL_EVALUATOR_CMD="$d/fail" "$COUNCIL_CMD" "$p" >/dev/null || { bad "$id" "second run failed"; return; }
  grep -q '"verdict":"FAIL"' "$f" && ! grep -q '"verdict":"PASS"' "$f" \
    || { bad "$id" "verdict file not overwritten to FAIL (COUNCIL-9)"; return; }
  n=$(grep '"event":"council_verdict"' .agents/events.jsonl | grep -c '"TASK-C18"')
  [ "$n" -eq 2 ] \
    && ok "$id" "re-run overwrites verdict; two council_verdict events (COUNCIL-9, EVENT-1)" \
    || bad "$id" "expected 2 council_verdict events for TASK-C18, got $n"
}

c19() { # COUNCIL-2, 3: CWD-independent; verdict + event land in the bus, not cwd
  local id="C19-council-bus-resolution"
  have "$COUNCIL_CMD" || { skip "$id" "$COUNCIL_CMD not on PATH"; return; }
  local d p abs elsewhere out; d=$(council_stubs); p=$(council_packet TASK-C19)
  abs="$FIXTURE/$p"; elsewhere=$(mktemp -d "${TMPDIR:-/tmp}/council-cwd.XXXXXX")
  out=$(cd "$elsewhere" && COUNCIL_EVALUATOR_CMD="$d/pass" "$COUNCIL_CMD" "$abs"); local rc=$?
  rm -rf "$elsewhere"
  [ $rc -eq 0 ] && [ "$out" = "council:TASK-C19:PASS" ] || { bad "$id" "rc=$rc out='$out' from foreign cwd (COUNCIL-2)"; return; }
  [ -f "$FIXTURE/.agents/council/TASK-C19.json" ] || { bad "$id" "verdict not written to the bus (COUNCIL-2)"; return; }
  grep '"TASK-C19"' "$FIXTURE/.agents/events.jsonl" | grep -q '"event":"council_verdict"' \
    && ok "$id" "resolves bus from packet path, not CWD; verdict + event land in main checkout" \
    || bad "$id" "council_verdict event not in the bus log (COUNCIL-2)"
}

c20() { # COUNCIL-2: harness-independent — the seam means the harness is never invoked
  local id="C20-council-harness-independence"
  have "$COUNCIL_CMD" || { skip "$id" "$COUNCIL_CMD not on PATH"; return; }
  local d p out pd; d=$(council_stubs); p=$(council_packet TASK-C20)
  # A poisoned `claude` that records if it is ever executed. With the evaluator
  # seam set, council MUST NOT fall back to the built-in harness evaluator.
  pd="$FIXTURE/poison"; mkdir -p "$pd"
  printf '#!/usr/bin/env bash\ntouch "%s/claude-was-called"\necho "VOTE: PASS"\n' "$FIXTURE" > "$pd/claude"
  chmod +x "$pd/claude"; rm -f "$FIXTURE/claude-was-called"
  out=$(PATH="$pd:$PATH" COUNCIL_EVALUATOR_CMD="$d/pass" "$COUNCIL_CMD" "$p"); local rc=$?
  [ $rc -eq 0 ] && [ "$out" = "council:TASK-C20:PASS" ] || { bad "$id" "rc=$rc out='$out'"; return; }
  [ ! -f "$FIXTURE/claude-was-called" ] \
    && ok "$id" "verdict produced via the seam; harness never invoked (COUNCIL-2)" \
    || bad "$id" "council invoked the harness despite COUNCIL_EVALUATOR_CMD (COUNCIL-2)"
}

c21() { # INDEX-1..4: fold two buses; project state, owner, verdict, last_note
  local id="C21-index-fold"
  have "$INDEX_CMD" || { skip "$id" "$INDEX_CMD not on PATH"; return; }
  have python3 || { skip "$id" "python3 unavailable"; return; }
  local A="$IDX/repoA" B="$IDX/repoB" out rc
  mkdir -p "$A" "$B"; index_make "$A"; index_make "$B"
  out=$(AGENTS_INDEX_FILE="$IDX/index.json" "$INDEX_CMD" refresh "$A" "$B"); rc=$?
  [ $rc -eq 0 ] || { bad "$id" "index exited $rc on the happy path (INDEX-1)"; return; }
  [ "$out" = "index:$IDX/index.json" ] || { bad "$id" "stdout '$out', expected index:$IDX/index.json (INDEX-2)"; return; }
  python3 - "$IDX/index.json" <<'PY' || { bad "$id" "projected task fields wrong (INDEX-4)"; return; }
import json,sys
d=json.load(open(sys.argv[1]))
t={(x["repo"],x["id"]):x for x in d["tasks"]}
assert len(d["tasks"])==6, len(d["tasks"])               # 3 states x 2 repos
for repo in ("repoA","repoB"):
    inb=t[(repo,"IX-IN")]; cl=t[(repo,"IX-CL")]; dn=t[(repo,"IX-DN")]
    assert inb["state"]=="inbox" and inb["owner"] is None and inb["verdict"] is None
    assert cl["state"]=="claimed" and cl["owner"]=="box_77" and cl["last_note"]=="halfway"
    assert dn["state"]=="done"  and dn["owner"]=="box_88" and dn["verdict"]=="PASS"
PY
  ok "$id" "two buses folded; state/owner/verdict/last_note projected (INDEX-1..4)"
}

c22() { # INDEX-5 (decision-4 fence): derived cache never lands in a repo bus; shape is exactly the projection
  local id="C22-index-derived"
  have "$INDEX_CMD" || { skip "$id" "$INDEX_CMD not on PATH"; return; }
  have python3 || { skip "$id" "python3 unavailable"; return; }
  local A="$IDX/d-repoA" B="$IDX/d-repoB" r
  mkdir -p "$A" "$B"; index_make "$A"; index_make "$B"
  AGENTS_INDEX_FILE="$IDX/d-index.json" "$INDEX_CMD" refresh "$A" "$B" >/dev/null \
    || { bad "$id" "index failed"; return; }
  for r in "$A" "$B"; do
    [ -e "$r/.agents/index.json" ] && { bad "$id" "derived cache written into $r/.agents (§9 derived-only)"; return; }
  done
  python3 - "$IDX/d-index.json" <<'PY' || { bad "$id" "task object carries non-projection fields (decision-4 fence)"; return; }
import json,sys
d=json.load(open(sys.argv[1]))
keys={"repo","id","state","owner","verdict","last_event_ts","last_note"}
for x in d["tasks"]:
    assert set(x)==keys, set(x)
PY
  ok "$id" "no cache inside repo buses; task fields are exactly the bus projection (INDEX-5)"
}

c23() { # INDEX-6: one unreadable repo is recorded, never fatal; good repos still fold
  local id="C23-index-badrepo"
  have "$INDEX_CMD" || { skip "$id" "$INDEX_CMD not on PATH"; return; }
  have python3 || { skip "$id" "python3 unavailable"; return; }
  local G="$IDX/b-good" ghost="$IDX/b-ghost-absent" out rc
  mkdir -p "$G"; index_make "$G"
  out=$(AGENTS_INDEX_FILE="$IDX/b-index.json" "$INDEX_CMD" refresh "$ghost" "$G"); rc=$?
  [ $rc -eq 0 ] || { bad "$id" "one bad repo failed the whole run (rc=$rc) (INDEX-6)"; return; }
  python3 - "$IDX/b-index.json" "$ghost" "$G" <<'PY' || { bad "$id" "bad/good repo handling wrong (INDEX-6)"; return; }
import json,sys
d=json.load(open(sys.argv[1])); ghost,good=sys.argv[2],sys.argv[3]
r={x["path"]:x for x in d["repos"]}
assert r[ghost]["ok"] is False and "error" in r[ghost]            # ghost recorded, not fatal
assert r[good]["ok"] is True                                       # good repo still scanned
assert {x["id"] for x in d["tasks"]}=={"IX-IN","IX-CL","IX-DN"}     # only the good repo's tasks
PY
  ok "$id" "ghost repo -> ok:false+error, exit 0; good repo still folded (INDEX-6)"
}

c24() { # INDEX-7: creates a missing output dir; atomic (no tmp residue); provenance; idempotent
  local id="C24-index-atomic"
  have "$INDEX_CMD" || { skip "$id" "$INDEX_CMD not on PATH"; return; }
  have python3 || { skip "$id" "python3 unavailable"; return; }
  local A="$IDX/a-repo" dst="$IDX/fresh/sub/index.json" first second
  mkdir -p "$A"; index_make "$A"
  AGENTS_INDEX_FILE="$dst" "$INDEX_CMD" refresh "$A" >/dev/null \
    || { bad "$id" "index could not create the missing output dir (INDEX-7)"; return; }
  [ -f "$dst" ] || { bad "$id" "output not written into a freshly-created dir (INDEX-7)"; return; }
  ls "$IDX/fresh/sub/".index.*.tmp >/dev/null 2>&1 \
    && { bad "$id" "temp file left beside output (write not atomic) (INDEX-7)"; return; }
  python3 - "$dst" <<'PY' || { bad "$id" "provenance fields missing (INDEX-7)"; return; }
import json,sys
d=json.load(open(sys.argv[1]))
assert d["generated_at"] and d["tool"].startswith("index/")
assert d["repos"] and d["repos"][0]["scanned_at"]
assert d["repos"][0]["events_mtime"]              # this bus has an events.jsonl
PY
  first=$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(sorted((x["repo"],x["id"],x["state"]) for x in d["tasks"]))' "$dst")
  AGENTS_INDEX_FILE="$dst" "$INDEX_CMD" refresh "$A" >/dev/null || { bad "$id" "second run failed (INDEX-7)"; return; }
  second=$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(sorted((x["repo"],x["id"],x["state"]) for x in d["tasks"]))' "$dst")
  [ "$first" = "$second" ] \
    && ok "$id" "creates missing dir; atomic (no tmp residue); provenance present; idempotent (INDEX-7)" \
    || bad "$id" "second run diverged from first (INDEX-7)"
}

# --- run -----------------------------------------------------------------------
c01; c02; c03; c04; c05; c06; c07; c08; c09; c10; c11; c12; c13; c14
c15; c16; c17; c18; c19; c20
c21; c22; c23; c24
printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
# All 24 cases are live (0 stubs). A skip means a tool was missing from PATH or a
# prerequisite failed — a misconfigured run, not a pass. Fail closed so a fully
# skipped run can never report green (0 passed / 0 failed must not exit 0).
[ "$FAIL" -eq 0 ] && [ "$SKIP" -eq 0 ] && [ "$PASS" -gt 0 ] || exit 1
