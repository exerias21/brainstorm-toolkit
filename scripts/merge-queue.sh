#!/usr/bin/env bash
# brainstorm-toolkit — the merge queue: the one opt-in script that lands a
# lane's branch on a target branch. OPT-IN: nothing calls it unless you do.
#
# WHY THIS EXISTS: with one worktree per writer, the danger moves from "two
# agents in one folder" to "two branches meeting". This script is the single
# door they meet at, one at a time: rebase the lane onto the target, run the
# project's FULL test command in a clean checkout (tracked files plus the
# .worktreeinclude copies -- never the lane's own folder, whose untracked
# leftovers could make a red suite look green), and fast-forward the target
# only if it has not moved since the rebase started.
#
# WHAT IT WILL NOT DO, by design (DECISIONS.md 2026-11-15):
#   - push, force-push, open a pull request, or touch any remote;
#   - move the target by anything but `git update-ref <ref> <new> <old>`, a
#     compare-and-swap that fails if someone else landed first;
#   - resolve a conflict. On conflict it aborts, prints the files and exits 2.
#     The conflict goes back to the lane that owns those files, or to the
#     orchestrator; a model guessing at both sides of a conflict is how
#     correct work gets silently dropped.
#   - land with no test command. "No tests configured" is not "tests passed".
# /sdlc keeps its no-git-writes rule; this script is outside the pipeline.
#
# Usage:
#   merge-queue.sh land <lane-branch>... [--target BRANCH] [--test-cmd CMD]
#                       [--verify-tests SLUG] [--pipeline-dir DIR] [--dry-run]
#   merge-queue.sh log [N]          last N verdicts (default 10)
#
#   several branches  are rebased in the order given onto the target in one
#                   clean checkout, the gate runs ONCE on the combined result,
#                   and the target moves once (all or none). Use it for lanes
#                   that only pass together (a shared pinned test string).
#   --target        default: the branch checked out in the main worktree.
#   --test-cmd      default: .claude/project.json pipeline.parallel.gate_command,
#                   then test.unit. Run with `bash -c` in the clean checkout.
#                   Passing it while a gate is configured prints a WARNING and
#                   logs test_cmd_override:true; every verdict logs test_cmd.
#   --verify-tests  also run scripts/protect-tests.sh verify --slug SLUG in the
#                   clean checkout (armed test files must be byte-identical).
#   --dry-run       rebase and test, but do not move the target.
#
# Serial: holds the lease `merge-queue` (scripts/lease.sh, TTL
# $MERGE_QUEUE_TTL, default 3600s) for the whole run; a second caller is
# refused with exit 3 instead of waiting.
#
# A DIRTY TARGET WORKTREE IS FINE UNLESS IT OVERLAPS THE LANE. The main
# folder of a busy repo almost always holds unrelated edits (shared ledgers,
# another session's work), so refusing on any dirt meant the queue could
# never land there (first trial, 2026-11-15). It refuses only when a
# modified, staged or untracked path in the target worktree is one the lane
# changes (`git diff --name-only <target>...<lane>`), or when the lane would
# create a file that already exists there untracked or ignored. It checks
# twice: before the test run and again just before the compare-and-swap.
# After the swap it moves only the lane's paths forward in that worktree
# (two-tree `git read-tree -m -u <old> <new>`, which touches only the paths
# that differ between the two trees); every other file, staged or not, is
# left exactly as it was.
#
# The clean checkout gets the .worktreeinclude copies and then
# pipeline.parallel.lane_setup (lanes.sh setup), the same seeding a new lane
# gets, so a suite that needs a built venv or node_modules can run there.
#
# Exit codes: 0 landed (or dry-run passed, or nothing to land), 1 usage or
# environment error, 2 conflict, 3 queue busy, 4 tests failed, none
# configured, or lane setup failed, 5 target moved (re-run), 6 the target
# worktree has uncommitted or untracked files on the lane's paths, or could
# not be moved forward. Each verdict is appended to <state>/merge-queue.jsonl.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { sed -n '24,44p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

[ $# -ge 1 ] || usage
SUB="$1"; shift

common="$(git rev-parse --git-common-dir 2>/dev/null)" || { echo "merge-queue.sh: not inside a git repository" >&2; exit 1; }
MAIN="$(cd "$(dirname "$common")" && pwd)"
STATE="${PARALLEL_STATE_DIR:-$MAIN/.claude/parallel}"
mkdir -p "$STATE"
LOG="$STATE/merge-queue.jsonl"

if [ "$SUB" = "log" ]; then
  [ -f "$LOG" ] && tail -n "${1:-10}" "$LOG"
  exit 0
fi
[ "$SUB" = "land" ] || usage

BRANCHES=(); TARGET=""; TEST_CMD=""; SLUG=""; PIPE_DIR=""; DRY=0; OVERRIDE=false
while [ $# -gt 0 ]; do
  case "$1" in
    --target)       TARGET="${2:-}"; shift 2 ;;
    --test-cmd)     TEST_CMD="${2:-}"; shift 2 ;;
    --verify-tests) SLUG="${2:-}"; shift 2 ;;
    --pipeline-dir) PIPE_DIR="${2:-}"; shift 2 ;;
    --dry-run)      DRY=1; shift ;;
    -h|--help) usage ;;
    --*) echo "merge-queue.sh: unknown flag $1" >&2; usage ;;
    *) BRANCHES+=("$1"); shift ;;
  esac
done
[ "${#BRANCHES[@]}" -ge 1 ] || usage
[ -n "$TARGET" ] || TARGET="$(git -C "$MAIN" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
[ -n "$TARGET" ] || { echo "merge-queue.sh: no --target and the main worktree is on a detached HEAD" >&2; exit 1; }
git -C "$MAIN" show-ref --verify --quiet "refs/heads/$TARGET" || { echo "merge-queue.sh: no branch $TARGET" >&2; exit 1; }
for b in "${BRANCHES[@]}"; do
  [ "$b" != "$TARGET" ] || { echo "merge-queue.sh: lane branch and target are the same" >&2; exit 1; }
  git -C "$MAIN" show-ref --verify --quiet "refs/heads/$b" || { echo "merge-queue.sh: no branch $b" >&2; exit 1; }
done
# Display / log name: one branch as-is, several space-joined.
BRANCH="${BRANCHES[*]}"
[ -z "$PIPE_DIR" ] && PIPE_DIR="$MAIN/.claude/pipeline"

# Test command: flag > pipeline.parallel.gate_command > test.unit. The
# configured one is looked up even when the flag is given, so an override of a
# configured gate can be warned about and logged (a narrow ad hoc --test-cmd on
# every landing meant the project's full gate never ran, 2026-11-15).
CONFIGURED=""
if [ -f "$MAIN/.claude/project.json" ]; then
  if PY="$(bash "$HERE/py.sh" --print 2>/dev/null)" && [ -n "$PY" ]; then
    CONFIGURED="$("$PY" - "$MAIN/.claude/project.json" <<'PYEOF' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
gate = ((d.get("pipeline") or {}).get("parallel") or {}).get("gate_command")
unit = (d.get("test") or {}).get("unit")
print(gate or unit or "")
PYEOF
)"
  fi
fi
if [ -z "$TEST_CMD" ]; then
  TEST_CMD="$CONFIGURED"
elif [ -n "$CONFIGURED" ] && [ "$TEST_CMD" != "$CONFIGURED" ]; then
  OVERRIDE=true
  echo "WARNING: --test-cmd overrides the configured gate ($CONFIGURED). A narrower command than the gate lets a red suite land; the project's full gate will NOT run."
fi

HOLDER="merge-queue-$$"
TMP=""
verdict() {  # result detail -- one JSON line per run
  local result="$1" detail="${2:-}" jpy
  # json.dumps so the logged command is exactly what ran (quotes, backslashes,
  # tabs and newlines included); the printf below is only the no-python fallback.
  if jpy="$(bash "$HERE/py.sh" --print 2>/dev/null)" && [ -n "$jpy" ]; then
    "$jpy" -c '
import json, sys
a = sys.argv[1:]
print(json.dumps({"ts": a[0], "branch": a[1], "target": a[2], "result": a[3], "old": a[4], "new": a[5],
                  "test_cmd": a[6], "test_cmd_override": a[7] == "true", "detail": a[8]}, separators=(",", ":")))
' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BRANCH" "$TARGET" "$result" "${OLD:-}" "${NEW:-}" "$TEST_CMD" "$OVERRIDE" "$detail" >> "$LOG"
    return 0
  fi
  printf '{"ts":"%s","branch":"%s","target":"%s","result":"%s","old":"%s","new":"%s","test_cmd":"%s","test_cmd_override":%s,"detail":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BRANCH" "$TARGET" "$result" "${OLD:-}" "${NEW:-}" \
    "$(printf '%s' "$TEST_CMD" | tr '\n"\\' ' __')" "$OVERRIDE" \
    "$(printf '%s' "$detail" | tr '\n"\\' ' __')" >> "$LOG"
}
cleanup() {
  if [ -n "$TMP" ]; then
    git -C "$TMP" rebase --abort >/dev/null 2>&1 || true
    git -C "$MAIN" worktree remove --force "$TMP" >/dev/null 2>&1 || rm -rf "$TMP"
    git -C "$MAIN" worktree prune >/dev/null 2>&1 || true
  fi
  PARALLEL_STATE_DIR="$STATE" bash "$HERE/lease.sh" release merge-queue --holder "$HOLDER" >/dev/null 2>&1 || true
}

if ! out="$(cd "$MAIN" && PARALLEL_STATE_DIR="$STATE" bash "$HERE/lease.sh" acquire merge-queue --holder "$HOLDER" --ttl "${MERGE_QUEUE_TTL:-3600}")"; then
  echo "BUSY: another landing holds the queue ($out). Re-run when it finishes."
  exit 3
fi
trap cleanup EXIT

if [ -z "$TEST_CMD" ]; then
  echo "REFUSED: no test command (--test-cmd, pipeline.parallel.gate_command or test.unit). An empty gate is not a pass."
  verdict refused-no-tests; exit 4
fi

# Where is the target checked out? Updating a checked-out branch's ref behind
# its worktree's back would leave that folder showing the landing reversed, so
# the lane's paths are moved forward there too -- which is only safe when none
# of them holds uncommitted work. Unrelated dirt is left alone.
TARGET_WT="$(git -C "$MAIN" worktree list --porcelain | awk -v b="refs/heads/$TARGET" '/^worktree /{p=substr($0,10)} $0=="branch " b && !f {print p; f=1}')"

# Paths in the target worktree that a landing of these lane paths would
# clobber: modified, staged or untracked (not ignored) files that are lane
# paths, plus lane paths absent from the target's tree that exist on disk
# anyway (an ignored or untracked file the lane would create over).
# $1 = the tree the target is at; stdin = the lane's paths, one per line.
overlap() {
  local at="$1" dirty
  dirty="$( { git -C "$TARGET_WT" diff --name-only --no-renames
              git -C "$TARGET_WT" diff --cached --name-only --no-renames
              git -C "$TARGET_WT" ls-files --others --exclude-standard; } | sort -u)"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if printf '%s\n' "$dirty" | grep -qxF -- "$p"; then echo "$p"
    elif [ -e "$TARGET_WT/$p" ] && ! git -C "$MAIN" cat-file -e "$at:$p" 2>/dev/null; then echo "$p"
    fi
  done
}
refuse_overlap() {  # $1 = the overlapping paths
  echo "REFUSED: $TARGET is checked out at $TARGET_WT with uncommitted or untracked files on paths this lane changes:"
  printf '%s\n' "$1" | sed 's/^/  dirty: /'
  echo "Commit, move or discard those paths there first. Unrelated uncommitted files do not block a landing."
  verdict refused-target-dirty "$1"; exit 6
}
if [ -n "$TARGET_WT" ]; then
  hits="$(for b in "${BRANCHES[@]}"; do git -C "$MAIN" diff --name-only --no-renames "refs/heads/$TARGET...refs/heads/$b"; done | sort -u | overlap "refs/heads/$TARGET")"
  [ -z "$hits" ] || refuse_overlap "$hits"
fi

for b in "${BRANCHES[@]}"; do
  LANE_WT="$(git -C "$MAIN" worktree list --porcelain | awk -v b="refs/heads/$b" '/^worktree /{p=substr($0,10)} $0=="branch " b && !f {print p; f=1}')"
  if [ -n "$LANE_WT" ] && [ -n "$(git -C "$LANE_WT" status --porcelain --untracked-files=no)" ]; then
    echo "WARNING: $b has uncommitted changes at $LANE_WT; only its commits will land."
  fi
done

OLD="$(git -C "$MAIN" rev-parse "refs/heads/$TARGET")"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/merge-queue.XXXXXX")"
rmdir "$TMP"
# The clean checkout runs with the project's git hooks off: a post-checkout
# hook that regenerates tracked files (seen 2026-11-15: a progress page) would
# leave the "clean" copy dirty, and git then refuses the rebase.
NOHOOKS=(-c core.hooksPath=/dev/null)
git "${NOHOOKS[@]}" -C "$MAIN" worktree add -q --detach "$TMP" "${BRANCHES[0]}"

# Several branches: each is rebased in turn onto the tip the previous one
# produced, so the gate below runs once on the combined result and the target
# moves once. A branch already contained in the previous ones rebases to nothing.
tip="$OLD"; first=1
for b in "${BRANCHES[@]}"; do
  if [ "$first" -eq 1 ]; then first=0
  else git "${NOHOOKS[@]}" -C "$TMP" checkout -q --detach "$b"; fi
  if ! rb_err="$(git "${NOHOOKS[@]}" -C "$TMP" rebase -q "$tip" 2>&1 >/dev/null)"; then
    files="$(git -C "$TMP" diff --name-only --diff-filter=U)"
    if [ -z "$files" ]; then
      echo "REBASE FAILED (not a conflict): $b could not be rebased onto $TARGET. Nothing was changed."
      printf '%s\n' "$rb_err" | sed '/^$/d; s/^/  git: /'
      verdict rebase-failed "$rb_err"; exit 1
    fi
    echo "CONFLICT: $b does not rebase cleanly onto $TARGET (combined with any branch listed before it). Nothing was changed."
    printf '%s\n' "$files" | sed '/^$/d; s/^/  conflict: /'
    echo "Next: hand these files back to the lane that owns them (lanes.sh sync), or to the orchestrator. Do not auto-resolve."
    verdict conflict "$files"; exit 2
  fi
  tip="$(git -C "$TMP" rev-parse HEAD)"
done
NEW="$tip"
if [ "$NEW" = "$OLD" ]; then
  echo "NOTHING TO LAND: $BRANCH has no changes that are not already on $TARGET."
  verdict nothing; exit 0
fi

bash "$HERE/lanes.sh" copy-includes "$TMP" >/dev/null 2>&1 || true
if ! (cd "$MAIN" && bash "$HERE/lanes.sh" setup "$TMP") > "$STATE/merge-queue.last-setup.log" 2>&1; then
  echo "SETUP FAILED: pipeline.parallel.lane_setup failed in the clean checkout; $BRANCH was not landed. Output: $STATE/merge-queue.last-setup.log"
  tail -n 20 "$STATE/merge-queue.last-setup.log" | sed 's/^/  /'
  verdict setup-failed; exit 4
fi

if [ -n "$SLUG" ]; then
  case "$PIPE_DIR" in /*) ;; *) PIPE_DIR="$MAIN/$PIPE_DIR" ;; esac
  if ! pt="$(cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" bash "$HERE/protect-tests.sh" verify --pipeline-dir "$PIPE_DIR" --slug "$SLUG" 2>&1)"; then
    echo "REFUSED: protected tests changed:"; printf '%s\n' "$pt" | sed 's/^/  /'
    verdict protected-tests "$pt"; exit 4
  fi
fi

echo "testing $BRANCH rebased on $TARGET (${NEW:0:12}) with: $TEST_CMD"
set +e
(cd "$TMP" && bash -c "$TEST_CMD") > "$STATE/merge-queue.last-test.log" 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  echo "TESTS FAILED (exit $rc): $BRANCH was not landed. Output: $STATE/merge-queue.last-test.log"
  tail -n 20 "$STATE/merge-queue.last-test.log" | sed 's/^/  /'
  verdict tests-failed "exit $rc"; exit 4
fi

if [ "$DRY" -eq 1 ]; then
  echo "DRY RUN: $BRANCH rebases cleanly and passes; $TARGET left at ${OLD:0:12}."
  verdict dry-run; exit 0
fi

# Re-check: the target worktree may have been edited during the test run.
if [ -n "$TARGET_WT" ]; then
  hits="$(git -C "$MAIN" diff --name-only --no-renames "$OLD" "$NEW" | overlap "$OLD")"
  [ -z "$hits" ] || refuse_overlap "$hits"
fi

if ! git -C "$MAIN" update-ref -m "merge-queue: land $BRANCH" "refs/heads/$TARGET" "$NEW" "$OLD" 2>/dev/null; then
  echo "TARGET MOVED: $TARGET changed while $BRANCH was being tested. Nothing landed; re-run to rebase on the new tip."
  verdict target-moved; exit 5
fi
if [ -n "$TARGET_WT" ]; then
  # Two-tree fast-forward of that worktree's index and files from OLD to NEW.
  # It rewrites only the paths whose blobs differ between OLD and NEW (the
  # lane's paths); an index entry or file elsewhere, staged or not, is kept
  # as it is. It refuses rather than overwrite an untracked file.
  if ! git -C "$TARGET_WT" read-tree -m -u "$OLD" "$NEW" 2>"$STATE/merge-queue.read-tree.err"; then
    git -C "$MAIN" update-ref -m "merge-queue: undo $BRANCH" "refs/heads/$TARGET" "$OLD" "$NEW" || true
    echo "REFUSED: could not update the checked-out $TARGET at $TARGET_WT (an untracked file would be overwritten?); $TARGET put back at ${OLD:0:12}."
    sed 's/^/  /' "$STATE/merge-queue.read-tree.err"
    verdict refused-target-worktree; exit 6
  fi
fi
echo "LANDED: $BRANCH -> $TARGET ${OLD:0:12}..${NEW:0:12} ($(git -C "$MAIN" rev-list --count "$OLD..$NEW") commit(s)). Not pushed."
verdict landed
