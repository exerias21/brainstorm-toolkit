#!/usr/bin/env bash
# brainstorm-toolkit — the ONE place that resolves a Python interpreter.
#
# WHY THIS EXISTS: there is no portable token. `python3` is a Microsoft Store
# STUB on Windows -- it resolves on PATH, prints "Python was not found; run
# without arguments to install from the Microsoft Store", opens the Store, and
# exits non-zero. `python` does not exist on stock macOS or on Debian/Ubuntu
# without python-is-python3. So every shipped command that named one of them
# was wrong on some platform, and 14 of them named `python3`.
#
# Five scripts here (close-tasks.sh, record-decision.sh, and the reseed,
# cost-report and stop-gate hooks) already solved this inline with the probe
# below. The knowledge never reached the PROSE, which is how the Store popup
# kept firing on every /sdlc run in a skill repo. One resolver, cited from
# everywhere, is the fix -- not 14 copies of a probe.
#
# Resolution order:
#   1. $BRAINSTORM_PYTHON            (env override; wins everywhere)
#   2. .claude/project.json `python` (per-repo, per-OS -- set it to whatever
#                                     your machine actually has)
#   3. probe python3 -> python -> py, taking the first that RUNS
#
# Step 3 proves the interpreter EXECUTES rather than merely resolving on PATH.
# That distinction is the whole point: the Store stub passes `command -v` and
# then fails, so a `command -v`-only probe picks exactly the broken one.
#
# Usage:
#   bash scripts/py.sh <script.py> [args...]   # run a script
#   bash scripts/py.sh --print                 # print the resolved interpreter
set -u

PROJ="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$PROJ" ]; then
  if _gr="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$_gr" ]; then
    PROJ="$_gr"
  else
    PROJ="$PWD"
  fi
fi

PY=""

# 1. env override
if [ -n "${BRAINSTORM_PYTHON:-}" ]; then
  PY="$BRAINSTORM_PYTHON"
fi

# 2. .claude/project.json `python` -- read WITHOUT python (chicken-and-egg: we
# cannot parse JSON with the interpreter we are trying to find). sed is enough
# for one top-level string scalar.
if [ -z "$PY" ] && [ -f "$PROJ/.claude/project.json" ]; then
  PY="$(sed -n 's/.*"python"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$PROJ/.claude/project.json" 2>/dev/null | head -n 1)"
fi

# A configured value that does not RUN is worse than none -- fall through to the
# probe rather than failing, so a stale config cannot brick every skill.
if [ -n "$PY" ] && ! "$PY" -c 'pass' >/dev/null 2>&1; then
  echo "py.sh: configured python '$PY' did not run; falling back to probe" >&2
  PY=""
fi

# 3. probe
if [ -z "$PY" ]; then
  for c in python3 python py; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c 'pass' >/dev/null 2>&1; then
      PY="$c"
      break
    fi
  done
fi

if [ -z "$PY" ]; then
  echo "py.sh: no working Python found (tried \$BRAINSTORM_PYTHON, .claude/project.json \`python\`, then python3/python/py)." >&2
  echo "       On Windows, \`python3\` is usually a Microsoft Store stub that resolves and then fails --" >&2
  echo "       set \`python\` in .claude/project.json to the interpreter you actually have." >&2
  exit 1
fi

if [ "${1:-}" = "--print" ]; then
  echo "$PY"
  exit 0
fi

exec "$PY" "$@"
