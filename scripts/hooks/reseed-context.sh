#!/usr/bin/env bash
# brainstorm-toolkit — reseed-context hook (loop context hygiene).
#
# Cross-tool: wired as a Claude Code SessionStart hook (matcher "compact|clear")
# and a Codex PostCompact hook. When a long-running loop's orchestrator session is
# compacted or cleared mid-work, this re-injects a POINTER to the loop's durable
# on-disk state (the active pipeline envelope + the .next-action sentinel + TASKS.md
# counts) as `additionalContext`. It never dumps state — the files are the memory;
# this just points back at them.
#
# Best-effort and FAIL-SOFT: emits nothing (exit 0) in any repo that isn't running a
# loop, so it costs zero tokens where it's irrelevant. See docs/LOOP-HYGIENE.md.
set -u

# A bare interactive TTY (manual debug invocation with no piped input) would block on
# `cat` below; the shipped hooks always pipe JSON, so guard the debug case explicitly.
[ -t 0 ] && exit 0

# Project root: CLAUDE_PROJECT_DIR (Claude) > git top-level (Codex may start elsewhere) > cwd.
PROJ="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$PROJ" ]; then
  if _gr="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$_gr" ]; then PROJ="$_gr"; else PROJ="$PWD"; fi
fi

# Read hook stdin. Tolerate the trigger field-name difference across tools/events:
# Claude SessionStart -> `.source` (startup|resume|clear|compact); Codex PostCompact
# -> `.trigger` (manual|auto). Also read `.hook_event_name` so the output names the
# actual invoking event rather than assuming SessionStart.
input="$(cat 2>/dev/null || true)"
trigger=""; event=""

# Probe that the interpreter RUNS, not merely that it resolves: on Windows
# `python3` is commonly a Microsoft Store stub that is on PATH and exits
# non-zero. Same probe style as run-cost-report.sh / stop-gate.sh.
#
# WHY THE FALLBACK: this hook used to require jq for every field read and bare
# `python3` for its output, so on a machine with neither it exited silently and
# the reseed never happened -- the one mechanism that carries state across a
# compaction, absent exactly when you cannot tell. Both sibling hooks already
# degrade to python; this one did not.
#
# Three-tier resolution matching scripts/py.sh / next-action.sh's inline copy
# of it: $BRAINSTORM_PYTHON > .claude/project.json's top-level `python` key >
# probe python3/python/py, each candidate proven to RUN. The final reseed
# message below is emitted ONLY through $PY (there is no jq path for it), so a
# probe that only tried python3/python/py silently dropped the reseed on any
# machine whose working interpreter was reachable only via one of those two
# settings -- exactly the machine this fallback exists for.
JQ=""; PY=""
if command -v jq >/dev/null 2>&1 && echo '{}' | jq -e . >/dev/null 2>&1; then JQ="jq"; fi
if [ -n "${BRAINSTORM_PYTHON:-}" ] && "${BRAINSTORM_PYTHON}" -c 'pass' >/dev/null 2>&1; then
  PY="$BRAINSTORM_PYTHON"
fi
if [ -z "$PY" ] && [ -f "$PROJ/.claude/project.json" ]; then
  PY="$(sed -n 's/.*"python"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$PROJ/.claude/project.json" 2>/dev/null | head -n 1)"
  if [ -n "$PY" ] && ! "$PY" -c 'pass' >/dev/null 2>&1; then PY=""; fi
fi
if [ -z "$PY" ]; then
  for c in python3 python py; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c 'pass' >/dev/null 2>&1; then PY="$c"; break; fi
  done
fi
[ -n "$JQ" ] || [ -n "$PY" ] || exit 0

# jget <file|-> <dotted.path[,alt.path]> [default]
# Accepts a comma-separated list of paths and returns the first non-empty one,
# so a reader can tolerate a field that drifted between envelope writers.
jget() {
  _f="$1"; _p="$2"; _d="${3:-}"; _in=""
  [ "$_f" = "-" ] && _in="$input"
  if [ -n "$PY" ]; then
    printf '%s' "$_in" | "$PY" -c 'import json,sys
f,paths,dflt = sys.argv[1], sys.argv[2].split(","), (sys.argv[3] if len(sys.argv)>3 else "")
try:
    o = json.load(open(f,encoding="utf-8")) if f != "-" else json.load(sys.stdin)
except Exception:
    print(dflt); raise SystemExit
for p in paths:
    cur = o
    try:
        for k in p.lstrip(".").split("."):
            cur = cur[k]
    except Exception:
        continue
    if cur not in (None, ""):
        print(cur); raise SystemExit
print(dflt)' "$_f" "$_p" "$_d" 2>/dev/null || printf '%s' "$_d"
  else
    _q="$(printf '%s' "$_p" | sed 's/,/ \/\/ /g')"
    if [ "$_f" = "-" ]; then printf '%s' "$_in" | jq -r "$_q // \"$_d\"" 2>/dev/null || printf '%s' "$_d"
    else jq -r "$_q // \"$_d\"" "$_f" 2>/dev/null || printf '%s' "$_d"; fi
  fi
}

if [ -n "$input" ]; then
  trigger="$(jget - '.source,.trigger,.reason')"
  event="$(jget - '.hook_event_name')"
fi
# Reseed only on a context RESET. A plain session start/resume needs none (the loop
# reads state on its next action anyway). PostCompact's manual/auto trigger, or an
# absent trigger, falls through and reseeds — which is correct (it only fires post-compact).
case "$trigger" in startup|resume) exit 0 ;; esac

cd "$PROJ" 2>/dev/null || exit 0

# Most-recent NON-TERMINAL pipeline envelope, if any (skip completed runs; fall back
# past a newer completed run to an older still-active one).
#
# `feature_slug` is the canonical key (see skills/sdlc/templates/state-schema.md,
# "Canonical keys only"), but envelopes written in the wild are mixed -- a run
# audited 2026-09-11 had written bare `slug` -- and a reseed that reports an empty
# slug is worse than one that tolerates the drift. Read canonical first, then fall
# back. Do NOT let this tolerance leak into writers: they emit `feature_slug`.
env_file=""; slug=""; stage=""; status=""
while IFS= read -r cand; do
  [ -n "$cand" ] || continue
  st="$(jget "$cand" '.status')"
  case "$st" in
    in_progress|paused|failed)
      env_file="$cand"; status="$st"
      slug="$(jget "$cand" '.feature_slug,.slug')"
      stage="$(jget "$cand" '.stage')"
      break ;;
  esac
done < <(ls -t .claude/pipeline/*/run.json 2>/dev/null)

# Sentinel (by path — read bounded in python, never via argv) + queue counts (fail-soft).
sentinel_file=""; [ -s .claude/.next-action ] && sentinel_file=".claude/.next-action"
open_n="$(grep -c '^- \[ \]' TASKS.md 2>/dev/null || true)"; open_n="${open_n:-0}"
done_n="$(grep -c '^- \[x\]' TASKS.md 2>/dev/null || true)"; done_n="${done_n:-0}"

# Decisions: the one thing the envelope does NOT carry -- WHY a settled call was
# made. Point at the file and name only the most recent one. Never dump it: a
# compaction is exactly when a large injection is most expensive, and the file
# is the memory (same rule as the envelope above).
dec_file=""; dec_n=0; dec_last=""
if [ -s DECISIONS.md ]; then
  dec_file="DECISIONS.md"
  dec_n="$(grep -c '^## [0-9][0-9][0-9][0-9]-' DECISIONS.md 2>/dev/null || true)"; dec_n="${dec_n:-0}"
  dec_last="$(grep '^## [0-9][0-9][0-9][0-9]-' DECISIONS.md 2>/dev/null | tail -n 1 | cut -c4- | cut -c1-120 || true)"
fi

# No-op guard: nothing loop-shaped on disk -> stay silent (zero token cost).
if [ -z "$env_file" ] && [ -z "$sentinel_file" ] && [ -z "$dec_file" ]; then exit 0; fi

# $PY was probed above (python3 > python > py, each proven to RUN). A bare
# `command -v python3` here used to exit the hook silently on Windows, where
# python3 is usually a Store stub.
[ -n "$PY" ] || exit 0
"$PY" - "$env_file" "$slug" "$stage" "$status" "$sentinel_file" "$open_n" "$done_n" "$event" \
      "$dec_file" "$dec_n" "$dec_last" <<'PY'
import json, sys
env_file, slug, stage, status, sentinel_file, open_n, done_n, event = sys.argv[1:9]
dec_file, dec_n, dec_last = (sys.argv[9:12] + ["", "0", ""])[:3]
lines = ["[brainstorm-toolkit reseed] Context was compacted/cleared mid-loop. Durable state lives on disk:"]
if env_file:
    lines.append(f"- active run: {env_file} (slug {slug}, stage {stage}, status {status})")
if sentinel_file:
    try:
        with open(sentinel_file) as f:
            s = f.read(8000).strip()   # bounded read — never pass file contents via argv
    except Exception:
        s = ""
    if s:
        lines.append("- next action (.claude/.next-action):\n" + s)
lines.append(f"- queue: TASKS.md ({open_n} open / {done_n} done)")
if dec_file:
    tail = f'; most recent: "{dec_last}"' if dec_last else ""
    lines.append(f"- decisions: {dec_file} ({dec_n} recorded{tail})")
lines.append("Resume from the envelope/sentinel on disk, not from memory. Do not re-run stages already "
             "marked passed. If unsure where you are, run /sdlc-status.")
if dec_file:
    lines.append("Before reversing anything that looks odd, read DECISIONS.md -- it records what was "
                 "REJECTED and why, which is the part that does not survive a compaction.")
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": event or "SessionStart", "reloadSkills": True, "additionalContext": "\n".join(lines)}}))
PY
exit 0
