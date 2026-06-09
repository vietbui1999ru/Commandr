#!/usr/bin/env bash
# checkpoint.sh — shared adapter core: project one harness-neutral
# task_progress milestone onto the .agents/ bus for the repo at <dir>.
#
# Contract: SPEC v0.1 §8 (adapter obligations), §6 (EVENT-4 neutrality).
#   usage:  checkpoint.sh <dir>
#   exit:   0 — emitted, deduped, or nothing to project (not a repo / no
#               task identity); non-zero only on a real emit failure.
#
# Harness shims (claude-code/, opencode/) own transport: they extract the
# working directory from their harness's payload and call this core. No
# harness payload field other than the directory may cross this boundary.
set -u
PROGRESS_CMD=${PROGRESS_CMD:-progress}

# A missing emitter would otherwise fail silently behind the fail-open shims,
# turn after turn; make it loud and let the shims report it.
command -v "$PROGRESS_CMD" >/dev/null 2>&1 || {
  printf 'checkpoint: PROGRESS_CMD not found: %s — is Commandr bin/ on PATH?\n' "$PROGRESS_CMD" >&2
  exit 1; }

dir=${1:-}
[ -n "$dir" ] && [ -d "$dir" ] && cd "$dir" || exit 0
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
# Capture-then-count: a piped `git status | wc -l` would mask a git failure
# (index.lock contention) as a false "0 files uncommitted" in the log.
status=$(git -C "$top" status --porcelain -- ':!.agents' 2>/dev/null) || exit 0
changed=$(printf '%s' "$status" | grep -c .) || true
default=$(git symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null) && default=${default#origin/}
commits=$(git rev-list --count "${default:-main}..HEAD" 2>/dev/null || echo 0)
note="checkpoint: ${commits} commits on task branch, ${changed} files uncommitted"

# Dedupe: an unchanged note is not a new milestone — skip the emit.
# Pure shell on purpose: a python3 dependency here failed silently on
# minimal hosts, defeating dedupe on every turn. Event lines are our own
# emitter's output, so the "note" field is reliably the last key; compare
# in escaped form, the way bin/progress wrote it.
main=$(dirname "$(git rev-parse --git-common-dir)")
main=$(cd "$main" && pwd -P) || exit 0
log="$main/.agents/events.jsonl"
if [ -f "$log" ]; then
  esc=${note//\\/\\\\}
  esc=${esc//\"/\\\"}
  last=$(grep '"task_progress"' "$log" | grep -F "\"task\":\"$task\"" | tail -1 \
    | sed 's/.*"note":"//; s/"}$//')
  [ "$last" = "$esc" ] && exit 0
fi

"$PROGRESS_CMD" "$task" "$note"
