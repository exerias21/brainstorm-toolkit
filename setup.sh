#!/usr/bin/env bash
# setup.sh â€” install brainstorm-toolkit into a target repo for Claude Code and/or GitHub Copilot.
#
# Usage:
#   bash setup.sh [--target <dir>] [--tools claude|copilot|both] [--force]
#                 [--no-copy-scripts] [--no-hooks]
#
#   --target <dir>      Target repo root (default: current directory)
#   --tools <which>     claude | copilot | both (default: both)
#   --force             Overwrite plugin assets (skills, agents, scripts).
#                       Does NOT overwrite user-customized files
#                       (AGENTS.md, CLAUDE.md, TASKS.md, .claude/project.json) —
#                       those are skip-on-exist regardless of this flag, since
#                       --force is meant to refresh plugin content, not blow
#                       away consumer edits. Default: skip-if-exists for everything.
#   --no-copy-scripts   Don't copy plugin scripts/ into target. Use this when
#                       you'd rather invoke project-agnostic helpers
#                       (eval-runner.py, check_docker_logs.py) from the plugin
#                       install directly — point .claude/project.json at the
#                       absolute plugin path instead.
#   --no-hooks          Skip Stop-hook installation (neither .claude/settings.json
#                       nor .github/hooks/next-action.json will be written).
#
# Design: the plugin repo is the source of truth. Re-run this script to refresh
# a consumer repo. Managed files such as CLAUDE.md and AGENTS.md are written as
# copies into the target repo; this script does not create symlinks.

set -euo pipefail

TARGET="$(pwd)"
TOOLS="both"
FORCE=0
COPY_SCRIPTS=1
INSTALL_HOOKS=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)            TARGET="$2"; shift 2 ;;
    --tools)             TOOLS="$2"; shift 2 ;;
    --force)             FORCE=1; shift ;;
    --no-copy-scripts)   COPY_SCRIPTS=0; shift ;;
    --no-hooks)          INSTALL_HOOKS=0; shift ;;
    -h|--help)
      sed -n '2,23p' "$0" | sed 's/^# *//'
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

case "$TOOLS" in
  claude|copilot|both) ;;
  *) echo "--tools must be claude, copilot, or both" >&2; exit 2 ;;
esac

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$(cd "$TARGET" && pwd)"

if [[ "$PLUGIN_ROOT" == "$TARGET" ]]; then
  echo "refusing to install into the plugin repo itself" >&2
  exit 2
fi

echo "brainstorm-toolkit setup"
echo "  plugin root: $PLUGIN_ROOT"
echo "  target:      $TARGET"
echo "  tools:       $TOOLS"
echo "  force:       $FORCE"
echo

want_claude=0; want_copilot=0
[[ "$TOOLS" == "claude"  || "$TOOLS" == "both" ]] && want_claude=1
[[ "$TOOLS" == "copilot" || "$TOOLS" == "both" ]] && want_copilot=1

copy_if_new() {
  # copy <src> <dest>
  local src="$1" dest="$2"
  if [[ -e "$dest" && "$FORCE" -ne 1 ]]; then
    echo "  skip (exists): $dest"
  else
    mkdir -p "$(dirname "$dest")"
    cp -f "$src" "$dest"
    echo "  wrote: $dest"
  fi
}

copy_tree_if_new() {
  # copy <src_dir> <dest_dir> recursively, skipping existing unless --force.
  # Excludes Python compile artifacts (__pycache__, *.pyc) — those are runtime
  # cruft, not plugin assets, even if they happen to exist in the source tree.
  local src="$1" dest="$2"
  mkdir -p "$dest"
  (cd "$src" && find . -type f \
      ! -path '*/__pycache__/*' \
      ! -name '*.pyc' \
      ! -name '*.pyo' \
      -printf '%P\n') | while read -r rel; do
    local from="$src/$rel" to="$dest/$rel"
    copy_if_new "$from" "$to"
  done
}

delete_if_exists() {
  # delete <path> if present
  local path="$1"
  if [[ -e "$path" ]]; then
    rm -rf "$path"
    echo "  removed legacy: $path"
  fi
}

applies_to_includes() {
  # applies_to_includes <skill_dir> <tool>
  local skill_file="$1/SKILL.md" tool="$2"
  [[ -f "$skill_file" ]] || return 1
  # Read frontmatter only (between first two '---' lines). Default: claude-only if no key.
  # The leading sub() strips trailing \r so CRLF-ended SKILL.md files parse correctly —
  # .gitattributes pins these to LF, but a dirty working copy should still install.
  local frontmatter
  frontmatter="$(awk '{sub(/\r$/,"")} /^---$/{c++; if(c==2) exit; next} c==1' "$skill_file")"
  local line
  line="$(echo "$frontmatter" | grep -E '^[[:space:]]*brainstorm-toolkit-applies-to:' | head -n 1 || true)"
  if [[ -z "$line" ]]; then
    line="$(echo "$frontmatter" | grep -E '^applies-to:' | head -n 1 || true)"
  fi
  if [[ -z "$line" ]]; then
    # No applies-to â†’ default to claude-only (conservative)
    [[ "$tool" == "claude" ]]
    return
  fi
  echo "$line" | grep -q "$tool"
}

# 1. Skills
echo "[1/6] Skills"
for skill_dir in "$PLUGIN_ROOT"/skills/*/; do
  [[ -d "$skill_dir" ]] || continue
  name="$(basename "$skill_dir")"

  if [[ "$want_claude" -eq 1 ]] && applies_to_includes "$skill_dir" claude; then
    copy_tree_if_new "$skill_dir" "$TARGET/.claude/skills/$name"
  fi

  if [[ "$want_copilot" -eq 1 ]]; then
    delete_if_exists "$TARGET/.github/prompts/$name.prompt.md"
  fi

  if [[ "$want_copilot" -eq 1 ]] && applies_to_includes "$skill_dir" copilot; then
    # Overlay pattern: prefer copilot/skills/<name>/ if it exists (Copilot-optimized version)
    copilot_override="$PLUGIN_ROOT/copilot/skills/$name"
    if [[ -d "$copilot_override" ]]; then
      copy_tree_if_new "$copilot_override" "$TARGET/.github/skills/$name"
    else
      copy_tree_if_new "$skill_dir" "$TARGET/.github/skills/$name"
    fi
  fi
done

# 2. Agents (Claude-only)
if [[ "$want_claude" -eq 1 && -d "$PLUGIN_ROOT/agents" ]]; then
  echo "[2/6] Agents (Claude-only)"
  copy_tree_if_new "$PLUGIN_ROOT/agents" "$TARGET/.claude/agents"
fi

# 3. Scripts (repo-local) — opt-out via --no-copy-scripts to use plugin-resident invocation
if [[ -d "$PLUGIN_ROOT/scripts" && "$COPY_SCRIPTS" -eq 1 ]]; then
  echo "[3/6] Scripts"
  copy_tree_if_new "$PLUGIN_ROOT/scripts" "$TARGET/scripts"
elif [[ "$COPY_SCRIPTS" -eq 0 ]]; then
  echo "[3/6] Scripts (skipped: --no-copy-scripts)"
  echo "  Configure .claude/project.json to invoke from the plugin, e.g.:"
  echo "    \"eval\": { \"runner\": \"python3 $PLUGIN_ROOT/scripts/eval-runner.py\" }"
fi

# Install the reference .example file if missing; refresh it when --force is
# used. Consumers can review it to discover newly-added optional fields like
# eval.thresholds and pipeline.poka_yoke. The user's actual
# .claude/project.json is never touched.
echo "[4/6] Project config example (skip-on-exist unless --force)"
copy_if_new "$PLUGIN_ROOT/templates/project.json.example" "$TARGET/.claude/project.json.example"
if [[ -f "$TARGET/.claude/project.json" ]]; then
  echo "  note: .claude/project.json present — review .claude/project.json.example for new optional fields"
else
  echo "  note: .claude/project.json not present — copy from .claude/project.json.example to start"
fi

# 5. AGENTS.md + CLAUDE.md
# These are user-customized assets, not plugin assets. They are skip-on-exist
# regardless of --force, because --force is meant to refresh plugin content
# (skills, agents, scripts) — not blow away the consumer's edited docs.
# We deliberately do NOT create a symlink between them: WSL/NTFS and Windows
# git both struggle with symlinks (git fails to index, edits in IDEs follow
# the link and silently drift). Two regular files is the lowest-friction
# cross-platform choice. Consumers keep them in sync — content is small.
echo "[5/6] AGENTS.md / CLAUDE.md"
if [[ -e "$TARGET/AGENTS.md" || -e "$TARGET/CLAUDE.md" ]]; then
  echo "  skip: AGENTS.md and/or CLAUDE.md already present (user content; not overwritten)"
else
  copy_if_new "$PLUGIN_ROOT/templates/AGENTS.md.template" "$TARGET/AGENTS.md"
  cp -f "$TARGET/AGENTS.md" "$TARGET/CLAUDE.md"
  echo "  wrote: $TARGET/CLAUDE.md (copy of AGENTS.md — keep them in sync)"
fi

# 6. TASKS.md
# Also user content; skip-on-exist regardless of --force.
echo "[6/6] TASKS.md"
if [[ -f "$TARGET/TASKS.md" ]]; then
  echo "  skip: TASKS.md already present (user content; not overwritten)"
else
  copy_if_new "$PLUGIN_ROOT/templates/TASKS.md.template" "$TARGET/TASKS.md"
fi

# Ensure a path is gitignored. Idempotent (grep-before-append) and CRLF-safe
# (strips trailing \r when checking existing entries). Creates .gitignore if
# missing. Treats a broader .claude/ pattern as already-covered for any
# .claude/* entry — never adds a redundant line.
ensure_gitignored() {
  local entry="$1"
  local gi="$TARGET/.gitignore"
  if [[ ! -f "$gi" ]]; then
    printf '# brainstorm-toolkit\n%s\n' "$entry" > "$gi"
    echo "  wrote: $gi (created with $entry)"
    return
  fi
  # awk strips trailing \r so CRLF files match the same way LF files do.
  # The exact-match regex is built from $entry; .claude/-broader pattern is
  # only an override for .claude/* entries (avoids matching a literal
  # ".claude/" entry as covering ".vscode/").
  # Escape regex specials, but use [.] for literal dots (avoids awk
  # "escape sequence treated as plain" warnings) and leave / unescaped
  # (awk regexes don't use / as a delimiter inside string-built patterns).
  local entry_re
  # Strip a trailing slash before building the regex, then append [/]? so
  # both "foo/bar" and "foo/bar/" in .gitignore are treated as equivalent.
  entry_re="$(printf '%s' "$entry" | sed -e 's/[][\\^$*+?(){}|]/\\&/g' -e 's/\./[.]/g' -e 's|/$||')"
  local check_broader=0
  if [[ "$entry" == .claude/* ]]; then
    check_broader=1
  fi
  if awk -v r="^${entry_re}[/]?$" -v b="$check_broader" \
       '{sub(/\r$/,"")} $0 ~ r || (b == "1" && $0 ~ /^[.]claude[/]?$/) {found=1} END {exit !found}' "$gi"; then
    echo "  skip: .gitignore already covers $entry"
  else
    if [[ -n "$(tail -c1 "$gi" 2>/dev/null)" ]]; then
      printf '\n' >> "$gi"
    fi
    printf '%s\n' "$entry" >> "$gi"
    echo "  appended to .gitignore: $entry"
  fi
}

# Install the Stop hook into the consumer's Claude Code settings file so the
# next-action sentinel is surfaced after Claude finishes a turn. Idempotent:
# checks for the exact command string before appending.
install_stop_hook_claude() {
  local settings="$TARGET/.claude/settings.json"
  local cmd
  if [[ "$COPY_SCRIPTS" -eq 1 ]]; then
    cmd="bash scripts/hooks/next-action.sh"
  else
    local hook_path_escaped
    printf -v hook_path_escaped '%q' "$PLUGIN_ROOT/scripts/hooks/next-action.sh"
    cmd="bash $hook_path_escaped"
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "  skip: jq not installed — cannot safely merge Claude hook config."
    echo "        Install jq and re-run, or add this manually to $settings:"
    echo "        {\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"$cmd\"}]}]}}"
    return
  fi
  mkdir -p "$(dirname "$settings")"
  if [[ ! -f "$settings" ]]; then
    echo '{}' > "$settings"
  fi
  if jq -e --arg cmd "$cmd" '
        any(.hooks.Stop[]?.hooks[]?; .command == $cmd)
      ' "$settings" >/dev/null 2>&1; then
    echo "  skip: Claude Stop hook already wired ($cmd)"
    return
  fi
  local tmp; tmp="$(mktemp)"
  if jq --arg cmd "$cmd" '
    .hooks //= {} |
    .hooks.Stop //= [] |
    .hooks.Stop += [{ "hooks": [{ "type": "command", "command": $cmd }] }]
  ' "$settings" > "$tmp" && mv "$tmp" "$settings"; then
    echo "  wrote: $settings (added Stop hook for next-action)"
  else
    rm -f "$tmp"
    echo "  error: failed to update $settings with Claude Stop hook" >&2
    return 1
  fi
}

# Install the Copilot Stop hook as a standalone file under .github/hooks/.
# Copilot reads any *.json under .github/hooks/, so a fresh file is the
# simplest install — no merging required. Skip-on-exist (refresh with --force).
install_stop_hook_copilot() {
  local hook_file="$TARGET/.github/hooks/next-action.json"
  local cmd
  if [[ "$COPY_SCRIPTS" -eq 1 ]]; then
    cmd="bash scripts/hooks/next-action.sh"
  else
    local hook_path_escaped
    printf -v hook_path_escaped '%q' "$PLUGIN_ROOT/scripts/hooks/next-action.sh"
    cmd="bash $hook_path_escaped"
  fi
  if [[ -f "$hook_file" && "$FORCE" -ne 1 ]]; then
    echo "  skip (exists): $hook_file"
    return
  fi
  mkdir -p "$(dirname "$hook_file")"
  cat > "$hook_file" <<JSON
{
  "hooks": {
    "Stop": [
      { "hooks": [{ "type": "command", "command": "$cmd" }] }
    ]
  }
}
JSON
  echo "  wrote: $hook_file"
}

echo "[gitignore]"
ensure_gitignored ".claude/pipeline/"
ensure_gitignored ".claude/.next-action"

if [[ "$INSTALL_HOOKS" -eq 1 ]]; then
  if [[ "$want_claude" -eq 1 ]]; then
    echo "[hooks] Claude Stop hook"
    install_stop_hook_claude
  fi
  if [[ "$want_copilot" -eq 1 ]]; then
    echo "[hooks] Copilot Stop hook"
    install_stop_hook_copilot
  fi
else
  echo "[hooks] skipped (--no-hooks)"
fi

echo
echo "Done."
echo
echo "Next steps:"
echo "  1. Review AGENTS.md and fill in the {{PLACEHOLDER}} sections (or run /repo-onboarding)."
echo "  2. Customize .claude/project.json (copy from .claude/project.json.example)."
echo "  3. Add project-specific gotchas to GOTCHAS.md as they come up."
echo "  4. In Claude Code: skills are available under /<skill-name>."
echo "  5. In GitHub Copilot: skills are available under /<skill-name> in .github/skills/."
if [[ "$INSTALL_HOOKS" -eq 1 ]]; then
  echo "  6. Stop hooks were installed but may need one-time activation:"
  echo "       Claude Code: open /hooks once to register .claude/settings.json"
  echo "       Copilot:     reload the VS Code window"
fi
