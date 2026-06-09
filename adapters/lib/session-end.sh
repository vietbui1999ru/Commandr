#!/usr/bin/env bash
# session-end.sh — shared adapter core: append a session_end event to the
# bus for the repo at <dir> (SPEC v0.1 §8: adapters emit session_end at
# shutdown when the harness supports exit hooks).
#
#   usage:  session-end.sh <dir> <session-id>
#   exit:   0 — emitted or nothing to project (not a repo / no bus);
#           non-zero on validation or filesystem failure.
#
# The session id is the one harness field SPEC sanctions on the bus — it is
# the session_end event's key. files_changed mirrors the checkpoint note's
# count (working tree, .agents/ excluded).
set -u

dir=${1:-}
session=${2:-}
[ -n "$dir" ] && [ -d "$dir" ] && cd "$dir" || exit 0
[ -n "$session" ] || { printf 'session-end: missing session id\n' >&2; exit 2; }
# Whitespace case covers embedded newlines too — grep alone can't see them
# (line-oriented), and an id should carry no whitespace at all.
case "$session" in
  *[[:space:]]*) printf 'session-end: whitespace in session id\n' >&2; exit 2 ;;
esac
printf '%s' "$session" | LC_ALL=C grep -q '[[:cntrl:]]' \
  && { printf 'session-end: control character in session id\n' >&2; exit 2; }

git rev-parse --git-common-dir >/dev/null 2>&1 || exit 0
main=$(dirname "$(git rev-parse --git-common-dir)")
main=$(cd "$main" && pwd -P) || exit 0
bus="$main/.agents"
[ -d "$bus" ] || exit 0   # repo without a bus: nothing to record

top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
status=$(git -C "$top" status --porcelain -- ':!.agents' 2>/dev/null) || status=""
changed=$(printf '%s' "$status" | grep -c .) || true

# Escape caller-supplied content before interpolation (EVENT-2).
esc=${session//\\/\\\\}
esc=${esc//\"/\\\"}

host=$(hostname | tr '_' '-')
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '{"ts":"%s","event":"session_end","session":"%s","files_changed":%s,"machine":"%s"}\n' \
  "$ts" "$esc" "$changed" "$host" >> "$bus/events.jsonl"
