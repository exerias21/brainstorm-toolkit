#!/usr/bin/env bash
# setup-roundtrip.sh — vendor-agnostic smoke test for setup.sh.
#
# Exercises both copy-scripts and no-copy-scripts modes against scratch
# targets in /tmp, then asserts every skill registered in
# .claude-plugin/marketplace.json's `brainstorm-toolkit` plugin was actually
# installed by setup.sh where it should be, and only where it should be.
#
# Designed to run from any CI vendor (GHA, GitLab, Jenkins, CircleCI, …).
# Non-zero exit on any failure.

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
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
echo "[setup-roundtrip] (1/4) setup.sh --tools both --target $ROOT_TMP/copy"
bash "$PLUGIN_ROOT/setup.sh" --target "$ROOT_TMP/copy" --tools both >/dev/null

# 2. Plugin-resident install: --no-copy-scripts, both tools.
echo "[setup-roundtrip] (2/4) setup.sh --tools both --no-copy-scripts --target $ROOT_TMP/no-copy"
bash "$PLUGIN_ROOT/setup.sh" --target "$ROOT_TMP/no-copy" --tools both --no-copy-scripts >/dev/null

# 3. Marketplace assertion: every entry in the `brainstorm-toolkit` plugin's `skills` list
#    must have produced a `.claude/skills/<name>/SKILL.md` in the copy target.
#
# The plugin is resolved BY NAME below, never by position (`data["plugins"][0]`): a future
# second plugin in the same marketplace.json would otherwise mean positional indexing
# silently checks the wrong plugin the moment ordering changes.
echo "[setup-roundtrip] (3/4) marketplace assertion"

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

skill_names_for_plugin() {
  # skill_names_for_plugin <plugin-name> -- print one basename per line, or nothing if the
  # plugin isn't registered. Windows Python emits CRLF, so every caller pipes this through
  # `tr -d '\r'` -- a bare CR on a line breaks every path but the last, the same bug the
  # original SKILL_NAMES extraction below already guards against.
  "$PY" -c '
import json, sys, pathlib
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
name = sys.argv[2]
for plugin in data["plugins"]:
    if plugin.get("name") == name:
        for p in plugin.get("skills", []):
            print(pathlib.PurePosixPath(p).name)
        break
' "$MARKETPLACE" "$1"
}

SKILL_NAMES="$(skill_names_for_plugin brainstorm-toolkit | tr -d '\r')"

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
#     named in marketplace.json's `brainstorm-toolkit` plugin skills list. Nothing else
#     catches this today -- validate_skills.py only checks *agent* registration, and the
#     forward check above only proves a REGISTERED skill installs, never that a skill
#     DIRECTORY got registered in the first place.
echo "[setup-roundtrip] (3b) reverse marketplace registration assertion (core)"

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

# 5. sync-global.sh round trip (the shell-install route, README Option C). HOME is pointed
#    at a scratch dir -- never the real ~/.claude. Run once per JSON backend: jq when
#    present, then the python fallback (BRAINSTORM_NO_JQ=1 forces it).
echo "[setup-roundtrip] (5) sync-global.sh round trip"

SG="$PLUGIN_ROOT/scripts/sync-global.sh"
SG_VERSION="$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "$PLUGIN_ROOT/.claude-plugin/plugin.json" | head -n 1)"
SG_HOOKS="$(grep -c '"command": "bash' "$PLUGIN_ROOT/hooks/hooks.json")"
SG_SKILLS="$(for d in "$PLUGIN_ROOT"/skills/*/; do basename "$d"; done)"

sg_fail() { echo "[setup-roundtrip] FAIL (sync-global/$SG_MODE): $1" >&2; exit 1; }
sg_count() { grep -c -- "$1" "$2" || true; }
sg_baks() { ls "$H/.claude" | grep -c '^settings\.json\.bak-' || true; }
sg_tree() { (cd "$H" && find . -type f | sort | while read -r f; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done); }

sg_round_trip() {
  SG_MODE="$1"
  H="$ROOT_TMP/sg-$SG_MODE/home"
  RT="$H/.claude/brainstorm-toolkit"
  mkdir -p "$H/.claude/skills/my-user-skill" "$H/.claude/agents"
  printf 'user skill\n' > "$H/.claude/skills/my-user-skill/SKILL.md"
  printf 'user agent\n' > "$H/.claude/agents/my-user-agent.md"
  printf '%s\n' '{"theme":"dark","hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"echo user-hook"}]}]}}' \
    > "$H/.claude/settings.json"
  sg() { HOME="$H" bash "$SG" "$@"; }

  before="$(sg_tree)"
  sg --dry-run >/dev/null
  [[ "$before" == "$(sg_tree)" ]] || sg_fail "--dry-run wrote something"

  sg >/dev/null
  for s in $SG_SKILLS; do [[ -f "$H/.claude/skills/$s/SKILL.md" ]] || sg_fail "skill $s not installed"; done
  [[ -f "$H/.claude/agents/test-runner.md" ]] || sg_fail "agents not installed"
  [[ -f "$RT/scripts/py.sh" && -f "$RT/scripts/close-tasks.sh" && -f "$RT/scripts/hooks/next-action.sh" ]] || sg_fail "runtime scripts missing"
  [[ -f "$RT/templates/TASKS.md.template" && -f "$RT/.claude-plugin/plugin.json" ]] || sg_fail "runtime templates/plugin.json missing"
  [[ ! -e "$RT/scripts/ci" && ! -e "$RT/scripts/sync-global.sh" ]] || sg_fail "repo-only scripts leaked into the runtime dir"
  [[ "$(sg_count "\"version\": \"$SG_VERSION\"" "$RT/INSTALL.json")" == 1 ]] || sg_fail "INSTALL.json version"
  [[ "$(sg_count 'brainstorm-toolkit/scripts/hooks/' "$H/.claude/settings.json")" == "$SG_HOOKS" ]] || sg_fail "hook count != hooks.json"
  [[ "$(sg_count 'bash \\"\(/\|[A-Za-z]:/\)' "$H/.claude/settings.json")" == "$SG_HOOKS" ]] || sg_fail "a hook path is not absolute+quoted"
  [[ "$(sg_count 'CLAUDE_PLUGIN_ROOT' "$H/.claude/settings.json")" == 0 ]] || sg_fail "unexpanded CLAUDE_PLUGIN_ROOT"
  grep -q '"echo user-hook"' "$H/.claude/settings.json" || sg_fail "user hook lost"
  grep -q '"theme": "dark"' "$H/.claude/settings.json" || sg_fail "unrelated setting lost"
  [[ -f "$H/.claude/skills/my-user-skill/SKILL.md" && -f "$H/.claude/agents/my-user-agent.md" ]] || sg_fail "user skill/agent touched"
  [[ "$(sg_baks)" == 1 ]] || sg_fail "expected exactly 1 settings backup after install"

  sg >/dev/null
  [[ "$(sg_count 'brainstorm-toolkit/scripts/hooks/' "$H/.claude/settings.json")" == "$SG_HOOKS" ]] || sg_fail "re-run duplicated hooks"
  [[ "$(sg_baks)" == 1 ]] || sg_fail "no-op re-run wrote a backup"

  # A hook left by an older checkout is replaced, not duplicated -- and gets its own backup.
  "$PY" -c '
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["hooks"]["Stop"].append({"matcher": "*", "hooks": [{"type": "command", "command": "bash /old/repo/scripts/hooks/next-action.sh"}]})
json.dump(d, open(p, "w"))' "$H/.claude/settings.json"
  sg >/dev/null
  grep -q '/old/repo' "$H/.claude/settings.json" && sg_fail "stale hook survived"
  [[ "$(sg_count 'brainstorm-toolkit/scripts/hooks/' "$H/.claude/settings.json")" == "$SG_HOOKS" ]] || sg_fail "stale replace changed hook count"
  [[ "$(sg_baks)" == 2 ]] || sg_fail "expected 2 distinct backups after the stale replace"

  st="$(sg --status)"
  printf '%s\n' "$st" | grep -q "installed: $SG_VERSION" || sg_fail "--status lacks installed version"
  printf '%s\n' "$st" | grep -q MISSING && sg_fail "--status reports a missing hook"
  [[ "$(printf '%s\n' "$st" | grep -c '^    present')" == "$SG_HOOKS" ]] || sg_fail "--status present count"

  sg --uninstall >/dev/null
  for s in $SG_SKILLS; do [[ ! -e "$H/.claude/skills/$s" ]] || sg_fail "skill $s survived uninstall"; done
  [[ ! -e "$H/.claude/agents/test-runner.md" && ! -e "$RT" ]] || sg_fail "agents/runtime survived uninstall"
  grep -q 'brainstorm-toolkit' "$H/.claude/settings.json" && sg_fail "toolkit hooks survived uninstall"
  grep -q '"echo user-hook"' "$H/.claude/settings.json" || sg_fail "uninstall removed the user hook"
  [[ -f "$H/.claude/skills/my-user-skill/SKILL.md" && -f "$H/.claude/agents/my-user-agent.md" ]] || sg_fail "uninstall removed user skill/agent"
  [[ "$(sg_baks)" == 3 ]] || sg_fail "expected 3 backups after uninstall"
  echo "[setup-roundtrip] OK: sync-global round trip ($SG_MODE)"
}

if command -v jq >/dev/null 2>&1; then sg_round_trip jq; else echo "[setup-roundtrip] note: jq not on PATH -- jq backend not exercised"; fi
BRAINSTORM_NO_JQ=1 sg_round_trip python
