#!/usr/bin/env bash
# annotate.sh — shared adapter core: inject pending per-turn annotations as
# context prefix on the next user prompt for the repo at <dir>.
#
# Contract: SPEC v0.3 §14.4 (ANNOT-8/9), §6 (task_annotation), §11 divergence 5.
#   usage:  annotate.sh <dir>            # hook payload JSON on stdin
#   stdout: the payload JSON with annotation bodies prepended to `prompt`;
#           or the original payload unchanged when there is nothing to inject
#           or the prompt field cannot be patched (fail-open).
#   exit:   0 always. Injection is best-effort and never a gate; diagnostics
#           go to stderr only.
#
# Harness shims (claude-code/) own transport: they capture the hook payload,
# extract cwd, and feed the payload to this core on stdin. No harness payload
# field other than the directory crosses this boundary (EVENT-4).
set -u

payload=$(cat)
dir=${1:-}
[ -n "$dir" ] && [ -d "$dir" ] && cd "$dir" || { printf '%s' "$payload"; exit 0; }
git rev-parse --git-common-dir >/dev/null 2>&1 || { printf '%s' "$payload"; exit 0; }

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
[ -n "$task" ] || { printf '%s' "$payload"; exit 0; }

# Find the main checkout from a worktree (CLAIM-2 pattern): annotations live
# in the main checkout's .agents/, never in a per-worktree bus.
main=$(dirname "$(git rev-parse --git-common-dir)")
main=$(cd "$main" && pwd -P) || { printf '%s' "$payload"; exit 0; }
adir="$main/.agents/annotations/$task"
[ -d "$adir" ] || { printf '%s' "$payload"; exit 0; }

# Collect consumed:false bodies in ascending <turn>-<seq> file order, prepend
# them to the prompt as a labelled context block, then flip consumed:true
# atomically per file (ANNOT-8: only after the body has been injected;
# ANNOT-9: alter only `consumed`). python3 does the JSON work — the same
# dependency checkpoint.sh leans on.
if out=$(python3 - "$adir" "$payload" <<'PY'
import json, os, sys, tempfile
adir, payload = sys.argv[1], sys.argv[2]
try:
    doc = json.loads(payload) if payload else {}
except Exception:
    sys.stdout.write(payload); sys.exit(0)
if not isinstance(doc, dict) or not isinstance(doc.get("prompt"), str):
    sys.stdout.write(payload); sys.exit(0)
prompt = doc["prompt"]
notes = []
if os.path.isdir(adir):
    for name in sorted(os.listdir(adir)):
        if name.endswith(".json"):
            f = os.path.join(adir, name)
            try:
                d = json.load(open(f))
            except Exception:
                continue
            if d.get("consumed") is False and isinstance(d.get("body"), str):
                notes.append((f, d))
if not notes:
    sys.stdout.write(payload); sys.exit(0)
parts = []
for f, d in notes:
    parts.append("### Annotation — turn %s, anchor `%s` (from %s)\n%s" % (
        d.get("turn", "?"), d.get("anchor", "general"), d.get("author", "human"), d["body"]))
block = "# Pending annotations\n\n" + "\n\n".join(parts) + "\n\n---\n\n"
doc["prompt"] = block + prompt
for f, d in notes:
    d["consumed"] = True
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(f), prefix=".tmp-")
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(d, fh, indent=2)
            fh.write("\n")
        os.replace(tmp, f)
    except Exception:
        try: os.unlink(tmp)
        except Exception: pass
sys.stdout.write(json.dumps(doc))
PY
); then
  [ -n "$out" ] && printf '%s' "$out" || printf '%s' "$payload"
else
  printf 'annotate: inject failed for task %s\n' "$task" >&2
  printf '%s' "$payload"
fi
exit 0
