# Stages 5.7 / 5.8 — Adversarial review + fix loop (shared)

Canonical for `/sdlc-lite`. **Opt-in, permanently OFF by default** —
do not load this file unless the stage is enabled (see the enablement rule below).

**Opt-in, permanently OFF by default.** This stage activates only on an explicit
`--review-model <name>` flag or an explicit `pipeline.review_fix.enabled: true` in
`.claude/project.json`; `--no-review` always wins OFF. An absent or `enabled: false`
`pipeline.review_fix` block means OFF — there is no default-on flip, now or later. When
activated, two auto-off gates still apply: the diff is docs-only/touches no code surface (self-skip
— **except in skill-repo mode, which never self-skips this gate**, since `.md` skill files *are*
the code surface there and would otherwise silently disable the stage in the repo that dogfoods it).

Runs after Stage 5, before Stage 6, once enabled and not auto-off'd. Fans out
**one reviewer pass per configured lens** (parallel sub-agents on Claude; sequential inline passes
on Copilot/Codex), each at the **reviewer** model — `models.code_review` / `--review-model`,
default `opus`, resolved per `skills/sdlc/templates/models.md`. That axis is separate from the
`haiku < sonnet < opus` cap ladder and `models.cap` never lowers it.

**Which lenses run — `agents.code_review_lenses`.** Read the array from `.claude/project.json`;
when the key is absent, use all four defaults below. **Set fewer to cut the stage's cost roughly
linearly** — the fan-out is one reviewer call per lens at the reviewer model (Opus by default), so
`["correctness", "plan-alignment"]` is about half the cost of the full set, and `["correctness"]`
about a quarter. Pick by what the change actually risks: `correctness` is the highest-yield single
lens; add `security` for anything touching auth, endpoints, or user input; add `plan-alignment`
when the plan has acceptance criteria you care about; `config-env-docs` matters most when the diff
touches env vars, compose, or docs. An unrecognized lens name is ignored with one warning (the
config-schema enum is deliberately open so a repo can add its own). Print the resolved list —
`review lenses: <a, b, …> (N of 4 defaults)` — before dispatching, so a reduced fan-out is never
silent. The circuit breaker below may drop a lens from this resolved list at dispatch time.

**How many run — `agents.code_review_max_lenses`** (default `4`, so it is inert until set).
Applied **after** the circuit-breaker drop, truncating the resolved list **in order** — so
`1` keeps `correctness`. Use it to cut cost without having to name lenses, and without
re-editing the list if the defaults change. A non-integer or non-positive value falls through
to `4`; it must never resolve to `0`, which would silently disable the stage rather than fail it.

**The cap interaction — say it out loud when it applies.** Each lens is one call at the
*reviewer* model, plus one verify pass and one fix-planner at the same model. `models.cap` does
**not** govern this axis, deliberately. The interaction is easy to misread: `cap: sonnet` puts
the implementer on sonnet, which *satisfies* the independence check below, so the reviewer stays
at full `opus` and no bump/degrade warning ever fires. When a cap is set and the reviewer
outranks it, emit:

```
review: reviewer runs <model> on <n> lens(es) + verify + fix-planner. models.cap (<cap>) does
        NOT govern this axis — lower it with models.code_review, or cut the fan-out with
        agents.code_review_max_lenses. See templates/models.md.
```

Never "fix" this by capping the reviewer — the cap does not govern this axis, and pretending
otherwise just hides the cost. Lower `models.code_review` or cut the fan-out instead.

| Lens | What it looks for |
|---|---|
| `correctness` | Logic bugs, wrong SQL, races, param types, edge cases, side-effects. Prompt from `templates/review-correctness-checklist.md`. |
| `plan-alignment` | Every acceptance criterion in the plan actually met; no contract drift between plan and diff. |
| `config-env-docs` | Env-var names match across code/`.env.example`/compose; docs not stale; no new secrets. In skill-repo mode this lens repoints to `templates/stage-5-skill-repo.md`'s frontmatter/marketplace/template-reference checks instead — there's no `.env`/compose surface in a skill repo. |
| `security` | Injection (SQL/shell/template), missing authn/authz on new endpoints (incl. IDOR), secrets in code/logs, unsafe deserialization, SSRF/path-traversal, dependency/supply-chain risk, crypto misuse, sensitive-data exposure, XSS. Prompt from `templates/review-security-checklist.md`. Rides the reviewer-model axis like every lens — never `models.cap`. |

Each lens returns structured findings (`REVIEW_FINDING_SCHEMA`, defined in
`docs/REVIEW-FIX-STAGE.md` §6.2; `skills/sdlc/templates/state-schema.md` documents the resulting `review.json`
sidecar shape, not the schema itself): `{severity, file, line, defect, failure_scenario, fix}`.
`auto_fixable` is set later by the fix-planner (Stage 5.8) and merged in at that point — the lens
itself never returns or claims it.

**Verify pass (adversarial, evidence-required, default-refute):** one more call, same reviewer
model, that must attach a fresh falsifiable artifact to each finding it confirms — a re-read
file:line quote, a grep result, or one call-graph hop. A finding it can't ground this way is
refuted, not "probably true."

**Optional second pass** (`agents.code_review_passes: 2`, default `1`): one additional
completeness-critic call at a cheaper `models.code_review_second_pass` (default `sonnet`), given pass 1's
findings and told to find what pass 1 missed — never to re-judge or restate them. Findings are
unioned and fingerprint-deduped into pass 1's set, then the single verify pass runs once over the
combined set. This is a recall mechanism, never a vote.

**False-positive circuit breaker (Phase 4):** a per-lens rolling confirmed/raw ratio, tracked
across the last 20 runs in `.claude/pipeline/_review-stats.json`. A lens under 40% confirmed-rate
is auto-demoted from the default fan-out (logged in `review.json.data.demoted_lenses`); re-promoted
after 5 consecutive runs at ≥60%.

**Diff size is not bounded here.** Each lens reviews the whole diff. The levers that actually
exist are the fan-out ones above — `agents.code_review_lenses` and `agents.code_review_max_lenses`
— plus keeping the plan small enough that one run's diff is reviewable.

**Writes** `stage-outputs/review.json`. `review` is appended to `run.json.stages_completed`
whenever this stage actually ran (even with zero findings). A self-skip (never opted in, opted out
via `--no-review`/`enabled: false`, or the docs-only/no-surface auto-off gate in a
**non**-skill-repo run) is recorded in `run.json.stages_skipped` instead.

## Stage 5.8 — Fix loop

Only runs when Stage 5.7 produced **≥1 confirmed finding**. A fix-planner (reviewer model) drafts
a structured fix spec per confirmed finding, applying the `auto_fixable` rubric below.

**`auto_fixable` rubric (default-deny):** a finding is `auto_fixable: true` only if it corrects an
existing explicit contract (plan acceptance criterion, docstring/type signature, schema, test
assertion — not a reviewer opinion), does **not** change a user-observable default (config default,
UI copy, threshold constant, API response shape), names a concrete reproducible input in
`failure_scenario` (not a judgment call), and the independence check below didn't mark the run
`"degraded"`. Failing any of the first two gets `auto_fixable: false` with a `reason` field —
design decisions are never auto-fixed by construction, since the fix agent's prompt is built
exclusively from `auto_fixable:true` findings.

Per `pipeline.review_fix.mode`:
- **`interactive`** (default): present each fix spec for approve/edit/skip. Approved specs route
  through the same `runGatedFix()` pattern Stage 5 uses, but as a **new gate function** — Stage 5
  is hard-wired to the eval runner. Loop until clean or `agents.code_review_max_fix_loops`.
  `interactive` means auto-apply confirmed `auto_fixable:true` findings (bounded by budget), then
  always pause-and-return before Stage 6 with every remaining finding surfaced. True per-finding
  approve/edit/skip is prose-path-only (Claude session, Copilot, Codex can literally ask).
- **`auto`**: auto-approve every confirmed `auto_fixable: true` finding without prompting, bounded
  by `agents.code_review_max_fix_loops`. Design-decision findings (`auto_fixable: false`) are never
  auto-approved in any mode — that branch is a hard gate, enforced by construction, since the fix
  agent's prompt is built exclusively from `auto_fixable: true` findings. There is no per-finding
  confidence or consecutive-approval throttle; the `auto_fixable` rubric and the loop budget are
  the whole bound.
- **`off`**: emit findings to `review.json` only; Stage 5.8 does not run.

**Independence enforcement:** the reviewer model must differ in effective tier from the
implementer's effective tier (its default after the cap is applied); if they collide, the reviewer bumps
one tier up, or — if already at the ceiling — the run is marked `data.independence = "degraded"`
in `review.json` and every finding that run is surfaced only, never auto-fixed.

**Oscillation guard (fingerprint-based):** each confirmed finding gets a stable fingerprint —
`file + ":" + lens + ":" + floor(line / 10)`. Persist `fixed_fingerprints[]` per loop iteration.
Before approving a finding in loop `n+1`, check it against the union of all prior loops'
`fixed_fingerprints` — a match means oscillation (a later fix reintroduced an earlier one), not a
fresh bug: don't spawn another fix attempt, pause with `run.json.status = "paused"` and report the
original fix + regression side by side (same shape as Stage 5's persistent-mismatch pause).

**Writes a single cumulative** `stage-outputs/review-fix.json` (not per-iteration files), with a
`loops[]` array carrying one entry per iteration. `review-fix` is recorded once in
`run.json.stages_completed` regardless of loop count.

**Blocking posture:** a surviving HIGH-severity confirmed finding (auto-fixable and unresolved
after budget exhaustion, or a HIGH-severity design decision) **blocks** — Stage 6 does not create
a PR; `run.json.status = "paused"`, same shape as an eval max-loops pause.

**Post-fix validation:** if any fix was actually applied this run, re-run the Stage 5 `validate`
gate exactly once before Stage 6 (a single confirmation pass, not a fresh budget). A regression
there pauses the run — an objective break, not an adversarial opinion, so this always stops rather
than proceeding.

**Fix-loop budget:** its own `agents.code_review_max_fix_loops` (default `3`, `pipeline.review_fix.*`) —
**separate** from the shared 3-iteration budget used by Stage 5. Review findings
are a categorically different surface (defects a green suite structurally cannot catch, discovered
after all four of those gates already passed), so they get their own dial rather than racing a
shared counter.

