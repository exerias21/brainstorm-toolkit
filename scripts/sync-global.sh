#!/usr/bin/env bash
# scripts/sync-global.sh — install brainstorm-toolkit GLOBALLY into ~/.claude from a
# checkout, with no marketplace, no plugin registration, and no --plugin-dir sideload.
#
# For machines where the plugin route isn't available or isn't wanted (org policy sets
# `disableSideloadFlags`, marketplace install blocked, Windows + WSL sharing one setup).
# It reaches the same runtime surface as the plugin:
#
#     ~/.claude/skills/<name>/          <- skills/<name>/          (canonical, Claude flavor)
#     ~/.claude/agents/<name>.md        <- agents/<name>.md
#     ~/.claude/brainstorm-toolkit/     <- the self-contained runtime root:
#         scripts/                         scripts/ minus scripts/ci and this file
#         templates/                       the seed templates + project.json.example
#         .claude-plugin/plugin.json       the version
#         INSTALL.json                     version, source repo + commit, time, skills, hooks
#     ~/.claude/settings.json           <- every hook hooks/hooks.json declares, wired
#                                          to the runtime root with absolute paths
#
# Usage:
#   bash scripts/sync-global.sh [--dry-run] [--skills a,b,c] [--no-hooks]
#                               [--prune-relative-hooks] [--repo <dir>]
#   bash scripts/sync-global.sh --status
#   bash scripts/sync-global.sh --uninstall [--dry-run]
#
#   --dry-run                Print every action and the settings.json diff; write nothing.
#                            RUN THIS FIRST.
#   --skills a,b,c           Sync only these skills (default: every skill under skills/).
#                            They are user-scope-resident in EVERY repo once synced.
#   --no-hooks               Skip the ~/.claude/settings.json hook wiring entirely.
#   --prune-relative-hooks   Also remove pre-existing toolkit hooks wired by a RELATIVE
#                            path (the classic breakage: a repo-scoped hook copied into
#                            global settings, where it only fires in repos that have it).
#   --status                 Show installed vs. repo version and which hooks are wired.
#   --uninstall              Remove the toolkit's skills, agents, runtime dir and hooks.
#                            Everything else in ~/.claude is kept.
#   --repo <dir>             Toolkit repo root (default: this script's parent dir).
#
# WHY COPIES, NOT SYMLINKS: symlinked skills and agents have known discovery bugs in
# Claude Code (missing from /skills autocomplete, "Unknown skill" at invoke, subagents
# not found), and a symlink would make a `git checkout` in the repo silently swap your
# live skills mid-session. Re-run after a `git pull` to update — that explicit step is
# the feature. The runtime dir is built beside the old one and swapped in, so a running
# session never sees a half-written tree.
#
# WHY HOOKS POINT AT THE RUNTIME DIR: ${CLAUDE_PLUGIN_ROOT} only expands inside the plugin
# runtime, and a path into the checkout would let a branch switch change live sessions.
# The hook list is read from hooks/hooks.json at run time (not hard-coded here), so the
# shell install cannot drift from the plugin's; CI's shell-install-parity check enforces it.
#
# SAFETY: skill removal is scoped PER SKILL DIRECTORY, never ~/.claude/skills/ as a whole.
# Every settings.json write is preceded by a uniquely named timestamped .bak.
set -euo pipefail

DRY_RUN=0
WANT_HOOKS=1
PRUNE_RELATIVE=0
UNINSTALL=0
STATUS=0
SKILL_FILTER=""
REPO="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)              DRY_RUN=1; shift ;;
    --skills)               SKILL_FILTER="${2:-}"; shift 2 ;;
    --no-hooks)             WANT_HOOKS=0; shift ;;
    --prune-relative-hooks) PRUNE_RELATIVE=1; shift ;;
    --uninstall)            UNINSTALL=1; shift ;;
    --status)               STATUS=1; shift ;;
    --repo)                 REPO="${2:-}"; shift 2 ;;
    -h|--help)              awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

CLAUDE_DIR="$HOME/.claude"
SKILLS_DST="$CLAUDE_DIR/skills"
AGENTS_DST="$CLAUDE_DIR/agents"
SETTINGS="$CLAUDE_DIR/settings.json"
RT="$CLAUDE_DIR/brainstorm-toolkit"
OLD_MANIFEST="$CLAUDE_DIR/.brainstorm-toolkit-global.json"
PLUGIN_KEY="brainstorm-toolkit@brainstorm-toolkit"

REPO="$(cd "$REPO" && pwd)"
HOOKS_JSON="$REPO/hooks/hooks.json"

say() { printf '%s\n' "$*"; }
act() { if [[ "$DRY_RUN" -eq 1 ]]; then say "  [dry-run] $*"; return 0; fi; return 1; }

# Windows / Git Bash: native tools (python, jq.exe) and the hook shell want C:/... paths,
# which Git Bash's `bash` also accepts. Elsewhere cygpath does not exist and this is a no-op.
pp() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
HOOK_ROOT="$(pp "$RT")"

[[ -d "$REPO/skills" && -f "$HOOKS_JSON" ]] || { echo "error: $REPO does not look like the toolkit repo (no skills/ or hooks/hooks.json)" >&2; exit 1; }

# ------------------------------------------------------------- json backend
# jq when present, else a working python through scripts/py.sh. BRAINSTORM_NO_JQ=1 forces
# the python path (the no-jq branch is exercised by CI that way).
BACKEND=""
PY=""
if [[ "${BRAINSTORM_NO_JQ:-0}" != "1" ]] && command -v jq >/dev/null 2>&1; then
  BACKEND="jq"
elif PY="$(bash "$REPO/scripts/py.sh" --print 2>/dev/null)" && [[ -n "$PY" ]]; then
  BACKEND="py"
fi

PYSRC='
import json, re, sys
try:
    sys.stdout.reconfigure(newline="\n")
except Exception:
    pass
op, hj, root, ours_re, any_re, prune = sys.argv[1:7]
if op == "rows":
    for ev, groups in (json.load(open(hj, encoding="utf-8")).get("hooks") or {}).items():
        for g in groups:
            for h in g.get("hooks") or []:
                print("\x1f".join([ev, g.get("matcher") or "", str(h.get("timeout", "")), h.get("command", "")]))
    sys.exit(0)
text = sys.stdin.read()
data = json.loads(text) if text.strip() else {}
def dump(d, srt):
    return json.dumps(d, indent=2, sort_keys=srt, ensure_ascii=False)
if op == "pretty":
    print(dump(data, True)); sys.exit(0)
def command(h):
    c = h.get("command") if isinstance(h, dict) else None
    return c if isinstance(c, str) else ""
def drop(h):
    c = command(h)
    if re.search(ours_re, c):
        return True
    return prune == "1" and bool(re.search(any_re, c))
if op == "has":
    ev, cmd = sys.argv[7:9]
    found = any(command(h) == cmd for g in (data.get("hooks") or {}).get(ev, []) if isinstance(g, dict)
                for h in g.get("hooks") or [])
    sys.exit(0 if found else 1)
hooks = data.get("hooks")
if hooks is None:
    hooks = {}
for ev in list(hooks):
    kept = []
    for g in hooks[ev]:
        if isinstance(g, dict) and isinstance(g.get("hooks"), list):
            before = len(g["hooks"])
            g["hooks"] = [h for h in g["hooks"] if not drop(h)]
            if before and not g["hooks"]:
                continue
        kept.append(g)
    hooks[ev] = kept
if op == "install":
    spec = json.load(open(hj, encoding="utf-8")).get("hooks") or {}
    for ev, groups in spec.items():
        for g in groups:
            for h in g.get("hooks") or []:
                h["command"] = h["command"].replace("${CLAUDE_PLUGIN_ROOT}", root)
        hooks[ev] = hooks.get(ev, []) + groups
else:
    hooks = {k: v for k, v in hooks.items() if v}
if hooks:
    data["hooks"] = hooks
else:
    data.pop("hooks", None)
print(dump(data, False))
'

JQ_OURS='def ours: ((.command // "") | tostring | test($re));
         def stale: ($prune == 1) and ((.command // "") | tostring | test($any)) and (ours | not);
         def clean: map(if (.hooks | type) == "array" then .hooks |= map(select((ours or stale) | not)) else . end)
                    | map(select((.hooks | type) != "array" or (.hooks | length) > 0));'

# jx <op> [extra] — JSON settings transform. Reads the settings text on stdin, except
# `rows` (reads hooks.json only). ops: rows | pretty | install | uninstall | has <event> <cmd>
jx() {
  local op="$1"; shift
  if [[ "$BACKEND" == "py" ]]; then
    "$PY" -c "$PYSRC" "$op" "$(pp "$HOOKS_JSON")" "$HOOK_ROOT" "$OURS_RE" "$ANY_RE" "$PRUNE_RELATIVE" "$@" | tr -d '\r'
    return "${PIPESTATUS[0]}"
  fi
  # jq.exe on Windows emits CRLF; a stray CR would end up inside every parsed command.
  jx_jq "$op" "$@" | tr -d '\r'
  return "${PIPESTATUS[0]}"
}

jx_jq() {
  local op="$1"; shift
  case "$op" in
    rows)    jq -r '.hooks | to_entries[] | .key as $e | .value[] | (.matcher // "") as $m | .hooks[]
                    | [$e, $m, ((.timeout // "") | tostring), .command] | join("\u001f")' "$(pp "$HOOKS_JSON")" ;;
    pretty)  jq -S . ;;
    has)     jq -e --arg e "$1" --arg c "$2" 'any(.hooks[$e][]?; any(.hooks[]?; .command == $c))' >/dev/null ;;
    install)
      jq --arg re "$OURS_RE" --arg any "$ANY_RE" --argjson prune "$PRUNE_RELATIVE" --arg root "$HOOK_ROOT" \
         --slurpfile hj "$(pp "$HOOKS_JSON")" "$JQ_OURS"'
         (.hooks // {}) as $h0
         | .hooks = ($h0 | map_values(if type == "array" then clean else . end))
         | reduce ($hj[0].hooks | keys_unsorted[]) as $e (.;
             .hooks[$e] = ((.hooks[$e] // []) +
               ($hj[0].hooks[$e] | map(.hooks |= map(.command |= (split("${CLAUDE_PLUGIN_ROOT}") | join($root)))))))' ;;
    uninstall)
      jq --arg re "$OURS_RE" --arg any "$ANY_RE" --argjson prune "$PRUNE_RELATIVE" "$JQ_OURS"'
         if has("hooks") then
           .hooks |= (map_values(if type == "array" then clean else . end) | with_entries(select(.value != [])))
           | if .hooks == {} then del(.hooks) else . end
         else . end' ;;
  esac
}

# Rows of hooks.json: event US matcher US timeout US command-template (US = octal 037, which
# IFS does not collapse the way it collapses a tab when matcher or timeout is empty).
US="$(printf '\037')"
ROWS=""
OURS_RE=""; ANY_RE=""
load_rows() {
  [[ -n "$BACKEND" ]] || { echo "error: neither jq nor a working python found -- install one (see scripts/py.sh)" >&2; exit 1; }
  ROWS="$(jx rows)"
  [[ -n "$ROWS" ]] || { echo "error: no hooks read from $HOOKS_JSON" >&2; exit 1; }
  local alt="" ev m t cmd base
  while IFS="$US" read -r ev m t cmd; do
    base="${cmd##*/}"; base="${base//\"/}"; base="${base//\'/}"
    alt="${alt:+$alt|}${base//./\\.}"
  done <<EOF
$ROWS
EOF
  # "Ours" = an ABSOLUTE path (any checkout, any older install) ending in scripts/hooks/<a hooks.json script>.
  OURS_RE="[ \"']([A-Za-z]:)?/.*/scripts/hooks/($alt)[\"']?\$"
  ANY_RE="scripts/hooks/($alt)[\"']?\$"
}
want_cmd() { printf '%s' "${1//\$\{CLAUDE_PLUGIN_ROOT\}/$HOOK_ROOT}"; }

read_settings() {
  local b; b="$(cat "$SETTINGS" 2>/dev/null || true)"
  [[ -z "${b//[[:space:]]/}" ]] && b='{}'
  printf '%s' "$b"
}

backup_settings() {
  [[ -f "$SETTINGS" ]] || return 0
  local stamp n=0 dst
  stamp="$(date +%Y%m%d%H%M%S)"; dst="$SETTINGS.bak-$stamp"
  while [[ -e "$dst" ]]; do n=$((n + 1)); dst="$SETTINGS.bak-$stamp-$n"; done
  cp "$SETTINGS" "$dst"
  say "  backup: $dst"
}

# apply_settings <install|uninstall> — compute, diff, back up, write.
apply_settings() {
  local op="$1" base new
  base="$(read_settings)"
  if ! printf '%s' "$base" | jx pretty >/dev/null 2>&1; then
    echo "error: $SETTINGS is not valid JSON — fix or move it, then re-run" >&2; exit 1
  fi
  new="$(printf '%s' "$base" | jx "$op")" || { echo "error: failed to build settings update" >&2; exit 1; }
  local a b; a="$(printf '%s' "$base" | jx pretty)"; b="$(printf '%s' "$new" | jx pretty)"
  if [[ "$a" == "$b" ]]; then
    say "  settings.json: no change"
    return 0
  fi
  say "settings.json diff ($SETTINGS):"
  diff -u <(printf '%s\n' "$a") <(printf '%s\n' "$b") | sed '1,2d;s/^/  /' || true
  act "write $SETTINGS" && return 0
  mkdir -p "$CLAUDE_DIR"
  backup_settings
  printf '%s\n' "$new" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  say "  wrote $SETTINGS"
}

plugin_warning() {
  local f="$CLAUDE_DIR/plugins/installed_plugins.json" hit=0
  { [[ -f "$f" ]] && grep -qF "$PLUGIN_KEY" "$f"; } && hit=1
  { [[ -f "$SETTINGS" ]] && grep -qF "\"$PLUGIN_KEY\"" "$SETTINGS"; } && hit=1
  [[ "$hit" -eq 1 ]] || return 0
  say "WARNING: the brainstorm-toolkit PLUGIN is also installed ($PLUGIN_KEY)."
  say "         Both routes double-register every skill and fire every hook twice. Remove the plugin:"
  say "           claude plugin uninstall $PLUGIN_KEY --scope user"
  say "           claude plugin marketplace remove brainstorm-toolkit"
  say
}

json_field() { { sed -n "s/^ *\"$2\": *\"\\([^\"]*\\)\".*/\\1/p" "$1" 2>/dev/null | head -n 1; } || true; }
json_list()  { awk -v k="$2" '$0 ~ "\""k"\": *\\[" {on=1; next} on && /\]/ {exit} on {gsub(/^[ \t]*"|",?[ \t]*$|"$/,""); if ($0!="") print}' "$1" 2>/dev/null || true; }
repo_version() { json_field "$REPO/.claude-plugin/plugin.json" version; }
jesc() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }

# ------------------------------------------------------------------ status
if [[ "$STATUS" -eq 1 ]]; then
  say "brainstorm-toolkit — global install status"
  load_rows
  if [[ -f "$RT/INSTALL.json" ]]; then
    iv="$(json_field "$RT/INSTALL.json" version)"
    say "  installed: ${iv:-?}  (commit $(json_field "$RT/INSTALL.json" source_commit), $(json_field "$RT/INSTALL.json" installed_at))"
    say "  source:    $(json_field "$RT/INSTALL.json" source_repo)"
  else
    iv=""; say "  installed: no ($RT/INSTALL.json not found)"
  fi
  rv="$(repo_version)"
  say "  repo:      ${rv:-?}  ($REPO)"
  if [[ -n "$iv" && "$iv" != "$rv" ]]; then say "  -> versions differ: re-run sync-global.sh to update"; fi
  say "  hooks in $SETTINGS:"
  base="$(read_settings)"
  while IFS="$US" read -r ev m t cmd; do
    if printf '%s' "$base" | jx has "$ev" "$(want_cmd "$cmd")"; then st="present"; else st="MISSING"; fi
    hb="${cmd##*/}"
    say "    $st  $ev${m:+ [$m]}  ${hb//\"/}"
  done <<EOF
$ROWS
EOF
  say
  plugin_warning
  exit 0
fi

# --------------------------------------------------------------- uninstall
if [[ "$UNINSTALL" -eq 1 ]]; then
  say "brainstorm-toolkit — global UNINSTALL"
  [[ "$DRY_RUN" -eq 1 ]] && say "  MODE:     dry-run (nothing will be written)"
  # Names to remove: what INSTALL.json recorded, plus this checkout's current names.
  names_s="$( { json_list "$RT/INSTALL.json" skills; for d in "$REPO"/skills/*/; do basename "$d"; done; true; } | sort -u)"
  names_a="$( { json_list "$RT/INSTALL.json" agents; for f in "$REPO"/agents/*.md; do [[ -f "$f" ]] && basename "$f" .md; done; true; } | sort -u)"
  while IFS= read -r s; do
    [[ -n "$s" && -d "$SKILLS_DST/$s" ]] || continue
    say "  skill: $s"; act "rm -rf $SKILLS_DST/$s" || rm -rf "${SKILLS_DST:?}/$s"
  done <<EOF
$names_s
EOF
  while IFS= read -r a; do
    [[ -n "$a" && -f "$AGENTS_DST/$a.md" ]] || continue
    say "  agent: $a"; act "rm -f $AGENTS_DST/$a.md" || rm -f "${AGENTS_DST:?}/$a.md"
  done <<EOF
$names_a
EOF
  if [[ -d "$RT" ]]; then say "  runtime: $RT"; act "rm -rf $RT" || rm -rf "${RT:?}"; fi
  [[ -f "$OLD_MANIFEST" ]] && { act "rm -f $OLD_MANIFEST" || rm -f "$OLD_MANIFEST"; }
  if [[ -f "$SETTINGS" ]]; then
    load_rows
    apply_settings uninstall
  fi
  say "done. Restart Claude Code."
  exit 0
fi

# -------------------------------------------------------------------- plan
say "brainstorm-toolkit — global sync (no marketplace, no sideload)"
say "  repo:     $REPO"
say "  skills -> $SKILLS_DST"
say "  agents -> $AGENTS_DST"
say "  runtime-> $RT"
[[ "$DRY_RUN" -eq 1 ]] && say "  MODE:     dry-run (nothing will be written)"
say
plugin_warning
load_rows

SKILLS=()
if [[ -n "$SKILL_FILTER" ]]; then
  IFS=',' read -ra SKILLS <<< "$SKILL_FILTER"
  for s in "${SKILLS[@]}"; do
    [[ -d "$REPO/skills/$s" ]] || { echo "error: no such skill: $s" >&2; exit 1; }
  done
else
  for d in "$REPO"/skills/*/; do SKILLS+=("$(basename "$d")"); done
fi

say "syncing ${#SKILLS[@]} skill(s):"
act "mkdir -p $SKILLS_DST" || mkdir -p "$SKILLS_DST"
for s in "${SKILLS[@]}"; do
  # Replace THIS skill dir only (rm-then-cp = rsync --delete scoped to it); siblings are never touched.
  act "replace $SKILLS_DST/$s" || { rm -rf "${SKILLS_DST:?}/$s" && mkdir -p "$SKILLS_DST/$s" && cp -R "$REPO/skills/$s/." "$SKILLS_DST/$s/"; }
  say "  $s"
done
say

say "syncing agents:"
act "mkdir -p $AGENTS_DST" || mkdir -p "$AGENTS_DST"
AGENT_NAMES=()
for f in "$REPO"/agents/*.md; do
  [[ -f "$f" ]] || continue
  act "cp $f $AGENTS_DST/" || cp -f "$f" "$AGENTS_DST/"
  AGENT_NAMES+=("$(basename "$f" .md)"); say "  $(basename "$f")"
done
say

# ----------------------------------------------------------------- runtime
# Skills run scripts/close-tasks.sh, scripts/py.sh, scripts/plan-refs.sh ... and read the
# seed templates. Same exclusions as setup.sh's repo-local copy: scripts/ci and this file
# are repo-only tooling (this script installs FROM a checkout; a copy at runtime has no
# skills/ to install and would only mislead).
say "runtime root: $RT"
VERSION="$(repo_version)"
COMMIT="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || true)"; COMMIT="${COMMIT:-unknown}"

# Skills/agents records are the UNION with any prior install, so a --skills subset run
# never shrinks what --uninstall knows it owns.
REC_SKILLS="$( { json_list "$RT/INSTALL.json" skills; printf '%s\n' "${SKILLS[@]}"; } | sort -u)"
REC_AGENTS="$( { json_list "$RT/INSTALL.json" agents; [[ ${#AGENT_NAMES[@]} -gt 0 ]] && printf '%s\n' "${AGENT_NAMES[@]}"; } | sort -u)"
REC_HOOKS=""
if [[ "$WANT_HOOKS" -eq 1 ]]; then
  while IFS="$US" read -r ev m t cmd; do
    REC_HOOKS="${REC_HOOKS}$(want_cmd "$cmd")"$'\n'
  done <<EOF
$ROWS
EOF
fi

json_array() {  # stdin lines -> pretty JSON array body (no brackets)
  local first=1 line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    [[ "$first" -eq 1 ]] || printf ',\n'
    printf '    "%s"' "$(jesc "$line")"; first=0
  done
  [[ "$first" -eq 1 ]] || printf '\n'
}

if ! act "build $RT (scripts/, templates/, .claude-plugin/plugin.json, INSTALL.json), then swap it in"; then
  NEW_RT="$CLAUDE_DIR/.brainstorm-toolkit.new.$$"
  OLD_RT="$CLAUDE_DIR/.brainstorm-toolkit.old.$$"
  rm -rf "$NEW_RT" "$OLD_RT"
  mkdir -p "$NEW_RT/scripts" "$NEW_RT/.claude-plugin"
  while IFS= read -r f; do
    rel="${f#"$REPO"/scripts/}"
    mkdir -p "$NEW_RT/scripts/$(dirname "$rel")"
    cp "$f" "$NEW_RT/scripts/$rel"
  done < <(find "$REPO/scripts" \( -path "$REPO/scripts/ci" -o -name __pycache__ \) -prune -o \
              -type f ! -name '*.pyc' ! -name '*.pyo' ! -name sync-global.sh -print)
  [[ -d "$REPO/templates" ]] && { mkdir -p "$NEW_RT/templates"; cp -R "$REPO/templates/." "$NEW_RT/templates/"; }
  cp "$REPO/.claude-plugin/plugin.json" "$NEW_RT/.claude-plugin/plugin.json"
  {
    printf '{\n  "version": "%s",\n  "source_repo": "%s",\n  "source_commit": "%s",\n  "installed_at": "%s",\n' \
      "$(jesc "$VERSION")" "$(jesc "$(pp "$REPO")")" "$(jesc "$COMMIT")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  "skills": [\n'; printf '%s\n' "$REC_SKILLS" | json_array; printf '  ],\n'
    printf '  "agents": [\n'; printf '%s\n' "$REC_AGENTS" | json_array; printf '  ],\n'
    printf '  "hooks": [\n'; printf '%s' "$REC_HOOKS" | json_array; printf '  ]\n}\n'
  } > "$NEW_RT/INSTALL.json"
  mkdir -p "$CLAUDE_DIR"
  [[ -e "$RT" ]] && mv "$RT" "$OLD_RT"
  mv "$NEW_RT" "$RT"
  rm -rf "$OLD_RT"
  say "  installed $VERSION ($COMMIT)"
fi
[[ -f "$OLD_MANIFEST" ]] && { act "rm -f $OLD_MANIFEST (superseded by INSTALL.json)" || rm -f "$OLD_MANIFEST"; }
say

# ------------------------------------------------------------------- hooks
if [[ "$WANT_HOOKS" -eq 1 ]]; then
  say "hooks: every hook in hooks/hooks.json -> $HOOK_ROOT/scripts/hooks/ ($BACKEND)"
  apply_settings install
  say
fi

say "done — restart Claude Code (the skill + agent registries load at session start)."
say "Verify:  bash $REPO/scripts/sync-global.sh --status"
say "Update:  git pull in $REPO, then re-run this script — it copies, it does not link."
