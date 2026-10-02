#!/usr/bin/env bash
# brainstorm-toolkit — shared helper, sourced (not executed) by the hooks under
# scripts/hooks/ that read .claude/project.json's `python` key.
#
# WHY THIS EXISTS: two separate gaps found in the same spot.
#
#   1. enforce-model-cap.sh only probed python3/python (never `py`), so on a
#      Windows machine whose ONLY working interpreter is the `py` launcher,
#      `pipeline.enforce_cap: true` silently enforced nothing -- the hook
#      exited 0 before ever reading models.cap. hooks_resolve_python() below
#      gives every hook the SAME three-tier order scripts/py.sh documents:
#      $BRAINSTORM_PYTHON -> .claude/project.json `python` -> probe
#      python3/python/py, each candidate proven to RUN, not merely resolve.
#   2. Every hook that reads that `python` key was executing a value from the
#      OPENED REPO's .claude/project.json with no validation -- a repo you
#      merely open could set "python": "/some/arbitrary/binary" and an
#      always-on Stop/SessionStart hook would run it. hooks_is_plausible_python()
#      is the gate: accept only a value whose basename looks like a Python
#      interpreter, or whose `--version` output actually says Python. Anything
#      else is ignored (never executed), and the caller falls back to the probe.
#
# Usage: `. "$(dirname "$0")/_pyresolve.sh"` then call hooks_resolve_python "$PROJ".

# hooks_is_plausible_python <candidate>
# True if $1 is worth running at all -- checked BEFORE the candidate is ever
# invoked, since the actual "does it run" proof (`"$cand" -c 'pass'`) already
# executes it once, and a config-supplied arbitrary binary should not get that
# one free execution either.
hooks_is_plausible_python() {
  local val="$1" base
  [ -n "$val" ] || return 1
  base="$(basename "$val" 2>/dev/null)"
  case "$base" in
    python|python3|py|python.exe|python3.exe|py.exe) return 0 ;;
    python3.[0-9]*|python3.[0-9]*.exe) return 0 ;;
  esac
  # Not a recognised name -- it may still be a real interpreter at an unusual
  # path (a venv, a pyenv shim). Prove it by asking, not by running it as code:
  # `--version` is the one flag every CPython/PyPy build answers without
  # executing any program logic.
  case "$("$val" --version 2>&1)" in
    *Python\ [0-9]*|*python\ [0-9]*) return 0 ;;
  esac
  return 1
}

# hooks_resolve_python <project-root>
# Prints the resolved interpreter (a bare command name or an absolute path) on
# stdout and returns 0, or prints nothing and returns 1 if none was found.
# Order matches scripts/py.sh: env override -> project.json `python` key
# (validated by hooks_is_plausible_python, then proven to run) -> probe.
# A rejected or non-running project.json value is reported on stderr once,
# never executed, and resolution falls through to the probe rather than
# failing outright -- a hostile or stale config must not brick the hook.
hooks_resolve_python() {
  local proj="$1" py="" cand=""

  if [ -n "${BRAINSTORM_PYTHON:-}" ] && "${BRAINSTORM_PYTHON}" -c 'pass' >/dev/null 2>&1; then
    py="$BRAINSTORM_PYTHON"
  fi

  if [ -z "$py" ] && [ -f "$proj/.claude/project.json" ]; then
    cand="$(sed -n 's/.*"python"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
          "$proj/.claude/project.json" 2>/dev/null | head -n 1)"
    if [ -n "$cand" ]; then
      if hooks_is_plausible_python "$cand" && "$cand" -c 'pass' >/dev/null 2>&1; then
        py="$cand"
      else
        echo "hooks: ignoring .claude/project.json 'python' value '$cand' -- not a plausible Python interpreter; falling back" >&2
      fi
    fi
  fi

  if [ -z "$py" ]; then
    local c
    for c in python3 python py; do
      if command -v "$c" >/dev/null 2>&1 && "$c" -c 'pass' >/dev/null 2>&1; then py="$c"; break; fi
    done
  fi

  [ -n "$py" ] || return 1
  printf '%s\n' "$py"
}
