#!/usr/bin/env bash
# setup-roundtrip.sh — vendor-agnostic smoke test for setup.sh.
#
# Exercises both copy-scripts and no-copy-scripts modes against scratch
# targets in /tmp, then asserts every skill registered in
# .claude-plugin/marketplace.json was actually installed by setup.sh.
#
# Designed to run from any CI vendor (GHA, GitLab, Jenkins, CircleCI, …).
# Non-zero exit on any failure.

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT_TMP="/tmp/sdlc-roundtrip-$$"

cleanup() {
  rm -rf "$ROOT_TMP" || true
}
trap cleanup EXIT

# Idempotent: nuke any leftover scratch from a prior run with the same PID
# (vanishingly rare, but cheap insurance).
rm -rf "$ROOT_TMP"
mkdir -p "$ROOT_TMP/copy" "$ROOT_TMP/no-copy"

echo "[setup-roundtrip] plugin root: $PLUGIN_ROOT"
echo "[setup-roundtrip] scratch:     $ROOT_TMP"
echo

# 1. Standard install: copy scripts/, both tools.
echo "[setup-roundtrip] (1/3) setup.sh --tools both --target $ROOT_TMP/copy"
bash "$PLUGIN_ROOT/setup.sh" --target "$ROOT_TMP/copy" --tools both >/dev/null

# 2. Plugin-resident install: --no-copy-scripts, both tools.
echo "[setup-roundtrip] (2/3) setup.sh --tools both --no-copy-scripts --target $ROOT_TMP/no-copy"
bash "$PLUGIN_ROOT/setup.sh" --target "$ROOT_TMP/no-copy" --tools both --no-copy-scripts >/dev/null

# 3. Marketplace assertion: every entry in marketplace.json `plugins[0].skills`
#    must have produced a `.claude/skills/<name>/SKILL.md` in the copy target.
echo "[setup-roundtrip] (3/3) marketplace assertion"

MARKETPLACE="$PLUGIN_ROOT/.claude-plugin/marketplace.json"
if [[ ! -f "$MARKETPLACE" ]]; then
  echo "[setup-roundtrip] FAIL: marketplace.json not found at $MARKETPLACE" >&2
  exit 1
fi

# Extract skill paths with Python -- avoids a jq dependency. Resolve the interpreter
# through scripts/py.sh rather than naming `python3`: on Windows that name is often the
# Store stub, which resolves but exits nonzero, and this step then failed locally while
# passing on Linux CI.
PY="$(bash "$PLUGIN_ROOT/scripts/py.sh" --print)" || { echo "[setup-roundtrip] FAIL: no working Python" >&2; exit 1; }
SKILL_NAMES="$("$PY" -c '
import json, sys, pathlib
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
for p in data["plugins"][0]["skills"]:
    print(pathlib.PurePosixPath(p).name)
' "$MARKETPLACE" | tr -d '\r')"  # Windows Python emits CRLF; a trailing CR broke every path but the last

missing=0
for name in $SKILL_NAMES; do
  installed="$ROOT_TMP/copy/.claude/skills/$name/SKILL.md"
  if [[ ! -f "$installed" ]]; then
    echo "[setup-roundtrip] FAIL: marketplace skill '$name' not installed at $installed" >&2
    missing=$((missing + 1))
  fi
done

if [[ "$missing" -gt 0 ]]; then
  echo "[setup-roundtrip] FAIL: $missing marketplace skill(s) missing from install" >&2
  exit 1
fi

echo "[setup-roundtrip] OK: all $(echo "$SKILL_NAMES" | wc -w | tr -d ' ') marketplace skills installed."

# 3b. Reverse marketplace assertion: every skills/*/SKILL.md directory must be
#     named in marketplace.json's plugins[0].skills list. Nothing else catches
#     this today -- validate_skills.py only checks *agent* registration, and
#     the forward check above only proves a REGISTERED skill installs, never
#     that a skill DIRECTORY got registered in the first place.
echo "[setup-roundtrip] (3b) reverse marketplace registration assertion"

unregistered=0
for skill_dir in "$PLUGIN_ROOT"/skills/*/; do
  [[ -f "${skill_dir}SKILL.md" ]] || continue
  dir_name="$(basename "$skill_dir")"
  if ! printf '%s\n' "$SKILL_NAMES" | grep -qx "$dir_name"; then
    echo "[setup-roundtrip] FAIL: skills/$dir_name/SKILL.md exists but is not registered in $MARKETPLACE" >&2
    unregistered=$((unregistered + 1))
  fi
done

if [[ "$unregistered" -gt 0 ]]; then
  echo "[setup-roundtrip] FAIL: $unregistered skill dir(s) exist under skills/ but are not registered in marketplace.json" >&2
  exit 1
fi
echo "[setup-roundtrip] OK: every skills/*/SKILL.md is registered in marketplace.json."

# 4. Stop-gate hook timeout assertion: stop-gate.sh runs the project's test.unit
#    suite inline (up to 300s by its own internal default) before deciding whether
#    to block. A Stop hook entry with no timeout, or a too-short one, falls back to
#    (or hits) the host's shorter default and the gate fails OPEN on a slow suite --
#    the exact bug this asserts against regressing. Checked in the copy-scripts
#    Claude settings.json produced by step (1) above.
echo "[setup-roundtrip] (4/4) stop-gate hook timeout assertion"
STOP_GATE_SETTINGS="$ROOT_TMP/copy/.claude/settings.json"
if [[ ! -f "$STOP_GATE_SETTINGS" ]]; then
  echo "[setup-roundtrip] FAIL: $STOP_GATE_SETTINGS not found" >&2
  exit 1
fi
STOP_GATE_TIMEOUT="$("$PY" -c '
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
for entry in data.get("hooks", {}).get("Stop", []):
    for h in entry.get("hooks", []) or []:
        if "stop-gate.sh" in (h.get("command") or ""):
            print(h.get("timeout", ""))
' "$STOP_GATE_SETTINGS" | tr -d '\r')"
if [[ -z "$STOP_GATE_TIMEOUT" ]]; then
  echo "[setup-roundtrip] FAIL: stop-gate Stop hook has no timeout set in $STOP_GATE_SETTINGS (fails open on a slow test suite)" >&2
  exit 1
fi
if [[ "$STOP_GATE_TIMEOUT" -lt 300 ]]; then
  echo "[setup-roundtrip] FAIL: stop-gate Stop hook timeout is ${STOP_GATE_TIMEOUT}s, want >= 300s" >&2
  exit 1
fi
echo "[setup-roundtrip] OK: stop-gate Stop hook timeout is ${STOP_GATE_TIMEOUT}s (>= 300s)"
