# Stages 5.7 / 5.8 — Adversarial review + fix loop (shared)

Canonical for `/sdlc`. **Opt-in, permanently OFF by default** —
do not load this file unless the stage is enabled (see the enablement rule below).

> **No sub-agent seam? (Copilot, Codex)** The dispatch instructions below describe the Claude
> path. On a runtime without sub-agents, do the same work **inline in the session** and produce
> the same structured result — but keep the discipline the dispatch existed to enforce: report
> only the structured summary, never paste raw tool or runner output into your context. That
> output is the single largest source of context bloat, and inline is exactly where it lands.

This stage activates only on an explicit
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

---

## Sidecar shapes (this stage only)

These live here rather than in `state-schema.md` because the stage is opt-in and permanently
OFF by default — a default run should not carry a thousand words describing files it will never
write. `state-schema.md` carries the envelope contract; this section carries the two shapes
that only exist when this stage runs.

#### `review` (Stage 5.7 -- only when the reviewer-model axis resolves ON)
```json
{
  "lenses": ["correctness", "plan-alignment", "config-env-docs", "security"],
  "reviewer_model": "opus",
  "independence": "ok",
  "passes_run": 1,
  "second_pass_model": null,
  "diff_lines_reviewed": 340,
  "partitioned": false,
  "findings": [
    {
      "finding_id": "f0-1",
      "lens": "correctness",
      "severity": "high",
      "file": "api/scrapers/ddg.py",
      "line": 42,
      "defect": "_unwrap_ddg_href double-decodes the href (parse_qs then unquote again)",
      "failure_scenario": "A scraped URL whose query value contains %26 is corrupted to & before storage.",
      "fix": "Drop the second unquote() call; parse_qs already unquotes."
    }
  ],
  "confirmed": [
    { "finding_id": "f0-1", "verify_confidence": 0.93, "evidence": "api/scrapers/ddg.py:42 -- `unquote(parse_qs(qs)['u'][0])`" }
  ],
  "demoted_lenses": [],
  "deferred_debt": []
}
```
`findings` is the raw merged fan-out output across all lenses (each tagged with its producing
lens and a `finding_id`). `passes_run` (1 or 2) and `models.code_review_second_pass` (the effective model
dispatched for the completeness critic, or `null` when `passes_run` is 1) record whether
`agents.code_review_passes` was 2 for this run. When `passes_run` is 2, each item in `findings`
additionally carries `pass: 1` or `pass: 2` (set at merge time, never by the reviewing or critic
agent itself); a `passes_run: 1` run never adds this field, so its absence means pass 1. This
`pass` tag is unrelated to the loop-scoped `finding_id` numbering described next -- two independent
axes that happen to share the word "pass."

**`finding_id` is loop-scoped, not run-global**: it is minted as `f<reviewPass>-<n>` where
`reviewPass` starts at 0 for the pre-fix-loop initial review (the pass this top-level `review.json`
snapshot reflects) and increments by one on every subsequent re-review inside Stage 5.8's fix loop
-- a stable cross-loop id is not attempted because the lens dispatch re-runs on every call, so a
later loop's "same" index is not guaranteed to name the same defect. `confirmed` is the subset that
survived the adversarial verify sub-pass, referenced back by `finding_id`; each
`confirmed[].verify_confidence` is copied verbatim from that finding's verify-verdict `confidence`
value -- not a separately-computed number. `deferred_debt` entries are out-of-scope issues surfaced
incidentally during review (each with a `debt_hash` dedup key, auto-appended once each to
`TASKS.md`). **If `confirmed` is empty, OR `pipeline.review_fix.mode` is `"off"`, Stage 5.8 is
skipped entirely** -- no `review-fix.json` is written. On the prose/overlay paths, `review-fix` is
recorded in `run.json.stages_skipped` for this self-skip.

#### `review-fix` (Stage 5.8 -- single cumulative sidecar; only when `review.json.confirmed` is non-empty)
```json
{
  "fix_loops_run": 2,
  "max_fix_loops": 3,
  "final_pass_count": 3,
  "final_fail_count": 0,
  "remaining_failures": [],
  "loops": [
    {
      "loop": 1,
      "fix_specs": [
        { "finding_id": "f0-1", "auto_fixable": true, "spec": "Remove the second unquote() in _unwrap_ddg_href (api/scrapers/ddg.py:42)." }
      ],
      "decisions": [
        { "finding_id": "f0-1", "action": "approved", "mode": "interactive", "reason": null }
      ],
      "fixed_fingerprints": ["api/scrapers/ddg.py:correctness:4"],
      "reverify": { "status": "pass", "remaining_findings": [] }
    }
  ]
}
```
Mirrors the shared fix-loop sidecar shape (`fix_loops_run`/`max_fix_loops`/`final_pass_count`/
`final_fail_count`/`remaining_failures`) with a `loops[]` array added for per-iteration detail.
`decisions[].action` is one of `approved`, `edited`, `skipped`; in `auto` mode `action` is still
`approved` but `reason` is populated (e.g. `"auto: confidence 0.93 >= threshold 0.85"`). A finding
with `auto_fixable: false` can never appear with `action: "approved"` except under `interactive`
mode with an explicit human approval -- the fix-planner routes design-decision findings to a forced
human prompt regardless of `pipeline.review_fix.mode`.

**`loops[n].fix_specs`/`decisions` reference ids from the review pass that ran *before* that
iteration's fix agent, not from `loops[n]`'s own re-review.** Concretely: `loops[0]` (loop 1) fixes
findings minted by the pre-loop initial review (`review.json`'s own `f0-*` ids); its `reverify`
field reports the result of the re-review that ran immediately *after* the fix, which mints a fresh
`f1-*` set. `loops[1]` (loop 2), if it runs, fixes findings from that `f1-*` re-review, and so on.
An id is only ever meaningful paired with the pass that minted it -- there is no guaranteed stable
identity for "the same defect" across loops; the oscillation guard uses a content fingerprint for
that instead. Persisted `fix_specs`/`decisions` are **id-keyed** (`finding_id`), never index-keyed
-- the fix-planner's agent-return shape is index-keyed, but the JS maps each `finding_index` to its
confirmed finding's `finding_id` when interpolating the fix agent's envelope payload, so raw indices
never reach the sidecar.

**`reverify` is never written by the fix agent itself, on either path.** The fix agent runs
*before* its own loop's re-review exists, so it cannot know that result.reason` is always `"workflow auto-apply"` (there
is no human channel there) rather than `null` -- the `null` shown in the example above is the
prose-path, human-interactive-approval case.

## `.claude/pipeline/_review-stats.json` — review circuit breaker (cross-run ledger)

Unlike every sidecar above, this file is **not per-run** — it is a rolling cross-run ledger, one
file per repo, keyed by lens. It backs the Review→Fix stage's false-positive circuit breaker
(repo-local, already covered by the existing `.claude/pipeline/` `.gitignore` entry):

```json
{
  "schema_version": 1,
  "lenses": {
    "correctness":     { "runs": [{ "raw": 3, "confirmed": 2, "ts": "2026-07-03T18:04:00Z" }], "demoted": false },
    "plan-alignment":  { "runs": [], "demoted": false },
    "config-env-docs": { "runs": [], "demoted": true },
    "security":        { "runs": [], "demoted": false }
  }
}
```

- `runs[]` is capped at the last 20 entries per lens (oldest evicted on push) — a rolling
  confirmed/raw ratio across the last 20 runs.
- `demoted` flips `true` once that lens's confirmed-rate (`sum(confirmed)/sum(raw)` over the
  window) drops under 40%, flips back `false` after 5 consecutive runs at ≥60%.
- **Writer:** the same Stage 5.7 persist step that writes `review.json` also appends this run's
  `{raw, confirmed, ts}` per dispatched lens to `_review-stats.json` and recomputes `demoted`.
  Every runtime writes the same file at the same path — there is no per-tool ledger. The resolved
  lens list for the **next** run is `agents.code_review_lenses` (or the four defaults) minus any
  lens currently `demoted` — demotion never changes which lenses ran *this* run, only which ones
  are dispatched on subsequent runs.
- `review.json.data.demoted_lenses` is this run's *view* of which lenses were skipped because
  `_review-stats.json` already marked them demoted going in — the two files are consistent by
  construction (one reads what the other most recently wrote).
- This mechanism (the sidecar, the writer-side update, and the demotion-aware lens filter) is
  **active**: the per-lens ledger in `_review-stats.json` backs live lens demotion (a lens whose
  confirmed-rate drops under 40% is demoted; 5 consecutive runs at ≥60% re-promote it, capped at the
  last 20 runs per lens). `REVIEW_LENSES` filters out demoted lenses from dispatch on every run, and
  `review.json.data.demoted_lenses` records which lenses were skipped because this ledger already
  marked them demoted going in.

---
