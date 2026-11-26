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
printf '{"pipeline": {"parallel": {"lane_setup": "mkdir -p node_modules/leftpad"}}}\n' > "$R/.claude/project.json"
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

CASE="lanes: check reports a lane set up under a lane_setup that has since changed"
printf '{"pipeline": {"parallel": {"lane_setup": "mkdir -p node_modules && touch node_modules/.package-lock.json && true"}}}
' > "$R/.claude/project.json"
run bash -c "cd '$R' && bash '$LANES' check '$SP'"
expect_rc "$RC" 3 "$OUT"
assert_match "$OUT" 'lane_setup changed'
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
if [ "${1:-}" = "--help" ]; then
  printf '  --permission-prompts <target>\n  --exclude-dynamic-system-prompt-sections\n  --tools <tools...>\n'
  [ -n "${FAKE_NO_STRICT:-}" ] || printf '  --strict-mcp-config\n'
  exit 0
fi
stdin="$(cat)"   # the runner sends the prompt on stdin, never as an argument
printf '%s PROMPT: %s' "$*" "$stdin" | tr '\n' ' ' >> "$FAKE_LOG"; echo >> "$FAKE_LOG"   # one line per call
sid="new-$(date +%s%N)"
prev=""
while [ $# -gt 0 ]; do [ "$1" = "--resume" ] && { sid="$2"; prev=1; }; shift; done
ctx="${FAKE_CTX:-1000}"
den='[]'; [ -n "${FAKE_DENY:-}" ] && den='[{"tool_name":"Bash","tool_use_id":"x","tool_input":{"command":"rm -rf build"}}]'
[ -z "${FAKE_DENY_JSON:-}" ] || den="$FAKE_DENY_JSON"
if [ -n "${FAKE_NO_TOTAL:-}" ]; then   # an error result with no total_cost_usd
  printf '{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"%s"}\n' "$sid"
  exit 1
fi
# Like the real CLI, total_cost_usd is the session's running total: $0.01 a call.
n=$(( $(cat "$FAKE_LOG.calls.$sid" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_LOG.calls.$sid"
n="$(awk -v n="$n" 'BEGIN { printf "%.2f", n / 100 }')"
printf '{"type":"result","subtype":"success","is_error":false,"session_id":"%s","num_turns":1,"total_cost_usd":%s,"result":"done %s","permission_denials":%s,"usage":{"input_tokens":5,"cache_read_input_tokens":%s,"cache_creation_input_tokens":0,"output_tokens":10,"iterations":[{"input_tokens":5,"cache_read_input_tokens":%s,"cache_creation_input_tokens":0,"output_tokens":10}]}}\n' "$sid" "$n" "$prev" "$den" "$ctx" "$ctx"
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
grep -q '"session_cost_usd": 0.03' "$PARALLEL_STATE_DIR/runners/t1/events.jsonl" || fail "running session total not recorded: $(cat "$PARALLEL_STATE_DIR/runners/t1/events.jsonl")"
grep -q '"cost_usd": 0.03' "$PARALLEL_STATE_DIR/runners/t1/status.json" || fail "status cost should be 0.03 (per-call deltas), not the summed running totals: $(cat "$PARALLEL_STATE_DIR/runners/t1/status.json")"
run bash "$RUNNER" report
expect_rc "$RC" 0 "$OUT"
printf '%s' "$OUT" | grep -q 'by task' || fail "text report missing the by-task table"
assert_match "$OUT" 'T-42'

CASE="runner: report reads lines from before session_cost_usd as running totals"
mkdir -p "$PARALLEL_STATE_DIR/runners/legacy"
printf '%s\n' '{"ts":"t1","mode":"fresh","rc":0,"session_id":"L","cost_usd":0.3}' \
  '{"ts":"t2","mode":"resume","rc":0,"session_id":"L","cost_usd":1.25}' \
  '{"ts":"t3","mode":"resume","rc":0,"session_id":"L","cost_usd":1.87}' \
  '{"ts":"t4","mode":"fresh","rc":0,"session_id":"M","cost_usd":0.5}' > "$PARALLEL_STATE_DIR/runners/legacy/events.jsonl"
run bash "$RUNNER" report --json
expect_rc "$RC" 0 "$OUT"
printf '%s' "$OUT" | "$(bash "$PLUGIN_ROOT/scripts/py.sh" --print)" -c '
import json, sys
c = json.load(sys.stdin)["by_runner"]["legacy"]["cost_usd"]
assert abs(c - 2.37) < 1e-9, c
' || fail "legacy running totals were summed: $OUT"
rm -rf "$PARALLEL_STATE_DIR/runners/legacy"
ok

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

CASE="runner: a claude without --strict-mcp-config gets neither --tools nor it, with a warning"
FAKE_NO_STRICT=1 run bash "$RUNNER" start lean3 --prompt "x" --cwd "$W" --allowed-tools Read
expect_rc "$RC" 0 "$OUT"
tail -1 "$FAKE_LOG" | grep -q -- '--tools' && fail "--tools passed without --strict-mcp-config: $(tail -1 "$FAKE_LOG")"
assert_match "$OUT" 'lacks --strict-mcp-config'

CASE="runner: a runner with no recorded tool set is told how to move to the lean one"
"$(bash "$PLUGIN_ROOT/scripts/py.sh" --print)" -c '
import json, sys
p = sys.argv[1]; s = json.load(open(p)); s.pop("tools", None); json.dump(s, open(p, "w"))
' "$PARALLEL_STATE_DIR/runners/lean3/status.json"
run bash "$RUNNER" resume lean3 --prompt "y"
expect_rc "$RC" 0 "$OUT"
assert_match "$OUT" 'no recorded tool set'

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

CASE="runner: a refusal before any claude call leaves a verdict of that refusal, never the last call's"
run bash "$RUNNER" start vs1 --prompt "x" --cwd "$W" --allowed-tools Read
expect_rc "$RC" 0 "$OUT"
run bash -c "bash '$RUNNER' resume vs1 --prompt y --allowed-tools '+Bash(node a/:*)' | tail -1"
expect_rc "$RC" 0 "$OUT"   # the pipe hides the 2 ...
grep -q '"exit": 2' "$PARALLEL_STATE_DIR/runners/vs1/verdict.json" || fail "stale verdict after a refusal: $(cat "$PARALLEL_STATE_DIR/runners/vs1/verdict.json")"
ok

CASE="runner: an empty --allowed-tools is refused on start and on resume"
run bash "$RUNNER" start em1 --prompt "x" --cwd "$W" --allowed-tools ""
expect_rc "$RC" 2 "$OUT"
run bash "$RUNNER" resume vs1 --prompt "y" --allowed-tools ""
expect_rc "$RC" 2 "$OUT"
grep -q '"allowed_tools": "Read"' "$PARALLEL_STATE_DIR/runners/vs1/status.json" || fail "an empty flag wiped the recorded allowlist"
ok

CASE="runner: + appends without repeating an entry already listed"
run bash "$RUNNER" resume vs1 --prompt "y" --allowed-tools "+Bash(ls:*)"
run bash "$RUNNER" resume vs1 --prompt "z" --allowed-tools "+Bash(ls:*)"
expect_rc "$RC" 0 "$OUT"
grep -q '"allowed_tools": "Read,Bash(ls:\*)"' "$PARALLEL_STATE_DIR/runners/vs1/status.json" || fail "duplicate entry: $(grep allowed_tools "$PARALLEL_STATE_DIR/runners/vs1/status.json")"
ok

CASE="runner: a denied first call after a rotation still clears the hand-off (no re-seeding)"
run bash "$RUNNER" resume vs1 --prompt "a" --fresh
run env FAKE_DENY=1 bash "$RUNNER" resume vs1 --prompt "b" --fresh
expect_rc "$RC" 3 "$OUT"
grep -q '"pending_handoff": null' "$PARALLEL_STATE_DIR/runners/vs1/status.json" || fail "pending_handoff not cleared after a denied call"
ok

CASE="runner: a fresh call gets the default budget of 5"
run bash "$RUNNER" start bg1 --prompt "x" --cwd "$W" --allowed-tools Read
expect_rc "$RC" 0 "$OUT"
tail -1 "$FAKE_LOG" | grep -q -- '--max-budget-usd 5 ' || fail "no default budget: $(tail -1 "$FAKE_LOG")"
ok

CASE="runner: a resume's budget is the session's recorded spend plus the allowance"
run bash "$RUNNER" resume bg1 --prompt "y"
expect_rc "$RC" 0 "$OUT"
tail -1 "$FAKE_LOG" | grep -q -- '--max-budget-usd 5.01 ' || fail "wrong resume budget: $(tail -1 "$FAKE_LOG")"
ok

CASE="runner: config max_budget_usd applies, and a flag overrides it"
printf '{"pipeline": {"parallel": {"runner": {"max_budget_usd": 2}}}}\n' > "$CFG/.claude/project.json"
run bash "$RUNNER" start bg2 --prompt "x" --cwd "$W" --allowed-tools Read
tail -1 "$FAKE_LOG" | grep -q -- '--max-budget-usd 2 ' || fail "config budget not used: $(tail -1 "$FAKE_LOG")"
run bash "$RUNNER" start bg3 --prompt "x" --cwd "$W" --allowed-tools Read --max-budget-usd 9
tail -1 "$FAKE_LOG" | grep -q -- '--max-budget-usd 9 ' || fail "flag budget not used: $(tail -1 "$FAKE_LOG")"
rm -f "$CFG/.claude/project.json"
ok

CASE="runner: a budget that is not a positive number is refused"
run bash "$RUNNER" start bg4 --prompt "x" --cwd "$W" --allowed-tools Read --max-budget-usd 0
assert_rc "$RC" 2 "$OUT"

CASE="runner: resume lowers a recorded rotate_at above the ceiling and rotates"
sed -i 's/"rotate_at": 180000/"rotate_at": 350000/' "$PARALLEL_STATE_DIR/runners/bg1/status.json"
run env FAKE_CTX=200000 bash "$RUNNER" resume bg1 --prompt "grow"
run bash "$RUNNER" resume bg1 --prompt "next"
expect_rc "$RC" 0 "$OUT"
printf '%s' "$OUT" | grep -q 'rotating bg1' || fail "did not rotate: $OUT"
grep -q '"rotate_at": 180000' "$PARALLEL_STATE_DIR/runners/bg1/status.json" || fail "rotate_at not lowered"
ok

CASE="runner: a --rotate-at flag is kept on later resumes"
run bash "$RUNNER" resume bg1 --prompt "a" --rotate-at 250000
run bash "$RUNNER" resume bg1 --prompt "b"
expect_rc "$RC" 0 "$OUT"
grep -q '"rotate_at": 250000' "$PARALLEL_STATE_DIR/runners/bg1/status.json" || fail "flag rotate_at was lowered"
ok

CASE="runner: a configured rotate_at survives a resume where that config is not visible"
printf '{"pipeline": {"parallel": {"runner": {"rotate_at": 220000}}}}\n' > "$CFG/.claude/project.json"
run bash "$RUNNER" start rk1 --prompt "x" --cwd "$W" --allowed-tools Read
expect_rc "$RC" 0 "$OUT"
rm -f "$CFG/.claude/project.json"
mkdir -p "$ROOT_TMP/elsewhere"
run env CLAUDE_PROJECT_DIR="$ROOT_TMP/elsewhere" bash "$RUNNER" resume rk1 --prompt "y"
expect_rc "$RC" 0 "$OUT"
grep -q '"rotate_at": 220000' "$PARALLEL_STATE_DIR/runners/rk1/status.json" || fail "config rotate_at was lowered: $OUT"
ok

CASE="runner: a result with no total_cost_usd does not reset the session's recorded spend"
run bash "$RUNNER" start nt1 --prompt "a" --cwd "$W" --allowed-tools Read
run bash "$RUNNER" resume nt1 --prompt "b"
run env FAKE_NO_TOTAL=1 bash "$RUNNER" resume nt1 --prompt "c"
expect_rc "$RC" 1 "$OUT"
run bash "$RUNNER" resume nt1 --prompt "d"
expect_rc "$RC" 0 "$OUT"
tail -1 "$FAKE_LOG" | grep -q -- '--max-budget-usd 5.02 ' || fail "prior spend lost: $(tail -1 "$FAKE_LOG")"
run bash "$RUNNER" report --json
printf '%s' "$OUT" | "$(bash "$PLUGIN_ROOT/scripts/py.sh" --print)" -c '
import json, sys
c = json.load(sys.stdin)["by_runner"]["nt1"]["cost_usd"]
assert abs(c - 0.03) < 1e-9, c
' || fail "session spend counted twice: $OUT"
ok

CASE="lanes: held shows in list and unheld clears it"
H="$(new_repo held-repo)"
cd "$H"
run bash "$LANES" create h1
expect_rc "$RC" 0 "$OUT"
run bash "$LANES" create h2
run bash "$LANES" held h1 --until 2026-11-27
expect_rc "$RC" 0 "$OUT"
run bash "$LANES" held h2 --until lane/h1
expect_rc "$RC" 0 "$OUT"
run bash "$LANES" list
printf '%s' "$OUT" | grep -q 'held-until=2026-11-27' || fail "date hold not listed: $OUT"
printf '%s' "$OUT" | grep -q 'held-until=h1$' || fail "lane hold not listed: $OUT"
run bash "$LANES" unheld h1
run bash "$LANES" unheld h2
run bash "$LANES" list
printf '%s' "$OUT" | grep -q 'held-until' && fail "hold not cleared: $OUT"
ok

CASE="lanes: held refuses itself and an unknown lane"
run bash "$LANES" held h1 --until h1
expect_rc "$RC" 2 "$OUT"
run bash "$LANES" held h1 --until nosuch
assert_rc "$RC" 2 "$OUT"
cd "$PLUGIN_ROOT"

# ── landing integrity: review gate, flake triage, migration numbers ─────────
export PARALLEL_STATE_DIR="$ROOT_TMP/state-review"
V="$(new_repo review-repo)"
mkdir -p "$V/.claude"
printf '{"pipeline": {"parallel": {"gate_command": "sh test.sh", "review_required_paths": ["guard/", "**/*.env"]}}}\n' > "$V/.claude/project.json"
mk_lane() { cd "$1" && bash "$LANES" create "$2" | sed -n 's/.*path=//p'; }
add_commit() {  # add_commit <lane-path> <file> <content>
  mkdir -p "$1/$(dirname "$2")"; printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add -f "$2"; git -C "$1" commit -q -m "edit $2"
}
LV="$(mk_lane "$V" money)"
add_commit "$LV" guard/rules.txt v1

CASE="review gate: a protected path with no recorded review is refused (exit 7)"
before="$(git -C "$V" rev-parse main)"
run bash -c "cd '$V' && bash '$MQ' land lane/money"
expect_rc "$RC" 7 "$OUT"
printf '%s' "$OUT" | grep -q 'protected: guard/rules.txt' || fail "path not named: $OUT"
[ "$(git -C "$V" rev-parse main)" = "$before" ] || fail "main moved"
ok

CASE="review gate: reviewed refuses a non-sha and a commit that is not on the lane"
run bash -c "cd '$V' && bash '$LANES' reviewed money HEAD"
expect_rc "$RC" 2 "$OUT"
stray="$(git -C "$V" commit-tree -m stray "main^{tree}")"
run bash -c "cd '$V' && bash '$LANES' reviewed money $stray"
assert_rc "$RC" 1 "$OUT"

CASE="review gate: a head past the reviewed sha is refused, naming what changed after review"
seen="$(git -C "$LV" rev-parse HEAD)"
run bash -c "cd '$V' && bash '$LANES' reviewed money $seen --verdict accept"
expect_rc "$RC" 0 "$OUT"
add_commit "$LV" late.txt after
run bash -c "cd '$V' && bash '$MQ' land lane/money"
expect_rc "$RC" 7 "$OUT"
printf '%s' "$OUT" | grep -q 'changed after review: late.txt' || fail "late path not named: $OUT"
tail -1 "$PARALLEL_STATE_DIR/merge-queue.jsonl" | grep -q '"result":"refused-review"' || fail "verdict not logged"
ok

CASE="review gate: a later non-accept verdict refuses"
run bash -c "cd '$V' && bash '$LANES' reviewed money $(git -C "$LV" rev-parse HEAD) --verdict reject"
run bash -c "cd '$V' && bash '$MQ' land lane/money"
expect_rc "$RC" 7 "$OUT"
assert_match "$OUT" "verdict is 'reject'"

CASE="review gate: an accept of the current head lands"
run bash -c "cd '$V' && bash '$LANES' reviewed money $(git -C "$LV" rev-parse HEAD)"
run bash -c "cd '$V' && bash '$MQ' land lane/money"
assert_rc "$RC" 0 "$OUT"

CASE="review gate: a lane outside the protected paths needs no review"
LV2="$(mk_lane "$V" docs)"
add_commit "$LV2" notes.txt n
run bash -c "cd '$V' && bash '$MQ' land lane/docs"
assert_rc "$RC" 0 "$OUT"

CASE="review gate: a leading **/ matches a root file"
LV3="$(mk_lane "$V" envfile)"
add_commit "$LV3" prod.env x
run bash -c "cd '$V' && bash '$MQ' land lane/envfile"
assert_rc "$RC" 7 "$OUT"

CASE="review gate: a path git would C-quote is still protected"
LV4="$(mk_lane "$V" quoted)"
add_commit "$LV4" 'guard/pay"x.py' q
run bash -c "cd '$V' && bash '$MQ' land lane/quoted"
expect_rc "$RC" 7 "$OUT"
assert_match "$OUT" 'protected: guard/pay"x.py'

CASE="review gate: an entry that can never match refuses (braces, ./, a folder with no /)"
LV5="$(mk_lane "$V" deadentry)"
add_commit "$LV5" engine/ledger/post.py p
for entry in 'engine/ledger' './engine/' '/engine/' 'engine/{ledger,quals}/' 'engine/*/ledger'; do
  printf '{"pipeline": {"parallel": {"gate_command": "true", "review_required_paths": ["%s"]}}}\n' "$entry" > "$V/.claude/project.json"
  run bash -c "cd '$V' && bash '$MQ' land lane/deadentry --dry-run"
  [ "$RC" -eq 7 ] || fail "entry $entry: expected exit 7, got $RC: $OUT"
  printf '%s' "$OUT" | grep -q 'can never match' || fail "entry $entry: $OUT"
done
ok

CASE="review gate: file globs and folder globs ending in / are accepted and match"
add_commit "$LV5" lib/guard.js g
add_commit "$LV5" src/a/config.py c
for pair in '**/guard.js=lib/guard.js' 'src/*/config.py=src/a/config.py' 'eng*/ledger/=engine/ledger/post.py'; do
  entry="${pair%%=*}"
  printf '{"pipeline": {"parallel": {"gate_command": "true", "review_required_paths": ["%s"]}}}\n' "$entry" > "$V/.claude/project.json"
  run bash -c "cd '$V' && bash '$MQ' land lane/deadentry --dry-run"
  [ "$RC" -eq 7 ] || fail "entry $entry: expected exit 7, got $RC: $OUT"
  printf '%s' "$OUT" | grep -q "protected: ${pair#*=}" || fail "entry $entry: $OUT"
done
ok

CASE="review gate: a wrong-typed key refuses instead of switching the check off"
printf '{"pipeline": {"parallel": {"review_required_paths": "guard/"}}}\n' > "$V/.claude/project.json"
run bash -c "cd '$V' && bash '$MQ' land lane/envfile --test-cmd true"
assert_rc "$RC" 7 "$OUT"

export PARALLEL_STATE_DIR="$ROOT_TMP/state-flake"
F="$(new_repo flake-repo)"
mkdir -p "$F/.claude"
# The gate always fails and names one check; the rerun passes only for "wobbly".
printf '{"pipeline": {"parallel": {"gate_command": "echo merge-queue-failed-check: wobbly; echo merge-queue-gate-complete: failed=1; exit 1", "rerun_check_command": "echo rerun {check}; test {check} = wobbly"}}}\n' > "$F/.claude/project.json"
LF="$(mk_lane "$F" f1)"
add_commit "$LF" f.txt f

CASE="flake: only the failing check is rerun; a pass lands and is logged as flake:<check>"
run bash -c "cd '$F' && bash '$MQ' land lane/f1 --dry-run"
expect_rc "$RC" 0 "$OUT"
tail -1 "$PARALLEL_STATE_DIR/merge-queue.jsonl" | grep -q '"flake":"flake:wobbly"' || fail "flake not logged"
grep -q '^merge-queue-failed-check: wobbly' "$PARALLEL_STATE_DIR/merge-queue.logs/lane-f1-1.log" || fail "attempt 1 log missing"
grep -q '^rerun wobbly' "$PARALLEL_STATE_DIR/merge-queue.logs/lane-f1-2.log" || fail "attempt 2 log missing"
ok

CASE="flake: a check with two flakes in 7 days is not rerun"
run bash -c "cd '$F' && bash '$MQ' land lane/f1 --dry-run"
expect_rc "$RC" 0 "$OUT"
run bash -c "cd '$F' && bash '$MQ' land lane/f1"
expect_rc "$RC" 4 "$OUT"
printf '%s' "$OUT" | grep -q 'FLAKE LIMIT' || fail "no limit message: $OUT"
[ ! -e "$PARALLEL_STATE_DIR/merge-queue.logs/lane-f1-6.log" ] || fail "the check was rerun past the limit"
tail -1 "$PARALLEL_STATE_DIR/merge-queue.jsonl" | grep -q '"result":"flake-limit"' || fail "verdict not flake-limit"
ok

CASE="flake: records older than 7 days do not count"
sed -i 's/"ts":"[0-9]\{4\}/"ts":"2000/' "$PARALLEL_STATE_DIR/merge-queue.jsonl"
run bash -c "cd '$F' && bash '$MQ' land lane/f1 --dry-run"
assert_rc "$RC" 0 "$OUT"

CASE="flake: a failing rerun, two named checks and an unsafe name all stay tests-failed"
for gate in 'echo merge-queue-failed-check: broken; echo merge-queue-gate-complete: failed=1; exit 1' \
            'echo merge-queue-failed-check: wobbly; echo merge-queue-failed-check: other; echo merge-queue-gate-complete: failed=1; exit 1' \
            'echo "merge-queue-failed-check: x;touch /nonexistent"; echo merge-queue-gate-complete: failed=1; exit 1'; do
  run bash -c 'cd "$1" && bash "$2" land lane/f1 --test-cmd "$3"' _ "$F" "$MQ" "$gate"
  [ "$RC" -eq 4 ] || fail "expected exit 4 for [$gate], got $RC: $OUT"
  tail -1 "$PARALLEL_STATE_DIR/merge-queue.jsonl" | grep -q '"result":"tests-failed"' || fail "not tests-failed for [$gate]"
  tail -1 "$PARALLEL_STATE_DIR/merge-queue.jsonl" | grep -q '"flake"' && fail "flake logged for [$gate]"
done
ok

CASE="flake: a gate that did not show it reached its end with one failure is not rerun"
for gate in 'echo merge-queue-failed-check: wobbly; exit 137' \
            'echo merge-queue-failed-check: wobbly; exit 1' \
            'echo merge-queue-failed-check: wobbly; echo merge-queue-gate-complete: failed=1; exit 137' \
            'echo merge-queue-failed-check: wobbly; echo merge-queue-gate-complete: failed=2; exit 1' \
            'echo merge-queue-failed-check: wobbly; echo merge-queue-gate-complete: failed=1; echo coverage too low; exit 1'; do
  run bash -c 'cd "$1" && bash "$2" land lane/f1 --dry-run --test-cmd "$3"' _ "$F" "$MQ" "$gate"
  [ "$RC" -eq 4 ] || fail "expected exit 4 for [$gate], got $RC: $OUT"
  printf '%s' "$OUT" | grep -q 'rerunning' && fail "rerun for [$gate]: $OUT"
done
ok

CASE="queue log: last-test.log shows the running test, and earlier attempt logs are kept"
first_log="$(cat "$PARALLEL_STATE_DIR/merge-queue.logs/lane-f1-1.log")"
run bash -c 'cd "$1" && bash "$2" land lane/f1 --dry-run --test-cmd "$3"' _ "$F" "$MQ" \
  "echo live-marker; cp '$PARALLEL_STATE_DIR/merge-queue.last-test.log' '$ROOT_TMP/seen.log'"
expect_rc "$RC" 0 "$OUT"
grep -qx 'live-marker' "$ROOT_TMP/seen.log" || fail "during the run it held: $(cat "$ROOT_TMP/seen.log")"
[ "$(cat "$PARALLEL_STATE_DIR/merge-queue.logs/lane-f1-1.log")" = "$first_log" ] || fail "an earlier attempt log was overwritten"
ok

CASE="flake: unset rerun_check_command means no rerun"
printf '{"pipeline": {"parallel": {"gate_command": "echo merge-queue-failed-check: wobbly; exit 1"}}}\n' > "$F/.claude/project.json"
run bash -c "cd '$F' && bash '$MQ' land lane/f1"
expect_rc "$RC" 4 "$OUT"
printf '%s' "$OUT" | grep -q 'rerunning' && fail "rerun while the feature is off: $OUT"
ok

export PARALLEL_STATE_DIR="$ROOT_TMP/state-mig"
G="$(new_repo mig-repo)"
mkdir -p "$G/.claude" "$G/db/versions"
printf 'x\n' > "$G/db/versions/0101_base.py"
git -C "$G" add db && git -C "$G" commit -q -m versions
printf '{"pipeline": {"parallel": {"gate_command": "true", "migrations_dir": "db/versions/"}}}\n' > "$G/.claude/project.json"
LA="$(mk_lane "$G" ma)"
LB="$(mk_lane "$G" mb)"

CASE="migrations: reservations count up from the target's highest number"
run bash -c "cd '$G' && bash '$LANES' reserve-migration ma"
expect_rc "$RC" 0 "$OUT"
printf '%s' "$OUT" | grep -q 'reserved: 0102 ' || fail "first number: $OUT"
run bash -c "cd '$G' && bash '$LANES' reserve-migration mb --dir db/versions"
expect_rc "$RC" 0 "$OUT"
assert_match "$OUT" 'reserved: 0103 '

CASE="migrations: a folder the target does not have is refused"
run bash -c "cd '$G' && bash '$LANES' reserve-migration ma --dir db/nosuch"
assert_rc "$RC" 1 "$OUT"

CASE="migrations: a number reserved by another lane is refused"
add_commit "$LB" db/versions/0102_mine.py b
run bash -c "cd '$G' && bash '$MQ' land lane/mb"
expect_rc "$RC" 7 "$OUT"
assert_match "$OUT" 'number 0102 is reserved by lane/ma'

CASE="migrations: the reserving lane lands its own number"
add_commit "$LA" db/versions/0102_theirs.py a
run bash -c "cd '$G' && bash '$MQ' land lane/ma"
assert_rc "$RC" 0 "$OUT"

CASE="migrations: a number already on the target is refused, even with the reservation released"
run bash -c "cd '$G' && bash '$LANES' release-migration ma"
expect_rc "$RC" 0 "$OUT"
run bash -c "cd '$G' && bash '$MQ' land lane/mb"
expect_rc "$RC" 7 "$OUT"
assert_match "$OUT" 'number 0102 is taken by db/versions/0102_theirs.py (already on main)'

CASE="migrations: unset migrations_dir leaves the check off"
printf '{"pipeline": {"parallel": {"gate_command": "true"}}}\n' > "$G/.claude/project.json"
run bash -c "cd '$G' && bash '$MQ' land lane/mb --dry-run"
assert_rc "$RC" 0 "$OUT"

CASE="migrations: remove drops the lane's reservations"
run bash -c "cd '$G' && bash '$LANES' remove mb --force"
expect_rc "$RC" 0 "$OUT"
grep -q '^mb' "$PARALLEL_STATE_DIR/reservations.tsv" && fail "reservation kept after remove"
ok

CASE="migrations: a revision whose name git would C-quote is still checked"
printf '{"pipeline": {"parallel": {"gate_command": "true", "migrations_dir": "db/versions"}}}\n' > "$G/.claude/project.json"
LQ="$(mk_lane "$G" mq)"
add_commit "$LQ" 'db/versions/0101_"dup.py' q
run bash -c "cd '$G' && bash '$MQ' land lane/mq --dry-run"
expect_rc "$RC" 7 "$OUT"
assert_match "$OUT" 'number 0101 is taken by db/versions/0101_base.py'

CASE="migrations: a migrations_dir neither side has refuses instead of switching the check off"
printf '{"pipeline": {"parallel": {"gate_command": "true", "migrations_dir": "db/version"}}}\n' > "$G/.claude/project.json"
run bash -c "cd '$G' && bash '$MQ' land lane/mq --dry-run"
expect_rc "$RC" 7 "$OUT"
tail -1 "$PARALLEL_STATE_DIR/merge-queue.jsonl" | grep -q '"result":"refused-config"' || fail "not refused-config: $OUT"
ok

CASE="migrations: remove with a busy reservations lock removes nothing"
run bash -c "cd '$G' && bash '$LANES' reserve-migration mq --dir db/versions"
expect_rc "$RC" 0 "$OUT"
run bash -c "cd '$G' && bash '$LEASE' acquire migration-reservations --holder crashed --ttl 60"
expect_rc "$RC" 0 "$OUT"
run bash -c "cd '$G' && bash '$LANES' remove mq --force"
expect_rc "$RC" 3 "$OUT"
[ -d "$LQ" ] || fail "the lane folder was removed"
git -C "$G" show-ref --verify --quiet refs/heads/lane/mq || fail "the lane branch was deleted"
run bash -c "cd '$G' && bash '$LEASE' release migration-reservations --holder crashed"
assert_rc "$RC" 0 "$OUT"

CASE="migrations: the reservations lease is released in a repo whose path has a quote"
export PARALLEL_STATE_DIR="$ROOT_TMP/state of it's"
Q="$(new_repo "my repo's")"
mkdir -p "$Q/db"; printf 'x\n' > "$Q/db/0001_a.sql"
git -C "$Q" add db && git -C "$Q" commit -q -m db
cd "$Q"
run bash "$LANES" create qa
expect_rc "$RC" 0 "$OUT"
run bash "$LANES" reserve-migration qa --dir db
expect_rc "$RC" 0 "$OUT"
run bash "$LEASE" list
cd "$PLUGIN_ROOT"
printf '%s' "$OUT" | grep -q 'migration-reservations' && fail "lease still held: $OUT"
ok

# ── event stream (events.v1.jsonl) and report --json ────────────────────────
export PARALLEL_STATE_DIR="$ROOT_TMP/state-events"
EVF="$PARALLEL_STATE_DIR/events.v1.jsonl"
PYB="$(bash "$PLUGIN_ROOT/scripts/py.sh" --print)"
E="$(new_repo events-repo)"
mkdir -p "$E/.claude"
export CLAUDE_PROJECT_DIR="$E"   # no runner settings left over from earlier cases
printf '{"pipeline": {"parallel": {"gate_command": "echo merge-queue-failed-check: tests/unit/wob.test; test ! -e FAIL"}}}\n' > "$E/.claude/project.json"
cd "$E"

# evcheck <python> [args]: `evs` is every event, `of(type)` filters, a = args.
evcheck() {
  local code="$1"; shift
  "$PYB" -c '
import json, sys
evs = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
def of(t): return [e for e in evs if e["type"] == t]
a = sys.argv[3:]
exec(sys.argv[2])
' "$EVF" "$code" "$@" || fail "event check failed: $(cat "$EVF")"
}

CASE="events: lanes.sh create writes lane.opened with the stored lane_id, area and base"
LE="$(mk_lane "$E" api-one)"; cd "$E"
LID="$(cut -d' ' -f1 "$(git -C "$LE" rev-parse --absolute-git-dir)/lane-id")"
evcheck '
e, = of("lane.opened")
assert e["lane_id"] == a[0] and a[0].startswith("api-one."), e
assert e["area"] == "api" and e["base_sha"] == a[1], e
' "$LID" "$(git -C "$E" rev-parse main)"
ok

CASE="events: runner.call carries the lane_id of its --cwd lane; a fresh call has no resume_reason"
run bash "$RUNNER" start ev1 --prompt "x" --cwd "$LE" --allowed-tools Read --model sonnet
expect_rc "$RC" 0 "$OUT"
evcheck '
e, = of("runner.call")
assert (e["lane_id"], e["runner"], e["attempt"], e["mode"], e["resume_reason"]) == (a[0], "ev1", 1, "fresh", None), e
assert (e["model"], e["num_turns"], e["context_tokens"], e["is_error"], e["rc"]) == ("sonnet", 1, 1015, False, 0), e
assert abs(e["cost_delta_usd"] - 0.01) < 1e-9, e
' "$LID"
ok

CASE="events: cost_delta_usd is the call's cost, never the session's running total"
run bash "$RUNNER" resume ev1 --prompt "y" --reason tests_failed
expect_rc "$RC" 0 "$OUT"
grep -q '"session_cost_usd": 0.02' "$PARALLEL_STATE_DIR/runners/ev1/events.jsonl" || fail "fake did not report a running total"
evcheck '
e = of("runner.call")[-1]
assert e["mode"] == "resume" and e["resume_reason"] == "tests_failed" and e["attempt"] == 2, e
assert abs(e["cost_delta_usd"] - 0.01) < 1e-9, e
'
ok

CASE="events: each denial gets a tool and a shape; the command and path text never reach the stream"
D='[{"tool_name":"Bash","tool_input":{"command":"git commit -m \"SEKRET a && b > c\""}},
{"tool_name":"Bash","tool_input":{"command":"git -C SEKRET add file"}},
{"tool_name":"Bash","tool_input":{"command":"cd SEKRET && git commit -m x"}},
{"tool_name":"Bash","tool_input":{"command":"cat <<EOF > SEKRET\nbody\nEOF"}},
{"tool_name":"Bash","tool_input":{"command":"sed -i s/SEKRET/b/ file"}},
{"tool_name":"Write","tool_input":{"file_path":"/r/.claude/hooks/SEKRET.js","content":"SEKRET"}},
{"tool_name":"Write","tool_input":{"file_path":"/r/x.lanes/one/.claude/results/SEKRET.md"}},
{"tool_name":"Bash","tool_input":{"command":"ls SEKRET"}},
{"tool_name":"SEKRET with spaces","tool_input":{"command":"SEKRET"}}]'
run env FAKE_DENY_JSON="$(printf '%s' "$D" | tr '\n' ' ')" bash "$RUNNER" resume ev1 --prompt "z"
expect_rc "$RC" 3 "$OUT"
evcheck '
got = [(e["tool"], e["shape"]) for e in of("runner.denial")]
want = [("Bash", "git_commit"), ("Bash", "git_add"), ("Bash", "chained"), ("Bash", "redirect_or_heredoc"),
        ("Bash", "sed_inplace"), ("Write", "protected_path"), ("Write", "lanes_path_write"),
        ("Bash", "read_cmd"), ("other", "other")]
assert got == want, got
assert "SEKRET" not in open(sys.argv[1]).read()
assert set(of("runner.denial")[0]) == {"schema", "event_id", "ts", "type", "lane_id", "runner", "attempt", "tool", "shape"}
c = of("runner.call")[-1]
assert c["denials"] == 9 and c["resume_reason"] == "other", c
'
ok

CASE="events: a rotation's hand-off turn is resume_reason=rotate; the call after keeps its own reason"
run bash "$RUNNER" resume ev1 --prompt "w" --fresh --reason review_fix
expect_rc "$RC" 0 "$OUT"
evcheck '
h, f = of("runner.call")[-2:]
assert (h["mode"], h["resume_reason"]) == ("resume", "rotate"), h
assert (f["mode"], f["resume_reason"]) == ("fresh", "review_fix"), f
'
ok

CASE="events: an unknown --reason is refused"
run bash "$RUNNER" resume ev1 --prompt "v" --reason because
assert_rc "$RC" 2 "$OUT"

CASE="events: --lane sets the lane_id when the runner's folder is not the lane"
run bash "$RUNNER" start ev2 --prompt "x" --cwd "$E" --lane api-one --allowed-tools Read
expect_rc "$RC" 0 "$OUT"
evcheck 'assert of("runner.call")[-1]["lane_id"] == a[0], of("runner.call")[-1]' "$LID"
ok

CASE="events: lanes.sh reviewed writes review.verdict with the round and reviewer model"
add_commit "$LE" FAIL x
run bash "$LANES" reviewed api-one "$(git -C "$LE" rev-parse HEAD)" --verdict fix --reviewer-model opus
expect_rc "$RC" 0 "$OUT"
run bash "$LANES" reviewed api-one "$(git -C "$LE" rev-parse HEAD)"
expect_rc "$RC" 0 "$OUT"
evcheck '
x, y = of("review.verdict")
assert (x["lane_id"], x["round"], x["verdict"], x["reviewer_model"]) == (a[0], 1, "fix", "opus"), x
assert (y["round"], y["verdict"], y["reviewer_model"]) == (2, "accept", None), y
' "$LID"
ok

CASE="events: a failed landing is a queue.attempt with the check's name, not its path"
run bash "$MQ" land lane/api-one
expect_rc "$RC" 4 "$OUT"
evcheck '
e, = of("queue.attempt")
assert (e["lane_id"], e["attempt"], e["result"], e["failed_check"], e["flake_suspected"]) == (a[0], 1, "tests-failed", "wob.test", False), e
assert isinstance(e["duration_s"], int) and e["old_sha"] == a[1] and e["new_sha"], e
' "$LID" "$(git -C "$E" rev-parse main)"
ok

CASE="events: a landing records result=landed with the old and new sha"
before="$(git -C "$E" rev-parse main)"
git -C "$LE" rm -q FAIL; git -C "$LE" commit -q -m unfail
add_commit "$LE" feature.txt f
run bash "$MQ" land lane/api-one
expect_rc "$RC" 0 "$OUT"
evcheck '
e = of("queue.attempt")[-1]
assert (e["lane_id"], e["attempt"], e["result"], e["old_sha"], e["new_sha"]) == (a[0], 2, "landed", a[1], a[2]), e
' "$LID" "$before" "$(git -C "$E" rev-parse main)"
ok

CASE="events: a rerun that passes is flake_suspected"
printf '{"pipeline": {"parallel": {"gate_command": "echo merge-queue-failed-check: wobbly; echo merge-queue-gate-complete: failed=1; exit 1", "rerun_check_command": "true {check}"}}}\n' > "$E/.claude/project.json"
LF2="$(mk_lane "$E" web-two)"; cd "$E"
add_commit "$LF2" web.txt w
run bash "$MQ" land lane/web-two
expect_rc "$RC" 0 "$OUT"
evcheck '
e = of("queue.attempt")[-1]
assert (e["result"], e["failed_check"], e["flake_suspected"]) == ("landed", "wobbly", True), e
'
ok

CASE="events: lease.taken once (a renewal is not a take) and lease.released with held_s"
run env LEASE_NOW=1000 bash "$LEASE" acquire evdb --holder alice --ttl 600
expect_rc "$RC" 0 "$OUT"
run env LEASE_NOW=1010 bash "$LEASE" renew evdb --holder alice --ttl 600
expect_rc "$RC" 0 "$OUT"
run env LEASE_NOW=1042 bash "$LEASE" release evdb --holder alice
expect_rc "$RC" 0 "$OUT"
run env LEASE_NOW=2000 bash "$LEASE" acquire evport --holder bob --ttl 5
expect_rc "$RC" 0 "$OUT"
run env LEASE_NOW=3000 bash "$LEASE" sweep
expect_rc "$RC" 0 "$OUT"
evcheck '
db = [(e["type"], e["held_s"]) for e in evs if e.get("resource") == "evdb"]
assert db == [("lease.taken", None), ("lease.released", 42)], db
x = [e for e in of("lease.released") if e["resource"] == "evport"]
assert len(x) == 1 and x[0]["held_s"] == 5 and x[0]["expired"] is True, x
'
ok

CASE="events: runner.sh tick writes loop.tick; both counts are required"
run bash "$RUNNER" tick --lanes-open 3 --needs-operator 1
expect_rc "$RC" 0 "$OUT"
evcheck 'e, = of("loop.tick"); assert (e["lanes_open"], e["needs_operator"], e["lane_id"]) == (3, 1, None), e'
run bash "$RUNNER" tick --lanes-open 3
assert_rc "$RC" 2 "$OUT"

CASE="events: lanes.sh remove writes lane.closed with the same lane_id"
run bash "$LANES" remove api-one --force
expect_rc "$RC" 0 "$OUT"
evcheck '
e, = of("lane.closed")
assert (e["lane_id"], e["area"], e["forced"]) == (a[0], "api", True) and e["base_sha"], e
' "$LID"
ok

CASE="events: free text and undeclared fields never get in; every line has the envelope"
"$PYB" "$PLUGIN_ROOT/scripts/events.py" emit "$PARALLEL_STATE_DIR" runner.denial 'tool=rm -rf SEKRET' 'shape=SEKRET text' 'command=SEKRET' 'lane_id=/home/SEKRET'
evcheck '
import re
e = evs[-1]
assert (e["tool"], e["shape"], e["lane_id"]) == ("other", "other", None) and "command" not in e, e
assert "SEKRET" not in open(sys.argv[1]).read()
for x in evs:
    assert x["schema"] == "opa.event/1", x
    assert {"event_id", "ts", "type", "lane_id", "runner", "attempt"} <= set(x), x
    assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", x["ts"]), x
assert len({x["event_id"] for x in evs}) == len(evs)
'
ok

CASE="events: a bad ts is replaced with now; report skips a record without a ts or type"
TSS="$ROOT_TMP/state-badts"
run "$PYB" "$PLUGIN_ROOT/scripts/events.py" queue "$TSS" "$E" ts=SEKRET result=landed -- lane/none
expect_rc "$RC" 0 "$OUT"
grep -q 'SEKRET' "$TSS/events.v1.jsonl" && fail "a bad ts reached the stream"
grep -Eq '"ts":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z"' "$TSS/events.v1.jsonl" || fail "ts not replaced: $(cat "$TSS/events.v1.jsonl")"
printf '%s\n' '{"schema":"opa.event/1","type":"runner.call"}' \
  '{"schema":"opa.event/1","ts":5,"type":"runner.call"}' \
  '{"schema":"opa.event/1","ts":"2026-01-01T00:00:00Z"}' >> "$TSS/events.v1.jsonl"
run env PARALLEL_STATE_DIR="$TSS" bash "$RUNNER" report --json
expect_rc "$RC" 0 "$OUT"
printf '%s' "$OUT" | "$PYB" -c '
import json, sys
t = json.load(sys.stdin)["totals"]
assert t["calls"] == 0 and t["landings"] == 1, t
' || fail "hand-edited lines not skipped: $OUT"
ok

CASE="report: --json is opa.report/1 with per-day and total figures from the stream"
run bash "$RUNNER" report --json
expect_rc "$RC" 0 "$OUT"
printf '%s' "$OUT" | "$PYB" -c '
import json, sys
r = json.load(sys.stdin)
assert r["schema"] == "opa.report/1" and r["since"] is None and r["source"] == "events", r
t = r["totals"]
assert t["calls"] == 6 and t["calls_with_denial"] == 1 and abs(t["denial_share"] - 1 / 6) < 1e-3, t
assert abs(t["cost_usd"] - t["cost_fresh_usd"] - t["cost_resume_usd"]) < 1e-9 and t["cost_usd"] > 0, t
assert len(t["top_denial_shapes"]) == 5, t
# api-one: five of its calls came before its one landing; web-two had none.
assert t["landings"] == 2 and t["landings_joined"] == 1, t
assert abs(t["cost_per_landing_usd"] - t["cost_usd"]) < 1e-9, t
assert t["queue_attempts"] == 3 and t["tests_failed"] == 1 and t["flakes"] == 1, t
assert abs(t["tests_failed_rate"] - 1 / 3) < 1e-3 and t["tests_failed_resumes"] == 1, t
assert sum(d["calls"] for d in r["days"]) == 6 and all("date" in d for d in r["days"]), r["days"]
assert r["total"]["calls"] == 6 and "ev1" in r["by_runner"], r
' || fail "report --json wrong: $OUT"
ok

CASE="report: --since drops earlier days; a bad date is refused; the text report still works"
run bash "$RUNNER" report --json --since 2999-01-01
expect_rc "$RC" 0 "$OUT"
printf '%s' "$OUT" | "$PYB" -c '
import json, sys
r = json.load(sys.stdin)
assert r["since"] == "2999-01-01" and r["days"] == [] and r["totals"]["calls"] == 0, r
assert r["total"]["calls"] == 0 and r["by_runner"] == {}, r
' || fail "--since not applied: $OUT"
run bash "$RUNNER" report --since yesterday
expect_rc "$RC" 2 "$OUT"
run bash "$RUNNER" report
expect_rc "$RC" 0 "$OUT"
assert_match "$OUT" 'by runner'

CASE="report: without a stream the older files are read, joined by lane name; --since filters days"
export PARALLEL_STATE_DIR="$ROOT_TMP/state-legacy"
mkdir -p "$PARALLEL_STATE_DIR/runners/old-lane"
printf '%s\n' '{"ts":"2026-01-01T10:00:00Z","mode":"fresh","session_id":"L","session_cost_usd":0.5,"denials":1}' \
  '{"ts":"2026-01-02T10:00:00Z","mode":"resume","session_id":"L","session_cost_usd":0.75}' > "$PARALLEL_STATE_DIR/runners/old-lane/events.jsonl"
printf '%s\n' '{"ts":"2026-01-01T10:00:00Z","denial":{"tool_name":"Bash","tool_input":{"command":"git add SEKRET"}}}' > "$PARALLEL_STATE_DIR/runners/old-lane/denials.jsonl"
printf '%s\n' '{"ts":"2026-01-02T11:00:00Z","branch":"lane/old-lane","result":"landed"}' > "$PARALLEL_STATE_DIR/merge-queue.jsonl"
run bash "$RUNNER" report --json --since 2026-01-02
expect_rc "$RC" 0 "$OUT"
printf '%s' "$OUT" | "$PYB" -c '
import json, sys
text = sys.stdin.read()
r = json.loads(text)
d, = r["days"]
assert r["source"] == "legacy" and d["date"] == "2026-01-02" and d["calls"] == 1, r
assert abs(d["cost_usd"] - 0.25) < 1e-9 and abs(d["cost_per_landing_usd"] - 0.75) < 1e-9, d
assert "SEKRET" not in text
' || fail "legacy report wrong: $OUT"
run bash "$RUNNER" report --json
printf '%s' "$OUT" | grep -q '"git_add"' || fail "legacy denial shape missing: $OUT"
ok

export PARALLEL_STATE_DIR="$ROOT_TMP/state-detached"
EVF="$PARALLEL_STATE_DIR/events.v1.jsonl"
H2="$(new_repo detached-repo)"
export CLAUDE_PROJECT_DIR="$H2"
LD="$(mk_lane "$H2" foo)"; cd "$H2"
DID="$(cut -d' ' -f1 "$(git -C "$LD" rev-parse --absolute-git-dir)/lane-id")"
add_commit "$LD" foo.txt f

CASE="events: a runner in a lane on a detached HEAD keeps the lane's id (new and resumed)"
run bash "$RUNNER" start d1 --prompt "x" --cwd "$LD" --allowed-tools Read
expect_rc "$RC" 0 "$OUT"
git -C "$LD" checkout -q --detach
run bash "$RUNNER" resume d1 --prompt "y"
expect_rc "$RC" 0 "$OUT"
run bash "$RUNNER" start d2 --prompt "x" --cwd "$LD" --allowed-tools Read
expect_rc "$RC" 0 "$OUT"
evcheck 'assert [e["lane_id"] for e in of("runner.call")] == [a[0]] * 3, of("runner.call")' "$DID"
grep -q "\"lane_id\": \"$DID\"" "$PARALLEL_STATE_DIR/runners/d1/status.json" || fail "status.json lost the lane id"
ok

CASE="events: a landing of a lane whose worktree is gone joins by the stream's id"
git -C "$LD" checkout -q lane/foo
run bash "$RUNNER" start d3 --prompt "x" --cwd "$H2" --lane foo --allowed-tools Read
expect_rc "$RC" 0 "$OUT"
git -C "$H2" worktree remove "$LD"
run bash "$MQ" land lane/foo --test-cmd true
expect_rc "$RC" 0 "$OUT"
evcheck 'assert of("queue.attempt")[-1]["lane_id"] == a[0], of("queue.attempt")[-1]' "$DID"
ok

CASE="events: reviewed and remove keep the lane's id after its worktree is gone"
run bash "$LANES" reviewed foo "$(git -C "$H2" rev-parse lane/foo)"
expect_rc "$RC" 0 "$OUT"
run bash "$LANES" remove foo --force
expect_rc "$RC" 0 "$OUT"
evcheck 'assert [of(t)[-1]["lane_id"] for t in ("review.verdict", "lane.closed")] == [a[0]] * 2, evs[-2:]' "$DID"
ok

CASE="events: a --lane runner resumed after the lane is removed keeps its recorded id"
run bash "$RUNNER" resume d3 --prompt "y"
expect_rc "$RC" 0 "$OUT"
evcheck 'assert of("runner.call")[-1]["lane_id"] == a[0], of("runner.call")[-1]' "$DID"
ok

CASE="report: a mixed report keeps every older-file record that has no twin in the stream"
export PARALLEL_STATE_DIR="$ROOT_TMP/state-mixed"
mkdir -p "$PARALLEL_STATE_DIR/runners/old" "$PARALLEL_STATE_DIR/runners/new"
printf '%s\n' '{"ts":"2026-11-24T10:00:00Z","mode":"fresh","session_id":"O","session_cost_usd":1.0}' \
  '{"ts":"2026-11-26T10:00:00Z","mode":"resume","session_id":"O","session_cost_usd":3.0}' > "$PARALLEL_STATE_DIR/runners/old/events.jsonl"
printf '%s\n' '{"ts":"2026-11-25T10:00:00Z","mode":"fresh","session_id":"N","session_cost_usd":0.5}' > "$PARALLEL_STATE_DIR/runners/new/events.jsonl"
printf '%s\n' '{"schema":"opa.event/1","ts":"2026-11-25T10:00:00Z","type":"runner.call","runner":"new","mode":"fresh","cost_delta_usd":0.5}' > "$PARALLEL_STATE_DIR/events.v1.jsonl"
run bash "$RUNNER" report --json
expect_rc "$RC" 0 "$OUT"
printf '%s' "$OUT" | "$PYB" -c '
import json, sys
r = json.load(sys.stdin)
t = r["totals"]
assert r["source"] == "mixed" and t["calls"] == 3 and abs(t["cost_usd"] - 3.5) < 1e-9, r
' || fail "older-file records dropped or doubled: $OUT"
ok

CASE="report: a wrong-typed or free-text stream line neither crashes the report nor reaches it"
export PARALLEL_STATE_DIR="$ROOT_TMP/state-badline"
mkdir -p "$PARALLEL_STATE_DIR"
printf '%s\n' '{"schema":"opa.event/1","ts":"2026-11-26T00:00:00Z","type":"runner.call","lane_id":["x"],"cost_delta_usd":1}' \
  '{"schema":"opa.event/1","ts":"2026-11-26T00:00:00Z","type":"runner.denial","shape":{"a":1}}' \
  '{"schema":"opa.event/1","ts":"2026-11-26T00:00:00Z","type":"runner.denial","shape":"rm -rf /home/SEKRET"}' \
  '{"schema":"opa.event/1","ts":"/home/SEKRET-path","type":"runner.call"}' > "$PARALLEL_STATE_DIR/events.v1.jsonl"
run bash "$RUNNER" report --json
expect_rc "$RC" 0 "$OUT"
printf '%s' "$OUT" | grep -Eq 'SEKRET|/home/' && fail "free text reached the report: $OUT"
printf '%s' "$OUT" | "$PYB" -c '
import json, sys
r = json.load(sys.stdin)
assert r["totals"]["calls"] == 1 and [d["date"] for d in r["days"]] == ["2026-11-26"], r
' || fail "bad lines handled wrongly: $OUT"
ok

CASE="skill: section 10 never tells an accepted lane to sync"
grep -q 'before review, never after an accept' "$PLUGIN_ROOT/skills/orchestrate-parallel-agents/SKILL.md" || fail "the rebase-early line is unqualified"
ok

cd "$PLUGIN_ROOT"
export PARALLEL_STATE_DIR="$ROOT_TMP/state-runner"

CASE="runner: status lists every runner"
run bash "$RUNNER" status
assert_match "$OUT" 'w1'

echo
echo "test-parallel.sh: all cases ok"
