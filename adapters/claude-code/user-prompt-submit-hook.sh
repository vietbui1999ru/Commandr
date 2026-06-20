#!/usr/bin/env bash
# user-prompt-submit-hook.sh — Claude Code adapter shim: UserPromptSubmit →
# annotation inject.
#
# Transport only. Claude Code sends the UserPromptSubmit payload on stdin; the
# hook emits the payload on stdout with pending annotation bodies prepended to
# the `prompt` field. cwd anchors git resolution. Pickup logic lives in
# adapters/lib/annotate.sh.
#
# Install (Claude Code settings.json):
#   "hooks": { "UserPromptSubmit": [ { "hooks": [ { "type": "command",
#     "command": "/path/to/adapters/claude-code/user-prompt-submit-hook.sh" } ] } ] }
#
# A UserPromptSubmit hook must never disrupt the harness: every exit path is 0;
# diagnostics go to stderr only. Annotation injection is best-effort — on any
# failure the original payload is emitted unchanged (fail-open: never a gate).
set -u

payload=$(cat)
cwd=$(printf '%s' "$payload" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("cwd",""))
except Exception: pass' 2>/dev/null)
[ -n "$cwd" ] || cwd=$PWD

if out=$(printf '%s' "$payload" | "$(dirname "$0")/../lib/annotate.sh" "$cwd"); then
  [ -n "$out" ] && printf '%s' "$out" || printf '%s' "$payload"
else
  printf 'user-prompt-submit-hook: inject failed for %s\n' "$cwd" >&2
  printf '%s' "$payload"
fi
exit 0
