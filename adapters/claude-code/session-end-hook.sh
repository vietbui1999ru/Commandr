#!/usr/bin/env bash
# session-end-hook.sh — Claude Code adapter shim: session shutdown →
# session_end on the bus (SPEC v0.1 §8). Pairs with stop-hook.sh, which
# handles per-turn checkpoints; this fires once, on the SessionEnd hook.
#
# Transport only: extracts cwd and session_id from the hook payload and
# calls adapters/lib/session-end.sh. The session id is the one harness
# field SPEC sanctions on the bus (it keys the session_end event).
#
# Install (Claude Code settings.json):
#   "hooks": { "SessionEnd": [ { "hooks": [ { "type": "command",
#     "command": "/path/to/adapters/claude-code/session-end-hook.sh" } ] } ] }
#
# Exit-path hooks must never disrupt the harness: every exit path is 0.
set -u

# One line per field — a cwd containing spaces must survive the split.
payload=$(python3 -c 'import json,sys
try:
  p = json.load(sys.stdin)
  print(p.get("cwd",""))
  print(p.get("session_id",""))
except Exception: pass' 2>/dev/null)
cwd=$(printf '%s\n' "$payload" | sed -n 1p)
session=$(printf '%s\n' "$payload" | sed -n 2p)
[ -n "$cwd" ] || cwd=$PWD
[ -n "$session" ] || exit 0   # no session id: nothing meaningful to record

"$(dirname "$0")/../lib/session-end.sh" "$cwd" "$session" \
  || printf 'session-end-hook: emit failed for %s\n' "$cwd" >&2
exit 0
