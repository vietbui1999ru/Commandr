#!/usr/bin/env bash
# conformance-driver.sh — drive the Claude Code adapter shims for the
# conformance harness (protocol/conformance.sh --adapter <this file>).
#
# Translates the harness-neutral driver verbs into what Claude Code itself
# would do: pipe the hook payload JSON into the real shims on stdin. The
# shims under test are the production files, untouched. Payloads carry the
# full field set Claude Code sends (not just what today's shims read), and
# are built with json.dumps so a cwd with quotes or backslashes survives.
set -u
here=$(cd "$(dirname "$0")" && pwd -P)

payload() { # payload <hook-event> <dir> [session-id] [reason]
  python3 -c 'import json,sys
print(json.dumps({
  "hook_event_name": sys.argv[1],
  "cwd": sys.argv[2],
  "session_id": sys.argv[3],
  "reason": sys.argv[4],
  "transcript_path": "/dev/null",
  "permission_mode": "allow",
}))' "$@"
}

case "${1:-}" in
  capabilities)
    printf 'turn-end\nsession-end\n' ;;
  turn-end)
    payload Stop "${2:?turn-end requires <dir>}" ses_driver turn-end \
      | "$here/stop-hook.sh" ;;
  session-end)
    payload SessionEnd "${2:?session-end requires <dir>}" "${3:?session-end requires <sid>}" exit \
      | "$here/session-end-hook.sh" ;;
  *)
    printf 'usage: conformance-driver.sh capabilities|turn-end <dir>|session-end <dir> <sid>\n' >&2
    exit 2 ;;
esac
