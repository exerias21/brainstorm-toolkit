#!/usr/bin/env bash
# test-hooks.sh — regression harness for the hooks that make policy DETERMINISTIC
# instead of prose-enforced: scripts/hooks/enforce-model-cap.sh and
# scripts/hooks/stop-gate.sh.
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

echo
echo "test-hooks.sh: all cases ok"
