#!/usr/bin/env bash
# annotate-hook.sh — integration test for the annotation pickup side
# (adapters/lib/annotate.sh). Creates a temp bus + annotation tree, invokes
# the core with a mock UserPromptSubmit payload, and asserts the fail-open
# invariants from SPEC v0.3 §14.4 (ANNOT-8/9).
#
# Run: bash test/annotate-hook.sh
set -u

here=$(cd "$(dirname "$0")/.." && pwd)
core="$here/adapters/lib/annotate.sh"

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok - %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  not ok - %s\n' "$1" >&2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp" "$norepo"' EXIT
git init -q "$tmp"
mkdir -p "$tmp/.agents/annotations/TASK-TEST"

write_note() { # <file> <body> <consumed-bool>
  printf '{"task":"TASK-TEST","turn":1,"anchor":"general","ts":"2026-06-18T00:00:00Z","author":"human","body":%s,"consumed":%s}\n' \
    "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$2")" "$3" \
    > "$tmp/.agents/annotations/TASK-TEST/$1"
}

payload() { printf '{"prompt":"do the thing","cwd":"%s"}' "$tmp"; }

echo "T1: positive — pending note injected + consumed flipped"
write_note 0001-0000.json "Cap retries at 3." false
out=$(payload | AGENTS_TASK_ID=TASK-TEST bash "$core" "$tmp"); rc=$?
[ $rc -eq 0 ] && ok "exit 0" || bad "exit $rc"
printf '%s' "$out" | grep -F "Cap retries at 3." >/dev/null && ok "body injected into prompt" || bad "body missing from output"
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["consumed"] is True' \
  "$tmp/.agents/annotations/TASK-TEST/0001-0000.json" \
  && ok "consumed flipped to true" || bad "consumed not flipped"
rm -f "$tmp/.agents/annotations/TASK-TEST/"*.json

echo "T2: no annotations — payload unchanged, exit 0"
out=$(payload | AGENTS_TASK_ID=TASK-TEST bash "$core" "$tmp"); rc=$?
[ $rc -eq 0 ] && ok "exit 0" || bad "exit $rc"
printf '%s' "$out" | grep -F '"prompt":"do the thing"' >/dev/null && ok "prompt preserved" || bad "prompt changed"

echo "T3: consumed annotations — payload unchanged, exit 0"
write_note 0001-0000.json "Already seen." true
out=$(payload | AGENTS_TASK_ID=TASK-TEST bash "$core" "$tmp"); rc=$?
[ $rc -eq 0 ] && ok "exit 0" || bad "exit $rc"
printf '%s' "$out" | grep -F '"prompt":"do the thing"' >/dev/null && ok "prompt unchanged" || bad "prompt changed"
printf '%s' "$out" | grep -F "Already seen." >/dev/null && bad "consumed note leaked into prompt" || ok "consumed note not injected"
rm -f "$tmp/.agents/annotations/TASK-TEST/"*.json

echo "T4: missing task directory — payload unchanged, exit 0"
rmdir "$tmp/.agents/annotations/TASK-TEST" 2>/dev/null
out=$(payload | AGENTS_TASK_ID=TASK-TEST bash "$core" "$tmp"); rc=$?
[ $rc -eq 0 ] && ok "exit 0" || bad "exit $rc"
printf '%s' "$out" | grep -F '"prompt":"do the thing"' >/dev/null && ok "prompt preserved" || bad "prompt changed"

echo "T5: not-a-repo directory — payload unchanged, exit 0"
norepo=$(mktemp -d)
out=$(payload | AGENTS_TASK_ID=TASK-TEST bash "$core" "$norepo"); rc=$?
[ $rc -eq 0 ] && ok "exit 0" || bad "exit $rc"
printf '%s' "$out" | grep -F '"prompt":"do the thing"' >/dev/null && ok "prompt preserved" || bad "prompt changed"
rm -rf "$norepo"; norepo=""

echo
echo "annotate-hook: $pass passed, $fail failed"
[ $fail -eq 0 ]
