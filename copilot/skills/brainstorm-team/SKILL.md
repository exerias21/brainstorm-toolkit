---
name: brainstorm-team
description: >
  Sequential product-strategy brainstorm for Copilot. Walk through five research
  passes (competitive landscape → codebase map → UX critique → ranked features →
  implementation blueprints) inline, producing a single strategy document. Use
  for "what should we build next", "competitive analysis", or product review
  sessions. Copilot-adapted version of the canonical — sequential instead of
  5 parallel workers.
metadata:
  brainstorm-toolkit-applies-to: copilot
disable-model-invocation: true
---

# Brainstorm Team (Copilot Edition — Sequential)

Six research passes executed in order by you, producing a single strategy document at `plans/team-brainstorm-<topic-slug>.md` (at the repo root, written via the Copilot agent's file-write mechanism — NOT under `.claude/`). The Claude canonical runs these as parallel workers; this version runs them sequentially. Output is the same shape, just slower.

## Before starting — load project context

Read, in order, skipping any that don't exist:
- `README.md`
- `CLAUDE.md` / `AGENTS.md`
- `.claude/project.json` (for the `modules` list)
- Any `plans/` index or recent plan files

Summarize into a 3–5 sentence "Project Context" block. Keep it in mind for every pass below.

## Pass 1 — Competitive landscape

Search the web for 20+ competitive products, concepts, or gaps relevant to this project's domain. Focus on what's missing in the market, not what's crowded. Useful sources: Reddit, ProductHunt, HackerNews, domain-specific forums.

Output for this pass: a bulleted list of competitors + 5-7 gaps the market isn't filling.

## Pass 2 — Codebase map

Deep-read the repo. **The live code is the source of truth — `README.md`/`CLAUDE.md`/`AGENTS.md` are hints that may be stale; verify against the code and flag any drift.** Map:
- Data model (migrations, schemas).
- Every API endpoint.
- Every service module.
- Every component folder.
- Cross-module connections.
- Visible technical debt.
- Infrastructure that could support new features cheaply.

Per `skills/sdlc/templates/convention-grounding.md`, also produce a **reuse inventory**: the dominant patterns (layout, naming, error handling, the data-access seam, shared utilities, test style) with `path:line` citations, so the Pass 5 blueprints extend what exists instead of reinventing it.

Output: a compact architectural overview (10-20 bullets) + the reuse inventory — bring Pass 1's gaps forward and note which ones the existing infrastructure could support inexpensively.

## Pass 3 — UX critique

Think as a first-time user of the product (frontend, CLI surface, or API surface — whichever is primary). Evaluate:
- First-time experience and onboarding.
- Daily friction points.
- Navigation clarity.
- Adoption resistance.

Output: 5 biggest UX problems + 5 genuine delights you'd keep.

## Pass 3.5 — Lateral Thinker (four lenses)

Push past the obvious before ranking. Run these four lenses against the Project Context and produce one Wildcard feature per lens. Do not re-analyze the codebase here — that's Pass 2's job.

1. **First Principles** — strip the product to its physics. What is the user actually trying to accomplish at the most basic level? Propose the simplest mechanism that delivers that outcome, assuming no prior code exists.
2. **Inversion** — solve the opposite problem. If the stated goal is X, what would preventing X look like? Would that be more valuable? What if the core assumption is wrong?
3. **Cross-Domain Analogy** — pick one non-software domain (game designer, biologist, musician, logistics planner) and import its patterns. Describe the analogous approach concretely.
4. **Constraint Removal** — what if compute / storage / user attention / dev time were free and infinite? Now flip it — what if each were zero? Describe both extremes and what survives in the middle.

Each Wildcard includes: name, one-line pitch, 3-5 bullets on how it works, tradeoffs, effort (S/M/L), and one sentence on why it's genuinely different from what a conventional ranking would surface.

Output: 4 Wildcards, one per lens, tagged with the lens name.

## Pass 4 — Feature strategy

Using Pass 1–3.5 findings, produce a ranked top-10 feature list. Weigh Pass 3.5's Wildcards against conventional candidates — you may promote up to 2 into the ranking if they beat a conventional option on impact. All 4 Wildcards are preserved in the final document regardless of promotion. Each feature includes:
- Name.
- One-line pitch.
- Why it matters (tie back to a gap or a UX problem).
- What exists in the codebase today.
- What to build (specific files + modules).
- Effort (S / M / L).
- Dependencies.
- Integration touchpoints.

## Pass 5 — Implementation blueprints

For the top 3 features from Pass 4, write detailed implementation blueprints following the project's existing patterns: data model changes, service functions, endpoints, UI components, integrations. **Bind each blueprint to Pass 2's reuse inventory** — cite the existing pattern/module each step extends (`path:line`), and call out explicitly any place you must introduce a *new* pattern and why no existing one fits. Don't reinvent what the codebase already has. Also note 2–3 "wild card" ideas — unconventional bets worth considering separately.

## Final output

**Write the assembled document to `plans/team-brainstorm-<topic-slug>.md`** at the
repo root (the consumer project's working directory) — NOT under `.claude/`.
Derive `<topic-slug>` from the session's topic (lowercase, hyphenated, ≤40
chars) so repeated runs don't clobber each other; fall back to
`team-brainstorm-results.md` only for a truly generic "what next?" session.
Use the file-write mechanism Copilot's agent has available; create the `plans/`
directory first if it does not exist.

Assemble everything into `plans/team-brainstorm-<topic-slug>.md` with sections:
1. Competitive Landscape
2. Codebase Map & Technical Assessment
3. Conventions & reuse (Pass 2's live-code reuse inventory: dominant patterns with `path:line`, shared utilities to reuse, and any doc drift found — blueprints in §6 bind to this)
4. UX Assessment (5 problems, 5 delights)
5. Top 10 Features Ranked
6. Implementation Blueprints (Top 3)
7. Wild Cards (2-3 Planner-spotted opportunistic ideas)
8. Wildcards — Lens Divergence (4 lens-driven approaches from Pass 3.5: First Principles, Inversion, Cross-Domain Analogy, Constraint Removal)

Sections 7 and 8 (Wild Cards and Lens Divergence) are both preserved — they come from different prompts (opportunistic vs. structured lenses) and the comparison is often illuminating.

If any Pass generated meaningfully more content than fits a single section, split into sub-sections — don't cut depth to fit a template.
