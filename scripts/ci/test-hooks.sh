#!/usr/bin/env bash
# test-hooks.sh — regression harness for the deterministic controls that make
# policy DETERMINISTIC instead of prose-enforced: scripts/hooks/enforce-model-cap.sh,
# scripts/hooks/stop-gate.sh, scripts/protect-tests.sh (a CLI, not a wired
# hook -- it earns a place here on scope alone; see its own header for why it
# is not under scripts/hooks/), scripts/hooks/next-action.sh (interpreter
# probe + the .next-action seam's dedup/staleness/depth-warning contract),
# and scripts/hooks/run-cost-report.sh (recency-based envelope selection).
#
# Builds fresh scratch project dirs under /tmp, feeds each hook sample stdin JSON
# against a `.claude/project.json`, and asserts on stdout with `grep -q`. Mirrors
# scripts/ci/setup-roundtrip.sh's shape (set -euo pipefail, trap cleanup, /tmp
# scratch — never a Windows TEMP path, setup.sh and these hooks choke on
# backslashes). Exits 1 on the FIRST failing case, printing which one and why;
# every case prints "[ok] <name>" as it passes.
#
# Usage: bash scripts/ci/test-hooks.sh

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CAP_HOOK="$PLUGIN_ROOT/scripts/hooks/enforce-model-cap.sh"
GATE_HOOK="$PLUGIN_ROOT/scripts/hooks/stop-gate.sh"
PROTECT_TESTS="$PLUGIN_ROOT/scripts/protect-tests.sh"
NEXT_ACTION_HOOK="$PLUGIN_ROOT/scripts/hooks/next-action.sh"
COST_HOOK="$PLUGIN_ROOT/scripts/hooks/run-cost-report.sh"
ROOT_TMP="/tmp/test-hooks-$$"

cleanup() { rm -rf "$ROOT_TMP" || true; }
trap cleanup EXIT
rm -rf "$ROOT_TMP"
mkdir -p "$ROOT_TMP"

CASE=""
fail() {
  echo "[FAIL] $CASE: $1" >&2
  exit 1
}
ok() { echo "[ok] $CASE"; }

assert_empty() {
  [ -z "$1" ] || fail "expected NO output, got: $1"
  ok
}
assert_match() {
  printf '%s' "$1" | grep -q -- "$2" || fail "expected output to contain '$2', got: $1"
  ok
}
assert_no_match() {
  if printf '%s' "$1" | grep -q -- "$2"; then fail "expected output to NOT contain '$2', got: $1"; fi
  ok
}
assert_rc() {
  [ "$1" -eq "$2" ] || fail "expected exit $2, got $1"
  ok
}

# ── enforce-model-cap.sh: the eleven-payload matrix ─────────────────────────
# Each case gets its own scratch project dir so state never leaks between cases.

cap_dir() { local d="$ROOT_TMP/cap-$1"; mkdir -p "$d/.claude/agents"; printf '%s' "$d"; }

run_cap() {
  local proj="$1" input="$2"
  CLAUDE_PROJECT_DIR="$proj" bash "$CAP_HOOK" <<<"$input"
}

CASE="cap: not enforced"
d="$(cap_dir 01)"
cat > "$d/.claude/project.json" <<'EOF'
{"pipeline": {"enforce_cap": false}, "models": {"cap": "sonnet"}}
EOF
out="$(run_cap "$d" '{"tool_name":"Agent","tool_input":{"model":"opus","description":"do stuff"}}')"
assert_empty "$out"

CASE="cap: opus -> sonnet"
d="$(cap_dir 02)"
cat > "$d/.claude/project.json" <<'EOF'
{"pipeline": {"enforce_cap": true}, "models": {"cap": "sonnet"}}
EOF
out="$(run_cap "$d" '{"tool_name":"Agent","tool_input":{"model":"opus","description":"do stuff"}}')"
assert_match "$out" '"model": "sonnet"'

CASE="cap: review: exempt"
d="$(cap_dir 03)"
cat > "$d/.claude/project.json" <<'EOF'
{"pipeline": {"enforce_cap": true}, "models": {"cap": "sonnet"}}
EOF
out="$(run_cap "$d" '{"tool_name":"Agent","tool_input":{"model":"opus","description":"review: correctness lens"}}')"
assert_empty "$out"

CASE="cap: haiku untouched"
d="$(cap_dir 04)"
cat > "$d/.claude/project.json" <<'EOF'
{"pipeline": {"enforce_cap": true}, "models": {"cap": "sonnet"}}
EOF
out="$(run_cap "$d" '{"tool_name":"Agent","tool_input":{"model":"haiku","description":"do stuff"}}')"
assert_empty "$out"

CASE="cap: pinned agent untouched"
d="$(cap_dir 05)"
cat > "$d/.claude/project.json" <<'EOF'
{"pipeline": {"enforce_cap": true}, "models": {"cap": "sonnet"}}
EOF
cat > "$d/.claude/agents/pinned-agent.md" <<'EOF'
---
name: pinned-agent
description: synthetic pinned agent for test-hooks.sh
model: haiku
---
Body.
EOF
out="$(run_cap "$d" '{"tool_name":"Agent","tool_input":{"subagent_type":"pinned-agent","description":"do stuff"}}')"
assert_empty "$out"

CASE="cap: unpinned agent filled"
d="$(cap_dir 06)"
cat > "$d/.claude/project.json" <<'EOF'
{"pipeline": {"enforce_cap": true}, "models": {"cap": "sonnet"}}
EOF
cat > "$d/.claude/agents/unpinned-agent.md" <<'EOF'
---
name: unpinned-agent
description: synthetic unpinned agent for test-hooks.sh
---
Body.
EOF
out="$(run_cap "$d" '{"tool_name":"Agent","tool_input":{"subagent_type":"unpinned-agent","description":"do stuff"}}')"
assert_match "$out" '"model": "sonnet"'

CASE="cap: general-purpose filled"
d="$(cap_dir 07)"
cat > "$d/.claude/project.json" <<'EOF'
{"pipeline": {"enforce_cap": true}, "models": {"cap": "sonnet"}}
EOF
out="$(run_cap "$d" '{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose","description":"do stuff"}}')"
assert_match "$out" '"model": "sonnet"'

CASE="cap: fable clamped"
d="$(cap_dir 08)"
cat > "$d/.claude/project.json" <<'EOF'
{"pipeline": {"enforce_cap": true}, "models": {"cap": "sonnet"}}
EOF
out="$(run_cap "$d" '{"tool_name":"Agent","tool_input":{"model":"fable","description":"do stuff"}}')"
assert_match "$out" '"model": "sonnet"'

CASE="cap: non-Agent tool ignored"
d="$(cap_dir 09)"
cat > "$d/.claude/project.json" <<'EOF'
{"pipeline": {"enforce_cap": true}, "models": {"cap": "sonnet"}}
EOF
out="$(run_cap "$d" '{"tool_name":"Bash","tool_input":{"command":"ls"}}')"
assert_empty "$out"

CASE="cap: full model id"
d="$(cap_dir 10)"
cat > "$d/.claude/project.json" <<'EOF'
{"pipeline": {"enforce_cap": true}, "models": {"cap": "sonnet"}}
EOF
out="$(run_cap "$d" '{"tool_name":"Agent","tool_input":{"model":"claude-opus-4-1-20250805","description":"do stuff"}}')"
assert_match "$out" '"model": "sonnet"'

CASE="cap: malformed config"
d="$(cap_dir 11)"
printf '{ this is not valid json' > "$d/.claude/project.json"
out="$(run_cap "$d" '{"tool_name":"Agent","tool_input":{"model":"opus","description":"do stuff"}}')"
assert_empty "$out"

# ── stop-gate.sh: off-by-default, envelope/test states, and the two-blocker
#    contention cases (stop_hook_active, pending sentinel) ──────────────────

gate_dir() {
  local d="$ROOT_TMP/gate-$1"
  mkdir -p "$d/.claude/pipeline/demo"
  printf '%s' "$d"
}

gate_envelope_in_progress() {
  cat > "$1/.claude/pipeline/demo/run.json" <<'EOF'
{"status": "in_progress"}
EOF
}

run_gate() {
  local proj="$1" input="$2"
  CLAUDE_PROJECT_DIR="$proj" bash "$GATE_HOOK" <<<"$input"
}

CASE="gate: off by default -> silent (no output for any input)"
d="$(gate_dir 01)"
gate_envelope_in_progress "$d"
cat > "$d/.claude/project.json" <<'EOF'
{"test": {"unit": "exit 1"}}
EOF
out="$(run_gate "$d" '{}')"
assert_empty "$out"
out="$(run_gate "$d" '{"stop_hook_active": true}')"
assert_empty "$out"
echo '{"cmd":"/gotcha x","source":"test","confirm":false}' > "$d/.claude/.next-action"
out="$(run_gate "$d" '{}')"
assert_empty "$out"
rm -f "$d/.claude/.next-action"

CASE="gate: no envelope -> silent"
d="$(gate_dir 02)"
cat > "$d/.claude/project.json" <<'EOF'
{"pipeline": {"stop_gate": "tests"}, "test": {"unit": "exit 1"}}
EOF
out="$(run_gate "$d" '{}')"
assert_empty "$out"

CASE="gate: envelope in_progress + green tests -> silent"
d="$(gate_dir 03)"
gate_envelope_in_progress "$d"
cat > "$d/.claude/project.json" <<'EOF'
{"pipeline": {"stop_gate": "tests"}, "test": {"unit": "exit 0"}}
EOF
out="$(run_gate "$d" '{}')"
assert_empty "$out"

CASE="gate: red tests -> decision:block"
d="$(gate_dir 04)"
gate_envelope_in_progress "$d"
cat > "$d/.claude/project.json" <<'EOF'
{"pipeline": {"stop_gate": "tests"}, "test": {"unit": "echo boom && exit 1"}}
EOF
out="$(run_gate "$d" '{}')"
assert_match "$out" '"decision": "block"'
out="$(run_gate "$d" '{}')"
assert_match "$out" 'stop-gate: tests red'

CASE="gate: hop budget exhausted -> silent with systemMessage"
d="$(gate_dir 05)"
gate_envelope_in_progress "$d"
cat > "$d/.claude/project.json" <<'EOF'
{"pipeline": {"stop_gate": "tests", "loop": {"max_hops": 2}}, "test": {"unit": "exit 1"}}
EOF
run_gate "$d" '{}' >/dev/null
run_gate "$d" '{}' >/dev/null
out="$(run_gate "$d" '{}')"
assert_no_match "$out" '"decision"'
assert_match "$out" '"systemMessage"'

CASE="gate: missing command -> silent (never blocks)"
d="$(gate_dir 06)"
gate_envelope_in_progress "$d"
cat > "$d/.claude/project.json" <<'EOF'
{"pipeline": {"stop_gate": "tests"}, "test": {"unit": "this-command-does-not-exist-xyz"}}
EOF
out="$(run_gate "$d" '{}')"
assert_no_match "$out" '"decision"'

CASE="gate: stop_hook_active true -> silent even with red tests"
d="$(gate_dir 07)"
gate_envelope_in_progress "$d"
cat > "$d/.claude/project.json" <<'EOF'
{"pipeline": {"stop_gate": "tests"}, "test": {"unit": "exit 1"}}
EOF
out="$(run_gate "$d" '{"stop_hook_active": true}')"
assert_empty "$out"

CASE="gate: pending .next-action sentinel -> silent (non-blocking) even with red tests"
d="$(gate_dir 08)"
gate_envelope_in_progress "$d"
cat > "$d/.claude/project.json" <<'EOF'
{"pipeline": {"stop_gate": "tests"}, "test": {"unit": "exit 1"}}
EOF
echo '{"cmd":"/gotcha x","source":"test","confirm":false}' > "$d/.claude/.next-action"
out="$(run_gate "$d" '{}')"
assert_no_match "$out" '"decision"'
assert_match "$out" '"systemMessage"'
[ -f "$d/.claude/.next-action" ] || fail "stop-gate.sh must PEEK the sentinel, never consume it"

CASE="gate: red tests with no output -> reason has real content after the em-dash"
d="$(gate_dir 09)"
gate_envelope_in_progress "$d"
cat > "$d/.claude/project.json" <<'EOF'
{"pipeline": {"stop_gate": "tests"}, "test": {"unit": "exit 1"}}
EOF
out="$(run_gate "$d" '{}')"
assert_match "$out" '"decision": "block"'
out="$(run_gate "$d" '{}')"
assert_match "$out" 'tests red'
assert_match "$out" 'command produced no output; exit code 1'

CASE="gate: auto_continue true -> silent, no decision key, even with red tests"
d="$(gate_dir 10)"
gate_envelope_in_progress "$d"
cat > "$d/.claude/project.json" <<'EOF'
{"pipeline": {"stop_gate": "tests", "loop": {"auto_continue": true}}, "test": {"unit": "echo boom && exit 1"}}
EOF
out="$(run_gate "$d" '{}')"
assert_no_match "$out" '"decision"'
assert_match "$out" '"systemMessage"'

# ── scripts/protect-tests.sh: arm / verify / disarm -- a CLI, not a wired
#    hook (see its own header), included here per the widened scope above ──

pt_dir() {
  local d="$ROOT_TMP/pt-$1"
  mkdir -p "$d/.claude/pipeline/demo" "$d/tests"
  cat > "$d/.claude/pipeline/demo/run.json" <<'EOF'
{"schema_version": 1, "feature_slug": "demo", "plan_hash": "sha256:deadbeef", "status": "in_progress", "stage": "implement"}
EOF
  printf 'def test_x():\n    assert False\n' > "$d/tests/test_x.py"
  printf '%s' "$d"
}

# Captures stdout/exit code without letting a nonzero rc trip `set -e`
# (a bare `x=$(cmd)` assignment does NOT get the && / || / if exemption).
run_pt() {
  local proj="$1"; shift
  set +e
  PT_OUT="$(cd "$proj" && CLAUDE_PROJECT_DIR="$proj" bash "$PROTECT_TESTS" "$@")"
  PT_RC=$?
  set -e
}

CASE="protect-tests: arm records sha256 in run.json"
d="$(pt_dir 01)"
run_pt "$d" arm tests/test_x.py
assert_rc "$PT_RC" 0
grep -q '"protected_tests"' "$d/.claude/pipeline/demo/run.json" || fail "run.json missing data.protected_tests after arm"
grep -q '"tests/test_x.py": "sha256:' "$d/.claude/pipeline/demo/run.json" || fail "run.json missing armed hash for tests/test_x.py"
ok

CASE="protect-tests: verify clean -> exit 0, no violation"
run_pt "$d" verify
assert_rc "$PT_RC" 0
assert_no_match "$PT_OUT" 'VIOLATION'

CASE="protect-tests: verify after modification -> nonzero exit with violation line"
printf 'def test_x():\n    assert True\n' > "$d/tests/test_x.py"
run_pt "$d" verify
[ "$PT_RC" -ne 0 ] || fail "expected nonzero exit on a tampered armed test, got 0"
assert_match "$PT_OUT" 'VIOLATION: tests/test_x.py changed since arming'

CASE="protect-tests: disarm clears data.protected_tests"
run_pt "$d" disarm
assert_rc "$PT_RC" 0
if grep -q '"protected_tests"' "$d/.claude/pipeline/demo/run.json"; then
  fail "run.json still has data.protected_tests after disarm"
fi
ok

CASE="protect-tests: verify after disarm -> exit 0 (nothing armed)"
run_pt "$d" verify
assert_rc "$PT_RC" 0
assert_no_match "$PT_OUT" 'VIOLATION'

CASE="protect-tests: no in_progress envelope -> no-op exit 0"
d="$ROOT_TMP/pt-noenv"
mkdir -p "$d"
run_pt "$d" verify
assert_rc "$PT_RC" 0

CASE="protect-tests: --slug addresses exactly the named envelope"
d="$ROOT_TMP/pt-slug"
mkdir -p "$d/.claude/pipeline/task-1-foo" "$d/.claude/pipeline/task-2-bar" "$d/tests"
cat > "$d/.claude/pipeline/task-1-foo/run.json" <<'EOF'
{"schema_version": 1, "feature_slug": "task-1-foo", "pipeline": "task", "status": "in_progress", "stage": "implement", "started_at": "2026-01-01T00:00:00Z"}
EOF
cat > "$d/.claude/pipeline/task-2-bar/run.json" <<'EOF'
{"schema_version": 1, "feature_slug": "task-2-bar", "pipeline": "task", "status": "in_progress", "stage": "implement", "started_at": "2026-02-01T00:00:00Z"}
EOF
printf 'def test_y():\n    assert False\n' > "$d/tests/test_y.py"
run_pt "$d" arm tests/test_y.py --slug task-1-foo
assert_rc "$PT_RC" 0
grep -q '"tests/test_y.py"' "$d/.claude/pipeline/task-1-foo/run.json" || fail "expected slug-addressed envelope task-1-foo to be armed"
if grep -q '"protected_tests"' "$d/.claude/pipeline/task-2-bar/run.json"; then
  fail "task-2-bar must not be touched when --slug names task-1-foo (even though it has the newer started_at)"
fi
ok

CASE="protect-tests: no --slug with two open envelopes prefers pipeline:task"
d="$ROOT_TMP/pt-pref"
mkdir -p "$d/.claude/pipeline/task-3-baz" "$d/.claude/pipeline/sdlc-run" "$d/tests"
cat > "$d/.claude/pipeline/sdlc-run/run.json" <<'EOF'
{"schema_version": 1, "feature_slug": "sdlc-run", "pipeline": "sdlc", "status": "in_progress", "stage": "implement", "started_at": "2026-03-01T00:00:00Z"}
EOF
cat > "$d/.claude/pipeline/task-3-baz/run.json" <<'EOF'
{"schema_version": 1, "feature_slug": "task-3-baz", "pipeline": "task", "status": "in_progress", "stage": "implement", "started_at": "2026-01-01T00:00:00Z"}
EOF
printf 'def test_z():\n    assert False\n' > "$d/tests/test_z.py"
run_pt "$d" arm tests/test_z.py
assert_rc "$PT_RC" 0
grep -q '"tests/test_z.py"' "$d/.claude/pipeline/task-3-baz/run.json" || fail "expected the pipeline:task envelope to be preferred over pipeline:sdlc even though sdlc-run has the newer started_at"
if grep -q '"protected_tests"' "$d/.claude/pipeline/sdlc-run/run.json"; then
  fail "sdlc-run envelope must not be armed when a pipeline:task envelope is open"
fi
ok

CASE="protect-tests: --slug naming a missing envelope -> exit 0 no-op"
d="$ROOT_TMP/pt-slug-missing"
mkdir -p "$d/.claude/pipeline" "$d/tests"
printf 'def test_w():\n    assert False\n' > "$d/tests/test_w.py"
run_pt "$d" arm tests/test_w.py --slug does-not-exist
assert_rc "$PT_RC" 0

# ── next-action.sh: interpreter probe (step 6) and the .next-action seam's
#    dedup / staleness / depth-warning contract (step 10c) ─────────────────

na_dir() {
  local d="$ROOT_TMP/na-$1"
  mkdir -p "$d/.claude"
  printf '%s' "$d"
}

# fakebin, when non-empty, is PREPENDED to PATH so its stubs shadow whatever
# real interpreters the host machine has. $BRAINSTORM_PYTHON and stdin are
# both cleared/emptied so nothing outside the fixture can affect resolution.
run_na() {
  local proj="$1" fakebin="$2"
  if [ -n "$fakebin" ]; then
    env -u BRAINSTORM_PYTHON CLAUDE_PROJECT_DIR="$proj" PATH="$fakebin:$PATH" \
      bash "$NEXT_ACTION_HOOK" </dev/null
  else
    env -u BRAINSTORM_PYTHON CLAUDE_PROJECT_DIR="$proj" bash "$NEXT_ACTION_HOOK" </dev/null
  fi
}

make_broken_stub() {
  local path="$1"
  cat > "$path" <<'EOF'
#!/bin/sh
echo "Python was not found; run without arguments to install from the Microsoft Store" >&2
exit 49
EOF
  chmod +x "$path"
}

CASE="next-action: falls back past a broken python3 -- Next reaches stdout"
d="$(na_dir 01)"
echo '{"cmd":"/gotcha next-action fallback test","source":"test","confirm":false}' > "$d/.claude/.next-action"
fakebin="$ROOT_TMP/na-fakebin-01"
mkdir -p "$fakebin"
make_broken_stub "$fakebin/python3"
out="$(run_na "$d" "$fakebin")"
assert_match "$out" 'Next: /gotcha next-action fallback test'
[ -f "$d/.claude/.next-action" ] && fail ".next-action should be consumed once the python fallback renders it"
ok

CASE="next-action: no working interpreter at all -- sentinel survives, no output"
d="$(na_dir 02)"
echo '{"cmd":"/gotcha next-action fallback test","source":"test","confirm":false}' > "$d/.claude/.next-action"
fakebin2="$ROOT_TMP/na-fakebin-02"
mkdir -p "$fakebin2"
for name in python3 python py; do make_broken_stub "$fakebin2/$name"; done
out="$(run_na "$d" "$fakebin2")"
assert_empty "$out"
[ -f "$d/.claude/.next-action" ] || fail "sentinel must survive (not be eaten) when nothing can render it"
ok

CASE="next-action: reader dedups by cmd even if duplicates reach the file"
d="$(na_dir 03)"
{
  echo '{"cmd":"/gotcha dup read test","source":"sdlc","confirm":false}'
  echo '{"cmd":"/gotcha dup read test","source":"task","confirm":false}'
} > "$d/.claude/.next-action"
out="$(run_na "$d" "")"
assert_match "$out" 'Next: /gotcha dup read test'
assert_no_match "$out" 'seam parked'

CASE="next-action: parked seam (>1 distinct pending) prints the depth warning"
d="$(na_dir 04)"
{
  echo '{"cmd":"/gotcha alpha pending","source":"sdlc","confirm":false}'
  echo '{"cmd":"/gotcha beta pending","source":"task","confirm":false}'
} > "$d/.claude/.next-action"
out="$(run_na "$d" "")"
# The em dash round-trips through JSON as — (json.dumps escapes non-ASCII
# by default), so match the ASCII portions of the depth warning separately
# rather than the literal glyph.
assert_match "$out" '2 actions pending'
assert_match "$out" 'seam parked'
assert_match "$out" 'Next: /gotcha alpha pending'
assert_match "$out" 'Next: /gotcha beta pending'

CASE="next-action: drops an entry whose plan/target file no longer exists"
d="$(na_dir 05)"
echo '{"cmd":"/sdlc plans/does-not-exist.md","source":"brainstorm","confirm":false}' > "$d/.claude/.next-action"
out="$(run_na "$d" "")"
assert_empty "$out"
[ -f "$d/.claude/.next-action" ] && fail "an all-stale sentinel should still be consumed (parsed, then removed)"
ok

CASE="seam: appending a duplicate cmd with a different source does not grow the file"
d="$(na_dir 06)"
file="$d/.claude/.next-action"
: > "$file"
seam_append_dedup() {
  local f="$1" cmd="$2" src="$3"
  grep -qF -e "\"cmd\":\"$cmd\"" -e "\"cmd\": \"$cmd\"" "$f" 2>/dev/null \
    || echo "{\"cmd\":\"$cmd\",\"source\":\"$src\",\"confirm\":false}" >> "$f"
}
seam_append_dedup "$file" "/gotcha dup write test" "sdlc"
seam_append_dedup "$file" "/gotcha dup write test" "task"
lines="$(wc -l < "$file" | tr -d ' ')"
[ "$lines" -eq 1 ] || fail "expected 1 line after a duplicate cmd from a different source, got $lines"
ok

# ── run-cost-report.sh: newest-terminal-envelope selection (step 7) ────────

cost_dir() {
  local d="$ROOT_TMP/cost-$1"
  mkdir -p "$d/.claude/pipeline/aaa-newer" "$d/.claude/pipeline/zzz-older"
  cat > "$d/.claude/pipeline/aaa-newer/run.json" <<'EOF'
{"status": "complete", "updated_at": "2026-09-18T12:00:00Z"}
EOF
  cat > "$d/.claude/pipeline/zzz-older/run.json" <<'EOF'
{"status": "complete", "updated_at": "2026-09-01T00:00:00Z"}
EOF
  # Synthetic JSONL transcript -- run-cost-report.sh exits early unless
  # `.transcript_path` names an existing file.
  cat > "$d/transcript.jsonl" <<'EOF'
{"message": {"usage": {"input_tokens": 100, "cache_read_input_tokens": 10, "cache_creation_input_tokens": 5, "output_tokens": 50}}}
{"message": {"usage": {"input_tokens": 120, "cache_read_input_tokens": 20, "cache_creation_input_tokens": 0, "output_tokens": 60}}}
EOF
  printf '%s' "$d"
}

run_cost() {
  local proj="$1" input="$2"
  CLAUDE_PROJECT_DIR="$proj" bash "$COST_HOOK" <<<"$input"
}

CASE="cost-report: newest terminal envelope wins, not the alphabetically-last glob entry"
d="$(cost_dir 01)"
out="$(run_cost "$d" "{\"transcript_path\": \"$d/transcript.jsonl\"}")"
assert_match "$out" '"systemMessage"'
grep -q '"cost"' "$d/.claude/pipeline/aaa-newer/run.json" \
  || fail "expected data.cost written to aaa-newer/run.json (the NEWER envelope by updated_at)"
if grep -q '"cost"' "$d/.claude/pipeline/zzz-older/run.json"; then
  fail "data.cost incorrectly written to zzz-older/run.json (the OLDER envelope, but alphabetically last)"
fi
[ -f "$d/.claude/pipeline/aaa-newer/.cost-reported" ] || fail "expected .cost-reported marker in aaa-newer"
[ -f "$d/.claude/pipeline/zzz-older/.cost-reported" ] && fail "unexpected .cost-reported marker in zzz-older"
ok

echo
echo "test-hooks.sh: all cases ok"
