#!/usr/bin/env bash
# conformance.sh — the one conformance test for the .agents/ bus (SPEC v0.1).
# Definition of done for the bus tools and for every harness adapter.
#
# Modes:
#   ./conformance.sh                  # test bus tools (claim/complete on PATH or via env)
#   ./conformance.sh --adapter <cmd>  # drive a harness adapter through C03-C13 (TODO)
#
# Env overrides: CLAIM_CMD (default: claim), COMPLETE_CMD (default: complete),
#                GATE_CMD (default: pre-commit-gate)
set -u

CLAIM_CMD=${CLAIM_CMD:-claim}
COMPLETE_CMD=${COMPLETE_CMD:-complete}
GATE_CMD=${GATE_CMD:-pre-commit-gate}
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
trap 'rm -rf "$FIXTURE" "$FIXTURE-wt"' EXIT
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

# --- TODO stubs ---------------------------------------------------------------
c02() { skip "C02-packet"   "TODO: (a) packet missing id/type/scope must not be claimable (PACKET-1); (b) packet with unknown frontmatter field must still claim (PACKET-2); (c) packet missing required body sections flagged (PACKET-3)"; }
c06() { skip "C06-claimevt" "TODO: task_claimed event exists after claim, before work (CLAIM-4)"; }
c07() { skip "C07-complete" "TODO: complete moves to done/, prints done:<path>, exit 0; missing path exits non-zero AND produces no stdout (COMPLETE-1..2)"; }
c09() { skip "C09-neutral"  "TODO: task_progress notes are harness-neutral (EVENT-4) — heuristic check"; }
c10() { skip "C10-token"    "TODO: approval writes <task-id>.approved from frontmatter id; denial writes nothing (APPROVAL-1)"; }
c11() { skip "C11-gate"     "TODO: pre-commit gate blocks commit without token; non-empty AGENTS_TASK_ID then exact-branch resolution (APPROVAL-2..3)"; }
c12() { skip "C12-human"    "TODO: gate allows commit when no task identity resolves, warns when claimed/ non-empty (APPROVAL-4)"; }
c13() { skip "C13-e2e"      "TODO: drive \${ADAPTER_CMD:-bus tools} through full lifecycle inbox->claimed->done with parseable log; assert no harness-private files under .agents/ (ADAPTER-2)"; }
c14() { skip "C14-integrity" "TODO: (a) snapshot log, run lifecycle, verify prior lines byte-identical (EVENT-1); (b) inject unknown-event line, verify readers tolerate it (EVENT-3 reader side)"; }

# --- run -----------------------------------------------------------------------
c01; c02; c03; c04; c05; c06; c07; c08; c09; c10; c11; c12; c13; c14
printf '\n%d passed, %d failed, %d skipped (stubs)\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
