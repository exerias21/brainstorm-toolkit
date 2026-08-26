# Loop context hygiene — keeping long `--queue`/auto-continue runs cheap

Reference doc. **Not shipped by `setup.sh`** into consumers (zero token weight there) — a
maintainer/deployment guide. It explains how the toolkit keeps a long-running loop's token cost
down, what ships to do it, and the escalation for when a single session is still too heavy.

## The problem

The loop skills (`/sdlc --queue`, the L9 auto-continue chain in
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

You **cannot force `/compact` or `/clear`** from a hook/skill/config on any tool, so a policy that
*enforces* "compact at 55%" isn't buildable. But **auto-compaction
already runs on both Claude Code and Codex** near the window limit. The toolkit ships a small hook —
`scripts/hooks/reseed-context.sh` — that makes that auto-compaction **lossless for the loop**: after
a compaction/clear it re-injects a *pointer* to the durable on-disk state (active envelope + sentinel
+ TASKS.md counts) as `additionalContext`, so the orchestrator resumes from files, not from a lossy
summary. It's fail-soft and emits nothing in any repo not running a loop.

### Correction: live context size *is* readable — but measure at the END, not mid-run

An earlier revision claimed "no tool exposes live token usage to a script." Too strong: a hook
is handed `transcript_path`, and the last `usage` row in that JSONL is the context that was on
the wire (`input_tokens + cache_read_input_tokens + cache_creation_input_tokens`). Verified
against a real transcript: `2 + 637769 + 378` -> **638,149 tokens**.

A first attempt used that to warn mid-run at a threshold. **That was wrong**, for three
reasons worth recording so nobody rebuilds it:

1. **Lagging indicator.** By the time the threshold trips, the tokens are spent. It reported
   cost; it never reduced any.
2. **It fired where acting is unsafe.** This very document says the safe reset point is a
   completed-item boundary, never mid-plan. The nag arrived exactly when clearing was the
   wrong move.
3. **It was tuned on the wrong unit.** The audited session was three days and several
   commands. The real unit is *one plan, executed in one fresh session* — the standard
   workflow is to author a plan in one session and execute it in a brand-new one, so context
   never accumulates across that boundary in the first place.

What ships instead is `scripts/hooks/run-cost-report.sh`: at terminal state, once, it prints
turns / average context / peak / cache-read / rough spend. That is a **leading** indicator for
the *next* plan — the only place the number can still change a decision.

**It emits `systemMessage`, not `hookSpecificOutput.additionalContext`.** `systemMessage` is
shown to the human and never enters the model's context, so the report is free. The paid
channel would make a cost report cost tokens, which defeats it. Do not switch it.

**Big runs are not automatically waste.** If the work needs the state, let it run — a 1M window
holds it and cache reads are cheap per token. The waste is *junk* in the orchestrator's
context, not its size: on the audited run, shell traffic (~53%) plus Write/Edit payloads
(~18%) were roughly 71% of it. Delegation (the Stage 2 rule) attacks that; plan size does not.

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

## The real lever for a long queue: batch handoff (opt-in runner)

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

### The shipped runner: `scripts/loop-runner.sh`
The toolkit ships this as an **opt-in script you run yourself** — `setup.sh` copies it into `scripts/`
(with the rest of the tree), but it is **not** a skill, **not** wired to any hook, and **not** a daemon.

```
bash scripts/loop-runner.sh [--queue X] [--fresh yes|no] [--engine claude|codex] [--model M] [--dry-run]
```
- **X (batch size)** resolves: `--queue X` flag > `.claude/project.json` `pipeline.loop.batch_size` >
  `pipeline.loop.max_items` > **5**. (5–10 is the useful range.)
- **`--fresh no`** runs the whole queue in ONE process (no context reset) — for short queues where a
  reset isn't worth the per-process baseline re-pay.
- **`--dry-run`** prints the batch-1 command and exits — preview it before letting it loose.
- Claude uses `claude -p --allowed-tools "Bash,Read,Write,Edit,Glob,Grep,Skill,…"` (auto-approve list,
  mirroring `AUTONOMOUS-DISCOVERY.md`); Codex uses `codex exec --ephemeral --full-auto`. Neither
  `resume`s — both would reload the full prior transcript and defeat the clean context; state is passed
  by **path** in the prompt. Extra engine flags via `LOOP_RUNNER_EXTRA` (e.g. `--max-budget-usd 5`).
- It makes **no git commits** (sdlc hands off a validated tree) and stops if a batch makes no
  progress (parked/blocked items are left for `/status` → `/triage`).

**⚠ It launches headless agents that edit files and run Bash unattended on the current repo** — review
the allowlist and understand the scope before running. This is the Lever-C operational tradeoff; use it
for a genuinely long backlog, not a handful of items.

> Note: Codex's own "Goal Mode" guidance recommends the *opposite* — keeping related work in one growing
> session. That inherits every limitation above and doesn't solve context bloat; it's OpenAI's default,
> not a fix for this problem.

## See also
- `docs/SEAM.md` — the `.next-action` seam the Stop hook surfaces / the reseed hook points at.
- `docs/AUTONOMOUS-DISCOVERY.md` — the sibling docs-only "Claude as a scheduled worker" pattern.
- `docs/gap-analysis/04-BACKLOG-LOOP.md` — Lever C (unattended worker) rationale.
