#!/usr/bin/env bash
# stop-hook.sh — Claude Code adapter: project a task_progress milestone onto
# the .agents/ bus at the end of each agent turn.
#
# Contract: SPEC v0.1 §8 (adapter obligations), §6 (EVENT-4 neutrality).
# Translation layer only: derives a harness-neutral note from git state and
# shells to `progress` on PATH (or $PROGRESS_CMD). Harness payload (session
# ids, transcript paths) never reaches the bus.
#
# Install (Claude Code settings.json):
#   "hooks": { "Stop": [ { "hooks": [ { "type": "command",
#     "command": "/path/to/adapters/claude-code/stop-hook.sh" } ] } ] }
#
# A Stop hook must never disrupt the harness: every exit path is 0;
# diagnostics go to stderr only.
set -u
PROGRESS_CMD=${PROGRESS_CMD:-progress}

# Claude Code sends the hook payload on stdin; only cwd is consumed — it
# anchors git resolution when the hook process starts elsewhere.
cwd=$(python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("cwd",""))
except Exception: pass' 2>/dev/null)
[ -n "$cwd" ] && [ -d "$cwd" ] && cd "$cwd" || true

git rev-parse --git-common-dir >/dev/null 2>&1 || exit 0   # not a repo: nothing to project

# Task identity, mirroring APPROVAL-3 order: (1) $AGENTS_TASK_ID if it has
# any non-whitespace; (2) branch exactly agent/<task-id>.
task=""
if [ -n "${AGENTS_TASK_ID:-}" ]; then
  stripped=$(printf '%s' "$AGENTS_TASK_ID" | tr -d '[:space:]')
  [ -n "$stripped" ] && task=$AGENTS_TASK_ID
fi
if [ -z "$task" ]; then
  branch=$(git symbolic-ref --short -q HEAD || true)
  case "$branch" in
    agent/?*) task=${branch#agent/} ;;
  esac
fi
[ -n "$task" ] || exit 0   # no task identity: human or non-bus session

# Neutral milestone from git state only (EVENT-4): uncommitted file count
# plus commits made on this task branch since it left the default branch.
# .agents/ is excluded — bus state (event log, approvals) is not task work,
# and counting it lets the adapter's own emit defeat the dedupe below.
top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
changed=$(git -C "$top" status --porcelain -- ':!.agents' 2>/dev/null | wc -l | tr -d ' ')
default=$(git symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null) && default=${default#origin/}
commits=$(git rev-list --count "${default:-main}..HEAD" 2>/dev/null || echo 0)
note="checkpoint: ${commits} commits on task branch, ${changed} files uncommitted"

# Dedupe: an unchanged note is not a new milestone — skip the emit.
main=$(dirname "$(git rev-parse --git-common-dir)")
log="$main/.agents/events.jsonl"
if [ -f "$log" ]; then
  last=$(grep '"task_progress"' "$log" | python3 -c 'import json,sys
last = ""
for line in sys.stdin:
    e = json.loads(line)
    if e.get("task") == sys.argv[1]: last = e.get("note","")
print(last)' "$task" 2>/dev/null)
  [ "$last" = "$note" ] && exit 0
fi

"$PROGRESS_CMD" "$task" "$note" \
  || printf 'stop-hook: progress emit failed for %s\n' "$task" >&2
exit 0
