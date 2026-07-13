#!/usr/bin/env bash
# next-action.sh — Stop-hook helper that surfaces a "next command" hint to the
# user when a skill drops one at .claude/.next-action.
#
# Contract:
#   - Reads (and discards) stdin — Claude Code / Copilot Stop hooks send the
#     session context as JSON; this hook ignores it.
#   - If .claude/.next-action exists and is non-empty, emits a single
#     systemMessage line and removes the file (so the hint fires once, not on
#     every Stop).
#   - Always exits 0; this hook is informational and must never block.
#
# Peek-vs-consume rule: this hook is the ONLY consumer — it alone deletes the
# file. Any other reader (e.g. a future /next or /status that inspects the
# pending next-action) must PEEK: read without deleting. A second consumer would
# eat the hint before the user sees it.
#
# Skills surface a follow-up command by APPENDING one line (>>), not overwriting
# (>), so independent sources coexist. Preferred structured form (multi-slot):
#   echo '{"cmd":"/sdlc-lite plans/foo.md","source":"brainstorm","confirm":false}' >> .claude/.next-action
# A bare command line is still accepted (legacy single-slot):
#   echo '/sdlc plans/brainstorm-add-orders.md' >> .claude/.next-action
# Set "confirm":true for anything that writes git history (e.g. /sdlc); dedup by
# cmd at the writer. Full contract: docs/SEAM.md.
#
# Cross-tool: the SAME script is wired into every runtime's `Stop` hook — Claude Code
# (`.claude/settings.json`), Copilot (`.github/hooks/*.json`), and Codex
# (`.codex/hooks.json`; Codex has a Stop hook with the same decision:block contract).
# All consume `systemMessage` from stdout JSON identically for the printed hint.
#
# Auto-continue (L9, OPT-IN, default OFF): with `pipeline.auto_continue: true` in
# .claude/project.json, on Claude Code OR Codex (both honor Stop-hook decision:block),
# a SINGLE non-confirm sentinel is EXECUTED (return
# {"decision":"block","reason":"Continue with: <cmd>"}) instead of printed — the
# session loops itself. Guardrails: never a confirm:true action; a
# hop budget (`pipeline.loop.max_hops`, default 5) in .claude/.auto-continue-hops
# bounds the chain; multiple pending actions park to a printed hint. Unset knob ⇒
# print behavior, unchanged. See docs/SEAM.md.

set -u

# Drain stdin without reading it — keeps the hook robust to large session
# context payloads on either runtime.
cat >/dev/null 2>&1 || true

# Resolve relative to the project root. Claude Code sets CLAUDE_PROJECT_DIR; Copilot
# sets cwd to the workspace root; Codex runs the hook with the session cwd (and may be
# started from a subdirectory), so fall back to the git top-level, then cwd.
PROJ="."
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then
  PROJ="$CLAUDE_PROJECT_DIR"
elif _gr="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$_gr" ]; then
  PROJ="$_gr"
fi
NEXT_ACTION_FILE="$PROJ/.claude/.next-action"

# Collect messages. Two kinds, by design:
#   - TRANSIENT hint: the .next-action sentinel — fires once, then deleted.
#   - CONDITION-DERIVED warning: recomputed from live state every Stop and
#     NEVER stored/deleted, so it persists while its cause is still true.
#     (A warning that deletes itself while the condition holds is useless.)
msgs=()

# 1. Transient next-action hint(s), fire-once. MULTI-SLOT: one entry per
#    non-empty line, so independent sources (e.g. the gotcha seam and a pipeline
#    handoff) coexist instead of racing for a single slot. Each line is either:
#      - a JSON object {"cmd": "...", "source": "...", "confirm": bool}, or
#      - a bare command string (legacy single-slot format — still supported).
#    `confirm: true` marks an action a human should approve first (e.g. /sdlc,
#    which opens a PR); a future auto-continue consumer must honor it.
sentinel_cmds=()      # raw cmds, for the auto-continue decision (L9)
sentinel_confirm=()   # 0/1 per cmd, parallel to sentinel_cmds
if [ -s "$NEXT_ACTION_FILE" ]; then
  if command -v python3 >/dev/null 2>&1; then
    while IFS="$(printf '\t')" read -r cflag cmd; do
      [ -n "$cmd" ] || continue
      sentinel_cmds+=("$cmd"); sentinel_confirm+=("$cflag")
      if [ "$cflag" = "1" ]; then
        msgs+=("Next: $cmd (confirm before running)")
      else
        msgs+=("Next: $cmd")
      fi
    done < <(python3 -c '
import json, sys
for raw in sys.stdin:
    s = raw.strip()
    if not s:
        continue
    try:
        obj = json.loads(s)
        if not isinstance(obj, dict):
            raise ValueError
        cmd = str(obj.get("cmd", "")).strip()
        if not cmd:
            continue
        print(("1" if obj.get("confirm") else "0") + "\t" + cmd)
    except (ValueError, TypeError):
        print("0\t" + s)  # not JSON -> legacy bare command (never confirm)
' < "$NEXT_ACTION_FILE")
  fi
  rm -f "$NEXT_ACTION_FILE"
fi

# 2. Condition-derived: a pipeline run left in_progress/paused with a stale
#    run.json is a skipped or abandoned pipeline (committed outside it, or
#    crashed). Pure file read — no model, no cost, never executes repo code.
#    Staleness = run.json untouched for >1 day. This is the "discipline was
#    skipped and nobody noticed" signal, surfaced live.
PIPE_DIR="$PROJ/.claude/pipeline"
if [ -d "$PIPE_DIR" ]; then
  stale=0
  for rj in "$PIPE_DIR"/*/run.json; do
    [ -e "$rj" ] || continue
    grep -q '"status"[[:space:]]*:[[:space:]]*"\(in_progress\|paused\)"' "$rj" 2>/dev/null || continue
    [ -n "$(find "$rj" -mtime +1 2>/dev/null)" ] && stale=$((stale+1))
  done
  if [ "$stale" -gt 0 ]; then
    msgs+=("⚠ ${stale} stale pipeline run(s) (in_progress/paused >1d). Run /status or /repo-health to reconcile.")
  fi
fi

# 3. Condition-derived (L8): a brainstorm plan with no pipeline run is a pending
#    handoff that outlived its fire-once sentinel. Recomputed every Stop, never
#    stored — persists while the plan sits unbuilt, unlike the sentinel. Guarded
#    against noise: only `brainstorm-<slug>.md` (the pipeline-intended plans, not
#    meta docs), only modified in the last 7 days (older ⇒ intentionally parked,
#    not pending), and only when no .claude/pipeline/<slug>/ envelope exists.
PLANS_DIR="$PROJ/plans"
if [ -d "$PLANS_DIR" ]; then
  pending=0
  for pf in "$PLANS_DIR"/brainstorm-*.md; do
    [ -e "$pf" ] || continue
    [ -n "$(find "$pf" -mtime -7 2>/dev/null)" ] || continue
    base="$(basename "$pf" .md)"; slug="${base#brainstorm-}"
    [ -d "$PROJ/.claude/pipeline/$slug" ] && continue
    pending=$((pending+1))
  done
  if [ "$pending" -gt 0 ]; then
    msgs+=("◆ ${pending} recent plan(s) awaiting a pipeline run. Run /next for the recommended next step.")
  fi
fi

# --- Auto-continue (L9) — OPT-IN, Claude-only, guardrailed. Turns a single
#     non-confirm sentinel into execution by returning {"decision":"block"}
#     (feeds `reason` back to the model as its next instruction) instead of a
#     printed hint — the session becomes the loop, the sentinel its program
#     counter. DEFAULT OFF: with the knob unset, behavior is unchanged (print).
#     Guardrails (non-negotiable): (1) opt-in `pipeline.auto_continue: true`;
#     (2) never a `confirm:true` action (those always park to a printed hint);
#     (3) a hop budget bounds the chain like the 3-iteration fix budget bounds a
#     fix loop; (4) runtime must support Stop-hook decision:block — Claude
#     (CLAUDE_PROJECT_DIR) or Codex (CODEX_* env; both honor decision:block per their
#     docs). Copilot stays print-only (its block-equivalent is unverified). NOTE: the
#     Codex env marker (CODEX_HOME) should be confirmed on a real Codex install; if it
#     doesn't match, auto-continue safely falls back to print. SINGLE action only → park.
HOPS_FILE="$PROJ/.claude/.auto-continue-hops"
PROJECT_JSON="$PROJ/.claude/project.json"
if { [ -n "${CLAUDE_PROJECT_DIR:-}" ] || [ -n "${CODEX_HOME:-}" ]; } \
   && [ -f "$PROJECT_JSON" ] \
   && grep -Eq '"auto_continue"[[:space:]]*:[[:space:]]*true' "$PROJECT_JSON" 2>/dev/null \
   && [ "${#sentinel_cmds[@]}" -eq 1 ] \
   && [ "${sentinel_confirm[0]:-1}" = "0" ] \
   && command -v python3 >/dev/null 2>&1; then
  max_hops="$(grep -Eo '"max_hops"[[:space:]]*:[[:space:]]*[0-9]+' "$PROJECT_JSON" 2>/dev/null | grep -Eo '[0-9]+' | head -1)"
  [ -n "$max_hops" ] || max_hops=5
  if [ -s "$HOPS_FILE" ]; then remaining="$(cat "$HOPS_FILE" 2>/dev/null)"; else remaining="$max_hops"; fi
  case "$remaining" in ''|*[!0-9]*) remaining="$max_hops";; esac
  if [ "$remaining" -gt 0 ]; then
    printf '%s' "$((remaining - 1))" > "$HOPS_FILE"
    python3 -c 'import json,sys; print(json.dumps({"decision":"block","reason":"Continue with: "+sys.argv[1]}))' "${sentinel_cmds[0]}"
    exit 0
  fi
  # Budget exhausted -> park (print) and reset the chain.
  msgs+=("⛔ auto-continue hop budget reached — parking. Run the command above to continue.")
fi
# Any print path ends the chain: reset the hop budget for the next one.
rm -f "$HOPS_FILE" 2>/dev/null || true

[ ${#msgs[@]} -gt 0 ] || exit 0

# Emit JSON with systemMessage (newline-joined). python3 handles escaping;
# if it's absent, stay silent rather than risk invalid JSON. Never blocks.
if command -v python3 >/dev/null 2>&1; then
  python3 -c '
import json, sys
print(json.dumps({"systemMessage": "\n".join(sys.argv[1:])}))
' "${msgs[@]}"
fi

exit 0
