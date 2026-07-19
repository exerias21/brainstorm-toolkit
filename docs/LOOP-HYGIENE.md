# Loop context hygiene — keeping long `--queue`/auto-continue runs cheap

Reference doc. **Not shipped by `setup.sh`** into consumers (zero token weight there) — a
maintainer/deployment guide. It explains how the toolkit keeps a long-running loop's token cost
down, what ships to do it, and the escalation for when a single session is still too heavy.

## The problem

The loop skills (`/sdlc-lite --queue`, the L9 auto-continue chain in
`scripts/hooks/next-action.sh`) run job→job in **one orchestrator session**. Prompt-cache reads
are cheap *per token* (~0.1× base) but are still billed **per token of the cached prefix on every
turn** — a 150k-token history costs on the order of $0.075/turn on Opus *just to re-read* before any
work happens. Over the hundreds of turns in an 8h loop that is a cost floor that only grows. Caching
lowers the *rate*, never the token *count*; **only shrinking context reduces real cost.**

## Why the main session is the only accumulator (and why compaction is safe here)

The pipeline's actual work already runs in **isolated subagents** that return only short summaries,
so the **orchestrator session is the sole place context piles up.** And every load-bearing piece of
loop state is **externalized to files**:

- per-item envelope `.claude/pipeline/<slug>/run.json` (stage, status, `next_action`, …),
- the `.next-action` sentinel (`docs/SEAM.md`),
- `TASKS.md` (the queue).

So a **lossy compaction/clear of the orchestrator drops only transient chatter** — the loop
re-reads its position from disk on the next action. "The files are the memory." (Anthropic's own
memory-tool guidance says the same thing: *"ASSUME INTERRUPTION: your context window might be reset
at any moment."*)

The reseed hook is wired to the **session-scoped** event (`SessionStart`/`PostCompact`), distinct
from the `SubagentStart`/`SubagentStop` events, so it targets the orchestrator, not the isolated
subagents — and it's fail-soft regardless.

## What ships: the reseed hook (cross-tool)

You **cannot force `/compact` or `/clear`** from a hook/skill/config on any tool (and no tool exposes
live token usage to a script, so a "compact at 55%" policy isn't buildable). But **auto-compaction
already runs on both Claude Code and Codex** near the window limit. The toolkit ships a small hook —
`scripts/hooks/reseed-context.sh` — that makes that auto-compaction **lossless for the loop**: after
a compaction/clear it re-injects a *pointer* to the durable on-disk state (active envelope + sentinel
+ TASKS.md counts) as `additionalContext`, so the orchestrator resumes from files, not from a lossy
summary. It's fail-soft and emits nothing in any repo not running a loop.

Because tools fire the post-reset event differently, the same script is wired to a different event
per tool:

| Tool | Event wired | Trigger field | Notes |
|---|---|---|---|
| **Claude Code** | `SessionStart`, matcher `compact\|clear` | `.source` (`startup\|resume\|clear\|compact`) | Also sets `reloadSkills: true` (re-scans skill/command dirs — a harmless no-op here since this hook installs no skills; belt-and-suspenders). Shipped via `hooks/hooks.json` (plugin) and `setup.sh` → `.claude/settings.json`. |
| **Codex** | `PostCompact` | `.trigger` (`manual\|auto`) | Codex splits the events — `SessionStart` fires only on start/resume, so the reseed point is the separate `PostCompact` event. Shipped via `setup.sh` → `.codex/hooks.json` (**trust the `.codex/` dir via `/hooks` to activate**). |

The reseed script reads `.hook_event_name` from stdin and echoes it back as `hookEventName`, and reads the trigger tolerantly (`.source // .trigger`), so one script serves both events/tools correctly.
| **Copilot** | — | — | No compaction/session hook event exists. Use the fresh-process escalation below. |

The script tolerates both field names (`jq -r '.source // .reason'`), so one script serves both tools.

## Advanced (manual, OFF by default): lower the auto-compact threshold

Auto-compaction fires near the window limit by default. You *can* make it fire earlier so the
orchestrator's average context stays smaller — but this is **manual, per-environment, and not
shipped as a default** (a blind low value burns tokens compacting sessions that never needed it, and
it's Claude-only). Calibrate it to your observed per-item token footprint (roughly "2–3 queue items'
worth"), not a round number.

- **Claude Code** — env vars (settings.json `env` block or shell):
  - `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` (1–100) lowers the trigger %. **Caveats:**
    - ⚠️ On **Opus** it is a **silent no-op unless you also set `CLAUDE_CODE_AUTO_COMPACT_WINDOW`** (the
      override only affects the proactive-compaction path, which Opus-local doesn't take by default).
      Sonnet 5 (native 1M window, proactive) honors it directly.
    - ⚠️ It **applies to subagents too** — in this 100%-subagent-heavy pipeline a global low value can
      compact a deep fix-loop subagent mid-task. Prefer leaving it default and relying on the reseed
      hook; only lower it if you've measured a win. `DISABLE_AUTO_COMPACT` turns auto-compaction off.
- **Codex** — `config.toml` `model_auto_compact_token_limit` (top-level only — **profile-scoped values
  are silently ignored**; no env var; the value is **clamped to ≤90% of the window**; there is no
  off-switch, and no live token read for any script/hook). A static conservative number is the only
  lever Codex offers.

## Escalation (docs-only, not shipped): fresh process per item

When even a compacted single session is too heavy, don't chain in one session at all — run **each
queue item as a fresh headless process** with clean context, passing the **state-file path** in the
prompt (never `resume` — both tools reload the *full* prior transcript on resume, which defeats the
point). This is the toolkit's Lever-C stance: a queue-driving runner is a **deployment pattern you opt
into**, not a shipped skill/daemon (same reasoning as `docs/AUTONOMOUS-DISCOVERY.md`).

- **Claude:** `claude -p "Run /sdlc-lite <task-id>. State is at .claude/pipeline/<slug>/run.json" --output-format json --permission-mode dontAsk --max-budget-usd <cap>`
  (use `--permission-mode dontAsk`, **not** `--dangerously-skip-permissions`, which hangs on a TTY dialog).
- **Codex:** `codex exec -m <model> --ephemeral --json "Run the sdlc-lite skill for <task-id>. State is at .claude/pipeline/<slug>/run.json"`
  (`--ephemeral` skips persisting the rollout; AGENTS.md + `.agents/skills/` auto-load).

A minimal driver reads the queue and fires one fresh process per item:

```sh
# loop-runner.sh — opt-in, unattended; NOT installed by setup.sh. Cross-tool via $ENGINE.
# ENGINE='claude -p'   or   ENGINE='codex exec -m gpt-5.6-terra --ephemeral --json'
set -eu
while IFS= read -r row; do
  id="${row#*task-}"; id="task-${id%% *}"          # extract task-N from a TASKS.md row
  $ENGINE "Run the sdlc-lite skill for $id. Durable state is under .claude/pipeline/. \
Do not resume any prior session; read state from disk." || { echo "item $id failed — stopping"; break; }
done < <(grep -E '^\- \[ \] ' TASKS.md)             # pending rows, top-down
```

> Note: Codex's own "Goal Mode" guidance recommends the *opposite* — keeping related work in one
> growing session. That inherits every compaction weakness above and does not solve context bloat;
> treat it as OpenAI's default, not a fix for this problem.

## See also
- `docs/SEAM.md` — the `.next-action` seam the Stop hook surfaces / the reseed hook points at.
- `docs/AUTONOMOUS-DISCOVERY.md` — the sibling docs-only "Claude as a scheduled worker" pattern.
- `docs/gap-analysis/04-BACKLOG-LOOP.md` — Lever C (unattended worker) rationale.
