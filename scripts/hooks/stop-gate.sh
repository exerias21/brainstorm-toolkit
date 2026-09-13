#!/usr/bin/env bash
# brainstorm-toolkit — opt-in Stop hook: keep an in-progress /sdlc run from
# handing off a validated tree when the unit suite is actually red.
#
# INERT unless .claude/project.json has BOTH `pipeline.stop_gate: "tests"` AND
# a `.claude/pipeline/*/run.json` with `status: "in_progress"` AND `test.unit`
# configured. With any of those absent this script produces NO output and
# exits 0 -- see "Config-gate first" below for why that ordering matters.
#
# Contract when the gate IS live:
#   - green test.unit  -> silent, exit 0, hop counter reset.
#   - red test.unit    -> {"decision":"block","reason":"stop-gate: tests red — <tail>"}
#     (last 15 lines, 1200 chars max; if the command produced no output, a
#     "(command produced no output; exit code N)" fallback stands in for
#     <tail> so the reason is never an empty em-dash) and the hop counter
#     increments.
#   - test.unit binary not found (exit 127) -> never blocks; a systemMessage
#     names the missing command, exit 0.
#   - hop counter >= pipeline.loop.max_hops (default 5) -> stands down with a
#     systemMessage instead of running the suite again; this bounds the loop
#     exactly like the L9 auto-continue hop budget in next-action.sh.
#
# Mandatory stand-downs (single-blocker contract): Stop hooks run in PARALLEL
# and hooks.json array order does NOT establish precedence, so two hooks both
# emitting decision:block in one event is undocumented behaviour. This hook
# guarantees BY CONSTRUCTION that it is never the second blocker:
#   (a) stdin `stop_hook_active: true` -> exit 0 immediately, no output. This
#       is the documented escape hatch against an infinite block loop (Claude
#       Code also caps consecutive blocks at CLAUDE_CODE_STOP_HOOK_BLOCK_CAP).
#   (b) a pending `.claude/.next-action` sentinel -> exit 0 with a
#       systemMessage saying this gate stood down; next-action.sh owns the
#       block in that event. PEEK only -- this hook never deletes the
#       sentinel; next-action.sh is the sole consumer (docs/SEAM.md).
#   (c) `pipeline.loop.auto_continue: true` -> exit 0 with a systemMessage.
#       next-action.sh can only ever emit decision:block from inside its
#       auto-continue path, itself gated on this same knob -- so standing
#       down here whenever the knob is true makes the two hooks mutually
#       exclusive BY CONFIG, deterministically, closing the TOCTOU window a
#       sentinel peek alone cannot (two parallel processes racing the same
#       sentinel file). (b) is kept as a secondary check for when
#       auto_continue is off.
#
# Config-gate first: the two stand-downs above only run AFTER this script has
# confirmed the gate is configured, an in_progress envelope exists, and
# test.unit is set. That reordering (vs. the naive "stand-downs before
# anything") is deliberate: it is the only way to also guarantee that a repo
# which never opted in (`pipeline.stop_gate` absent) sees literally zero
# bytes of output for ANY stdin, including a pending sentinel or
# stop_hook_active. Once the gate IS live, the stand-downs still run before
# any test is executed or any hop is spent, so the single-blocker guarantee
# holds in every case that could actually reach `decision:block`.
#
# Cross-tool: wired on Claude Code (.claude/settings.json) and Codex
# (.codex/hooks.json, same decision:block contract) by setup.sh. Copilot gets
# no wiring -- its block-equivalent is unverified, same reasoning as the L9
# auto-continue guard in next-action.sh.
set -u

input="$(cat 2>/dev/null || true)"

# Resolve relative to the project root, same three-step fallback as the
# other hooks: CLAUDE_PROJECT_DIR -> git top-level -> PWD.
PROJ="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$PROJ" ]; then
  if _gr="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$_gr" ]; then PROJ="$_gr"; else PROJ="$PWD"; fi
fi

# jq-or-python fallback, same probe style as run-cost-report.sh: prove the
# interpreter RUNS, not merely that it resolves on PATH (a Windows Store
# python3 stub resolves and then exits non-zero).
JQ=""; PY=""
if command -v jq >/dev/null 2>&1 && echo '{}' | jq -e . >/dev/null 2>&1; then JQ="jq"; fi
for c in python3 python py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'pass' >/dev/null 2>&1; then PY="$c"; break; fi
done

jget() {
  _f="$1"; _p="$2"; _d="${3:-}"
  if [ -n "$JQ" ]; then
    if [ "$_f" = "-" ]; then jq -r "$_p // \"$_d\"" 2>/dev/null || printf '%s' "$_d"
    else jq -r "$_p // \"$_d\"" "$_f" 2>/dev/null || printf '%s' "$_d"; fi
  elif [ -n "$PY" ]; then
    "$PY" -c 'import json,sys
path=sys.argv[2].lstrip(".").split(".")
d=sys.argv[3] if len(sys.argv)>3 else ""
try:
    o=json.load(open(sys.argv[1],encoding="utf-8")) if sys.argv[1]!="-" else json.load(sys.stdin)
    for k in path: o=o[k]
    if isinstance(o, bool): o = "true" if o else "false"  # match jq -r boolean casing
    print(o if o is not None else d)
except Exception: print(d)' "$_f" "$_p" "$_d" 2>/dev/null || printf '%s' "$_d"
  else
    printf '%s' "$_d"
  fi
}

emit_message() {
  [ -n "$JQ" ] || [ -n "$PY" ] || return 0
  if [ -n "$JQ" ]; then
    jq -n --arg m "$1" '{systemMessage:$m}'
  else
    "$PY" -c 'import json,sys; print(json.dumps({"systemMessage": sys.argv[1]}))' "$1"
  fi
}

emit_block() {
  [ -n "$JQ" ] || [ -n "$PY" ] || return 0
  if [ -n "$JQ" ]; then
    jq -n --arg r "$1" '{decision:"block",reason:$r}'
  else
    "$PY" -c 'import json,sys; print(json.dumps({"decision":"block","reason":sys.argv[1]}))' "$1"
  fi
}

# --- Config gate: exit 0, NO output, unless every condition holds. ---
PROJECT_JSON="$PROJ/.claude/project.json"
[ -f "$PROJECT_JSON" ] || exit 0

stop_gate_mode="$(jget "$PROJECT_JSON" '.pipeline.stop_gate' '')"
[ "$stop_gate_mode" = "tests" ] || exit 0

test_cmd="$(jget "$PROJECT_JSON" '.test.unit' '')"
[ -n "$test_cmd" ] || exit 0

envelope=""
for f in "$PROJ"/.claude/pipeline/*/run.json; do
  [ -f "$f" ] || continue
  st="$(jget "$f" '.status' '')"
  if [ "$st" = "in_progress" ]; then envelope="$f"; break; fi
done
[ -n "$envelope" ] || exit 0

# --- Gate is live from here. Mandatory stand-downs before any other work. ---

# (a) documented escape hatch against an infinite block loop.
stop_hook_active="$(printf '%s' "$input" | jget - '.stop_hook_active' 'false')"
[ "$stop_hook_active" = "true" ] && exit 0

# (b) a pending seam sentinel takes precedence -- PEEK, never consume.
NEXT_ACTION_FILE="$PROJ/.claude/.next-action"
if [ -s "$NEXT_ACTION_FILE" ]; then
  emit_message "stop-gate: standing down — a pending .next-action sentinel takes precedence (next-action.sh will surface it)."
  exit 0
fi

# (c) config-level mutual exclusion: next-action.sh can only ever emit
# decision:block when pipeline.loop.auto_continue is true, so standing down
# here whenever that same knob is true makes the two hooks mutually exclusive
# by construction -- no sentinel-timing race between two parallel Stop hooks.
auto_continue="$(jget "$PROJECT_JSON" '.pipeline.loop.auto_continue' 'false')"
if [ "$auto_continue" = "true" ]; then
  emit_message "stop-gate: standing down — pipeline.loop.auto_continue is true, so next-action.sh may block this event; the two hooks are mutually exclusive by config."
  exit 0
fi

HOPS_FILE="$PROJ/.claude/.stop-gate-hops"
max_hops="$(jget "$PROJECT_JSON" '.pipeline.loop.max_hops' '5')"
case "$max_hops" in ''|*[!0-9]*) max_hops=5;; esac
hops=0
if [ -s "$HOPS_FILE" ]; then hops="$(cat "$HOPS_FILE" 2>/dev/null)"; fi
case "$hops" in ''|*[!0-9]*) hops=0;; esac
if [ "$hops" -ge "$max_hops" ]; then
  emit_message "stop-gate: standing down — hop budget ($max_hops) reached without a green test.unit run; investigate manually."
  exit 0
fi

timeout_s="$(jget "$PROJECT_JSON" '.pipeline.stop_gate_timeout' '300')"
case "$timeout_s" in ''|*[!0-9]*) timeout_s=300;; esac

output="$(cd "$PROJ" 2>/dev/null && timeout "$timeout_s" bash -c "$test_cmd" 2>&1)"
rc=$?

# Never block on a missing command (exit 127 is the shell's own signal for
# "command not found", portable across single- and compound-command test.unit
# values, e.g. `cd web && pnpm test`).
if [ "$rc" -eq 127 ]; then
  emit_message "stop-gate: standing down — test.unit command not found ($test_cmd)."
  exit 0
fi

if [ "$rc" -eq 0 ]; then
  rm -f "$HOPS_FILE" 2>/dev/null || true
  exit 0
fi

new_hops=$((hops + 1))
printf '%s' "$new_hops" > "$HOPS_FILE" 2>/dev/null || true
tail_out="$(printf '%s\n' "$output" | tail -n 15)"
tail_out="${tail_out:0:1200}"
if [ -z "$tail_out" ]; then
  tail_out="(command produced no output; exit code ${rc})"
fi
emit_block "stop-gate: tests red — ${tail_out}"
exit 0
