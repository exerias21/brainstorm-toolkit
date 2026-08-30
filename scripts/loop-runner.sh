#!/usr/bin/env bash
# scripts/loop-runner.sh — batch-handoff queue runner (OPT-IN, you run it yourself).
#
# Processes the pending TASKS.md backlog in BATCHES so a long queue never bloats one
# session: each batch is a FRESH headless process (clean context) that runs sdlc
# in --queue mode over up to X items, then exits; the runner relaunches until the queue
# drains. Context resets every X items — at a clean completed-item boundary, never
# mid-plan. State is handed off via disk (.claude/pipeline/<slug>/run.json + .next-action
# + TASKS.md), which the toolkit already externalizes, so a cold process reads its
# position at startup and never `resume`s a prior transcript.
#
# Batch size X resolves:  --queue N  >  .claude/project.json pipeline.loop.batch_size
#                         >  pipeline.loop.max_items  >  5.  (5–10 is the useful range.)
# --fresh no  runs the WHOLE queue in ONE process (no context reset) — for short queues
#             where a reset isn't worth the per-process baseline re-pay.
#
# This is the toolkit's Lever-C stance as an opt-in script (NOT a skill, NOT a daemon,
# NOT wired by setup.sh). It launches headless agents that edit files + run Bash
# unattended on the CURRENT repo — review the allowlist below and understand the scope
# before using. It makes NO git commits (sdlc hands off a validated tree). See
# docs/LOOP-HYGIENE.md.
set -euo pipefail

PROJ="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$PROJ"

ENGINE="claude"          # claude | codex
FRESH="yes"              # yes = batch-handoff (fresh process per batch); no = one process
BATCH=""                 # X; empty -> project.json -> default
MODEL=""                 # optional model override (--model / -m)
DRY_RUN="0"
TASKS_FILE="TASKS.md"
PROJECT_JSON=".claude/project.json"

usage() {
  cat >&2 <<'USAGE'
usage: loop-runner.sh [--queue X] [--fresh yes|no] [--engine claude|codex] [--model M] [--dry-run]
  --queue X     items per fresh process (batch size). Default: project.json
                pipeline.loop.batch_size > pipeline.loop.max_items > 5.
  --fresh no    run the whole queue in ONE process (no context reset).
  --engine      claude (default) or codex.
  --model M     model override passed to the engine.
  --dry-run     print the batch-1 command and exit; run nothing.
Extra engine flags: set LOOP_RUNNER_EXTRA (e.g. LOOP_RUNNER_EXTRA='--max-budget-usd 5').
USAGE
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --queue)   BATCH="${2:-}"; shift 2 ;;
    --fresh)   FRESH="${2:-}"; shift 2 ;;
    --engine)  ENGINE="${2:-}"; shift 2 ;;
    --model)   MODEL="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN="1"; shift ;;
    -h|--help) usage ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

# Batch size: flag > project.json batch_size > project.json max_items > 5.
if [ -z "$BATCH" ] && command -v jq >/dev/null 2>&1 && [ -f "$PROJECT_JSON" ]; then
  BATCH="$(jq -r '.pipeline.loop.batch_size // .pipeline.loop.max_items // empty' "$PROJECT_JSON" 2>/dev/null || true)"
fi
[ -n "$BATCH" ] || BATCH=5

case "$BATCH" in ''|*[!0-9]*) echo "batch size must be a positive integer, got: '$BATCH'" >&2; exit 2 ;; esac
[ "$BATCH" -ge 1 ] || { echo "batch size must be >= 1" >&2; exit 2; }
case "$FRESH" in yes|no) ;; *) echo "--fresh must be yes or no" >&2; exit 2 ;; esac
case "$ENGINE" in claude|codex) ;; *) echo "--engine must be claude or codex" >&2; exit 2 ;; esac
[ -f "$TASKS_FILE" ] || { echo "[loop-runner] no $TASKS_FILE at repo root — nothing to run."; exit 0; }

# Count pending ('- [ ] ') rows. Always exits 0 (grep -c prints 0 + exits 1 on no match).
pending() { local n; n="$(grep -cE '^- \[ \] ' "$TASKS_FILE" 2>/dev/null || true)"; echo "${n:-0}"; }

# Build + run one batch of up to $1 items in a fresh headless process.
run_batch() {
  local n="$1"
  local prompt="Use the brainstorm-toolkit sdlc skill in queue mode (--queue ${n}) over the pending TASKS.md backlog: process up to ${n} pending items, then stop. Durable state is under .claude/pipeline/ and TASKS.md — read your position from disk; do NOT resume any prior session, and make NO git commits."
  local -a cmd
  if [ "$ENGINE" = "claude" ]; then
    # --allowed-tools auto-approves these for unattended runs (mirrors docs/AUTONOMOUS-DISCOVERY.md).
    cmd=(claude -p --allowed-tools "Bash,Read,Write,Edit,Glob,Grep,Skill,TodoWrite,WebSearch,WebFetch")
    [ -n "$MODEL" ] && cmd+=(--model "$MODEL")
  else
    cmd=(codex exec --ephemeral --full-auto)   # --ephemeral: don't persist the rollout
    [ -n "$MODEL" ] && cmd+=(-m "$MODEL")
  fi
  # shellcheck disable=SC2206
  [ -n "${LOOP_RUNNER_EXTRA:-}" ] && cmd+=(${LOOP_RUNNER_EXTRA})
  cmd+=("$prompt")
  if [ "$DRY_RUN" = "1" ]; then printf '[dry-run] '; printf '%q ' "${cmd[@]}"; printf '\n'; return 0; fi
  "${cmd[@]}"
}

# --fresh no: whole queue in one process, no context reset.
if [ "$FRESH" = "no" ]; then
  p="$(pending)"; [ "$p" -gt 0 ] || { echo "[loop-runner] no pending items."; exit 0; }
  echo "[loop-runner] --fresh no: whole queue ($p items) in one $ENGINE process (no context reset)."
  if [ "$DRY_RUN" = "1" ]; then run_batch "$p"; exit 0; fi
  run_batch "$p" || { echo "[loop-runner] run failed." >&2; exit 1; }
  exit 0
fi

# Batch-handoff loop: a fresh process per X items.
echo "[loop-runner] batch-handoff: $(pending) pending; X=$BATCH; engine=$ENGINE${DRY_RUN:+ (dry-run)}"
if [ "$DRY_RUN" = "1" ]; then run_batch "$BATCH"; exit 0; fi
batch_no=0
while [ "$(pending)" -gt 0 ]; do
  batch_no=$((batch_no + 1)); before="$(pending)"
  echo "[loop-runner] batch #$batch_no — $before pending — launching fresh $ENGINE process (X=$BATCH)"
  if ! run_batch "$BATCH"; then
    echo "[loop-runner] batch #$batch_no failed — stopping." >&2; exit 1
  fi
  after="$(pending)"
  if [ "$after" -ge "$before" ]; then
    echo "[loop-runner] no progress ($before -> $after pending) — stopping to avoid a spin." >&2
    echo "[loop-runner] remaining items may be parked/blocked; check /sdlc-status." >&2
    exit 1
  fi
done
echo "[loop-runner] queue drained after $batch_no batch(es)."
