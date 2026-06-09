#!/usr/bin/env bash
# conformance-driver.sh — drive the OpenCode adapter plugin for the
# conformance harness (protocol/conformance.sh --adapter <this file>).
#
# Translates the harness-neutral driver verbs into what OpenCode itself
# would do: instantiate the production plugin under bun and publish the
# events the harness publishes on an idle transition — both session.status
# (idle) and its deprecated session.idle twin, concurrently, exactly as a
# real turn end behaves.
#
# session-end is not advertised: OpenCode has no verified per-session
# shutdown event (SPEC §8 makes session_end conditional on harness support).
set -u
here=$(cd "$(dirname "$0")" && pwd -P)

case "${1:-}" in
  capabilities)
    printf 'turn-end\n' ;;
  turn-end)
    dir=${2:?turn-end requires <dir>}
    command -v bun >/dev/null 2>&1 || { printf 'oc-driver: bun required\n' >&2; exit 3; }
    t=$(mktemp "${TMPDIR:-/tmp}/oc-driver.XXXXXX.js")
    trap 'rm -f "$t"' EXIT INT TERM
    cat > "$t" <<'EOF'
import { $ } from "bun"
// Resolve exports the way OpenCode does: PluginModule.server first, then
// the legacy default/named function fallback.
const mod = await import(process.env.OC_PLUGIN)
const plugin = mod.server ?? mod.default
// Full PluginInput shape (minimal stubs for fields this plugin must not
// depend on without the driver noticing — keep the simulation honest).
const dir = process.env.OC_DIR
const hooks = await plugin({
  client: {},
  project: { id: "conformance", worktree: dir },
  directory: dir,
  worktree: dir,
  experimental_workspace: { register() {} },
  serverUrl: new URL("http://localhost:0"),
  $,
})
const idle = { event: { type: "session.status", properties: { sessionID: "ses_driver", status: { type: "idle" } } } }
const legacy = { event: { type: "session.idle", properties: { sessionID: "ses_driver" } } }
await Promise.all([hooks.event(idle), hooks.event(legacy)])
EOF
    OC_PLUGIN="$here/checkpoint.js" OC_DIR="$dir" bun "$t" ;;
  *)
    printf 'usage: conformance-driver.sh capabilities|turn-end <dir>\n' >&2
    exit 2 ;;
esac
