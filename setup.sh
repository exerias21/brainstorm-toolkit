#!/usr/bin/env bash
# setup.sh â€” install brainstorm-toolkit into a target repo for Claude Code and/or GitHub Copilot.
#
# Usage:
#   bash setup.sh [--target <dir>] [--tools claude|copilot|both] [--force] [--no-copy-scripts]
#
#   --target <dir>      Target repo root (default: current directory)
#   --tools <which>     claude | copilot | both (default: both)
#   --force             Overwrite existing files (default: skip-if-exists)
#   --no-copy-scripts   Don't copy plugin scripts/ into target. Use this when
#                       you'd rather invoke project-agnostic helpers
#                       (eval-runner.py, check_docker_logs.py) from the plugin
#                       install directly — point .claude/project.json at the
#                       absolute plugin path instead.
#
# Design: the plugin repo is the source of truth. Re-run this script to refresh
# a consumer repo. On POSIX we try a symlink CLAUDE.md â†’ AGENTS.md; otherwise copy.

set -euo pipefail

TARGET="$(pwd)"
TOOLS="both"
FORCE=0
COPY_SCRIPTS=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)            TARGET="$2"; shift 2 ;;
    --tools)             TOOLS="$2"; shift 2 ;;
    --force)             FORCE=1; shift ;;
    --no-copy-scripts)   COPY_SCRIPTS=0; shift ;;
    -h|--help)
      sed -n '2,15p' "$0" | sed 's/^# *//'
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

# 4. project.json.example â†’ .claude/project.json.example (only if .claude/project.json missing)
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
    echo "  wrote: $TARGET/CLAUDE.md (symlink â†’ AGENTS.md)"
  else
    cp -f "$TARGET/AGENTS.md" "$TARGET/CLAUDE.md"
    echo "  wrote: $TARGET/CLAUDE.md (copy â€” symlink not supported here)"
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
echo "  5. In GitHub Copilot: skills are available under /<skill-name> in .github/skills/."
