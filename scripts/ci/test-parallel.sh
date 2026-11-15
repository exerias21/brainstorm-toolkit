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

# ── runner.sh (fake claude) ─────────────────────────────────────────────────
export PARALLEL_STATE_DIR="$ROOT_TMP/state-runner"
FAKE="$ROOT_TMP/fakeclaude"
cat > "$FAKE" <<'EOF'
#!/usr/bin/env bash
# Fake `claude -p --output-format json`: logs argv, answers in the measured shape.
[ "${1:-}" = "--help" ] && { echo "  --permission-prompts <target>"; exit 0; }
printf '%s' "$*" | tr '\n' ' ' >> "$FAKE_LOG"; echo >> "$FAKE_LOG"   # one line per call
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

CASE="runner: resume below the threshold passes --resume <id>"
run env FAKE_CTX=200000 bash "$RUNNER" resume w1 --prompt "task two"
expect_rc "$RC" 0 "$OUT"
tail -1 "$FAKE_LOG" | grep -q -- "--resume $S1" || fail "did not resume $S1: $(tail -1 "$FAKE_LOG")"
grep -q '"context_tokens": 200015' "$PARALLEL_STATE_DIR/runners/w1/status.json" || fail "context not recorded from usage.iterations"
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

CASE="runner: status lists every runner"
run bash "$RUNNER" status
assert_match "$OUT" 'w1'

echo
echo "test-parallel.sh: all cases ok"
