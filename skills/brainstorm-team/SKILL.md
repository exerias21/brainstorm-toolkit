---
name: brainstorm-team
description: >
  Launches a coordinated multi-agent team (5 agents in parallel) to produce a complete
  product strategy document: competitive research, codebase mapping, UX critique, ranked
  feature list, and detailed implementation blueprints. Use when the user wants heavy
  autonomous product research or says "brainstorm team", "what should we build next",
  "competitive analysis", "product review", or invokes /brainstorm-team. For
  conversational ideation with the user in-session, use /brainstorm instead.
applies-to: [claude]
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

Creates a 5-agent team with specialized roles that work in parallel to produce a complete product strategy document. The team:

1. **Researches** the competitive landscape (internet search)
2. **Maps** the codebase architecture and identifies opportunities
3. **Critiques** the UX from a real user's perspective
4. **Synthesizes** findings into a ranked feature list
5. **Plans** detailed implementation for the top features

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
Create an agent team with 5 teammates for a product strategy session. Use Sonnet for each teammate. Require plan approval before any teammate writes files.

PROJECT CONTEXT:
{PROJECT_CONTEXT}

Teammate 1 — Product Researcher:
Search the internet for competitive intelligence relevant to this project's domain. Find 20+ products/concepts. Focus on gaps nobody fills. Search Reddit, ProductHunt, HackerNews, relevant industry forums. Write findings as you go.

Teammate 2 — Codebase Architect:
Deep-read the entire codebase. Map the data model (migrations, schemas), every API endpoint, every service module, every component folder. Identify cross-module connections, technical debt, and where existing infrastructure could support new features cheaply. Message the Researcher when you find relevant architectural context.

Teammate 3 — UX Critic:
Think like a first-time user of this product. Read the frontend (or CLI surface, or API surface — whichever applies). Evaluate: first-time experience, daily friction, navigation/clarity, adoption resistance. Find 5 biggest UX problems and 5 genuine delights.

Teammate 4 — Feature Strategist:
Wait for teammates 1-3 to report findings, then synthesize a ranked top-10 feature list. Each feature needs: name, one-line pitch, why it matters, what exists in the codebase today, what to build (specific files), effort (S/M/L), dependencies, integration touchpoints.

Teammate 5 — Implementation Planner:
Wait for the Strategist's top 10, then write detailed implementation blueprints for the top 3 following the project's existing patterns (data model, services, endpoints, UI components, integrations). Also write 2-3 wild card ideas.

Coordination: Teammates 1-3 work in parallel. Teammate 4 starts after 1-3 report. Teammate 5 starts after 4 finalizes. All teammates message each other when they find cross-domain insights. Final output goes to plans/team-brainstorm-results.md.
```

### Focused Team (Module-Specific)

If the user wants to brainstorm about a specific module or surface (e.g., "brainstorm auth improvements"), adapt:
- Researcher: focus competitive search on that domain
- Architect: deep-dive that module's code specifically
- Critic: evaluate that module's UX flow
- Strategist: rank features for that module only
- Planner: blueprint the top 3 for that module

### Quick Team (3 agents)

For faster/cheaper sessions:
```
Create an agent team with 3 teammates:
1. Researcher+Critic (combined): research competitors AND critique our UX
2. Architect+Strategist (combined): map codebase AND rank features
3. Planner: blueprint top 3

Output to plans/team-brainstorm-results.md
```

## Output Format

The team produces `plans/team-brainstorm-results.md` with sections:
1. Competitive Landscape
2. Codebase Map & Technical Assessment
3. UX Assessment (5 problems, 5 delights)
4. Top 10 Features Ranked (8-field format per feature)
5. Implementation Blueprints (Top 3)
6. Wild Cards (2-3 unconventional ideas)
