# Model & cost reference

What each skill dispatches under the hood, and what a run costs. Split out of `README.md`
so the front page stays a tour rather than a reference table.

See also: [`skills/sdlc/templates/models.md`](../skills/sdlc/templates/models.md) (the
canonical model-tier contract) and [`docs/MODEL-AXES.md`](MODEL-AXES.md) (why there are two
independent axes).

What each skill dispatches under the hood, and a rough order-of-magnitude
cost. Token counts are **per typical run**, not worst-case: a `/sdlc` run
on a tiny plan is closer to the low end, on a multi-module refactor the
high end. Costs use **2026-06 list pricing** per M tokens (input / output):
Opus 5 $5 / $25, Sonnet 5 $2 / $10, Haiku 4.5 $1 / $5 and, for the
reviewer axis only, where it is an explicit opt-in, Fable 5 $10 / $50.

> Opus and Sonnet both got cheaper after this table was first written (Opus
> was $15 / $75, Sonnet $3 / $15). The figures below are rescaled to current
> pricing, so an older copy of this README overstates every Opus-orchestrated
> row by roughly 3×. Re-check against current list pricing before quoting them.

**These numbers assume the current skill set.** The pipeline's instruction load is ~16k tokens
per run after the 2026-08 consolidation (two pipeline skills merged into one, shared stage
bodies split into templates, opt-in stages gated so they load nothing when off), down from
~26k. The fan-out below is unchanged; what shrank is what the orchestrator reads before it
starts.

| Skill | Orchestrator | Sub-agents (per run) | Tokens/run (rough) | Cost/run (rough) |
|---|---|---|---|---|
| `/sdlc-status` | host model | none (reads `TASKS.md`) | <1k | ~$0.00 |
| `/gotcha` | host model | none (read/append `GOTCHAS.md`) | <1k | ~$0.00 |
| `/test-check` | host model | none (runs tests + log audit) | 1k–3k | ~$0.01 |
| `/plan-html` | host model | none (markdown read → HTML write) | 3k–10k | ~$0.01–$0.05 |
| `/task` | host model | none (inline TDD) | 5k–15k | $0.02–$0.10 |
| `/repo-health` | host model | 2 × Haiku (dead-code + gotchas-currency); 3 procedural checks | 5k–20k | $0.02–$0.10 |
| `/flowsim` | host model | none (plan-vs-code grep) | 10k–40k | $0.05–$0.40 |
| `/test-check --loop` | host model | 1 × Sonnet per fix iteration | 10k–30k / iter | $0.05–$0.30 / iter |
| `/repo-onboarding` | host model (Opus recommended) | 0–1 × Sonnet (pattern detection) | 20k–60k | $0.10–$0.35 |
| `/brainstorm-team` | host (Opus) | 6 × Sonnet teammates (4 parallel, 2 sequential) | 60k–150k | $0.20–$0.70 |
| `/brainstorm` | host (Opus) | 4 × Sonnet wildcard lenses (parallel); `--vet` adds a review pass | 20k–60k | $0.04–$0.20 |
| `/code-tour` | host model | none (AST script + docstring authoring) | 20k–60k | $0.10–$0.60 |
| `/dead-code-review` | host (Opus) | up to 5 lenses (2 × Haiku, 2 × Sonnet, 1 × Opus-tier), only those the repo has | 60k–180k | $0.20–$0.75 |
| `/sdlc` | host (Opus) | 3 × Haiku (sanity) + 1 × Sonnet (implement) + 1 × Haiku (test-runner) + 1 × Sonnet (plan check); review stage opt-in | 90k–280k | $0.85–$3.00 |

**Notes / caveats**:

- The "host model" / "orchestrator" is whichever model is running the
  Claude Code or Copilot session; the toolkit doesn't pin it. Costs
  above assume Opus for Plan-mode-bearing and fan-out-heavy skills
  (`/brainstorm`, `/sdlc`, `/dead-code-review`)
  and whatever the user has selected otherwise.
- **Orchestrator context dominates real cost.** An Opus orchestrator
  carrying a 100k-token codebase context across 5 sub-agent dispatches
  pays the input cost 5×; agent dispatch fees themselves are usually
  10–20% of the bill. Keeping orchestrator context tight is the highest-
  leverage cost lever.
- Sonnet is the right default for parallel sub-agents that do bounded
  code-search / pattern-match / judgement work. Opus is reserved for
  cross-module reasoning where one wrong call costs more than the whole
  fan-out. Haiku is right when the task is "find the regex match" not
  "judge what to do about it."
- These numbers are calibration, not budgeting. Real runs vary 3–5× with
  repo size, plan complexity, and how much context the orchestrator has
  already accumulated when the skill fires.
