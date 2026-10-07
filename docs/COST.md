# Model & cost reference

> **✓ Live contract — current and maintained.**

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
| `/docstring-sync` | host model | 0 (scan/`--report`/`--pointers-only`) or 1 × Sonnet per candidate file (triage) + 1 × Sonnet per ~8 files (rewrite); `models.docstring_sync: "opus"` opt-up | 10k–1.8M | $0.05–$8.00 |
| `/dead-code-review` | host (Opus) | up to 5 lenses (2 × Haiku, 2 × Sonnet, 1 × Opus-tier), only those the repo has | 60k–180k | $0.20–$0.75 |
| `/sdlc` | host (Opus) | 1 × Haiku + 2 × Sonnet (sanity: `paths` haiku, `completeness`/`gotchas` sonnet by default) + 1 × Sonnet (implement) + 1 × Haiku (test-runner) + 1 × Sonnet (plan check); review stage opt-in | 90k–280k | $0.90–$3.00 |

**Why the `/sdlc` row's low end moved ($0.85 → $0.90).** Stage 1.5's sanity fan-out now
defaults two of its three focuses (`completeness`, `gotchas`) to Sonnet instead of Haiku —
only `paths` still defaults to Haiku (see `docs/CONFIG.md`, `models.sanity`). Each focus
agent only reads the plan file, so it's a small slice of a typical run's tokens, but Sonnet's
list price is roughly double Haiku's per token — a small slice priced twice as high moves the
floor by a few cents. The high end doesn't move: it's already dominated by the
implement/plan-check agents, which were already Sonnet.

**`pipeline.fix_loop.escalate_last`**, when enabled with `models.cap: "opus"` (or no cap at all), makes the Stage 5 fix loop's final retry an Opus call instead of Sonnet — one
additional Opus-priced dispatch on a run that would otherwise have exhausted the budget at
Sonnet. Under `models.cap: "sonnet"` it is a no-op and changes nothing above; with no cap set it does raise the last iteration.

**A measured run, for calibration (2026-09):** one `/sdlc` run with the review stage **on**
(4 lenses at Opus, `cap: sonnet`) on a +1,200 / −230 line change came to **~$22** — 7–25× the
`/sdlc` row above. The split was Sonnet 61% / Opus 37% / Haiku 3%, and the Sonnet share was
almost entirely **cache reads** (~60M cache-read tokens against <1k fresh input) — i.e. the
orchestrator re-reading its own context turn after turn, not sub-agent work. Two lessons: the
table above is a lower bound for a review-on run, and the lever that matters on a run like that
is turn count × context size (delegate, stay `quiet`, keep the plan small), not the tier of the
3%-share Haiku calls. `scripts/token-audit.py --session <uuid>` gives the same split per run.

**Notes / caveats**:

- **`/docstring-sync` has two cost regimes.** A scan-only, `--report`, or
  `--pointers-only` run does no triage and no fan-out — the mechanical script
  (pointer, placeholder, param/return checks) is a free, no-model pass, and the
  low end of the row above (10k–40k tokens) is the host reading the rewrite
  rules and fixing only what the script flagged. A full run adds a triage
  sub-agent per candidate file (mechanical findings ∪ `body-newer`, typically
  20–30% of scanned docstrings; `--all` widens this to every docstring, ~3x the
  triage cost) and, after human confirmation, rewrite sub-agents batched ~8
  files each and capped at `--limit`; both dispatch Sonnet by default, Opus when
  `models.docstring_sync` is set to `"opus"`. That fan-out is what pushes the row's high end well
  past the scan-only ceiling.
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
