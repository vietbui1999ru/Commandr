#!/usr/bin/env bash
# conformance-driver.sh — drive the omp adapter through the conformance
# harness (protocol/conformance.sh --adapter <this file>).
#
# Translates the harness-neutral driver verbs into the omp adapter's bus
# projection. Unlike the Claude Code driver, there are NO omp-specific
# transport shims to pipe a payload through: omp is launched as a subprocess
# with an explicit workspace directory, so there is no harness hook payload to
# parse for `cwd`. The verbs therefore call the shared adapter cores in
# adapters/lib/ directly — the same canonical projectors the Claude Code and
# OpenCode adapters are gated on (checkpoint.sh, session-end.sh). The cores
# under test are the production files, untouched.
#
# Verb → bus effect:
#   turn-end <dir>          -> adapters/lib/checkpoint.sh <dir>
#                              (one neutral task_progress milestone from git
#                              worktree state; dedupes an unchanged note)
#   session-end <dir> <sid> -> adapters/lib/session-end.sh <dir> <sid>
#                              (omp processes are one-shot and terminate, so
#                              session_end is well-defined — unlike OpenCode's
#                              persistent sessions, which omit this verb)
#
# SCOPE NOTE (honest boundary): this driver certifies the omp ADAPTER's
# neutral-lifecycle bus contract via the canonical cores. The Level 1
# runner.sh additionally emits its own "omp runner started"/"omp complete"
# bookend milestones via PROGRESS_CMD; those are runner-lifecycle markers, a
# separate concern from per-turn worktree checkpoints. runner.sh does not yet
# call checkpoint.sh at turn boundaries — wiring it through the shared core
# (so the runner's own output is what C13 exercises) is the Level 2 follow-up
# tracked in docs/plans/PLAN-control-plane-runner-packages.md.
#
# AGENTS_TASK_ID and PROGRESS_CMD are inherited from the harness environment;
# the cores read them. Every core resolves the bus from <dir> via git, so the
# driver passes the harness FIXTURE straight through.
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
lib="$here/../lib"

case "${1:-}" in
  capabilities)
    # omp supports both: one-shot subprocess => turn checkpoints AND a real
    # process-exit boundary for session_end.
    printf 'turn-end\nsession-end\n' ;;
  turn-end)
    "$lib/checkpoint.sh" "${2:?turn-end requires <dir>}" ;;
  session-end)
    "$lib/session-end.sh" "${2:?session-end requires <dir>}" "${3:?session-end requires <sid>}" ;;
  *)
    printf 'usage: conformance-driver.sh capabilities|turn-end <dir>|session-end <dir> <sid>\n' >&2
    exit 2 ;;
esac
