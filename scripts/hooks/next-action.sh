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
# Skills that want to surface a follow-up command write the file with one line:
#   echo '/sdlc plans/brainstorm-add-orders.md' > .claude/.next-action
#
# Cross-tool: the same script is wired into Claude Code's `Stop` hook (via
# .claude/settings.json) and Copilot's `Stop` hook (via .github/hooks/*.json).
# Both runtimes consume `systemMessage` from stdout JSON identically.

set -u

# Drain stdin without reading it — keeps the hook robust to large session
# context payloads on either runtime.
cat >/dev/null 2>&1 || true

# Resolve relative to the project root. Claude Code sets CLAUDE_PROJECT_DIR;
# Copilot sets the cwd to the workspace root.
PROJ="."
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then
  PROJ="$CLAUDE_PROJECT_DIR"
fi
NEXT_ACTION_FILE="$PROJ/.claude/.next-action"

# Collect messages. Two kinds, by design:
#   - TRANSIENT hint: the .next-action sentinel — fires once, then deleted.
#   - CONDITION-DERIVED warning: recomputed from live state every Stop and
#     NEVER stored/deleted, so it persists while its cause is still true.
#     (A warning that deletes itself while the condition holds is useless.)
msgs=()

# 1. Transient next-action hint (fire-once).
if [ -s "$NEXT_ACTION_FILE" ]; then
  cmd="$(awk 'NF{print; exit}' "$NEXT_ACTION_FILE" | sed 's/[[:space:]]*$//')"
  rm -f "$NEXT_ACTION_FILE"
  [ -n "$cmd" ] && msgs+=("Next: $cmd")
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
