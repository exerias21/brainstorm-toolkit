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

NEXT_ACTION_FILE=".claude/.next-action"

# Resolve relative to the project root. Claude Code sets CLAUDE_PROJECT_DIR;
# Copilot sets the cwd to the workspace root. Either way, the relative path
# resolves correctly when launched by the runtime.
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then
  NEXT_ACTION_FILE="$CLAUDE_PROJECT_DIR/$NEXT_ACTION_FILE"
fi

[ -s "$NEXT_ACTION_FILE" ] || exit 0

# First non-empty line is the command. Trim trailing whitespace; ignore
# anything after the first line so future versions can append metadata
# without breaking older hooks.
cmd="$(awk 'NF{print; exit}' "$NEXT_ACTION_FILE" | sed 's/[[:space:]]*$//')"
rm -f "$NEXT_ACTION_FILE"

[ -n "$cmd" ] || exit 0

# Emit JSON with systemMessage. Use python3 for reliable JSON escaping
# (handles quotes, backslashes, control chars). Falls back to a sed-based
# escape if python3 isn't on PATH — keeps the hook usable on minimal images.
if command -v python3 >/dev/null 2>&1; then
  python3 -c '
import json, sys
print(json.dumps({"systemMessage": f"Next: {sys.argv[1]}"}))
' "$cmd"
else
  esc=$(printf '%s' "$cmd" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
  printf '{"systemMessage":"Next: %s"}\n' "$esc"
fi

exit 0
