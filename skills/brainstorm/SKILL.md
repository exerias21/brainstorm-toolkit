---
name: brainstorm
description: >
  Interactive brainstorming and feature ideation skill: clarifies the idea, explores codebase
  context, generates multiple approaches, evaluates tradeoffs, and writes an action plan to
  `plans/`. Use whenever the user says /brainstorm, mentions "brainstorm", "let's think through",
  "I have an idea", "what if we", "how should we approach", "let's explore", or wants to ideate
  on a feature or change before jumping into code. This is the conversational planning companion
  — for heavy autonomous multi-agent product research, use /brainstorm-team instead.
argument-hint: "[topic] [--vet light|deep|ultra|none] - optional: topic + multi-agent vet mode"
metadata:
  brainstorm-toolkit-applies-to: claude copilot codex
---

# Brainstorm

An interactive ideation skill that walks through a structured brainstorming process *with* the
user. Unlike `/brainstorm-team` (which launches autonomous agents to produce a
research document), this skill is conversational — it thinks out loud, asks questions, and iterates
on ideas together with the user before producing an implementation plan.

## How It Works

The conversational loop stays in the **main context window** for Steps 1–3, 5, and 6. Do not
delegate exploration or ideation to subagents outside Step 4b and Step 7.

### Step 0: Set the frame (no Plan mode)

**Do NOT call `EnterPlanMode`.** This skill runs in the normal conversational mode and
persists its output as a file: plan mode's approve gate would duplicate the conversational
convergence below, and its sandbox blocks the repo-root write every downstream skill reads.

Say in one line that this is an exploration session, not an implementation session: you'll
think out loud, explore the codebase, generate options, and iterate with the user to
converge on a concrete action plan before any code is written. Write no implementation code
during Steps 1–7 — the discipline is a working agreement here, not a host-enforced sandbox.

### Step 1: Understand the Seed

Start by understanding what the user wants to explore. If they gave a topic with `/brainstorm`,
use that as the seed. Otherwise, ask.

**Ask before you explore — the gate is objective, not a vibe.** Ask clarifying questions when
**any** of these is true of the seed:

- it names a *problem* but no shape ("payments are a mess"), or a *shape* but no problem
  ("let's add a queue");
- who uses it, or what they do instead today, is not stated;
- it would land in more than one surface and the seed doesn't say which is primary;
- two readings of it would produce materially different plans;
- it references a system, term, or constraint you cannot find in the repo.

None of those true, and the seed is concrete? Skip straight to Step 2 and say you're skipping —
don't interview someone who already told you.

Ask in **one message per round**, and make every question one whose answer changes the plan:
- **The "why"** — what problem does this solve? What is the user working around today?
- **The scope** — quick enhancement or new module? Who uses it, and how often?
- **The spark** — what prompted this now? A specific moment usually carries the real constraint.

**Scale the count to the ambiguity, and keep going until the plan-shaping unknowns are
closed.** A concrete seed needs 2–3; a vague one ("payments are a mess") needs as many as it
takes, across as many rounds as it takes — there is no cap, and stopping early to look decisive
is the expensive move. Two good questions beat five mediocre ones, but two good questions also
beat one good question and a guess. Each round: name what is still unknown, ask, and stop when
you could write the plan without inventing anything. If a round's answers are thin, say which
unknown is still open and ask again rather than picking a reading and building on it.

Prefer the host's **built-in interactive question UI** (the multiple-choice picker) where it
exists, one question per unknown with a recommended default first — a user who is never offered
an option never discovers the choice existed. Fall back to a numbered list answered in one reply.

**This holds for the whole session, not just Step 1.** A plan-shaping ambiguity that surfaces at
Step 3, 4, or 6 is a question, not an assumption: stop and ask. Everything else — anything a
careful colleague would just decide — you decide, and note the call in the plan's Open Questions.
Guessing at the top of a funnel is the most expensive mistake available here: every later stage,
and the entire `/sdlc` run after it, compounds the wrong reading.

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
  silently when the file is absent.
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
words. **Sonnet by default** — resolve the tier per `skills/sdlc/templates/models.md`
(`--model <tier>` > `project.json` `models.cap` > default) and print
`model: <tier> (cap: <cap|none>)` before dispatching.

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

### Step 6: Produce the Action Plan

Once the user has converged on a direction, produce a concrete plan. Structure it as:

**Write the plan using `skills/brainstorm/templates/plan.md.template`** — read it now. It
carries the full section set (Direction, Conventions & reuse, Implementation Steps,
Cross-Module Touchpoints, Open Questions, Appendix: Alternatives Considered) and the notes on
what belongs in each. Keep the headings verbatim: `/sdlc`'s Stage 0 parser finds
implementation steps and files-to-change by those names.

**Use the `Write` tool** to save this to `plans/brainstorm-[topic-slug].md` at the **repo
root** (not under `.claude/`) — the only location downstream skills (`/sdlc`, `/flowsim`,
`/repo-health`, validators) read, and Step 7's validation agent reads it too, so do this
before Step 7. Create `plans/` first if it doesn't exist (Write creates parent dirs
automatically).

If you find yourself holding a transient host plan path (`~/.claude/plans/<random>.md`), something
entered Plan mode against this skill's contract — write the canonical copy to
`plans/brainstorm-<topic-slug>.md` and continue from there.

**Group implementation steps into phases past ~6 steps, or a real ordering dependency**
(phase 2 needs phase 1 landed first) — `#### Phase N — <title>` headings under
`### Implementation Steps`, per the template. A flat list stays one implicit phase; nothing
downstream requires phases.

**Also append action items to `TASKS.md`** (at repo root). For each implementation step
that's concrete and bounded enough to stand alone, add a row to the `Active / Pending`
section: `- [ ] (P2) <step title> — plans/brainstorm-[topic-slug].md _plan: [topic-slug]_`
(append `· _phase: N_` when the step sits under a `#### Phase N` heading). **The `_plan:_`
value is `[topic-slug]` alone, never `brainstorm-[topic-slug]`** — `/sdlc` Stage 0 derives
its slug by stripping the leading `brainstorm-` from the plan filename, so tagging the row
with the full filename stem would make the "deterministic" key never match at Stage 6
close-out. If `TASKS.md` doesn't exist, create it from `templates/TASKS.md.template` (or
with minimal sections).

### Step 6.5: Multi-agent Vet (mode-gated)

**Off unless a vet mode is explicitly requested** (`--vet`, or the user asking for a review
pass). Resolve that first — when no mode is set, go straight to Step 7 and do not open the
template. When a mode *is* set, **read `skills/brainstorm/templates/vet-modes.md` now** and run
it; it carries the modes, their agent prompts, the merge rule and the post-vet hand-back.
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

A plan is usually executed in a **fresh session** (`/sdlc <plan>`), so the plan itself
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

**"Splittable" is information, not an instruction.** Recommend a split only when the steps
are **independent**, because then a second session costs nothing but re-reading the plan,
and each slice starts clean. Never split a sequentially-dependent chain to hit a number;
that trades real working context for a metric.

If the user shares the last run's cost report, prefer its measured number over this
estimate.

### Step 8: Continue the flow

Default posture: keep the momentum — continue into the delivery pipeline rather than
stopping at the plan.

**Step 8.0 — confirm the plan file exists before routing.** There is no plan mode
to exit (Step 0), so this is a one-line check rather than a state transition:
`plans/brainstorm-<topic-slug>.md` must exist at the repo root — Step 6 wrote it.
Do not proceed to routing or the sentinel until it does; a sentinel pointing at a
missing plan is a bug.

**Then — is this plan about the toolkit's own vendored skills?** If the plan's
changed-files target `.claude/skills/**` (or `.github/skills/**`,
`.agents/skills/**`) — i.e. it proposes editing *installed/vendored* skill
copies — **do NOT route it through this consumer repo's `/sdlc`.** Those edits
belong in the **canonical brainstorm-toolkit repo**, then get re-installed.
Suppress the auto-pipeline sentinel and emit instead:
`Next: file this upstream in the brainstorm-toolkit repo (these are vendored
skill copies; editing them here diverges from canonical).` This is the
"toolkit improving itself" case — shipping skill edits through a consumer's
pipeline is exactly the mis-route to avoid. (Authoring a *new app feature*
proceeds normally below.)

**Otherwise the next command is `/sdlc`** — it runs the full pipeline and hands back
validated changes with **no git writes**, so it is safe to take without asking.

Drop a **next-action sentinel** naming that command so the Stop hook surfaces it.

```
# Append ONE structured line (multi-slot seam — coexists with a gotcha entry;
# see docs/SEAM.md). /sdlc does no git writes, so confirm stays false; set
# "confirm":true only if you substitute a command that is hard to reverse.
line='{"cmd":"/sdlc plans/brainstorm-<topic-slug>.md","source":"brainstorm","confirm":false}'
grep -qF "$line" .claude/.next-action 2>/dev/null || echo "$line" >> .claude/.next-action
```

The Stop hook — **shipped by the plugin** (auto-wired when the plugin is enabled,
SEAM1) or installed by `setup.sh` (`.claude/settings.json` / `.github/hooks/next-action.json`
/ `.codex/hooks.json`) — reads the file once, prints `Next: <command>`, and deletes it.
Codex **does** have a Stop hook shipped the same way; until the Codex hook is wired and
`.codex/` is trusted (`/hooks`), also print `Next:` inline right after writing the
sentinel, so the handoff degrades gracefully instead of vanishing. **No-hook nudge
(SEAM2):** if no hook is wired at all, the sentinel is inert — after writing it, check for
one: `grep -rlqs 'next-action' .claude/settings.json ~/.claude/settings.json
.github/hooks/ ~/.claude/plugins/ 2>/dev/null` — and if that finds nothing, tell the user
to enable the plugin or run `setup.sh`/`/repo-onboarding` (else the `Next:` hint silently
never appears). Skip the sentinel only if the user explicitly chose "save for later" with
no intent to ship.

Continue:

1. **Show what's being built** (optional, cheap) — offer
   `/plan-html plans/brainstorm-<topic-slug>.md` to render the plan as a
   single-file HTML view the user or a stakeholder can scroll, for a
   shape-of-the-work read before delivery starts.
2. **Continue into delivery** — `/sdlc plans/brainstorm-<topic-slug>.md`.
3. **Save for later** — if the user signals they're done for now, leave the
   plan file and skip the sentinel.

If the plan has clear implementation steps with file paths and acceptance
criteria, proceed with delivery (option 2). If it's exploratory or has
ambiguous tradeoffs, pause for the user to review (offer option 1's HTML view
first).

Transition conversationally.

## Tone and Style

Think out loud, stay curious about the user's ideas, use plain language over jargon, and
keep momentum rather than stalling in analysis paralysis.
