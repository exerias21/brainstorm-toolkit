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
#   --verdict-file  where to write this run's verdict JSON (exit, result,
#                   branch, target, pid, ts); default
#                   <state>/merge-queue.verdict.json. Written on EVERY exit,
#                   so `land ... | tail` cannot hide a refusal: read the file.
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
# THREE OPT-IN CHECKS, each off while its .claude/project.json key
# (pipeline.parallel.*) is unset; references/merge-queue.md has the detail.
#   review_required_paths  globs. A lane whose diff touches one lands only if
#                          `lanes.sh reviewed` recorded an accept for the
#                          content now at its head.
#   migrations_dir         a lane may not add a revision whose number another
#                          file there already has, or another lane reserved
#                          (`lanes.sh reserve-migration`).
#   rerun_check_command    has {check}. When the gate fails and names exactly
#                          one check (`merge-queue-failed-check: <name>`),
#                          that check alone is rerun once; a pass is logged as
#                          flake:<check>. A check with two flakes in 7 days is
#                          not rerun. The gate must prove it reached its end:
#                          last line `merge-queue-gate-complete: failed=1`, and
#                          an exit code below 126.
# Every test run also keeps its own log, <state>/merge-queue.logs/<branch>-<n>.log.
#
# Exit codes: 0 landed (or dry-run passed, or nothing to land), 1 usage or
# environment error, 2 conflict, 3 queue busy, 4 tests failed, none
# configured, or lane setup failed, 5 target moved (re-run), 6 the target
# worktree has uncommitted or untracked files on the lane's paths, or could
# not be moved forward, 7 refused by the review or migration-number check (or
# its config could not be read). Each verdict is appended to
# <state>/merge-queue.jsonl.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { sed -n '24,48p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

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

# Verdict file: written from the EXIT trap on every exit from here on, with the
# exit code, because a pipe (`land ... | tail`) reports the last command's
# status and once read a REFUSED as 0 (2026-11-21).
VERDICT_FILE="$STATE/merge-queue.verdict.json"
LAST_RESULT="error"; BRANCH=""; TARGET=""; LEASED=0
write_verdict_file() {
  local rc="$1" vpy
  if vpy="$(bash "$HERE/py.sh" --print 2>/dev/null)" && [ -n "$vpy" ]; then
    "$vpy" -c '
import json, sys
a = sys.argv[1:]
print(json.dumps({"ts": a[0], "exit": int(a[1]), "result": a[2], "branch": a[3], "target": a[4], "pid": int(a[5])}))
' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" "$LAST_RESULT" "$BRANCH" "$TARGET" "$$" > "$VERDICT_FILE" 2>/dev/null || true
  else
    printf '{"ts":"%s","exit":%s,"result":"%s","branch":"%s","target":"%s","pid":%s}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" "$LAST_RESULT" \
      "$(printf '%s' "$BRANCH" | tr '"\\' '__')" "$(printf '%s' "$TARGET" | tr '"\\' '__')" "$$" > "$VERDICT_FILE" 2>/dev/null || true
  fi
}
on_exit() {
  local rc=$?
  [ "$LEASED" -eq 1 ] && cleanup
  write_verdict_file "$rc"
}
trap on_exit EXIT

BRANCHES=(); TEST_CMD=""; SLUG=""; PIPE_DIR=""; DRY=0; OVERRIDE=false
while [ $# -gt 0 ]; do
  case "$1" in
    --target)       TARGET="${2:-}"; shift 2 ;;
    --test-cmd)     TEST_CMD="${2:-}"; shift 2 ;;
    --verify-tests) SLUG="${2:-}"; shift 2 ;;
    --pipeline-dir) PIPE_DIR="${2:-}"; shift 2 ;;
    --dry-run)      DRY=1; shift ;;
    --verdict-file) [ -n "${2:-}" ] || { echo "merge-queue.sh: --verdict-file needs a path" >&2; exit 1; }
                    VERDICT_FILE="$2"; shift 2 ;;
    -h|--help) usage ;;
    --*) echo "merge-queue.sh: unknown flag $1" >&2; usage ;;
    *) BRANCHES+=("$1"); shift ;;
  esac
done
rm -f "$VERDICT_FILE"
LAST_RESULT="usage"
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
LAST_RESULT="error"
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
MIG_TMP=""
FLAKE=""  # "flake:<check>" once a single-check rerun has passed
FAILED_CHECK=""  # the check the gate named, when it named exactly one
verdict() {  # result detail -- one JSON line per run
  local result="$1" detail="${2:-}" jpy ts suspected=false
  LAST_RESULT="$result"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"  # shared with the event: report compares them
  if [ -n "$FLAKE" ] || [ "$result" = "flake-limit" ]; then suspected=true; fi
  # json.dumps so the logged command is exactly what ran (quotes, backslashes,
  # tabs and newlines included); the printf below is only the no-python fallback.
  if jpy="$(bash "$HERE/py.sh" --print 2>/dev/null)" && [ -n "$jpy" ]; then
    "$jpy" -c '
import json, sys
a = sys.argv[1:]
d = {"ts": a[0], "branch": a[1], "target": a[2], "result": a[3], "old": a[4], "new": a[5],
     "test_cmd": a[6], "test_cmd_override": a[7] == "true", "detail": a[8]}
if a[9]:
    d["flake"] = a[9]
print(json.dumps(d, separators=(",", ":")))
' "$ts" "$BRANCH" "$TARGET" "$result" "${OLD:-}" "${NEW:-}" "$TEST_CMD" "$OVERRIDE" "$detail" "$FLAKE" >> "$LOG"
    # One queue.attempt event per branch. Neither detail nor the command goes in.
    "$jpy" "$HERE/events.py" queue "$STATE" "$MAIN" "ts=$ts" "result=$result" "failed_check=$FAILED_CHECK" \
      "flake_suspected=$suspected" "duration_s=$SECONDS" "old_sha=${OLD:-}" "new_sha=${NEW:-}" -- "${BRANCHES[@]}" >/dev/null || true
    return 0
  fi
  # No python means no config was read, so FLAKE is always empty here.
  printf '{"ts":"%s","branch":"%s","target":"%s","result":"%s","old":"%s","new":"%s","test_cmd":"%s","test_cmd_override":%s,"detail":"%s"}\n' \
    "$ts" "$BRANCH" "$TARGET" "$result" "${OLD:-}" "${NEW:-}" \
    "$(printf '%s' "$TEST_CMD" | tr '\n"\\' ' __')" "$OVERRIDE" \
    "$(printf '%s' "$detail" | tr '\n"\\' ' __')" >> "$LOG"
}
cleanup() {
  [ -z "$MIG_TMP" ] || rm -f "$MIG_TMP"
  if [ -n "$TMP" ]; then
    git -C "$TMP" rebase --abort >/dev/null 2>&1 || true
    git -C "$MAIN" worktree remove --force "$TMP" >/dev/null 2>&1 || rm -rf "$TMP"
    git -C "$MAIN" worktree prune >/dev/null 2>&1 || true
  fi
  PARALLEL_STATE_DIR="$STATE" bash "$HERE/lease.sh" release merge-queue --holder "$HOLDER" >/dev/null 2>&1 || true
}

if ! out="$(cd "$MAIN" && PARALLEL_STATE_DIR="$STATE" bash "$HERE/lease.sh" acquire merge-queue --holder "$HOLDER" --ttl "${MERGE_QUEUE_TTL:-3600}")"; then
  echo "BUSY: another landing holds the queue ($out). Re-run when it finishes."
  LAST_RESULT="busy"
  exit 3
fi
LEASED=1

if [ -z "$TEST_CMD" ]; then
  echo "REFUSED: no test command (--test-cmd, pipeline.parallel.gate_command or test.unit). An empty gate is not a pass."
  verdict refused-no-tests; exit 4
fi

# One pipeline.parallel key: $1 name, $2 `str` or `list` (printed one per line).
# Nothing when unset. Fails when the file names the key but it cannot be read or
# has the wrong type: a check the project asked for must not switch itself off.
cfg_value() {
  local f="$MAIN/.claude/project.json" py
  [ -f "$f" ] || return 0
  if ! py="$(bash "$HERE/py.sh" --print 2>/dev/null)" || [ -z "$py" ]; then
    if grep -q "\"$1\"" "$f"; then return 3; fi
    return 0
  fi
  "$py" - "$f" "$1" "$2" <<'PYEOF' 2>/dev/null | tr -d '\r'
import json, sys
path, key, kind = sys.argv[1:]
raw = open(path, encoding="utf-8", errors="replace").read()
try:
    v = ((json.loads(raw).get("pipeline") or {}).get("parallel") or {}).get(key)
except Exception:
    sys.exit(3 if '"%s"' % key in raw else 0)
if v is None:
    sys.exit(0)
if kind == "list":
    if not (isinstance(v, list) and all(isinstance(x, str) and x for x in v)):
        sys.exit(3)
    print("\n".join(v))
else:
    if not isinstance(v, str):
        sys.exit(3)
    print(v)
PYEOF
}
refuse_config() {
  echo "REFUSED: pipeline.parallel.$1 in .claude/project.json cannot be read (invalid JSON, wrong type, or no python). Fix it, then re-run."
  verdict refused-config "$1"; exit 7
}
REVIEW_PATHS="$(cfg_value review_required_paths list)" || refuse_config review_required_paths
MIG_DIR="$(cfg_value migrations_dir str)" || refuse_config migrations_dir
RERUN_CMD="$(cfg_value rerun_check_command str)" || refuse_config rerun_check_command
MIG_DIR="${MIG_DIR#./}"; MIG_DIR="${MIG_DIR%/}"

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
# Lane tips are read once: the commit that is checked is the commit that lands,
# even if a lane gets a new commit while this run is going.
HEADS=()
for b in "${BRANCHES[@]}"; do HEADS+=("$(git -C "$MAIN" rev-parse "refs/heads/$b")"); done
gdiff() { git -C "$MAIN" -c core.quotePath=false diff --no-renames "$@"; }

# An entry that can never match a file path would leave its folder unreviewed
# with no warning, so it is refused.
check_review_paths() {
  local g why rev
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    why=""
    case "$g" in
      *'{'*) why="can never match: braces are not expanded; write one entry per alternative" ;;
      ./*|/*) why="can never match: paths are relative to the repo root, with no leading ./ or /" ;;
      */) ;;
      # `engine/*/ledger` reads as a folder but would match only a file so named.
      *'*'*|*'?'*|*'['*) case "${g##*/}" in
          *'*'*) ;;
          *) why="a glob's last segment needs a '*', or the entry a trailing / (for a folder, write $g/)" ;;
        esac ;;
      *) for rev in "$OLD" "${HEADS[@]}"; do
           [ "$(git -C "$MAIN" cat-file -t "$rev:$g" 2>/dev/null || true)" != "tree" ] || why="can never match: it is a folder; write $g/"
         done ;;
    esac
    [ -z "$why" ] || {
      echo "REFUSED: pipeline.parallel.review_required_paths entry '$g' $why."
      verdict refused-config "review_required_paths: $g"; exit 7; }
  done <<<"$REVIEW_PATHS"
}

# stdin: NUL-delimited paths (git C-quotes odd names in newline output, which no
# glob matches). Prints those matching a review_required_paths glob. `*` crosses
# `/`; a trailing `/` means the subtree; a leading `**/` also matches the root.
protected_paths() {
  local p g
  while IFS= read -r -d '' p; do
    [ -n "$p" ] || continue
    while IFS= read -r g; do
      [ -n "$g" ] || continue
      case "$g" in */) g="$g*" ;; esac
      # shellcheck disable=SC2254  # the glob is the point
      case "$p" in $g) printf '%s\n' "$p"; break ;; esac
      case "$g" in
        '**/'*) case "$p" in ${g#'**/'}) printf '%s\n' "$p"; break ;; esac ;;
      esac
    done <<<"$REVIEW_PATHS"
  done
}
refuse_review() {  # $1 = branch, $2 = reason, $3 = path label, $4 = paths
  echo "REFUSED: $1 touches paths that need review (pipeline.parallel.review_required_paths): $2"
  printf '%s\n' "$4" | sed "/^\$/d; s|^|  $3: |"
  echo "Have these reviewed, then record the accepted commit: lanes.sh reviewed ${1#lane/} <sha> --verdict accept"
  verdict refused-review "$1: $2: $4"; exit 7
}
review_check() {
  [ -n "$REVIEW_PATHS" ] || return 0
  local i b h prot row sha v after why
  check_review_paths
  for i in "${!BRANCHES[@]}"; do
    b="${BRANCHES[$i]}"; h="${HEADS[$i]}"
    # pipefail: a failing diff refuses.
    prot="$(gdiff --name-only -z "$OLD...$h" | protected_paths)" || refuse_review "$b" "its diff against $TARGET cannot be read" path ""
    [ -n "$prot" ] || continue
    row=""
    [ ! -f "$STATE/reviews.tsv" ] || row="$(awk -F'\t' -v b="$b" '$1==b{l=$0} END{print l}' "$STATE/reviews.tsv")"
    [ -n "$row" ] || refuse_review "$b" "no review is recorded for it" protected "$prot"
    sha="$(printf '%s' "$row" | cut -f2)"; v="$(printf '%s' "$row" | cut -f3)"
    [ "$v" = "accept" ] || refuse_review "$b" "the latest recorded verdict is '$v' (${sha:0:12})" protected "$prot"
    # Same tree = same content (a reworded commit needs no new review).
    if [ "$sha" != "$h" ] && ! git -C "$MAIN" diff --quiet "$sha" "$h" 2>/dev/null; then
      why="its head ${h:0:12} is past the reviewed ${sha:0:12}"
      git -C "$MAIN" merge-base --is-ancestor "$sha" "$h" 2>/dev/null || why="it was rewritten (rebased, amended or reset) after the review of ${sha:0:12}"
      after="$(gdiff --name-only "$sha" "$h" 2>/dev/null)" || after="(the reviewed commit is no longer available)"
      refuse_review "$b" "$why" "changed after review" "$after"
    fi
  done
}

# Leading number of a revision file name (0102_x.py -> 0102), empty otherwise.
rev_number() { [[ "$1" =~ ^([0-9]+)[._-] ]] && printf '%s' "${BASH_REMATCH[1]}"; return 0; }
# One revision may be several files (0005_x.up.sql, 0005_x.down.sql).
rev_stem() { local s="${1%.*}"; s="${s%.up}"; printf '%s' "${s%.down}"; }
# Needs NEW (the rebased result), so numbers are compared with the current target.
migration_check() {
  [ -n "$MIG_DIR" ] || return 0
  local added all p base num q qbase qnum where holder rdir rnum _ts i mine problems=""
  # A folder neither side has is a typo or a moved folder, not "nothing added".
  if [ -z "$(git -C "$MAIN" ls-tree --name-only "$OLD" -- "$MIG_DIR/")" ] &&
     [ -z "$(git -C "$MAIN" ls-tree --name-only "$NEW" -- "$MIG_DIR/")" ]; then
    echo "REFUSED: pipeline.parallel.migrations_dir is '$MIG_DIR', but neither $TARGET nor this landing has that folder. Fix the key, then re-run."
    verdict refused-config "migrations_dir: no folder $MIG_DIR"; exit 7
  fi
  # NUL-delimited (see protected_paths), through files so a git failure still exits.
  [ -n "$MIG_TMP" ] || MIG_TMP="$(mktemp "${TMPDIR:-/tmp}/merge-queue-mig.XXXXXX")"
  added=(); all=()
  gdiff --name-only -z --diff-filter=A "$OLD" "$NEW" -- "$MIG_DIR/" > "$MIG_TMP"
  while IFS= read -r -d '' p; do added+=("$p"); done < "$MIG_TMP"
  git -C "$MAIN" ls-tree -z --name-only "$NEW" -- "$MIG_DIR/" > "$MIG_TMP"
  while IFS= read -r -d '' p; do all+=("$p"); done < "$MIG_TMP"
  for p in "${added[@]+"${added[@]}"}"; do
    [ "${p%/*}" = "$MIG_DIR" ] || continue
    base="${p##*/}"; num="$(rev_number "$base")"
    [ -n "$num" ] || continue
    for q in "${all[@]+"${all[@]}"}"; do
      qbase="${q##*/}"; qnum="$(rev_number "$qbase")"
      [ -n "$qnum" ] && [ "$((10#$qnum))" -eq "$((10#$num))" ] || continue
      [ "$(rev_stem "$qbase")" != "$(rev_stem "$base")" ] || continue
      where="also added by this landing"
      git -C "$MAIN" cat-file -e "$OLD:$q" 2>/dev/null && where="already on $TARGET"
      problems="$problems$p: number $num is taken by $q ($where)"$'\n'
    done
    [ -f "$STATE/reservations.tsv" ] || continue
    while IFS=$'\t' read -r holder rnum rdir _ts; do
      [ "$rdir" = "$MIG_DIR" ] && [ "$((10#$rnum))" -eq "$((10#$num))" ] || continue
      mine=0
      for i in "${!BRANCHES[@]}"; do
        if [ "${BRANCHES[$i]}" = "lane/$holder" ] && [ -n "$(gdiff --name-only --diff-filter=A "$OLD...${HEADS[$i]}" -- ":(literal)$p")" ]; then mine=1; fi
      done
      [ "$mine" -eq 1 ] || problems="$problems$p: number $num is reserved by lane/$holder"$'\n'
    done < "$STATE/reservations.tsv"
  done
  [ -n "$problems" ] || return 0
  echo "REFUSED: duplicate or reserved migration number in $MIG_DIR; $BRANCH was not landed."
  printf '%s' "$problems" | sed 's/^/  migration: /'
  echo "The owning lane takes a free number (lanes.sh reserve-migration <lane>), renames the file and its revision ids, and commits."
  verdict refused-migration "$problems"; exit 7
}

review_check
TMP="$(mktemp -d "${TMPDIR:-/tmp}/merge-queue.XXXXXX")"
rmdir "$TMP"
# The clean checkout runs with the project's git hooks off: a post-checkout
# hook that regenerates tracked files (seen 2026-11-15: a progress page) would
# leave the "clean" copy dirty, and git then refuses the rebase.
NOHOOKS=(-c core.hooksPath=/dev/null)
git "${NOHOOKS[@]}" -C "$MAIN" worktree add -q --detach "$TMP" "${HEADS[0]}"

# Several branches: each is rebased in turn onto the tip the previous one
# produced, so the gate below runs once on the combined result and the target
# moves once. A branch already contained in the previous ones rebases to nothing.
tip="$OLD"
for i in "${!BRANCHES[@]}"; do
  b="${BRANCHES[$i]}"
  [ "$i" -eq 0 ] || git "${NOHOOKS[@]}" -C "$TMP" checkout -q --detach "${HEADS[$i]}"
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
migration_check

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

LOG_DIR="$STATE/merge-queue.logs"
# Runs $1 in the clean checkout into its own numbered log (ATTEMPT_LOG) and sets
# rc. merge-queue.last-test.log is linked to that log before the run, so a tail
# of it never shows an earlier landing.
test_attempt() {
  local slug n=1
  mkdir -p "$LOG_DIR"
  slug="$(printf '%s' "$BRANCH" | tr '/ ' '-+' | tr -c 'A-Za-z0-9._+-' '_' | cut -c1-150)"
  while [ -e "$LOG_DIR/$slug-$n.log" ]; do n=$((n + 1)); done
  ATTEMPT_LOG="$LOG_DIR/$slug-$n.log"
  local last="$STATE/merge-queue.last-test.log"
  : > "$ATTEMPT_LOG"
  rm -f "$last"  # first: it may be a hard link to an earlier attempt's log
  ln "$ATTEMPT_LOG" "$last" 2>/dev/null || ln -s "merge-queue.logs/$slug-$n.log" "$last" 2>/dev/null || true
  set +e
  (cd "$TMP" && bash -c "$1") > "$ATTEMPT_LOG" 2>&1
  rc=$?
  set -e
  [ "$last" -ef "$ATTEMPT_LOG" ] || cp "$ATTEMPT_LOG" "$last"  # no links here
}
tests_failed() {  # $1 = result, $2 = detail
  echo "TESTS FAILED (exit $rc): $BRANCH was not landed. Output: $ATTEMPT_LOG"
  tail -n 20 "$ATTEMPT_LOG" | sed 's/^/  /'
  verdict "$1" "$2"; exit 4
}
# How many times flake:$1 was logged in the last 7 days.
recent_flakes() {
  local py
  [ -f "$LOG" ] || { echo 0; return 0; }
  py="$(bash "$HERE/py.sh" --print 2>/dev/null)" && [ -n "$py" ] || return 1
  "$py" - "$LOG" "flake:$1" <<'PYEOF' | tr -d '\r'
import json, sys, time, calendar
since = time.time() - 7 * 86400
n = 0
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    try:
        d = json.loads(line)
        if d.get("flake") == sys.argv[2] and calendar.timegm(time.strptime(d["ts"], "%Y-%m-%dT%H:%M:%SZ")) >= since:
            n += 1
    except Exception:
        pass
print(n)
PYEOF
}

echo "testing $BRANCH rebased on $TARGET (${NEW:0:12}) with: $TEST_CMD"
test_attempt "$TEST_CMD"
if [ "$rc" -ne 0 ]; then
  checks="$(sed -n 's/^merge-queue-failed-check:[[:space:]]*//p' "$ATTEMPT_LOG" | tr -d '\r' | sed 's/[[:space:]]*$//; /^$/d' | sort -u)"
  if [ -n "$checks" ] && [ "$(printf '%s\n' "$checks" | wc -l)" -eq 1 ]; then FAILED_CHECK="$checks"; fi
  case "$RERUN_CMD" in
    "") tests_failed tests-failed "exit $rc" ;;
    *'{check}'*) ;;
    *) echo "WARNING: pipeline.parallel.rerun_check_command has no {check} placeholder; nothing is rerun."
       tests_failed tests-failed "exit $rc" ;;
  esac
  if [ -z "$FAILED_CHECK" ]; then
    echo "no rerun: the gate output does not name exactly one failed check."
    tests_failed tests-failed "exit $rc"
  fi
  # One marker proves nothing about the checks after it: a gate killed or dying
  # partway prints one too. Only its own last line says it reached the end.
  last_line="$(tr -d '\r' < "$ATTEMPT_LOG" | sed 's/[[:space:]]*$//; /^$/d' | tail -n 1)"
  if [ "$rc" -ge 126 ] || ! [[ "$last_line" =~ ^merge-queue-gate-complete:[[:space:]]*failed=1$ ]]; then
    echo "no rerun: the gate did not show that it ran to the end with one failure (exit $rc; its last line must be 'merge-queue-gate-complete: failed=1')."
    tests_failed tests-failed "exit $rc"
  fi
  # The name comes from test output and goes into a shell command: plain
  # characters only, and never a leading dash.
  if ! [[ "$checks" =~ ^[A-Za-z0-9_][A-Za-z0-9._/:=@+-]*$ ]]; then
    echo "no rerun: the failed check's name has characters that are not allowed."
    tests_failed tests-failed "exit $rc"
  fi
  if ! seen="$(recent_flakes "$checks")"; then
    echo "no rerun: the flake history in $LOG cannot be read."
    tests_failed tests-failed "exit $rc"
  fi
  if [ "$seen" -ge 2 ]; then
    echo "FLAKE LIMIT: $checks flaked $seen times in the last 7 days; it is not rerun. Open a task to fix the check."
    tests_failed flake-limit "$checks"
  fi
  first_rc="$rc"; first_log="$ATTEMPT_LOG"
  rerun="${RERUN_CMD//\{check\}/$checks}"
  echo "gate failed (exit $first_rc, $first_log); rerunning only $checks once: $rerun"
  test_attempt "$rerun"
  [ "$rc" -eq 0 ] || tests_failed tests-failed "exit $first_rc; rerun of $checks exit $rc"
  FLAKE="flake:$checks"
  echo "FLAKE: $checks passed on its rerun. First run: $first_log; rerun: $ATTEMPT_LOG"
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

# A verdict or a reservation may also have been recorded during the test run.
review_check
migration_check

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
