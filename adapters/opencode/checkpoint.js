// checkpoint.js — OpenCode adapter shim: turn-end → bus checkpoint.
//
// Transport only. OpenCode publishes "session.status" (status.type "idle")
// when the agent finishes a turn; older code paths also publish the
// deprecated "session.idle" on the same transition, so both are handled
// behind an in-flight guard to avoid a double spawn. The one field that
// crosses to the bus side is the project directory captured at plugin
// registration — session ids never leave this file (SPEC v0.1 EVENT-4).
// Milestone logic lives in adapters/lib/checkpoint.sh.
//
// Install — symlink (preserves the relative path to ../lib/checkpoint.sh):
//   ln -s /path/to/Commandr/adapters/opencode/checkpoint.js \
//         ~/.config/opencode/plugins/commandr-checkpoint.js
// (or project-local .opencode/plugins/; both dirs are auto-discovered)
// If copied instead of symlinked, set
//   COMMANDR_CHECKPOINT=/path/to/Commandr/adapters/lib/checkpoint.sh
//
// An event hook must never disrupt the harness: the handler swallows all
// errors (fail-open), mirroring the Claude Code Stop hook shim.

const script =
  process.env.COMMANDR_CHECKPOINT ??
  new URL("../lib/checkpoint.sh", import.meta.url).pathname

const isTurnEnd = (event) =>
  (event?.type === "session.status" &&
    event?.properties?.status?.type === "idle") ||
  event?.type === "session.idle" // deprecated twin, still published

export const CommandrCheckpoint = async ({ $, directory, worktree }) => {
  const root = directory || worktree || process.cwd()
  let inFlight = false // session.status + session.idle fire back-to-back
  return {
    event: async ({ event }) => {
      if (!isTurnEnd(event)) return
      if (!$ || inFlight) return // $ is undefined outside Bun
      inFlight = true
      try {
        // .nothrow() keeps the hook fail-open, but a broken emit path must
        // not be invisible — surface the script's stderr in OpenCode's log.
        const r = await $`bash ${script} ${root}`.quiet().nothrow()
        if (r.exitCode !== 0) {
          const err = r.stderr?.toString().trim()
          console.error(`commandr-checkpoint: emit failed for ${root} (exit ${r.exitCode})${err ? `: ${err}` : ""}`)
        }
      } catch (err) {
        console.error(`commandr-checkpoint: emit failed for ${root}: ${err}`)
      } finally {
        inFlight = false
      }
    },
  }
}

export default CommandrCheckpoint
