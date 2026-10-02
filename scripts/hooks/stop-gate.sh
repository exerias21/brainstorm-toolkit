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
#   - green test.unit  -> silent, exit 0, hop counter reset -- EXCEPT the very
#     first Stop of a given run, which still emits a one-line systemMessage
#     naming the command (see "Trust model" below); every later green Stop on
#     the same run is silent again.
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
# Trust model (closes "a cloned repo runs arbitrary commands on Stop"): this
# gate's config (`test.unit`, the `pipeline.stop_gate` opt-in itself) lives in
# .claude/project.json, which runs OUTSIDE Claude Code's Bash permission
# system -- a Stop hook executes it with no approval prompt. `setup.sh`
# gitignores that file for exactly this reason (`ensure_gitignored
# ".claude/project.json"`), so in the common case it is the person running
# Claude Code's own local config, never committed. But .gitignore does not
# stop a repo from committing the file anyway (a forced add, or a team that
# deliberately shares it -- repo-onboarding's "tracked = shared with the
# team" option). So: an UNTRACKED project.json is trusted; a file `git
# ls-files` reports as TRACKED is repo-supplied content and this hook refuses
# to run test.unit from it (stands down with a systemMessage instead),
# unless the person sets `BRAINSTORM_TRUST_STOP_GATE=1` themselves. On top of
# that, the FIRST Stop of any run that does proceed announces the exact
# command in its systemMessage/reason (folded into whatever this invocation
# already emits -- never a second output line) before ever executing it, so
# the command run on your behalf is never silently inferred from config you
# didn't read. A marker file next to the run envelope
# (`.claude/pipeline/<slug>/.stop-gate-announced`) makes this once-per-run,
# not once-per-Stop.
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
#   (c) `pipeline.loop.auto_continue: true` (or its legacy flat alias
#       `pipeline.auto_continue: true`) -> exit 0 with a systemMessage.
#       next-action.sh can only ever emit decision:block from inside its
#       auto-continue path, itself gated on this same knob -- so standing
#       down here whenever the knob is true makes the two hooks mutually
#       exclusive BY CONFIG, deterministically, closing the TOCTOU window a
#       sentinel peek alone cannot (two parallel processes racing the same
#       sentinel file). (b) is kept as a secondary check for when
#       auto_continue is off.
#   (d) `.claude/project.json` is TRACKED by git (see "Trust model" above) ->
#       exit 0 with a systemMessage, never runs test.unit.
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
# Canonical key is the nested `pipeline.loop.auto_continue` (project.json.example,
# docs/SEAM.md); the legacy flat `pipeline.auto_continue` is accepted as an alias
# so the mutual exclusion holds for either spelling -- next-action.sh resolves
# the same two keys (never "anywhere in the file") the same way.
auto_continue="$(jget "$PROJECT_JSON" '.pipeline.loop.auto_continue' '')"
if [ "$auto_continue" != "true" ]; then
  auto_continue="$(jget "$PROJECT_JSON" '.pipeline.auto_continue' 'false')"
fi
if [ "$auto_continue" = "true" ]; then
  emit_message "stop-gate: standing down — pipeline.loop.auto_continue (or its legacy alias pipeline.auto_continue) is true, so next-action.sh may block this event; the two hooks are mutually exclusive by config."
  exit 0
fi

# (d) TRUST CHECK -- the actual fix for "a cloned repo runs arbitrary commands
# on Stop with no Bash permission prompt". This gate's config (test.unit, the
# opt-in itself) lives in .claude/project.json; setup.sh gitignores that file
# for exactly this reason (`ensure_gitignored ".claude/project.json"`) so it is
# normally the PERSON RUNNING Claude Code's own local, untracked config -- not
# something that arrived with the clone. But .gitignore does not stop a repo
# from committing the file anyway (a forced add, or a team that intentionally
# shares it, per repo-onboarding's "tracked = shared with the team" option).
# Trust model: an UNTRACKED project.json is yours; a TRACKED one is
# repo-supplied content and is not trusted to auto-run a shell command on
# Stop, unless explicitly overridden. See docs/ENFORCEMENT.md.
if [ "${BRAINSTORM_TRUST_STOP_GATE:-}" != "1" ] \
   && command -v git >/dev/null 2>&1 \
   && git -C "$PROJ" ls-files --error-unmatch -- .claude/project.json >/dev/null 2>&1; then
  emit_message "stop-gate: standing down — .claude/project.json is TRACKED by git in this repo, not your own local/gitignored config, so its pipeline.stop_gate opt-in is not trusted to run test.unit (\`$test_cmd\`) automatically on Stop. Untrack/gitignore the file, or set BRAINSTORM_TRUST_STOP_GATE=1 if your team deliberately commits a shared project.json. See docs/ENFORCEMENT.md."
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
  # Reset the counter so the budget is per continuation chain, not permanent --
  # without this, one exhausted run disables the gate forever (mirrors
  # next-action.sh's own hop-budget reset on every print/park path).
  rm -f "$HOPS_FILE" 2>/dev/null || true
  exit 0
fi

timeout_s="$(jget "$PROJECT_JSON" '.pipeline.stop_gate_timeout' '300')"
case "$timeout_s" in ''|*[!0-9]*) timeout_s=300;; esac

# First-time-per-run transparency: name the exact command before ever running
# it, once per in_progress envelope (not every Stop -- the marker lives next
# to the envelope, so it naturally resets when this run finishes and a later
# run starts). Folded into whichever message this invocation already emits
# rather than printed separately, since at most one JSON object may go out
# per Stop event (the single-blocker contract above).
ANNOUNCE_FILE="$(dirname "$envelope")/.stop-gate-announced"
cmd_note=""
if [ ! -f "$ANNOUNCE_FILE" ]; then
  cmd_note="stop-gate: first Stop this run -- will execute test.unit (\`$test_cmd\`) from .claude/project.json on every Stop while in_progress (trust model: docs/ENFORCEMENT.md). "
  : > "$ANNOUNCE_FILE" 2>/dev/null || true
fi

# Resolve a timeout runner BEFORE running anything, rather than hard-coding
# `timeout` -- stock macOS has no `timeout(1)` (it ships neither GNU nor BSD
# coreutils' version) unless the user installed coreutils, and bash then
# reports the literal "timeout: command not found" as exit 127 -- the exact
# code this script already uses to mean "test.unit is missing". Without this
# resolution, that collision made the gate silently stand down on stock macOS
# instead of running the suite, on every single Stop. `command -v` here
# proves each wrapper resolves; unlike the python probes elsewhere in this
# hook family a wrapper only needs to exist on PATH, not "prove it runs" --
# `timeout`/`gtimeout`/`perl` don't have a Store-stub failure mode.
RUNNER=""
if command -v timeout >/dev/null 2>&1; then
  RUNNER="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  RUNNER="gtimeout"
elif command -v perl >/dev/null 2>&1; then
  RUNNER="perl"
fi

case "$RUNNER" in
  timeout|gtimeout)
    output="$(cd "$PROJ" 2>/dev/null && "$RUNNER" "$timeout_s" bash -c "$test_cmd" 2>&1)"
    rc=$?
    ;;
  perl)
    # perl ships with macOS by default even without coreutils. `alarm` fires
    # SIGALRM after $timeout_s seconds; its handler is the process default
    # (kill) both before AND after `exec` replaces this perl process with
    # bash, so this behaves like `timeout N bash -c CMD` for our purposes.
    output="$(cd "$PROJ" 2>/dev/null && perl -e 'alarm shift; exec @ARGV' "$timeout_s" bash -c "$test_cmd" 2>&1)"
    rc=$?
    ;;
  *)
    # No wrapper at all: run WITHOUT a time limit rather than never running
    # the suite -- a hung test.unit is a smaller failure than a gate that
    # never enforces anything. Flagged below so it isn't silently unbounded.
    output="$(cd "$PROJ" 2>/dev/null && bash -c "$test_cmd" 2>&1)"
    rc=$?
    ;;
esac

# Never block on a missing command (exit 127 is the shell's own signal for
# "command not found", portable across single- and compound-command test.unit
# values, e.g. `cd web && pnpm test`). Reached only when the TEST command
# itself is missing -- $RUNNER, when set, was already proven to resolve
# above, so a 127 here can no longer be misattributed to the timeout wrapper.
if [ "$rc" -eq 127 ]; then
  emit_message "${cmd_note}stop-gate: standing down — test.unit command not found ($test_cmd)."
  exit 0
fi

if [ "$rc" -eq 0 ]; then
  rm -f "$HOPS_FILE" 2>/dev/null || true
  if [ -z "$RUNNER" ]; then
    emit_message "${cmd_note}stop-gate: tests green, but ran with NO time limit — no timeout, gtimeout, or perl found on PATH to bound test.unit."
  elif [ -n "$cmd_note" ]; then
    emit_message "${cmd_note}stop-gate: tests green."
  fi
  exit 0
fi

new_hops=$((hops + 1))
printf '%s' "$new_hops" > "$HOPS_FILE" 2>/dev/null || true
tail_out="$(printf '%s\n' "$output" | tail -n 15)"
tail_out="${tail_out:0:1200}"
if [ -z "$tail_out" ]; then
  tail_out="(command produced no output; exit code ${rc})"
fi
reason="${cmd_note}stop-gate: tests red — ${tail_out}"
if [ -z "$RUNNER" ]; then
  reason="${cmd_note}stop-gate: tests red (ran with NO time limit — no timeout, gtimeout, or perl found on PATH) — ${tail_out}"
fi
emit_block "$reason"
exit 0
