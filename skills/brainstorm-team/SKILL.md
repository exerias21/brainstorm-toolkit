---
name: brainstorm-team
description: >
  Launches a coordinated multi-agent team (5 agents in parallel) to produce a complete
  product strategy document: competitive research, codebase mapping, UX critique, ranked
  feature list, and detailed implementation blueprints. Use when the user wants heavy
  autonomous product research or says "brainstorm team", "what should we build next",
  "competitive analysis", "product review", or invokes /brainstorm-team. For
  conversational ideation with the user in-session, use /brainstorm instead.
metadata:
  brainstorm-toolkit-applies-to: claude copilot
---

# Brainstorm Team

Use this skill when the user wants to run a product brainstorm, feature planning session, competitive analysis, or strategic review of the current project. Invoke with `/brainstorm-team` or when the user says things like "what should we build next", "competitive analysis", "feature planning", "product review".

## Prerequisites

Agent teams must be enabled. Check or set:
```json
// settings.json
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  }
}
```

## What This Skill Does

Creates a 6-agent team with specialized roles that work in parallel to produce a complete product strategy document. The team:

1. **Researches** the competitive landscape (internet search)
2. **Maps** the codebase architecture and identifies opportunities
3. **Critiques** the UX from a real user's perspective
4. **Thinks laterally** through four fixed lenses to push past the obvious
5. **Synthesizes** findings (including lens wildcards) into a ranked feature list
6. **Plans** detailed implementation for the top features

## Before Invoking — Load Project Context

Before spawning the team, read (in this order, skipping any that don't exist):
- The project's `README.md`
- The project's `CLAUDE.md`
- `.claude/project.json` (for `modules` list)
- Any `plans/` directory index or recent plans

Summarize findings into a 3-5 sentence "Project Context" block and inject it into each teammate's prompt below where marked `{PROJECT_CONTEXT}`.

## How to Invoke

When triggered, create an agent team with this structure. Adapt the specific research angles based on what the user asks for (e.g., if they say "brainstorm auth improvements" focus the research on authentication patterns).

### Default Team (Full Product Review)

```
Create an agent team with 6 teammates for a product strategy session. Use Sonnet for each teammate. Require plan approval before any teammate writes files.

PROJECT CONTEXT:
{PROJECT_CONTEXT}

Teammate 1 — Product Researcher:
Search the internet for competitive intelligence relevant to this project's domain. Find 20+ products/concepts. Focus on gaps nobody fills. Search Reddit, ProductHunt, HackerNews, relevant industry forums. Write findings as you go.

Teammate 2 — Codebase Architect:
Deep-read the entire codebase. Map the data model (migrations, schemas), every API endpoint, every service module, every component folder. Identify cross-module connections, technical debt, and where existing infrastructure could support new features cheaply. Message the Researcher when you find relevant architectural context.

Teammate 3 — UX Critic:
Think like a first-time user of this product. Read the frontend (or CLI surface, or API surface — whichever applies). Evaluate: first-time experience, daily friction, navigation/clarity, adoption resistance. Find 5 biggest UX problems and 5 genuine delights.

Teammate 4 — Lateral Thinker:
Your job is to push past the obvious. Do NOT analyze the codebase or market — the other teammates cover that. Run these four lenses against the PROJECT CONTEXT and produce one Wildcard feature per lens:

  (a) First Principles — strip the product to its physics. What is the user actually trying to accomplish at the most basic level? Propose the simplest mechanism that delivers that outcome, assuming no prior code exists.
  (b) Inversion — solve the opposite problem. If the stated goal is X, what would preventing X look like? Would that be more valuable? What if the core assumption is wrong?
  (c) Cross-Domain Analogy — pick one non-software domain (game designer, biologist, musician, logistics planner) and import its patterns. Describe the analogous approach concretely.
  (d) Constraint Removal — what if compute / storage / user attention / dev time were free and infinite? Now flip it — what if each were zero? Describe both extremes and what survives in the middle.

Each Wildcard returns: name, one-line pitch, 3-5 bullets on how it works, tradeoffs, effort (S/M/L), and one sentence on why it's genuinely different from anything the Strategist is likely to rank. Message the Strategist when ready.

Teammate 5 — Feature Strategist:
Wait for teammates 1-4 to report findings, then synthesize a ranked top-10 feature list. Each feature needs: name, one-line pitch, why it matters, what exists in the codebase today, what to build (specific files), effort (S/M/L), dependencies, integration touchpoints. Weigh the Lateral Thinker's Wildcards against the conventional candidates — you may promote up to 2 Wildcards into the top-10 if they beat a conventional option on impact. Whether promoted or not, all 4 Wildcards are preserved in the final document.

Teammate 6 — Implementation Planner:
Wait for the Strategist's top 10, then write detailed implementation blueprints for the top 3 following the project's existing patterns (data model, services, endpoints, UI components, integrations). Also write 2-3 opportunistic "wild card" ideas you spotted while planning — these are separate from the Lateral Thinker's lens Wildcards and live in their own section.

Coordination: Teammates 1-4 work in parallel. Teammate 5 starts after 1-4 report. Teammate 6 starts after 5 finalizes. All teammates message each other when they find cross-domain insights. Final output is written by the orchestrator (you) — see "Output Format" below — to plans/team-brainstorm-results.md at the repo root.
```

### Focused Team (Module-Specific)

If the user wants to brainstorm about a specific module or surface (e.g., "brainstorm auth improvements"), adapt:
- Researcher: focus competitive search on that domain
- Architect: deep-dive that module's code specifically
- Critic: evaluate that module's UX flow
- Lateral Thinker: apply the four lenses to *that module's* problem space, not the whole product
- Strategist: rank features for that module only
- Planner: blueprint the top 3 for that module

### Quick Team (3 agents)

For faster/cheaper sessions:
```
Create an agent team with 3 teammates:
1. Researcher+Critic+Lateral (combined): research competitors, critique our UX, AND run the four lateral-thinking lenses (First Principles, Inversion, Cross-Domain Analogy, Constraint Removal) to produce 4 Wildcards.
2. Architect+Strategist (combined): map codebase, then rank features — weighing the Wildcards alongside conventional candidates.
3. Planner: blueprint top 3.

Output to plans/team-brainstorm-results.md at the repo root (use the Write tool — see "Output Format" below) — must include a Wildcards section even when the quick variant is used.
```

## Output Format

**Use the `Write` tool** to save the assembled document to
`plans/team-brainstorm-results.md` at the **repo root** (the consumer project's
working directory) — NOT under `.claude/`. Plan Mode internal storage and
`.claude/` are not where downstream skills look. Create the `plans/` directory
if it doesn't exist (Write creates parent dirs automatically).

The team produces `plans/team-brainstorm-results.md` with sections:
1. Competitive Landscape
2. Codebase Map & Technical Assessment
3. UX Assessment (5 problems, 5 delights)
4. Top 10 Features Ranked (8-field format per feature)
5. Implementation Blueprints (Top 3)
6. Wild Cards (2-3 Planner-spotted opportunistic ideas)
7. Wildcards — Lens Divergence (4 lens-driven approaches from the Lateral Thinker: First Principles, Inversion, Cross-Domain Analogy, Constraint Removal)

Sections 6 and 7 are both preserved — they come from different agents with different prompts, and the comparison itself is often illuminating.
