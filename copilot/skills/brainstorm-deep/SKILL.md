---
name: brainstorm-deep
description: >
  Clarification-heavy ideation skill for ambiguous or high-stakes ideas.
  Runs a three-pass loop (understand → saturate-by-questioning →
  plan-with-alternates) and runs perspective-frame stress-tests
  (inversion, pre-mortem, steelman, adjacent-reuse) sequentially before
  plan freeze. Output ends with an explicit expectation contract block.
  Invoke when the user says /brainstorm-deep, "I'm not sure what I
  want", "this is vague", "high stakes", or asks for more rigor than
  /brainstorm provides. Copilot overlay — sequential where Claude runs
  parallel, no plan-approval primitive (the user steers each pass via
  normal chat).
argument-hint: "[topic] [--fast] [--frames <list>] [--ambition conservative|default|ambitious]"
metadata:
   brainstorm-toolkit-applies-to: copilot
---

# /brainstorm-deep — clarification-heavy ideation (Copilot overlay)

Same three-pass design as the Claude version, adapted to Copilot's runtime: no Plan-mode primitive, no parallel sub-agent dispatch. Each pass is a step the user can steer mid-flight via chat.

| Skill | Use when |
|---|---|
| `/brainstorm` | Fast conversational ideation, low ambiguity |
| `/brainstorm-deep` | High ambiguity OR high stakes; misalignment risk dominates cost |
| `/brainstorm-team` | Multi-persona product strategy doc |

## When this skill triggers

- User types `/brainstorm-deep` or `/brainstorm-deep <topic>`
- User says "I'm not sure what I want", "this is vague", "high stakes", "really important to get right"
- User asks for more rigor than `/brainstorm` provided

## Pass 1 — Understand (≤2 minutes of chat)

Goal: agree on what we're solving before asking clarifying questions.

1. Restate the ask in your own words (2–3 sentences).
2. Surface 2–3 plausible interpretations, phrased as concrete differences (not paraphrases).
3. Ask the user to pick (or "none — here's what I really mean").
4. Capture the agreed framing as a "What we're solving" block at the top of the working notes.

If the user's pick reveals a much smaller or much larger scope than implied by the prompt, **flag it explicitly** — don't redirect silently.

## Pass 2 — Saturate by questioning (max 3 batches)

Goal: ask enough clarifications that further questions would not change the design. **`--fast` skips this pass entirely** — one batch of clarifying questions, then proceed.

1. Read `templates/question-typology.md` for the 9 buckets:
   Scope, Success, Failure, Audience, Priors, Trade-offs, Constraints, Reversibility, Resemblance.
2. Pick the 3–5 buckets the ask is *most ambiguous on*. Justify the pick to the user in one line.
3. Ask one batch of 3–5 questions. Wait for answers. Never one-at-a-time.
4. Self-score: "what do I still not know that would change the design?" If "very little," proceed. If "a lot," ask another batch (max 3 total).
5. **Anti-ratholing**: track scope creep. If new requirements appear in 2+ rounds, surface explicitly: "we've added N requirements over M rounds — pause options: decompose, commit to current scope, or park as follow-ups."
6. Hard ceiling: 3 batches.

## Pass 3 — Perspective frames (sequential) + plan with alternates

Goal: stress-test from multiple angles, then produce an actionable plan.

1. Read `templates/perspective-frames.md` for the 8 available frames. Defaults: `inversion`, `pre-mortem`, `steelman`, `adjacent-reuse`. `--frames <list>` overrides.
2. **Run frames sequentially.** For each selected frame:
   - Construct a stress-test prompt using the frame's "Intent" + the bolded prompt in the template + the agreed framing + clarification answers.
   - Run it as a single chat turn. Capture output (≤300 words per frame).
   - Move to next frame.
3. Synthesize. Frames go into a `## Perspective passes` section, one subsection per frame, in declared order. Frames inform the plan; user intent wins ties.
4. Produce **three plan variants**:
   - **Conservative** — minimum viable, narrowest scope, smallest blast radius.
   - **Default** — what the conversation has been pointing at.
   - **Ambitious** — what we'd build if budget weren't a constraint.

   Each variant: 1-paragraph summary + 5–10 bullet implementation outline + estimated effort + key risks.
5. **`--ambition <level>`** collapses to a single variant up front.

## Step 4 — Expectation contract (mandatory output block)

Every plan file produced by this skill **must end** with:

```
## Expectation contract

**What you said**
<verbatim ask, lightly edited for grammar>

**What I heard**
<restatement of agreed framing from Pass 1, plus any reframing from Pass 2>

**What I'm NOT doing**
- <explicit non-goal 1>
- <explicit non-goal 2>

**How we'll know it worked**
- <observable success signal 1>
- <observable success signal 2>
```

Plans without this block fail acceptance — refuse to write them.

## Step 5 — Write the plan file

Write to `plans/brainstorm-deep-<topic-slug>.md`. Same naming convention as `/brainstorm` so downstream `/sdlc <plan>` consumption is uniform.

## Args

- **`<topic>`** (optional) — if absent, ask in Pass 1.
- **`--fast`** — skip Pass 2 entirely (one batch of clarifying questions max).
- **`--frames <list>`** — comma-separated frame names from the typology file. Default: `inversion,pre-mortem,steelman,adjacent-reuse`.
- **`--ambition <level>`** — `conservative` / `default` / `ambitious`. Skips the 3-variant output.

## Rules

- Batches of 3–5 questions, never one at a time.
- 3-batch ceiling, no exceptions.
- Each frame ≤300 words.
- Frames inform; don't override user intent.
- No expectation contract → no plan write.
- `--fast` is the eject hatch, not the default.

## When to redirect

- Ask is small, well-scoped, low-stakes → `/brainstorm`
- User wants competitive analysis or multi-persona separate sections → `/brainstorm-team`
- User has a clear PBI in mind → `/pbi` (Phase 1D)
- "Audit the existing X for issues" → `/repo-health` or `/dead-code-review`

## Cost note

Sequential frame stress-tests cost similar tokens to the Claude parallel version (4 × ~5k input + 300-word output ≈ 20–25k tokens). Latency is higher because they're serialized — that's the Copilot tradeoff until parallel sub-agent primitives ship.
