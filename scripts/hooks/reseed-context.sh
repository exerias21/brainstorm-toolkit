#!/usr/bin/env bash
# brainstorm-toolkit — reseed-context hook (loop context hygiene).
#
# Cross-tool: wired as a Claude Code SessionStart hook (matcher "compact|clear")
# and a Codex PostCompact hook. When a long-running loop's orchestrator session is
# compacted or cleared mid-work, this re-injects a POINTER to the loop's durable
# on-disk state (the active pipeline envelope + the .next-action sentinel + TASKS.md
# counts) as `additionalContext`. It never dumps state — the files are the memory;
# this just points back at them.
#
# Best-effort and FAIL-SOFT: emits nothing (exit 0) in any repo that isn't running a
# loop, so it costs zero tokens where it's irrelevant. See docs/LOOP-HYGIENE.md.
set -u

# A bare interactive TTY (manual debug invocation with no piped input) would block on
# `cat` below; the shipped hooks always pipe JSON, so guard the debug case explicitly.
[ -t 0 ] && exit 0

# Project root: CLAUDE_PROJECT_DIR (Claude) > git top-level (Codex may start elsewhere) > cwd.
PROJ="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$PROJ" ]; then
  if _gr="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$_gr" ]; then PROJ="$_gr"; else PROJ="$PWD"; fi
fi

# Read hook stdin. Tolerate the trigger field-name difference across tools/events:
# Claude SessionStart -> `.source` (startup|resume|clear|compact); Codex PostCompact
# -> `.trigger` (manual|auto). Also read `.hook_event_name` so the output names the
# actual invoking event rather than assuming SessionStart.
input="$(cat 2>/dev/null || true)"
trigger=""; event=""
if command -v jq >/dev/null 2>&1 && [ -n "$input" ]; then
  trigger="$(printf '%s' "$input" | jq -r '.source // .trigger // .reason // empty' 2>/dev/null || true)"
  event="$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null || true)"
fi
# Reseed only on a context RESET. A plain session start/resume needs none (the loop
# reads state on its next action anyway). PostCompact's manual/auto trigger, or an
# absent trigger, falls through and reseeds — which is correct (it only fires post-compact).
case "$trigger" in startup|resume) exit 0 ;; esac

cd "$PROJ" 2>/dev/null || exit 0

# Most-recent NON-TERMINAL pipeline envelope, if any (skip completed runs; fall back
# past a newer completed run to an older still-active one). Whole block needs jq — if
# jq is absent, report no envelope rather than emitting blank fields.
env_file=""; slug=""; stage=""; status=""
if command -v jq >/dev/null 2>&1; then
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    st="$(jq -r '.status // empty' "$cand" 2>/dev/null || true)"
    case "$st" in
      in_progress|paused|failed)
        env_file="$cand"; status="$st"
        slug="$(jq -r '.feature_slug // empty' "$cand" 2>/dev/null || true)"
        stage="$(jq -r '.stage // empty' "$cand" 2>/dev/null || true)"
        break ;;
    esac
  done < <(ls -t .claude/pipeline/*/run.json 2>/dev/null)
fi

# Sentinel (by path — read bounded in python, never via argv) + queue counts (fail-soft).
sentinel_file=""; [ -s .claude/.next-action ] && sentinel_file=".claude/.next-action"
open_n="$(grep -c '^- \[ \]' TASKS.md 2>/dev/null || true)"; open_n="${open_n:-0}"
done_n="$(grep -c '^- \[x\]' TASKS.md 2>/dev/null || true)"; done_n="${done_n:-0}"

# No-op guard: nothing loop-shaped on disk -> stay silent (zero token cost).
if [ -z "$env_file" ] && [ -z "$sentinel_file" ]; then exit 0; fi

command -v python3 >/dev/null 2>&1 || exit 0
python3 - "$env_file" "$slug" "$stage" "$status" "$sentinel_file" "$open_n" "$done_n" "$event" <<'PY'
import json, sys
env_file, slug, stage, status, sentinel_file, open_n, done_n, event = sys.argv[1:9]
lines = ["[brainstorm-toolkit reseed] Context was compacted/cleared mid-loop. Durable state lives on disk:"]
if env_file:
    lines.append(f"- active run: {env_file} (slug {slug}, stage {stage}, status {status})")
if sentinel_file:
    try:
        with open(sentinel_file) as f:
            s = f.read(8000).strip()   # bounded read — never pass file contents via argv
    except Exception:
        s = ""
    if s:
        lines.append("- next action (.claude/.next-action):\n" + s)
lines.append(f"- queue: TASKS.md ({open_n} open / {done_n} done)")
lines.append("Resume from the envelope/sentinel on disk, not from memory. Do not re-run stages already "
             "marked passed. If unsure where you are, run /status.")
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": event or "SessionStart", "reloadSkills": True, "additionalContext": "\n".join(lines)}}))
PY
exit 0
