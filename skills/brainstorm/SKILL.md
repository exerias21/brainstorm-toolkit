---
name: brainstorm
description: >
  Interactive brainstorming and feature ideation skill. Guides the user through structured creative
  exploration: clarifying the idea, exploring codebase context, generating multiple
  approaches, evaluating tradeoffs, and writing a concrete action plan to `plans/`. Use this skill whenever the
  user says /brainstorm, mentions "brainstorm", "let's think through", "I have an idea", "what if we",
  "how should we approach", "let's explore", or otherwise wants to ideate on a feature, improvement,
  or architectural change before jumping into code. This is the conversational planning companion —
  for heavy autonomous multi-agent product research, use /brainstorm-team instead.
argument-hint: "[topic] [--vet light|deep|ultra|none] - optional: topic + multi-agent vet mode"
metadata:
  brainstorm-toolkit-applies-to: claude copilot codex
---

# Brainstorm

An interactive ideation skill that walks through a structured brainstorming process *with* the
user. Unlike `/brainstorm-team` (which launches autonomous agents to produce a
research document), this skill is conversational — it thinks out loud, asks questions, and iterates
on ideas together with the user before producing an implementation plan.

**This skill does not use Plan mode.** It writes its plan directly to
`plans/brainstorm-<topic-slug>.md` in the repo. Plan mode's approve-and-proceed gate adds a
second, redundant approval on top of the conversational convergence this skill already does
with the user, and its sandbox blocks the repo-root write that every downstream skill
(`/sdlc-lite`, `/flowsim`, `/repo-health`) depends on. The plan file on disk
is the artifact — not a plan-mode proposal.

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

### Step 0: Set the frame (no Plan mode)

**Do NOT call `EnterPlanMode`.** This skill runs in the normal conversational mode and
persists its output as a file.

Say in one line that this is an exploration session, not an implementation session: you'll
think out loud, explore the codebase, generate options, and iterate with the user to
converge on a concrete action plan before any code is written. Write no implementation code
during Steps 1–7 — the discipline is a working agreement here, not a host-enforced sandbox.

### Step 1: Understand the Seed

Start by understanding what the user wants to explore. If they gave a topic with `/brainstorm`,
use that as the seed. Otherwise, ask.

Ask 2-3 focused clarifying questions. Good questions surface:
- **The "why"** — What problem does this solve? What's the user feeling or frustrated by?
- **The scope** — Is this a quick enhancement or a new module? Who uses it?
- **The spark** — What inspired this? Was there a specific moment or observation?

Don't over-interview. Two good questions beat five mediocre ones. If the user's initial
description is already detailed, skip straight to exploration.

### Step 2: Explore for Context — ground in the live code

Before generating ideas, ground yourself in what already exists. **The source of
truth is the live code, not `AGENTS.md` / `CLAUDE.md`** — read those as hints,
but verify against the code and trust the code when they disagree (a mismatch
usually means the doc is stale). Use Glob, Grep, and Read directly in the main
context window. Follow the procedure in
[`skills/sdlc/templates/convention-grounding.md`](../sdlc/templates/convention-grounding.md):

- **Check `GOTCHAS.md` for the touched area** (scoped injection): read the
  configured `gotchas_file` if it exists and surface only entries matching the
  idea's area/keywords — cap at the top few, never inline the whole file. Skip
  silently when the file is absent. This puts hard-won pitfalls in front of the
  idea *before* it's shaped, not only at Step 7 validation.
- **Find the 2–3 closest existing implementations** to the idea (same layer,
  same kind of thing) and note the patterns they follow with `path:line`
  citations — layout, naming, error handling, the data-access seam, shared
  utilities already available, test style.
- **What infrastructure exists** that this idea could build on (prefer extending
  it over inventing a parallel one).
- **What data models are relevant** (check migrations, models).

Summarize what you found in 3-5 bullets, and carry the reuse decisions forward
into the plan's `### Conventions & reuse` block (Step 6). The user shouldn't have
to read code — translate what you found into plain language that connects to
their idea. Don't reinvent what the repo already does.

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

### Conventions & reuse
What this plan reuses from the existing codebase (from Step 2's recon), so
implementation follows the repo instead of reinventing it:
- Follow: <pattern> — see `path:line`
- Reuse: <existing module/helper/type> for <purpose> — `path`
- New (justified): <thing>, because <no existing pattern fits>
- Doc drift: <AGENTS.md/CLAUDE.md says X but the code does Y>   (omit if none)

### Implementation Steps
Numbered list of concrete steps, each with:
- What to do
- Which files to create/modify
- Key patterns to follow (reference existing code from the block above)

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

The persistent plan **must** live at `<repo-root>/plans/<slug>.md` — that is the
only location downstream skills (`/sdlc-lite`, `/flowsim`,
`/repo-health`, validators) read. If the `plans/` directory doesn't exist,
create it first (use a Bash `mkdir -p plans` or include the directory in the Write
target — Write creates parent dirs automatically).

Do this **before** Step 7 (validation) — the validation agent reads the plan from
this path.

Because this skill never enters Plan mode (Step 0), the write goes straight to the
repo root with no sandbox in the way and no re-persist step. If you find yourself
holding a transient host plan path (`~/.claude/plans/<random>.md`), something
entered Plan mode against this skill's contract — write the canonical copy to
`plans/brainstorm-<topic-slug>.md` and continue from there.

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
  high-blast-radius plans where extra scrutiny is worth it (opt up with
  `--model opus` for the vet reviewers if warranted).
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

#### `ultra` — `deep` + 2 top-tier agents in parallel
Model cap applies: these two reviewers are **Sonnet by default** (Opus only on
`--model opus` opt-up), resolved per
`skills/sdlc/templates/models.md` (`--model <tier>` > `project.json`
`models.cap` > default). Before dispatch, print `model: <tier> (cap: <cap|none>)`
and emit the session-model nudge once when a cap is active.
After Sonnet stress-test, dispatch the two agents (Sonnet by default; Opus on
`--model opus` opt-up) in a single message:

1. **architectural-coherence** (capped tier — Sonnet by default). Prompt:
   > Read the plan at {plan_file} and the project's CLAUDE.md/AGENTS.md.
   > Check whether the plan's structure fits the codebase's existing
   > architecture: layering, abstraction boundaries, naming conventions,
   > module ownership. Flag any contradiction with existing patterns —
   > "the plan works in isolation but violates the established X
   > convention." Cap report at 300 words.

2. **edge-case-divergence** (capped tier — Sonnet by default). Prompt:
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

### Step 7.5: Size the plan against one execution session

A plan is usually executed in a **fresh session** (`/sdlc-lite <plan>`), so the plan itself
decides how big that session gets. Say so at authoring time, when splitting is cheap — not
during execution, where it isn't.

Estimate from the plan's own shape and state it in one line:

- **files touched** and **implementation steps** (both already parsed above),
- **surfaces** crossed (backend / frontend / data / docs),
- whether the steps are **sequentially dependent** (they must share a session) or
  **independent** (they need not).

Then print, once:

```
plan size: <n> steps across <m> files, <k> surface(s) — <one execution session | splittable>
```

**"Splittable" is information, not an instruction.** A large run is not automatically waste:
if the work genuinely needs that much state, let it cook — a 1M window holds it and cache
reads are cheap per token. Recommend a split only when the steps are **independent**, because
then a second session costs nothing but re-reading the plan, and each slice starts clean.
Never split a sequentially-dependent chain to hit a number; that trades real working context
for a metric.

What *does* waste tokens at any plan size is junk in the orchestrator's context — shell
output and file bodies a sub-agent should have held. That is Stage 2's delegation rule's job,
not the plan's. Do not try to fix it here.

If the user has run a pipeline before, `run-cost-report.sh` printed what the last one actually
cost. That measured number beats this estimate — prefer it when sizing.

### Step 8: Continue the flow

A brainstorm that ends at a file the user has to manually pick up is a
**dropped flow**. Default posture: keep the momentum — continue into the
delivery pipeline rather than stopping at the plan.

**Step 8.0 — confirm the plan file exists before routing.** There is no plan mode
to exit (Step 0), so this is a one-line check rather than a state transition:
`plans/brainstorm-<topic-slug>.md` must exist at the repo root — Step 6 wrote it.
Do not proceed to routing or the sentinel until it does; a sentinel pointing at a
missing plan is a bug.

**Then — is this plan about the toolkit's own vendored skills?** If the plan's
changed-files target `.claude/skills/**` (or `.github/skills/**`,
`.agents/skills/**`) — i.e. it proposes editing *installed/vendored* skill
copies — **do NOT route it through this consumer repo's `/sdlc-lite`.** Those edits
belong in the **canonical brainstorm-toolkit repo**, then get re-installed.
Suppress the auto-pipeline sentinel and emit instead:
`Next: file this upstream in the brainstorm-toolkit repo (these are vendored
skill copies; editing them here diverges from canonical).` This is the
"toolkit improving itself" case — shipping skill edits through a consumer's
pipeline is exactly the mis-route to avoid. (Authoring a *new app feature*
proceeds normally below.)

**Otherwise, pick the next command by flow continuity** — don't make the user
re-choose a flow they've already established this session:
- If `/sdlc-lite` has been used this session → continue with `/sdlc-lite`.
- If `/sdlc-lite` has been used, or no pipeline flow is established yet →
  use `/sdlc-lite`. It runs the full pipeline and hands back validated changes
  with **no git writes**, so it's the safe default — it can't surprise the user
  with a PR.

> These continuity rules are a slice of `/status`'s **canonical decision ladder**
> (rung 4 — a plan with no run; see `skills/status/SKILL.md`). `/status` is the source
> of truth for "what's the next step"; this inline copy keeps `/brainstorm`
> self-contained when the user hasn't got `/status` in mind.

Drop a **next-action sentinel** naming that command so the Stop hook surfaces
it. The plan file MUST already exist at `plans/brainstorm-<topic-slug>.md`
before writing the sentinel — Step 6 wrote it and Step 8.0 confirms it. A
sentinel pointing at a missing plan is a bug.

```
# Append ONE structured line (multi-slot seam — coexists with a gotcha entry;
# see docs/SEAM.md). Default to the safe pipeline; substitute /sdlc-lite with
# "confirm":true if that's the established flow (it opens a PR).
line='{"cmd":"/sdlc-lite plans/brainstorm-<topic-slug>.md","source":"brainstorm","confirm":false}'
grep -qF "$line" .claude/.next-action 2>/dev/null || echo "$line" >> .claude/.next-action
```

The Stop hook — **shipped by the plugin** (auto-wired when the plugin is enabled,
SEAM1) or installed by `setup.sh` (`.claude/settings.json` / `.github/hooks/next-action.json`)
— reads the file once, prints `Next: <command>`, and deletes it. **On Codex (no Stop
hook), also print `Next: <command>` inline** right after writing the sentinel, so the
flagship handoff degrades gracefully instead of vanishing. **No-hook nudge (SEAM2):** if
no hook is wired at all, the sentinel is inert — after writing it, run the best-effort
check in `docs/SEAM.md` and, if nothing will surface it, tell the user to enable the
plugin or run `setup.sh`/`/repo-onboarding` (else the `Next:` hint silently never
appears). Skip the sentinel only if the user explicitly chose "save for later" with no
intent to ship.

The plan file exists on disk (Step 8.0). Continue:

1. **Show what's being built** (optional, cheap) — offer
   `/plan-html plans/brainstorm-<topic-slug>.md` to render the plan as a
   single-file HTML view the user or a stakeholder can scroll, for a
   shape-of-the-work read before delivery starts.
2. **Continue into delivery** with the established flow, or `/sdlc-lite` by
   default — run the full pipeline. `/sdlc-lite` hands back validated changes
   for the user to commit (no git writes); `/sdlc-lite` goes all the way to a PR.
   **Because `/sdlc-lite` opens a PR, confirm before taking that path** — but you do
   not need to ask permission to continue with the safe `/sdlc-lite` path.
3. **Save for later** — if the user signals they're done for now, leave the
   plan file and skip the sentinel.

If the plan has clear implementation steps with file paths and acceptance
criteria, proceed with delivery (option 2). If it's exploratory or has
ambiguous tradeoffs, pause for the user to review (offer option 1's HTML view
first).

Transition conversationally — there is no planning-mode exit to perform.

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
