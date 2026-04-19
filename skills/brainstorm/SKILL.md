---
name: brainstorm
description: >
  Interactive brainstorming and feature ideation skill. Enters Plan mode to guide the user through
  structured creative exploration: clarifying the idea, exploring codebase context, generating multiple
  approaches, evaluating tradeoffs, and producing a concrete action plan. Use this skill whenever the
  user says /brainstorm, mentions "brainstorm", "let's think through", "I have an idea", "what if we",
  "how should we approach", "let's explore", or otherwise wants to ideate on a feature, improvement,
  or architectural change before jumping into code. This is the conversational planning companion —
  for heavy autonomous multi-agent product research, use /brainstorm-team instead.
argument-hint: "[topic] - optional: brief description of what you want to brainstorm"
applies-to: [claude]
---

# Brainstorm

An interactive ideation skill that enters Plan mode and walks through a structured brainstorming
process *with* the user. Unlike `/brainstorm-team` (which launches autonomous agents to produce a
research document), this skill is conversational — it thinks out loud, asks questions, and iterates
on ideas together with the user before producing an implementation plan.

## When This Skill Triggers

- User says `/brainstorm` or `/brainstorm [topic]`
- User mentions brainstorming, ideating, or exploring an idea
- User says things like "what if we...", "I have an idea for...", "how should we approach...",
  "let's think through...", "let's explore..."
- User wants to plan a feature but isn't ready to commit to a specific approach yet

## Important: No Subagents During Brainstorming

All brainstorming, exploration, and ideation happens in the **main context window**. Do NOT
delegate to Explore, Plan, or other subagents during Steps 0-6. Read files, grep code, and
think through options directly — this keeps you and the user on the same page with shared
context. The only agent usage is a dedicated **tester agent** in Step 7 after the plan is
finalized.

## How It Works

### Step 0: Enter Plan Mode

Immediately call `EnterPlanMode` to signal that this is a planning conversation, not an
implementation session. Plan mode gives you freedom to explore the codebase, think through
options, and iterate without the user expecting code changes.

### Step 1: Understand the Seed

Start by understanding what the user wants to explore. If they gave a topic with `/brainstorm`,
use that as the seed. Otherwise, ask.

Ask 2-3 focused clarifying questions. Good questions surface:
- **The "why"** — What problem does this solve? What's the user feeling or frustrated by?
- **The scope** — Is this a quick enhancement or a new module? Who uses it?
- **The spark** — What inspired this? Was there a specific moment or observation?

Don't over-interview. Two good questions beat five mediocre ones. If the user's initial
description is already detailed, skip straight to exploration.

### Step 2: Explore for Context

Before generating ideas, ground yourself in what already exists. Use Glob, Grep, and Read
directly in the main context window to understand:

- **What infrastructure exists** that this idea could build on
- **What patterns the codebase uses** for similar features
- **What data models are relevant** (check migrations, models)
- **What services or endpoints** are nearby

Summarize what you found in 3-5 bullets. The user shouldn't have to read code — translate
what you found into plain language that connects to their idea.

### Step 3: Cross-Module Integration Check

Features rarely live in isolation. Read `.claude/project.json` for a `modules` array
listing this project's major modules (e.g., `["api", "web", "worker"]` or
`["billing", "auth", "notifications"]`). For each listed module, ask:

- Does the idea create data, events, or state that this module owns?
- Does the idea consume or trigger something this module already produces?
- Is there shared infrastructure this idea could reuse here?

Present only the relevant connections (not every module, every time). Frame them as
opportunities, not requirements: "This could also tie into the notifications module
if you wanted email/push alerts."

If `project.json` doesn't exist or has no `modules` key, skip this step and move
directly to Step 4.

### Step 4: Generate Approaches

Produce 2-4 distinct approaches. Each approach should have:

- **A name** — something memorable, not "Option A"
- **The core idea** — one sentence
- **How it works** — 3-5 bullet points covering the user-facing flow
- **What it builds on** — existing code/infrastructure it leverages
- **Tradeoffs** — what you gain and what you give up
- **Effort** — rough size (Small / Medium / Large)

Vary the approaches meaningfully. Don't just offer "do more" vs "do less" — explore genuinely
different angles. One approach might be UI-first, another data-model-first, another might
lean on LLM/AI capabilities. Include at least one approach that's simpler than the user
probably expects — sometimes the best feature is the smallest one.

### Step 5: Evaluate Together

After presenting approaches, pause and let the user react. They might:
- Pick one approach outright
- Want to combine elements from multiple approaches
- Have new ideas sparked by what they see
- Want to dig deeper into one approach's tradeoffs

Follow their lead. This is a conversation, not a presentation. If they're leaning toward an
approach, help them stress-test it: "The one thing I'd want to think through is..." or
"That approach is strong — the main risk is..."

If the user wants deeper architectural analysis on a specific approach, read the relevant
files directly — don't delegate to subagents. Keeping everything in the main context window
means you and the user share the same understanding as you iterate.

### Step 6: Produce the Action Plan

Once the user has converged on a direction, produce a concrete plan. Structure it as:

```markdown
## Brainstorm Result: [Feature Name]

### Direction
One paragraph summarizing the chosen approach and why.

### Implementation Steps
Numbered list of concrete steps, each with:
- What to do
- Which files to create/modify
- Key patterns to follow (reference existing code)

### Cross-Module Touchpoints
- Which other modules this connects to and how

### Open Questions
- Anything that still needs deciding (keep this short)
```

Save this to `plans/brainstorm-[topic-slug].md` so it persists for implementation.

**Also append action items to `TASKS.md`** (at repo root). For each implementation step
that's concrete and bounded enough to stand alone, add a row to the `Active / Pending`
section: `- [ ] (P2) <step title> — plans/brainstorm-[topic-slug].md`. If `TASKS.md`
doesn't exist, create it from `templates/TASKS.md.template` (or with minimal sections).
This gives both Claude's `/status`/`/task` flow and Copilot's TODO workflow a shared
entry point into the brainstorm's output.

### Step 7: Validate the Plan

Once the plan is saved, spawn a dedicated **tester agent** (using the Agent tool) to
stress-test it. This is the ONE place where a subagent is used — to get a fresh pair of
eyes on the plan without the brainstorming context biasing the review.

Give the tester agent:
- The path to the saved plan file (`plans/brainstorm-[topic-slug].md`)
- Instructions to read the plan and the relevant source files it references
- A checklist to evaluate:
  - Are the referenced files/patterns still accurate? (grep/read to verify)
  - Are there missing steps or dependencies?
  - Does the effort estimate seem realistic given the codebase?
  - Are there existing utilities or patterns the plan should reuse but missed?
  - Any gotchas from GOTCHAS.md that apply?

Share the tester's feedback with the user. If there are issues, revise the plan together.

### Step 8: Exit Plan Mode

Call `ExitPlanMode` and offer the user next steps:

1. **Implement now** — transition into building directly in this session
2. **Run `/sdlc {plan_file}`** — hand the plan to the automated pipeline
   (implement → eval → fix loop → test → PR). Best for bounded, well-specified plans.
3. **Save for later** — the plan persists at `plans/brainstorm-[topic-slug].md`

If the plan has clear implementation steps with file paths and acceptance criteria,
recommend option 2 (`/sdlc`). If the plan is exploratory or has ambiguous tradeoffs,
recommend option 1 (manual implementation).

## Tone and Style

- Think out loud. Share your reasoning, not just conclusions.
- Be genuinely curious about the user's ideas — build on them, don't just evaluate them.
- Use plain language. "This would need a new database table" not "This requires a migration
  to add a new relation to the schema."
- Keep momentum. Don't let the conversation stall in analysis paralysis.
- Be opinionated when you have a view, but hold it loosely. "I'd lean toward approach 2
  because... but I could see 3 working if you want tighter [X] integration."

## What This Skill Is NOT

- **Not a research tool** — for competitive research and multi-agent product strategy,
  use `/brainstorm-team`
- **Not a code generator** — this produces plans, not code. Implementation comes after.
- **Not a requirements doc** — keep it conversational and lightweight, not formal.
