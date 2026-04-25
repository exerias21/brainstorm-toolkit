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

# Extract skill paths via python3 (always present in CI runners and the local
# dev env). Avoids a jq dependency.
SKILL_NAMES="$(python3 -c '
import json, sys, pathlib
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
for p in data["plugins"][0]["skills"]:
    print(pathlib.PurePosixPath(p).name)
' "$MARKETPLACE")"

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
