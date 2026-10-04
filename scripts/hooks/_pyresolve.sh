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
#      merely open could set "python": "./evil.sh" (or "bin/python3", a
#      repo-shipped file) and an always-on Stop/SessionStart hook would run
#      it -- the ORIGINAL fix here still shelled out to an unrecognised
#      basename's `--version` to see if it "looked like Python", which is
#      itself an unconditional execution of arbitrary repo content. A LATER
#      fix accepted an absolute path as long as it did not resolve (by
#      string comparison, after a `cd` + `pwd -P` normalization) under the
#      project root -- that comparison is whack-a-mole: it is case-sensitive,
#      so on a case-insensitive filesystem (NTFS, default macOS) a
#      differently-cased spelling of a repo-shipped path (`/C/<real
#      path>/repo/bin/python3` when the real path is `/c/...`) resolves to
#      the exact same on-disk file yet compares unequal and slips through;
#      and without `git` on PATH to resolve a mount-alias spelling, two
#      strings naming the same directory can likewise fail to compare equal.
#      The CURRENT rule removes path comparison entirely: a `"python"` value
#      read from the repo's .claude/project.json is accepted ONLY as a BARE
#      command name -- no path separator (`/` or `\`) and no drive prefix
#      (`X:`) anywhere in it -- whose name is one of the known Python names
#      (python, python3, py, python3.N, each optionally with .exe). Anything
#      containing a separator or a drive letter is rejected outright, no
#      probe, no exception, regardless of basename or where it points --
#      a value is never treated as a filesystem path at all, so there is no
#      path comparison left to get wrong. The accepted bare name is then
#      resolved through PATH -- but stripping just `.`/empty PATH entries
#      from the LOOKUP is not enough on its own: (a) a RELATIVE PATH entry
#      (`bin`, `./bin`) still lets a repo-shipped `bin/python3` win the
#      lookup without ever being `.` itself, and (b) resolving safely once
#      and then handing a caller the BARE name back (`py="$cand"`) throws
#      the safety away -- every later `"$py" ...` (hooks_read_top_level_python
#      parsing project.json, and every hook under scripts/hooks/ that runs
#      `"$PY" ...`) re-resolves that bare name under whatever PATH is active
#      AT THAT POINT, `.`/relative entries included. The fix is two-sided:
#      hooks_path_sans_cwd keeps ONLY absolute PATH entries (`/...` or a
#      Windows drive `C:\...`/`C:/...`) for the lookup -- a relative or `.`
#      or empty entry is dropped, not merely `.` itself -- and every
#      resolver (project.json candidate, the python3/python/py probe, and
#      the interpreter handed to hooks_read_top_level_python) prints and
#      executes the RESOLVED ABSOLUTE PATH from that lookup, never the bare
#      name, so there is nothing left for a later unsanitised PATH to
#      re-resolve. `BRAINSTORM_PYTHON` is the one exception: it is the
#      user's own environment, not repo-controlled, so it may still name a
#      bare command or a full path, used exactly as given.
#
# Usage: `. "$(dirname "$0")/_pyresolve.sh"` then call hooks_resolve_python "$PROJ".

# hooks_is_plausible_python <candidate>
# True if $1 is SAFE TO EVEN TRY running, checked BEFORE it is ever invoked.
# Accepts ONLY a bare command name: no path separator (`/` or `\`) and no
# drive prefix (`X:`) anywhere in the value, whose name is one of the known
# Python names (see header). Anything else -- a relative path (`./evil.sh`),
# an absolute path (`/anything`, `C:\anything`), or a drive-prefixed value
# with no separator (`C:python3`) -- is rejected outright, no probe, no
# exception, regardless of basename. A value this function accepts is never
# treated as a filesystem path by the caller; it is resolved through PATH.
hooks_is_plausible_python() {
  local val="$1"
  [ -n "$val" ] || return 1
  case "$val" in
    */*|*\\*) return 1 ;;      # any path separator -- reject, never a path
    [A-Za-z]:*) return 1 ;;    # a drive prefix, even with no separator yet
  esac
  case "$val" in
    python|python3|py|python.exe|python3.exe|py.exe) return 0 ;;
    python3.[0-9]*|python3.[0-9]*.exe) return 0 ;;
    *) return 1 ;;
  esac
}

# hooks_path_sans_cwd
# Prints $PATH reduced to its ABSOLUTE entries only (POSIX `/...` or a
# Windows drive `C:\...`/`C:/...`). Every other entry is dropped -- not just
# "." or empty, but any RELATIVE entry (`bin`, `./bin`, `..`) too: all of
# them name a location relative to whatever the current working directory
# happens to be at lookup time, and a repo-shipped `bin/python3` wins a bare
# `python3` lookup exactly the same way `./python3` or an empty/"." entry
# does the moment cwd is the repo root. Keeping only absolute entries is
# what makes "resolved through PATH, never relative to cwd" actually hold.
hooks_path_sans_cwd() {
  local part out=""
  local IFS=':'
  for part in ${PATH:-}; do
    case "$part" in
      /*|[A-Za-z]:[\\/]*) : ;;   # absolute (POSIX, or Windows drive-letter)
      *) continue ;;             # relative, ".", ".." or empty -- drop
    esac
    out="${out:+$out:}$part"
  done
  printf '%s' "$out"
}

# hooks_resolve_on_path <bare-name>
# Prints the absolute path `command -v` resolves <bare-name> to, looked up on
# an absolute-entries-only PATH (hooks_path_sans_cwd) -- never the current
# working directory, and never a repo-local file reachable only via a
# relative PATH entry. Prints nothing and returns 1 if <bare-name> isn't
# found on that PATH. Callers must keep and use THIS absolute result, not
# <bare-name> itself -- re-resolving the bare name later, under whatever
# PATH is active at that later point, is exactly what reopens this.
hooks_resolve_on_path() {
  local name="$1" safe
  safe="$(hooks_path_sans_cwd)"
  PATH="$safe" command -v "$name" 2>/dev/null
}

# hooks_probe_python
# Prints the RESOLVED ABSOLUTE PATH of the first of python3/python/py that
# resolves on PATH AND proves it runs (`-c 'pass'`), or nothing + returns 1
# if none do -- never the bare name. Shared by the final fallback tier and
# by hooks_read_top_level_python's "find something to parse JSON with" step
# below -- same probe, one definition.
# These three names are fixed, not project-controlled, but the lookup still
# uses hooks_resolve_on_path's absolute-entries-only PATH and prints/executes
# the resolved ABSOLUTE path, never the bare name -- otherwise a relative,
# `.`, or empty PATH entry (common misconfiguration, not just an
# attacker-supplied project.json) would let a same-named file sitting in
# whatever the current working directory happens to be at call time stand in
# for a real interpreter here too, AND would let a later caller that only
# has the bare name re-resolve straight back into the same trap.
hooks_probe_python() {
  local c resolved
  for c in python3 python py; do
    resolved="$(hooks_resolve_on_path "$c")" || continue
    if "$resolved" -c 'pass' >/dev/null 2>&1; then
      printf '%s' "$resolved"
      return 0
    fi
  done
  return 1
}

# hooks_read_top_level_python <project.json path> <interpreter-or-empty>
# Prints the project.json `python` key's value, ONLY when that key sits at
# the document's root -- a `"python"` key nested inside some other object
# (e.g. `"other": {"python": "..."}`) must never match. Prints nothing if
# there is no root-level `python` string key.
#
# When $2 names a working interpreter, this parses the JSON properly (a
# `json.load` + a plain root-dict `.get("python")` can't confuse nesting
# depth by construction). $2 is independent of this call's EVENTUAL
# resolved interpreter -- it only needs to exist well enough to parse JSON,
# the three-tier BRAINSTORM_PYTHON -> project.json -> probe priority for
# which interpreter hooks_resolve_python actually returns is unaffected.
#
# LIMIT (the no-interpreter-at-all fallback): with $2 empty, this falls back
# to a hand-rolled, single-pass AWK brace/string scanner with no real JSON
# grammar -- it tracks `{`/`}` depth and quote state character-by-character,
# and captures a `"python": "<value>"` pair only while depth==1 (i.e. still
# inside the root object, before any nested `{` was opened). It is correct
# for the ordinary hand-written shape templates/project.json.example ships
# (string values, no escaped quotes inside them, no `python` key living
# inside a top-level ARRAY), but it is not a JSON parser: an escaped `\"`
# inside an unrelated string value earlier in the file, or a literal `{`/`}`
# character inside a string, can throw off the depth count. This path is
# only reached when NO working Python exists anywhere on the host (not even
# to read this one key) -- the common case always has $2 populated.
hooks_read_top_level_python() {
  local projfile="$1" py="$2"
  [ -f "$projfile" ] || return 0
  if [ -n "$py" ]; then
    "$py" -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        d = json.load(f)
    v = d.get("python") if isinstance(d, dict) else None
    if isinstance(v, str) and v:
        print(v)
except Exception:
    pass
' "$projfile" 2>/dev/null
    return 0
  fi
  awk '
    { buf = buf $0 "\n" }
    END {
      n = length(buf); depth = 0; instr = 0; esc = 0
      mode = "none"; key = ""; val = ""; result = ""
      for (i = 1; i <= n; i++) {
        c = substr(buf, i, 1)
        if (instr) {
          if (esc) {
            esc = 0
            if (mode == "key") key = key c
            else if (mode == "value") val = val c
          } else if (c == "\\") {
            esc = 1
          } else if (c == "\"") {
            instr = 0
            if (mode == "key") { mode = "afterkey" }
            else if (mode == "value") {
              if (depth == 1 && key == "python" && result == "") result = val
              mode = "none"; key = ""; val = ""
            }
          } else {
            if (mode == "key") key = key c
            else if (mode == "value") val = val c
          }
          continue
        }
        if (c == "\"") {
          instr = 1
          if (mode == "afterkey") { mode = "value"; val = "" }
          else { mode = "key"; key = "" }
          continue
        }
        if (c == "{") { depth++; mode = "none"; continue }
        if (c == "}") { depth--; mode = "none"; continue }
        if (c == ",") { mode = "none"; continue }
      }
      if (result != "") print result
    }
  ' "$projfile" 2>/dev/null
}

# hooks_resolve_python <project-root>
# Prints the resolved interpreter on stdout and returns 0, or prints nothing
# and returns 1 if none was found. The project.json and probe tiers always
# print a RESOLVED ABSOLUTE PATH (never a bare name -- see hooks_probe_python
# and hooks_resolve_on_path for why); only the $BRAINSTORM_PYTHON tier prints
# its value verbatim, bare or absolute, exactly as the user set it.
# Order matches scripts/py.sh: env override -> project.json `python` key
# (root-level only; accepted as a bare name by hooks_is_plausible_python,
# resolved on PATH by hooks_resolve_on_path, then proven to run) -> probe.
# A rejected or non-running candidate (from either tier) is
# reported on stderr once, never executed, and resolution falls through to
# the next tier rather than failing outright -- a hostile or stale config, or
# a broken BRAINSTORM_PYTHON, must not brick the hook.
hooks_resolve_python() {
  local proj="$1" py="" cand="" probe_py="" resolved=""

  if [ -n "${BRAINSTORM_PYTHON:-}" ]; then
    if "${BRAINSTORM_PYTHON}" -c 'pass' >/dev/null 2>&1; then
      py="$BRAINSTORM_PYTHON"
    else
      echo "hooks: ignoring BRAINSTORM_PYTHON value '$BRAINSTORM_PYTHON' -- failed to run; falling back" >&2
    fi
  fi

  if [ -z "$py" ] && [ -f "$proj/.claude/project.json" ]; then
    probe_py="$(hooks_probe_python)" || probe_py=""
    cand="$(hooks_read_top_level_python "$proj/.claude/project.json" "$probe_py" | head -n 1)"
    if [ -n "$cand" ]; then
      if hooks_is_plausible_python "$cand"; then
        resolved="$(hooks_resolve_on_path "$cand")" || resolved=""
        if [ -n "$resolved" ] && "$resolved" -c 'pass' >/dev/null 2>&1; then
          py="$resolved"
        else
          echo "hooks: ignoring .claude/project.json 'python' value '$cand' -- not found on PATH; falling back" >&2
        fi
      else
        echo "hooks: ignoring .claude/project.json 'python' value '$cand' -- a path is not accepted from project.json; set BRAINSTORM_PYTHON for a specific interpreter path; falling back" >&2
      fi
    fi
  fi

  if [ -z "$py" ]; then
    py="$(hooks_probe_python)" || py=""
  fi

  [ -n "$py" ] || return 1
  printf '%s\n' "$py"
}
