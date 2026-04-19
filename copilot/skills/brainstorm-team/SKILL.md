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

Five research passes executed in order by you, producing a single strategy document at `plans/team-brainstorm-results.md`. The Claude canonical runs these as five parallel workers; this version runs them sequentially. Output is the same shape, just slower.

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

Deep-read the repo. Map:
- Data model (migrations, schemas).
- Every API endpoint.
- Every service module.
- Every component folder.
- Cross-module connections.
- Visible technical debt.
- Infrastructure that could support new features cheaply.

Output: a compact architectural overview (10-20 bullets) — bring Pass 1's gaps forward and note which ones the existing infrastructure could support inexpensively.

## Pass 3 — UX critique

Think as a first-time user of the product (frontend, CLI surface, or API surface — whichever is primary). Evaluate:
- First-time experience and onboarding.
- Daily friction points.
- Navigation clarity.
- Adoption resistance.

Output: 5 biggest UX problems + 5 genuine delights you'd keep.

## Pass 4 — Feature strategy

Using Pass 1–3 findings, produce a ranked top-10 feature list. Each feature includes:
- Name.
- One-line pitch.
- Why it matters (tie back to a gap or a UX problem).
- What exists in the codebase today.
- What to build (specific files + modules).
- Effort (S / M / L).
- Dependencies.
- Integration touchpoints.

## Pass 5 — Implementation blueprints

For the top 3 features from Pass 4, write detailed implementation blueprints following the project's existing patterns: data model changes, service functions, endpoints, UI components, integrations. Also note 2–3 "wild card" ideas — unconventional bets worth considering separately.

## Final output

Assemble everything into `plans/team-brainstorm-results.md` with sections:
1. Competitive Landscape
2. Codebase Map & Technical Assessment
3. UX Assessment (5 problems, 5 delights)
4. Top 10 Features Ranked
5. Implementation Blueprints (Top 3)
6. Wild Cards (2-3)

If any Pass generated meaningfully more content than fits a single section, split into sub-sections — don't cut depth to fit a template.
