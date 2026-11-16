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
#     when unset). merge-queue.sh uses it too.
#   lanes.sh list [--target BRANCH]
#     One line per lane: name, branch, path, commits not yet on the target.
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

usage() { sed -n '38,71p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

[ $# -ge 1 ] || usage
SUB="$1"; shift

NAME=""; BASE=""; DIR=""; TARGET=""; FORCE=0; SETUP=1; OWNED=()
while [ $# -gt 0 ]; do
  case "$1" in
    --base)   BASE="${2:-}"; shift 2 ;;
    --dir)    DIR="${2:-}"; shift 2 ;;
    --target) TARGET="${2:-}"; shift 2 ;;
    --force)  FORCE=1; shift ;;
    --no-setup) SETUP=0; shift ;;
    --owned)  shift
              while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do OWNED+=("$1"); shift; done
              [ "${#OWNED[@]}" -gt 0 ] || { echo "lanes.sh: --owned needs at least one glob" >&2; exit 2; } ;;
    -h|--help) usage ;;
    --*) echo "lanes.sh: unknown flag $1" >&2; usage ;;
    *) [ -z "$NAME" ] || { echo "lanes.sh: unexpected argument $1" >&2; usage; }; NAME="$1"; shift ;;
  esac
done

common="$(git rev-parse --git-common-dir 2>/dev/null)" || { echo "lanes.sh: not inside a git repository" >&2; exit 2; }
MAIN="$(cd "$(dirname "$common")" && pwd)"
[ -n "$TARGET" ] || TARGET="$(git -C "$MAIN" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"

valid_name() {
  case "$1" in ''|*[!A-Za-z0-9._-]*|.*) echo "lanes.sh: lane name must match [A-Za-z0-9._-]+ and not start with a dot" >&2; exit 2 ;; esac
}

# Path of the worktree whose branch is lane/<name>, empty if none.
lane_path() {
  git -C "$MAIN" worktree list --porcelain | awk -v b="refs/heads/lane/$1" '
    /^worktree /{p=substr($0,10)} $0=="branch " b {print p; exit}'
}

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

run_setup() {  # $1 = worktree root. Returns the command's exit code.
  local cmd; cmd="$(setup_cmd)"
  [ -n "$cmd" ] || return 0
  echo "lane setup in $1: $cmd"
  (cd "$1" && bash -c "$cmd")
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
  copy-includes)
    [ -n "$NAME" ] && [ -d "$NAME" ] || { echo "lanes.sh copy-includes: destination directory required" >&2; exit 2; }
    copy_includes "$(cd "$NAME" && pwd)"
    ;;
  list)
    git -C "$MAIN" worktree list --porcelain | awk '
      /^worktree /{p=substr($0,10)} /^branch refs\/heads\/lane\//{print substr($0,24) "\t" p}' |
    while IFS=$'\t' read -r n p; do
      if [ -n "$TARGET" ]; then printf '%s\tlane/%s\t%s\tunlanded=%s\n' "$n" "$n" "$p" "$(unlanded "$n")"
      else printf '%s\tlane/%s\t%s\n' "$n" "$n" "$p"; fi
    done
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
    if [ -n "$p" ]; then
      if [ "$FORCE" -eq 1 ]; then git -C "$MAIN" worktree remove --force "$p"; else git -C "$MAIN" worktree remove "$p"; fi
    fi
    git -C "$MAIN" worktree prune
    git -C "$MAIN" branch -q -D "lane/$NAME" 2>/dev/null || true
    echo "removed: lane/$NAME"
    ;;
  -h|--help) usage ;;
  *) echo "lanes.sh: unknown subcommand $SUB" >&2; usage ;;
esac
