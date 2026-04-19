#!/usr/bin/env bash
# setup.sh — install brainstorm-toolkit into a target repo for Claude Code and/or GitHub Copilot.
#
# Usage:
#   bash setup.sh [--target <dir>] [--tools claude|copilot|both] [--force]
#
#   --target <dir>   Target repo root (default: current directory)
#   --tools <which>  claude | copilot | both (default: both)
#   --force          Overwrite existing files (default: skip-if-exists)
#
# Design: the plugin repo is the source of truth. Re-run this script to refresh
# a consumer repo. On POSIX we try a symlink CLAUDE.md → AGENTS.md; otherwise copy.

set -euo pipefail

TARGET="$(pwd)"
TOOLS="both"
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --tools)  TOOLS="$2"; shift 2 ;;
    --force)  FORCE=1; shift ;;
    -h|--help)
      sed -n '2,10p' "$0" | sed 's/^# *//'
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
  # copy <src_dir> <dest_dir> recursively, skipping existing unless --force
  local src="$1" dest="$2"
  mkdir -p "$dest"
  (cd "$src" && find . -type f -printf '%P\n') | while read -r rel; do
    local from="$src/$rel" to="$dest/$rel"
    copy_if_new "$from" "$to"
  done
}

applies_to_includes() {
  # applies_to_includes <skill_dir> <tool>
  local skill_file="$1/SKILL.md" tool="$2"
  [[ -f "$skill_file" ]] || return 1
  # Read frontmatter only (between first two '---' lines). Default: claude+copilot if no key.
  local frontmatter
  frontmatter="$(awk '/^---$/{c++; if(c==2) exit; next} c==1' "$skill_file")"
  local line
  line="$(echo "$frontmatter" | grep -E '^applies-to:' || true)"
  if [[ -z "$line" ]]; then
    # No applies-to → default to claude-only (conservative)
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

  if [[ "$want_copilot" -eq 1 ]] && applies_to_includes "$skill_dir" copilot; then
    copy_if_new "$skill_dir/SKILL.md" "$TARGET/.github/prompts/$name.prompt.md"
  fi
done

# 2. Agents (Claude-only)
if [[ "$want_claude" -eq 1 && -d "$PLUGIN_ROOT/agents" ]]; then
  echo "[2/6] Agents (Claude-only)"
  copy_tree_if_new "$PLUGIN_ROOT/agents" "$TARGET/.claude/agents"
fi

# 3. Scripts (repo-local)
if [[ -d "$PLUGIN_ROOT/scripts" ]]; then
  echo "[3/6] Scripts"
  copy_tree_if_new "$PLUGIN_ROOT/scripts" "$TARGET/scripts"
fi

# 4. project.json.example → .claude/project.json.example (only if .claude/project.json missing)
echo "[4/6] Project config example"
if [[ -f "$TARGET/.claude/project.json" ]]; then
  echo "  skip: .claude/project.json already present"
else
  copy_if_new "$PLUGIN_ROOT/templates/project.json.example" "$TARGET/.claude/project.json.example"
fi

# 5. AGENTS.md + CLAUDE.md
echo "[5/6] AGENTS.md / CLAUDE.md"
if [[ ! -f "$TARGET/AGENTS.md" || "$FORCE" -eq 1 ]]; then
  copy_if_new "$PLUGIN_ROOT/templates/AGENTS.md.template" "$TARGET/AGENTS.md"
fi
if [[ ! -e "$TARGET/CLAUDE.md" || "$FORCE" -eq 1 ]]; then
  if ln -s AGENTS.md "$TARGET/CLAUDE.md" 2>/dev/null; then
    echo "  wrote: $TARGET/CLAUDE.md (symlink → AGENTS.md)"
  else
    cp -f "$TARGET/AGENTS.md" "$TARGET/CLAUDE.md"
    echo "  wrote: $TARGET/CLAUDE.md (copy — symlink not supported here)"
  fi
fi

# 6. TASKS.md
echo "[6/6] TASKS.md"
if [[ ! -f "$TARGET/TASKS.md" || "$FORCE" -eq 1 ]]; then
  copy_if_new "$PLUGIN_ROOT/templates/TASKS.md.template" "$TARGET/TASKS.md"
else
  echo "  skip: TASKS.md already present"
fi

echo
echo "Done."
echo
echo "Next steps:"
echo "  1. Review AGENTS.md and fill in the {{PLACEHOLDER}} sections (or run /repo-onboarding)."
echo "  2. Customize .claude/project.json (copy from .claude/project.json.example)."
echo "  3. Add project-specific gotchas to GOTCHAS.md as they come up."
echo "  4. In Claude Code: skills are available under /<skill-name>."
echo "  5. In GitHub Copilot: prompts are available under /<skill-name> in .github/prompts/."
