#!/usr/bin/env bash
# brainstorm-toolkit — PreToolUse(AskUserQuestion) hook: deny operator questions the advisor
# did not approve.
#
# INERT unless .claude/project.json has `pipeline.question_advisor.gate: true`. The question
# tool only: a question typed as plain text is not covered. The file flag
# .claude/pipeline/_advice/off lets everything through (an env var cannot be set in a
# running session). Fails open: malformed input, a missing helper or any error emits nothing;
# gate on with no interpreter emits a visible systemMessage instead.
set -u
input="$(cat 2>/dev/null || true)"
[ -n "$input" ] || exit 0

PROJ="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$PROJ" ]; then
  if _gr="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$_gr" ]; then PROJ="$_gr"; else PROJ="$PWD"; fi
fi
HERE="$(dirname "${BASH_SOURCE[0]:-$0}")"
# shellcheck source=./_pyresolve.sh
. "$HERE/_pyresolve.sh"
PY="$(hooks_resolve_python "$PROJ")" || PY=""
if [ -z "$PY" ]; then
  if [ -f "$PROJ/.claude/project.json" ] \
     && grep -Eq '"gate"[[:space:]]*:[[:space:]]*true' "$PROJ/.claude/project.json" 2>/dev/null; then
    printf '%s' "$input" | grep -q '"tool_name"[[:space:]]*:[[:space:]]*"AskUserQuestion"' 2>/dev/null && \
    echo '{"systemMessage":"ask-gate hook: pipeline.question_advisor.gate is true but no working Python interpreter was found -- operator questions are NOT being checked this call."}'
  fi
  exit 0
fi

active="$(HOOK_INPUT="$input" "$PY" - "$PROJ" <<'PY'
import json, os, sys

try:
    inp = json.loads(os.environ.get("HOOK_INPUT", ""))
except Exception:
    sys.exit(0)
if not isinstance(inp, dict) or inp.get("tool_name") != "AskUserQuestion":
    sys.exit(0)
proj = sys.argv[1]
try:
    with open(os.path.join(proj, ".claude", "project.json"), encoding="utf-8") as fh:
        cfg = json.load(fh)
    qa = (cfg.get("pipeline") or {}).get("question_advisor") or {}
except Exception:
    sys.exit(0)
if not isinstance(qa, dict) or qa.get("gate") is not True:
    sys.exit(0)
if os.path.exists(os.path.join(proj, ".claude", "pipeline", "_advice", "off")):
    sys.exit(0)
print("1")
PY
)" || exit 0
[ "$active" = "1" ] || exit 0

verdict="$(printf '%s' "$input" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HERE/../question-advice.sh" check 2>/dev/null)" || exit 0
case "$verdict" in
  deny:*)
    reason="${verdict#deny: }"
    HOOK_REASON="$reason" "$PY" -c '
import json, os
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "Operator question blocked (" + os.environ["HOOK_REASON"] + "). Run the advisor pass in skills/sdlc/templates/operator-gate.md, record the approved questions with scripts/question-advice.sh approve, then ask exactly those."}}))
' 2>/dev/null ;;
esac
exit 0
