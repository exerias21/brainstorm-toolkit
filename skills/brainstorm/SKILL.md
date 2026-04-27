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
argument-hint: "[topic] [--vet light|deep|ultra|none] - optional: topic + multi-agent vet mode"
metadata:
  brainstorm-toolkit-applies-to: claude copilot
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

## Subagent Usage During Brainstorming

The conversational loop stays in the **main context window** — you and the user share
one thread. Read files, grep code, and think out loud directly during Steps 1–3, 5, and 6.

Subagents are used at exactly two points, and both are scoped:

- **Step 4b — Lens Divergence.** Four lateral-thinking lens agents run in parallel to
  push past the obvious. Their outputs land in a clearly-labeled `Wildcards` section so
  you and the user can compare them to the conventional options, not silently absorb them.
- **Step 7 — Validation.** A fresh-context validator stress-tests the finalized plan.

Do not delegate general exploration or ideation to subagents outside these two points.

## How It Works

### Step 0: Enter Plan Mode

Switch to **Plan mode** (`EnterPlanMode`). This is a planning and exploration session, not
an implementation session. You'll think out loud, explore the codebase, generate options,
and iterate with the user to converge on a concrete action plan before any code is written.

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

### Step 4: Generate Approaches (Conventional + Wildcards)

Ideation from a single head converges on the obvious. Run two tracks so the user sees both
what a sensible team would build *and* what lateral thinking would propose.

**Step 4a — Conventional approaches (main context).** Produce 2–3 distinct approaches.
Each has: a memorable name; one-sentence core idea; 3–5 bullets on the user-facing flow;
what existing code it builds on; tradeoffs; effort (S/M/L). Vary meaningfully — UI-first
vs data-model-first vs AI-leaning — and include at least one simpler than expected.

**Step 4b — Wildcards (four lens subagents in parallel).** In a single message, dispatch
four Agent tool calls with `subagent_type: general-purpose`. Each agent receives the user's
seed idea, your Step 2/3 summary, and exactly one lens prompt. Cap each response at 200
words.

1. **First Principles** — strip the idea to its physics. What is the user *actually* trying
   to accomplish at the most basic level? Propose the simplest mechanism that delivers that
   outcome, assuming no prior code exists.
2. **Inversion** — solve the opposite problem. If the goal is X, what would *preventing* X
   look like, and would that be more valuable? What if the core assumption is wrong?
3. **Cross-Domain Analogy** — pick one non-software domain (game designer, biologist,
   musician, logistics planner). Import its patterns; describe the analogous approach.
4. **Constraint Removal** — what if compute / storage / attention / dev time were free and
   infinite? Flip it — what if each were zero? Describe both extremes and what survives.

Each lens returns: name, one-sentence pitch, 3–5 bullets on how it works, tradeoffs, effort
(S/M/L), and one sentence on why this is genuinely different from the conventional options.

**Step 4c — Merge and present.** Use two clear headings: `## Conventional Approaches` (the
2–3 from 4a) and `## Wildcards (Outside-the-Box)` (one entry per lens, tagged by lens name).
Do not silently drop wildcards that seem impractical — the user decides what's practical,
and weak wildcards can still spark a combination with a conventional option.

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
One paragraph summarizing the chosen approach and why. If the direction combines a
conventional option with a wildcard, say so explicitly.

### Implementation Steps
Numbered list of concrete steps, each with:
- What to do
- Which files to create/modify
- Key patterns to follow (reference existing code)

### Cross-Module Touchpoints
- Which other modules this connects to and how

### Open Questions
- Anything that still needs deciding (keep this short)

### Appendix: Alternatives Considered
Preserve every Conventional Approach and Wildcard generated in Step 4 — even the
rejected ones — with a one-line "why not chosen" note. Future sessions (and the user
revisiting later) often pick these back up.
```

**Use the `Write` tool** to save this to `plans/brainstorm-[topic-slug].md` at the
**repo root** (the consumer project's working directory) — NOT under `.claude/`.

This is critical: Plan Mode's internal storage in `.claude/` is transient and
invisible to downstream skills (`/sdlc`, `/flowsim`, `/post-deploy-verify`,
validators). The persistent plan **must** live at
`<repo-root>/plans/<slug>.md`. If the `plans/` directory doesn't exist, create
it first (use a Bash `mkdir -p plans` or include the directory in the Write
target — Write creates parent dirs automatically).

Do this **before** Step 7 (validation) — the validation agent reads the plan
from this path. Do NOT rely on Plan Mode's "approve plan" affordance to
persist the file; that's a separate UX from the on-disk artifact this skill
must produce.

**Also append action items to `TASKS.md`** (at repo root). For each implementation step
that's concrete and bounded enough to stand alone, add a row to the `Active / Pending`
section: `- [ ] (P2) <step title> — plans/brainstorm-[topic-slug].md`. If `TASKS.md`
doesn't exist, create it from `templates/TASKS.md.template` (or with minimal sections).
This gives both Claude's `/status`/`/task` flow and Copilot's TODO workflow a shared
entry point into the brainstorm's output.

### Step 6.5: Multi-agent Vet (mode-gated)

Before the single-agent validator in Step 7, optionally run a multi-lens vet
using the `--vet [light|deep|ultra|none]` flag. Multiple agents catch issues
one validator misses.

**Mode resolution** when `--vet` is not passed explicitly:
- `<5` implementation steps in the saved plan → `none` (skip this step; go
  straight to Step 7).
- `5–15` steps → `light`.
- `>15` steps OR plan has a "Cross-Module Touchpoints" section listing more
  than one module → suggest `deep` to the user; proceed with `light` if
  they decline.
- Plan grep finds keywords (`migration`, `auth`, `secret`, `oauth`,
  `public api`, `deploy`, `rollback`, `prod`) in "Files to change" or
  "Implementation Steps" → suggest `ultra` to the user. These flag
  high-blast-radius plans where Opus-level scrutiny is worth the cost.
- User can always override the suggestion via explicit `--vet <mode>`.

**Mode behavior**:

#### `none`
Skip Step 6.5 entirely. Step 7 (single validator) runs alone.

#### `light` — 3 Haiku agents in parallel
Reuse the three prompts at `skills/sdlc/templates/stage-1.5-sanity-check.md`
(`paths`, `completeness`, `gotchas`) so vetting language is consistent across
skills. Substitute `{plan_file}` = the saved plan path from Step 6 and
`{feature_name}` = the topic slug. Dispatch all three Haiku agents in a single
message. Cost: ~3 small agents, ~30s.

#### `deep` — `light` + 1 Sonnet stress-test agent
After the 3 Haiku agents return, dispatch one Sonnet agent with this prompt:

> Read the plan at {plan_file}. Try to find a way it would fail. Apply
> inversion: assume the plan is wrong, and identify the single most likely
> mode of failure under realistic load, edge cases, or operator error.
> Report under 250 words: name the failure mode, the step that introduces
> it, and a one-line fix.

#### `ultra` — `deep` + 2 Opus agents in parallel
After Sonnet stress-test, dispatch two Opus agents in a single message:

1. **architectural-coherence** (Opus). Prompt:
   > Read the plan at {plan_file} and the project's CLAUDE.md/AGENTS.md.
   > Check whether the plan's structure fits the codebase's existing
   > architecture: layering, abstraction boundaries, naming conventions,
   > module ownership. Flag any contradiction with existing patterns —
   > "the plan works in isolation but violates the established X
   > convention." Cap report at 300 words.

2. **edge-case-divergence** (Opus). Prompt:
   > Read the plan at {plan_file}. For each acceptance criterion,
   > enumerate 3–5 edge cases the plan does NOT explicitly handle:
   > nulls, empty inputs, concurrent writes, partial failures, auth
   > expiry, off-by-one boundaries, etc. Surface "happy-path only"
   > plans. Cap at 400 words.

#### Processing results

1. Collect all vet-mode reports.
2. **If issues found**: surface them to the user. For HIGH-confidence
   findings (`paths` flag a non-existent file; `architectural-coherence`
   flags a layering violation), auto-revise the plan. For lower-confidence
   findings, ask the user to adjudicate.
3. After revisions, save the updated plan back to the same path
   (overwrite — the saved plan is the source of truth).
4. Proceed to Step 7 with the post-vet plan.

### Step 7: Validate the Plan

Spawn a dedicated **validation agent** (via the Agent tool) to read the saved plan with fresh
context and stress-test it against this checklist:

- Are the referenced files/patterns still accurate? (grep/read to verify)
- Are there missing steps or dependencies?
- Does the effort estimate seem realistic given the codebase?
- Are there existing utilities or patterns the plan should reuse but missed?
- Any gotchas from GOTCHAS.md that apply?

Share the validation feedback with the user. If there are issues, revise the plan together.

### Step 8: Exit Plan Mode and Next Steps

Before exiting Plan mode, drop a **next-action sentinel** so the Stop hook
surfaces the recommended follow-up command in the terminal once Claude
finishes responding. The plan file MUST already exist at
`plans/brainstorm-<topic-slug>.md` before writing the sentinel — a sentinel
that points at a missing plan is a bug.

```
# Write a single line to .claude/.next-action with the recommended command:
echo "/sdlc plans/brainstorm-<topic-slug>.md" > .claude/.next-action
```

The Stop hook (installed by `setup.sh` into both
`.claude/settings.json` for Claude Code and `.github/hooks/next-action.json`
for Copilot) reads the file once, prints `Next: <command>` to the user, and
deletes it — so the suggestion fires once, not on every Stop. Skip the
sentinel write if the user explicitly chose "save for later" with no
intent to ship.

Then exit Plan mode (`ExitPlanMode`). Offer the user the next steps:

1. **Implement now** — transition into building directly in this session
2. **Run `/sdlc {plan_file}`** — hand the plan to the automated implementation flow
   (implement → eval → fix loop → test → PR). Best for bounded, well-specified plans.
3. **Save for later** — the plan persists at `plans/brainstorm-[topic-slug].md`

If the plan has clear implementation steps with file paths and acceptance criteria,
recommend option 2 (`/sdlc`). If the plan is exploratory or has ambiguous tradeoffs,
recommend option 1 (manual implementation).

If the current tool supports an explicit planning-mode exit, you may use it here. Otherwise,
just transition conversationally.

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

## Availability By Tool

| Capability | Claude Code | GitHub Copilot |
|---|---|---|
| Brainstorming loop (Steps 1-6) | Yes | Yes |
| Plan generation and TASKS.md output | Yes | Yes |
| Step 4b lens divergence | Yes (4 parallel subagents) | Yes (4 sequential passes) |
| Dedicated fresh-context validation agent | Yes | Manual checklist fallback |
| Dedicated planning-mode UI affordances | Optional enhancement | Not required |

This skill is intentionally distributed to both tools because the main brainstorming value is
shared. Differences: Claude runs the four lenses as parallel Agent calls; Copilot walks them
sequentially in the main context (see the Copilot override). Step 7 uses a dedicated
validation agent on Claude and a manual checklist on Copilot.
