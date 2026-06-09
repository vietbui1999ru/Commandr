#!/usr/bin/env bash
# stop-hook.sh — Claude Code adapter shim: turn-end → bus checkpoint.
#
# Transport only. Claude Code sends the Stop hook payload on stdin; the one
# field that may cross to the bus side is cwd — it anchors git resolution.
# Session ids and transcript paths never leave this file (EVENT-4).
# Milestone logic lives in adapters/lib/checkpoint.sh.
#
# Install (Claude Code settings.json):
#   "hooks": { "Stop": [ { "hooks": [ { "type": "command",
#     "command": "/path/to/adapters/claude-code/stop-hook.sh" } ] } ] }
#
# A Stop hook must never disrupt the harness: every exit path is 0;
# diagnostics go to stderr only.
set -u

cwd=$(python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("cwd",""))
except Exception: pass' 2>/dev/null)
[ -n "$cwd" ] || cwd=$PWD

"$(dirname "$0")/../lib/checkpoint.sh" "$cwd" \
  || printf 'stop-hook: checkpoint emit failed for %s\n' "$cwd" >&2
exit 0
