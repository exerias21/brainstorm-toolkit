#!/usr/bin/env bash
# brainstorm-toolkit — context-watch hook (context-drag detector).
#
# Cross-tool: wired as a Claude Code / Codex `Stop` hook alongside next-action.sh.
# Reads the hook's OWN transcript to measure live context size, and emits a one-line
# handoff nudge once it exceeds pipeline.context.warn_above_tokens (default 250000).
#
# ADVISORY ONLY. No tool permits a skill or hook to force /clear or /compact (see
# docs/LOOP-HYGIENE.md and plans/brainstorm-loop-context-hygiene.md — that lever was
# investigated and rejected). This measures and reports; the human acts.
#
# Why this works despite "no tool exposes live token usage to a script": no tool exposes
# an API for it, but the hook payload carries `transcript_path`, and the LAST usage row in
# that JSONL is the context that was actually on the wire:
#     input_tokens + cache_read_input_tokens + cache_creation_input_tokens
#
# Best-effort and FAIL-SOFT: emits nothing (exit 0) when there is no active pipeline run,
# no transcript, or no JSON parser — so it costs zero tokens everywhere it is irrelevant.
set -u

# A bare interactive TTY (manual debug invocation with no piped input) would block on `cat`.
[ -t 0 ] && exit 0

# Parser: jq (matching the sibling hooks) OR python3. Unlike next-action.sh/reseed-context.sh,
# this hook needs a parser for its ENTIRE job -- a jq-only implementation would silently never
# fire on the Windows boxes this feature exists to help. Python is shipped alongside the repo's
# other helpers and is far likelier to be present there, so accept either.
# NOTE: probe that the interpreter actually RUNS, not merely that it is on PATH. On Windows,
# `python3` is commonly a Microsoft Store stub that resolves via `command -v` and then exits
# non-zero -- taking `command -v` as proof would silently disable this hook on exactly the
# platform it was added for.
JQ=""; PY=""
if command -v jq >/dev/null 2>&1 && echo '{}' | jq -e . >/dev/null 2>&1; then JQ="jq"; fi
for c in python3 python py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'pass' >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -n "$JQ" ] || [ -n "$PY" ] || exit 0

# jget <json-file-or-"-"> <dot.path> [default] -- read one scalar, fail-soft to the default.
jget() {
  _f="$1"; _p="$2"; _d="${3:-}"
  if [ -n "$JQ" ]; then
    if [ "$_f" = "-" ]; then jq -r "$_p // \"$_d\"" 2>/dev/null || printf '%s' "$_d"
    else jq -r "$_p // \"$_d\"" "$_f" 2>/dev/null || printf '%s' "$_d"; fi
  else
    "$PY" -c 'import json,sys
path=sys.argv[2].lstrip(".").split(".")
d=sys.argv[3] if len(sys.argv)>3 else ""
try:
    o=json.load(open(sys.argv[1],encoding="utf-8")) if sys.argv[1]!="-" else json.load(sys.stdin)
    for k in path:
        o=o[k]
    print(o if o is not None else d)
except Exception:
    print(d)' "$_f" "$_p" "$_d" 2>/dev/null || printf '%s' "$_d"
  fi
}

# Project root: CLAUDE_PROJECT_DIR (Claude) > git top-level (Codex may start elsewhere) > cwd.
PROJ="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$PROJ" ]; then
  if _gr="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$_gr" ]; then PROJ="$_gr"; else PROJ="$PWD"; fi
fi

input="$(cat 2>/dev/null || true)"
[ -n "$input" ] || exit 0

# Read the payload from STDIN, never a temp file: under Git Bash a native Windows Python
# cannot open an MSYS path like /tmp/foo, so a temp-file handoff fails silently there.
# Paths read later are either relative (after `cd "$PROJ"`) or come from the payload already
# in the host's native form, so both interpreters handle them.
transcript="$(printf '%s' "$input" | jget - '.transcript_path')"
[ -n "$transcript" ] && [ -f "$transcript" ] || exit 0

cd "$PROJ" 2>/dev/null || exit 0

# Only nudge inside an active pipeline run. Outside one there is no stage boundary to hand
# off at, and the advice would be noise.
envelope=""
for f in .claude/pipeline/*/run.json; do
  [ -f "$f" ] || continue
  st="$(jget "$f" '.status')"
  case "$st" in in_progress|paused) envelope="$f" ;; esac
done
[ -n "$envelope" ] || exit 0

# Threshold: pipeline.context.warn_above_tokens, default 250000. 0 disables.
threshold=250000
if [ -f .claude/project.json ]; then
  cfg="$(jget .claude/project.json '.pipeline.context.warn_above_tokens')"
  case "$cfg" in ''|*[!0-9]*) : ;; *) threshold="$cfg" ;; esac
fi
[ "$threshold" -eq 0 ] 2>/dev/null && exit 0

# Last usage row in the transcript = context actually on the wire for the most recent call.
if [ -n "$JQ" ]; then
  ctx="$(jq -rs '
    [ .[] | select(.message?.usage?)
           | .message.usage
           | (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0) ]
    | last // 0' "$transcript" 2>/dev/null || echo 0)"
else
  ctx="$("$PY" -c 'import json,sys
last=0
for line in open(sys.argv[1],encoding="utf-8",errors="replace"):
    line=line.strip()
    if not line: continue
    try: d=json.loads(line)
    except Exception: continue
    u=((d.get("message") or {}).get("usage") or {})
    if u:
        last=(u.get("input_tokens") or 0)+(u.get("cache_read_input_tokens") or 0)+(u.get("cache_creation_input_tokens") or 0)
print(last)' "$transcript" 2>/dev/null || echo 0)"
fi
case "$ctx" in ''|*[!0-9]*) exit 0 ;; esac
[ "$ctx" -gt "$threshold" ] 2>/dev/null || exit 0

slug="$(basename "$(dirname "$envelope")")"
stage="$(jget "$envelope" '.stage' '?')"
[ -n "$stage" ] || stage='?'

relay="off"
if [ -f .claude/project.json ]; then
  r="$(jget .claude/project.json '.pipeline.context.relay' off)"
  [ -n "$r" ] && relay="$r"
fi

ctx_k=$(( ctx / 1000 ))
thr_k=$(( threshold / 1000 ))

msg="[brainstorm-toolkit context-watch] Context is ${ctx_k}k tokens (threshold ${thr_k}k).
Every further turn in this session re-reads all ${ctx_k}k - cost scales with turns x context.
Durable state is on disk: ${envelope} (stage ${stage}), so a fresh session loses nothing.
At the next stage boundary consider /clear - the SessionStart reseed hook re-points the new
session at the envelope automatically. This is advisory; nothing was reset."

if [ "$relay" = "suggest" ]; then
  msg="${msg}
Fresh-process re-entry (never --resume; it reloads the full transcript and defeats the point):
  claude -p \"/sdlc-lite --resume ${slug}\""
fi

# Emit as non-blocking hook output on both runtimes. Never `decision: block` — this hook
# must never stop or steer the run, only inform.
if [ -n "$JQ" ]; then
  jq -n --arg m "$msg" '{hookSpecificOutput:{hookEventName:"Stop", additionalContext:$m}}'
else
  printf '%s' "$msg" | "$PY" -c 'import json,sys,io; t=io.TextIOWrapper(sys.stdin.buffer,encoding="utf-8",errors="replace").read(); print(json.dumps({"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":t}}))'
fi
exit 0
