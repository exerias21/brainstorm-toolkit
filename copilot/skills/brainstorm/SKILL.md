---
name: brainstorm
description: >
  Interactive brainstorming and feature ideation skill. Guides the user through structured creative
  exploration: clarifying the idea, exploring codebase context, generating multiple approaches,
  evaluating tradeoffs, and producing a concrete action plan. Use this skill whenever the user says
  /brainstorm, mentions "brainstorm", "let's think through", "I have an idea", "what if we",
  "how should we approach", "let's explore", or otherwise wants to ideate on a feature, improvement,
  or architectural change before jumping into code. This is the conversational planning companion —
  for heavy autonomous multi-agent product research, use /brainstorm-team (Claude Code only).
argument-hint: "[topic] - optional: brief description of what you want to brainstorm"
disable-model-invocation: true
metadata:
  brainstorm-toolkit-applies-to: copilot
---

# Brainstorm (Copilot Edition)

An interactive ideation skill that walks through a structured brainstorming process *with* the
user. This is conversational — think out loud, ask questions, and iterate on ideas together with
the user before producing an implementation plan.

## When This Skill Triggers

- User says `/brainstorm` or `/brainstorm [topic]`
- User mentions brainstorming, ideating, or exploring an idea
- User says things like "what if we...", "I have an idea for...", "how should we approach...",
  "let's think through...", "let's explore..."
- User wants to plan a feature but isn't ready to commit to a specific approach yet

## How It Works

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

Before generating ideas, ground yourself in what already exists. Search the codebase to
understand:

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

If `project.json` doesn't exist or has no `modules` key, skip this step.

### Step 4: Generate Approaches

Produce 2-4 distinct approaches. Each approach should have:

- **A name** — something memorable, not "Option A"
- **The core idea** — one sentence
- **How it works** — 3-5 bullet points covering the user-facing flow
- **What it builds on** — existing code/infrastructure it leverages
- **Tradeoffs** — what you gain and what you give up
- **Effort** — rough size (Small / Medium / Large)

Vary the approaches meaningfully. Don't just offer "do more" vs "do less" — explore genuinely
different angles. Include at least one approach that's simpler than the user probably expects.

### Step 5: Evaluate Together

After presenting approaches, pause and let the user react. They might:
- Pick one approach outright
- Want to combine elements from multiple approaches
- Have new ideas sparked by what they see
- Want to dig deeper into one approach's tradeoffs

Follow their lead. This is a conversation, not a presentation. If they're leaning toward an
approach, help them stress-test it: "The one thing I'd want to think through is..." or
"That approach is strong — the main risk is..."

### Step 6: Produce the Action Plan

Once the user has converged on a direction, produce a concrete plan:

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

### Step 7: Validate the Plan

Before moving to implementation, run through this checklist (either yourself or surface it
to the user for review):

**Plan Validation Checklist:**
- [ ] All referenced files/patterns still exist and are accurate
- [ ] No missing steps or dependencies between steps
- [ ] Effort estimate is realistic for the stated scope
- [ ] Existing utilities or patterns were not missed
- [ ] GOTCHAS.md has been checked for relevant pitfalls
- [ ] Cross-module touchpoints were confirmed where relevant
- [ ] Implementation steps are concrete and bounded, not vague

If the plan passes, move to Step 8. Otherwise, revise it with the user.

### Step 8: Next Steps

Offer the user the next steps:

1. **Implement now** — transition into building directly in this session
2. **Use `/task`** — pick a single bounded task from the plan and execute it with TDD
3. **Save for later** — the plan persists at `plans/brainstorm-[topic-slug].md`
   and task items are already in `TASKS.md`
