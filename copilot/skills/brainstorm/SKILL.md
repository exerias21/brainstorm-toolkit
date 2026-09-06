---
name: brainstorm
description: >
  Interactive brainstorming and feature ideation skill: clarifies the idea, explores codebase
  context, generates multiple approaches, evaluates tradeoffs, and writes an action plan to
  `plans/`. Use whenever the user says /brainstorm, mentions "brainstorm", "let's think through",
  "I have an idea", "what if we", "how should we approach", "let's explore", or wants to ideate
  on a feature or change before jumping into code. This is the conversational planning companion
  — for heavy autonomous multi-agent product research, use /brainstorm-team instead.
metadata:
  brainstorm-toolkit-applies-to: copilot
---

# Brainstorm (Copilot Edition)

An interactive ideation skill that walks through a structured brainstorming process *with* the
user. This is conversational — think out loud, ask questions, and iterate on ideas together with
the user before producing an implementation plan.

## How It Works

### Step 1: Understand the Seed

If the user gave a topic with `/brainstorm`, that's the seed; otherwise ask for one.

**Ask before you explore — the gate is objective.** Ask clarifying questions when **any** of
these is true: the seed names a problem but no shape (or a shape but no problem); who uses it
and what they do today is unstated; it spans more than one surface without saying which is
primary; two readings would produce materially different plans; or it references something you
cannot find in the repo.

None true and the seed is concrete? Skip to Step 2 and say you're skipping.

Ask **2–3 questions in one message** — the ones whose answers change the plan: the **why**
(what problem, what workaround today), the **scope** (enhancement or module, who uses it), the
**spark** (what prompted it now — the moment usually carries the real constraint). Thin answers
are a reason to ask again, **once**: name the unknown rather than picking a reading.

**This holds all session.** A plan-shaping ambiguity at any later step is a question, not an
assumption. Everything else — anything a careful colleague would just decide — you decide, and
note the call under Open Questions.

### Step 2: Explore for Context — ground in the live code

Before generating ideas, ground yourself in what already exists. **The source of
truth is the live code, not `AGENTS.md` / `CLAUDE.md`** — read those as hints,
but verify against the code and trust the code when they disagree (a mismatch
usually means the doc is stale). Search the codebase per the procedure in
`skills/sdlc/templates/convention-grounding.md`:

- **Check `GOTCHAS.md` for the touched area** (scoped injection): read the
  configured `gotchas_file` if it exists and surface only entries matching
  the idea's area/keywords — cap at the top few, never inline the whole
  file. Skip silently when the file is absent.
- **Find the 2–3 closest existing implementations** to the idea (same layer,
  same kind of thing) and note the patterns they follow with `path:line`
  citations — layout, naming, error handling, the data-access seam, shared
  utilities already available, test style.
- **What infrastructure exists** that this idea could build on (prefer extending
  it over inventing a parallel one).
- **What data models are relevant** (check migrations, models).

Summarize what you found in 3-5 bullets and carry the reuse decisions into the
plan's `### Conventions & reuse` block (Step 6). The user shouldn't have to read
code — translate what you found into plain language. Don't reinvent what the repo
already does.

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

### Step 4: Generate Approaches (Conventional + Wildcards)

Brainstorming converges on the obvious if all the ideas come from one head. This step
produces two tracks — conventional options and lens-driven wildcards — so the user sees
both what a sensible team would build and what lateral thinking proposes.

**Step 4a — Conventional approaches.** Produce 2–3 distinct approaches. Each has:

- **A name** — something memorable, not "Option A"
- **The core idea** — one sentence
- **How it works** — 3-5 bullet points covering the user-facing flow
- **What it builds on** — existing code/infrastructure it leverages
- **Tradeoffs** — what you gain and what you give up
- **Effort** — rough size (Small / Medium / Large)

Vary them meaningfully — UI-first vs data-model-first vs AI-leaning, for example. Include
at least one approach simpler than the user probably expects.

**Step 4b — Wildcards (four lenses, sequential).** Walk through these four lenses in
order. Keep each lens's output tight (≤200 words) so the combined block stays scannable.
For each lens, consider the user's seed and your Step 2/3 summary through that lens alone:

1. **First Principles** — strip the idea to its physics. What's the user *actually* trying
   to accomplish at the most basic level? Propose the simplest mechanism that delivers
   that outcome, assuming no prior code exists.
2. **Inversion** — solve the opposite problem. If the stated goal is X, what would
   *preventing* X look like — and would that be more valuable? What if the core assumption
   is wrong?
3. **Cross-Domain Analogy** — pick one non-software domain (game designer, biologist,
   musician, logistics planner) and import its patterns. Describe the analogous approach
   concretely.
4. **Constraint Removal** — what if compute / storage / user attention / dev time were
   free and infinite? Now flip it — what if each were zero? Describe both extremes and
   what survives at the middle.

Each lens returns: name, one-sentence pitch, 3–5 bullets on how it works, tradeoffs,
effort (S/M/L), and one sentence on why it's genuinely different from the conventional
options.

**Step 4c — Merge and present.** Assemble output with two clear headings — `## Conventional
Approaches` and `## Wildcards (Outside-the-Box)` — each wildcard tagged with its lens name.
Don't silently drop wildcards that seem impractical; the user decides what's practical.

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

**Write the plan using `skills/brainstorm/templates/plan.md.template`** — read it now. It
carries the full section set (Direction, Conventions & reuse, Implementation Steps,
Cross-Module Touchpoints, Open Questions, Appendix: Alternatives Considered). Keep the headings
verbatim: `/sdlc`'s Stage 0 parser finds implementation steps and files-to-change by those names.

**Write this to `plans/brainstorm-[topic-slug].md` at the repo root** (the
consumer project's working directory) — NOT under `.claude/`. Use the file-write
mechanism the agent has available. The on-disk path `<repo-root>/plans/<slug>.md`
is the source of truth — it is the only location the downstream skills (`/sdlc`,
`/flowsim`, `/repo-health`) read. Create the `plans/` directory first if it
doesn't exist.

Do this **before** Step 7 (validation) — the validation checklist references
this path.

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

### Step 6.5: Multi-pass Vet (mode-gated)

**Off unless a vet mode is explicitly requested** (`--vet`, or the user asking for a review
pass). Resolve that first — when no mode is set, go straight to Step 7 and do not open the
template. When a mode *is* set, **read `skills/brainstorm/templates/vet-modes.md` now** and run
it; it carries the modes, their prompts, the merge rule and the post-vet hand-back. On this
runtime run each pass **inline and sequentially** in the session (no sub-agents) — the cap is
advisory here, so set your session model to the cap tier for the savings.

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

### Step 8: Continue the flow

Don't stop at the plan file — keep the momentum into delivery. Continue
whichever pipeline flow has been used this session; default to `/sdlc`
(full pipeline, hands you the validated changes to commit — no git writes, so
it can't surprise you with a PR).

1. **Show what's being built** (optional) — `/plan-html plans/brainstorm-[topic-slug].md`
   renders the plan as a single-file HTML view for a shape-of-the-work read.
2. **Continue into delivery** — `/sdlc <plan>`. It runs the full pipeline and
   leaves the validated changes for you to commit; it opens no PR. For a single
   tiny item, `/task` is the fast path.
3. **Save for later** — leave the plan at `plans/brainstorm-[topic-slug].md`
   (task items are already in `TASKS.md`).

Write the next-action sentinel naming the chosen command so Copilot's Stop
hook surfaces it — append ONE structured line (multi-slot seam; coexists with a gotcha
entry, see `docs/SEAM.md`), deduped by `cmd`:
`line='{"cmd":"/sdlc plans/brainstorm-[topic-slug].md","source":"brainstorm","confirm":false}'; grep -qF "$line" .claude/.next-action 2>/dev/null || echo "$line" >> .claude/.next-action`
On Codex (as a fallback until its `.codex/hooks.json` Stop hook is wired+trusted), also print `Next: <command>` inline right after writing
the sentinel, so the handoff degrades gracefully instead of vanishing. **No-hook
nudge (SEAM2):** if no Stop hook is wired at all, the sentinel is inert — check for one:
`grep -rlqs 'next-action' .claude/settings.json ~/.claude/settings.json .github/hooks/
~/.claude/plugins/ 2>/dev/null` — and if that finds nothing, tell the user to enable the
plugin (it ships the hook, SEAM1) or run `setup.sh`/`/repo-onboarding`.
(substitute `/sdlc` if that's the established flow). Skip only on "save for later".
