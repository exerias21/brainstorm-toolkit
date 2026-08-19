#!/usr/bin/env bash
# brainstorm-toolkit — end-of-run cost report.
#
# Prints what a pipeline run actually cost, ONCE, when the run reaches a terminal state.
# Replaces the earlier mid-run context-threshold nag, which was wrong three ways: it was a
# lagging indicator (the tokens were already spent), it fired mid-plan where clearing is
# explicitly unsafe (docs/LOOP-HYGIENE.md), and it was tuned on a multi-day multi-command
# session rather than the real unit of work — one plan, executed in one fresh session.
#
# COSTS ZERO MODEL TOKENS. The report goes out as `systemMessage`, which the hook contract
# displays to the human and never injects into the model's context. It must NEVER use
# `hookSpecificOutput.additionalContext` — that is the paid channel, and a cost report that
# costs tokens is self-defeating.
#
# The number is a LEADING indicator for the next plan you write, which is the only place it
# can change a decision. It is not a suggestion to split anything: a big run is fine when the
# context is real work. Compare peak against how much of it was genuinely working state.
#
# Best-effort and FAIL-SOFT: silent (exit 0) with no terminal run, no transcript, or no
# JSON parser.
set -u

[ -t 0 ] && exit 0

# Probe that the interpreter RUNS, not merely that it is on PATH: on Windows `python3` is
# commonly a Microsoft Store stub that resolves and then exits non-zero.
JQ=""; PY=""
if command -v jq >/dev/null 2>&1 && echo '{}' | jq -e . >/dev/null 2>&1; then JQ="jq"; fi
for c in python3 python py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'pass' >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -n "$JQ" ] || [ -n "$PY" ] || exit 0

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
    for k in path: o=o[k]
    print(o if o is not None else d)
except Exception: print(d)' "$_f" "$_p" "$_d" 2>/dev/null || printf '%s' "$_d"
  fi
}

PROJ="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$PROJ" ]; then
  if _gr="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$_gr" ]; then PROJ="$_gr"; else PROJ="$PWD"; fi
fi

input="$(cat 2>/dev/null || true)"
[ -n "$input" ] || exit 0
# stdin, never a temp file: under Git Bash a native Windows Python cannot open an MSYS path.
transcript="$(printf '%s' "$input" | jget - '.transcript_path')"
[ -n "$transcript" ] && [ -f "$transcript" ] || exit 0

cd "$PROJ" 2>/dev/null || exit 0

# Opt out entirely.
if [ -f .claude/project.json ]; then
  enabled="$(jget .claude/project.json '.pipeline.context.cost_report' 'on')"
  [ "$enabled" = "off" ] && exit 0
fi

# Report only for a run that JUST reached a terminal state, and only once per run.
envelope=""; slug=""
for f in .claude/pipeline/*/run.json; do
  [ -f "$f" ] || continue
  st="$(jget "$f" '.status')"
  case "$st" in
    complete|completed|failed|paused)
      d="$(dirname "$f")"
      [ -f "$d/.cost-reported" ] && continue
      envelope="$f"; slug="$(basename "$d")"
      ;;
  esac
done
[ -n "$envelope" ] || exit 0

# Whole-transcript stats. Context on the wire per call = input + cache_read + cache_creation.
if [ -n "$PY" ]; then
  stats="$("$PY" -c 'import json,sys
turns=0; peak=0; tot=0; out=0; cr=0; cw=0; inp=0
for line in open(sys.argv[1],encoding="utf-8",errors="replace"):
    line=line.strip()
    if not line: continue
    try: d=json.loads(line)
    except Exception: continue
    u=((d.get("message") or {}).get("usage") or {})
    if not u: continue
    i=u.get("input_tokens") or 0; r=u.get("cache_read_input_tokens") or 0
    w=u.get("cache_creation_input_tokens") or 0
    ctx=i+r+w
    turns+=1; tot+=ctx; peak=max(peak,ctx)
    out+=u.get("output_tokens") or 0; cr+=r; cw+=w; inp+=i
avg=tot//turns if turns else 0
# Rough relative spend, opus rates: in 15 / cache-write 18.75 / cache-read 1.50 / out 75 per Mtok.
usd=(inp*15.0 + cw*18.75 + cr*1.50 + out*75.0)/1e6
print(f"{turns} {avg} {peak} {cr} {usd:.2f}")' "$transcript" 2>/dev/null)"
else
  stats="$(jq -rs '
    [ .[] | select(.message?.usage?) | .message.usage ] as $u
    | ($u | length) as $n
    | [ $u[] | (.input_tokens//0)+(.cache_read_input_tokens//0)+(.cache_creation_input_tokens//0) ] as $c
    | [ ($n|tostring), (if $n>0 then (($c|add)/$n|floor|tostring) else "0" end),
        (($c|max)//0|tostring), ([$u[]|.cache_read_input_tokens//0]|add|tostring),
        ((([$u[]|.input_tokens//0]|add)*15.0
          + ([$u[]|.cache_creation_input_tokens//0]|add)*18.75
          + ([$u[]|.cache_read_input_tokens//0]|add)*1.50
          + ([$u[]|.output_tokens//0]|add)*75.0)/1000000 | tostring) ]
    | join(" ")' "$transcript" 2>/dev/null)"
fi
[ -n "$stats" ] || exit 0
set -- $stats
turns="${1:-0}"; avg="${2:-0}"; peak="${3:-0}"; cread="${4:-0}"; usd="${5:-0}"
[ "$turns" -gt 0 ] 2>/dev/null || exit 0

status="$(jget "$envelope" '.status' '?')"
: > "$(dirname "$envelope")/.cost-reported" 2>/dev/null || true

msg="[run cost] ${slug} (${status}) - ${turns} turns, avg context $((avg/1000))k, peak $((peak/1000))k, cache-read $((cread/1000000))M, ~\$${usd}.
Cost scales turns x context, so peak is the number that compounds. A big run is fine when the
context is real work; check how much of it was shell output and file bodies that a sub-agent
should have held instead. Size the NEXT plan against this. (project.json pipeline.context.cost_report: \"off\" to silence.)"

# systemMessage ONLY -- shown to the human, never added to the model's context, so this
# report is free. Never switch this to additionalContext.
if [ -n "$JQ" ]; then
  jq -n --arg m "$msg" '{systemMessage:$m}'
else
  printf '%s' "$msg" | "$PY" -c 'import json,sys,io; t=io.TextIOWrapper(sys.stdin.buffer,encoding="utf-8",errors="replace").read(); print(json.dumps({"systemMessage":t}))'
fi
exit 0
