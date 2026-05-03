---
name: brainstorm-deep
description: >
  Clarification-heavy ideation skill for ambiguous or high-stakes ideas.
  Runs a three-pass loop (understand → saturate-by-questioning →
  plan-with-alternates) and dispatches perspective-frame sub-agents
  (inversion, pre-mortem, steelman, adjacent-reuse) before plan freeze.
  Output ends with an explicit expectation contract block. Invoke when
  the user says /brainstorm-deep, "I'm not sure what I want", "this is
  vague", "high stakes", "really important to get right", or asks for
  more rigor than /brainstorm provides. Use /brainstorm for fast cases
  and /brainstorm-team for autonomous multi-persona product strategy.
argument-hint: "[topic] [--fast] [--frames <list>] [--ambition conservative|default|ambitious]"
metadata:
   brainstorm-toolkit-applies-to: claude copilot
---

# /brainstorm-deep — clarification-heavy ideation

The third member of the brainstorm family. Position:

| Skill | Use when |
|---|---|
| `/brainstorm` | Fast conversational ideation, low ambiguity, you trust the model's first read |
| `/brainstorm-deep` | High ambiguity OR high stakes; misalignment risk dominates cost |
| `/brainstorm-team` | Multi-persona product strategy doc, autonomous, long-form output |

The differentiator vs `/brainstorm` is **structured saturation**: questions are asked in batches drawn from a fixed 9-bucket typology, with an explicit stop rule (saturation OR 3-batch ceiling). The differentiator vs `/brainstorm-team` is that the perspective layer here is **frames against the same idea** (inversion, pre-mortem, steelman, adjacent reuse) rather than role-based personas writing separate sections.

## When this skill triggers

- User types `/brainstorm-deep` or `/brainstorm-deep <topic>`
- User says "I'm not sure what I want", "this is vague", "high stakes", "really important to get right"
- User asks for more rigor than `/brainstorm` provided on a previous run
- A previous `/brainstorm` produced a plan the user is uncertain about — this skill can re-engage on the same topic with deeper clarification

## How it works

### Step 0: Enter Plan mode

Switch to **Plan mode** (`EnterPlanMode` on Claude Code; equivalent step-by-step approval flow on Copilot). This skill is conversational by design — implementation is for `/sdlc` later.

### Pass 1 — Understand (≤2 minutes of chat)

Goal: agree on what we're solving **before** asking clarifying questions. Many "this missed the mark" outcomes come from the model anchoring on the wrong interpretation, not from too few clarifications.

1. **Restate the ask** in your own words. Use 2–3 sentences max.
2. **Surface 2–3 plausible interpretations** of what the user meant. Phrase them as concrete differences, not paraphrases. Example:
   - *Interpretation A*: build feature X as a standalone module.
   - *Interpretation B*: extend existing module Y to cover the X case.
   - *Interpretation C*: refactor Y so X falls out as a side-effect.
3. **Ask the user to pick** (or "none — here's what I really mean").
4. Capture the agreed framing as a "What we're solving" block at the top of the working notes. This block becomes the seed of the expectation contract in Pass 3.

If the user's pick reveals a much smaller or much larger scope than implied by the prompt, **flag it explicitly**: "this is narrower than I expected — should we use `/brainstorm` instead?" or "this is broader than I expected — `/brainstorm-team` may serve you better." Don't redirect silently.

### Pass 2 — Saturate by questioning (max 3 batches)

Goal: ask enough clarifications that further questions would not change the design. Stop the moment that's true. **`--fast` skips this pass entirely** — one batch only, then proceed to Pass 3.

1. **Read `templates/question-typology.md`** for the 9 buckets:
   Scope, Success, Failure, Audience, Priors, Trade-offs, Constraints, Reversibility, Resemblance.
2. **Pick the 3–5 buckets the ask is *most ambiguous on*.** Do not ask all 9 — that's exhausting and signals the model didn't read the prompt. Justify the pick to the user in one line: "I'm asking about Scope, Failure, and Reversibility because those are where I'd most likely build the wrong thing."
3. **Ask one batch of 3–5 questions.** Wait for answers. Never ask one question at a time — batches of 3–5 keep the loop fast.
4. **Self-score after each batch**: "what do I still not know that would *change the design*?" If the answer is "very little," proceed to Pass 3. If "a lot," ask another batch (max 3 total batches).
5. **Anti-ratholing rule**: track scope creep across batches. If the user adds new requirements in 2+ rounds, surface explicitly:
   > "We've added N requirements over M rounds — pause options: (a) decompose into multiple plans, (b) commit to current scope, (c) park the new requirements as follow-ups."

   Do not silently absorb scope creep into a single ballooning plan.
6. **Hard ceiling: 3 batches.** After the third batch, proceed to Pass 3 even if you'd love to ask more. The friction cost dominates beyond that point.

### Pass 3 — Perspective frames + plan with alternates

Goal: stress-test the agreed framing from multiple angles, then produce a plan the user can act on.

1. **Read `templates/perspective-frames.md`** for the 8 available frames.
2. **Pick frames.** Defaults: `inversion`, `pre-mortem`, `steelman`, `adjacent-reuse`. `--frames <comma-list>` overrides.
3. **Dispatch in parallel.** In a **single message**, fire one Agent tool call per frame with `subagent_type: "general-purpose"`, **Sonnet** model. Each agent gets the agreed framing, the user's clarified answers, and the frame's prompt from the template. Each returns ≤300 words.
4. **Synthesize.** Frames go in their own labeled section in the plan (`## Perspective passes`); they inform the design but do not override user intent. If a frame's output contradicts a user clarification, surface the conflict for the user to resolve, don't silently side with the agent.
5. **Produce three plan variants** at different ambition levels:
   - **Conservative** — minimum viable, narrowest scope, smallest blast radius.
   - **Default** — what the conversation has been pointing at.
   - **Ambitious** — what we'd build if budget weren't a constraint.

   Each variant: 1-paragraph summary + 5–10 bullet implementation outline + estimated effort + key risks. The user picks; the picked variant becomes the body of the plan file.
6. **`--ambition <level>`** collapses to a single variant up front. Useful for follow-up runs once the user knows what they want.

### Step 4 — Expectation contract (mandatory output block)

Every plan file produced by this skill **must end** with this block:

```
## Expectation contract

**What you said**
<verbatim ask, lightly edited for grammar>

**What I heard**
<restatement of the agreed framing from Pass 1, plus any reframing
that emerged in Pass 2>

**What I'm NOT doing**
- <explicit non-goal 1>
- <explicit non-goal 2>
- ...

**How we'll know it worked**
- <observable success signal 1>
- <observable success signal 2>
- ...
```

`/sdlc` and `/task` can grep this block to ground their own work. Plans without this block fail acceptance and the skill should refuse to write them.

### Step 5 — Write the plan file

Write to `plans/brainstorm-deep-<topic-slug>.md`. Slug is derived from the user's topic the same way `/brainstorm` does it. Same naming convention so downstream `/sdlc <plan>` consumption is uniform.

## Args

- **`<topic>`** (optional) — if absent, ask in Pass 1.
- **`--fast`** — skip Pass 2 entirely (one batch of clarifying questions max). Useful when the user knows the skill and wants only the perspective-frame pass.
- **`--frames <list>`** — comma-separated frame names from the typology file. Default: `inversion,pre-mortem,steelman,adjacent-reuse`.
- **`--ambition <level>`** — `conservative` / `default` / `ambitious`. Skips the 3-variant output and produces only that level.

## Rules

- **Plan mode only for the conversational passes.** Sub-agent dispatch in Pass 3 happens after Plan mode exits and the user has approved the framing.
- **Batches of 3–5 questions, never one at a time.**
- **3-batch ceiling, no exceptions.** If you reach it and still feel uncertain, say so out loud and proceed anyway — that's a useful signal to the user.
- **Sub-agents return ≤300 words each.** Frame agents are punchy stress-tests, not essays.
- **Frames inform, don't override.** User intent wins ties.
- **No expectation contract → no plan write.** This block is the misalignment-catching net; without it the skill loses its differentiator.
- **`--fast` is the eject hatch, not the default.** If users start passing it every time, the skill's depth is wrong for them and they should be using `/brainstorm`.

## When to redirect to a sibling skill

- Ask is small, well-scoped, low-stakes → `/brainstorm`
- User wants competitive analysis or a multi-persona team to write separate sections → `/brainstorm-team`
- User already has a clear PBI in mind and just wants it written up → `/pbi` (Phase 1D)
- Ask is "audit the existing X for issues," not "design something new" → `/repo-health` or `/dead-code-review`

## Subagent usage summary

| Step | Subagents | Model | Count |
|---|---|---|---|
| Pass 1, Pass 2 | none — main context window | — | 0 |
| Pass 3 frame stress-test | yes — parallel single-message dispatch | Sonnet | 3–4 (defaults: 4) |

Per the model/cost reference table, this skill costs roughly $0.20–0.40 per run at 2026 list pricing — comparable to `/brainstorm --vet light`. The cost is dominated by the frame agents in Pass 3; Passes 1 and 2 are pure conversation.

## Cross-tool notes

- **Claude Code**: full skill works as designed. Plan mode + parallel agent dispatch.
- **GitHub Copilot**: Plan mode is unavailable; treat each pass as a step requiring the user's "continue" approval. Frame stress-tests run sequentially rather than in parallel — slightly slower, same output. Mark `metadata.brainstorm-toolkit-applies-to: claude copilot` and a `copilot/skills/brainstorm-deep/` overlay can be added later if the sequential version diverges enough to warrant it.

## Output

A single plan file at `plans/brainstorm-deep-<topic-slug>.md` containing:

```
# Brainstorm-deep: <topic>

## What we're solving
<agreed framing from Pass 1>

## Clarifications captured
<bulleted Q-A from Pass 2 batches>

## Perspective passes
### Inversion
<agent output>

### Pre-mortem
<agent output>

### Steelman the opposite
<agent output>

### Adjacent reuse
<agent output>

## Plan variants
### Conservative
<summary + outline + effort + risks>

### Default (recommended)
<summary + outline + effort + risks>

### Ambitious
<summary + outline + effort + risks>

## Selected variant
<which variant the user picked>

## Expectation contract
<the four-block contract — mandatory>
```

That's the contract. `/sdlc <plan>` reads this file as input the same way it reads `/brainstorm`'s output.
