#!/usr/bin/env bash
# brainstorm-toolkit — one git worktree and branch per writing agent (a "lane").
#
# WHY THIS EXISTS: two agents writing in one working folder fail each other's
# test gates with half-finished files, stage into one index, and race on every
# commit. A lane gives each writer its own folder, index and branch; read-only
# agents (research, review, measurement) need none and stay in the shared
# folder. Lanes are short-lived: open one per task, land it through
# scripts/merge-queue.sh, remove it.
#
# WHY A COPY STEP: a new worktree holds tracked files only -- no .env, no
# node_modules, no virtualenv. List what a lane needs in .worktreeinclude at
# the repo root (one path or glob per line, relative to the root, `#` comments;
# the same file Claude Code reads for `--worktree`). Absolute paths and `..`
# are refused so a lane can never be seeded from outside the repo. List only
# what a lane cannot rebuild cheaply and may legitimately hold: .env, local
# config, small gitignored test inputs. Keep large or private data out of it
# (a capture folder, a production export): copying it into every lane spreads
# it, and a test that needs it is better taught to skip when it is absent.
#
# WHY A SETUP HOOK: copied dependency folders are often not portable. A
# Python venv holds absolute paths and links into a cache, and on a Windows
# drive under WSL (/mnt/c, /mnt/e) a fresh worktree's first `uv sync` was
# measured to produce a broken venv (pygments and starlette failed to import,
# 2026-11-15); `uv sync --locked --reinstall --link-mode=copy` fixed it. So
# do not copy .venv; set .claude/project.json pipeline.parallel.lane_setup to
# the command that builds it, e.g.
#   "uv sync --locked --directory engine --link-mode=copy"
# (add --reinstall on a /mnt drive). node_modules is the same: prefer
# `npm --prefix portal ci` (or pnpm/yarn with a frozen lock) in lane_setup to
# copying the folder; copy it only when installs are slow and the tree holds
# no absolute paths. `create` runs lane_setup with `bash -c` in the new
# worktree's root after the copy step; merge-queue.sh runs it in its clean
# checkout too.
#
# WHY A COMPLETION MARKER: an install killed part-way (a caller's timeout hit
# `npm ci` on /mnt/e, 2026-11-22) left a half-installed lane that nothing
# noticed. Setup now counts as done only when the command exits 0 AND no
# package-lock.json folder has a node_modules without the
# node_modules/.package-lock.json npm writes at the end of an install; then it
# writes <git-dir>/lane-setup.done. A failure or a half install is retried
# pipeline.parallel.lane_setup_retries times (default 1). `check` reads the
# marker, so a lane whose setup was interrupted is caught before work starts.
# A lane made before the marker existed reports "never finished" until
# `lanes.sh setup <lane>` runs once there. npm 6 writes no
# node_modules/.package-lock.json: on npm 6, leave npm out of lane_setup.
#
# Subcommands:
#
#   lanes.sh create <name> [--base REF] [--dir PATH] [--no-setup]
#     New branch lane/<name> at REF (default: the main worktree's HEAD), in a
#     worktree at PATH (default: <repo-parent>/<repo>.lanes/<name>, a sibling,
#     so the main folder never sees the lane as untracked files). Copies the
#     .worktreeinclude entries, then runs pipeline.parallel.lane_setup there
#     unless --no-setup. Prints "lane=<name> branch=<b> base=<sha> path=<p>"
#     (path last, so `sed 's/.*path=//'` reads it; base is the expected tip
#     to put in the lane's brief).
#     If the setup command fails the lane is kept and the exit is 3.
#   lanes.sh copy-includes <dest>
#     Only the copy step, from the main worktree into <dest>; merge-queue.sh
#     uses it to seed its clean checkout.
#   lanes.sh setup <dest>
#     Only the setup step: run pipeline.parallel.lane_setup in <dest> (no-op
#     when unset), with the completion check and retries. merge-queue.sh uses
#     it too.
#   lanes.sh check <dest>
#     Exit 0 when the setup is complete (or none is configured), 3 when it never
#     finished or an npm install is half done, naming what is missing.
#   lanes.sh list [--target BRANCH]
#     One line per lane: name, branch, path, commits not yet on the target,
#     and held-until=<value> for a held lane.
#   lanes.sh held <name> --until <YYYY-MM-DD|lane>
#     Record that the lane waits for a date or for another open lane. A record
#     only: it releases and blocks nothing. It lives in the lane's git dir, so
#     `remove` drops it.
#   lanes.sh unheld <name>
#     Clear the hold.
#   lanes.sh reviewed <name> <sha> [--verdict accept|fix|reject]
#                     [--reviewer-model M]
#     Record a reviewer's verdict (default accept) on that commit of the lane,
#     in <state>/reviews.tsv. The latest row wins. merge-queue.sh reads it when
#     pipeline.parallel.review_required_paths is set.
#   lanes.sh reserve-migration <name> [--dir <versions dir>] [--target BRANCH]
#     Take the next migration number: one above the highest among the target's
#     files in the folder and the open reservations. Recorded in
#     <state>/reservations.tsv. --dir defaults to
#     pipeline.parallel.migrations_dir.
#   lanes.sh release-migration <name> [--number N]
#     Drop the lane's reservations (or only number N). `remove` does this too.
#   lanes.sh sync <name> [--target BRANCH]
#     Rebase the lane on the target now ("rebase early"): small conflicts found
#     today are cheaper than large ones at landing. On conflict it aborts the
#     rebase, prints the files, exits 2 -- it never resolves anything.
#   lanes.sh verify <name> --owned <glob>... [--base REF] [--target BRANCH]
#     Scope check: exit 1, naming the files, when the lane's diff against its
#     base (REF, else the merge-base with the target) touches a path matching
#     none of the globs. `*` matches across `/`, so `engine/*` is a subtree.
#     Exit 2 (not "in scope") when the diff itself fails, e.g. a bad --base.
#   lanes.sh remove <name> [--force] [--target BRANCH]
#     Remove the worktree and branch. Refuses (exit 1) while the lane has
#     commits whose changes are not on the target or uncommitted edits, unless
#     --force. "On the target" means git cherry (a lane landed by rebase counts)
#     OR every path the lane changed already equals the lane's version on the
#     target (a lane landed combined with other work). Lost content still refuses.
#
# --target defaults to the branch checked out in the main worktree.
set -euo pipefail

usage() { sed -n '48,106p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

[ $# -ge 1 ] || usage
SUB="$1"; shift

NAME=""; BASE=""; DIR=""; TARGET=""; FORCE=0; SETUP=1; OWNED=(); UNTIL=""
SHA=""; VERDICT="accept"; NUMBER=""; REVIEWER_MODEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base)   BASE="${2:-}"; shift 2 ;;
    --dir)    DIR="${2:-}"; shift 2 ;;
    --target) TARGET="${2:-}"; shift 2 ;;
    --force)  FORCE=1; shift ;;
    --until)  [ -n "${2:-}" ] || { echo "lanes.sh: --until needs a date or a lane" >&2; exit 2; }
              UNTIL="$2"; shift 2 ;;
    --verdict) [ -n "${2:-}" ] || { echo "lanes.sh: --verdict needs a value" >&2; exit 2; }
              VERDICT="$2"; shift 2 ;;
    --reviewer-model) [ -n "${2:-}" ] || { echo "lanes.sh: --reviewer-model needs a value" >&2; exit 2; }
              REVIEWER_MODEL="$2"; shift 2 ;;
    --number)[ -n "${2:-}" ] || { echo "lanes.sh: --number needs a value" >&2; exit 2; }
              NUMBER="$2"; shift 2 ;;
    --no-setup) SETUP=0; shift ;;
    --owned)  shift
              while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do OWNED+=("$1"); shift; done
              [ "${#OWNED[@]}" -gt 0 ] || { echo "lanes.sh: --owned needs at least one glob" >&2; exit 2; } ;;
    -h|--help) usage ;;
    --*) echo "lanes.sh: unknown flag $1" >&2; usage ;;
    *) if [ -z "$NAME" ]; then NAME="$1"
       elif [ "$SUB" = "reviewed" ] && [ -z "$SHA" ]; then SHA="$1"
       else echo "lanes.sh: unexpected argument $1" >&2; usage; fi
       shift ;;
  esac
done

common="$(git rev-parse --git-common-dir 2>/dev/null)" || { echo "lanes.sh: not inside a git repository" >&2; exit 2; }
MAIN="$(cd "$(dirname "$common")" && pwd)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${PARALLEL_STATE_DIR:-$MAIN/.claude/parallel}"
RESERVATIONS="$STATE/reservations.tsv"  # lane, number, folder, ts
[ -n "$TARGET" ] || TARGET="$(git -C "$MAIN" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"

valid_name() {
  case "$1" in ''|*[!A-Za-z0-9._-]*|.*) echo "lanes.sh: lane name must match [A-Za-z0-9._-]+ and not start with a dot" >&2; exit 2 ;; esac
}

# Path of the worktree whose branch is lane/<name>, empty if none.
lane_path() {
  git -C "$MAIN" worktree list --porcelain | awk -v b="refs/heads/lane/$1" '
    /^worktree /{p=substr($0,10)} $0=="branch " b && !f {print p; f=1}'
}

# Append one event (scripts/events.py). Never fails the command that did the work.
emit_event() {
  local py
  py="$(bash "$HERE/py.sh" --print 2>/dev/null)" && [ -n "$py" ] || return 0
  "$py" "$HERE/events.py" emit "$STATE" "$@" >/dev/null || true
}

# A lane's identity, in its git dir (so `remove` drops it): "<lane_id> <base>".
# The random suffix keeps two lanes that reuse one name apart in the reports.
lane_id_file() {
  local g; g="$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null)" && [ -n "$g" ] || return 1
  printf '%s/lane-id' "$g"
}
read_lane_id() {  # $1 = worktree ("" if none), $2 = name. Sets LANE_ID, LANE_BASE.
  local f; LANE_ID=""; LANE_BASE=""
  if [ -n "$1" ] && f="$(lane_id_file "$1")" && [ -f "$f" ]; then read -r LANE_ID LANE_BASE < "$f" || true; fi
  [ -n "$LANE_ID" ] || LANE_ID="$2"  # a lane made before ids existed
}
lane_area() { printf '%s' "${1%%[-._]*}"; }

copy_includes() {
  local dest="$1" inc="$MAIN/.worktreeinclude" line rel
  [ -f "$inc" ] || return 0
  shopt -s nullglob dotglob; shopt -s globstar 2>/dev/null || true  # globstar: bash 4+
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"; line="$(printf '%s' "$line" | sed 's/[[:space:]]*$//; s/^[[:space:]]*//')"
    [ -n "$line" ] || continue
    case "$line" in /*|*..*) echo "lanes.sh: skipping unsafe .worktreeinclude entry: $line" >&2; continue ;; esac
    line="${line%/}"
    # shellcheck disable=SC2086  # the glob is the point
    for src in "$MAIN"/$line; do
      [ -e "$src" ] || continue
      rel="${src#"$MAIN"/}"
      mkdir -p "$dest/$(dirname "$rel")"
      cp -R "$src" "$dest/$(dirname "$rel")/"
      echo "copied: $rel"
    done
  done < "$inc"
  shopt -u nullglob dotglob; shopt -u globstar 2>/dev/null || true
}

# The configured lane_setup command, empty when unset.
setup_cmd() {
  local cfg="$MAIN/.claude/project.json" py here
  [ -f "$cfg" ] || return 0
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  py="$(bash "$here/py.sh" --print 2>/dev/null)" || return 0
  [ -n "$py" ] || return 0
  "$py" - "$cfg" <<'PYEOF' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
v = ((d.get("pipeline") or {}).get("parallel") or {}).get("lane_setup")
print(v if isinstance(v, str) else "")
PYEOF
}

# pipeline.parallel.lane_setup_retries: a whole number 0-5, default 1.
setup_retries() {
  local cfg="$MAIN/.claude/project.json" py here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  { [ -f "$cfg" ] && py="$(bash "$here/py.sh" --print 2>/dev/null)" && [ -n "$py" ]; } || { echo 1; return 0; }
  "$py" - "$cfg" <<'PYEOF' 2>/dev/null || echo 1
import json, sys
try:
    v = json.load(open(sys.argv[1], encoding="utf-8"))["pipeline"]["parallel"]["lane_setup_retries"]
except Exception:
    v = 1
print(v if isinstance(v, int) and not isinstance(v, bool) and 0 <= v <= 5 else 1)
PYEOF
}

setup_marker() {
  local g; g="$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null)" && [ -n "$g" ] || return 1
  printf '%s/lane-setup.done' "$g"
}

# Folders (relative to $1) with a package-lock.json whose node_modules exists
# but lacks node_modules/.package-lock.json: an npm install that started and
# did not finish. Depth 3, never inside node_modules.
npm_half_installed() {
  local lock d
  while IFS= read -r lock; do
    d="$(dirname "$lock")"
    [ -d "$d/node_modules" ] && [ ! -f "$d/node_modules/.package-lock.json" ] || continue
    # Only a node_modules holding packages counts; .cache/.vite alone are tool caches.
    [ -n "$(ls "$d/node_modules" 2>/dev/null | head -n 1)" ] && printf '%s\n' "${d#"$1"/}"
  done < <(find "$1" -maxdepth 3 -name node_modules -prune -o -name package-lock.json -print 2>/dev/null)
  return 0
}

run_setup() {  # $1 = worktree root. Returns 0 when the setup completed.
  local cmd tries n=0 rc half marker
  cmd="$(setup_cmd)"
  marker="$(setup_marker "$1")" || { echo "lanes.sh: $1 is not a git checkout" >&2; return 2; }
  rm -f "$marker"
  if [ -z "$cmd" ]; then printf 'none\n' > "$marker"; return 0; fi
  tries=$(( $(setup_retries) + 1 ))
  while :; do
    n=$((n + 1))
    echo "lane setup in $1 (attempt $n of $tries): $cmd"
    # No set +e/-e toggling here: a caller already under set +e must keep it.
    if (cd "$1" && bash -c "$cmd"); then rc=0; else rc=$?; fi
    half="$(npm_half_installed "$1")"
    if [ "$rc" -eq 0 ] && [ -z "$half" ]; then
      printf '%s\n' "$cmd" > "$marker"
      return 0
    fi
    [ -n "$half" ] && echo "lanes.sh: npm install incomplete in: $(printf '%s' "$half" | tr '\n' ' ')" >&2
    [ "$rc" -ne 0 ] || rc=3
    [ "$n" -lt "$tries" ] || return "$rc"
    echo "lanes.sh: setup failed (exit $rc); retrying" >&2
  done
}

# 0 = setup complete or none configured; 3 = not finished, with the reason.
check_setup() {
  local half marker cmd
  marker="$(setup_marker "$1")" || { echo "lanes.sh: $1 is not a git checkout"; return 2; }
  cmd="$(setup_cmd)"
  if [ -n "$cmd" ] && [ ! -f "$marker" ]; then
    echo "setup incomplete: lane_setup never finished in $1 (run: lanes.sh setup $1)"; return 3
  fi
  # The marker holds the command that ran; a lane set up under another one is stale.
  if [ -n "$cmd" ] && [ "$(cat "$marker" 2>/dev/null)" != "$cmd" ]; then
    echo "setup incomplete: lane_setup changed since this lane was set up (run: lanes.sh setup $1)"; return 3
  fi
  half="$(npm_half_installed "$1")"
  if [ -n "$half" ]; then
    echo "setup incomplete: npm install half done in: $(printf '%s' "$half" | tr '\n' ' ')(run: lanes.sh setup $1)"; return 3
  fi
  echo "setup complete: $1"
}

held_marker() {  # $1 = worktree root
  local g; g="$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null)" && [ -n "$g" ] || return 1
  printf '%s/lane-held' "$g"
}

unlanded() {  # commits on lane/<name> whose patch is not on TARGET
  git -C "$MAIN" cherry "$TARGET" "lane/$1" 2>/dev/null | grep -c '^+' || true
}

# Paths the lane changed against its base: --base REF, else the merge-base
# with the target.
lane_changed() {
  local base="$BASE"
  [ -n "$base" ] || base="$(git -C "$MAIN" merge-base "$TARGET" "lane/$1")" || return 1
  git -C "$MAIN" diff --name-only --no-renames "$base" "lane/$1"
}

# True when every path the lane changed already has the lane's content on the
# TARGET -- the lane landed combined with other changes or rebased, so git cherry
# still lists its commits. Content that would be lost makes this false.
content_landed() {
  local paths path; paths="$(lane_changed "$1")" || return 1
  [ -n "$paths" ] || return 0
  local args=(); while IFS= read -r path; do args+=("$path"); done <<<"$paths"
  git -C "$MAIN" diff --quiet "$TARGET" "lane/$1" -- "${args[@]}"
}

# pipeline.parallel.migrations_dir, empty when unset.
configured_migrations_dir() {
  local cfg="$MAIN/.claude/project.json" py
  [ -f "$cfg" ] || return 0
  py="$(bash "$HERE/py.sh" --print 2>/dev/null)" && [ -n "$py" ] || return 0
  "$py" - "$cfg" <<'PYEOF' 2>/dev/null | tr -d '\r' || true
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
v = ((d.get("pipeline") or {}).get("parallel") or {}).get("migrations_dir")
print(v if isinstance(v, str) else "")
PYEOF
}

# One writer of reservations.tsv at a time, so two lanes never get one number.
# The lease is released on exit.
lock_reservations() {
  local holder="lanes-$$" i
  mkdir -p "$STATE"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if (cd "$MAIN" && PARALLEL_STATE_DIR="$STATE" bash "$HERE/lease.sh" acquire migration-reservations --holder "$holder" --ttl 60) >/dev/null 2>&1; then
      # shellcheck disable=SC2064  # expand now: holder is local
      trap "cd '$MAIN' && PARALLEL_STATE_DIR='$STATE' bash '$HERE/lease.sh' release migration-reservations --holder '$holder' >/dev/null 2>&1 || true" EXIT
      return 0
    fi
    sleep 1
  done
  echo "lanes.sh: the migration-reservations lease is busy; re-run" >&2
  exit 3
}

drop_reservations() {  # $1 = lane, $2 = number or empty for all. Prints each dropped row.
  [ -f "$RESERVATIONS" ] || return 0
  local lane num dir ts keep="$RESERVATIONS.$$"
  : > "$keep"
  while IFS=$'\t' read -r lane num dir ts; do
    if [ "$lane" = "$1" ] && { [ -z "$2" ] || [ "$((10#$num))" -eq "$((10#$2))" ]; }; then
      echo "released: $num lane=$lane dir=$dir"
    else
      printf '%s\t%s\t%s\t%s\n' "$lane" "$num" "$dir" "$ts" >> "$keep"
    fi
  done < "$RESERVATIONS"
  mv "$keep" "$RESERVATIONS"
}

need_target() { [ -n "$TARGET" ] || { echo "lanes.sh: no --target and the main worktree is on a detached HEAD" >&2; exit 2; }; }

case "$SUB" in
  create)
    valid_name "$NAME"
    git -C "$MAIN" show-ref --verify --quiet "refs/heads/lane/$NAME" && { echo "lanes.sh: branch lane/$NAME already exists" >&2; exit 1; }
    [ -n "$BASE" ] || BASE="$(git -C "$MAIN" rev-parse HEAD)"
    [ -n "$DIR" ] || DIR="$(dirname "$MAIN")/$(basename "$MAIN").lanes/$NAME"
    [ ! -e "$DIR" ] || { echo "lanes.sh: $DIR already exists" >&2; exit 1; }
    mkdir -p "$(dirname "$DIR")"
    # Project hooks off for the checkout: a post-checkout hook that regenerates
    # tracked files (seen 2026-11-15) would leave a new lane dirty before any
    # work, and those edits could be committed by mistake.
    git -c core.hooksPath=/dev/null -C "$MAIN" worktree add -q -b "lane/$NAME" "$DIR" "$BASE"
    DIR="$(cd "$DIR" && pwd)"
    base_sha="$(git -C "$DIR" rev-parse HEAD)"
    lane_id="$NAME.$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
    printf '%s %s\n' "$lane_id" "$base_sha" > "$(lane_id_file "$DIR")"
    emit_event lane.opened "lane_id=$lane_id" "area=$(lane_area "$NAME")" "base_sha=$base_sha"
    copy_includes "$DIR"
    if [ "$SETUP" -eq 1 ]; then
      set +e; run_setup "$DIR"; rc=$?; set -e
      if [ "$rc" -ne 0 ]; then
        echo "lanes.sh: lane_setup failed (exit $rc) in $DIR; the lane is kept. Fix the setup and re-run it there, or remove the lane." >&2
        echo "lane=$NAME branch=lane/$NAME setup=failed base=$(git -C "$DIR" rev-parse HEAD) path=$DIR"
        exit 3
      fi
    fi
    echo "lane=$NAME branch=lane/$NAME base=$(git -C "$DIR" rev-parse HEAD) path=$DIR"
    ;;
  setup)
    [ -n "$NAME" ] && [ -d "$NAME" ] || { echo "lanes.sh setup: destination directory required" >&2; exit 2; }
    run_setup "$(cd "$NAME" && pwd)"
    ;;
  check)
    [ -n "$NAME" ] && [ -d "$NAME" ] || { echo "lanes.sh check: lane directory required" >&2; exit 2; }
    check_setup "$(cd "$NAME" && pwd)"
    ;;
  copy-includes)
    [ -n "$NAME" ] && [ -d "$NAME" ] || { echo "lanes.sh copy-includes: destination directory required" >&2; exit 2; }
    copy_includes "$(cd "$NAME" && pwd)"
    ;;
  list)
    git -C "$MAIN" worktree list --porcelain | awk '
      /^worktree /{p=substr($0,10)} /^branch refs\/heads\/lane\//{print substr($0,24) "\t" p}' |
    while IFS=$'\t' read -r n p; do
      line="$(printf '%s\tlane/%s\t%s' "$n" "$n" "$p")"
      [ -z "$TARGET" ] || line="$line"$'\t'"unlanded=$(unlanded "$n")"
      if m="$(held_marker "$p")" && [ -f "$m" ]; then line="$line"$'\t'"held-until=$(cat "$m")"; fi
      printf '%s\n' "$line"
    done
    ;;
  held)
    valid_name "$NAME"
    [ -n "$UNTIL" ] || { echo "lanes.sh held: --until <YYYY-MM-DD|lane> is required" >&2; exit 2; }
    p="$(lane_path "$NAME")"; [ -n "$p" ] || { echo "lanes.sh: no lane named $NAME" >&2; exit 1; }
    case "$UNTIL" in
      [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]) ;;
      *) UNTIL="${UNTIL#lane/}"
         { [ "$UNTIL" != "$NAME" ] && git -C "$MAIN" show-ref --verify --quiet "refs/heads/lane/$UNTIL"; } || {
           echo "lanes.sh held: --until must be a YYYY-MM-DD date or another existing lane, got $UNTIL" >&2; exit 2; } ;;
    esac
    m="$(held_marker "$p")"; printf '%s\n' "$UNTIL" > "$m"
    echo "held: lane/$NAME until $UNTIL"
    ;;
  unheld)
    valid_name "$NAME"
    p="$(lane_path "$NAME")"; [ -n "$p" ] || { echo "lanes.sh: no lane named $NAME" >&2; exit 1; }
    m="$(held_marker "$p")"; rm -f "$m"
    echo "unheld: lane/$NAME"
    ;;
  reviewed)
    NAME="${NAME#lane/}"; valid_name "$NAME"
    git -C "$MAIN" show-ref --verify --quiet "refs/heads/lane/$NAME" || { echo "lanes.sh: no lane named $NAME" >&2; exit 1; }
    case "$VERDICT" in accept|fix|reject) ;; *) echo "lanes.sh reviewed: --verdict must be accept, fix or reject" >&2; exit 2 ;; esac
    # A sha only: a branch name or HEAD would record whatever is there now, not
    # what the reviewer read.
    case "$SHA" in ''|*[!0-9a-f]*) echo "lanes.sh reviewed: give the commit sha the reviewer read" >&2; exit 2 ;; esac
    [ "${#SHA}" -ge 7 ] || { echo "lanes.sh reviewed: the sha needs at least 7 characters" >&2; exit 2; }
    full="$(git -C "$MAIN" rev-parse --verify --quiet "$SHA^{commit}")" || { echo "lanes.sh reviewed: no commit $SHA" >&2; exit 1; }
    git -C "$MAIN" merge-base --is-ancestor "$full" "refs/heads/lane/$NAME" || { echo "lanes.sh reviewed: $SHA is not on lane/$NAME" >&2; exit 1; }
    mkdir -p "$STATE"
    read_lane_id "$(lane_path "$NAME")" "$NAME"
    printf 'lane/%s\t%s\t%s\t%s\t%s\n' "$NAME" "$full" "$VERDICT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LANE_ID" >> "$STATE/reviews.tsv"
    # Rows from before ids existed count only for a lane that has none.
    round="$(awk -F'\t' -v b="lane/$NAME" -v id="$LANE_ID" -v n="$NAME" '$1==b && ($5==id || ($5=="" && id==n)){c++} END{print c+0}' "$STATE/reviews.tsv")"
    emit_event review.verdict "lane_id=$LANE_ID" "attempt=$round" "round=$round" "verdict=$VERDICT" "reviewer_model=$REVIEWER_MODEL"
    echo "reviewed: lane/$NAME $full verdict=$VERDICT"
    ;;
  reserve-migration)
    NAME="${NAME#lane/}"; valid_name "$NAME"; need_target
    git -C "$MAIN" show-ref --verify --quiet "refs/heads/lane/$NAME" || { echo "lanes.sh: no lane named $NAME" >&2; exit 1; }
    [ -n "$DIR" ] || DIR="$(configured_migrations_dir)"
    DIR="${DIR#./}"; DIR="${DIR%/}"
    case "$DIR" in ''|/*|*..*) echo "lanes.sh reserve-migration: give --dir (relative to the repo root) or set pipeline.parallel.migrations_dir" >&2; exit 2 ;; esac
    lock_reservations
    names="$(git -C "$MAIN" -c core.quotePath=false ls-tree --name-only "refs/heads/$TARGET" -- "$DIR/")"
    # A mistyped folder would otherwise hand out number 1.
    [ -n "$names" ] || { echo "lanes.sh reserve-migration: no folder $DIR on $TARGET" >&2; exit 1; }
    max=0; width=4; found=0
    while IFS= read -r f; do
      f="${f##*/}"
      [[ "$f" =~ ^([0-9]+)[._-] ]] || continue
      num="${BASH_REMATCH[1]}"
      if [ "$found" -eq 0 ] || [ "$((10#$num))" -gt "$max" ]; then max="$((10#$num))"; width="${#num}"; found=1; fi
    done <<<"$names"
    if [ -f "$RESERVATIONS" ]; then
      while IFS=$'\t' read -r _lane num rdir _ts; do
        [ "$rdir" = "$DIR" ] || continue
        if [ "$((10#$num))" -gt "$max" ]; then max="$((10#$num))"; width="${#num}"; fi
      done < "$RESERVATIONS"
    fi
    next="$(printf '%0*d' "$width" "$((max + 1))")"
    printf '%s\t%s\t%s\t%s\n' "$NAME" "$next" "$DIR" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$RESERVATIONS"
    echo "reserved: $next lane=$NAME dir=$DIR"
    ;;
  release-migration)
    # No lane-exists check: a reservation can outlive a branch deleted by hand.
    NAME="${NAME#lane/}"; valid_name "$NAME"
    case "$NUMBER" in *[!0-9]*) echo "lanes.sh release-migration: --number must be digits" >&2; exit 2 ;; esac
    lock_reservations
    out="$(drop_reservations "$NAME" "$NUMBER")"
    [ -n "$out" ] || { echo "lanes.sh release-migration: lane/$NAME holds no such reservation" >&2; exit 1; }
    printf '%s\n' "$out"
    ;;
  sync)
    valid_name "$NAME"; need_target
    p="$(lane_path "$NAME")"; [ -n "$p" ] || { echo "lanes.sh: no lane named $NAME" >&2; exit 1; }
    if ! git -C "$p" diff --quiet || ! git -C "$p" diff --cached --quiet; then
      echo "lanes.sh: lane $NAME has uncommitted edits; commit them before sync" >&2; exit 1
    fi
    if git -c core.hooksPath=/dev/null -C "$p" rebase -q "$TARGET" >/dev/null 2>&1; then
      echo "synced: lane/$NAME onto $TARGET"
    else
      files="$(git -C "$p" diff --name-only --diff-filter=U)"
      git -C "$p" rebase --abort >/dev/null 2>&1 || true
      echo "CONFLICT: lane/$NAME does not rebase cleanly onto $TARGET; rebase aborted, nothing changed"
      printf '%s\n' "$files" | sed '/^$/d; s/^/  conflict: /'
      echo "Hand this back to the lane's owner (or the orchestrator). Do not auto-resolve."
      exit 2
    fi
    ;;
  verify)
    valid_name "$NAME"
    [ "${#OWNED[@]}" -gt 0 ] || { echo "lanes.sh verify: --owned <glob>... is required" >&2; exit 2; }
    [ -n "$BASE" ] || need_target
    git -C "$MAIN" show-ref --verify --quiet "refs/heads/lane/$NAME" || { echo "lanes.sh: no lane named $NAME" >&2; exit 1; }
    # Capture first: a process substitution would swallow a git failure (bad
    # --base, no common ancestor) and report "in scope" -- failing open.
    files="$(lane_changed "$NAME")" || { echo "lanes.sh verify: cannot diff lane/$NAME against its base; nothing was verified" >&2; exit 2; }
    stray=""
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      ok=0
      for g in "${OWNED[@]}"; do
        # shellcheck disable=SC2254  # the glob is the point; `*` also crosses `/`
        case "$f" in $g) ok=1; break ;; esac
      done
      [ "$ok" -eq 1 ] || stray="$stray$f"$'\n'
    done <<<"$files"
    if [ -n "$stray" ]; then
      echo "OUT OF SCOPE: lane/$NAME changed paths outside its owned globs (${OWNED[*]}):"
      printf '%s' "$stray" | sed 's/^/  /'
      exit 1
    fi
    echo "in scope: lane/$NAME touches only its owned paths"
    ;;
  remove)
    valid_name "$NAME"
    p="$(lane_path "$NAME")"
    if [ "$FORCE" -ne 1 ]; then
      need_target
      n="$(unlanded "$NAME")"
      if [ "$n" -ne 0 ]; then
        if BASE="" content_landed "$NAME"; then
          echo "lanes.sh: lane/$NAME's commits differ from $TARGET's, but every path it changed already matches $TARGET (landed combined or rebased); treating as landed"
        else
          echo "lanes.sh: lane/$NAME has $n commit(s) not on $TARGET; land them or pass --force" >&2; exit 1
        fi
      fi
      if [ -n "$p" ] && [ -n "$(git -C "$p" status --porcelain)" ]; then
        echo "lanes.sh: lane $NAME has uncommitted or untracked files; pass --force to discard them" >&2; exit 1
      fi
    fi
    existed=0
    if [ -n "$p" ] || git -C "$MAIN" show-ref --verify --quiet "refs/heads/lane/$NAME"; then existed=1; fi
    read_lane_id "$p" "$NAME"  # before the git dir goes
    if [ -n "$p" ]; then
      if [ "$FORCE" -eq 1 ]; then git -C "$MAIN" worktree remove --force "$p"; else git -C "$MAIN" worktree remove "$p"; fi
    fi
    git -C "$MAIN" worktree prune
    git -C "$MAIN" branch -q -D "lane/$NAME" 2>/dev/null || true
    if [ "$existed" -eq 1 ]; then
      forced=false; [ "$FORCE" -ne 1 ] || forced=true
      emit_event lane.closed "lane_id=$LANE_ID" "area=$(lane_area "$NAME")" "base_sha=$LANE_BASE" "forced=$forced"
    fi
    if [ -f "$RESERVATIONS" ]; then lock_reservations; drop_reservations "$NAME" ""; fi
    echo "removed: lane/$NAME"
    ;;
  -h|--help) usage ;;
  *) echo "lanes.sh: unknown subcommand $SUB" >&2; usage ;;
esac
