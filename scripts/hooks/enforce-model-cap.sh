#!/usr/bin/env bash
# brainstorm-toolkit — PreToolUse(Agent) hook: make models.cap deterministic.
#
# The cap is otherwise prose-enforced: each fan-out dispatch site resolves the tier and passes
# `model`. That is one instruction the orchestrator can forget, and a dispatch that omits
# `model` inherits the session model with zero error and zero log line. This hook closes both
# gaps on Claude Code, where PreToolUse can rewrite tool input before the call runs:
#
#   * `model` above the cap            -> rewritten to the cap (haiku < sonnet < opus; fable > opus)
#   * `model` omitted                  -> set to the cap, unless the named agent definition pins
#                                         its own tier (agents/<type>.md has a `model:` line)
#   * description starting `review:`   -> untouched. Axis 2 (the adversarial reviewer) is
#                                         never governed by models.cap; stage-5.7 marks its
#                                         dispatches with that prefix for exactly this reason.
#
# INERT unless .claude/project.json has BOTH `pipeline.enforce_cap: true` AND a valid
# `models.cap`. Opt-in because the hook cannot see a per-run `--model opus`: with enforcement
# on, the config cap is policy and a flag above it is clamped. Every rewrite is reported to the
# human as `systemMessage` (costs no model tokens). Never blocks, never denies.
set -u
input="$(cat 2>/dev/null || true)"
[ -n "$input" ] || exit 0

PROJ="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$PROJ" ]; then
  if _gr="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$_gr" ]; then PROJ="$_gr"; else PROJ="$PWD"; fi
fi
PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'pass' >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -n "$PY" ] || exit 0

# The script arrives on stdin (heredoc), so the hook payload travels in an env var instead.
HOOK_INPUT="$input" "$PY" - "$PROJ" "${CLAUDE_PLUGIN_ROOT:-}" <<'PY'
import json, os, re, sys

try:
    inp = json.loads(os.environ.get("HOOK_INPUT", ""))
except Exception:
    sys.exit(0)
proj, plugin = sys.argv[1], sys.argv[2]
if inp.get("tool_name") != "Agent":
    sys.exit(0)
try:
    with open(os.path.join(proj, ".claude", "project.json"), encoding="utf-8") as fh:
        cfg = json.load(fh)
except Exception:
    sys.exit(0)
pipe = cfg.get("pipeline") if isinstance(cfg.get("pipeline"), dict) else {}
if pipe.get("enforce_cap") is not True:
    sys.exit(0)
models = cfg.get("models") if isinstance(cfg.get("models"), dict) else {}
cap = models.get("cap")
RANK = {"haiku": 1, "sonnet": 2, "opus": 3}
if cap not in RANK:
    sys.exit(0)

ti = dict(inp.get("tool_input") or {})
desc = str(ti.get("description") or "")
stype = str(ti.get("subagent_type") or "")
model = ti.get("model")

def emit(new_model, why):
    updated = dict(ti)
    updated["model"] = new_model
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "updatedInput": updated,
        },
        "systemMessage": f"models.cap hook: {why}",
    }))
    sys.exit(0)

# Axis 2 is exempt by contract (skills/sdlc/templates/models.md).
if desc.strip().lower().startswith("review:"):
    sys.exit(0)

if model:
    m = str(model).lower()
    tier = next((t for t in ("opus", "sonnet", "haiku") if t in m), None)
    if tier is None and "fable" in m:
        tier = "fable"
    if tier is None:
        sys.exit(0)  # an id this hook does not recognise -- leave it alone rather than guess
    if RANK.get(tier, 4) > RANK[cap]:
        emit(cap, f"{model} -> {cap} on '{desc or stype or 'agent'}' (models.cap={cap})")
    sys.exit(0)

# No model: a pinned agent definition keeps its pin (per-invocation > frontmatter > session).
name = stype.split(":")[-1].strip()
bases = [os.path.join(proj, ".claude", "agents")]
if plugin:
    bases.append(os.path.join(plugin, "agents"))
if name:
    for base in bases:
        path = os.path.join(base, name + ".md")
        if os.path.isfile(path):
            try:
                head = open(path, encoding="utf-8", errors="replace").read(4000)
            except Exception:
                head = ""
            if re.search(r"^model:\s*\S", head, re.M):
                sys.exit(0)
            break
emit(cap, f"no model on '{desc or stype or 'agent'}' -- it would inherit the session model; set to {cap} (models.cap={cap})")
PY
exit 0
