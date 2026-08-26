#!/usr/bin/env bash
# scripts/sync-global.sh — install brainstorm-toolkit GLOBALLY into ~/.claude,
# with no marketplace, no plugin registration, and no --plugin-dir sideload.
#
# For machines where the plugin route isn't available (org policy sets
# `disableSideloadFlags`, marketplace install is blocked, etc.). Skills and agents
# become plain user-scope files that Claude Code discovers natively:
#
#     ~/.claude/skills/<name>/     <- from  skills/<name>/     (canonical, Claude flavor)
#     ~/.claude/agents/<name>.md   <- from  agents/<name>.md
#     ~/.claude/settings.json      <- Stop + SessionStart hooks, ABSOLUTE paths
#
# Usage:
#   bash scripts/sync-global.sh [--dry-run] [--skills a,b,c] [--no-hooks]
#                               [--prune-relative-hooks] [--uninstall] [--repo <dir>]
#
#   --dry-run                Print every action and the settings.json diff; write nothing.
#                            RUN THIS FIRST.
#   --skills a,b,c           Sync only these skills (default: all of skills/*).
#                            All 14 are user-scope-resident in EVERY repo once synced —
#                            see "Token weight" below before taking the default.
#   --no-hooks               Skip the ~/.claude/settings.json hook wiring entirely.
#   --prune-relative-hooks   Also remove pre-existing Stop hooks that invoke
#                            next-action.sh by a RELATIVE path (the classic breakage:
#                            a repo-scoped hook copied into global settings, where it
#                            only fires in repos that happen to have scripts/hooks/).
#   --uninstall              Remove everything this script installed, then exit.
#   --repo <dir>             Toolkit repo root (default: this script's parent dir).
#
# WHY NOT SYMLINKS: symlinked skills and agents have known discovery bugs in Claude
# Code (missing from /skills autocomplete, "Unknown skill" at invoke, subagents not
# found), and a symlink would make a `git checkout` in the repo silently swap your live
# skills mid-session. This copies. Re-run it to pick up repo changes — that explicit
# step is the feature.
#
# WHY ABSOLUTE PATHS IN HOOKS: ${CLAUDE_PLUGIN_ROOT} only expands inside the plugin
# runtime. In a global settings.json there is no plugin runtime, so the variable stays
# a literal and the hook silently no-ops. This writes real paths.
#
# SAFETY: --delete is scoped PER SKILL DIRECTORY, never to ~/.claude/skills/ as a whole,
# so unrelated user skills installed by other tools are never pruned. Every write to
# settings.json is preceded by a timestamped .bak.
set -euo pipefail

DRY_RUN=0
WANT_HOOKS=1
PRUNE_RELATIVE=0
UNINSTALL=0
SKILL_FILTER=""
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)              DRY_RUN=1; shift ;;
    --skills)               SKILL_FILTER="$2"; shift 2 ;;
    --no-hooks)             WANT_HOOKS=0; shift ;;
    --prune-relative-hooks) PRUNE_RELATIVE=1; shift ;;
    --uninstall)            UNINSTALL=1; shift ;;
    --repo)                 REPO="$2"; shift 2 ;;
    -h|--help)              sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

CLAUDE_DIR="$HOME/.claude"
SKILLS_DST="$CLAUDE_DIR/skills"
AGENTS_DST="$CLAUDE_DIR/agents"
SETTINGS="$CLAUDE_DIR/settings.json"
MANIFEST="$CLAUDE_DIR/.brainstorm-toolkit-global.json"

REPO="$(cd "$REPO" && pwd)"
HOOK_STOP="bash $REPO/scripts/hooks/next-action.sh"
HOOK_RESEED="bash $REPO/scripts/hooks/reseed-context.sh"

say()  { printf '%s\n' "$*"; }
run()  { if [[ "$DRY_RUN" -eq 1 ]]; then say "  [dry-run] $*"; else eval "$@"; fi; }

[[ -d "$REPO/skills" ]] || { echo "error: $REPO does not look like the toolkit repo (no skills/)" >&2; exit 1; }
command -v rsync >/dev/null || { echo "error: rsync not found" >&2; exit 1; }

# ---------------------------------------------------------------- uninstall
if [[ "$UNINSTALL" -eq 1 ]]; then
  say "brainstorm-toolkit — global UNINSTALL"
  say "  removing skills/agents recorded in $MANIFEST"
  if [[ -f "$MANIFEST" ]] && command -v jq >/dev/null; then
    while read -r s; do [[ -n "$s" ]] && run "rm -rf ${SKILLS_DST:?}/$s"; done \
      < <(jq -r '.skills[]?' "$MANIFEST")
    while read -r a; do [[ -n "$a" ]] && run "rm -f ${AGENTS_DST:?}/$a.md"; done \
      < <(jq -r '.agents[]?' "$MANIFEST")
  else
    say "  no manifest (or no jq) — falling back to the repo's current skill/agent names"
    for d in "$REPO"/skills/*/; do run "rm -rf ${SKILLS_DST:?}/$(basename "$d")"; done
    for f in "$REPO"/agents/*.md; do run "rm -f ${AGENTS_DST:?}/$(basename "$f")"; done
  fi
  if [[ -f "$SETTINGS" ]] && command -v jq >/dev/null; then
    run "cp '$SETTINGS' '$SETTINGS.bak-\$(date +%Y%m%d%H%M%S)'"
    run "jq --arg s '$HOOK_STOP' --arg r '$HOOK_RESEED' '
          (.hooks.Stop        |= (map(.hooks |= map(select(.command != \$s))) | map(select((.hooks|length) > 0)))) |
          (.hooks.SessionStart |= (map(.hooks |= map(select(.command != \$r))) | map(select((.hooks|length) > 0))))
        ' '$SETTINGS' > '$SETTINGS.tmp' && mv '$SETTINGS.tmp' '$SETTINGS'"
    say "  removed toolkit hooks from $SETTINGS"
  fi
  run "rm -f '$MANIFEST'"
  say "done. Restart Claude Code."
  exit 0
fi

# ---------------------------------------------------------------- plan
say "brainstorm-toolkit — global sync (no marketplace, no sideload)"
say "  repo:     $REPO"
say "  skills -> $SKILLS_DST"
say "  agents -> $AGENTS_DST"
[[ "$DRY_RUN" -eq 1 ]] && say "  MODE:     dry-run (nothing will be written)"
say

# Warn if the marketplace route is ALSO active — double registration means every skill
# is discovered twice and the Stop hook fires twice (next-action.sh consumes the
# sentinel on first read, so the second pass sees an empty seam).
if [[ -f "$SETTINGS" ]] && command -v jq >/dev/null; then
  if jq -e '.enabledPlugins // {} | to_entries | any(.key | startswith("brainstorm-toolkit@"))' \
       "$SETTINGS" >/dev/null 2>&1; then
    say "WARNING: the brainstorm-toolkit PLUGIN is still enabled in $SETTINGS."
    say "         Running both routes double-registers every skill and fires the Stop"
    say "         hook twice. Disable the plugin (/plugin) before using the global install."
    say
  fi
fi

# Resolve the skill set.
declare -a SKILLS=()
if [[ -n "$SKILL_FILTER" ]]; then
  IFS=',' read -ra SKILLS <<< "$SKILL_FILTER"
  for s in "${SKILLS[@]}"; do
    [[ -d "$REPO/skills/$s" ]] || { echo "error: no such skill: $s" >&2; exit 1; }
  done
else
  for d in "$REPO"/skills/*/; do SKILLS+=("$(basename "$d")"); done
fi

say "syncing ${#SKILLS[@]} skill(s):"
run "mkdir -p '$SKILLS_DST'"
for s in "${SKILLS[@]}"; do
  # --delete is scoped INSIDE this one skill dir: it prunes files removed from the
  # repo's copy of THIS skill, and can never reach a sibling skill it doesn't own.
  run "rsync -a --delete '$REPO/skills/$s/' '$SKILLS_DST/$s/'"
  say "  $s"
done
say

say "syncing agents:"
run "mkdir -p '$AGENTS_DST'"
for f in "$REPO"/agents/*.md; do
  run "rsync -a '$f' '$AGENTS_DST/'"
  say "  $(basename "$f")"
done
say

# ---------------------------------------------------------------- hooks
if [[ "$WANT_HOOKS" -eq 1 ]]; then
  if ! command -v jq >/dev/null; then
    say "skip hooks: jq not installed. Install jq and re-run, or merge this by hand into"
    say "$SETTINGS:"
    cat <<JSON
  "hooks": {
    "Stop": [ { "matcher": "*", "hooks": [
        { "type": "command", "command": "$HOOK_STOP", "timeout": 10 } ] } ],
    "SessionStart": [ { "matcher": "compact|clear", "hooks": [
        { "type": "command", "command": "$HOOK_RESEED", "timeout": 10 } ] } ]
  }
JSON
  else
    # Read the current settings as text, defaulting to {} when the file is absent or
    # empty. Feeding jq an empty file yields NO output, which silently collapsed the
    # whole update to "no change" on a machine with no settings.json yet.
    BASE="$(cat "$SETTINGS" 2>/dev/null || true)"
    [[ -z "${BASE//[[:space:]]/}" ]] && BASE='{}'
    if ! printf '%s' "$BASE" | jq -e . >/dev/null 2>&1; then
      echo "error: $SETTINGS is not valid JSON — fix or move it, then re-run" >&2
      exit 1
    fi

    NEW="$(printf '%s' "$BASE" | jq --arg s "$HOOK_STOP" --arg r "$HOOK_RESEED" --argjson prune "$PRUNE_RELATIVE" '
      .hooks //= {} | .hooks.Stop //= [] | .hooks.SessionStart //= []
      # Optional: drop pre-existing next-action.sh hooks wired by a RELATIVE path.
      | if $prune == 1 then
          .hooks.Stop |= (map(.hooks |= map(select(
              (.command | test("next-action\\.sh")) and (.command | test("(^|[ \"])/") | not) | not
            ))) | map(select((.hooks|length) > 0)))
        else . end
      # Idempotent: only append when this exact absolute command is absent.
      | if (any(.hooks.Stop[]?.hooks[]?; .command == $s) | not) then
          .hooks.Stop += [{ "matcher": "*", "hooks": [
            { "type": "command", "command": $s, "timeout": 10 } ] }]
        else . end
      | if (any(.hooks.SessionStart[]?.hooks[]?; .command == $r) | not) then
          .hooks.SessionStart += [{ "matcher": "compact|clear", "hooks": [
            { "type": "command", "command": $r, "timeout": 10 } ] }]
        else . end
    ')" || { echo "error: failed to build settings update" >&2; exit 1; }

    say "settings.json diff ($SETTINGS):"
    if diff -u <(printf '%s' "$BASE" | jq -S .) <(printf '%s' "$NEW" | jq -S .) \
         | sed '1,2d;s/^/  /'; then
      say "  (no change — hooks already wired)"
      CHANGED=0
    else
      CHANGED=1
    fi
    say

    if [[ "$DRY_RUN" -eq 0 ]]; then
      # Only touch the file when something actually changed — otherwise a routine
      # re-sync would litter a .bak per run.
      if [[ "$CHANGED" -eq 0 ]]; then
        say "  unchanged — $SETTINGS left as-is"
      else
        mkdir -p "$CLAUDE_DIR"
        [[ -f "$SETTINGS" ]] && cp "$SETTINGS" "$SETTINGS.bak-$(date +%Y%m%d%H%M%S)"
        printf '%s\n' "$NEW" > "$SETTINGS"
        say "  wrote $SETTINGS"
      fi
    fi
  fi
  say
fi

# ---------------------------------------------------------------- manifest
if [[ "$DRY_RUN" -eq 0 ]] && command -v jq >/dev/null; then
  # UNION with any prior manifest, never replace it. A `--skills a,b` run after a full
  # sync must not shrink the record to two names — the other 22 are still on disk, and
  # --uninstall reads this file to know what it owns.
  PRIOR="$(cat "$MANIFEST" 2>/dev/null || echo '{}')"
  printf '%s' "$PRIOR" | jq --arg repo "$REPO" \
        --argjson skills "$(printf '%s\n' "${SKILLS[@]}" | jq -R . | jq -s .)" \
        --argjson agents "$(for f in "$REPO"/agents/*.md; do basename "$f" .md; done \
                            | jq -R . | jq -s .)" \
        '{repo: $repo,
          skills: ((.skills // []) + $skills | unique),
          agents: ((.agents // []) + $agents | unique)}' > "$MANIFEST.tmp" \
    && mv "$MANIFEST.tmp" "$MANIFEST"
fi

say "done — restart Claude Code (the skill + agent registries load at session start)."
say "Verify:  /skills   should list the toolkit commands"
say "         claude --debug   then end a turn; the Stop hook path should be absolute"
say
say "Re-run this script after every 'git pull' in $REPO — it copies, it does not link."
