# Gap 3 — The seam channel is too weak to carry a loop

**Gap:** the only machinery connecting one skill's end to the next skill's start is the
`.claude/.next-action` sentinel + Stop hook. It was designed as a *hint* — and as a hint it's
well built (fire-once, never blocks, cross-tool). But the moment the goal becomes *looping*,
every design choice that makes it a good hint makes it a bad seam.

**Levers:** (a) make the channel multi-slot and machine-readable, (b) make the pending next
action durable in the state envelope, (c) an opt-in **auto-continue** mode that turns the hint
into execution — the cheapest path to "the system loops" that exists in the current
architecture.

---

## Audit of the channel as built

Facts, from `scripts/hooks/next-action.sh`, `setup.sh`, and the skills that write the file:

| Property | Behavior today | Consequence for a loop |
|---|---|---|
| **Capacity** | one line, one file (`awk 'NF{print; exit}'` — first non-empty line wins) | two skills finishing in one turn can't both hand off |
| **Contention rule** | "only if absent — the outermost run wins" (`/sdlc` gotcha seam, `/task`) | the gotcha capture seam and the pipeline handoff **compete for the same slot**; whichever writes first silently suppresses the other |
| **Lifetime** | fire-once: printed at the next Stop, then deleted — whether or not anyone acts on it | walk away after `/brainstorm`, come back tomorrow: the hint fired into an empty room and is gone; the plan sits orphaned (only `/next` — gap 1 — would rediscover it) |
| **Consumer** | the *human's eyes*. `systemMessage` is informational; nothing executes the command | every loop iteration costs one human keystroke-and-decision |
| **Format** | a raw command string | no source, no priority, no expiry, no "requires confirm" bit — an auto-continue consumer couldn't safely act on it |
| **Durability** | gitignored (correctly — it's local runtime state) | fine; but it is also the *only* record of the pending handoff — nothing in the envelope knows a next action was proposed |
| **Cross-tool** | Claude + Copilot get the Stop hook; **Codex gets nothing** — skills must remember to also print `Next: …` inline | one of three runtimes runs the seam on prose discipline alone |

Also worth naming: the hook itself is deliberately dumb (pure file read, no model, `exit 0`
always) and its header documents a sharp two-kinds design — *transient* hints (fire-once) vs
*condition-derived* warnings (recomputed every Stop while true). That taxonomy is exactly
right; the problem is that a pending handoff is filed under "transient" when it is really a
**condition** ("this plan has no run yet") that should persist until acted on.

## Lever A — multi-slot, structured sentinel

Replace the single line with an append-friendly, still-trivially-parsable format — one JSON
object per line:

```
{"cmd": "/gotcha [Testing] eval fixture …", "source": "sdlc", "confirm": false}
{"cmd": "/sdlc plans/brainstorm-radius.md", "source": "brainstorm", "confirm": false}
{"cmd": "/sdlc plans/big-feature.md", "source": "brainstorm", "confirm": true}
```

- Hook prints all pending lines (`Next: …`, one per line), keeps fire-once semantics per line.
- Kills the contention rule: gotcha seam and pipeline handoff coexist instead of racing.
- `confirm: true` is the machine-readable version of "/sdlc opens a PR — ask first", which an
  auto-continue consumer (Lever C) must honor and a human reader can ignore.
- Backward compat: a line that isn't JSON is treated as a bare command (today's format).
- Cost: ~15 lines in `next-action.sh`, plus updating the 6 writer sites (the echo one-liners in
  `/brainstorm`, `/task`, `/sdlc`, `/repo-health` + overlays — three-way-sync applies).

## Lever B — the pending handoff lives in the envelope, not only the sentinel

Add an optional, additive `next_action` field to `run.json` (and to the plan-side world via a
convention: a plan with no envelope *is itself* the pending action — `/next` already treats it
that way). Then:

- The Stop hook's existing **condition-derived** section can warn "1 plan with no pipeline
  run" the same persistent way it warns about stale runs — the handoff survives the fired
  sentinel, session death, and even a different machine (envelope is local, but the plan file
  is committed; the *condition* is recomputable from tracked files).
- `/next` and `/sdlc-status` get the pending handoff for free.

This is the "the loop's program counter should live in files, not chat context" fix. Schema
change is additive; `state-schema.md` gets one field.

## Lever C — auto-continue (the hint becomes the loop)

Claude Code Stop hooks are not limited to `systemMessage`: a Stop hook may return
`{"decision": "block", "reason": "…"}`, which **prevents the stop and feeds `reason` back to
the model as the next instruction**. That one capability is the difference between "the system
prints what it would do next" and "the system does it":

```
skill finishes → writes sentinel → Stop fires → hook (auto-continue mode) returns
decision:block, reason:"Continue with: /sdlc plans/…" → the session executes it →
that skill finishes → writes the next sentinel → …
```

This is the cheapest genuine loop available in the current architecture — no daemon, no
scheduler, no new orchestrator process; the session *is* the loop and the sentinel is the
program counter.

**Guardrails (non-negotiable, learned from the soft-stop tier's own philosophy):**

1. **Opt-in knob**, e.g. `project.json` `pipeline.auto_continue: true` — default off. The hook
   stays print-only unless the consumer explicitly turned the loop on.
2. **Never auto-continue a `confirm: true` action** (i.e., never `/sdlc`/anything that writes
   git history) — those always degrade to today's printed hint. Same asymmetry as everywhere
   else in the toolkit.
3. **Chain budget**: a counter in the sentinel line (`"hops": 3`) decremented per auto-continue;
   at 0, print instead. A runaway brainstorm→pipeline→gotcha→… chain must self-limit exactly
   like the 3-iteration fix budget does.
4. **Codex/Copilot degradation stated honestly**: Copilot's Stop hook contract would need
   verification for a block-equivalent; Codex has no hook at all — on those runtimes
   auto-continue simply doesn't exist and the printed hint remains the seam. This is a
   Claude-only enhancement in exactly the sense `CLAUDE.md` rule 2 anticipates.

## Lever D — parity and honesty fixes (small, do regardless)

- **Codex inline fallback is under-specified**: only the gotcha seam mentions printing
  `Next: …` inline on Codex. `/brainstorm`'s pipeline handoff (the most important sentinel in
  the toolkit) says nothing about Codex — on that runtime the handoff silently vanishes. One
  sentence in the canonical skill + codex overlay fixes it.
- **Peek vs consume**: any new reader (`/next`) must *peek* at the sentinel; only the hook
  deletes. Write that down in the hook header, which is currently the only spec the sentinel
  has — better: give the seam its own short `docs/SEAM.md` contract page once levers A–C
  change its shape (it will then be referenced from 5+ files).
