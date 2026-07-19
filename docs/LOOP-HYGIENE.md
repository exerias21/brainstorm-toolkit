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

| **Copilot** | — | — | No compaction/session hook event exists. Use the batch-handoff escalation below. |

The reseed script reads `.hook_event_name` from stdin and echoes it back as `hookEventName`, and reads the trigger tolerantly (`.source // .trigger`), so one script serves both events/tools correctly.

## Can the loop compact the main session itself, mid-run? No.

There is **no supported way** for a hook, skill, or the agent to *trigger* a `/compact` mid-session on
either tool — so the toolkit does **not** auto-shrink a mid-range orchestrator session. That's also by
design: you don't want a reset dropping live working context in the middle of a single plan (the natural,
safe reset point is a *completed-item boundary*, after state is flushed to disk — not a size threshold
that can fire anywhere). As of mid-2026:

- **A hook can't trigger compaction.** `PreCompact` is gate-only (blocks/observes an already-triggered
  compaction; never initiates one). And no hook event carries token counts, so a hook can't even detect
  "context is large."
- **The agent can't invoke `/compact` itself.** `/compact` is explicitly excluded from what the `Skill`
  tool may run (the old `SlashCommand` tool was folded into `Skill`). The tracking request
  (claude-code #19877) is open, unresolved, and not on the roadmap.
- **The threshold can't be scoped to the main session.** `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` applies to the
  main conversation *and every subagent*; Codex's `model_auto_compact_token_limit` is global config only.
- **The one exception — the Agent SDK.** An SDK loop *driver* can dispatch `/compact` between turns as a
  `query({continue:true})` prompt, so "compact after X items" is buildable there (subagents untouched,
  since you compact the main history explicitly). That's a different execution model from the hook-driven
  interactive CLI the skills run under — use the SDK if you truly need programmatic self-compaction.

**What the reseed hook does, then:** it makes whatever compaction *does* happen lossless — Claude's native
auto-compaction near the window max, or a manual `/compact`/`/clear` — by re-pointing at on-disk state. It
cannot *cause* a compaction. So on a large-window model (Sonnet 5 ~967k, Opus 1M) a `--queue` run that
stays well under the ceiling simply never compacts and the hook stays dormant (zero cost). To actually cap
context on such a run, use batch handoff below — not a threshold.

### Last-resort knob: lower the native auto-compact threshold (NOT recommended)
You *can* make the native auto-compaction fire earlier via config, but it's the wrong shape here and stays
**off by default**: it triggers on **size**, so it can fire **mid-plan** (dropping live context), and it
**also lowers subagent thresholds** (no way to exempt them) — a deep fix-loop worker can get compacted
mid-task. Only reach for it if you've measured a win.
- **Claude:** `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` (1–100); on **Opus** it's a silent no-op unless you also
  set `CLAUDE_CODE_AUTO_COMPACT_WINDOW`. `DISABLE_AUTO_COMPACT` turns auto-compaction off.
- **Codex:** `model_auto_compact_token_limit` (top-level config.toml only; clamped ≤90%; no env, no off-switch).

## The real lever for a long queue: batch handoff (docs-only, not shipped)

For a genuinely long `--queue` run, don't fight the main session's growth or try to force compaction —
**bound it by re-launching**. Run a batch of **X** items in one process, then hand off to a **fresh
process** for the next batch. Clean context every X items; state handed off via disk
(`.claude/pipeline/<slug>/run.json` + `.next-action` + `TASKS.md`), which the toolkit already externalizes,
so a cold process reads its position at startup — the reseed hook isn't even needed here. Trigger on
**item count (X)**, not size: the boundary is clean (never mid-plan) and measurable (you can't read live
context size from a script anyway).

**Batching beats fresh-process-*per-item*.** Per-item re-pays the full CLAUDE.md/skills/plugin baseline
*every* item (`N × baseline`); per-batch amortizes it (`N/X × baseline`) while still capping growth at
~X items' worth. Tune X to your per-item footprint. This is the toolkit's **Lever-C** stance — a
self-relaunching headless loop is a **deployment pattern you opt into**, not a shipped skill/daemon (same
reasoning as `docs/AUTONOMOUS-DISCOVERY.md`) — and it carries real operational baggage (headless auth,
permission mode, claude.ai MCP connectors don't load headless, detachment UX). Worth it for an overnight
backlog, not a handful of items.

It reuses the existing `--queue [N]` cap (N = the per-batch size): each fresh process runs `--queue X`,
parks when it hits X, and the runner relaunches until the queue drains.

```sh
# loop-runner.sh — opt-in, unattended; NOT installed by setup.sh. Cross-tool via $ENGINE.
# Each iteration is a FRESH process that runs ONE batch of X items, then exits → clean context per batch.
#   ENGINE='claude -p --permission-mode dontAsk --max-budget-usd 5'  (dontAsk, NOT --dangerously-skip-permissions)
#   ENGINE='codex exec -m gpt-5.6-terra --ephemeral --json'          (--ephemeral: don't persist the rollout)
BATCH=5   # X — items per fresh process; tune to per-item context footprint
set -eu
while grep -qE '^\- \[ \] ' TASKS.md; do            # pending rows remain?
  $ENGINE "Run /sdlc-lite --queue $BATCH. Durable state is under .claude/pipeline/; \
read your position from disk, do not resume any prior session." || { echo "batch failed — stopping"; break; }
done
```

Never `resume`/`--continue` — both tools reload the *full* prior transcript on resume, defeating the
clean-context goal. Pass the state **path** in the prompt instead.

> Note: Codex's own "Goal Mode" guidance recommends the *opposite* — keeping related work in one growing
> session. That inherits every limitation above and doesn't solve context bloat; it's OpenAI's default,
> not a fix for this problem.

## See also
- `docs/SEAM.md` — the `.next-action` seam the Stop hook surfaces / the reseed hook points at.
- `docs/AUTONOMOUS-DISCOVERY.md` — the sibling docs-only "Claude as a scheduled worker" pattern.
- `docs/gap-analysis/04-BACKLOG-LOOP.md` — Lever C (unattended worker) rationale.
