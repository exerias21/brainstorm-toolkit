#!/usr/bin/env bash
# test-parallel.sh — regression harness for the parallel-orchestration CLIs:
# scripts/lease.sh, scripts/lanes.sh, scripts/merge-queue.sh, scripts/runner.sh.
#
# Same shape as scripts/ci/test-hooks.sh (which calls this file at its end):
# set -euo pipefail, throwaway repos under /tmp, "[ok] <case>" per pass, exit 1
# on the first failure. Nothing here touches the network or a real `claude`:
# runner.sh is driven through a fake binary ($RUNNER_CLAUDE_BIN) that prints
# the JSON shape `claude -p --output-format json` was measured to print on
# 2026-11-15 (session_id, usage.iterations[], permission_denials, result).
#
# Usage: bash scripts/ci/test-parallel.sh
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
LEASE="$PLUGIN_ROOT/scripts/lease.sh"
LANES="$PLUGIN_ROOT/scripts/lanes.sh"
MQ="$PLUGIN_ROOT/scripts/merge-queue.sh"
RUNNER="$PLUGIN_ROOT/scripts/runner.sh"
ROOT_TMP="/tmp/test-parallel-$$"

cleanup() { [ -n "${KEEP_TMP:-}" ] || rm -rf "$ROOT_TMP" || true; }
trap cleanup EXIT
rm -rf "$ROOT_TMP"; mkdir -p "$ROOT_TMP"

CASE=""
fail() { echo "[FAIL] $CASE: $1" >&2; exit 1; }
ok() { echo "[ok] $CASE"; }
assert_match() { printf '%s' "$1" | grep -q -- "$2" || fail "expected output to contain '$2', got: $1"; ok; }
expect_rc() { [ "$1" -eq "$2" ] || fail "expected exit $2, got $1 (output: ${3:-})"; }
assert_rc() { [ "$1" -eq "$2" ] || fail "expected exit $2, got $1 (output: ${3:-})"; ok; }

# run <cmd...>: capture stdout+stderr in OUT and exit code in RC without set -e.
run() { set +e; OUT="$("$@" 2>&1)"; RC=$?; set -e; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# A repo on branch main with one tracked file and a passing test script.
new_repo() {
  local d="$ROOT_TMP/$1"
  mkdir -p "$d"
  git -C "$d" init -q -b main
  printf 'one\n' > "$d/a.txt"
  printf '#!/bin/sh\ntest ! -e FAIL\n' > "$d/test.sh"
  printf '.claude/\n' > "$d/.gitignore"
  git -C "$d" add -A && git -C "$d" commit -q -m init
  printf '%s' "$d"
}

# ── lease.sh ────────────────────────────────────────────────────────────────
export PARALLEL_STATE_DIR="$ROOT_TMP/state-lease"

CASE="lease: acquire a free resource"
run bash "$LEASE" acquire db --holder alice --ttl 60
assert_rc "$RC" 0 "$OUT"

CASE="lease: a second holder is refused and told who holds it"
run bash "$LEASE" acquire db --holder bob
[ "$RC" -eq 1 ] || fail "expected exit 1, got $RC"
assert_match "$OUT" 'held: db by alice'

CASE="lease: all-or-nothing -- a blocked set takes nothing"
run bash "$LEASE" acquire port-8080 db --holder bob
[ "$RC" -eq 1 ] || fail "expected exit 1"
if bash "$LEASE" list | grep -q 'port-8080'; then fail "port-8080 was taken despite db being blocked"; fi
ok

CASE="lease: same holder re-acquiring renews"
run bash "$LEASE" acquire db --holder alice --ttl 120
assert_rc "$RC" 0 "$OUT"

CASE="lease: renew by another holder is refused"
run bash "$LEASE" renew db --holder bob
assert_rc "$RC" 1 "$OUT"

CASE="lease: an expired lease is free again and sweep reports it"
now=$(( $(date +%s) + 1000 ))
run env LEASE_NOW="$now" bash "$LEASE" sweep
printf '%s' "$OUT" | grep -q -- 'expired: db by alice' || fail "missing expired: db by alice"
run env LEASE_NOW="$now" bash "$LEASE" acquire db --holder bob --ttl 60
assert_rc "$RC" 0 "$OUT"

CASE="lease: release by a non-holder is refused; by the holder succeeds"
run env LEASE_NOW="$now" bash "$LEASE" release db --holder alice
[ "$RC" -eq 1 ] || fail "non-holder release should fail"
run env LEASE_NOW="$now" bash "$LEASE" release db --holder bob
assert_rc "$RC" 0 "$OUT"

CASE="lease: missing --holder is a usage error"
run env -u LEASE_HOLDER bash "$LEASE" acquire db
assert_rc "$RC" 2 "$OUT"

# ── lanes.sh ────────────────────────────────────────────────────────────────
export PARALLEL_STATE_DIR="$ROOT_TMP/state-lanes"
R="$(new_repo lanes)"
printf 'SECRET=x\n' > "$R/.env"
mkdir -p "$R/deps/sub" && printf 'dep\n' > "$R/deps/sub/lib.txt"
printf '# lane seed\n.env\ndeps/\n../outside\n' > "$R/.worktreeinclude"
git -C "$R" add .worktreeinclude && git -C "$R" commit -q -m include

CASE="lanes: create makes a worktree + branch and copies .worktreeinclude"
run bash -c "cd '$R' && bash '$LANES' create ui"
expect_rc "$RC" 0 "$OUT"
LP="$(printf '%s' "$OUT" | sed -n 's/.*path=//p')"
[ -f "$LP/.env" ] || fail ".env not copied into the lane"
[ -f "$LP/deps/sub/lib.txt" ] || fail "deps/ not copied into the lane"
printf '%s' "$OUT" | grep -q 'skipping unsafe' || fail "a '..' entry was not refused"
[ "$(git -C "$LP" symbolic-ref --short HEAD)" = "lane/ui" ] || fail "lane is not on lane/ui"

CASE="lanes: list shows the lane"
run bash -c "cd '$R' && bash '$LANES' list"
assert_match "$OUT" 'lane/ui'

CASE="lanes: remove refuses a lane with unlanded commits"
printf 'lane work\n' > "$LP/b.txt"; git -C "$LP" add b.txt; git -C "$LP" commit -q -m "lane work"
run bash -c "cd '$R' && bash '$LANES' remove ui"
[ "$RC" -eq 1 ] || fail "expected refusal, got $RC: $OUT"
assert_match "$OUT" 'not on main'

CASE="lanes: sync reports conflicting files and aborts the rebase"
printf 'main side\n' > "$R/b.txt"; git -C "$R" add b.txt; git -C "$R" commit -q -m "main b"
run bash -c "cd '$R' && bash '$LANES' sync ui"
[ "$RC" -eq 2 ] || fail "expected exit 2, got $RC: $OUT"
printf '%s' "$OUT" | grep -q 'conflict: b.txt' || fail "conflict file not named: $OUT"
[ ! -d "$(git -C "$LP" rev-parse --git-path rebase-merge)" ] || fail "rebase left in progress"
ok

CASE="lanes: remove --force discards the lane"
run bash -c "cd '$R' && bash '$LANES' remove ui --force"
expect_rc "$RC" 0 "$OUT"
[ ! -d "$LP" ] || fail "worktree dir still present"
git -C "$R" show-ref --verify --quiet refs/heads/lane/ui && fail "branch still present"
ok

CASE="lanes: create prints the base sha (the main worktree's HEAD)"
run bash -c "cd '$R' && bash '$LANES' create based --no-setup"
expect_rc "$RC" 0 "$OUT"
printf '%s' "$OUT" | grep -q "base=$(git -C "$R" rev-parse HEAD) " || fail "base sha not printed: $OUT"
bash -c "cd '$R' && bash '$LANES' remove based --force" >/dev/null
ok

CASE="lanes: pipeline.parallel.lane_setup runs in the new worktree's root"
mkdir -p "$R/.claude"
printf '{"pipeline": {"parallel": {"lane_setup": "pwd > setup-ran.txt"}}}\n' > "$R/.claude/project.json"
run bash -c "cd '$R' && bash '$LANES' create setup1"
expect_rc "$RC" 0 "$OUT"
SP="$(printf '%s' "$OUT" | sed -n 's/.*path=//p')"
[ "$(cat "$SP/setup-ran.txt" 2>/dev/null)" = "$SP" ] || fail "setup did not run in the lane root: $OUT"
bash -c "cd '$R' && bash '$LANES' remove setup1 --force" >/dev/null
ok

CASE="lanes: --no-setup skips lane_setup"
run bash -c "cd '$R' && bash '$LANES' create setup2 --no-setup"
expect_rc "$RC" 0 "$OUT"
SP="$(printf '%s' "$OUT" | sed -n 's/.*path=//p')"
[ ! -e "$SP/setup-ran.txt" ] || fail "setup ran despite --no-setup"
bash -c "cd '$R' && bash '$LANES' remove setup2 --force" >/dev/null
ok

CASE="lanes: a failing lane_setup exits 3 and keeps the lane"
printf '{"pipeline": {"parallel": {"lane_setup": "exit 7"}}}\n' > "$R/.claude/project.json"
run bash -c "cd '$R' && bash '$LANES' create setup3"
expect_rc "$RC" 3 "$OUT"
SP="$(printf '%s' "$OUT" | sed -n 's/.*path=//p')"
[ -d "$SP" ] || fail "lane removed after a failed setup"
bash -c "cd '$R' && bash '$LANES' remove setup3 --force" >/dev/null
rm -f "$R/.claude/project.json"
ok

CASE="lanes: a half-finished npm install fails setup (after the retry) and check reports it"
printf '{}\n' > "$R/package-lock.json"; git -C "$R" add package-lock.json; git -C "$R" commit -q -m lock
printf '{"pipeline": {"parallel": {"lane_setup": "mkdir -p node_modules"}}}\n' > "$R/.claude/project.json"
run bash -c "cd '$R' && bash '$LANES' create npm1"
expect_rc "$RC" 3 "$OUT"
printf '%s' "$OUT" | grep -q 'npm install incomplete' || fail "half install not named: $OUT"
printf '%s' "$OUT" | grep -q 'attempt 2 of 2' || fail "no retry: $OUT"
SP="$(printf '%s' "$OUT" | sed -n 's/.*path=//p')"
run bash -c "cd '$R' && bash '$LANES' check '$SP'"
expect_rc "$RC" 3 "$OUT"
assert_match "$OUT" 'setup incomplete'

CASE="lanes: a complete npm install passes setup and check"
printf '{"pipeline": {"parallel": {"lane_setup": "mkdir -p node_modules && touch node_modules/.package-lock.json"}}}\n' > "$R/.claude/project.json"
run bash -c "cd '$R' && bash '$LANES' setup '$SP'"
expect_rc "$RC" 0 "$OUT"
run bash -c "cd '$R' && bash '$LANES' check '$SP'"
assert_rc "$RC" 0 "$OUT"
bash -c "cd '$R' && bash '$LANES' remove npm1 --force" >/dev/null

CASE="lanes: a setup that fails once is retried and the lane comes up complete"
CNT="$ROOT_TMP/setup-count"; rm -f "$CNT"
printf '{"pipeline": {"parallel": {"lane_setup": "echo x >> %s; test $(wc -l < %s) -ge 2"}}}\n' "$CNT" "$CNT" > "$R/.claude/project.json"
run bash -c "cd '$R' && bash '$LANES' create retry1"
expect_rc "$RC" 0 "$OUT"
SP="$(printf '%s' "$OUT" | sed -n 's/.*path=//p')"
run bash -c "cd '$R' && bash '$LANES' check '$SP'"
expect_rc "$RC" 0 "$OUT"
bash -c "cd '$R' && bash '$LANES' remove retry1 --force" >/dev/null

CASE="lanes: an interrupted setup (no completion marker) is caught by check"
printf '{"pipeline": {"parallel": {"lane_setup": "true"}}}\n' > "$R/.claude/project.json"
run bash -c "cd '$R' && bash '$LANES' create killed1 --no-setup"
expect_rc "$RC" 0 "$OUT"
SP="$(printf '%s' "$OUT" | sed -n 's/.*path=//p')"
run bash -c "cd '$R' && bash '$LANES' check '$SP'"
expect_rc "$RC" 3 "$OUT"
printf '%s' "$OUT" | grep -q 'never finished' || fail "missing marker not reported: $OUT"
bash -c "cd '$R' && bash '$LANES' remove killed1 --force" >/dev/null
git -C "$R" rm -q package-lock.json && git -C "$R" commit -q -m "drop lock"
rm -f "$R/.claude/project.json"
ok

# ── merge-queue.sh ──────────────────────────────────────────────────────────
export PARALLEL_STATE_DIR="$ROOT_TMP/state-mq"
M="$(new_repo mq)"
lane_commit() {  # lane_commit <lane-path> <file> <content>
  printf '%s\n' "$3" > "$1/$2"; git -C "$1" add "$2"; git -C "$1" commit -q -m "edit $2"
}

CASE="merge-queue: clean lane lands by fast-forward, main worktree follows"
L1="$(cd "$M" && bash "$LANES" create one | sed -n 's/.*path=//p')"
lane_commit "$L1" c.txt c
printf 'unrelated main\n' > "$M/d.txt"; git -C "$M" add d.txt; git -C "$M" commit -q -m "main d"
run bash -c "cd '$M' && bash '$MQ' land lane/one --test-cmd 'sh test.sh'"
expect_rc "$RC" 0 "$OUT"
printf '%s' "$OUT" | grep -q 'LANDED' || fail "no LANDED line: $OUT"
[ -f "$M/c.txt" ] || fail "main worktree files were not moved forward"
[ -z "$(git -C "$M" status --porcelain --untracked-files=no)" ] || fail "main worktree shows changes after landing: $(git -C "$M" status --short)"
git -C "$M" log --format=%s -1 | grep -q 'edit c.txt' || fail "main tip is not the lane commit"
printf '%s' "$OUT" | grep -qi 'push' && ! printf '%s' "$OUT" | grep -q 'Not pushed' && fail "unexpected push wording"
ok

CASE="merge-queue: a landed (rebased) lane counts as landed for lanes.sh remove"
run bash -c "cd '$M' && bash '$LANES' remove one"
assert_rc "$RC" 0 "$OUT"

CASE="merge-queue: failing tests refuse and leave main untouched"
L2="$(cd "$M" && bash "$LANES" create two | sed -n 's/.*path=//p')"
lane_commit "$L2" FAIL boom
before="$(git -C "$M" rev-parse main)"
run bash -c "cd '$M' && bash '$MQ' land lane/two --test-cmd 'sh test.sh'"
[ "$RC" -eq 4 ] || fail "expected exit 4, got $RC: $OUT"
[ "$(git -C "$M" rev-parse main)" = "$before" ] || fail "main moved on a red suite"
ok

CASE="merge-queue: no test command configured is refused, not passed"
run bash -c "cd '$M' && bash '$MQ' land lane/two"
assert_rc "$RC" 4 "$OUT"

CASE="merge-queue: a conflict is refused with the files named, never resolved"
L3="$(cd "$M" && bash "$LANES" create three | sed -n 's/.*path=//p')"
lane_commit "$L3" a.txt "lane version"
printf 'main version\n' > "$M/a.txt"; git -C "$M" commit -q -am "main a"
before="$(git -C "$M" rev-parse main)"
run bash -c "cd '$M' && bash '$MQ' land lane/three --test-cmd 'sh test.sh'"
[ "$RC" -eq 2 ] || fail "expected exit 2, got $RC: $OUT"
printf '%s' "$OUT" | grep -q 'conflict: a.txt' || fail "conflict file not named: $OUT"
[ "$(git -C "$M" rev-parse main)" = "$before" ] || fail "main moved on a conflict"
[ "$(cat "$L3/a.txt")" = "lane version" ] || fail "lane files were touched"
[ "$(git -C "$M" worktree list | wc -l)" -eq 3 ] || fail "temp worktree left behind: $(git -C "$M" worktree list)"
ok

CASE="merge-queue: target moved during the test run -> CAS refuses, nothing lands"
L4="$(cd "$M" && bash "$LANES" create four | sed -n 's/.*path=//p')"
lane_commit "$L4" e.txt e
# The test command itself advances main, as a second lander would.
mover="git -C '$M' commit -q --allow-empty -m 'someone else landed'; sh test.sh"
run bash -c "cd '$M' && bash '$MQ' land lane/four --test-cmd \"$mover\""
[ "$RC" -eq 5 ] || fail "expected exit 5, got $RC: $OUT"
git -C "$M" log --format=%s -1 | grep -q 'someone else landed' || fail "the other landing was overwritten"
[ ! -f "$M/e.txt" ] || fail "lane four's file reached main"
ok

CASE="merge-queue: re-running after target moved lands on the new tip"
run bash -c "cd '$M' && bash '$MQ' land lane/four --test-cmd 'sh test.sh'"
assert_rc "$RC" 0 "$OUT"

CASE="merge-queue: unrelated dirty, staged and untracked files in main do not block, and are untouched"
L5="$(cd "$M" && bash "$LANES" create five | sed -n 's/.*path=//p')"
lane_commit "$L5" f.txt f
printf 'dirty edit\n' > "$M/d.txt"                       # modified, tracked, unrelated
printf 'staged edit\n' > "$M/test2.txt"; git -C "$M" add test2.txt   # staged new file
printf 'scratch\n' > "$M/notes.tmp"                       # untracked
run bash -c "cd '$M' && bash '$MQ' land lane/five --test-cmd 'sh test.sh'"
expect_rc "$RC" 0 "$OUT"
[ "$(cat "$M/f.txt")" = "f" ] || fail "lane file not moved forward in main"
[ "$(cat "$M/d.txt")" = "dirty edit" ] || fail "unrelated dirty file was touched"
[ "$(cat "$M/notes.tmp")" = "scratch" ] || fail "untracked file was touched"
git -C "$M" diff --cached --name-only | grep -qx test2.txt || fail "staged unrelated file lost its staging"
git -C "$M" diff --name-only | grep -qx d.txt || fail "d.txt no longer shows as modified"
git -C "$M" diff --name-only | grep -qx f.txt && fail "f.txt shows as modified after landing"
git -C "$M" diff --cached --name-only | grep -qx f.txt && fail "f.txt shows as staged after landing"
bash -c "cd '$M' && bash '$LANES' remove five" >/dev/null
ok

CASE="merge-queue: a dirty file in main on a lane path is refused (exit 6), nothing moves"
L6="$(cd "$M" && bash "$LANES" create six | sed -n 's/.*path=//p')"
lane_commit "$L6" d.txt "lane d"
before="$(git -C "$M" rev-parse main)"
run bash -c "cd '$M' && bash '$MQ' land lane/six --test-cmd 'sh test.sh'"
[ "$RC" -eq 6 ] || fail "expected exit 6, got $RC: $OUT"
printf '%s' "$OUT" | grep -q 'dirty: d.txt' || fail "overlapping path not named: $OUT"
[ "$(git -C "$M" rev-parse main)" = "$before" ] || fail "main moved despite the overlap"
[ "$(cat "$M/d.txt")" = "dirty edit" ] || fail "the dirty file was overwritten"
ok

CASE="merge-queue: an untracked file in main where the lane adds a file is refused (exit 6)"
L7="$(cd "$M" && bash "$LANES" create seven | sed -n 's/.*path=//p')"
lane_commit "$L7" notes.tmp "lane notes"
run bash -c "cd '$M' && bash '$MQ' land lane/seven --test-cmd 'sh test.sh'"
[ "$RC" -eq 6 ] || fail "expected exit 6, got $RC: $OUT"
[ "$(cat "$M/notes.tmp")" = "scratch" ] || fail "the untracked file was overwritten"
ok

CASE="merge-queue: main dirtied on a lane path during the test run -> refused before the swap"
git -C "$M" checkout -q -- d.txt; git -C "$M" reset -q test2.txt; rm -f "$M/test2.txt" "$M/notes.tmp"
before="$(git -C "$M" rev-parse main)"
dirtier="printf 'late edit\\n' > '$M/d.txt'; sh test.sh"
run bash -c "cd '$M' && bash '$MQ' land lane/six --test-cmd \"$dirtier\""
[ "$RC" -eq 6 ] || fail "expected exit 6, got $RC: $OUT"
[ "$(git -C "$M" rev-parse main)" = "$before" ] || fail "main moved after a late overlap"
[ "$(cat "$M/d.txt")" = "late edit" ] || fail "the late edit was overwritten"
git -C "$M" checkout -q -- d.txt
ok

CASE="merge-queue: pipeline.parallel.lane_setup runs in the clean checkout before the tests"
mkdir -p "$M/.claude"
printf '{"pipeline": {"parallel": {"lane_setup": "touch SETUP_DONE"}}}\n' > "$M/.claude/project.json"
run bash -c "cd '$M' && bash '$MQ' land lane/seven --dry-run --test-cmd 'test -e SETUP_DONE'"
assert_rc "$RC" 0 "$OUT"

CASE="merge-queue: a failing lane_setup refuses to land (exit 4)"
printf '{"pipeline": {"parallel": {"lane_setup": "exit 9"}}}\n' > "$M/.claude/project.json"
run bash -c "cd '$M' && bash '$MQ' land lane/seven --test-cmd 'sh test.sh'"
[ "$RC" -eq 4 ] || fail "expected exit 4, got $RC: $OUT"
rm -f "$M/.claude/project.json"
assert_match "$OUT" 'SETUP FAILED'

CASE="merge-queue: a busy queue refuses a second caller"
PARALLEL_STATE_DIR="$PARALLEL_STATE_DIR" bash "$LEASE" acquire merge-queue --holder other --ttl 60 >/dev/null
run bash -c "cd '$M' && bash '$MQ' land lane/two --test-cmd true"
expect_rc "$RC" 3 "$OUT"
bash "$LEASE" release merge-queue --holder other >/dev/null
ok

CASE="merge-queue: test.unit from .claude/project.json is used when no flag"
mkdir -p "$M/.claude"
printf '{"test": {"unit": "sh test.sh"}}\n' > "$M/.claude/project.json"
run bash -c "cd '$M' && bash '$MQ' land lane/two --dry-run"
[ "$RC" -eq 4 ] || fail "expected the configured suite to run and fail (exit 4), got $RC: $OUT"
assert_match "$OUT" 'sh test.sh'

CASE="merge-queue: a project post-checkout hook that rewrites a tracked file does not break the clean checkout"
# Seen 2026-11-15: a repo hook regenerated a tracked progress file on every
# checkout, so the queue's "clean" copy was dirty and git refused the rebase.
HK="$ROOT_TMP/hooks-mq"; mkdir -p "$HK"
printf '#!/bin/sh\necho regenerated >> "$(git rev-parse --show-toplevel)/c.txt"\n' > "$HK/post-checkout"; chmod +x "$HK/post-checkout"
git -C "$M" config core.hooksPath "$HK"
L7="$(cd "$M" && bash "$LANES" create hookcase | sed -n 's/.*path=//p')"
git -C "$L7" checkout -q -- . 2>/dev/null || true
lane_commit "$L7" g.txt g
printf 'main g-side\n' > "$M/h.txt"; git -C "$M" add h.txt; git -c core.hooksPath=/dev/null -C "$M" commit -q -m "main h"
run bash -c "cd '$M' && bash '$MQ' land lane/hookcase --test-cmd 'sh test.sh'"
git -C "$M" config --unset core.hooksPath
expect_rc "$RC" 0 "$OUT"
printf '%s' "$OUT" | grep -q 'LANDED' || fail "no LANDED line: $OUT"
ok

CASE="merge-queue: every verdict is logged"
run bash "$MQ" log 20
printf '%s' "$OUT" | grep -q '"result":"conflict"' || fail "conflict verdict missing"
assert_match "$OUT" '"result":"target-moved"'

CASE="merge-queue: a piped refusal still leaves its exit code in the verdict file"
run bash -c "cd '$M' && bash '$MQ' land lane/two --test-cmd 'sh test.sh' | tail -1"
expect_rc "$RC" 0 "$OUT"   # the pipe hides the 4 ...
grep -q '"exit": 4' "$PARALLEL_STATE_DIR/merge-queue.verdict.json" || fail "verdict file lacks exit 4: $(cat "$PARALLEL_STATE_DIR/merge-queue.verdict.json" 2>/dev/null)"
grep -q '"result": "tests-failed"' "$PARALLEL_STATE_DIR/merge-queue.verdict.json" || fail "verdict file lacks the result"
ok

CASE="merge-queue: --verdict-file writes there; a busy queue records busy/3"
PARALLEL_STATE_DIR="$PARALLEL_STATE_DIR" bash "$LEASE" acquire merge-queue --holder other --ttl 60 >/dev/null
run bash -c "cd '$M' && bash '$MQ' land lane/two --test-cmd true --verdict-file '$ROOT_TMP/vf.json'"
bash "$LEASE" release merge-queue --holder other >/dev/null
expect_rc "$RC" 3 "$OUT"
grep -q '"exit": 3' "$ROOT_TMP/vf.json" || fail "verdict file lacks exit 3: $(cat "$ROOT_TMP/vf.json" 2>/dev/null)"
grep -q '"result": "busy"' "$ROOT_TMP/vf.json" || fail "verdict file lacks result busy"
ok

# ── merge-queue.sh: gate logging, override warning, multi-branch land ────────
export PARALLEL_STATE_DIR="$ROOT_TMP/state-mq2"
N="$(new_repo mq2)"
printf 'old\n' > "$N/x.txt"; printf 'old\n' > "$N/y.txt"
printf '#!/bin/sh\ntest "$(cat x.txt)" = "$(cat y.txt)"\n' > "$N/pin.sh"
git -C "$N" add -A; git -C "$N" commit -q -m "pinned pair"
mkdir -p "$N/.claude"
printf '{"pipeline": {"parallel": {"gate_command": "sh pin.sh"}}}\n' > "$N/.claude/project.json"
LX="$(cd "$N" && bash "$LANES" create x | sed -n 's/.*path=//p')"
LY="$(cd "$N" && bash "$LANES" create y | sed -n 's/.*path=//p')"
lane_commit "$LX" x.txt new
lane_commit "$LY" y.txt new

CASE="merge-queue: a configured gate is logged as test_cmd, override false"
run bash -c "cd '$N' && bash '$MQ' land lane/x --dry-run"
[ "$RC" -eq 4 ] || fail "x alone should fail the pinned gate (exit 4), got $RC: $OUT"
tail -1 "$PARALLEL_STATE_DIR/merge-queue.jsonl" | grep -q '"test_cmd":"sh pin.sh"' || fail "test_cmd not logged: $(tail -1 "$PARALLEL_STATE_DIR/merge-queue.jsonl")"
tail -1 "$PARALLEL_STATE_DIR/merge-queue.jsonl" | grep -q '"test_cmd_override":false' || fail "override flag wrong"
printf '%s' "$OUT" | grep -q WARNING && fail "warned without an override"
ok

CASE="merge-queue: --test-cmd over a configured gate warns and logs test_cmd_override:true"
run bash -c "cd '$N' && bash '$MQ' land lane/x --dry-run --test-cmd true"
expect_rc "$RC" 0 "$OUT"
printf '%s' "$OUT" | grep -q 'WARNING: --test-cmd overrides the configured gate (sh pin.sh)' || fail "no override warning: $OUT"
tail -1 "$PARALLEL_STATE_DIR/merge-queue.jsonl" | grep -q '"test_cmd":"true"' || fail "overriding command not logged"
tail -1 "$PARALLEL_STATE_DIR/merge-queue.jsonl" | grep -q '"test_cmd_override":true' || fail "override not recorded"
ok

CASE="merge-queue: --test-cmd with no configured gate does not warn"
NG="$(new_repo mq3)"
LG="$(cd "$NG" && bash "$LANES" create g | sed -n 's/.*path=//p')"
lane_commit "$LG" g.txt g
run bash -c "cd '$NG' && bash '$MQ' land lane/g --dry-run --test-cmd true"
expect_rc "$RC" 0 "$OUT"
printf '%s' "$OUT" | grep -q WARNING && fail "warned although no gate is configured: $OUT"
tail -1 "$PARALLEL_STATE_DIR/merge-queue.jsonl" | grep -q '"test_cmd_override":false' || fail "override flagged without a configured gate"
ok

CASE="merge-queue: two interdependent lanes each fail the gate alone, and land together in one call"
run bash -c "cd '$N' && bash '$MQ' land lane/y --dry-run"
[ "$RC" -eq 4 ] || fail "y alone should fail (exit 4), got $RC: $OUT"
before="$(git -C "$N" rev-parse main)"
run bash -c "cd '$N' && bash '$MQ' land lane/x lane/y"
expect_rc "$RC" 0 "$OUT"
printf '%s' "$OUT" | grep -q 'LANDED: lane/x lane/y -> main' || fail "no combined LANDED line: $OUT"
[ "$(git -C "$N" rev-list --count "$before..main")" -eq 2 ] || fail "expected both lane commits on main"
[ "$(cat "$N/x.txt")" = new ] && [ "$(cat "$N/y.txt")" = new ] || fail "main worktree not moved forward"
[ "$(grep -c '"result":"landed"' "$PARALLEL_STATE_DIR/merge-queue.jsonl")" -eq 1 ] || fail "expected exactly one landed verdict"
tail -1 "$PARALLEL_STATE_DIR/merge-queue.jsonl" | grep -q '"branch":"lane/x lane/y"' || fail "verdict does not name both branches"
ok

CASE="merge-queue: a multi-branch land is all or none -- a failing gate moves nothing"
LP1="$(cd "$N" && bash "$LANES" create p1 | sed -n 's/.*path=//p')"
LP2="$(cd "$N" && bash "$LANES" create p2 | sed -n 's/.*path=//p')"
lane_commit "$LP1" p1.txt one
lane_commit "$LP2" y.txt broken
before="$(git -C "$N" rev-parse main)"
run bash -c "cd '$N' && bash '$MQ' land lane/p1 lane/p2"
[ "$RC" -eq 4 ] || fail "expected exit 4, got $RC: $OUT"
[ "$(git -C "$N" rev-parse main)" = "$before" ] || fail "main moved although the combined gate failed"
[ ! -f "$N/p1.txt" ] || fail "the first lane landed alone"
ok

CASE="merge-queue: a multi-branch land that conflicts between lanes exits 2 and moves nothing"
lane_commit "$LP1" y.txt "p1 version"
run bash -c "cd '$N' && bash '$MQ' land lane/p1 lane/p2 --test-cmd true"
[ "$RC" -eq 2 ] || fail "expected exit 2, got $RC: $OUT"
printf '%s' "$OUT" | grep -q 'conflict: y.txt' || fail "conflict file not named: $OUT"
[ "$(git -C "$N" rev-parse main)" = "$before" ] || fail "main moved on a conflict"
[ "$(git -C "$N" worktree list | wc -l)" -eq 5 ] || fail "temp worktree left behind: $(git -C "$N" worktree list)"
ok

CASE="merge-queue: a single branch still lands as before (exit 0, one branch in the verdict)"
run bash -c "cd '$N' && bash '$MQ' land lane/p1 --test-cmd true"
expect_rc "$RC" 0 "$OUT"
tail -1 "$PARALLEL_STATE_DIR/merge-queue.jsonl" | grep -q '"branch":"lane/p1"' || fail "single-branch verdict changed"
ok

CASE="merge-queue: --test-cmd identical to the configured gate does not warn or flag an override"
run bash -c "cd '$N' && bash '$MQ' land lane/p1 --dry-run --test-cmd 'sh pin.sh'"
expect_rc "$RC" 0 "$OUT"
printf '%s' "$OUT" | grep -q WARNING && fail "warned although the command equals the gate: $OUT"
tail -1 "$PARALLEL_STATE_DIR/merge-queue.jsonl" | grep -q '"test_cmd_override":false' || fail "override flagged for an identical command"
ok

CASE="merge-queue: a test_cmd with quote, backslash, tab and newline is logged as valid JSON and round-trips exactly"
PYB="$(bash "$PLUGIN_ROOT/scripts/py.sh" --print)"
WEIRD=$'true # q"uote back\\slash\ttab\nexit 0'
run bash -c 'cd "$1" && shift && bash "$@"' _ "$NG" "$MQ" land lane/g --dry-run --test-cmd "$WEIRD"
expect_rc "$RC" 0 "$OUT"
LASTLINE="$(tail -1 "$PARALLEL_STATE_DIR/merge-queue.jsonl")"
GOT="$(printf '%s' "$LASTLINE" | "$PYB" -c 'import json,sys; sys.stdout.buffer.write(json.loads(sys.stdin.read())["test_cmd"].encode())')" || fail "log line is not valid JSON: $LASTLINE"
[ "$GOT" = "$WEIRD" ] || fail "test_cmd did not round-trip: got [$GOT]"
ok

# ── lanes.sh remove: content landed combined; verify: scope check ────────────
export PARALLEL_STATE_DIR="$ROOT_TMP/state-lanes2"
CASE="lanes: remove accepts a lane whose content landed combined with other changes"
LS="$(cd "$N" && bash "$LANES" create s | sed -n 's/.*path=//p')"
lane_commit "$LS" s.txt s
printf 's\n' > "$N/s.txt"; printf 'other\n' > "$N/t.txt"; git -C "$N" add s.txt t.txt; git -C "$N" commit -q -m "s and t together"
[ "$(git -C "$N" cherry main lane/s | grep -c '^+')" -eq 1 ] || fail "setup: cherry should still list the lane commit"
run bash -c "cd '$N' && bash '$LANES' remove s"
expect_rc "$RC" 0 "$OUT"
git -C "$N" show-ref --verify --quiet refs/heads/lane/s && fail "branch still present (output: $OUT; branches: $(git -C "$N" branch --list 'lane/*' | tr '\n' ' '))"
ok

CASE="lanes: remove still refuses when the lane's content is not on the target"
LU="$(cd "$N" && bash "$LANES" create u | sed -n 's/.*path=//p')"
lane_commit "$LU" u.txt mine
printf 'theirs\n' > "$N/u.txt"; git -C "$N" add u.txt; git -C "$N" commit -q -m "u differently"
run bash -c "cd '$N' && bash '$LANES' remove u"
[ "$RC" -eq 1 ] || fail "expected refusal (exit 1), got $RC: $OUT"
assert_match "$OUT" 'not on main'

CASE="lanes: verify passes when the lane stays inside its owned globs"
LV="$(cd "$N" && bash "$LANES" create v | sed -n 's/.*path=//p')"
mkdir -p "$LV/src/deep" "$LV/docs"
printf 'a\n' > "$LV/src/deep/a.txt"; printf 'b\n' > "$LV/docs/b.txt"
git -C "$LV" add -A; git -C "$LV" commit -q -m "v work"
run bash -c "cd '$N' && bash '$LANES' verify v --owned 'src/*' 'docs/*'"
assert_rc "$RC" 0 "$OUT"

CASE="lanes: verify fails naming the files outside the owned globs"
run bash -c "cd '$N' && bash '$LANES' verify v --owned 'src/*'"
[ "$RC" -eq 1 ] || fail "expected exit 1, got $RC: $OUT"
printf '%s' "$OUT" | grep -q 'docs/b.txt' || fail "out-of-scope file not named: $OUT"
printf '%s' "$OUT" | grep -q 'src/deep/a.txt' && fail "an owned file was reported"
ok

CASE="lanes: verify fails closed (exit 2, never 'in scope') when the diff itself fails"
run bash -c "cd '$N' && bash '$LANES' verify v --owned 'src/*' 'docs/*' --base doesnotexist"
[ "$RC" -eq 2 ] || fail "expected exit 2 for a bad --base, got $RC: $OUT"
printf '%s' "$OUT" | grep -q 'in scope' && fail "a failed diff was reported in scope: $OUT"
ok

CASE="lanes: verify without --owned is a usage error"
run bash -c "cd '$N' && bash '$LANES' verify v"
assert_rc "$RC" 2 "$OUT"

# ── runner.sh (fake claude) ─────────────────────────────────────────────────
export PARALLEL_STATE_DIR="$ROOT_TMP/state-runner"
FAKE="$ROOT_TMP/fakeclaude"
cat > "$FAKE" <<'EOF'
#!/usr/bin/env bash
# Fake `claude -p --output-format json`: logs argv, answers in the measured shape.
[ "${1:-}" = "--help" ] && { printf '  --permission-prompts <target>\n  --strict-mcp-config\n  --exclude-dynamic-system-prompt-sections\n  --tools <tools...>\n'; exit 0; }
stdin="$(cat)"   # the runner sends the prompt on stdin, never as an argument
printf '%s PROMPT: %s' "$*" "$stdin" | tr '\n' ' ' >> "$FAKE_LOG"; echo >> "$FAKE_LOG"   # one line per call
sid="new-$(date +%s%N)"
prev=""
while [ $# -gt 0 ]; do [ "$1" = "--resume" ] && { sid="$2"; prev=1; }; shift; done
ctx="${FAKE_CTX:-1000}"
den='[]'; [ -n "${FAKE_DENY:-}" ] && den='[{"tool_name":"Bash","tool_use_id":"x","tool_input":{"command":"rm -rf build"}}]'
printf '{"type":"result","subtype":"success","is_error":false,"session_id":"%s","num_turns":1,"total_cost_usd":0.01,"result":"done %s","permission_denials":%s,"usage":{"input_tokens":5,"cache_read_input_tokens":%s,"cache_creation_input_tokens":0,"output_tokens":10,"iterations":[{"input_tokens":5,"cache_read_input_tokens":%s,"cache_creation_input_tokens":0,"output_tokens":10}]}}\n' "$sid" "$prev" "$den" "$ctx" "$ctx"
EOF
chmod +x "$FAKE"
export RUNNER_CLAUDE_BIN="$FAKE" FAKE_LOG="$ROOT_TMP/fake.log"
W="$ROOT_TMP/runner-cwd"; mkdir -p "$W"
CFG="$ROOT_TMP/runner-proj"; mkdir -p "$CFG/.claude"
export CLAUDE_PROJECT_DIR="$CFG"   # no project.json yet: models.runner defaults to sonnet

CASE="runner: no project.json -> the runner runs on sonnet"
run bash "$RUNNER" start m0 --prompt "x" --cwd "$W" --allowed-tools Read
expect_rc "$RC" 0 "$OUT"
tail -1 "$FAKE_LOG" | grep -q -- '--model sonnet' || fail "expected --model sonnet: $(tail -1 "$FAKE_LOG")"
grep -q '"model": "sonnet"' "$PARALLEL_STATE_DIR/runners/m0/status.json" || fail "model not recorded"
grep -q '"model_source": "default"' "$PARALLEL_STATE_DIR/runners/m0/status.json" || fail "source not default"
ok

CASE="runner: models.runner in project.json is used, recorded, and kept on resume"
printf '{"models": {"runner": "opus"}}\n' > "$CFG/.claude/project.json"
run bash "$RUNNER" start m1 --prompt "x" --cwd "$W" --allowed-tools Read
expect_rc "$RC" 0 "$OUT"
tail -1 "$FAKE_LOG" | grep -q -- '--model opus' || fail "expected --model opus"
printf '{"models": {"runner": "haiku"}}\n' > "$CFG/.claude/project.json"
run bash "$RUNNER" resume m1 --prompt "y"
expect_rc "$RC" 0 "$OUT"
tail -1 "$FAKE_LOG" | grep -q -- '--model opus' || fail "resume did not keep the recorded model"
ok

CASE="runner: models.cap lowers models.runner"
printf '{"models": {"runner": "opus", "cap": "sonnet"}}\n' > "$CFG/.claude/project.json"
run bash "$RUNNER" start m2 --prompt "x" --cwd "$W" --allowed-tools Read
expect_rc "$RC" 0 "$OUT"
tail -1 "$FAKE_LOG" | grep -q -- '--model sonnet' || fail "cap not applied"
ok

CASE="runner: --model overrides config, then rotation returns to the configured model"
printf '{"models": {"runner": "haiku"}}\n' > "$CFG/.claude/project.json"
run bash "$RUNNER" start m3 --prompt "x" --cwd "$W" --allowed-tools Read --model opus
expect_rc "$RC" 0 "$OUT"
tail -1 "$FAKE_LOG" | grep -q -- '--model opus' || fail "override ignored"
grep -q '"model_source": "flag"' "$PARALLEL_STATE_DIR/runners/m3/status.json" || fail "source not flag"
run env FAKE_CTX=360000 bash "$RUNNER" resume m3 --prompt "y"
expect_rc "$RC" 0 "$OUT"
tail -1 "$FAKE_LOG" | grep -q -- '--model opus' || fail "resume did not keep the override model"
run bash "$RUNNER" resume m3 --prompt "z"
expect_rc "$RC" 0 "$OUT"
tail -1 "$FAKE_LOG" | grep -q -- '--model haiku' || fail "fresh session after rotation did not use models.runner: $(tail -1 "$FAKE_LOG")"
ok
rm -f "$CFG/.claude/project.json"

CASE="runner: start without an allowlist is refused"
run bash "$RUNNER" start w1 --prompt hi --cwd "$W"
assert_rc "$RC" 2 "$OUT"

CASE="runner: start records the session id, flags and context"
run bash "$RUNNER" start w1 --prompt "task one" --cwd "$W" --allowed-tools "Read,Edit" --model sonnet --max-turns 30
expect_rc "$RC" 0 "$OUT"
S1="$(grep -m1 '"session_id"' "$PARALLEL_STATE_DIR/runners/w1/status.json" | sed 's/.*"session_id": "\([^"]*\)".*/\1/')"
[ -n "$S1" ] || fail "no session_id recorded"
tail -1 "$FAKE_LOG" | grep -q -- '--output-format json' || fail "json output not requested"
tail -1 "$FAKE_LOG" | grep -q -- '--permission-mode dontAsk' || fail "default permission mode not dontAsk"
tail -1 "$FAKE_LOG" | grep -q -- '--permission-prompts none' || fail "--permission-prompts none not passed"
tail -1 "$FAKE_LOG" | grep -q -- '--allowed-tools Read,Edit' || fail "allowlist not passed"
tail -1 "$FAKE_LOG" | grep -q -- '--max-turns 30' || fail "max-turns not passed"
[ "$(wc -l < "$PARALLEL_STATE_DIR/runners/w1/events.jsonl")" -eq 1 ] || fail "events.jsonl should have one line"
ok

CASE="runner: --max-turns defaults to 200 when not given"
run bash "$RUNNER" start wturns --prompt "t" --cwd "$W" --allowed-tools Read
expect_rc "$RC" 0 "$OUT"
tail -1 "$FAKE_LOG" | grep -q -- '--max-turns 200' || fail "default max-turns is not 200: $(tail -1 "$FAKE_LOG")"
ok

CASE="runner: resume below the threshold passes --resume <id>"
run env FAKE_CTX=100000 bash "$RUNNER" resume w1 --prompt "task two"
expect_rc "$RC" 0 "$OUT"
tail -1 "$FAKE_LOG" | grep -q -- "--resume $S1" || fail "did not resume $S1: $(tail -1 "$FAKE_LOG")"
grep -q '"context_tokens": 100015' "$PARALLEL_STATE_DIR/runners/w1/status.json" || fail "context not recorded from usage.iterations"
ok

CASE="runner: past rotate_at, resume writes a hand-off and starts a fresh session"
run env FAKE_CTX=360000 bash "$RUNNER" resume w1 --prompt "task three"
expect_rc "$RC" 0 "$OUT"
run env FAKE_CTX=1000 bash "$RUNNER" resume w1 --prompt "task four"
expect_rc "$RC" 0 "$OUT"
printf '%s' "$OUT" | grep -q 'hand-off note' || fail "no rotation reported: $OUT"
[ -f "$PARALLEL_STATE_DIR/runners/w1/handoff-1.md" ] || fail "handoff-1.md not written"
tail -1 "$FAKE_LOG" | grep -q -- '--resume' && fail "fresh session after rotation still passed --resume"
tail -1 "$FAKE_LOG" | grep -q 'Its hand-off note' || fail "the new session was not seeded with the hand-off"
S2="$(grep -m1 '"session_id"' "$PARALLEL_STATE_DIR/runners/w1/status.json" | sed 's/.*"session_id": "\([^"]*\)".*/\1/')"
[ -n "$S2" ] && [ "$S2" != "$S1" ] || fail "new session id not recorded ($S1 -> $S2)"
grep -c '"session_id"' "$PARALLEL_STATE_DIR/runners/w1/status.json" | grep -q '[3-9]' || fail "session history not kept"
ok

CASE="runner: permission denials exit 3, print DENIED and are logged"
run env FAKE_DENY=1 bash "$RUNNER" resume w1 --prompt "task five"
expect_rc "$RC" 3 "$OUT"
printf '%s' "$OUT" | grep -q 'DENIED: Bash' || fail "no DENIED line: $OUT"
[ -s "$PARALLEL_STATE_DIR/runners/w1/denials.jsonl" ] || fail "denials.jsonl empty"
ok

CASE="runner: a denial exits 3 even when the claude process also exits non-zero"
FAKE_RC="$ROOT_TMP/fakeclaude-rc"
printf '#!/usr/bin/env bash\n"%s" "$@"; exit 1\n' "$FAKE" > "$FAKE_RC"; chmod +x "$FAKE_RC"
run env FAKE_DENY=1 RUNNER_CLAUDE_BIN="$FAKE_RC" bash "$RUNNER" resume w1 --prompt "task six"
assert_rc "$RC" 3 "$OUT"

CASE="runner: --task is recorded in status.json and on every later events line"
run bash "$RUNNER" start t1 --prompt "x" --cwd "$W" --allowed-tools Read --task T-42
expect_rc "$RC" 0 "$OUT"
grep -q '"task": "T-42"' "$PARALLEL_STATE_DIR/runners/t1/status.json" || fail "task not in status.json"
run bash "$RUNNER" resume t1 --prompt "y"
expect_rc "$RC" 0 "$OUT"
[ "$(grep -c '"task": "T-42"' "$PARALLEL_STATE_DIR/runners/t1/events.jsonl")" -eq 2 ] || fail "task not on both events lines: $(cat "$PARALLEL_STATE_DIR/runners/t1/events.jsonl")"
run bash "$RUNNER" resume t1 --prompt "z" --task T-43
expect_rc "$RC" 0 "$OUT"
tail -1 "$PARALLEL_STATE_DIR/runners/t1/events.jsonl" | grep -q '"task": "T-43"' || fail "a new --task was not recorded"
ok

CASE="runner: report aggregates calls, cost and denials by runner and by task"
run bash "$RUNNER" report --json
expect_rc "$RC" 0 "$OUT"
printf '%s' "$OUT" | "$(bash "$PLUGIN_ROOT/scripts/py.sh" --print)" -c '
import json, sys
r = json.load(sys.stdin)
t = r["by_task"]
assert t["T-42"]["calls"] == 2, t
assert t["T-43"]["calls"] == 1, t
assert abs(r["by_runner"]["t1"]["cost_usd"] - 0.03) < 1e-9, r["by_runner"]["t1"]
assert r["by_runner"]["w1"]["denials"] >= 2, r["by_runner"]["w1"]
assert r["total"]["calls"] == sum(v["calls"] for v in r["by_runner"].values())
' || fail "report totals wrong: $OUT"
run bash "$RUNNER" report
expect_rc "$RC" 0 "$OUT"
printf '%s' "$OUT" | grep -q 'by task' || fail "text report missing the by-task table"
assert_match "$OUT" 'T-42'

CASE="runner: lean start -- --tools, --strict-mcp-config, exclude-dynamic; prompt on stdin, not argv"
run bash "$RUNNER" start lean1 --prompt "do the lean thing" --cwd "$W" --allowed-tools Read
expect_rc "$RC" 0 "$OUT"
L="$(tail -1 "$FAKE_LOG")"
printf '%s' "$L" | grep -q -- '--tools Bash,Read,Edit,Write,Glob,Grep --strict-mcp-config' || fail "lean tool set not passed: $L"
printf '%s' "$L" | grep -q -- '--exclude-dynamic-system-prompt-sections' || fail "exclude-dynamic not passed: $L"
printf '%s' "$L" | grep -q 'PROMPT: do the lean thing' || fail "prompt not on stdin: $L"
printf '%s' "${L%% PROMPT:*}" | grep -q 'do the lean thing' && fail "prompt also passed as an argument: $L"
grep -q '"rotate_at": 180000' "$PARALLEL_STATE_DIR/runners/lean1/status.json" || fail "default rotate_at is not 180000"
tail -1 "$PARALLEL_STATE_DIR/runners/lean1/events.jsonl" | grep -q '"tools": "Bash,Read,Edit,Write,Glob,Grep"' || fail "tool set not on the events line"
ok

CASE="runner: --tools default passes neither --tools nor --strict-mcp-config"
run bash "$RUNNER" start lean2 --prompt "x" --cwd "$W" --allowed-tools Read --tools default
expect_rc "$RC" 0 "$OUT"
tail -1 "$FAKE_LOG" | grep -q -- '--tools\|--strict-mcp-config' && fail "default tool set still restricted: $(tail -1 "$FAKE_LOG")"
ok

CASE="runner: project default allowlist is used, + appends, and the list in force is on every events line"
printf '{"pipeline": {"parallel": {"runner": {"allowed_tools": "Read,Bash(git status:*)", "rotate_at": 200000}}}}\n' > "$CFG/.claude/project.json"
run bash "$RUNNER" start al1 --prompt "x" --cwd "$W"
expect_rc "$RC" 0 "$OUT"
tail -1 "$FAKE_LOG" | grep -q -- '--allowed-tools Read,Bash(git status:\*)' || fail "config allowlist not passed: $(tail -1 "$FAKE_LOG")"
grep -q '"rotate_at": 200000' "$PARALLEL_STATE_DIR/runners/al1/status.json" || fail "config rotate_at not used"
run bash "$RUNNER" resume al1 --prompt "y" --allowed-tools "+Bash(git diff:*)"
expect_rc "$RC" 0 "$OUT"
tail -1 "$FAKE_LOG" | grep -q -- '--allowed-tools Read,Bash(git status:\*),Bash(git diff:\*)' || fail "+ did not append: $(tail -1 "$FAKE_LOG")"
[ "$(grep -c '"allowed_tools"' "$PARALLEL_STATE_DIR/runners/al1/events.jsonl")" -eq 2 ] || fail "allowlist not on every events line"
tail -1 "$PARALLEL_STATE_DIR/runners/al1/events.jsonl" | grep -q 'git diff' || fail "events line does not show the widened list"
ok
rm -f "$CFG/.claude/project.json"

CASE="runner: a Bash(<prefix>/:*) entry that can never match is refused, naming it"
run bash "$RUNNER" start dead1 --prompt "x" --cwd "$W" --allowed-tools "Read,Bash(node research/tools/:*)"
expect_rc "$RC" 2 "$OUT"
printf '%s' "$OUT" | grep -q 'Bash(node research/tools/:\*)' || fail "offending entry not named: $OUT"
[ -f "$PARALLEL_STATE_DIR/runners/dead1/status.json" ] && grep -q '"session_id": "' "$PARALLEL_STATE_DIR/runners/dead1/status.json" && fail "a claude call ran despite the refusal"
ok

CASE="runner: verdict.json carries the exit code (3 on denial, 0 on success)"
run env FAKE_DENY=1 bash "$RUNNER" start vd1 --prompt "x" --cwd "$W" --allowed-tools Read
expect_rc "$RC" 3 "$OUT"
grep -q '"exit": 3' "$PARALLEL_STATE_DIR/runners/vd1/verdict.json" || fail "verdict.json lacks exit 3: $(cat "$PARALLEL_STATE_DIR/runners/vd1/verdict.json")"
grep -q '"result": "denied"' "$PARALLEL_STATE_DIR/runners/vd1/verdict.json" || fail "verdict.json lacks result denied"
run bash "$RUNNER" resume vd1 --prompt "y"
expect_rc "$RC" 0 "$OUT"
grep -q '"exit": 0' "$PARALLEL_STATE_DIR/runners/vd1/verdict.json" || fail "verdict.json not refreshed to exit 0"
ok

CASE="runner: resume --fresh hands off and starts a fresh session below rotate_at"
run bash "$RUNNER" start fr1 --prompt "x" --cwd "$W" --allowed-tools Read
expect_rc "$RC" 0 "$OUT"
run bash "$RUNNER" resume fr1 --prompt "fix-up: shas abc123, review text" --fresh
expect_rc "$RC" 0 "$OUT"
[ -f "$PARALLEL_STATE_DIR/runners/fr1/handoff-1.md" ] || fail "--fresh wrote no hand-off"
tail -1 "$FAKE_LOG" | grep -q -- '--resume' && fail "--fresh still resumed the old session"
tail -1 "$FAKE_LOG" | grep -q 'fix-up: shas abc123' || fail "the fresh session did not get the prompt"
ok

CASE="runner: status lists every runner"
run bash "$RUNNER" status
assert_match "$OUT" 'w1'

echo
echo "test-parallel.sh: all cases ok"
