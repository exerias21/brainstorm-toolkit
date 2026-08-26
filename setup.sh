#!/usr/bin/env bash
# setup.sh — install brainstorm-toolkit into a target repo for Claude Code, GitHub Copilot, and/or OpenAI Codex.
#
# Usage:
#   bash setup.sh [--target <dir>] [--tools claude|copilot|codex|both|all] [--force]
#                 [--no-copy-scripts] [--no-hooks]
#
#   --target <dir>      Target repo root (default: current directory)
#   --tools <which>     claude | copilot | codex | both | all (default: both)
#                       both = claude + copilot (kept for backward compat)
#                       all  = claude + copilot + codex
#                       Codex skills install to <target>/.agents/skills/<name>/
#                       (the path Codex CLI scans per its 2026 Agent Skills spec).
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
  claude|copilot|codex|both|all) ;;
  *) echo "--tools must be claude, copilot, codex, both, or all" >&2; exit 2 ;;
esac

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$(cd "$TARGET" && pwd)"

if [[ "$PLUGIN_ROOT" == "$TARGET" ]]; then
  echo "note: installing into the plugin repo itself (dogfood mode)." >&2
  echo "      install output is gitignored; the canonical source lives in" >&2
  echo "      skills/, copilot/skills/, codex/skills/, agents/." >&2
fi

echo "brainstorm-toolkit setup"
echo "  plugin root: $PLUGIN_ROOT"
echo "  target:      $TARGET"
echo "  tools:       $TOOLS"
echo "  force:       $FORCE"
echo

want_claude=0; want_copilot=0; want_codex=0
[[ "$TOOLS" == "claude"  || "$TOOLS" == "both" || "$TOOLS" == "all" ]] && want_claude=1
[[ "$TOOLS" == "copilot" || "$TOOLS" == "both" || "$TOOLS" == "all" ]] && want_copilot=1
[[ "$TOOLS" == "codex"   || "$TOOLS" == "all" ]] && want_codex=1

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
echo "[1/7] Skills"
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

  if [[ "$want_codex" -eq 1 ]] && applies_to_includes "$skill_dir" codex; then
    # Codex CLI scans $CWD/.agents/skills/<name>/SKILL.md per its Agent Skills spec.
    # Codex has its own plan mode, but not Claude Code's Workflow tool or its
    # Agent-tool parallel sub-agent fan-out, so the sequential Copilot overlay
    # is the right fit. Fall through in this order:
    #   1. codex/skills/<name>/   — a Codex-tuned override, if one exists
    #   2. copilot/skills/<name>/ — the sequential Copilot overlay (correct for Codex)
    #   3. skills/<name>/         — the canonical (Claude-shaped) skill as a last resort
    codex_override="$PLUGIN_ROOT/codex/skills/$name"
    copilot_override="$PLUGIN_ROOT/copilot/skills/$name"
    if [[ -d "$codex_override" ]]; then
      copy_tree_if_new "$codex_override" "$TARGET/.agents/skills/$name"
    elif [[ -d "$copilot_override" ]]; then
      copy_tree_if_new "$copilot_override" "$TARGET/.agents/skills/$name"
    else
      copy_tree_if_new "$skill_dir" "$TARGET/.agents/skills/$name"
    fi
  fi
done

# 1b. Shared skill templates — reachability fix.
#
# An overlay is installed *instead of* the canonical skill tree, and no overlay ships a
# templates/ dir, so the shared skills/sdlc/templates/ tree never reached Copilot or Codex:
# 26 citations per tool resolved to nothing. 16 of them are CROSS-skill (non-sdlc skills
# citing the sdlc templates), so giving each overlay its own copy would mean the same files
# duplicated into eight skill dirs per tool. Instead: install the shared tree once per tool,
# then rewrite the citation prefix to a path that resolves from the consumer's repo root.
#
# The repo keeps exactly ONE citation form (`skills/sdlc/templates/<file>`), which is what a
# maintainer reads and what validate_skills.py checks. The rewrite below is what a consumer gets.
#
# Idempotent by construction: the backtick anchors the match, so a already-rewritten citation
# (`.github/skills/...`) no longer starts with `skills/ and is skipped on re-run.
install_shared_templates() {
  local root="$1"          # .claude | .github | .agents
  local dest="$TARGET/$root/skills"
  [[ -d "$dest" ]] || return 0

  # Ship the shared sdlc tree wherever a skill was installed for this tool.
  local src="$PLUGIN_ROOT/skills/sdlc/templates"
  if [[ -d "$src" && ! -d "$dest/sdlc/templates" ]]; then
    mkdir -p "$dest/sdlc/templates"
    cp -R "$src/." "$dest/sdlc/templates/" 2>/dev/null || true
  fi

  # Ship the repo-root SEED templates (*.template). /task, /brainstorm, /repo-onboarding and
  # /post-deploy-verify read these to CREATE a missing TASKS.md / AGENTS.md, so the source has
  # to travel even though setup.sh also materializes those files at the target root.
  if compgen -G "$PLUGIN_ROOT/templates/*.template" >/dev/null 2>&1; then
    mkdir -p "$TARGET/$root/templates"
    cp -R "$PLUGIN_ROOT"/templates/*.template "$TARGET/$root/templates/" 2>/dev/null || true
  fi

  # Retarget citations to a repo-root-relative path the agent can actually open.
  local n=0 f
  while IFS= read -r f; do
    local hit=0
    if grep -q '`skills/[a-z0-9-]*/templates/' "$f" 2>/dev/null; then
      sed -i.bak "s|\`skills/|\`$root/skills/|g" "$f" && rm -f "$f.bak"
      hit=1
    fi
    # Seed templates only (*.template). A skill-local `templates/<x>.md` resolves relative to
    # the skill dir already and MUST NOT be rewritten -- doing so would break brainstorm-deep
    # and cheatsheet, which ship their own templates/ dirs.
    if grep -q '`templates/[A-Za-z0-9._-]*\.template`' "$f" 2>/dev/null; then
      sed -i.bak "s|\`templates/\([A-Za-z0-9._-]*\.template\)\`|\`$root/templates/\1\`|g" "$f" && rm -f "$f.bak"
      hit=1
    fi
    [[ "$hit" -eq 1 ]] && n=$((n+1))
  done < <(find "$dest" \( -name 'SKILL.md' -o -path '*/templates/*.md' \) 2>/dev/null)
  [[ "$n" -gt 0 ]] && echo "  retargeted template citations in $n file(s) under $root/"
  return 0
}

echo "[1b/7] Shared skill templates"
[[ "$want_claude"  -eq 1 ]] && install_shared_templates ".claude"
[[ "$want_copilot" -eq 1 ]] && install_shared_templates ".github"
[[ "$want_codex"   -eq 1 ]] && install_shared_templates ".agents"

# 2. Agents (Claude-only)
if [[ "$want_claude" -eq 1 && -d "$PLUGIN_ROOT/agents" ]]; then
  echo "[2/7] Agents (Claude-only)"
  copy_tree_if_new "$PLUGIN_ROOT/agents" "$TARGET/.claude/agents"
fi

# 3. Scripts (repo-local) — opt-out via --no-copy-scripts to use plugin-resident invocation
if [[ -d "$PLUGIN_ROOT/scripts" && "$COPY_SCRIPTS" -eq 1 ]]; then
  echo "[3/7] Scripts"
  copy_tree_if_new "$PLUGIN_ROOT/scripts" "$TARGET/scripts"
  # Plugin-repo-only tooling: scripts/ci/ tests THIS repo's installer and
  # sync-global.sh installs FROM this repo. Neither has any use in a consumer,
  # and both were shipping to every target.
  rm -rf "$TARGET/scripts/ci" "$TARGET/scripts/sync-global.sh"
elif [[ "$COPY_SCRIPTS" -eq 0 ]]; then
  echo "[3/7] Scripts (skipped: --no-copy-scripts)"
  echo "  Configure .claude/project.json to invoke from the plugin, e.g.:"
  echo "    \"eval\": { \"runner\": \"python3 $PLUGIN_ROOT/scripts/eval-runner.py\" }"
fi

# Install the reference .example file if missing; refresh it when --force is
# used. Consumers can review it to discover newly-added optional fields like
# eval.thresholds and pipeline.poka_yoke. The user's actual
# .claude/project.json is never touched.
echo "[4/7] Project config example (skip-on-exist unless --force)"
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
echo "[5/7] AGENTS.md / CLAUDE.md"
if [[ -e "$TARGET/AGENTS.md" || -e "$TARGET/CLAUDE.md" ]]; then
  echo "  skip: AGENTS.md and/or CLAUDE.md already present (user content; not overwritten)"
else
  copy_if_new "$PLUGIN_ROOT/templates/AGENTS.md.template" "$TARGET/AGENTS.md"
  cp -f "$TARGET/AGENTS.md" "$TARGET/CLAUDE.md"
  echo "  wrote: $TARGET/CLAUDE.md (copy of AGENTS.md — keep them in sync)"
fi

# 6. TASKS.md
# Also user content; skip-on-exist regardless of --force.
echo "[6/7] TASKS.md"
if [[ -f "$TARGET/TASKS.md" ]]; then
  echo "  skip: TASKS.md already present (user content; not overwritten)"
else
  copy_if_new "$PLUGIN_ROOT/templates/TASKS.md.template" "$TARGET/TASKS.md"
fi

# CHEATSHEET.md — printable one-pager. Skip-on-exist regardless of --force,
# because consumers customize it (different from /cheatsheet, which is the
# always-current view from SKILL.md frontmatter and never written to disk).
echo "[7/7] CHEATSHEET.md"
if [[ -f "$TARGET/CHEATSHEET.md" ]]; then
  echo "  skip: CHEATSHEET.md already present (user content; not overwritten)"
else
  copy_if_new "$PLUGIN_ROOT/templates/CHEATSHEET.md.template" "$TARGET/CHEATSHEET.md"
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
# $1 = hook script basename (default next-action.sh), $2 = label for the log line.
install_stop_hook_claude() {
  local script="${1:-next-action.sh}"
  local label="${2:-next-action}"
  local settings="$TARGET/.claude/settings.json"
  local cmd
  if [[ "$COPY_SCRIPTS" -eq 1 ]]; then
    cmd="bash scripts/hooks/$script"
  else
    local hook_path_escaped
    printf -v hook_path_escaped '%q' "$PLUGIN_ROOT/scripts/hooks/$script"
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
    echo "  wrote: $settings (added Stop hook for $label)"
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

# Install the Codex Stop hook as .codex/hooks.json. Codex has a Stop hook with the SAME
# {"decision":"block","reason":...} continuation contract as Claude Code
# (learn.chatgpt.com/docs/hooks). Uses the git top-level for the script path (Codex may
# start the hook from a subdirectory). NOTE: project-local .codex/ hooks only fire once
# the user TRUSTS the directory (Codex prompts via `/hooks`).
install_stop_hook_codex() {
  local hook_file="$TARGET/.codex/hooks.json"
  local cmd
  if [[ "$COPY_SCRIPTS" -eq 1 ]]; then
    cmd='bash "$(git rev-parse --show-toplevel)/scripts/hooks/next-action.sh"'
  else
    local hook_path_escaped
    printf -v hook_path_escaped '%q' "$PLUGIN_ROOT/scripts/hooks/next-action.sh"
    cmd="bash $hook_path_escaped"
  fi
  if [[ -f "$hook_file" && "$FORCE" -ne 1 ]]; then
    echo "  skip (exists): $hook_file"
    return
  fi
  local cmd_json=${cmd//\"/\\\"}     # JSON-escape embedded double-quotes
  mkdir -p "$(dirname "$hook_file")"
  cat > "$hook_file" <<JSON
{
  "hooks": {
    "Stop": [
      { "hooks": [{ "type": "command", "command": "$cmd_json", "timeout": 10 }] }
    ]
  }
}
JSON
  echo "  wrote: $hook_file (trust the .codex/ dir via /hooks to activate)"
}

# Install the Codex run-cost-report Stop hook by jq-MERGING a second entry into
# .codex/hooks.json's Stop array. Cannot reuse install_stop_hook_codex: that one writes the
# whole file and skips-on-exist, so it would never add a second hook to an existing install.
# Idempotent by command string.
install_context_watch_codex() {
  local hook_file="$TARGET/.codex/hooks.json"
  local cmd
  if [[ "$COPY_SCRIPTS" -eq 1 ]]; then
    cmd='bash "$(git rev-parse --show-toplevel)/scripts/hooks/run-cost-report.sh"'
  else
    local cw_path_escaped
    printf -v cw_path_escaped '%q' "$PLUGIN_ROOT/scripts/hooks/run-cost-report.sh"
    cmd="bash $cw_path_escaped"
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "  skip: jq not installed — add a run-cost-report Stop hook manually to $hook_file:"
    echo "        {\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"$cmd\",\"timeout\":10}]}]}}"
    return
  fi
  mkdir -p "$(dirname "$hook_file")"
  [[ -f "$hook_file" ]] || echo '{}' > "$hook_file"
  if jq -e --arg cmd "$cmd" '
        any(.hooks.Stop[]?.hooks[]?; .command == $cmd)
      ' "$hook_file" >/dev/null 2>&1; then
    echo "  skip: Codex run-cost-report hook already wired ($cmd)"
    return
  fi
  local tmp; tmp="$(mktemp)"
  if jq --arg cmd "$cmd" '
    .hooks //= {} |
    .hooks.Stop //= [] |
    .hooks.Stop += [{ "hooks": [{ "type": "command", "command": $cmd, "timeout": 10 }] }]
  ' "$hook_file" > "$tmp" && mv "$tmp" "$hook_file"; then
    echo "  wrote: $hook_file (added run-cost-report Stop hook)"
  else
    rm -f "$tmp"
    echo "  error: failed to update $hook_file with Codex run-cost-report hook" >&2
    return 1
  fi
}

# Install the Codex PostCompact reseed hook by jq-MERGING a PostCompact array into
# .codex/hooks.json. Separate from install_stop_hook_codex (which skips-on-exist,
# writing the whole file) so an EXISTING Codex install that only had `Stop` still
# gains PostCompact on a plain re-run — and without clobbering any hand-added hooks.
# Idempotent by command string.
install_reseed_hook_codex() {
  local hook_file="$TARGET/.codex/hooks.json"
  local cmd
  if [[ "$COPY_SCRIPTS" -eq 1 ]]; then
    cmd='bash "$(git rev-parse --show-toplevel)/scripts/hooks/reseed-context.sh"'
  else
    local reseed_path_escaped
    printf -v reseed_path_escaped '%q' "$PLUGIN_ROOT/scripts/hooks/reseed-context.sh"
    cmd="bash $reseed_path_escaped"
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "  skip: jq not installed — add a PostCompact hook manually to $hook_file:"
    echo "        {\"hooks\":{\"PostCompact\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"$cmd\",\"timeout\":10}]}]}}"
    return
  fi
  mkdir -p "$(dirname "$hook_file")"
  [[ -f "$hook_file" ]] || echo '{}' > "$hook_file"
  if jq -e --arg cmd "$cmd" '
        any(.hooks.PostCompact[]?.hooks[]?; .command == $cmd)
      ' "$hook_file" >/dev/null 2>&1; then
    echo "  skip: Codex PostCompact reseed hook already wired ($cmd)"
    return
  fi
  local tmp; tmp="$(mktemp)"
  if jq --arg cmd "$cmd" '
    .hooks //= {} |
    .hooks.PostCompact //= [] |
    .hooks.PostCompact += [{ "hooks": [{ "type": "command", "command": $cmd, "timeout": 10 }] }]
  ' "$hook_file" > "$tmp" && mv "$tmp" "$hook_file"; then
    echo "  wrote: $hook_file (added PostCompact reseed; trust the .codex/ dir via /hooks to activate)"
  else
    rm -f "$tmp"
    echo "  error: failed to update $hook_file with Codex PostCompact reseed hook" >&2
    return 1
  fi
}

# Install the Claude SessionStart reseed hook (matcher compact|clear) into settings.json.
# Separate from install_stop_hook_claude (which early-returns when the Stop hook already
# exists) so re-runs still wire the reseed leg. Idempotent by command string.
install_reseed_hook_claude() {
  local settings="$TARGET/.claude/settings.json"
  local cmd
  if [[ "$COPY_SCRIPTS" -eq 1 ]]; then
    cmd="bash scripts/hooks/reseed-context.sh"
  else
    local reseed_path_escaped
    printf -v reseed_path_escaped '%q' "$PLUGIN_ROOT/scripts/hooks/reseed-context.sh"
    cmd="bash $reseed_path_escaped"
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "  skip: jq not installed — add SessionStart reseed hook manually to $settings:"
    echo "        {\"hooks\":{\"SessionStart\":[{\"matcher\":\"compact|clear\",\"hooks\":[{\"type\":\"command\",\"command\":\"$cmd\"}]}]}}"
    return
  fi
  mkdir -p "$(dirname "$settings")"
  [[ -f "$settings" ]] || echo '{}' > "$settings"
  if jq -e --arg cmd "$cmd" '
        any(.hooks.SessionStart[]?.hooks[]?; .command == $cmd)
      ' "$settings" >/dev/null 2>&1; then
    echo "  skip: Claude SessionStart reseed hook already wired ($cmd)"
    return
  fi
  local tmp; tmp="$(mktemp)"
  if jq --arg cmd "$cmd" '
    .hooks //= {} |
    .hooks.SessionStart //= [] |
    .hooks.SessionStart += [{ "matcher": "compact|clear", "hooks": [{ "type": "command", "command": $cmd }] }]
  ' "$settings" > "$tmp" && mv "$tmp" "$settings"; then
    echo "  wrote: $settings (added SessionStart reseed hook)"
  else
    rm -f "$tmp"
    echo "  error: failed to update $settings with Claude SessionStart reseed hook" >&2
    return 1
  fi
}

echo "[gitignore]"
# Local working state, not shared contract. project.json is machine-specific (test
# commands, paths); the committed bootstrap template is .claude/project.json.example,
# which is deliberately NOT ignored -- the pattern below matches the exact filename, so
# the .example sibling stays tracked. Ignoring these does not break the cross-tool
# contract: Copilot and Codex read them off disk, and .gitignore governs sharing, not
# reading. Mirrors /repo-onboarding Step 5 -- keep the two lists in sync.
ensure_gitignored ".claude/pipeline/"
ensure_gitignored ".claude/.next-action"
ensure_gitignored ".claude/.auto-continue-hops"
ensure_gitignored ".claude/project.json"
ensure_gitignored "TASKS.md"
ensure_gitignored "plans/"

if [[ "$INSTALL_HOOKS" -eq 1 ]]; then
  if [[ "$want_claude" -eq 1 ]]; then
    echo "[hooks] Claude Stop hook"
    install_stop_hook_claude
    echo "[hooks] Claude SessionStart reseed hook"
    install_reseed_hook_claude
    install_stop_hook_claude run-cost-report.sh run-cost-report
  fi
  if [[ "$want_copilot" -eq 1 ]]; then
    echo "[hooks] Copilot Stop hook"
    install_stop_hook_copilot
    echo "  note: Copilot has no compaction/session hook — see docs/LOOP-HYGIENE.md for the fresh-process loop mitigation"
  fi
  if [[ "$want_codex" -eq 1 ]]; then
    echo "[hooks] Codex Stop + PostCompact hooks"
    install_stop_hook_codex
    install_reseed_hook_codex
    install_context_watch_codex
  fi
else
  echo "[hooks] skipped (--no-hooks)"
fi

echo
echo "Done."
echo
# The epilogue is what the user actually acts on, so it must name only the runtimes
# they installed. It used to be hard-coded and always named Claude + Copilot — a
# `--tools codex` install was told to reload the VS Code window (irrelevant) and was
# never told to trust the .codex/ dir, without which its Stop hook silently never
# fires. `step` renumbers automatically so omitting a line can't leave a gap.
step=1
echo "Next steps:"
echo "  $((step++)). Review AGENTS.md and fill in the {{PLACEHOLDER}} sections (or run /repo-onboarding)."
echo "  $((step++)). Customize .claude/project.json (copy from .claude/project.json.example)."
# /repo-onboarding owns GOTCHAS.md creation (from examples/GOTCHAS.md.example) —
# setup.sh never creates it, so don't imply the file is already there.
echo "  $((step++)). Add project-specific gotchas to GOTCHAS.md (/repo-onboarding creates it) as they come up."
if [[ "$want_claude" -eq 1 ]]; then
  echo "  $((step++)). In Claude Code: skills are available under /<skill-name>."
fi
if [[ "$want_copilot" -eq 1 ]]; then
  echo "  $((step++)). In GitHub Copilot: skills are available under /<skill-name> in .github/skills/."
fi
if [[ "$want_codex" -eq 1 ]]; then
  echo "  $((step++)). In Codex: skills are available under /<skill-name> from .agents/skills/."
fi
if [[ "$INSTALL_HOOKS" -eq 1 ]]; then
  echo "  $((step++)). Stop hooks were installed but may need one-time activation:"
  [[ "$want_claude"  -eq 1 ]] && echo "       Claude Code: open /hooks once to register .claude/settings.json"
  [[ "$want_copilot" -eq 1 ]] && echo "       Copilot:     reload the VS Code window"
  # The trust gate is the non-obvious one: project-local .codex/ hooks do not fire
  # until the directory is trusted, and nothing else in the output says so.
  [[ "$want_codex"   -eq 1 ]] && echo "       Codex:       trust the .codex/ dir via /hooks (hooks do NOT fire until you do)"
fi

# The last statement above is a conditional `[[ ... ]] && echo`, whose false branch would
# otherwise become the script's exit status -- so a fully successful install returned 1
# unless codex happened to be selected. Every smoke test used --tools all, which set the
# flag and masked it. Be explicit.
exit 0
