#!/usr/bin/env bash
# test-hooks.sh — regression harness for the deterministic controls that make
# policy DETERMINISTIC instead of prose-enforced: scripts/hooks/enforce-model-cap.sh,
# scripts/hooks/stop-gate.sh (envelope/test states, its timeout-runner
# resolution -- timeout/gtimeout/perl fallback -- and its fail-closed git
# trust check: tracked, no-git-on-PATH, and not-a-git-repo all stand down),
# scripts/protect-tests.sh (a CLI,
# not a wired hook -- it earns a place here on scope alone; see its own header
# for why it is not under scripts/hooks/), scripts/hooks/next-action.sh
# (interpreter probe + the .next-action seam's dedup/staleness/depth-warning
# contract), scripts/hooks/run-cost-report.sh (recency-based envelope selection,
# the this-session bound on which envelope may be reported, and its three-tier
# interpreter resolution), scripts/hooks/reseed-context.sh (three-tier
# interpreter resolution -- this script's FIRST CI coverage), and
# scripts/close-tasks.sh (trailer-only `_manual_`/`_followup_` matching, the
# phase-aware `reconcile` refinement, `board`'s `manual` field, and `rows`'
# first-run row lookup).
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

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
CAP_HOOK="$PLUGIN_ROOT/scripts/hooks/enforce-model-cap.sh"
GATE_HOOK="$PLUGIN_ROOT/scripts/hooks/stop-gate.sh"
PROTECT_TESTS="$PLUGIN_ROOT/scripts/protect-tests.sh"
NEXT_ACTION_HOOK="$PLUGIN_ROOT/scripts/hooks/next-action.sh"
COST_HOOK="$PLUGIN_ROOT/scripts/hooks/run-cost-report.sh"
RESEED_HOOK="$PLUGIN_ROOT/scripts/hooks/reseed-context.sh"
PYRESOLVE_HOOK="$PLUGIN_ROOT/scripts/hooks/_pyresolve.sh"
CLOSE_TASKS="$PLUGIN_ROOT/scripts/close-tasks.sh"
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

# Blinds `command -v <name>` for a fixed set of names to whatever runs "$@",
# WITHOUT touching the real jq/python3/etc. on this host's PATH -- used to
# prove a hook's fallback resolution (BRAINSTORM_PYTHON or a
# .claude/project.json `python` key) actually engages instead of a real match
# on this machine masking a broken probe. Defining `command` as a shell
# function only takes effect for the DURATION of "$@" (it delegates to the
# real builtin via `builtin command` for every other name), and every call
# site below invokes this inside a `$(...)` command substitution, which bash
# always runs in a subshell -- so the shadow function never escapes to affect
# any later test in this file, with no explicit unset required.
#
# NOTE: this only fools code that EXPLICITLY calls `command -v NAME` before
# acting. stop-gate.sh's PRE-FIX timeout/gtimeout resolution has no such
# check -- it invokes `timeout ...` directly -- so blinding `command -v
# timeout` here does nothing to it (the real /usr/bin/timeout is still
# reachable via ordinary PATH lookup); confirmed by hand while writing the
# step-10 tests below. Proving THAT bug needs build_restricted_path instead.
hide_from_command_v() {
  local hidden="$1"; shift
  # shellcheck disable=SC2317  # invoked indirectly via `command -v` lookups below
  command() {
    local _h
    if [ "${1:-}" = "-v" ]; then
      for _h in $HIDE_FROM_COMMAND_V; do
        [ "${2:-}" = "$_h" ] && return 1
      done
    fi
    builtin command "$@"
  }
  export -f command
  HIDE_FROM_COMMAND_V="$hidden" "$@"
}

# Builds a scratch bin dir wired up as a real, restricted PATH: a tiny wrapper
# script per essential tool (bash/sh/perl/jq/python*/coreutils basics),
# resolved from THIS host's actual PATH, EXCLUDING every name in $1. Unlike
# hide_from_command_v, this changes what a bare `foo ...` invocation actually
# finds -- required to prove stop-gate.sh's PRE-FIX behavior (which shells
# out to `timeout` with no existence check) and its POST-FIX ladder both.
#
# Each entry is a wrapper SCRIPT that `exec`s the real tool's resolved
# absolute path, not a symlink -- a symlinked native .exe (perl.exe on this
# Windows/MSYS host) fails to load its shared libraries when run from outside
# its real install directory ("error while loading shared libraries"), since
# the OS's DLL search follows the invoked path's directory. A wrapper script
# instead execs the ORIGINAL absolute path, so the OS loads the real .exe
# from its real directory and DLL resolution is unaffected.
build_restricted_path() {
  local exclude="$1" bindir="$2"
  rm -rf "$bindir"; mkdir -p "$bindir"
  local essential="bash sh perl jq python3 python py git cat grep sed tail wc rm mkdir mv cp chmod dirname basename tr head ls"
  local name resolved skip ex
  for name in $essential; do
    resolved="$(command -v "$name" 2>/dev/null || true)"
    [ -n "$resolved" ] || continue
    skip=0
    for ex in $exclude; do [ "$name" = "$ex" ] && skip=1; done
    [ "$skip" -eq 1 ] && continue
    printf '#!/bin/sh\nexec "%s" "$@"\n' "$resolved" > "$bindir/$name"
    chmod +x "$bindir/$name"
  done
}
BASH_ABS="$(command -v bash)"

# A proven-RUNNING python, resolved once up front via scripts/py.sh's own
# resolution order (not a bare `command -v python3`, which on this host
# resolves to a broken Microsoft Store stub -- `command -v` succeeds, running
# it does not). Used to build fakebin fixtures below that need a real working
# interpreter under a different name (e.g. a `py` launcher fixture).
REAL_PY_NAME="$(bash "$PLUGIN_ROOT/scripts/py.sh" --print 2>/dev/null | tr -d '\r')"
REAL_PY_ABS="$(command -v "$REAL_PY_NAME" 2>/dev/null || true)"

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

CASE="cap: opus dispatch within an opus cap passes through untouched (the escalated final fix-loop iteration)"
d="$(cap_dir 12)"
cat > "$d/.claude/project.json" <<'EOF'
{"pipeline": {"enforce_cap": true}, "models": {"cap": "opus"}}
EOF
out="$(run_cap "$d" '{"tool_name":"Agent","tool_input":{"model":"opus","description":"do stuff"}}')"
assert_empty "$out"

# ── cap: interpreter resolution -- finding 1. The probe used to try only
#    python3/python, never `py`, so a machine whose ONLY working interpreter is
#    the `py` launcher had enforce_cap silently do nothing. Blind python3/python
#    from `command -v` (not the real ones on THIS host) and prove `py` alone
#    still resolves the enforcement; then blind all three and prove the hook
#    now WARNS instead of going silent. ───────────────────────────────────────

CASE="cap: py launcher alone (python3/python hidden) still enforces the cap"
d="$(cap_dir 13)"
cat > "$d/.claude/project.json" <<'EOF'
{"pipeline": {"enforce_cap": true}, "models": {"cap": "sonnet"}}
EOF
if [ -z "$REAL_PY_ABS" ]; then
  echo "[skip] cap: py launcher fallback -- could not resolve an absolute python path on this host"
else
  fakebin="$ROOT_TMP/cap-fakebin-13"
  mkdir -p "$fakebin"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$REAL_PY_ABS" > "$fakebin/py"
  chmod +x "$fakebin/py"
  out="$(hide_from_command_v "python3 python" env PATH="$fakebin:$PATH" CLAUDE_PROJECT_DIR="$d" \
        bash "$CAP_HOOK" <<<'{"tool_name":"Agent","tool_input":{"model":"opus","description":"do stuff"}}')"
  assert_match "$out" '"model": "sonnet"'
fi

CASE="cap: no interpreter at all while enforce_cap:true -> visible systemMessage warning, never silent"
d="$(cap_dir 14)"
cat > "$d/.claude/project.json" <<'EOF'
{"pipeline": {"enforce_cap": true}, "models": {"cap": "sonnet"}}
EOF
out="$(hide_from_command_v "python3 python py" env -u BRAINSTORM_PYTHON CLAUDE_PROJECT_DIR="$d" \
      bash "$CAP_HOOK" <<<'{"tool_name":"Agent","tool_input":{"model":"opus","description":"do stuff"}}')"
assert_match "$out" '"systemMessage"'
assert_match "$out" 'enforce_cap is true but no working Python'

# ── stop-gate.sh: off-by-default, envelope/test states, and the two-blocker
#    contention cases (stop_hook_active, pending sentinel) ──────────────────

gate_dir() {
  local d="$ROOT_TMP/gate-$1"
  mkdir -p "$d/.claude/pipeline/demo"
  # Every other gate_dir-based case below assumes the OLD "no git repo at
  # all" behavior falls through to trusted/runs -- that was the fail-open
  # bug. Post-fix, a non-repo dir stands down instead, so these scratch dirs
  # need to actually BE a (git-init'd, nothing committed) repo to land in the
  # untracked-inside-a-repo/trusted bucket these cases intend to exercise.
  # The explicit fail-closed cases ("not a git repo" / "git hidden from
  # PATH") build their own dirs instead of calling gate_dir, on purpose.
  #
  # The `|| true` on `git init` itself only defers the failure past this
  # line -- it is NOT the guard. If `git init` fails (e.g. a CI runner's
  # safe.directory/ownership restriction), `$d` is NOT a work tree and the
  # fail-closed stop-gate stands down on it for the SAME reason the explicit
  # "not a git repo" case exercises on purpose -- every case below that
  # asserts only the ABSENCE of a block would then pass for the wrong
  # reason (git distrust, not the behavior under test). The real guard is
  # the explicit check right after: assert the work tree actually exists
  # and fail the whole suite loudly, with a clear message, if it doesn't --
  # letting `git init`'s own failure hit `set -e` directly here would abort
  # the same way but silently, with no explanation.
  (cd "$d" && git init -q) >/dev/null 2>&1 || true
  if ! git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "[FAIL] gate_dir $1: 'git init' at $d did not produce a usable git" \
         "work tree (safe.directory/ownership restriction on this host?)." \
         "Every gate_dir case assumes a real, trusted work tree -- without" \
         "one, the fail-closed stop-gate stands down for the wrong reason" \
         "and absence-of-block assertions would pass vacuously." >&2
    exit 1
  fi
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

CASE="gate: envelope in_progress + green tests -> silent AFTER the first-run announcement"
d="$(gate_dir 03)"
gate_envelope_in_progress "$d"
cat > "$d/.claude/project.json" <<'EOF'
{"pipeline": {"stop_gate": "tests"}, "test": {"unit": "exit 0"}}
EOF
# The very first Stop of a run still names the exact command once (finding 4:
# transparency before ever auto-running a shell command on your behalf) --
# only the SECOND Stop on the same run is the old silent-on-green case.
out="$(run_gate "$d" '{}')"
assert_match "$out" '"systemMessage"'
assert_match "$out" 'exit 0'
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

CASE="gate: legacy FLAT pipeline.auto_continue alias also stands down (mutual exclusion holds either spelling)"
d="$(gate_dir 11)"
gate_envelope_in_progress "$d"
cat > "$d/.claude/project.json" <<'EOF'
{"pipeline": {"stop_gate": "tests", "auto_continue": true}, "test": {"unit": "echo boom && exit 1"}}
EOF
out="$(run_gate "$d" '{}')"
assert_no_match "$out" '"decision"'
assert_match "$out" '"systemMessage"'

CASE="gate: hop budget resets on standdown -- the NEXT Stop runs tests again instead of standing down forever"
d="$(gate_dir 12)"
gate_envelope_in_progress "$d"
cat > "$d/.claude/project.json" <<'EOF'
{"pipeline": {"stop_gate": "tests", "loop": {"max_hops": 2}}, "test": {"unit": "exit 1"}}
EOF
printf '2' > "$d/.claude/.stop-gate-hops"
out="$(run_gate "$d" '{}')"
assert_no_match "$out" '"decision"'
assert_match "$out" 'hop budget'
out="$(run_gate "$d" '{}')"
assert_match "$out" '"decision": "block"'
assert_match "$out" 'stop-gate: tests red'

CASE="gate: timeout AND gtimeout both unresolvable -- falls back to perl and still runs+blocks (stock-macOS shape)"
d="$(gate_dir 13)"
gate_envelope_in_progress "$d"
cat > "$d/.claude/project.json" <<'EOF'
{"pipeline": {"stop_gate": "tests"}, "test": {"unit": "echo boom && exit 1"}}
EOF
# A REAL restricted PATH (see build_restricted_path) -- this is the exact
# stock-macOS shape: no coreutils `timeout(1)` at all, but perl ships by
# default. Before the fix, this hook shelled out to `timeout` unconditionally
# with no existence check; bash's own "timeout: command not found" is exit
# 127, which this hook mapped to "test.unit command not found" and stood
# down WITHOUT ever running the suite.
build_restricted_path "timeout gtimeout" "$ROOT_TMP/rp-13"
out="$(PATH="$ROOT_TMP/rp-13" CLAUDE_PROJECT_DIR="$d" "$BASH_ABS" "$GATE_HOOK" <<<'{}')"
assert_match "$out" '"decision": "block"'
assert_match "$out" 'stop-gate: tests red'
assert_no_match "$out" 'command not found'

CASE="gate: no timeout/gtimeout/perl at all -- runs with NO limit rather than standing down, and says so"
d="$(gate_dir 14)"
gate_envelope_in_progress "$d"
cat > "$d/.claude/project.json" <<'EOF'
{"pipeline": {"stop_gate": "tests"}, "test": {"unit": "echo boom && exit 1"}}
EOF
build_restricted_path "timeout gtimeout perl" "$ROOT_TMP/rp-14"
out="$(PATH="$ROOT_TMP/rp-14" CLAUDE_PROJECT_DIR="$d" "$BASH_ABS" "$GATE_HOOK" <<<'{}')"
assert_match "$out" '"decision": "block"'
assert_match "$out" 'NO time limit'
assert_no_match "$out" 'command not found'

# ── gate: trust model -- finding 4, "a cloned repo runs arbitrary commands on
#    Stop" closed by refusing test.unit when .claude/project.json is TRACKED
#    by git (repo-supplied, not the person's own local/gitignored config) ────

CASE="gate: TRACKED .claude/project.json -- stands down, never runs test.unit, even red"
d="$ROOT_TMP/gate-15"
mkdir -p "$d/.claude/pipeline/demo"
gate_envelope_in_progress "$d"
cat > "$d/.claude/project.json" <<'EOF'
{"pipeline": {"stop_gate": "tests"}, "test": {"unit": "echo ran > marker.txt; exit 1"}}
EOF
(cd "$d" && git init -q && git config user.email t@t.com && git config user.name t \
  && git add .claude/project.json && git commit -q -m "commit config")
out="$(run_gate "$d" '{}')"
assert_no_match "$out" '"decision"'
assert_match "$out" '"systemMessage"'
assert_match "$out" 'TRACKED by git'
[ -f "$d/marker.txt" ] && fail "test.unit must never execute when .claude/project.json is tracked by git"
ok

CASE="gate: BRAINSTORM_TRUST_STOP_GATE=1 overrides the tracked-config stand-down"
d="$ROOT_TMP/gate-16"
mkdir -p "$d/.claude/pipeline/demo"
gate_envelope_in_progress "$d"
cat > "$d/.claude/project.json" <<'EOF'
{"pipeline": {"stop_gate": "tests"}, "test": {"unit": "echo boom && exit 1"}}
EOF
(cd "$d" && git init -q && git config user.email t@t.com && git config user.name t \
  && git add .claude/project.json && git commit -q -m "commit config")
out="$(CLAUDE_PROJECT_DIR="$d" BRAINSTORM_TRUST_STOP_GATE=1 bash "$GATE_HOOK" <<<'{}')"
assert_match "$out" '"decision": "block"'
assert_match "$out" 'tests red'

CASE="gate: UNTRACKED .claude/project.json inside a git repo still runs normally"
d="$ROOT_TMP/gate-17"
mkdir -p "$d/.claude/pipeline/demo"
gate_envelope_in_progress "$d"
(cd "$d" && git init -q)
cat > "$d/.claude/project.json" <<'EOF'
{"pipeline": {"stop_gate": "tests"}, "test": {"unit": "echo boom && exit 1"}}
EOF
out="$(run_gate "$d" '{}')"
assert_match "$out" '"decision": "block"'
assert_match "$out" 'tests red'

# ── gate: trust model fail-closed -- the trust check used to gate the git
#    call on a bare `command -v git` and fall through to TRUSTED when that
#    failed, unlike every other branch of this model (fail-open). These
#    build their own dirs instead of gate_dir, which now git-inits on
#    purpose, so they stay genuinely git-less / non-repo. ───────────────────

CASE="gate: project dir is not a git repo at all -- fails closed, names the override, never runs test.unit"
d="$ROOT_TMP/gate-22"
mkdir -p "$d/.claude/pipeline/demo"
gate_envelope_in_progress "$d"
cat > "$d/.claude/project.json" <<'EOF'
{"pipeline": {"stop_gate": "tests"}, "test": {"unit": "echo ran > marker.txt; exit 1"}}
EOF
out="$(run_gate "$d" '{}')"
assert_no_match "$out" '"decision"'
assert_match "$out" '"systemMessage"'
assert_match "$out" 'BRAINSTORM_TRUST_STOP_GATE=1'
[ -f "$d/marker.txt" ] && fail "test.unit must never execute when the project dir is not a git repo (fail closed)"
ok

CASE="gate: git hidden from PATH -- fails closed, names the override, never runs test.unit"
d="$ROOT_TMP/gate-23"
mkdir -p "$d/.claude/pipeline/demo"
gate_envelope_in_progress "$d"
cat > "$d/.claude/project.json" <<'EOF'
{"pipeline": {"stop_gate": "tests"}, "test": {"unit": "echo ran > marker.txt; exit 1"}}
EOF
build_restricted_path "git" "$ROOT_TMP/rp-23"
out="$(PATH="$ROOT_TMP/rp-23" CLAUDE_PROJECT_DIR="$d" "$BASH_ABS" "$GATE_HOOK" <<<'{}')"
assert_no_match "$out" '"decision"'
assert_match "$out" '"systemMessage"'
assert_match "$out" 'BRAINSTORM_TRUST_STOP_GATE=1'
[ -f "$d/marker.txt" ] && fail "test.unit must never execute when git is unavailable on PATH (fail closed)"
ok

CASE="gate: BRAINSTORM_TRUST_STOP_GATE=1 overrides the not-a-git-repo stand-down"
d="$ROOT_TMP/gate-24"
mkdir -p "$d/.claude/pipeline/demo"
gate_envelope_in_progress "$d"
cat > "$d/.claude/project.json" <<'EOF'
{"pipeline": {"stop_gate": "tests"}, "test": {"unit": "echo ran > marker.txt; exit 1"}}
EOF
out="$(CLAUDE_PROJECT_DIR="$d" BRAINSTORM_TRUST_STOP_GATE=1 bash "$GATE_HOOK" <<<'{}')"
assert_match "$out" '"decision": "block"'
[ -f "$d/marker.txt" ] || fail "test.unit must run when BRAINSTORM_TRUST_STOP_GATE=1 overrides the fail-closed stand-down"
ok

# stop-gate.sh used to resolve Python with its OWN private
# `for c in python3 python py; do command -v "$c" ...` probe, run
# UNCONDITIONALLY before the config gate even checks whether
# .claude/project.json exists -- so a repo-local `python3` reachable via a
# "."/relative PATH entry executed on every Stop event, opt-in or not. It now
# sources _pyresolve.sh and calls hooks_resolve_python like next-action.sh
# does. These two cases plant that marker and confirm it's never run, with no
# project.json present at all (silent exit 0, per "off by default" above) --
# confirmed by hand against the pre-fix stop-gate.sh, which executed both.

CASE="gate: a '.' PATH entry never lets a repo-local python3 marker run, even with the gate off (no project.json)"
d="$(gate_dir 18)"
printf '#!/bin/sh\ntouch "%s/evil-ran.marker"\n' "$d" > "$d/python3"
chmod +x "$d/python3"
out="$(cd "$d" && env -u BRAINSTORM_PYTHON CLAUDE_PROJECT_DIR="$d" PATH=".:$PATH" bash "$GATE_HOOK" <<<'{}')"
assert_empty "$out"
[ -f "$d/evil-ran.marker" ] && fail "stop-gate.sh must never execute a repo-local python3 via a '.' PATH entry"
ok

CASE="gate: a relative 'bin' PATH entry never lets a repo-local bin/python3 marker run"
d="$(gate_dir 19)"
mkdir -p "$d/bin"
printf '#!/bin/sh\ntouch "%s/evil-ran.marker"\n' "$d/bin" > "$d/bin/python3"
chmod +x "$d/bin/python3"
out="$(cd "$d" && env -u BRAINSTORM_PYTHON CLAUDE_PROJECT_DIR="$d" PATH="bin:$PATH" bash "$GATE_HOOK" <<<'{}')"
assert_empty "$out"
[ -f "$d/bin/evil-ran.marker" ] && fail "stop-gate.sh must never execute a repo-local python3 via a relative 'bin' PATH entry"
ok

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

# ── next-action.sh: interpreter probe and the .next-action seam's
#    dedup / staleness / depth-warning contract ────────────────────────────

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

CASE="next-action: a genuinely stale /sdlc pointer to a missing plan is still dropped"
d="$(na_dir 05b)"
echo '{"cmd":"/sdlc docs/plans/missing.md","source":"brainstorm","confirm":false}' > "$d/.claude/.next-action"
out="$(run_na "$d" "")"
assert_empty "$out"
[ -f "$d/.claude/.next-action" ] && fail "a stale /sdlc target pointer should still be consumed (parsed, then removed)"
ok

CASE="next-action: a /gotcha entry whose PROSE mentions a bare path is never dropped"
d="$(na_dir 05c)"
# Consumer root has no skills/ tree at all (it lives under .claude/skills/ once
# installed) -- the drop logic must not read this bare-path mention in the
# gotcha's prose as a stale command-target pointer.
echo '{"cmd":"/gotcha remember that skills/sdlc/templates/models.md is loaded first","source":"sdlc","confirm":false}' > "$d/.claude/.next-action"
out="$(run_na "$d" "")"
assert_match "$out" 'Next: /gotcha remember that skills/sdlc/templates/models.md is loaded first'
[ -f "$d/.claude/.next-action" ] && fail ".next-action should be consumed once rendered"
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

CASE="next-action: auto-continue ignores an unrelated nested 'auto_continue' key (not 'anywhere' matching)"
d="$(na_dir 07)"
cat > "$d/.claude/project.json" <<'EOF'
{"other_feature": {"nested": {"auto_continue": true}}, "pipeline": {}}
EOF
echo '{"cmd":"/gotcha unrelated-key test","source":"sdlc","confirm":false}' > "$d/.claude/.next-action"
out="$(env -u BRAINSTORM_PYTHON CLAUDE_PROJECT_DIR="$d" bash "$NEXT_ACTION_HOOK" </dev/null)"
assert_no_match "$out" '"decision"'
assert_match "$out" 'Next: /gotcha unrelated-key test'
[ -f "$d/.claude/.auto-continue-hops" ] && fail "auto-continue must not engage for an unrelated nested auto_continue key"
ok

CASE="next-action: legacy flat pipeline.auto_continue alias still engages auto-continue"
d="$(na_dir 08)"
cat > "$d/.claude/project.json" <<'EOF'
{"pipeline": {"auto_continue": true}}
EOF
echo '{"cmd":"/gotcha flat-alias test","source":"sdlc","confirm":false}' > "$d/.claude/.next-action"
# The exact reason text is asserted too: the cmd reaches python on stdin, so Git Bash
# on Windows can no longer rewrite the leading "/gotcha" into "C:/Program Files/Git/gotcha".
out="$(env -u BRAINSTORM_PYTHON CLAUDE_PROJECT_DIR="$d" bash "$NEXT_ACTION_HOOK" </dev/null)"
assert_match "$out" '"decision": "block"'
assert_match "$out" 'Continue with: /gotcha flat-alias test'
assert_no_match "$out" 'Program Files'
ok

CASE="next-action: auto-continue hop budget reads pipeline.loop.max_hops, not any nested max_hops key (finding 3)"
d="$(na_dir 09)"
# A decoy max_hops=999 nested somewhere unrelated -- the pre-fix grep matched the
# FIRST "max_hops" anywhere in the file, which would have picked this decoy
# instead of the real pipeline.loop.max_hops=1 and never hit the budget.
cat > "$d/.claude/project.json" <<'EOF'
{"other_feature": {"deep": {"max_hops": 999}}, "pipeline": {"loop": {"auto_continue": true, "max_hops": 1}}}
EOF
echo '{"cmd":"/gotcha max-hops path test","source":"sdlc","confirm":false}' > "$d/.claude/.next-action"
out1="$(env -u BRAINSTORM_PYTHON CLAUDE_PROJECT_DIR="$d" bash "$NEXT_ACTION_HOOK" </dev/null)"
assert_match "$out1" '"decision": "block"'
assert_match "$out1" 'Continue with: /gotcha max-hops path test'
echo '{"cmd":"/gotcha max-hops path test","source":"sdlc","confirm":false}' > "$d/.claude/.next-action"
out2="$(env -u BRAINSTORM_PYTHON CLAUDE_PROJECT_DIR="$d" bash "$NEXT_ACTION_HOOK" </dev/null)"
assert_no_match "$out2" '"decision"'
assert_match "$out2" 'hop budget reached'

CASE="next-action: an implausible .claude/project.json python value is rejected, falls back to the probe (finding 2)"
d="$(na_dir 10)"
# /usr/bin/true (or wherever it resolves): ignores all args and always exits 0,
# so the OLD unvalidated resolution would have accepted it as "python" (it
# passes the "-c 'pass' runs" proof) and then used it for every JSON read in
# this hook, which `true` always satisfies with silent empty output -- the
# sentinel would go unrendered. hooks_is_plausible_python must reject it by
# basename (and its --version output never says "Python") before it is ever
# treated as the resolved interpreter.
TRUE_ABS="$(command -v true 2>/dev/null || true)"
if [ -z "$TRUE_ABS" ]; then
  echo "[skip] next-action implausible-python case: no 'true' binary found on this host"
else
  cat > "$d/.claude/project.json" <<EOF
{"python": "$TRUE_ABS"}
EOF
  echo '{"cmd":"/gotcha plausibility test","source":"sdlc","confirm":false}' > "$d/.claude/.next-action"
  out="$(run_na "$d" "")"
  assert_match "$out" 'Next: /gotcha plausibility test'
fi

# ── _pyresolve.sh: never execute an unvalidated .claude/project.json `python`
#    value -- relative paths, paths under the project root, and nested keys
#    must all be rejected WITHOUT ever shelling out to the candidate, and a
#    broken BRAINSTORM_PYTHON must note itself on stderr and still fall
#    through to the probe. Sources the helper directly (hooks_resolve_python
#    is the one function every hook under scripts/hooks/ calls) rather than
#    going through a specific hook, so these cases pin the helper's own
#    contract independent of any one caller's plumbing. ─────────────────────

pyr_dir() {
  local d="$ROOT_TMP/pyr-$1"
  mkdir -p "$d/.claude"
  printf '%s' "$d"
}

# Writes an executable script at $1 that touches a marker file (same
# directory, "evil-ran.marker") if it is ever run -- proof of execution, not
# merely of resolution.
write_marker_script() {
  local path="$1" dir
  dir="$(dirname "$path")"
  mkdir -p "$dir"
  printf '#!/bin/sh\ntouch "%s/evil-ran.marker"\n' "$dir" > "$path"
  chmod +x "$path"
}

# Sources _pyresolve.sh and calls hooks_resolve_python "$proj" in a subshell
# (command substitution already forks one, so the sourced functions never
# leak into this script). $BRAINSTORM_PYTHON is cleared unless the caller
# passed its own env assignments after $proj. Sets PYR_OUT/PYR_ERR/PYR_RC.
run_pyresolve() {
  local proj="$1"; shift
  local errfile="$ROOT_TMP/pyr-stderr.$$"
  set +e
  PYR_OUT="$(env -u BRAINSTORM_PYTHON "$@" bash -c '. "$1"; hooks_resolve_python "$2"' _ "$PYRESOLVE_HOOK" "$proj" 2>"$errfile")"
  PYR_RC=$?
  set -e
  PYR_ERR="$(cat "$errfile" 2>/dev/null)"
  rm -f "$errfile"
}

# Like run_pyresolve, but ALSO sets cwd to $proj before calling
# hooks_resolve_python, and takes the exact PATH value to run under as $2 --
# needed for cases where PATH carries a "."/relative/empty entry, since what
# such an entry resolves to depends on cwd at lookup time, not just on PATH's
# text. Sets PYR_OUT/PYR_ERR/PYR_RC.
run_pyresolve_in() {
  local proj="$1" newpath="$2"
  local errfile="$ROOT_TMP/pyr-stderr.$$"
  set +e
  PYR_OUT="$(cd "$proj" && env -u BRAINSTORM_PYTHON PATH="$newpath" bash -c '. "$1"; hooks_resolve_python "$2"' _ "$PYRESOLVE_HOOK" "$proj" 2>"$errfile")"
  PYR_RC=$?
  set -e
  PYR_ERR="$(cat "$errfile" 2>/dev/null)"
  rm -f "$errfile"
}

CASE="pyresolve: a relative python value (./evil.sh) is never executed, resolution falls back to the probe"
d="$(pyr_dir 01)"
write_marker_script "$d/evil.sh"
cat > "$d/.claude/project.json" <<'EOF'
{"python": "./evil.sh"}
EOF
run_pyresolve "$d"
assert_rc "$PYR_RC" 0
[ -f "$d/evil-ran.marker" ] && fail "a relative 'python' value must never be executed"
[ -n "$PYR_OUT" ] || fail "expected the probe fallback to still resolve a working interpreter"
ok

CASE="pyresolve: an absolute path under the project root (bin/python3) is rejected despite a plausible basename"
d="$(pyr_dir 02)"
write_marker_script "$d/bin/python3"
cat > "$d/.claude/project.json" <<EOF
{"python": "$d/bin/python3"}
EOF
run_pyresolve "$d"
assert_rc "$PYR_RC" 0
[ -f "$d/bin/evil-ran.marker" ] && fail "a project-rooted absolute path must never be executed, even with a plausible basename"
[ -n "$PYR_OUT" ] || fail "expected the probe fallback to still resolve a working interpreter"
ok

CASE="pyresolve: a nested python key (tools.python) is never read as the top-level key, resolution falls back to the probe"
d="$(pyr_dir 03)"
write_marker_script "$d/evil.sh"
cat > "$d/.claude/project.json" <<'EOF'
{"tools": {"python": "./evil.sh"}}
EOF
run_pyresolve "$d"
assert_rc "$PYR_RC" 0
[ -f "$d/evil-ran.marker" ] && fail "a nested tools.python key must never be read as the root-level python key"
[ -n "$PYR_OUT" ] || fail "expected the probe fallback to still resolve a working interpreter"
ok

CASE="pyresolve: a plausible bare python name from project.json is accepted normally"
d="$(pyr_dir 04)"
cat > "$d/.claude/project.json" <<EOF
{"python": "$REAL_PY_NAME"}
EOF
run_pyresolve "$d"
assert_rc "$PYR_RC" 0
assert_match "$PYR_OUT" "$REAL_PY_NAME"
assert_no_match "$PYR_ERR" 'ignoring'

CASE="pyresolve: a broken BRAINSTORM_PYTHON prints a one-line stderr note and resolution still succeeds via the probe"
d="$(pyr_dir 05)"
run_pyresolve "$d" BRAINSTORM_PYTHON=/nonexistent/python3
assert_rc "$PYR_RC" 0
assert_match "$PYR_ERR" "ignoring BRAINSTORM_PYTHON value '/nonexistent/python3'"
[ -n "$PYR_OUT" ] || fail "expected the probe fallback to still resolve a working interpreter"
ok

# The three cases below pin the bare-name-only rule that replaced path
# comparison: hooks_is_plausible_python never treats a `python` value as a
# filesystem path at all (any separator or drive prefix is an outright
# reject), so there is no case-sensitivity or mount-alias comparison left to
# get wrong. Confirmed by hand against the pre-fix helper before this rule
# landed: a case-varied absolute path and a bare name colliding with a cwd
# file both executed the repo-local marker script under the old
# path-comparison logic; neither does under this one.

CASE="pyresolve: a case-varied absolute path to an in-repo python3 marker is rejected outright, not by a (case-sensitive) root comparison (f)"
d="$(pyr_dir 06)"
write_marker_script "$d/bin/python3"
UPPER_BIN="$(printf '%s' "$d/bin" | tr 'a-z' 'A-Z')"
cat > "$d/.claude/project.json" <<EOF
{"python": "$UPPER_BIN/python3"}
EOF
run_pyresolve "$d"
assert_rc "$PYR_RC" 0
[ -f "$d/bin/evil-ran.marker" ] && fail "a case-varied path to an in-repo file must never be executed"
[ -n "$PYR_OUT" ] || fail "expected the probe fallback to still resolve a working interpreter"
ok

CASE="pyresolve: a Windows drive-letter form path to an in-repo python3 marker is rejected outright (g)"
d="$(pyr_dir 07)"
write_marker_script "$d/bin/python3"
# cygpath exists only on Windows (Git Bash/MSYS). Guarded with `command -v`, not a
# pipeline: under `set -euo pipefail` a missing cygpath exits 127 and kills the run.
# Elsewhere a synthetic drive-letter path still exercises the rule, which rejects
# the value lexically, before anything could run.
DRIVE_FORM=""
if command -v cygpath >/dev/null 2>&1; then
  DRIVE_FORM="$(cygpath -w "$d/bin/python3" | sed 's#\\#/#g')"
fi
[ -n "$DRIVE_FORM" ] || DRIVE_FORM="C:${d}/bin/python3"
{
  cat > "$d/.claude/project.json" <<EOF
{"python": "$DRIVE_FORM"}
EOF
  run_pyresolve "$d"
  assert_rc "$PYR_RC" 0
  [ -f "$d/bin/evil-ran.marker" ] && fail "a drive-letter form path must never be executed"
  [ -n "$PYR_OUT" ] || fail "expected the probe fallback to still resolve a working interpreter"
  ok
}

# The eight cases below (h, A1-A4, B1-B2) all pin the SAME follow-up finding:
# stripping just "."/empty PATH entries at the lookup is not enough on its
# own. (A) a RELATIVE PATH entry (`bin`, `./bin`) still lets a repo-shipped
# file win without ever being "." itself; and (B) resolving safely once and
# then handing a caller the BARE name back throws the safety away, since
# hooks_read_top_level_python's own JSON-parsing interpreter call, and every
# hook's later `"$PY" ...`, would re-resolve that bare name under whatever
# PATH is active AT THAT LATER POINT. hooks_resolve_python now always prints
# a resolved ABSOLUTE path for the project.json and probe tiers (never the
# bare name), and hooks_path_sans_cwd keeps PATH entries that are absolute
# only -- dropping "." and empty too, same as a relative entry. Confirmed by
# hand against the pre-fix helper before this landed: every one of these
# combinations executed the repo-local marker.

CASE="pyresolve: a bare name resolves to an absolute PATH entry, never a same-named file in the project root, with PATH leading '.' and project.json naming it explicitly (h / A1)"
d="$(pyr_dir 08)"
write_marker_script "$d/$REAL_PY_NAME"
cat > "$d/.claude/project.json" <<EOF
{"python": "$REAL_PY_NAME"}
EOF
run_pyresolve_in "$d" ".:$PATH"
assert_rc "$PYR_RC" 0
[ -f "$d/evil-ran.marker" ] && fail "a bare name must never resolve to a same-named file in the current working directory"
case "$PYR_OUT" in
  "$d/$REAL_PY_NAME") fail "resolved to the repo-local file instead of a real PATH entry: $PYR_OUT" ;;
esac
[ -n "$PYR_OUT" ] || fail "expected resolution to still succeed via a real PATH entry"
ok

CASE="pyresolve: same as above but PATH carries an EMPTY entry instead of '.' (A2)"
d="$(pyr_dir 09)"
write_marker_script "$d/$REAL_PY_NAME"
cat > "$d/.claude/project.json" <<EOF
{"python": "$REAL_PY_NAME"}
EOF
run_pyresolve_in "$d" ":$PATH"
assert_rc "$PYR_RC" 0
[ -f "$d/evil-ran.marker" ] && fail "a bare name must never resolve to a same-named file in the current working directory via an empty PATH entry"
case "$PYR_OUT" in
  "$d/$REAL_PY_NAME") fail "resolved to the repo-local file instead of a real PATH entry: $PYR_OUT" ;;
esac
[ -n "$PYR_OUT" ] || fail "expected resolution to still succeed via a real PATH entry"
ok

CASE="pyresolve: with NO project.json python key, the default probe (python3/python/py) still never picks up a same-named cwd file, PATH leading '.' (A3)"
d="$(pyr_dir 10)"
write_marker_script "$d/$REAL_PY_NAME"
cat > "$d/.claude/project.json" <<'EOF'
{}
EOF
run_pyresolve_in "$d" ".:$PATH"
assert_rc "$PYR_RC" 0
[ -f "$d/evil-ran.marker" ] && fail "the probe tier must never pick up a same-named file in the current working directory"
case "$PYR_OUT" in
  "$d/$REAL_PY_NAME") fail "resolved to the repo-local file instead of a real PATH entry: $PYR_OUT" ;;
esac
[ -n "$PYR_OUT" ] || fail "expected the probe to still resolve a real interpreter"
ok

CASE="pyresolve: same as above but PATH carries an EMPTY entry instead of '.' (A4)"
d="$(pyr_dir 11)"
write_marker_script "$d/$REAL_PY_NAME"
cat > "$d/.claude/project.json" <<'EOF'
{}
EOF
run_pyresolve_in "$d" ":$PATH"
assert_rc "$PYR_RC" 0
[ -f "$d/evil-ran.marker" ] && fail "the probe tier must never pick up a same-named file in the current working directory via an empty PATH entry"
case "$PYR_OUT" in
  "$d/$REAL_PY_NAME") fail "resolved to the repo-local file instead of a real PATH entry: $PYR_OUT" ;;
esac
[ -n "$PYR_OUT" ] || fail "expected the probe to still resolve a real interpreter"
ok

CASE="pyresolve: a RELATIVE PATH entry ('bin') must never let a repo-shipped bin/python3 win a bare-name lookup (B1)"
d="$(pyr_dir 12)"
write_marker_script "$d/bin/python3"
cat > "$d/.claude/project.json" <<'EOF'
{"python": "python3"}
EOF
run_pyresolve_in "$d" "bin:$PATH"
assert_rc "$PYR_RC" 0
[ -f "$d/bin/evil-ran.marker" ] && fail "a relative PATH entry must never let a repo-shipped file win the lookup"
case "$PYR_OUT" in
  "$d/bin/python3") fail "resolved to the repo-local file instead of a real PATH entry: $PYR_OUT" ;;
esac
[ -n "$PYR_OUT" ] || fail "expected resolution to still succeed via a real PATH entry"
ok

CASE="pyresolve: same as above but the relative PATH entry is spelled './bin' (B2)"
d="$(pyr_dir 13)"
write_marker_script "$d/bin/python3"
cat > "$d/.claude/project.json" <<'EOF'
{"python": "python3"}
EOF
run_pyresolve_in "$d" "./bin:$PATH"
assert_rc "$PYR_RC" 0
[ -f "$d/bin/evil-ran.marker" ] && fail "a './bin' PATH entry must never let a repo-shipped file win the lookup"
case "$PYR_OUT" in
  "$d/bin/python3") fail "resolved to the repo-local file instead of a real PATH entry: $PYR_OUT" ;;
esac
[ -n "$PYR_OUT" ] || fail "expected resolution to still succeed via a real PATH entry"
ok

# ── run-cost-report.sh: newest-terminal-envelope selection ─────────────────

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
  # `.transcript_path` names an existing file. The first line's `timestamp`
  # fixes this session's start well before EITHER envelope's `updated_at`,
  # so the this-session bound never excludes either candidate here
  # -- this fixture is about recency tie-breaking, not session bounding
  # (that has its own dedicated case below).
  cat > "$d/transcript.jsonl" <<'EOF'
{"timestamp": "2026-08-01T00:00:00Z", "message": {"usage": {"input_tokens": 100, "cache_read_input_tokens": 10, "cache_creation_input_tokens": 5, "output_tokens": 50}}}
{"timestamp": "2026-08-01T00:05:00Z", "message": {"usage": {"input_tokens": 120, "cache_read_input_tokens": 20, "cache_creation_input_tokens": 0, "output_tokens": 60}}}
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

CASE="cost-report: a paused run is reported, then reported AGAIN once it later completes"
d="$ROOT_TMP/cost-02"
mkdir -p "$d/.claude/pipeline/run-x"
cat > "$d/.claude/pipeline/run-x/run.json" <<'EOF'
{"status": "paused", "updated_at": "2026-09-18T12:00:00Z"}
EOF
# Session start (from the transcript's first timestamp) is well before both
# this envelope's initial `updated_at` and its later completed `updated_at` --
# this fixture is about the paused->complete re-report contract, not session
# bounding.
cat > "$d/transcript.jsonl" <<'EOF'
{"timestamp": "2026-09-01T00:00:00Z", "message": {"usage": {"input_tokens": 100, "cache_read_input_tokens": 10, "cache_creation_input_tokens": 5, "output_tokens": 50}}}
EOF
out="$(run_cost "$d" "{\"transcript_path\": \"$d/transcript.jsonl\"}")"
assert_match "$out" '"systemMessage"'
[ -f "$d/.claude/pipeline/run-x/.cost-reported" ] || fail "expected .cost-reported marker after the paused report"
marker1="$(cat "$d/.claude/pipeline/run-x/.cost-reported" 2>/dev/null | tr -d '\r')"
[ "$marker1" = "paused" ] || fail "expected the marker to record the reported status 'paused', got: $marker1"

# A second Stop while still paused (no status change) must NOT re-report.
out2="$(run_cost "$d" "{\"transcript_path\": \"$d/transcript.jsonl\"}")"
assert_empty "$out2"

# The run resumes and completes -- flip status, same envelope.
cat > "$d/.claude/pipeline/run-x/run.json" <<'EOF'
{"status": "complete", "updated_at": "2026-09-19T12:00:00Z"}
EOF
out3="$(run_cost "$d" "{\"transcript_path\": \"$d/transcript.jsonl\"}")"
assert_match "$out3" '"systemMessage"'
marker2="$(cat "$d/.claude/pipeline/run-x/.cost-reported" 2>/dev/null | tr -d '\r')"
[ "$marker2" = "complete" ] || fail "expected the marker to be updated to 'complete' after the second report, got: $marker2"

# A second Stop at complete (no further status change) must NOT report again.
out4="$(run_cost "$d" "{\"transcript_path\": \"$d/transcript.jsonl\"}")"
assert_empty "$out4"
ok

CASE="cost-report: a lone envelope that settled BEFORE this session started is never reported, only marked"
# A single stale envelope, with nothing newer competing for selection -- this
# is the shape of the real bug: the OLD code picked "whichever unreported
# settled envelope has the highest updated_at" with NO floor, so a repo whose
# only candidate predates this session got THIS session's transcript stats
# written into a run it took no part in, on every Stop. A two-envelope
# fixture (old + fresh) can't discriminate pre-fix from post-fix here: since
# a later moment always sorts as a larger `updated_at`, "the fresh one has
# the higher updated_at" and "the fresh one is at/after session start" are
# the same fact, so the old (buggy) recency-only selection would have picked
# the fresh envelope anyway, coincidentally. Only a LONE stale candidate
# exposes the missing bound.
d="$ROOT_TMP/cost-03"
mkdir -p "$d/.claude/pipeline/old-run"
# Session start (from the transcript's first timestamp) is 2026-09-20;
# old-run settled a full 19 days before that -- it predates this session.
cat > "$d/.claude/pipeline/old-run/run.json" <<'EOF'
{"status": "complete", "updated_at": "2026-09-01T00:00:00Z"}
EOF
cat > "$d/transcript.jsonl" <<'EOF'
{"timestamp": "2026-09-20T00:00:00Z", "message": {"usage": {"input_tokens": 100, "cache_read_input_tokens": 10, "cache_creation_input_tokens": 5, "output_tokens": 50}}}
EOF
old_before="$(cat "$d/.claude/pipeline/old-run/run.json")"
out="$(run_cost "$d" "{\"transcript_path\": \"$d/transcript.jsonl\"}")"
assert_empty "$out"
old_after="$(cat "$d/.claude/pipeline/old-run/run.json")"
[ "$old_before" = "$old_after" ] || fail "old-run's run.json (pre-session envelope) must be byte-for-byte unchanged, got: $old_after"
grep -q '"cost"' "$d/.claude/pipeline/old-run/run.json" && fail "old-run must never get data.cost written -- it predates this session"
[ -f "$d/.claude/pipeline/old-run/.cost-reported" ] || fail "old-run should still be marked (silently) so it is not reconsidered every Stop"
marker="$(cat "$d/.claude/pipeline/old-run/.cost-reported" 2>/dev/null | tr -d '\r')"
[ "$marker" = "complete" ] || fail "expected old-run's silent marker to record its status 'complete', got: $marker"
ok

CASE="cost-report: a fresh envelope (updated_at at/after session start) is still reported normally"
d="$ROOT_TMP/cost-04"
mkdir -p "$d/.claude/pipeline/fresh-run"
cat > "$d/.claude/pipeline/fresh-run/run.json" <<'EOF'
{"status": "complete", "updated_at": "2026-09-21T00:00:00Z"}
EOF
cat > "$d/transcript.jsonl" <<'EOF'
{"timestamp": "2026-09-20T00:00:00Z", "message": {"usage": {"input_tokens": 100, "cache_read_input_tokens": 10, "cache_creation_input_tokens": 5, "output_tokens": 50}}}
EOF
out="$(run_cost "$d" "{\"transcript_path\": \"$d/transcript.jsonl\"}")"
assert_match "$out" '"systemMessage"'
assert_match "$out" 'fresh-run'
grep -q '"cost"' "$d/.claude/pipeline/fresh-run/run.json" || fail "fresh-run (this session's own work) should have data.cost written"
[ -f "$d/.claude/pipeline/fresh-run/.cost-reported" ] || fail "expected .cost-reported marker in fresh-run after a real report"
ok

# ── interpreter resolution: run-cost-report.sh and reseed-context.sh
#    must resolve $BRAINSTORM_PYTHON and .claude/project.json's `python` key
#    the same way scripts/py.sh / next-action.sh do, not just probe
#    python3/python/py -- proven here with jq AND all three probed names
#    blinded via hide_from_command_v, so a real match on THIS host can't mask
#    a broken fallback. REAL_PY_NAME/REAL_PY_ABS are resolved once, near the
#    top of this file (reused by the cap: py-launcher fixture above too). ───

cost_dir_single() {
  local d="$ROOT_TMP/cost-hidden-$1"
  mkdir -p "$d/.claude/pipeline/run-only"
  cat > "$d/.claude/pipeline/run-only/run.json" <<'EOF'
{"status": "complete", "updated_at": "2026-01-01T00:00:01Z"}
EOF
  cat > "$d/transcript.jsonl" <<'EOF'
{"timestamp": "2026-01-01T00:00:00Z", "message": {"usage": {"input_tokens": 100, "cache_read_input_tokens": 10, "cache_creation_input_tokens": 5, "output_tokens": 50}}}
EOF
  printf '%s' "$d"
}

if [ -z "$REAL_PY_ABS" ]; then
  echo "[skip] cost-report/reseed interpreter-resolution cases: could not resolve an absolute python path on this host"
else
  CASE="cost-report: BRAINSTORM_PYTHON resolves the interpreter when jq/python3/python/py all fail to resolve"
  d="$(cost_dir_single 01)"
  out="$(hide_from_command_v "jq python3 python py" env BRAINSTORM_PYTHON="$REAL_PY_ABS" CLAUDE_PROJECT_DIR="$d" bash "$COST_HOOK" <<<"{\"transcript_path\": \"$d/transcript.jsonl\"}")"
  assert_match "$out" '"systemMessage"'
  grep -q '"cost"' "$d/.claude/pipeline/run-only/run.json" || fail "expected data.cost written via the BRAINSTORM_PYTHON fallback"

  # project.json's `python` key can no longer carry a path (see _pyresolve.sh's
  # bare-name-only rule) -- its remaining value is naming a DIFFERENT bare
  # interpreter name than the default probe set (python3/python/py), resolved
  # through PATH like any other bare name.
  CASE="cost-report: .claude/project.json's bare python key names an interpreter outside the default probe set, resolved via PATH"
  d="$(cost_dir_single 02)"
  ALT_BIN="$ROOT_TMP/altbin-cost-02"
  mkdir -p "$ALT_BIN"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$REAL_PY_ABS" > "$ALT_BIN/python3.11"
  chmod +x "$ALT_BIN/python3.11"
  cat > "$d/.claude/project.json" <<'EOF'
{"python": "python3.11"}
EOF
  out="$(hide_from_command_v "jq python3 python py" env -u BRAINSTORM_PYTHON PATH="$ALT_BIN:$PATH" CLAUDE_PROJECT_DIR="$d" bash "$COST_HOOK" <<<"{\"transcript_path\": \"$d/transcript.jsonl\"}")"
  assert_match "$out" '"systemMessage"'
  grep -q '"cost"' "$d/.claude/pipeline/run-only/run.json" || fail "expected data.cost written via the project.json python-key fallback"
fi

# ── reseed-context.sh: interpreter resolution -- this script's
#    FIRST CI coverage. The final reseed message is emitted ONLY through $PY
#    (no jq path exists for it), so this also proves the hook doesn't go
#    silent -- exactly the failure the fix addresses. ───────────────────────

reseed_dir() {
  local d="$ROOT_TMP/reseed-$1"
  mkdir -p "$d/.claude/pipeline/demo-slug"
  cat > "$d/.claude/pipeline/demo-slug/run.json" <<'EOF'
{"status": "in_progress", "feature_slug": "demo-slug", "stage": "implement"}
EOF
  printf '%s' "$d"
}

if [ -z "$REAL_PY_ABS" ]; then
  echo "[skip] reseed-context interpreter-resolution cases: could not resolve an absolute python path on this host"
else
  CASE="reseed-context: BRAINSTORM_PYTHON resolves the interpreter when jq/python3/python/py all fail to resolve"
  d="$(reseed_dir 01)"
  out="$(hide_from_command_v "jq python3 python py" env BRAINSTORM_PYTHON="$REAL_PY_ABS" CLAUDE_PROJECT_DIR="$d" bash "$RESEED_HOOK" <<<'{"source":"compact","hook_event_name":"SessionStart"}')"
  assert_match "$out" '"additionalContext"'
  assert_match "$out" 'demo-slug'

  # Same rule as the cost-report case above: project.json's `python` key
  # names a bare interpreter outside the default probe set, never a path.
  CASE="reseed-context: .claude/project.json's bare python key names an interpreter outside the default probe set, resolved via PATH"
  d="$(reseed_dir 02)"
  ALT_BIN="$ROOT_TMP/altbin-reseed-02"
  mkdir -p "$ALT_BIN"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$REAL_PY_ABS" > "$ALT_BIN/python3.11"
  chmod +x "$ALT_BIN/python3.11"
  cat > "$d/.claude/project.json" <<'EOF'
{"python": "python3.11"}
EOF
  out="$(hide_from_command_v "jq python3 python py" env -u BRAINSTORM_PYTHON PATH="$ALT_BIN:$PATH" CLAUDE_PROJECT_DIR="$d" bash "$RESEED_HOOK" <<<'{"source":"compact","hook_event_name":"SessionStart"}')"
  assert_match "$out" '"additionalContext"'
  assert_match "$out" 'demo-slug'
fi

# ── close-tasks.sh: trailer-only tag matching, `_manual_` exemptions, the
#    phase-aware reconcile refinement, and board's `manual` field (this
#    script's FIRST CI coverage) ────────────────────────────────────────────

ct_dir() {
  local d="$ROOT_TMP/ct-$1"
  mkdir -p "$d/.claude/pipeline" "$d/plans"
  printf '%s' "$d"
}

# Fixture rows contain literal em dashes (U+2014) -- write via printf so the
# bytes land as UTF-8 regardless of the host's default encoding.
run_ct() {
  local proj="$1"; shift
  set +e
  CT_OUT="$(cd "$proj" && bash "$CLOSE_TASKS" "$@" 2>&1)"
  CT_RC=$?
  set -e
  CT_OUT="$(printf '%s' "$CT_OUT" | tr -d '\r')"
}

CASE="close-tasks board: trailer-only matching -- a title merely mentioning a tag is not tagged"
d="$(ct_dir 01)"
printf '## Active / Pending\n' > "$d/TASKS.md"
printf -- '- [ ] (P1) Row mentioning _manual_ in prose, not tagged \xe2\x80\x94 plans/a.md\n' >> "$d/TASKS.md"
printf -- '- [ ] (P1) Row with a real manual tag \xe2\x80\x94 plans/a.md _manual_\n' >> "$d/TASKS.md"
printf -- '- [ ] (P1) Row mentioning pr_followup_of in prose, not tagged \xe2\x80\x94 plans/a.md\n' >> "$d/TASKS.md"
printf -- '- [ ] (P1) Row with a real followup tag \xe2\x80\x94 plans/a.md _followup_\n' >> "$d/TASKS.md"
run_ct "$d" board --file TASKS.md
assert_rc "$CT_RC" 0
BOARD01="$d/board.json"
printf '%s' "$CT_OUT" > "$BOARD01"
set +e
PY_OUT="$(bash "$PLUGIN_ROOT/scripts/py.sh" - "$BOARD01" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
tasks = d['tasks']
assert tasks[0]['manual'] is False, "prose mention of _manual_ must not set manual=true"
assert '_manual_' in tasks[0]['title'], "prose mention of _manual_ must survive in title"
assert tasks[1]['manual'] is True, "a real trailing _manual_ tag must set manual=true"
assert '_manual_' not in tasks[1]['title'], "a real _manual_ tag must be stripped from title"
assert tasks[2]['followup'] is False, "prose mention (pr_followup_of) must not set followup=true"
assert 'pr_followup_of' in tasks[2]['title'], "pr_followup_of must survive stripping intact"
assert tasks[3]['followup'] is True, "a real trailing _followup_ tag must set followup=true"
assert '_followup_' not in tasks[3]['title'], "a real _followup_ tag must be stripped from title"
print("OK")
PYEOF
)"
PY_RC=$?
set -e
[ "$PY_RC" -eq 0 ] || fail "board trailer-only assertions failed: $PY_OUT"
ok

CASE="close-tasks reconcile: exempts _manual_ and _followup_, still catches a forgotten row"
d="$(ct_dir 02)"
printf '## Active / Pending\n' > "$d/TASKS.md"
printf -- '- [ ] (P1) Deliberately open manual row \xe2\x80\x94 plans/b.md _manual_\n' >> "$d/TASKS.md"
printf -- '- [ ] (P1) Deliberately open followup row \xe2\x80\x94 plans/b.md _followup_\n' >> "$d/TASKS.md"
printf -- '- [ ] (P1) Forgotten close-out row \xe2\x80\x94 plans/b.md\n' >> "$d/TASKS.md"
mkdir -p "$d/.claude/pipeline/plan-b"
cat > "$d/.claude/pipeline/plan-b/run.json" <<'EOF'
{"schema_version": 1, "feature_slug": "plan-b", "plan_file": "plans/b.md", "status": "complete"}
EOF
run_ct "$d" reconcile --file TASKS.md
assert_rc "$CT_RC" 0
assert_match "$CT_OUT" '"terminal_envelope_open_rows"'
assert_match "$CT_OUT" 'Forgotten close-out row'
assert_no_match "$CT_OUT" 'Deliberately open manual row'
assert_no_match "$CT_OUT" 'Deliberately open followup row'

CASE="close-tasks reconcile: phase-aware -- silent on a parked later phase, fires on the taken one"
d="$(ct_dir 03)"
printf '#### Phase 1 -- foo\n\nbody\n\n#### Phase 2 -- bar\n\nbody\n' > "$d/plans/c.md"
printf '## Active / Pending\n' > "$d/TASKS.md"
printf -- '- [ ] (P1) Phase 2 work not yet due \xe2\x80\x94 plans/c.md _plan: c_ \xc2\xb7 _phase: 2_\n' >> "$d/TASKS.md"
printf -- '- [ ] (P1) Phase 1 work somehow still open \xe2\x80\x94 plans/c.md _plan: c_ \xc2\xb7 _phase: 1_\n' >> "$d/TASKS.md"
mkdir -p "$d/.claude/pipeline/plan-c"
cat > "$d/.claude/pipeline/plan-c/run.json" <<'EOF'
{"schema_version": 1, "feature_slug": "plan-c", "plan_file": "plans/c.md", "status": "complete",
 "data": {"scope_gate": {"taken_phases": [1]}}}
EOF
run_ct "$d" reconcile --file TASKS.md
assert_rc "$CT_RC" 0
assert_match "$CT_OUT" 'Phase 1 work somehow still open'
assert_no_match "$CT_OUT" 'Phase 2 work not yet due'

CASE="close-tasks reconcile: phase_tag_without_heading fires on an OPEN row, not on a CLOSED [x] row"
d="$(ct_dir 04)"
printf '#### Phase 1 -- foo\n\nbody\n' > "$d/plans/e.md"
printf '## Active / Pending\n' > "$d/TASKS.md"
printf -- '- [ ] (P1) Open row tagged with a phase the plan never declares \xe2\x80\x94 plans/e.md _plan: e_ \xc2\xb7 _phase: 2_\n' >> "$d/TASKS.md"
printf '\n## Done\n' >> "$d/TASKS.md"
printf -- '- [x] (P1) Closed row tagged with a phase the plan never declares \xe2\x80\x94 plans/e.md _plan: e_ \xc2\xb7 _phase: 3_ _completed_at: 2026-01-01T00:00:00Z_\n' >> "$d/TASKS.md"
run_ct "$d" reconcile --file TASKS.md
assert_rc "$CT_RC" 0
assert_match "$CT_OUT" '"phase_tag_without_heading"'
assert_match "$CT_OUT" 'Open row tagged with a phase the plan never declares'
assert_no_match "$CT_OUT" 'Closed row tagged with a phase the plan never declares'

CASE="close-tasks rows: first run (no envelope on disk) still reports tagged rows"
d="$(ct_dir 05)"
# No run.json anywhere under .claude/pipeline -- this is the exact incident
# shape: `reconcile | grep <slug>` only sees EXISTING envelopes, so a first
# run for a plan always reads zero rows even though tagged rows are open.
printf '## Active / Pending\n' > "$d/TASKS.md"
printf -- '- [ ] (P1) Open row, no work started yet \xe2\x80\x94 plans/rowplan.md _plan: rowplan_ \xc2\xb7 _phase: 1_\n' >> "$d/TASKS.md"
printf -- '- [~] (P1) In-progress row this run is taking \xe2\x80\x94 plans/rowplan.md _plan: rowplan_ \xc2\xb7 _phase: 1_\n' >> "$d/TASKS.md"
printf -- '- [ ] (P2) Followup-tagged row, deliberately open \xe2\x80\x94 plans/rowplan.md _plan: rowplan_ \xc2\xb7 _phase: 2_ _followup_\n' >> "$d/TASKS.md"
printf -- '- [ ] (P2) Manual-only row \xe2\x80\x94 plans/rowplan.md _plan: rowplan_ \xc2\xb7 _phase: 2_ _manual_\n' >> "$d/TASKS.md"
printf '\n## Done\n' >> "$d/TASKS.md"
printf -- '- [x] (P1) Already-closed row from an earlier phase \xe2\x80\x94 plans/rowplan.md _plan: rowplan_ \xc2\xb7 _phase: 1_ _completed_at: 2026-01-01_\n' >> "$d/TASKS.md"
printf -- '- [ ] (P1) A different plan entirely, must be excluded \xe2\x80\x94 plans/otherplan.md _plan: otherplan_ \xc2\xb7 _phase: 1_\n' >> "$d/TASKS.md"
run_ct "$d" rows --plan rowplan --plan-file plans/rowplan.md
assert_rc "$CT_RC" 0
ROWS05="$d/rows.json"
printf '%s' "$CT_OUT" > "$ROWS05"
set +e
PY_OUT="$(bash "$PLUGIN_ROOT/scripts/py.sh" - "$ROWS05" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
assert d['match_key'] == 'rowplan', d
m = d['matched']
by_line = {r['line']: r for r in m}
assert len(m) == 5, f"expected 5 rowplan rows (first run, zero envelopes), got {len(m)}: {m}"
assert not any('otherplan' in r['text'] for r in m), "a row tagged for a DIFFERENT plan must be excluded"
open_row = next(r for r in m if 'Open row, no work started yet' in r['text'])
assert open_row['state'] == 'open' and open_row['phase'] == 1
assert open_row['followup'] is False and open_row['manual'] is False
inprog_row = next(r for r in m if 'In-progress row this run is taking' in r['text'])
assert inprog_row['state'] == 'in_progress' and inprog_row['phase'] == 1
followup_row = next(r for r in m if 'Followup-tagged row' in r['text'])
assert followup_row['state'] == 'open' and followup_row['phase'] == 2
assert followup_row['followup'] is True and followup_row['manual'] is False
manual_row = next(r for r in m if 'Manual-only row' in r['text'])
assert manual_row['state'] == 'open' and manual_row['phase'] == 2
assert manual_row['manual'] is True and manual_row['followup'] is False
done_row = next(r for r in m if 'Already-closed row' in r['text'])
assert done_row['state'] == 'done' and done_row['phase'] == 1
print("OK")
PYEOF
)"
PY_RC=$?
set -e
[ "$PY_RC" -eq 0 ] || fail "rows assertions failed: $PY_OUT"
ok

CASE="close-tasks reconcile: --json is accepted as a documented no-op (output is always JSON)"
d="$(ct_dir 06)"
printf '## Active / Pending\n' > "$d/TASKS.md"
run_ct "$d" reconcile --file TASKS.md --json
assert_rc "$CT_RC" 0
assert_match "$CT_OUT" '"drift_count"'

CASE="close-tasks rows: raw plan-file basename (prefixed) and Stage 0's stripped slug both match rows tagged with the stripped slug"
d="$(ct_dir 07)"
printf '## Active / Pending\n' > "$d/TASKS.md"
printf -- '- [ ] (P1) Row for add-orders \xe2\x80\x94 plans/brainstorm-add-orders.md _plan: add-orders_\n' >> "$d/TASKS.md"
printf -- '- [ ] (P1) Row for a different plan, must stay excluded \xe2\x80\x94 plans/other.md _plan: other_\n' >> "$d/TASKS.md"
run_ct "$d" rows --plan add-orders --plan-file plans/brainstorm-add-orders.md
assert_rc "$CT_RC" 0
assert_match "$CT_OUT" 'Row for add-orders'
assert_no_match "$CT_OUT" 'Row for a different plan'
run_ct "$d" rows --plan brainstorm-add-orders --plan-file plans/brainstorm-add-orders.md
assert_rc "$CT_RC" 0
assert_match "$CT_OUT" 'Row for add-orders'
assert_no_match "$CT_OUT" 'Row for a different plan'

CASE="close-tasks close --scope plan: raw plan-file basename (unstripped --key) closes the same [~] row the stripped slug would"
d="$(ct_dir 08)"
printf '## Active / Pending\n' > "$d/TASKS.md"
printf -- '- [~] (P1) In-progress row for add-orders \xe2\x80\x94 plans/brainstorm-add-orders.md _plan: add-orders_\n' >> "$d/TASKS.md"
run_ct "$d" close --file TASKS.md --scope plan --key brainstorm-add-orders --plan-file plans/brainstorm-add-orders.md --dry-run
assert_rc "$CT_RC" 0
assert_match "$CT_OUT" 'In-progress row for add-orders'
assert_no_match "$CT_OUT" '"closed": \[\]'

CASE="close-tasks reconcile --apply: terminal envelope closes only the [~] row, leaves the [ ] row reported but untouched"
d="$(ct_dir 09)"
printf '## Active / Pending\n' > "$d/TASKS.md"
printf -- '- [~] (P1) In-progress row taken this run \xe2\x80\x94 plans/d.md _plan: d_\n' >> "$d/TASKS.md"
printf -- '- [ ] (P1) Parked row the scope gate never started \xe2\x80\x94 plans/d.md _plan: d_\n' >> "$d/TASKS.md"
mkdir -p "$d/.claude/pipeline/plan-d"
cat > "$d/.claude/pipeline/plan-d/run.json" <<'EOF'
{"schema_version": 1, "feature_slug": "plan-d", "plan_file": "plans/d.md", "status": "complete"}
EOF
run_ct "$d" reconcile --file TASKS.md --apply
assert_rc "$CT_RC" 0
assert_match "$CT_OUT" 'Parked row the scope gate never started'
assert_match "$CT_OUT" '"closed 1 row(s) belonging to terminal envelope(s)"'
AFTER="$(cat "$d/TASKS.md")"
assert_match "$AFTER" '\[x\] (P1) In-progress row taken this run'
assert_match "$AFTER" '\[ \] (P1) Parked row the scope gate never started'

CASE="close-tasks reconcile: a row's _plan: tag wins over a substring hit on an unrelated envelope's slug"
d="$(ct_dir 10)"
printf '## Active / Pending\n' > "$d/TASKS.md"
printf -- '- [~] (P2) Fix the enforce-model-cap.sh timeout \xe2\x80\x94 plans/brainstorm-hook-timeouts.md _plan: hook-timeouts_\n' >> "$d/TASKS.md"
mkdir -p "$d/.claude/pipeline/model-cap"
cat > "$d/.claude/pipeline/model-cap/run.json" <<'EOF'
{"schema_version": 1, "feature_slug": "model-cap", "plan_file": "plans/model-cap.md", "status": "complete"}
EOF
run_ct "$d" reconcile --file TASKS.md
assert_rc "$CT_RC" 0
assert_match "$CT_OUT" '"drift_count": 0'
assert_no_match "$CT_OUT" 'enforce-model-cap.sh timeout'
run_ct "$d" reconcile --file TASKS.md --apply
assert_rc "$CT_RC" 0
assert_no_match "$CT_OUT" 'enforce-model-cap.sh timeout'
AFTER="$(cat "$d/TASKS.md")"
assert_match "$AFTER" '\[~\] (P2) Fix the enforce-model-cap.sh timeout'

CASE="close-tasks reconcile: the SAME row's own _plan: tag still joins its real envelope"
mkdir -p "$d/.claude/pipeline/hook-timeouts"
cat > "$d/.claude/pipeline/hook-timeouts/run.json" <<'EOF'
{"schema_version": 1, "feature_slug": "hook-timeouts", "plan_file": "plans/hook-timeouts.md", "status": "complete"}
EOF
run_ct "$d" reconcile --file TASKS.md
assert_rc "$CT_RC" 0
assert_match "$CT_OUT" '"drift_count": 1'
assert_match "$CT_OUT" '"envelope": "hook-timeouts"'
assert_no_match "$CT_OUT" '"envelope": "model-cap"'
assert_match "$CT_OUT" 'enforce-model-cap.sh timeout'

CASE="close-tasks board: a row's started_at is not taken from an unrelated envelope that merely contains its slug as a substring"
d="$(ct_dir 11)"
printf '## Active / Pending\n' > "$d/TASKS.md"
printf -- '- [~] (P2) Fix the enforce-model-cap.sh timeout \xe2\x80\x94 plans/brainstorm-hook-timeouts.md _plan: hook-timeouts_\n' >> "$d/TASKS.md"
mkdir -p "$d/.claude/pipeline/model-cap"
cat > "$d/.claude/pipeline/model-cap/run.json" <<'EOF'
{"schema_version": 1, "feature_slug": "model-cap", "plan_file": "plans/model-cap.md", "status": "complete", "started_at": "2099-01-01T00:00:00Z"}
EOF
run_ct "$d" board --file TASKS.md
assert_rc "$CT_RC" 0
BOARD11="$d/board.json"
printf '%s' "$CT_OUT" > "$BOARD11"
set +e
PY_OUT="$(bash "$PLUGIN_ROOT/scripts/py.sh" - "$BOARD11" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
row = d['tasks'][0]
assert 'enforce-model-cap.sh' in row['title']
assert row['started_at'] is None, f"started_at must not be borrowed from the unrelated model-cap envelope: {row['started_at']!r}"
print("OK")
PYEOF
)"
PY_RC=$?
set -e
[ "$PY_RC" -eq 0 ] || fail "board started_at assertions failed: $PY_OUT"
ok

# ── close-tasks.sh: the legacy (untagged-row) fallback must require a
#    "specific" slug -- a single-word envelope slug (`cleanup`, `fix`, `task`)
#    is ordinary English and must never match an untagged row by prose alone;
#    only a path match or a hyphen-compound slug counts (tag matches, when a
#    row DOES carry a `_plan:` tag, are unaffected either way) ────────────────

CASE="close-tasks reconcile --apply: single-word envelope slug 'cleanup' must NOT match an untagged row that merely mentions the word"
d="$(ct_dir 12)"
printf '## Active / Pending\n' > "$d/TASKS.md"
printf -- '- [~] (P1) Run the cleanup script \xe2\x80\x94 plans/other-feature.md\n' >> "$d/TASKS.md"
mkdir -p "$d/.claude/pipeline/cleanup"
cat > "$d/.claude/pipeline/cleanup/run.json" <<'EOF'
{"schema_version": 1, "feature_slug": "cleanup", "plan_file": "plans/x.md", "status": "complete"}
EOF
run_ct "$d" reconcile --file TASKS.md
assert_rc "$CT_RC" 0
assert_match "$CT_OUT" '"drift_count": 0'
assert_no_match "$CT_OUT" 'terminal_envelope_open_rows'
run_ct "$d" reconcile --file TASKS.md --apply
assert_rc "$CT_RC" 0
AFTER="$(cat "$d/TASKS.md")"
assert_match "$AFTER" '\[~\] (P1) Run the cleanup script'
assert_no_match "$AFTER" '## Done'

CASE="close-tasks reconcile: hyphen-compound envelope slug 'hook-timeouts' still matches an untagged row mentioning it (unaffected by the specificity gate)"
d="$(ct_dir 13)"
printf '## Active / Pending\n' > "$d/TASKS.md"
printf -- '- [~] (P1) Fix hook-timeouts in enforce-model-cap \xe2\x80\x94 plans/other.md\n' >> "$d/TASKS.md"
mkdir -p "$d/.claude/pipeline/hook-timeouts"
cat > "$d/.claude/pipeline/hook-timeouts/run.json" <<'EOF'
{"schema_version": 1, "feature_slug": "hook-timeouts", "plan_file": "plans/hook-timeouts.md", "status": "complete"}
EOF
run_ct "$d" reconcile --file TASKS.md
assert_rc "$CT_RC" 0
assert_match "$CT_OUT" '"drift_count": 1'
assert_match "$CT_OUT" '"envelope": "hook-timeouts"'
assert_match "$CT_OUT" 'Fix hook-timeouts in enforce-model-cap'

# ── close-tasks.sh waves: now/next grouping by lane, phase order, explicit tag
#    overrides, file-conflict inference, `_manual_` / unknown-file reporting,
#    the other-worktree overlap warning, and --write ─────────────────────────

# Reads a python body on stdin with `d` bound to the parsed `waves` JSON from
# $CT_OUT; the body asserts, this helper reports.
waves_check() {
  local f="$ROOT_TMP/waves-out-$$.json" out rc
  printf '%s' "$CT_OUT" > "$f"
  set +e
  out="$({ printf 'import json, sys\nd = json.load(open(sys.argv[1], encoding="utf-8"))\n'; cat; printf 'print("OK")\n'; } \
    | bash "$PLUGIN_ROOT/scripts/py.sh" - "$f" 2>&1)"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "waves assertions failed: $out :: $CT_OUT"
}

# One plan file with two phases, each naming its files on a step-level line.
wv_plan() {
  printf '### Implementation Steps\n#### Phase 1 \xe2\x80\x94 one\n1. step\n   Files: `%s`\n#### Phase 2 \xe2\x80\x94 two\n2. step\n   Files: `%s`\n' "$2" "$3" > "$1"
}

CASE="close-tasks waves: a later phase waits on an earlier undone phase of the same plan; lane comes from the files"
d="$(ct_dir w01)"
wv_plan "$d/plans/p.md" src/a.py src/b.py
printf '## Active / Pending\n' > "$d/TASKS.md"
printf -- '- [ ] (P1) Phase two \xe2\x80\x94 plans/p.md _plan: p_ \xc2\xb7 _phase: 2_\n' >> "$d/TASKS.md"
printf -- '- [ ] (P2) Phase one \xe2\x80\x94 plans/p.md _plan: p_ \xc2\xb7 _phase: 1_\n' >> "$d/TASKS.md"
run_ct "$d" waves --file TASKS.md
assert_rc "$CT_RC" 0
waves_check <<'PYEOF'
assert d['schema'] == 1
assert list(d['now']) == ['backend'], d['now']
assert d['now']['backend']['phase'] == 1, d['now']
assert [r['phase'] for r in d['next']['backend']] == [2], d['next']
assert d['needs_you'] == [] and d['unknown_files'] == [] and d['overlaps'] == []
PYEOF
ok

CASE="close-tasks waves: a blocked earlier phase still holds the later phase back (and an empty now-wave is {})"
d="$(ct_dir w02)"
wv_plan "$d/plans/p.md" src/a.py src/b.py
printf '## Active / Pending\n' > "$d/TASKS.md"
printf -- '- [ ] (P1) Phase two \xe2\x80\x94 plans/p.md _plan: p_ \xc2\xb7 _phase: 2_\n\n## Blocked\n' >> "$d/TASKS.md"
printf -- '- [ ] (P1) Phase one \xe2\x80\x94 plans/p.md _plan: p_ \xc2\xb7 _phase: 1_ _blocked_reason: waiting_\n' >> "$d/TASKS.md"
run_ct "$d" waves --file TASKS.md
assert_rc "$CT_RC" 0
waves_check <<'PYEOF'
assert d['now'] == {}, d['now']
assert d['next'] == {}, d['next']
PYEOF
ok

CASE="close-tasks waves: _after: replaces phase inference; a satisfied reference frees the row, an open one holds it"
d="$(ct_dir w03)"
wv_plan "$d/plans/p.md" src/a.py src/b.py
printf '### Implementation Steps\n#### Phase 1 \xe2\x80\x94 one\n1. step\n   Files: `docs/r.md`\n' > "$d/plans/r.md"
printf '## Active / Pending\n' > "$d/TASKS.md"
printf -- '- [ ] (P2) P phase one \xe2\x80\x94 plans/p.md _plan: p_ \xc2\xb7 _phase: 1_\n' >> "$d/TASKS.md"
printf -- '- [ ] (P2) P phase two, freed \xe2\x80\x94 plans/p.md _plan: p_ \xc2\xb7 _phase: 2_ \xc2\xb7 _after: gone_ \xc2\xb7 _lane: other_\n' >> "$d/TASKS.md"
printf -- '- [ ] (P2) R held \xe2\x80\x94 plans/r.md _plan: r_ \xc2\xb7 _phase: 1_ \xc2\xb7 _after: p:1_\n' >> "$d/TASKS.md"
run_ct "$d" waves --file TASKS.md
assert_rc "$CT_RC" 0
waves_check <<'PYEOF'
assert sorted(d['now']) == ['backend', 'other'], d['now']
assert d['now']['other']['title'].startswith('P phase two'), d['now']
held = [r['title'] for rs in d['next'].values() for r in rs]
assert held == ['R held'], d['next']
PYEOF
ok

CASE="close-tasks waves: two rows whose plan phases name the same file conflict; only one reaches now"
d="$(ct_dir w04)"
wv_plan "$d/plans/p.md" src/shared.py src/x.py
wv_plan "$d/plans/q.md" src/shared.py src/y.py
printf '## Active / Pending\n' > "$d/TASKS.md"
printf -- '- [ ] (P1) P one \xe2\x80\x94 plans/p.md _plan: p_ \xc2\xb7 _phase: 1_ \xc2\xb7 _lane: l1_\n' >> "$d/TASKS.md"
printf -- '- [ ] (P2) Q one \xe2\x80\x94 plans/q.md _plan: q_ \xc2\xb7 _phase: 1_ \xc2\xb7 _lane: l2_\n' >> "$d/TASKS.md"
run_ct "$d" waves --file TASKS.md
assert_rc "$CT_RC" 0
waves_check <<'PYEOF'
assert list(d['now']) == ['l1'], d['now']
assert [r['title'] for r in d['next']['l2']] == ['Q one'], d['next']
assert [(c['source'], c['files']) for c in d['conflicts']] == [('inferred', ['src/shared.py'])], d['conflicts']
PYEOF
ok

CASE="close-tasks waves: an explicit _conflicts: keeps two file-disjoint rows out of the same wave"
d="$(ct_dir w05)"
wv_plan "$d/plans/p.md" src/a.py src/x.py
wv_plan "$d/plans/q.md" src/b.py src/y.py
printf '## Active / Pending\n' > "$d/TASKS.md"
printf -- '- [ ] (P1) P one \xe2\x80\x94 plans/p.md _plan: p_ \xc2\xb7 _phase: 1_ \xc2\xb7 _lane: l1_ \xc2\xb7 _conflicts: q:1_\n' >> "$d/TASKS.md"
printf -- '- [ ] (P2) Q one \xe2\x80\x94 plans/q.md _plan: q_ \xc2\xb7 _phase: 1_ \xc2\xb7 _lane: l2_\n' >> "$d/TASKS.md"
run_ct "$d" waves --file TASKS.md
assert_rc "$CT_RC" 0
waves_check <<'PYEOF'
assert list(d['now']) == ['l1'] and 'l2' in d['next'], (d['now'], d['next'])
assert [c['source'] for c in d['conflicts']] == ['explicit'], d['conflicts']
PYEOF
ok

CASE="close-tasks waves: one row per lane (priority, then [~], decides); --write renders ACTION_ITEMS.md"
d="$(ct_dir w06)"
wv_plan "$d/plans/p.md" src/a.py src/x.py
wv_plan "$d/plans/q.md" src/b.py src/y.py
printf '## Active / Pending\n' > "$d/TASKS.md"
printf -- '- [ ] (P1) Backend P1 \xe2\x80\x94 plans/p.md _plan: p_ \xc2\xb7 _phase: 1_\n' >> "$d/TASKS.md"
printf -- '- [~] (P3) Backend in flight \xe2\x80\x94 plans/q.md _plan: q_ \xc2\xb7 _phase: 1_\n' >> "$d/TASKS.md"
run_ct "$d" waves --file TASKS.md --write ACTION_ITEMS.md
assert_rc "$CT_RC" 0
waves_check <<'PYEOF'
assert d['now']['backend']['title'] == 'Backend in flight', d['now']
assert [r['title'] for r in d['next']['backend']] == ['Backend P1'], d['next']
assert d['written'] == 'ACTION_ITEMS.md'
PYEOF
[ -f "$d/ACTION_ITEMS.md" ] || fail "waves --write did not create ACTION_ITEMS.md"
assert_match "$(cat "$d/ACTION_ITEMS.md")" 'generated'
assert_match "$(cat "$d/ACTION_ITEMS.md")" '^## Now'
assert_match "$(cat "$d/ACTION_ITEMS.md")" '^### backend'
ok

CASE="close-tasks waves: _manual_ rows go to needs_you; a row with no resolvable files runs in parallel and is listed in unknown_files"
d="$(ct_dir w07)"
wv_plan "$d/plans/p.md" src/a.py src/x.py
printf '## Active / Pending\n' > "$d/TASKS.md"
printf -- '- [ ] (P1) Human job \xe2\x80\x94 plans/p.md _plan: p_ \xc2\xb7 _phase: 1_ \xc2\xb7 _manual_\n' >> "$d/TASKS.md"
printf -- '- [ ] (P2) Legacy row with no plan \xe2\x80\x94 just do it\n' >> "$d/TASKS.md"
printf -- '- [ ] (P2) Backend row \xe2\x80\x94 plans/p.md _plan: p_ \xc2\xb7 _phase: 1_\n' >> "$d/TASKS.md"
run_ct "$d" waves --file TASKS.md
assert_rc "$CT_RC" 0
waves_check <<'PYEOF'
assert [r['title'] for r in d['needs_you']] == ['Human job'], d['needs_you']
assert [r['title'] for r in d['unknown_files']] == ['Legacy row with no plan — just do it'] or \
    [r['title'] for r in d['unknown_files']][0].startswith('Legacy row'), d['unknown_files']
assert sorted(d['now']) == ['backend', 'general'], d['now']
PYEOF
ok

CASE="close-tasks waves: a now row whose files are dirty in ANOTHER worktree gets overlaps; the current worktree and clean ones do not"
d="$(ct_dir w08)"
if (cd "$d" && git init -q) >/dev/null 2>&1; then
  mkdir -p "$d/src"
  printf 'x\n' > "$d/src/a.py"
  wv_plan "$d/plans/p.md" src/a.py src/x.py
  printf '## Active / Pending\n' > "$d/TASKS.md"
  printf -- '- [ ] (P1) Touches a \xe2\x80\x94 plans/p.md _plan: p_ \xc2\xb7 _phase: 1_\n' >> "$d/TASKS.md"
  (cd "$d" && git add -A && git -c user.name=t -c user.email=t@t commit -q -m init) >/dev/null 2>&1 || fail "waves overlap fixture: commit failed"
  # Dirt in the CURRENT worktree must not count.
  printf 'dirty-here\n' >> "$d/src/a.py"
  run_ct "$d" waves --file TASKS.md
  assert_rc "$CT_RC" 0
  waves_check <<'PYEOF'
assert d['overlaps'] == [] and 'overlaps' not in d['now']['backend'], d
PYEOF
  (cd "$d" && git checkout -q -- src/a.py && git worktree add -q -b other "$ROOT_TMP/ct-w08-other") >/dev/null 2>&1 || fail "waves overlap fixture: worktree add failed"
  printf 'dirty-there\n' >> "$ROOT_TMP/ct-w08-other/src/a.py"
  run_ct "$d" waves --file TASKS.md
  assert_rc "$CT_RC" 0
  waves_check <<'PYEOF'
ov = d['now']['backend']['overlaps']
assert len(ov) == 1 and ov[0]['branch'] == 'other' and ov[0]['files'] == ['src/a.py'], ov
assert len(d['overlaps']) == 1
PYEOF
  ok
else
  echo "[skip] waves overlap: git init unavailable"
fi

CASE="close-tasks waves: outside a git repo the overlap check is silent"
d="$(ct_dir w09)"
wv_plan "$d/plans/p.md" src/a.py src/x.py
printf '## Active / Pending\n' > "$d/TASKS.md"
printf -- '- [ ] (P1) Row \xe2\x80\x94 plans/p.md _plan: p_ \xc2\xb7 _phase: 1_\n' >> "$d/TASKS.md"
run_ct "$d" waves --file TASKS.md
assert_rc "$CT_RC" 0
waves_check <<'PYEOF'
assert d['overlaps'] == [] and list(d['now']) == ['backend'], d
PYEOF
ok

CASE="close-tasks board: exposes after/conflicts/lane from the trailer only"
d="$(ct_dir w10)"
printf '## Active / Pending\n' > "$d/TASKS.md"
printf -- '- [ ] (P1) Prose mentions _lane: fake_ here \xe2\x80\x94 plans/p.md _after: p:1_ \xc2\xb7 _conflicts: q_ \xc2\xb7 _lane: ui_\n' >> "$d/TASKS.md"
printf -- '- [ ] (P1) Prose only mentions _after: z_ \xe2\x80\x94 plans/p.md\n' >> "$d/TASKS.md"
run_ct "$d" board --file TASKS.md
assert_rc "$CT_RC" 0
waves_check <<'PYEOF'
t = d['tasks']
assert t[0]['after'] == ['p:1'] and t[0]['conflicts'] == ['q'] and t[0]['lane'] == 'ui', t[0]
assert t[1]['after'] == [] and t[1]['lane'] is None, t[1]
PYEOF
ok

# ── close-tasks.sh tag: the only writer of _after:/_conflicts:/_lane: ────────

tag_fixture() {
  local d="$1"
  wv_plan "$d/plans/p.md" src/a.py src/b.py
  printf '## Active / Pending\n' > "$d/TASKS.md"
  printf -- '- [ ] (P1) Alpha work \xe2\x80\x94 plans/p.md _plan: p_ \xc2\xb7 _phase: 1_\n' >> "$d/TASKS.md"
  printf -- '- [~] (P2) Beta work \xe2\x80\x94 plans/p.md _plan: p_ \xc2\xb7 _phase: 2_\n' >> "$d/TASKS.md"
  printf -- '- [ ] Gamma bare title\n\n## Done\n' >> "$d/TASKS.md"
  printf -- '- [x] (P2) Delta finished \xe2\x80\x94 plans/p.md _plan: p_ \xc2\xb7 _phase: 1_\n' >> "$d/TASKS.md"
}

# Same shape as waves_check, bound to $CT_OUT.
tag_check() { waves_check; }

CASE="close-tasks tag: --add appends to the trailer in the chaining style, touches no checkbox; --remove undoes it byte-for-byte"
d="$(ct_dir t01)"
tag_fixture "$d"
cp "$d/TASKS.md" "$d/TASKS.orig"
run_ct "$d" tag --file TASKS.md --row Beta --add after:p:1
assert_rc "$CT_RC" 0
tag_check <<'PYEOF'
assert d['changed'] is True and d['tag'] == '_after: p:1_' and d['line'] == 3, d
PYEOF
grep -qF -- "$(printf -- '(P2) Beta work \xe2\x80\x94 plans/p.md _plan: p_ \xc2\xb7 _phase: 2_ \xc2\xb7 _after: p:1_')" "$d/TASKS.md" || fail "tag add: row not extended in chaining style: $(cat "$d/TASKS.md")"
[ "$(grep -c '^- \[~\]' "$d/TASKS.md")" -eq 1 ] || fail "tag add: checkbox state changed"
run_ct "$d" tag --file TASKS.md --row Beta --remove after:p:1
assert_rc "$CT_RC" 0
cmp -s "$d/TASKS.md" "$d/TASKS.orig" || fail "tag remove did not restore the original bytes"
ok

CASE="close-tasks tag: re-adding an existing tag is idempotent; removing an absent tag is a no-op"
d="$(ct_dir t02)"
tag_fixture "$d"
run_ct "$d" tag --file TASKS.md --row Alpha --add lane:docs
assert_rc "$CT_RC" 0
cp "$d/TASKS.md" "$d/TASKS.once"
run_ct "$d" tag --file TASKS.md --row Alpha --add lane:docs
assert_rc "$CT_RC" 0
tag_check <<'PYEOF'
assert d['changed'] is False, d
PYEOF
cmp -s "$d/TASKS.md" "$d/TASKS.once" || fail "idempotent re-add rewrote the file"
run_ct "$d" tag --file TASKS.md --row Gamma --remove after:p:1
assert_rc "$CT_RC" 0
tag_check <<'PYEOF'
assert d['changed'] is False, d
PYEOF
cmp -s "$d/TASKS.md" "$d/TASKS.once" || fail "removing an absent tag rewrote the file"
ok

CASE="close-tasks tag: a row with no trailer gains one; refusals (grammar, unknown plan/phase, 0 or many matches, closed row) exit 1 and write nothing"
d="$(ct_dir t03)"
tag_fixture "$d"
run_ct "$d" tag --file TASKS.md --row Gamma --add lane:ops
assert_rc "$CT_RC" 0
grep -qF -- "$(printf -- '- [ ] Gamma bare title \xe2\x80\x94 _lane: ops_')" "$d/TASKS.md" || fail "tag add on a trailer-less row: $(cat "$d/TASKS.md")"
cp "$d/TASKS.md" "$d/TASKS.before"
for spec in \
  "bad_grammar|Alpha|--add|after:P:1" \
  "bad_grammar|Alpha|--add|lane:has_underscore" \
  "bad_grammar|Alpha|--add|nonsense:x" \
  "unknown_plan|Alpha|--add|after:nosuchplan" \
  "unknown_phase|Alpha|--add|after:p:9" \
  "no_match|zzznothing|--add|lane:x" \
  "no_match|Delta|--add|lane:x" \
  "ambiguous|work|--add|lane:x"; do
  IFS='|' read -r want needle mode val <<<"$spec"
  run_ct "$d" tag --file TASKS.md --row "$needle" "$mode" "$val"
  assert_rc "$CT_RC" 1
  assert_match "$CT_OUT" "\"code\": \"$want\""
done
cmp -s "$d/TASKS.md" "$d/TASKS.before" || fail "a refused tag call modified TASKS.md"
ok

CASE="close-tasks tag: CRLF TASKS.md keeps CRLF on every line and the em-dash bytes"
d="$(ct_dir t04)"
tag_fixture "$d"
sed -i 's/$/\r/' "$d/TASKS.md"
run_ct "$d" tag --file TASKS.md --row Alpha --add after:p:2
assert_rc "$CT_RC" 0
total="$(wc -l < "$d/TASKS.md")"
crlf="$(grep -c $'\r$' "$d/TASKS.md")"
[ "$total" -eq "$crlf" ] || fail "CRLF not preserved ($crlf of $total lines)"
[ "$(grep -c $'\xe2\x80\x94' "$d/TASKS.md")" -ge 3 ] || fail "em-dash bytes lost"
grep -q '_after: p:2_' "$d/TASKS.md" || fail "tag not written in CRLF file"
ok

CASE="close-tasks waves: summary counts and a stable open_hash that moves when the open-row set does"
d="$(ct_dir t05)"
tag_fixture "$d"
run_ct "$d" waves --file TASKS.md
assert_rc "$CT_RC" 0
h1="$(printf '%s' "$CT_OUT" | bash "$PLUGIN_ROOT/scripts/py.sh" -c 'import json,sys; print(json.load(sys.stdin)["open_hash"])')"
waves_check <<'PYEOF'
s = d['summary']
assert set(s) == {'now', 'lanes', 'next', 'needs_you', 'unknown_files', 'conflicts'}, s
assert s['now'] == len(d['now']) and s['next'] == sum(len(v) for v in d['next'].values()), (s, d)
assert s['needs_you'] == 0 and isinstance(d['open_hash'], str) and d['open_hash'], d
PYEOF
run_ct "$d" waves --file TASKS.md
h2="$(printf '%s' "$CT_OUT" | bash "$PLUGIN_ROOT/scripts/py.sh" -c 'import json,sys; print(json.load(sys.stdin)["open_hash"])')"
[ "$h1" = "$h2" ] || fail "open_hash is not stable across identical runs"
run_ct "$d" tag --file TASKS.md --row Gamma --add lane:ops
run_ct "$d" waves --file TASKS.md
h3="$(printf '%s' "$CT_OUT" | bash "$PLUGIN_ROOT/scripts/py.sh" -c 'import json,sys; print(json.load(sys.stdin)["open_hash"])')"
[ "$h1" != "$h3" ] || fail "open_hash did not change after the open-row set changed"
ok

echo
echo "test-hooks.sh: all cases ok"
