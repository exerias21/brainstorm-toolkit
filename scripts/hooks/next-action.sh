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
# file. Any other reader (e.g. a future reader that inspects the
# pending next-action) must PEEK: read without deleting. A second consumer would
# eat the hint before the user sees it.
#
# Skills surface a follow-up command by APPENDING one line (>>), not overwriting
# (>), so independent sources coexist. Preferred structured form (multi-slot):
#   echo '{"cmd":"/sdlc plans/foo.md","source":"brainstorm","confirm":false}' >> .claude/.next-action
# A bare command line is still accepted (legacy single-slot):
#   echo '/sdlc plans/brainstorm-add-orders.md' >> .claude/.next-action
# Set "confirm":true for anything that writes git history (e.g. a commit); dedup by
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

# Resolve a working Python by matching scripts/py.sh's full contract, not
# merely "on PATH" (a Windows Store `python3` stub satisfies `command -v`
# and then exits non-zero) -- this script calls python3 at three separate
# sites below, so it needs the resolved value, not py.sh's one-shot `exec`
# tail. Order: $BRAINSTORM_PYTHON -> .claude/project.json `python` -> probe
# python3/python/py, each proven to RUN. One resolver's contract, matched
# here rather than sourced, per scripts/py.sh's own header.
PY="${BRAINSTORM_PYTHON:-}"
if [ -n "$PY" ] && ! "$PY" -c 'pass' >/dev/null 2>&1; then PY=""; fi
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
#    `confirm: true` marks an action a human should approve first (e.g. a commit,
#    which opens a PR); a future auto-continue consumer must honor it.
sentinel_cmds=()      # raw cmds, for the auto-continue decision (L9)
sentinel_confirm=()   # 0/1 per cmd, parallel to sentinel_cmds
if [ -s "$NEXT_ACTION_FILE" ]; then
  if [ -n "$PY" ]; then
    while IFS="$(printf '\t')" read -r cflag cmd; do
      # Strip a trailing CR here, at the read site -- a Windows Python's stdout is
      # opened in text mode, which translates the emitted "\n" into "\r\n", so
      # `read -r` (which splits on \n only) leaves the \r attached to $cmd. Left
      # in, it rides into the joined systemMessage (seen live:
      # "Next: /sdlc plans/X.md\r\n..."). $cflag gets the same treatment for symmetry.
      cmd="${cmd%$'\r'}"; cflag="${cflag%$'\r'}"
      [ -n "$cmd" ] || continue
      sentinel_cmds+=("$cmd"); sentinel_confirm+=("$cflag")
      if [ "$cflag" = "1" ]; then
        msgs+=("Next: $cmd (confirm before running)")
      else
        msgs+=("Next: $cmd")
      fi
    done < <("$PY" -c '
import json, os, sys
proj = sys.argv[1] if len(sys.argv) > 1 else "."
seen = set()
for raw in sys.stdin:
    s = raw.strip()
    if not s:
        continue
    try:
        obj = json.loads(s)
        if not isinstance(obj, dict):
            raise ValueError
        cmd = str(obj.get("cmd", "")).strip()
        confirm = "1" if obj.get("confirm") else "0"
    except (ValueError, TypeError):
        cmd = s  # not JSON -> legacy bare command (never confirm)
        confirm = "0"
    if not cmd:
        continue
    if cmd in seen:
        continue  # dedup by cmd (SEAM.md: dedup key is cmd, not the raw line)
    # Drop an entry whose plan/target file no longer exists (or was already
    # delivered) -- a stale pointer left over from a finished/abandoned run.
    dropped = False
    for tok in cmd.split():
        if "/" in tok and (tok.endswith(".md") or tok.endswith(".json")):
            path = tok if os.path.isabs(tok) else os.path.join(proj, tok)
            if not os.path.exists(path):
                dropped = True
                break
    if dropped:
        continue
    seen.add(cmd)
    print(confirm + "\t" + cmd)
' "$PROJ" < "$NEXT_ACTION_FILE")
    # Only the branch that actually parsed the file may consume it -- on an
    # interpreter that resolves but fails to run, NEXT_ACTION_FILE must
    # survive so the sentinel is not silently eaten with zero output.
    rm -f "$NEXT_ACTION_FILE"
  fi
  # A parked seam (more than one distinct pending action) must announce
  # itself -- a parked hook otherwise looks identical to a hook with
  # nothing to say (docs/SEAM.md).
  if [ "${#sentinel_cmds[@]}" -gt 1 ]; then
    msgs+=("⚠ ${#sentinel_cmds[@]} actions pending — seam parked")
  fi
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
    msgs+=("⚠ ${stale} stale pipeline run(s) (in_progress/paused >1d). Run /sdlc-status or /repo-health to reconcile.")
  fi
fi

# 3. Condition-derived (L8): a brainstorm plan with no pipeline run is a pending
#    handoff that outlived its fire-once sentinel. Recomputed every Stop, never
#    stored — persists while the plan sits unbuilt, unlike the sentinel. Guarded
#    against noise: only `brainstorm-<slug>.md` (the pipeline-intended plans, not
#    meta docs), only modified in the last 7 days (older ⇒ intentionally parked,
#    not pending), and only when no .claude/pipeline/<slug>/ envelope exists.
#    In a skill repo (.claude-plugin/marketplace.json at repo root -- same detection
#    /sdlc itself uses), /brainstorm and /brainstorm-team write to docs/plans/ instead
#    of plans/ (see docs/SEAM.md / skills/sdlc/templates/state-schema.md), so scan
#    that directory there too -- excluding README.md, which indexes the plans rather
#    than being one.
PLANS_DIR="$PROJ/plans"
pending=0
if [ -d "$PLANS_DIR" ]; then
  for pf in "$PLANS_DIR"/brainstorm-*.md; do
    [ -e "$pf" ] || continue
    [ -n "$(find "$pf" -mtime -7 2>/dev/null)" ] || continue
    base="$(basename "$pf" .md)"; slug="${base#brainstorm-}"
    [ -d "$PROJ/.claude/pipeline/$slug" ] && continue
    pending=$((pending+1))
  done
fi
if [ -f "$PROJ/.claude-plugin/marketplace.json" ] && [ -d "$PROJ/docs/plans" ]; then
  for pf in "$PROJ/docs/plans"/*.md; do
    [ -e "$pf" ] || continue
    base="$(basename "$pf" .md)"
    [ "$base" = "README" ] && continue
    [ -n "$(find "$pf" -mtime -7 2>/dev/null)" ] || continue
    slug="${base#team-brainstorm-}"; slug="${slug#brainstorm-}"
    [ -d "$PROJ/.claude/pipeline/$slug" ] && continue
    pending=$((pending+1))
  done
fi
if [ "$pending" -gt 0 ]; then
  msgs+=("◆ ${pending} recent plan(s) awaiting a pipeline run. Run /sdlc-status for the recommended next step.")
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
#     Long-loop context hygiene (the reseed-context.sh companion hook that keeps auto-compaction
#     lossless for a --queue/auto-continue run) is documented in docs/LOOP-HYGIENE.md.
HOPS_FILE="$PROJ/.claude/.auto-continue-hops"
PROJECT_JSON="$PROJ/.claude/project.json"
if { [ -n "${CLAUDE_PROJECT_DIR:-}" ] || [ -n "${CODEX_HOME:-}" ]; } \
   && [ -f "$PROJECT_JSON" ] \
   && grep -Eq '"auto_continue"[[:space:]]*:[[:space:]]*true' "$PROJECT_JSON" 2>/dev/null \
   && [ "${#sentinel_cmds[@]}" -eq 1 ] \
   && [ "${sentinel_confirm[0]:-1}" = "0" ] \
   && [ -n "$PY" ]; then
  max_hops="$(grep -Eo '"max_hops"[[:space:]]*:[[:space:]]*[0-9]+' "$PROJECT_JSON" 2>/dev/null | grep -Eo '[0-9]+' | head -1)"
  [ -n "$max_hops" ] || max_hops=5
  if [ -s "$HOPS_FILE" ]; then remaining="$(cat "$HOPS_FILE" 2>/dev/null)"; else remaining="$max_hops"; fi
  case "$remaining" in ''|*[!0-9]*) remaining="$max_hops";; esac
  if [ "$remaining" -gt 0 ]; then
    printf '%s' "$((remaining - 1))" > "$HOPS_FILE"
    "$PY" -c 'import json,sys; print(json.dumps({"decision":"block","reason":"Continue with: "+sys.argv[1]}))' "${sentinel_cmds[0]}"
    exit 0
  fi
  # Budget exhausted -> park (print) and reset the chain.
  msgs+=("⛔ auto-continue hop budget reached — parking. Run the command above to continue.")
fi
# Any print path ends the chain: reset the hop budget for the next one.
rm -f "$HOPS_FILE" 2>/dev/null || true

[ ${#msgs[@]} -gt 0 ] || exit 0

# Emit JSON with systemMessage (newline-joined). $PY handles escaping; if no
# working interpreter was resolved, stay silent rather than risk invalid
# JSON. Never blocks.
if [ -n "$PY" ]; then
  "$PY" -c '
import json, sys
print(json.dumps({"systemMessage": "\n".join(sys.argv[1:])}))
' "${msgs[@]}"
fi

exit 0
