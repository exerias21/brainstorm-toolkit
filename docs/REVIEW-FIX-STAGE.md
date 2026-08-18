# Adversarial Review→Fix stage for `/sdlc` + `/sdlc-lite`

> **Target repo:** brainstorm-toolkit (this repo). Owns `skills/sdlc/`, `skills/sdlc-lite/`,
> `skills/sdlc/workflows/sdlc-pipeline.workflow.js`, `skills/sdlc/templates/*`, the four
> Copilot/Codex overlays, `docs/CONVENTIONS.md`, `templates/project.json.example`, `README.md`,
> and `CLAUDE.md`. This plan is implementation-ready: every claim below was checked against the
> live files, not assumed from the original Teacup-session write-up.
>
> **Status of this document:** synthesis of 7 independent grounding passes over the first draft.
> All corrections are folded in; all open questions are resolved (see "Design decisions
> (resolved)"). Nothing is left as a dangling fork for the implementer to guess at.
>
> **Canonical location:** this file lives at `docs/REVIEW-FIX-STAGE.md` (git-tracked). It was
> promoted here from the gitignored `plans/` working copy so the design contract is durable and the
> `CLAUDE.md`/`README.md` pointers (§7.6–7.7) resolve. Where §7.7's acceptance criterion says
> "`docs/REVIEW-FIX-STAGE.md` exists containing the reviewer-axis contract, the precedence chains,
> the `auto_fixable` rubric, D1–D17, and the regression-corpus table," it refers to **this file** —
> that content is already present below (§5, §8, §4.3, §11).
>
> **SHIPPED as of 2026-07-26 — this is now the design of record for a DELIVERED feature.**
> (An earlier revision of this header said "implementation has not started"; that is no longer
> true.) Live surfaces: `skills/sdlc/SKILL.md` Stages 5.7/5.8, `skills/sdlc-lite/SKILL.md`
> Stages 5.7/5.8, `sdlc-pipeline.workflow.js` (`phase('Review')` + the `review-fix` loop with its
> oscillation guard and post-fix-validate regression gate), and the
> `review-correctness-checklist.md` / `review-security-checklist.md` lens templates. The stage
> remains **opt-in, permanently** — it never runs unless explicitly enabled.
>
> **Two enumerated gaps are still open** (§7's TODO list, mirrored as a comment in
> `sdlc-pipeline.workflow.js`): the `max_diff_lines`/`max_files` cost-bound diff partition, and
> `auto_approve_after`/`confidence_threshold`-driven auto-approval throttling in `auto` mode.
> Those keys parse but do not yet gate. Shipped ≠ feature-complete.
>
> Where this document and the live files disagree on a *config key name*, the live files win:
> see the superseded-config banner at §6.1.
>
> **Revised 2026-07-05 for Claude Fable 5's sunset** (promotional access ends 2026-07-07 →
> usage-credit-billed): reviewer default is now Opus; the stage is opt-in (no default-on flip);
> Fable demoted to a usage-billed opt-in.
>
> **Added 2026-07-05 — optional second review pass.** `agents.code_review_passes` (default `1`,
> the existing single fan-out, unchanged) gains an opt-in `2`: one additional completeness-critic
> reviewer call at a separate, cheaper `models.code_review_second_pass` (default `sonnet`), run after pass 1's
> lenses return and unioned (never voted) into pass 1's findings before the single verify pass
> runs (§4.1, §6.1, §7.2, D17). Purely additive — does not change the single-pass default path, the
> Opus-default reviewer, or the stage's opt-in posture. (The config *namespace* has since moved to
> the top-level `models` / `agents` blocks — §6.1 banner.)

---

## 1. Summary

`/sdlc` and `/sdlc-lite` gain two new optional pipeline stages — **Stage 5.7 (adversarial
review)** and **Stage 5.8 (fix loop)** — that run after Stage 5.6 flowsim and before Stage 6
(deliver). They fan out N reviewer passes on distinct lenses (correctness, plan⇄code alignment,
config/env/docs, security), verify findings adversarially (default-refute), and drive confirmed,
auto-fixable findings through a bounded fix loop. Design-decision findings are never auto-fixed —
they are always surfaced to a human. The reviewer is (or approximates, depending on runtime — see
§5.5) a model independent of the implementer; the reviewer axis is a config/flag knob, default
`opus`, and is **structurally separate** from the existing `models.cap` / `--model` fan-out
ceiling — it must never pass through `capModel()`. The stage is **opt-in, permanently** (D8): it
never runs unless explicitly turned on via `--review-model <name>` or
`pipeline.review_fix.enabled: true` — there is no planned default-on flip. `fable` remains a valid,
explicit opt-in value (`--review-model fable`), but it is no longer the default: Claude Fable 5's
promotional/plan-included access ends 2026-07-07, and it is now billed via paid usage credits
outside plan weekly limits (§5.5).

This document also scopes six process-hardening items surfaced by the same retro into a labeled
**Companion changes** section (§12): three ship alongside this feature because they are either
prerequisites or trivial additions to files already open; three are explicitly routed elsewhere
(a not-yet-built feature's spec, and two consumer-repo `GOTCHAS.md` entries with zero toolkit-code
footprint).

---

## 2. Why (case study — the session that motivated this plan)

`/sdlc-lite` delivered the Community Search fixes and reported everything green: **969→981 tests
passed, flowsim 7/7 MATCH, plan-validate 8/8, container logs clean.** Then three independent
**Fable** review passes (correctness / plan⇄code alignment / config-env-docs) — run manually by
the orchestrator, no toolkit support — found **6 real bugs the green suite never caught**, plus a
live-data check surfaced a 7th:

1. `_unwrap_ddg_href` **double-decoded** URLs (`parse_qs` then `unquote` again) → `%26`→`&`
   silently corrupts scraped URLs. No test asserted it.
2. The new job-worker self-exit **reset in-memory weather state hourly** → WeatherAPI hammered
   24×/day. A side-effect no unit test modeled.
3. `backfill_event_dates` marked **one-off events as recurring** on any weekday word.
4. GUI radius change **didn't refetch the feed** (wrong query key invalidated).
5. An **over-broad geo deny-list** dropped within-range cross-county destinations.
6. `JOB_WORKER_MAX_UPTIME` missing from `.env.example`; a silent-failure warning skipped on an
   early return.
7. (live-data) The feed still **leaked ungeocodable Pasco rows** until a name-filter was added.

**Lesson:** "all tests green + flowsim match" ≠ "correct." An independent adversarial reviewer — a
*different* model from the implementer — catches a class of defect a plan-derived test suite
structurally cannot (side-effects, contract drift, double-decode, config consistency). The 3
passes cost ≈240k tokens total, ~1–6 min each. This should be a first-class, optional pipeline
stage, not a thing a human remembers to do by hand.

**Corrected framing (the original draft overclaimed 7/7):** of the 7 defects above, the 3-lens
design in this plan cleanly catches 5, correctly routes 1 to a human as a design decision (never
"catches and fixes" it), and cannot reach 1 at all (it's a live-data property, not a static-code
defect). See the full mapping in §11 (Regression corpus) — that table, not a blanket claim, is
this feature's actual, honest scope.

---

## 3. Grounding note — a pre-existing drift this plan must not paper over

`docs/CONVENTIONS.md` "Migration policy" (line 232) states: *"`/sdlc`, `/task`, and `/sdlc-lite`
are zero-flag by design and recognize no aliases."* That sentence is **already false today**,
independent of this plan: `skills/sdlc/SKILL.md`'s own "Model cap" section (line 211) and
`skills/sdlc/templates/models.md` document a live, working `--model <tier>` flag, wired into
`sdlc-pipeline.workflow.js` (`args?.model_cap`, `capModel()`). `skills/sdlc/SKILL.md`'s own
"## Arguments" section (line 60) still reads "Pass the plan file path. No flags." — also stale,
also already inconsistent with the Model-cap section 150 lines below it in the same file.

**Decision:** this plan does not treat "`/sdlc` is zero-flag by design" as binding — it is stale
documentation describing a state the repo left behind when `--model` shipped. This plan adds
`--review-model` and `--no-review` following the *actually-shipped* `--model` precedent (CLI flag
conventions in `docs/CONVENTIONS.md` §"Command-line flags", which remain valid and are followed
here). As a **companion, low-risk fix** (bundled into this change since it corrects a
self-contradiction in files this change already opens): update `docs/CONVENTIONS.md` line 232 to
drop the false "zero-flag by design" claim for `/sdlc`/`/sdlc-lite`, and fix
`skills/sdlc/SKILL.md`'s "## Arguments" section to actually list `--model`, `--review-model`, and
`--no-review` (see §6.4). `/task` keeps its zero-flag status untouched — this plan does not touch
`/task`.

---

## 4. What we're adding: Stage 5.7 / Stage 5.8

Canonical kebab stage names (per `docs/CONVENTIONS.md` "Stage names," never decimal-versioned in
machine-readable form; human prose keeps the "5.7"/"5.8" numbering for continuity with Stage
5.5/5.6): **`review`** (Stage 5.7) and **`review-fix`** (Stage 5.8). Both stages are optional and
skip cleanly (see §5.3 for the resolution/skip logic).

### 4.1 Stage 5.7 — `review` (adversarial review)

Runs after Stage 5.6 flowsim, before Stage 6 deliver, when the reviewer-model axis resolves to
"on" (§5.3). Fans out **4 reviewer passes on distinct lenses** (Claude/ultracode: parallel
sub-agents; Copilot/Codex/Claude-prose: sequential inline passes — see §7 for the three-way
split):

| Lens | What it looks for |
|---|---|
| `correctness` | Logic bugs, wrong SQL, races, param types, edge cases, side-effects. Prompt sourced from `skills/sdlc/templates/review-correctness-checklist.md` (Appendix A — a new template file, not inlined prose, per this repo's "no inline checklists" rule). |
| `plan-alignment` | Every acceptance criterion in the plan actually met; no contract drift between the plan and the diff. |
| `config-env-docs` | Env-var names match across code/`.env.example`/compose; docs not stale; no new secrets; (skill-repo mode: repoint to `templates/stage-5-skill-repo.md`'s frontmatter/marketplace/template-reference checks instead — there's no `.env`/compose surface in a skill repo). |
| `security` | Injection (SQL/shell/template), missing authn/authz on new endpoints (incl. IDOR), secrets in code/logs, unsafe deserialization, SSRF/path-traversal, dependency/supply-chain risk, crypto misuse, sensitive-data exposure, XSS. Prompt sourced from `skills/sdlc/templates/review-security-checklist.md`. Rides the reviewer-model axis like every lens — never `models.cap`; skill-repo mode applies its item-10 shell-injection check to skill prose + hook scripts. |

> **Lens-count note.** `security` was added as a later increment on top of the original
> three-lens design. The "3-lens" framing in the §11 regression-corpus analysis and the
> Phase-1 ships-list below is left intact as history — those describe the original three
> lenses; `security` was not evaluated against that corpus and did not ship in Phase 1.
> The live default fan-out is now **four** lenses (see `DEFAULT_LENSES`).

Each lens returns **structured findings** shaped by `REVIEW_FINDING_SCHEMA` (§6.2):
`{severity, file, line, defect, failure_scenario, fix, auto_fixable}`. `auto_fixable` is set by
the *fix-planner* step, not the reviewing lens itself (see §4.3's rubric) — the raw findings from
the lens pass carry no `auto_fixable` claim.

**Verify pass (adversarial, evidence-required, default-refute):** one more call, same reviewer
axis, that must attach a *falsifiable artifact* to each finding it confirms — a fresh
file:line quote (re-read in this call, not copy-pasted from the raw finding — a mismatch
auto-refutes), a grep result proving a claimed test gap is real, or one call-graph hop for a
claimed side-effect. A finding the verify pass cannot ground this way is refuted, not "probably
true." This is stronger than same-model re-judgment (which risks the reviewer rubber-stamping its
own hallucination) and costs nothing extra to specify.

**Optional second pass (recall, `review_fix.passes: 2`).** `agents.code_review_passes` defaults to
`1` — the single fan-out across the lenses above plus the one verify pass just described,
byte-for-byte unchanged. Setting it to `2` adds exactly **one** additional reviewer call after pass
1's lenses return: a **completeness critic**, dispatched at a separate, cheaper model
(`models.code_review_second_pass`, default `sonnet` — §6.1). It is explicitly prompted **not** to re-review from
scratch — it is given pass 1's findings as context and told to find what pass 1 **missed** (an
un-flagged side-effect, a config/env/docs drift, an off-by-one/boundary condition, an unverified
claim), never to re-judge or restate them. Its findings are **unioned** into pass 1's, fingerprint-
deduped against them (the same `fingerprint()` used by §4.2's oscillation guard), and this is a
**recall mechanism, never a vote or a consensus check** — the existing default-refute verify pass
already owns precision, and it then runs exactly once, over the combined (unioned, deduped) set,
not once per pass. **Rationale:** recall comes from a *different look* at the diff, not a *stronger
repeat* of the same look; a Sonnet- or Haiku-tier completeness critic captures most of the
missed-bug catch a second full reviewer fan-out would, at roughly 1/5–1/15 the cost of a second
Opus pass, and because the union only ever *adds* candidate findings that still have to clear the
same verify gate, a cheaper second pass can only add confirmed findings — it can never dilute the
result, since the verify pass still gates everything before anything is confirmed or acted on.
**Independence caveat:** the *primary* reviewer (Opus by default) is what satisfies §5.4's
independence-from-the-implementer requirement; the second pass is a bonus recall layer on top of
that, not a substitute for it. If `models.code_review_second_pass` happens to equal the model the implementer
used this run (e.g. a Sonnet second pass alongside the default Sonnet implementer), that pass
shares the implementer's blind spots — it still adds fresh-context/completeness value (a second
look, later, with pass 1's findings in hand), but **not** model-diversity. Setting
`second_pass_model: "haiku"` keeps the second pass both diverse and cheap in that common case.

**False-positive circuit breaker (per lens, cross-run):** track a rolling confirmed/raw ratio per
lens across the last 20 runs in `.claude/pipeline/_review-stats.json` (repo-local, already covered
by the existing `.claude/pipeline/` gitignore entry). A lens whose confirmed-rate drops under 40%
is auto-demoted from the default fan-out (dropped from dispatch, logged in
`review.json.data.demoted_lenses`) rather than let one noisy lens erode trust in the whole stage;
re-promote after 5 consecutive runs at ≥60%. This is per-lens, never the whole-stage kill switch —
see §9.1's mitigations table for the full rationale (this directly answers "what happens when the
reviewer cries wolf"). **Phase-gated:** this mechanism ships as Phase 4 (§9.2, renumbered — see D8
and §9.2's rollout note: there is no default-on burn-in gate anymore), once enough opt-in runs have
accumulated confirmed-rate history to demote against — see §6.3 for the sidecar's full shape and
writer.

**Cost bound:** before dispatch, sum `added + removed` from the run's already-collected
`data.files_changed[]` (Stage 2's numstat data — no new git call). Default ceilings:
`review.max_diff_lines` = 1500, `review.max_files` = 25 (both in `pipeline.review_fix.*`, §6.1).
Under both: review the full diff. Over either: partition files across the decompose lanes if the
run decomposed (`decompose.json.data.lanes[]`), else by `changed-files-gate.md` surface — each lens
reviews one partition, findings merge before verify. Record `data.diff_lines_reviewed`,
`data.partitioned`, `data.partition_count`.

**Writes** `stage-outputs/review.json` (schema in §6.3). `review` is added to
`run.json.stages_completed` whenever Stage 5.7 actually ran (even with zero findings). A self-skip
(never opted in — the permanent default, D8 — opted out via `--no-review`/`enabled: false`, or the
docs-only/no-surface gate in a **non**-skill-repo run — see §5.3 gate 1) is recorded in
`run.json.stages_skipped` instead, per `state-schema.md`'s documented convention.

**Workflow-path caveat (read once, applies everywhere this plan says "lands in
`stages_skipped`"):** that convention is honored today only on the **prose/overlay** paths, which
manage `run.json` by direct instruction. Confirmed live: `sdlc-pipeline.workflow.js` never writes
`stages_skipped` for *any* stage — every existing self-skip (e.g. the `evalsSkipped` branch at
line 565) is a `log()` line only, no array append. This is a **pre-existing gap** in the Workflow
script, not something this plan introduces or is responsible for closing. Stage 5.7/5.8's own
skip path (§7.2) follows that identical existing log-only pattern rather than inventing new
behavior — see §7.2's else branch and §10's acceptance criteria for the code-true, scoped-per-path
claim. **Skill-repo mode itself is never a self-skip condition for Stage 5.7** — per D6, it adapts
and runs; only the two gates above (opt-out, or a non-skill-repo docs-only diff) self-skip it.

### 4.2 Stage 5.8 — `review-fix` (fix loop)

Only runs when Stage 5.7 produced ≥1 confirmed finding. A **fix-planner** step (reviewer axis
model) drafts a structured fix spec per confirmed finding, applying the `auto_fixable` rubric
(§4.3). Then, per `pipeline.review_fix.mode`:

- **`interactive`** (default): present each fix spec for **approve / edit / skip**. Approved specs
  route through the *pattern* used by Stage 4's fix loop — reuse the `runGatedFix()` helper and
  fix-budget shape, but Stage 5.7/5.8 is a **new gate function**, not literally "Stage 4" (Stage 4
  is hard-wired to the eval runner; see §7.2 for exactly why a custom gate is required). Loop until
  clean or `agents.code_review_max_fix_loops` (own budget, §4.4).
  - **Workflow-tool limitation (state this plainly, don't gloss over it):** the Workflow tool has
    no mid-run human-prompt primitive — every existing pause point (Stage 1.5 critical findings,
    every `pauseOnBudget` call) is a hard stop-and-return, never an interactive question. Under
    the Workflow, `interactive` mode therefore means: **auto-apply fixes for confirmed
    `auto_fixable:true` findings (bounded by the review budget), then always pause-and-return**
    before Stage 6 — the human sees every design-decision finding and any surviving auto-fixable
    one in that single pause. True per-finding approve/edit/skip conversation is a **prose-path-only**
    capability (the orchestrating Claude session, Copilot, or Codex can literally ask); this is a
    Workflow-tool limitation, not a prose downgrade, and it is documented here so no implementer
    rediscovers it as a bug.
- **`auto`**: after `pipeline.review_fix.auto_approve_after` consecutive approvals (default 2),
  OR for findings whose verify-confidence ≥ `confidence_threshold` (default 0.85), auto-approve
  and continue without prompting. Design-decision findings (`auto_fixable: false`) are **never**
  auto-approved in any mode — see §4.3 for why this is a hard branch, not a prompt instruction.
- **`off`**: emit findings to `review.json` only; Stage 5.8 does not run at all.

**Oscillation guard (fingerprint-based):** each confirmed finding gets a stable fingerprint —
a plain composite string, `file + ":" + lens + ":" + floor(line / 10)`, not a hash (no crypto
dependency needed; the fingerprint is only an in-memory Set-equality key, so hashing it buys
nothing) — keyed on fields that actually exist on a
confirmed finding (`REVIEW_FINDING_SCHEMA`, §6.2, has no `defect_category` field; `lens` is the
one already tagged on every merged finding at the `runLenses`/`reviewGate` merge point, §7.2).
Bucketing the line number into tens is **stable under a small shift within the same 10-line
bucket** (an unrelated edit moving the defect a couple of lines does not change the fingerprint) —
it is **not** a guaranteed ±N-line tolerance: a shift that crosses a bucket boundary (line 19→20)
re-fingerprints the finding as "new," which is an acceptable failure mode (it fails open to one
extra fix attempt, never a false oscillation-pause). Persist `fixed_fingerprints[]` per loop iteration inside
`review-fix.json.data.loops[]`. Before approving a finding in loop `n+1`, check it against the
union of all prior loops' `fixed_fingerprints`. A match means oscillation (a later fix
reintroduced an earlier one), not a fresh bug — **do not** spawn another fix attempt; immediately
pause with `run.json.status = "paused"` and report the original fix + the regression side by
side, reusing Stage 5.6 flowsim's persistent-mismatch pause report shape.

**Writes a single cumulative** `stage-outputs/review-fix.json` (schema in §6.3) — **not**
per-iteration `review-fix-<n>.json` files. This matches the one-and-only existing multi-iteration
sidecar precedent in this repo, `stage-outputs/eval-fix.json` (`state-schema.md` line 239:
`fix_loops_run`, `max_fix_loops`, `final_pass_count`, `final_fail_count`, `remaining_failures`),
extended with a `loops[]` array carrying one entry per iteration. The canonical stage name
`review-fix` is recorded **once** in `run.json.stages_completed` regardless of loop count — same
pattern as `implement` being recorded once despite N `implement-<lane>.json` sidecars.

**Blocking posture (the one place `/sdlc` and `/sdlc-lite` diverge for this feature — same shape
as their existing Stage 6 divergence, not a new branching mechanism):**
- `/sdlc`: a surviving HIGH-severity confirmed finding (auto-fixable and unresolved after budget
  exhaustion, OR a HIGH-severity design decision) **blocks** — Stage 6 does not create a PR;
  `run.json.status = "paused"`, same shape as an eval max-loops pause.
- `/sdlc-lite`: **warns and hands off** — consistent with its existing warn-only secret-scan
  posture (`sdlc-pipeline.workflow.js` line ~696: "WARN-ONLY... NEVER block"). Surviving findings
  are listed prominently in the Stage 7 handoff report; the human decides whether to fix before
  committing.

**Post-fix validation (all three legs — canonical/§7.2/overlays — must say the same thing):** a
review-fix loop edits code *after* Stages 4/5/5.5/5.6 already validated the tree once. If any fix
was actually applied this run, re-run the Stage 5 `validate` gate **exactly once** before Stage 6
— not a fresh budget, a single confirmation pass. A regression there pauses the run for **both**
`/sdlc` and `/sdlc-lite` (unlike the severity-gated review-finding blocking above, a validate
regression is an objective break, not an adversarial opinion, so both modes stop rather than hand
off broken code).

### 4.3 The `auto_fixable` rubric (deterministic-first, not vibes)

A finding is `auto_fixable: true` only if **all** of these hold (default-deny otherwise):

1. The fix corrects an **existing, explicit contract** — a plan acceptance criterion, a
   docstring/type signature, a schema, a test assertion — not just "the reviewer's opinion of
   better behavior."
2. The fix does **not** change a **user-observable default** (a config default value, a UI copy
   string, a threshold/limit constant, an API response shape). Concretely: if the changed value
   also appears in `.env.example`, a frontend constants file, or a migration default, treat as a
   design decision.
3. `failure_scenario` names a **concrete, reproducible input** ("parse_qs then unquote again
   corrupts `%26`" — reproducible; "should the deny-list include Manatee county?" — a judgment
   call, correctly non-auto-fixable).
4. The reviewer-axis independence check (§5.4) did not mark this run `"degraded"`.

Any finding failing #1 or #2 gets `auto_fixable: false` with a `reason` field naming which
criterion failed. This is what makes "design decisions are never auto-fixed" a mechanical branch
(the fix agent's prompt is built exclusively from `auto_fixable:true` findings — a
`auto_fixable:false` finding physically never enters the payload) rather than an instruction the
model could ignore under pressure to "keep going" in `auto` mode.

### 4.4 Fix-loop budget — separate from the shared Verify-phase budget

Stage 5.8 uses **its own** `reviewBudget = makeBudget(pipeline.review_fix.max_fix_loops ?? 3)` —
**not** the existing `fixBudget` shared across Stages 4/5/5.5/5.6
(`sdlc-pipeline.workflow.js` line 389, comment: "shared across Stages 4/5/5.5/5.6"). Reasons:

1. That shared budget is deliberately pooled across four stages re-litigating the *same* failure
   surface (regressions against the plan's own test/eval/validator suite). Review findings are a
   *categorically different* surface — defects a green suite structurally cannot catch — discovered
   *after* all four of those gates already passed. Charging them against the same 3-count pool
   means a run that spent 2/3 iterations on a flaky eval has only 1 left for however many
   adversarial findings Fable surfaces, an accidental coupling with no design rationale.
2. `runGatedFix()`'s while-loop increments one shared counter regardless of which stage is
   failing — a shared budget makes `pauseOnBudget('review-fix', ...)` vs
   `pauseOnBudget('validate', ...)` a race on a single counter, not a real accounting of
   review-specific effort. The pause reason would misrepresent what was actually spent.
3. A separate budget gives an independent dial: a team can turn review-fix retries down (e.g. to 1,
   since the default-refute verify pass already suppresses most false positives) without touching
   the unrelated eval/validate budget.

---

## 5. Reviewer-model axis

### 5.1 What it is

A **model selection for the adversarial reviewer**, wholly independent of the implement/fan-out
ceiling (`--model` / `models.cap` / `models.md`). `models.md`'s entire contract is
`effective_tier = min(default_tier, cap)` over the closed rank `haiku(1) < sonnet(2) < opus(3)`
(confirmed live: `sdlc-pipeline.workflow.js` lines 22–27, `MODEL_TIER_RANK` +
`capModel(defaultTier, cap)`, which returns `defaultTier` unchanged for any `cap` not in that map).
Fable is not a fourth rung on that ladder — it is chosen for being a *different model from the
implementer*, not for being cheaper or pricier. **`fable` must never be passed to `capModel()`** —
doing so silently no-ops it back to whatever tier the call site already defaults to, with zero
error and zero log line. This is the single highest-priority implementation hazard in this plan.

**Fable demotion note.** Claude Fable 5's promotional/plan-included access ends 2026-07-07
(11:59:59 PM PT); it remains dispatchable but is now billed via paid usage credits, outside plan
weekly limits — so `--review-model fable` is an explicit, cost-aware opt-in, not the default. The
default reviewer model is `opus` (§5.2).

### 5.2 Resolution — reviewer MODEL (independent precedence chain)

```
--review-model <value>            (explicit, wins outright)
  > project.json  models.code_review
  > skill default: "opus"
```

Valid values: `fable`, `opus`, `sonnet`, `haiku`. `opus`, `sonnet`, and `haiku` let a run pin the
reviewer to a fan-out tier (`opus` is the default — see the Fable demotion note in §5.1 and §5.5
for why). `fable` opts into a model outside the tier ladder entirely — a deliberate, cost-aware
choice (Claude Fable 5's promotional/plan-included access ends 2026-07-07; it is now billed via
paid usage credits outside plan weekly limits), not a stand-in for the default. Invalid input
follows `models.md`'s own rule verbatim: an unknown `--review-model` value, or a malformed
`models.code_review`, is **ignored with one warning**, falling through to the next
precedence level — never a hard failure, never a guess.

**Runtime-availability fallback — resolved model can't be dispatched → highest available of
`opus`/`sonnet`/`haiku`, `opus` preferred (D16).** The rules above resolve a reviewer model *name*;
a separate failure mode is a resolved model the *runtime/account cannot dispatch at all* — distinct
from an *invalid name*, which falls through the precedence chain above. **Fable is explicitly NOT
an unavailability case:** Claude Fable 5 remains fully dispatchable after its 2026-07-07 sunset —
`agent({model:'fable'})` still works (D11) — it is simply billed via paid usage credits instead of
being free/plan-included. So an explicit `--review-model fable` opt-in never routes through this
fallback on cost or plan-limit grounds; the fallback exists only for a genuine dispatch failure. If
a reviewer dispatch fails because the resolved model truly cannot be dispatched, **fall back to the
highest available of `opus`/`sonnet`/`haiku`, preferring `opus`** — logged once
(`review: <model> unavailable — falling back to <tier>`). Because the default reviewer is already
`opus` (this section), the fallback target and the default coincide in the common case — this is a
general availability safety net, not a mechanism that exists because Fable used to be the cheap
default and is now gone. The **effective** model actually dispatched (§5.4's
`effectiveReviewModel`) — not the resolved name — is what `review.json.data.reviewer_model`
records, so the sidecar never claims a review ran on a model that wasn't available. To *force* a
specific reviewer deliberately (not as a fallback), use `--review-model <name>` (e.g.
`--review-model fable` for an explicit, cost-aware opt-in into Fable, or `--review-model
opus`/`sonnet`/`haiku` to pin a tier) — an explicit, first-class choice, not this fallback.

**No `--model fable` alias.** The original draft proposed overloading the existing `--model` flag
so a bare `--model fable` would "turn on review." This is **dropped** — see Design Decision D1.
**Implication for the prose that builds `args.model_cap` (§7.1):** a user typo'ing `--model fable`
(meaning `--review-model fable`) must not reach the Workflow as the raw string `"fable"` — live
code shows why this is a real hazard, not a hypothetical: `MODEL_CAP = args?.model_cap ?? 'sonnet'`
(`sdlc-pipeline.workflow.js` line 30) only falls back to `'sonnet'` when `model_cap` is
*absent/nullish*, and `capModel(defaultTier, cap)` (line 25) returns `defaultTier` unchanged for
any `cap` not in `MODEL_TIER_RANK` — so a truthy junk string doesn't get "ignored," it makes
`capModel()` a no-op at every call site, running every Opus dispatch (implement, every fix agent)
at full Opus with zero warning. The prose MUST apply `models.md`'s own "unknown value → ignore,
warn once, fall through" rule to `--model`'s raw value **before** it ever becomes
`args.model_cap` — never forward an unrecognized string through to the Workflow.

### 5.3 Resolution — ENABLEMENT (a separate precedence chain from model choice)

```
--no-review                                          → OFF, always wins
--review-model <value>                                → ON (explicit opt-in)
pipeline.review_fix.enabled: true                    → ON (explicit opt-in), subject to the two auto-off gates below
pipeline.review_fix.enabled: false | omitted | absent → OFF (default)
```

**Opt-in, permanently (D8).** There is no default-on flip, planned or scheduled.
`pipeline.review_fix.enabled` defaults to `false`, and an absent `pipeline.review_fix` block also
means OFF — "omitted" never resolves to ON. The stage activates only on an explicit
`--review-model <name>` flag or an explicit `pipeline.review_fix.enabled: true` in `project.json`.
`--no-review` always wins over either. §6.1's shipped `"enabled": false` is the permanent day-one
(and every-day) default — there is no later phase where that default flips.

**Auto-off gates** (apply even when the chain above resolves ON):
1. **Docs-only / no-surface diff — does NOT apply in skill-repo mode.** Reuse the *real* existing
   primitive: `touchedSurfaces()` (`sdlc-pipeline.workflow.js` lines 188–192), already computed once
   per run as `const touched = touchedSurfaces(changedFiles, discipline)` at line 558 (in scope for
   the Stage 5.7 insertion point) and consumed by Stage 5's e2e/visual trigger and Stage 5.5's
   validator selection. If `touched` is empty or `{docs}`-only, Stage 5.7 self-skips — **unless
   `skill_repo_mode` is true**, in which case this gate is skipped entirely: in a skill repo,
   `.md` skill files (classified `docs` by `surfacesFor()`'s default globs, `ext === 'md'`) **are**
   the code surface, so applying this gate there would make Stage 5.7 self-skip on virtually every
   skill-repo change — silently disabling the stage in the exact repo (brainstorm-toolkit) that
   dogfoods it, contradicting D6 below. (The original draft's phrase "reuse the existing 'no test
   surface' degeneracy check" pointed at nothing real — the only similarly-named check is Stage
   5.5's project-level "no `eval.runner` configured" gate, which is unrelated. This plan reuses
   `touchedSurfaces()` directly — no new helper, see §7.2.)
2. **Skill-repo mode** — Stage 5.7 **adapts** rather than skips (see Design Decision D6); Stage
   5.8 is unchanged. (This is the same exemption as gate 1 above, stated from the other direction:
   skill-repo mode is never auto-off'd by either gate.)

### 5.4 Independence enforcement

At dispatch time, resolve both the implementer's effective tier and the reviewer's resolved
value. The implementer's effective tier is **`capModel('opus', MODEL_CAP)`** — not a generic
`capModel(default, MODEL_CAP)` — because `'opus'` is the actual default tier passed at the Stage 2
single-agent implement call site (`sdlc-pipeline.workflow.js` line 465:
`{ label: 'implement', phase: 'Implement', schema: IMPLEMENT_SCHEMA, model: capModel('opus',
MODEL_CAP) }`); using any other default here (e.g. `'sonnet'`) computes the wrong tier and lets a
same-tier reviewer/implementer pair silently register as independent (see the §7.2 snippet, which
must use this same call). If the run decomposed into per-lane dispatch (§7.2's lane note), each
lane's own tier is a separate, out-of-scope concern for this run-level check — this resolves only
the single-agent implement path's tier. If the reviewer value is one of the three tier names (not
`fable`) **and** it resolves to the *same* tier the implementer used, independence is not
established: bump the reviewer one tier up (both `sonnet` → reviewer runs `opus`; if implementer
is already `opus`, mark `data.independence = "degraded"` in `review.json` and warn). The bumped
value is the *effective* dispatch tier (§7.2's `effectiveReviewModel`, distinct from the raw
resolved `REVIEW_MODEL`) — every reviewer/verify/fix-planner call, and `review.json.data.
reviewer_model`, use it once a bump applies. Any finding produced under a `"degraded"` run fails
rubric criterion #4 (§4.3) and can never be auto-fixed — only surfaced. `fable` is independent of
the tier ladder by construction, so this check only applies when the reviewer resolves to one of
the three tier names — whether from an explicit `--review-model {opus|sonnet|haiku}` override or
from the **default resolution itself**, since the default is now `opus` (§5.2).

**Now-default-relevant case.** Before the Fable sunset, this check only ever fired on an explicit
`--review-model {opus|sonnet|haiku}` override, because the default reviewer (`fable`) was outside
the ladder. With the default reviewer now `opus`, the plain default configuration — implementer at
`MODEL_CAP`'s default `sonnet`, reviewer at its default `opus` — is independent with no action
needed. But `--model opus` (bumping the implementer to `opus`) combined with the *unmodified*
default reviewer (`opus`) is a same-tier collision that cannot be bumped any higher: `data.
independence` is recorded `"degraded"`, a warning is logged, and every finding that run is
surfaced, never auto-fixed (rubric criterion #4). This is now the single most common way a run
lands in `"degraded"` — it needs no `--review-model` flag at all, just `--model opus` on its own.

### 5.5 Dispatch mechanism — settled (confirmed live)

**Confirmed:** `agent({model:'fable'})` dispatches `claude-fable-5` natively on the Claude
Agent/Task seam and the Workflow's `agent()` helper — no dispatchability spike and no
persona-fallback dual-path were needed, and this remains true after Fable's 2026-07-07 sunset
(D11). (A *runtime-availability* fallback to the highest available of `opus`/`sonnet`/`haiku` — for
a genuine dispatch failure on whichever model resolves — is a separate, retained safety: §5.2 /
D16; it is not keyed to Fable specifically, and Fable's own dispatchability is never in question.
That is not the persona-fallback the earlier draft carried; it's a one-line model swap at the
dispatch seam, not a second review mechanism.) Stage 5.7/5.8
dispatch the reviewer/verify/fix-planner agents with `model: REVIEW_MODEL` directly, never through
`capModel()`, exactly as `agent()` calls elsewhere in the Workflow already do for
`haiku`/`sonnet`/`opus` (§7.2). Record the model id `claude-fable-5` in
`skills/sdlc/templates/models.md` §Dispatch (§5.6) for the implementer, alongside the
demotion note below.

This is independent of §5.4's capModel-bypass rule: `fable` still must never be passed to
`capModel()` (that ladder only ranks haiku/sonnet/opus) — what's settled here is only that the
dispatch seam *accepts* the literal string `"fable"`, not that it should ever go through the cap.

**Fable demotion (2026-07-07 sunset).** Claude Fable 5's promotional/plan-included access ends
2026-07-07 (11:59:59 PM PT). After that date it remains exactly as dispatchable as described
above — `agent({model:'fable'})` still works, D11 stays true — but it is now billed via paid usage
credits, outside plan weekly limits, rather than being free/plan-included. That cost shift, not a
dispatch regression, is why `fable` is no longer the default reviewer model (§5.2): it demotes to
an explicit, cost-aware `--review-model fable` opt-in. Nothing in this section's dispatch
confirmation changes as a result — `fable` is exactly as reachable as it always was, it is simply
no longer free.

**Out of scope for this resolution — a separate, still-legitimate path:** the Copilot/Codex
overlays (§7.4) have no parallel sub-agent seam at all; they review under an adversarial persona
in the session model, or a reachable MCP reviewer if configured. That approximation is unaffected
by this dispatch confirmation — it was never a "does the seam accept fable" question on that
runtime, since there is no seam to ask.

### 5.6 Canonical contract file

All of the above is codified once in a **new sibling file to `models.md`**:
`skills/sdlc/templates/models.md` (spec in §6.1's companion note). `skills/sdlc/SKILL.md`'s
Stage 5.7 section gets a one-line pointer to it — the resolution rules, the invalid-input rule,
the runtime-availability fallback to the highest available of `opus`/`sonnet`/`haiku` (§5.2 / D16),
the Fable demotion note (§5.1/§5.5: usage-billed opt-in, not the default), and the dispatch note
(§Dispatch: `claude-fable-5`, confirmed live per §5.5) are never inlined in
the skill prose (same "reference `templates/*`, don't inline" discipline `models.md` itself
follows).

---

## 6. Config & state schema

### 6.1 `templates/project.json.example` — new `pipeline.review_fix` block

> **⚠ SUPERSEDED 2026-07-26 — read `skills/sdlc/templates/models.md` for the live config
> shape.** This section (and the JSON block below) records the *original* nested layout. The
> model-tier and count keys have since been consolidated into top-level `models` / `agents`
> blocks, and the old names are **no longer read** — a repo still using one silently gets the
> built-in default. The *behavior* keys stayed put. Mapping:
>
> | This document says | Live key |
> |---|---|
> | `pipeline.review_fix.model` | `models.code_review` |
> | `pipeline.review_fix.second_pass_model` | `models.code_review_second_pass` |
> | `pipeline.review_fix.lenses` | `agents.code_review_lenses` |
> | `pipeline.review_fix.passes` | `agents.code_review_passes` |
> | `pipeline.review_fix.max_fix_loops` | `agents.code_review_max_fix_loops` |
> | `pipeline.decompose_min_tasks` | `agents.decompose_min_tasks` |
> | `pipeline.review_fix.enabled` / `.mode` / `.blocking` / `.confidence_threshold` / `.auto_approve_after` / `.max_diff_lines` / `.max_files` | **unchanged** — stage behavior, not model or count selection |
>
> The same rename applies to every `cfg.review_fix?.*` code excerpt later in this document
> (§7 onward) and to the `pipeline.review_fix.*` key names in the §11 design-decision table,
> which is preserved as a historical record of what was decided, not as current API.
> The *sidecar* field names (`review.json`'s `reviewer_model`, `second_pass_model`,
> `lenses`, `passes_run`) are **unchanged** — those are run outputs, not config.

Renamed away from the original draft's `pipeline.review.*` to avoid colliding with the
**already-existing, different** `pipeline.skip_review` key (`templates/project.json.example` line
70; `skills/sdlc/SKILL.md` Stage 6 step 6: "Invoke `/review` on the branch (skip if
`pipeline.skip_review`)" — a post-PR, same-model, human-readability diff pass, structurally
unrelated to this pre-PR, independent-model, potentially-blocking adversarial stage). Insert after
the existing `poka_yoke` key:

```json
  "pipeline": {
    "_comment": "Optional. Knobs read by /sdlc. Most keys default to false/unset; decompose_min_tasks defaults to 6 when unset.",
    "skip_secret_scan": false,
    "skip_review": false,
    "_decompose_min_tasks_comment": "Optional. Stage 2 fans out into per-surface lanes only when surfaces>=2 AND task_count>=this AND the file sets are disjoint. Default 6.",
    "decompose_min_tasks": 6,
    "_skip_workflow_comment": "Claude-only off-switch for every Workflow-backed skill (/sdlc, /sdlc-lite, and /brainstorm-deep Pass 3). When true, they use their prose path instead of the deterministic Workflow even when ultracode is on. Copilot/Codex always use the prose path (no Workflow tool).",
    "skip_workflow": false,
    "_poka_yoke_comment": "Claude-only. See AGENTS.md 'Hooks (Claude-only)'.",
    "poka_yoke": false,

    "review_fix": {
      "_comment": "Optional, OFF by default. Adversarial Review->Fix stage (Stage 5.7 review / Stage 5.8 fix loop) for /sdlc and /sdlc-lite -- runs after Stage 5.6 flowsim, before Stage 6. DIFFERENT feature from 'skip_review' above: skip_review silences the single-pass built-in /review diff check at Stage 6 (post-PR, same model); review_fix is a separate pre-PR N-lens adversarial review + fix loop, default reviewer model 'opus' (see skills/sdlc/templates/models.md). Both toggle independently. Omit this whole block to accept the defaults below (stage stays OFF). OPT-IN, PERMANENTLY (plan D8): there is no default-on flip, planned or shipped. An explicit --review-model <name> flag or an explicit enabled:true here is required to activate the stage; omitted, absent, or enabled:false all mean OFF.",
      "enabled": false,
      "model": "opus",
      "_model_comment": "Reviewer-model name. Default 'opus' -- a SEPARATE axis from models.cap / --model (see skills/sdlc/templates/models.md, 'Reviewer model is a separate axis'). Valid values: opus, sonnet, haiku, fable -- none of the four is ever passed to capModel(). Override per-run with --review-model <name> (e.g. --review-model fable for an explicit, cost-aware opt-in into Claude Fable 5 -- its promotional/plan-included access ends 2026-07-07; it remains dispatchable but is now billed via paid usage credits outside plan limits, which is why it is no longer the default). RUNTIME-AVAILABILITY FALLBACK (plan D16): if the resolved model can't be dispatched at all, the stage falls back to the highest available of opus/sonnet/haiku, opus preferred (logged) rather than no-op'ing; review.json.data.reviewer_model records the effective model actually used.",
      "mode": "interactive",
      "_mode_comment": "One of 'interactive' (default: each confirmed finding's fix spec is presented for approve/edit/skip -- degrades to auto-fix-then-pause under the Claude Workflow tool, which has no mid-run prompt primitive), 'auto' (auto-approve after auto_approve_after consecutive approvals OR confidence >= confidence_threshold -- design-decision findings, auto_fixable:false, are NEVER auto-approved regardless of mode), 'off' (report only, Stage 5.8 does not run).",
      "max_fix_loops": 3,
      "_max_fix_loops_comment": "Own budget, separate from the shared 3-iteration budget across Stages 4/5/5.5/5.6 -- see the plan's 'Fix-loop budget' section for why sharing it would be wrong.",
      "auto_approve_after": 2,
      "confidence_threshold": 0.85,
      "_confidence_threshold_comment": "auto mode only. A confirmed finding's adversarial-verify confidence >= this value lets it bypass the auto_approve_after counter.",
      "blocking": true,
      "_blocking_comment": "Whether a surviving HIGH-severity confirmed finding blocks Stage 6. Defaults true (matches /sdlc's PR-gate posture); /sdlc-lite treats this as false-equivalent regardless of the value here (warn-and-handoff is its posture by design, consistent with its warn-only secret scan).",
      "max_diff_lines": 1500,
      "max_files": 25,
      "_cost_bound_comment": "Above either ceiling, the diff is partitioned across decompose lanes (or changed-files-gate surfaces) so no single reviewer call carries the whole diff.",
      "lenses": ["correctness", "plan-alignment", "config-env-docs", "security"],
      "_lenses_comment": "Parallel reviewer-agent focuses fanned out at Stage 5.7. Lens names are lowercase-kebab (CONVENTIONS.md identity rule) -- echoed verbatim into stage-outputs/review.json.",
      "passes": 1,
      "_passes_comment": "Optional, default 1 -- the single fan-out across the lenses above plus the existing default-refute verify pass, UNCHANGED. Set to 2 to add ONE additional completeness-critic reviewer call, at second_pass_model below, run after pass 1's lenses return and given pass 1's findings as context -- it is prompted to find what pass 1 MISSED (an un-flagged side-effect, a config drift, an off-by-one/boundary, an unverified claim), not to re-review from scratch. Its findings are UNIONED into pass 1's (fingerprint-deduped, same fingerprint() as the section 4.2 oscillation guard) -- a recall mechanism, never a vote/consensus -- and the single verify pass then runs once over the combined set. Any value other than the integer 2 is treated as 1 (plan D17).",
      "second_pass_model": "sonnet",
      "_second_pass_model_comment": "Only read when passes=2. A DIFFERENT, cheaper model than the Opus primary reviewer above -- recall comes from a different look, not a stronger repeat. Default 'sonnet' (~1/5 the Opus cost, most of the missed-bug catch). 'haiku' is cheaper still and maximally diverse when the implementer itself resolved to sonnet (this repo's common default, see models.cap) -- a sonnet-vs-sonnet second pass still adds fresh-context/completeness value but not model-diversity (section 5.4 is NOT re-run for this axis; that independence bump/degrade check applies only to the primary reviewer model above). Resolved the same way as the reviewer-model axis (config value with an invalid/unrecognized value ignored, one warning, falling through to the default) and NEVER passed through capModel() -- 'opus' is a valid override for a full second-Opus completeness pass; see plan D17."
    }
  }
```

CLI flags (documented per `docs/CONVENTIONS.md`'s existing "Command-line flags" form —
`--no-X` boolean negation, `--X <value>` mode/enum):

- `--review-model <fable|opus|sonnet|haiku>` — per-run reviewer override; implies enablement (§5.3).
- `--no-review` — fully skip Stages 5.7/5.8 for this run.

### 6.2 Schemas — `REVIEW_SCHEMA`, `VERIFY_VERDICT_SCHEMA`

Insert near the existing schema block in `sdlc-pipeline.workflow.js` (after `GATE_RESULT_SCHEMA`,
line 301), matching the file's existing flat-JSON-Schema style used for `PARSE_SCHEMA`,
`SANITY_SCHEMA`, `GATE_RESULT_SCHEMA`:

```js
// Stage 5.7 reviewer output. One call per lens; the agent may return 0..N findings.
// auto_fixable is NOT set here -- the reviewing lens only reports the defect; the
// fix-planner (Stage 5.8) applies the rubric in the plan's "auto_fixable rubric" section.
const REVIEW_FINDING_SCHEMA = {
  type: 'object',
  required: ['severity', 'file', 'defect', 'failure_scenario', 'fix'],
  properties: {
    severity: { type: 'string', enum: ['low', 'medium', 'high'] },
    file: { type: 'string' },
    line: { type: ['integer', 'null'] },
    defect: { type: 'string', description: 'one-sentence statement of the defect' },
    failure_scenario: { type: 'string', description: 'concrete inputs/state -> wrong output/crash' },
    fix: { type: 'string', description: 'the specific change to make' },
  },
}
// Merge-time-only fields -- added by the JS merge step in section 7.2's reviewGate(), never
// emitted by the reviewing lens (or second-pass critic) agent itself, so neither is listed in
// the properties above: `finding_id` (existing) and, only on a `agents.code_review_passes: 2`
// run, `pass` (1 | 2) -- which review pass surfaced this finding, section 4.1 / D17. A pass:1 run
// (the default) never sets `pass` at all; its absence means pass 1. NOTE ON A NAME COLLISION: this
// `pass` field (the lens-fan-out vs. completeness-critic axis added by review_fix.passes) is a
// DIFFERENT axis from `reviewPassN` / the `f<passLabel>-<n>` finding_id prefix used elsewhere in
// section 7.2, which counts reviewGate() re-review iterations across the Stage 5.8 fix loop --
// two independent meanings of "pass" in this document, disambiguated by field name (`pass` vs.
// the finding_id's numeric prefix) and never combined into one integer.

const REVIEW_SCHEMA = {
  type: 'object',
  required: ['lens', 'findings'],
  properties: {
    // NOT a hardcoded enum: agents.code_review_lenses (§6.1) is project-configurable, and
    // the circuit breaker (below) can demote a default lens at runtime -- a fixed
    // ['correctness','plan-alignment','config-env-docs','security'] enum would reject a customized or
    // demotion-adjusted lens set. Validate lens membership in JS against the run's OWN
    // resolved lens list instead (see REVIEW_LENSES resolution in §7.2), not in the schema.
    lens: { type: 'string' },
    findings: { type: 'array', items: REVIEW_FINDING_SCHEMA },
  },
}

// Stage 5.7 default-refute, evidence-required verify pass. One verdict per input
// finding, indexed (not content-matched) so a paraphrase can't cause a false
// confirm/refute. `evidence` is mandatory when verdict === 'confirmed' -- a
// verify call that can't produce it must refute instead of guessing. `confidence`
// is REQUIRED on every verdict (not just confirmed ones) -- it is the value both
// the `auto` mode gate (`confidence_threshold`, §4.2) and `review.json.confirmed[].
// verify_confidence` (§6.3) depend on; without it here, neither is implementable.
const VERIFY_VERDICT_SCHEMA = {
  type: 'object',
  required: ['finding_index', 'verdict', 'rationale', 'confidence'],
  properties: {
    finding_index: { type: 'integer' },
    verdict: { type: 'string', enum: ['confirmed', 'refuted'] },
    rationale: { type: 'string', description: 'one line: the evidence that confirms it, or why it is a nit/hallucination' },
    evidence: { type: ['string', 'null'], description: 'a fresh file:line quote, grep hit, or one-hop call-graph fact -- required (non-null) when verdict=confirmed' },
    confidence: { type: 'number', minimum: 0, maximum: 1, description: 'how confident this verdict is, 0-1. For a confirmed verdict this becomes review.json.confirmed[].verify_confidence and, in auto mode, is compared against confidence_threshold (see section 4.2 / 6.1) to decide auto-approval.' },
  },
}

// Stage 5.8 fix-planner output: applies the auto_fixable rubric to each confirmed finding.
const FIX_SPEC_SCHEMA = {
  type: 'object',
  required: ['finding_index', 'auto_fixable', 'spec'],
  properties: {
    finding_index: { type: 'integer' },
    auto_fixable: { type: 'boolean' },
    reason: { type: ['string', 'null'], description: 'required (non-null) when auto_fixable=false -- which rubric criterion failed' },
    spec: { type: 'string', description: 'the fix instruction the fix agent will execute' },
  },
}
```

**Adapter note:** `runGatedFix()` (line 317) expects a gate returning `GATE_RESULT_SCHEMA`
(`{green, failures[]}` where each failure is `{name, detail, file}`) — too thin to carry
`severity`/`auto_fixable`/`fix` through to the design-decision surfacing step. Stage 5.7/5.8 does
**not** call `runGatedFix()` directly; it uses a custom `reviewGate()` (spec in §7.2) that keeps
the rich finding objects and only projects a thin `{name, detail, file}` shape for the loop's own
green/fail bookkeeping, reusing `runGatedFix`'s *budget pattern*, not its gate-signature contract.

### 6.3 `state-schema.md` additions

**Directory layout** (insert between `flowsim.json` and `secret-scan.json`):

```
    flowsim.json
    review.json             # Stage 5.7 -- only when a reviewer resolves (see enablement chain)
    review-fix.json         # Stage 5.8 -- only when review.json.data.confirmed is non-empty; single cumulative file, data.loops[] holds one entry per iteration (NOT numbered review-fix-<n>.json files)
    secret-scan.json
```

Extend the canonical kebab-name sentence: "...`flowsim`, `review`, `review-fix`, `secret-scan`,
`pr-create`." Note: `review-fix`'s internal `loops[]` index is a bounded loop counter
(`max_fix_loops` default 3), **not** an artifact ID — it is not zero-padded and does not fall
under the `pbi-001`/`task-001` convention.

**Per-stage `data` shapes** (insert after the existing `#### eval-fix` subsection, before
`#### validate`):

```markdown
#### `review` (Stage 5.7 -- only when the reviewer-model axis resolves ON)
```
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
```
`findings` is the raw merged fan-out output across all lenses (each tagged with its producing
lens and a `finding_id`). `passes_run` (1 or 2) and `models.code_review_second_pass` (the effective model
dispatched for the completeness critic, or `null` when `passes_run` is 1) record the section
4.1/D17 second-pass knobs actually used this run. When `passes_run` is 2, each item in `findings`
additionally carries `pass: 1` or `pass: 2` (set at the same merge point, never by the reviewing or
critic agent itself — see the note beside `REVIEW_FINDING_SCHEMA`, §6.2); a `passes_run: 1` run
never adds this field, so its absence means pass 1. This `pass` tag is unrelated to the loop-scoped
`finding_id` numbering described next — two independent axes that happen to share the word "pass."
**`finding_id` is loop-scoped, not run-global**: it is minted as
`f<reviewPass>-<n>` where `reviewPass` starts at 0 for the pre-fix-loop initial review (the pass
this top-level `review.json` snapshot reflects) and increments by one on every subsequent
re-review inside Stage 5.8's fix loop — see §7.2's `reviewGate()` for why a stable cross-loop id
is not attempted (the lens dispatch re-runs on every call, so a later loop's "same" index is not
guaranteed to name the same defect). `confirmed` is the subset that survived the
adversarial verify sub-pass, referenced back by `finding_id`; each `confirmed[].verify_confidence`
is copied verbatim from that finding's `VERIFY_VERDICT_SCHEMA.confidence` value (§6.2) — not a
separately-computed number. `deferred_debt` entries are
out-of-scope issues surfaced incidentally -- see Appendix B for the mechanism and dedup
rule. **If `confirmed` is empty, OR `pipeline.review_fix.mode` is `"off"`, Stage 5.8 is skipped
entirely** -- no `review-fix.json` is written. On the prose/overlay paths, `review-fix` is recorded
in `run.json.stages_skipped` for this self-skip, per `state-schema.md`'s convention; on the
Workflow path this is the same pre-existing log-only gap noted in §4.1's "Workflow-path caveat"
(the skip is logged, not array-appended) -- not a special case Stage 5.8 invents.

#### `review-fix` (Stage 5.8 -- single cumulative sidecar; only when `review.json.confirmed` is non-empty)
```
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
```
Mirrors `eval-fix.json`'s top-level shape (`fix_loops_run`/`max_fix_loops`/`final_pass_count`/
`final_fail_count`/`remaining_failures`) with a `loops[]` array added for per-iteration detail.
`decisions[].action` is one of `approved`, `edited`, `skipped`; in `auto` mode `action` is still
`approved` but `reason` is populated (e.g. `"auto: confidence 0.93 >= threshold 0.85"`). A finding
with `auto_fixable: false` can never appear with `action: "approved"` except under `interactive`
mode with an explicit human approval -- the fix-planner routes design-decision findings to a
forced human prompt regardless of `pipeline.review_fix.mode`.

**`loops[n].fix_specs`/`decisions` reference ids from the review pass that ran *before* that
iteration's fix agent, not from `loops[n]`'s own re-review.** Concretely: `loops[0]` (loop 1) fixes
findings minted by the pre-loop initial review (`review.json`'s own `f0-*` ids, per the note
above); its `reverify` field reports the result of the re-review that ran immediately *after* the
fix, which mints a fresh `f1-*` set. `loops[1]` (loop 2), if it runs, fixes findings from that
`f1-*` re-review, and so on. An id is only ever meaningful paired with the pass that minted it —
there is no guaranteed stable identity for "the same defect" across loops (see §7.2's
`reviewGate()` comment); the oscillation guard (§4.2) exists precisely because ids cannot be
relied on for that and uses a content fingerprint instead. Persisted `fix_specs`/`decisions` are
**id-keyed** (`finding_id`, as shown above), never index-keyed: §6.2's `FIX_SPEC_SCHEMA` is the
fix-planner's *agent-return* shape only — the JS maps each `finding_index` to its confirmed
finding's `finding_id` when interpolating the fix agent's envelope payload (§7.2), so raw indices
never reach the sidecar.

**`reverify` is never written by the fix agent itself, on either path.** The fix agent runs
*before* its own loop's re-review exists, so it cannot know that result. On the Workflow, the fix
agent's envelopeNote writes only `fix_specs`/`decisions`/`fixed_fingerprints`; `reverify` is
back-filled by the `persist:review-fix` call after the loop, from the pass-N `reviewGate()` result
already held in JS (§7.2). On the Workflow, `decisions[].reason` is always
`"workflow auto-apply (D4)"` (there is no human channel there) rather than `null` — the `null`
shown in the example above is the prose-path, human-interactive-approval case.
```

**`.claude/pipeline/_review-stats.json`** (Phase 4 — false-positive circuit breaker, §4.1/§9.1;
repo-local, already covered by the existing `.claude/pipeline/` `.gitignore` entry, confirmed live).
This is the sidecar the circuit breaker reads and writes; unlike `review.json`/`review-fix.json` it
is **not per-run** — it is a rolling cross-run ledger, one file per repo, keyed by lens:

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

- `runs[]` is capped at the last 20 entries per lens (oldest evicted on push) — matches §4.1's
  "rolling confirmed/raw ratio... across the last 20 runs."
- `demoted` flips `true` once that lens's confirmed-rate (`sum(confirmed)/sum(raw)` over the
  window) drops under 40%, flips back `false` after 5 consecutive runs at ≥60% (§4.1).
- **Writer:** the same Stage 5.7 persist agent (`persist:review`, §7.2) that writes `review.json`
  also appends this run's `{raw, confirmed, ts}` per dispatched lens to `_review-stats.json` and
  recomputes `demoted`, on **both** the Workflow and the four prose/overlay paths (a Copilot/Codex
  run updates the same file at the same path — there is no separate per-tool ledger).
  `REVIEW_LENSES` (§7.2) is then computed on the **next** run as
  `(cfg.review_fix?.lenses ?? DEFAULT_LENSES).filter(l => !stats.lenses[l]?.demoted)` — demotion
  never changes which lenses ran *this* run, only which ones are dispatched on subsequent runs.
- `review.json.data.demoted_lenses` (already in the schema above) is this run's *view* of which
  lenses were skipped because `_review-stats.json` already marked them demoted going in — the two
  files are consistent by construction (one reads what the other most recently wrote).
- **Phase gating:** this whole mechanism (the sidecar, the writer-side update, and the
  demotion-aware `REVIEW_LENSES` filter in §7.2) is **Phase 4** (§9.2's renumbering after the
  default-on flip was dropped — see D8) — a rollout increment added once enough opt-in runs have
  accumulated confirmed-rate history to demote against, not part of Phases 1–3. Phases 1–3's
  `REVIEW_LENSES` is always the configured/default set with no demotion filtering (§7.2's
  `DEFAULT_LENSES` comment). The four overlay insertions (§7.4) get one added sentence at Phase 4
  time: "A lens repeatedly producing unconfirmable findings across runs is auto-demoted from
  dispatch — see `.claude/pipeline/_review-stats.json`." — not before, since the mechanism doesn't
  exist yet in Phases 1–3.

**`run.json.stages_completed` worked example** (supplementary, add after the existing example):

```json
{
  "stages_completed": [
    "parse", "sanity-check", "implement", "generate-evals", "eval-fix",
    "validate", "plan-validate", "flowsim", "review", "review-fix",
    "secret-scan", "pr-create"
  ]
}
```

When `pipeline.review_fix.enabled` is `false`, `--no-review` was passed, or `review.json`'s
`confirmed[]` ends up empty, `review` and/or `review-fix` move to `stages_skipped` instead on the
prose/overlay paths — same documented convention as `generate-evals`/`eval-fix`/`plan-validate`/
`flowsim`'s own skill-repo-mode skips. On the Workflow path, see §4.1's "Workflow-path caveat":
this is logged, not array-appended (a pre-existing gap, not new here).

### 6.4 `docs/CONVENTIONS.md` additions

**"Stage names" list** — insert after `flowsim`, before `secret-scan`:

```
flowsim            # Stage 5.6
review             # Stage 5.7 (adversarial N-lens review; skipped when the reviewer-model axis resolves off)
review-fix         # Stage 5.8 (fix loop over confirmed findings; single cumulative sidecar, see state-schema.md)
secret-scan        # Stage 6 step 2
pr-create          # Stage 6 step 3
```

**Migration policy, line 232** — replace: *"`/sdlc`, `/task`, and `/sdlc-lite` are zero-flag by
design and recognize no aliases."* → *"`/task` is zero-flag by design. `/sdlc` and `/sdlc-lite`
already ship `--model <tier>` (see `models.md`) and now also `--review-model <name>` /
`--no-review` (see `models.md`) — both follow the `--no-X`/`--X <value>` forms below."* (See
§3 — this corrects a pre-existing self-contradiction this plan's own additions would otherwise
compound.)

**`skills/sdlc/SKILL.md` "## Arguments"** — replace the stale "No flags" text:

```markdown
## Arguments

- `plan_file` (required): Path to the plan (e.g., `plans/my-feature.md`)
- `--model <tier>` (optional): per-run fan-out cap override; see **Model cap**. `tier` ∈
  `haiku|sonnet|opus`. **Not an alias for `--review-model`** — `--model fable` is an unrecognized
  value for this flag (per `models.md`'s invalid-input rule: ignore, warn once, fall through to
  `models.cap`/default) and must resolve to `'sonnet'`/the configured cap *before* it is ever
  passed as `args.model_cap`, never forwarded as the raw string — forwarding it un-caps every
  Opus dispatch in the Workflow (see §5.2's implication note).
- `--review-model <name>` (optional): per-run reviewer-model override; see **Reviewer model**.
  `name` ∈ `fable|opus|sonnet|haiku`. Default `opus`. Passing `fable` (or setting
  `models.code_review: "fable"`) is a valid, explicit, cost-aware opt-in — usage-billed
  since Claude Fable 5's 2026-07-07 promotional-access sunset — never the default.
- `--no-review` (optional): fully skip Stage 5.7/5.8 for this run. **Note:** Stage 5.7/5.8 is
  opt-in, permanently (D8) — it does not run at all unless `--review-model` is passed or
  `pipeline.review_fix.enabled: true` is set, so `--no-review` is mainly useful to override an
  opted-in `project.json` for a single run.

Skill-repo mode is auto-detected — see "Skill-repo mode" below.
```

`skills/sdlc-lite/SKILL.md`'s argument-hint stays `"<plan-file | task-id | task-range |
description>"` (unchanged shape — task-id/range/description are its existing input forms; add the
same two new flags to its own "## Arguments"-equivalent prose section).

---

## 7. Prose + Workflow + Overlay integration (the three-way sync)

Per `CLAUDE.md`'s "Workflow-backed skills" contract: **the canonical prose in
`skills/sdlc/SKILL.md` (and `skills/sdlc-lite/SKILL.md`) is the source of truth.** Change it first;
bring the Workflow and the four overlays into line with it. All four legs below ship at **Phase 1**
(§9.2) — no leg is deferred relative to another, per the scope-discipline review that flagged the
original draft for not mentioning overlays at all. The overlays' *content* ships with **opt-in
wording from Phase 1 and stays opt-in wording permanently** ("Skipped when `--no-review`,
`pipeline.review_fix.enabled: false`, or omitted...") — there is no later default-on reword,
because there is no default-on flip (D8, §5.3, §9.2). The overlays do get exactly **one** later
one-line wording increment: a Phase 4 sentence about the false-positive circuit breaker (§6.3),
added once that mechanism ships. That increment is not a new leg shipping late — the overlay
*files* and their Stage 5.7/5.8 sections exist from Phase 1 onward; only one sentence inside them
is added later, on the same schedule the canonical prose's own circuit-breaker mention follows.
See §7.4 for the Phase 1 opt-in text (permanent) and the Phase 4 circuit-breaker addition.

### 7.1 Canonical prose (`skills/sdlc/SKILL.md`, `skills/sdlc-lite/SKILL.md`)

Insert a "## Stage 5.7 — Adversarial review" and "## Stage 5.8 — Fix loop" section between the
existing Stage 5.6 (flowsim) and Stage 6 (deliver) sections, containing the content of §4.1–4.4
above in skill-prose form (pointer to `templates/models.md` for the axis, pointer to
`templates/review-correctness-checklist.md` for the correctness lens content — do not inline
either). Add a "## Reviewer model" section mirroring the existing "## Model cap" section's
one-line-pointer style:

```markdown
## Reviewer model (Stage 5.7/5.8 only)

Independent from **Model cap** above. See
[`templates/models.md`](templates/models.md): `--review-model <name>` flag >
`models.code_review` (project.json) > skill default `opus`. Never governed by
`models.cap` / `--model`; none of `fable`/`opus`/`sonnet`/`haiku` on this axis is a member of the
`haiku < sonnet < opus` cap rank. `fable` remains a valid, explicit opt-in (`--review-model
fable`) — usage-billed since Claude Fable 5's 2026-07-07 promotional-access sunset, which is why it
is no longer the default.
```

**Invocation-block edit (required — without this, the flags never reach the Workflow):** the
Workflow reads `args?.review_model` and `args?.no_review` (§7.2), but `args` is whatever the
invoking prose passes at the `Workflow({...})` call — nothing more. Both documented invocation
blocks must gain two keys, pre-resolved by the prose exactly the way `model_cap` already is:

`skills/sdlc/SKILL.md`'s existing invocation block (currently):

```
Workflow({
  scriptPath: ".claude/skills/sdlc/workflows/sdlc-pipeline.workflow.js",
  args: { mode: "sdlc", plan_file: "<plan path>",
          model_cap: "<resolved cap: --model flag > project.json models.cap > null>" }
})
```

becomes:

```
Workflow({
  scriptPath: ".claude/skills/sdlc/workflows/sdlc-pipeline.workflow.js",
  args: { mode: "sdlc", plan_file: "<plan path>",
          model_cap: "<resolved cap: --model flag > project.json models.cap > null>",
          review_model: "<resolved: --review-model flag > models.code_review > 'opus'>",
          no_review: "<true iff --no-review was passed, else false>" }
})
```

`skills/sdlc-lite/SKILL.md`'s invocation block gets the identical two keys added after its
`model_cap` line (its `args.input`/`args.mode` shape is otherwise unchanged). Both edits are made
in the same pass as this section's other `SKILL.md` prose changes — not deferred to §7.2, which
only covers the Workflow script's *consumption* side.

Add the Stage-substitutions table row for skill-repo mode (§9's "Stage substitutions" table,
`skills/sdlc/SKILL.md` line ~838):

```markdown
| Stage 5.7 — Adversarial review | **adapt** — still runs; correctness + plan-alignment lenses apply equally to prose/JS, and the `security` lens applies its item-10 shell-injection check (quoting/eval in skill prose + hook scripts). The `config-env-docs` lens repoints to the skill-authoring checks in `templates/stage-5-skill-repo.md` (frontmatter/metadata, marketplace registration, template-reference resolution) since there is no `.env`/compose surface in a skill repo. |
| Stage 5.8 — Fix loop | unchanged (same approve/auto/off machinery) |
```

### 7.2 Workflow script (`sdlc-pipeline.workflow.js`) — exact insertion

**Prerequisite edits — without these, every `cfg.review_fix?.*` read below is dead code.**
`cfg` is `parse.config` (assigned at `const cfg = parse.config || {}`, line 385), whose shape is
pinned by `PARSE_SCHEMA.config.properties` (lines 213–220: `main_branch`, `eval_runner`,
`test_unit`, `test_frontend`, `test_e2e`, `logs_command`, `decompose_min_tasks`, `discipline` —
**no `review_fix`**) and populated only by the bootstrap agent's step-1 explicit key list
(lines 347–349). §7.1's invocation-block edit only gets `review_model`/`no_review` into `args`
(the per-run flag/CLI axis) — it does **not** put the `project.json` block into `cfg`. Two edits,
made in the same pass as the schema insertion below, both required:

(a) **`PARSE_SCHEMA.config.properties`** — add one property after `discipline` (line ~220):
   ```js
   review_fix: { type: ['object', 'null'] },
   ```
(b) **The parse+bootstrap agent's step-1 resolution list** (line 348) — add one clause after the
    existing `decompose_min_tasks (agents.decompose_min_tasks)` precedent, same form:
   ```
   review_fix (pipeline.review_fix — the whole object, or null if the key is absent).
   ```
   The step-1 prompt text becomes: "...`test_e2e` (test.e2e), `decompose_min_tasks`
   (agents.decompose_min_tasks), `review_fix` (pipeline.review_fix — the whole object, or
   null), `discipline{}` (surface-glob overrides). Missing -> null."

Without (a)+(b), `cfg.review_fix` is always `undefined` on the Workflow path and every knob in
§6.1's block (`enabled`, `model`, `mode`, `max_fix_loops`, `blocking`, `lenses`, the cost-bound
pair) silently falls to its hard-coded default — the config file would appear to work (no error)
while doing nothing. See §10's new acceptance criterion for the binary check.

**Anchor:** insert between the end of the Stage 5.6 flowsim block (the closing `}` of
`if (!skillRepo && flowsimEvidence && hasPlanTarget) { ... }`, line 689) and line 691's
`// ----- Stage 6 — Deliver ...` comment. Add a `'Review'` entry to `meta.phases` (between
`'Verify'` and `'Deliver'`):

```js
{ title: 'Review', detail: '5.7 adversarial review (reviewer axis, default opus, opt-in) + 5.8 fix loop; own budget; never blocks sdlc-lite' },
```

**Code to insert (mode handling + skip-path shown in full below; the cost-bound diff partition is
NOT — it is called out as an explicit follow-up TODO after the block, not silently omitted).
Convention note: agent-prompt template literals below never contain a raw backtick — a literal
backtick inside a JS template literal terminates it early (SyntaxError). Where the source prose
this plan is drawn from used backtick-quoted field names (`` `evidence` ``, `` `confidence` ``,
`` `reason` ``) inside a prompt string, the snippet below uses plain field names instead; the
file's own established escape for a rendered backtick, where one is genuinely needed inside a
template literal, is `${'`'}` (see `sdlc-pipeline.workflow.js` lines 364, 522, 587) — use that
form, never a raw backtick, if an implementer needs one inside a prompt string:**

This block reads `cfg.review_fix?.mode` and skips the fix-loop entirely in `off` mode (Stage 5.7
review still runs; Stage 5.8 fix loop does not — §4.2), adds the D4-mandated always-pause-before-
Stage-6 behavior for `interactive` mode on the Workflow, and adds the previously-missing `else`
branch when the stage self-skips. It also computes the §5.4 independence resolution (below) and
threads it into `planFixes` and the `persist:review` call, which the code snippet shows in full.
**Not yet implemented in this block — see the TODO list immediately after it:** the
`max_diff_lines`/`max_files` cost-bound partition (§4.1), and `auto_approve_after`/
`confidence_threshold`-driven auto-approval semantics beyond what the fix-planner's rubric already
encodes (the fix-planner marks `auto_fixable`; nothing here yet throttles *how many* auto-fixable
findings get auto-approved per §4.2's `auto` mode). An implementer must close those two gaps before
claiming Stage 5.7/5.8 complete — they are enumerated, not silently droppable.

```js
// ----- Stage 5.7/5.8 — Adversarial review + fix (reviewer axis, default 'opus') -----
phase('Review')

// REVIEW_MODEL is a SEPARATE axis from MODEL_CAP/capModel(). capModel() only
// ranks haiku<sonnet<opus (MODEL_TIER_RANK) and silently falls through to the
// default tier for anything else -- 'fable' would be swallowed. NEVER pass
// REVIEW_MODEL through capModel(); pass it straight to agent({ model: ... }).
const REVIEW_MODEL = args?.review_model ?? cfg.review_fix?.model ?? 'opus'
const reviewBlocking = MODE === 'sdlc' ? (cfg.review_fix?.blocking ?? true) : false // /sdlc blocks by default; sdlc-lite never blocks
// OPT-IN, PERMANENTLY (D8 / §5.3 / §9.2) -- there is no default-on flip, planned or shipped.
// "omitted" (no flag, no explicit enabled:true) always resolves OFF. Only an explicit
// --review-model flag or an explicit pipeline.review_fix.enabled:true turns the stage on;
// --no-review always wins over either (checked separately below, never folded into the
// opt-in condition itself, so it short-circuits regardless of how the run opted in).
const reviewOptedIn = !!args?.review_model || cfg.review_fix?.enabled === true
const reviewOptedOut = args?.no_review === true
// Reuse the REAL existing primitive -- `touched` is already computed once at line 558
// (`const touched = touchedSurfaces(changedFiles, discipline)`), the same Set Stage 5/5.5
// already gate on. No new helper needed; do NOT invent a fresh changed-files parser here --
// it would drop discipline.*_globs overrides and diverge from Stage 5/5.5's classification.
// The docs-only auto-off gate does NOT apply in skill-repo mode (see plan section 5.3 gate 1
// and Design Decision D6) -- a skill repo's .md skill files ARE its code surface.
const noReviewSurface = !skillRepo && (touched.size === 0 || (touched.size === 1 && touched.has('docs')))
const reviewEnabled = reviewOptedIn && !reviewOptedOut && !noReviewSurface

// Hoisted so Stage 6 (below, outside this if-block) can thread a note into the PR/handoff
// prompt -- same pattern as the existing `rebuildNote` const. Stay empty when review didn't run.
let reviewSurvivingHigh = []
let reviewDesignDecisions = []

if (reviewEnabled) {
  const DEFAULT_LENSES = ['correctness', 'plan-alignment', 'config-env-docs', 'security']
  // Circuit-breaker phase (§9.2 Phase 4 -- see the phase note below the reviewGate function):
  // dispatch lenses = configured lenses MINUS any lens _review-stats.json marks demoted for
  // this repo. Phase 1-3 (this code) always dispatches the full configured/default set --
  // readReviewStats()/demotion is a LATER phase's addition, called out explicitly rather than
  // silently assumed here (see the Phase 4 note after this block).
  const REVIEW_LENSES = cfg.review_fix?.lenses ?? DEFAULT_LENSES
  // SEPARATE budget from fixBudget (shared by Stages 4/5/5.5/5.6) -- see plan
  // section "Fix-loop budget" for why sharing it is wrong.
  const reviewBudget = makeBudget(cfg.review_fix?.max_fix_loops ?? 3)
  // 'off': Stage 5.7 (review) still runs -- findings still get written to review.json --
  // but Stage 5.8 (the fix loop below) never runs at all (see section 4.2). 'interactive' on the
  // Workflow degrades to auto-apply-then-ALWAYS-pause (D4, enforced further down).
  const REVIEW_MODE = cfg.review_fix?.mode ?? 'interactive'

  // Optional second pass (recall, review_fix.passes:2 -- section 4.1 / D17). REVIEW_PASSES gates
  // whether reviewGate() below dispatches a completeness critic after pass 1's lenses return; any
  // value other than the literal number 2 means "off" (1, the unchanged single-fan-out design).
  // SECOND_PASS_MODEL is resolved the SAME WAY as REVIEW_MODEL below -- a plain cfg read, default
  // 'sonnet', NEVER passed through capModel() (it is not a member of MODEL_TIER_RANK either) --
  // but, unlike REVIEW_MODEL, it does NOT go through the §5.4 independence bump/degrade check:
  // that check exists to make the PRIMARY reviewer independent of the implementer; the second
  // pass is a bonus recall layer on top of that, not a second independence gate (see the
  // independence caveat in section 4.1). If SECOND_PASS_MODEL happens to equal MODEL_CAP's
  // resolved tier this run, that is a documented, accepted tradeoff (diverse-and-cheap 'haiku'
  // is the escape hatch), never an error or a forced bump.
  const REVIEW_PASSES = cfg.review_fix?.passes === 2 ? 2 : 1
  const SECOND_PASS_MODEL = cfg.review_fix?.second_pass_model ?? 'sonnet'

  // §5.4 independence resolution -- computed ONCE per run, threaded into planFixes
  // (rubric criterion #4) and into the persist:review envelope (data.independence,
  // data.reviewer_model). Only applies when REVIEW_MODEL is one of the tier names (not
  // 'fable' -- fable is independent of the ladder by construction, so it is always "ok").
  const TIER_NAMES = ['haiku', 'sonnet', 'opus']
  let independence = 'ok'
  // The ACTUAL dispatch tier for this run -- starts equal to REVIEW_MODEL, reassigned below
  // on a same-tier bump. Every reviewer/verify/fix-planner agent() call and the persist:review
  // envelope use THIS variable, never the original REVIEW_MODEL const, once a bump applies.
  let effectiveReviewModel = REVIEW_MODEL
  if (TIER_NAMES.includes(REVIEW_MODEL)) {
    // Anchored to the Stage 2 single-agent implement dispatch site (this file, line 465:
    // `{ label: 'implement', ..., model: capModel('opus', MODEL_CAP) }`) -- 'opus' is that
    // call's own default tier, NOT 'sonnet'. Using the wrong default here would resolve
    // implementerTier='sonnet' even when the implementer actually runs at opus (--model opus),
    // letting a same-tier opus/opus pair silently register as independent (see plan section 5.4).
    // A decompose lane's own tier is per-lane and out of scope for this run-level check.
    const implementerTier = capModel('opus', MODEL_CAP)
    if (REVIEW_MODEL === implementerTier) {
      if (implementerTier === 'opus') {
        independence = 'degraded'
        log(`review: reviewer and implementer both resolve to opus -- independence degraded; every finding this run is forced auto_fixable:false (rubric #4).`)
      } else {
        // bump the reviewer one tier up so the two calls are not the same model
        effectiveReviewModel = TIER_NAMES[TIER_NAMES.indexOf(implementerTier) + 1]
        log(`review: reviewer and implementer both resolved to ${implementerTier} -- bumping reviewer to ${effectiveReviewModel} for independence.`)
      }
    }
  }

  // Runtime-availability fallback (§5.2 / D16): if effectiveReviewModel is unavailable at dispatch
  // (a genuine dispatch failure on this account/host -- NOT a Fable-cost issue; Fable is never
  // treated as unavailable, see §5.1/§5.5 -- it's usage-billed, not unreachable), fall back to the
  // highest available of opus/sonnet/haiku, preferring 'opus', logged once. If 'opus' is ITSELF
  // the unavailable resolved value, step down to the highest available of sonnet/haiku. agent()
  // returns null on a terminal dispatch error, so each reviewer/verify/fix-planner call retries
  // once at the fallback tier when its result is null due to model-unavailability; persist:review
  // records the post-fallback effectiveReviewModel as data.reviewer_model, so the sidecar never
  // names a model that didn't run. Since 'opus' is already the default (§5.2), the fallback target
  // and the default coincide in the common case -- this is a general safety net, not a mechanism
  // that exists because Fable used to be the default and is now gone.

  const runLenses = () => parallel(REVIEW_LENSES.map((lens) => () =>
    agent(
      `You are the Stage 5.7 "${lens}" adversarial reviewer for "${parse.feature_name}" --
a DIFFERENT model from the implementer (independence is the point: an independent pass
catches side-effects, contract drift, double-decode, and config/env/docs mismatches a
plan-derived test suite structurally can't).
${lens === 'correctness' ? 'Use the checklist at .claude/skills/sdlc/templates/review-correctness-checklist.md.' : ''}
${skillRepo && lens === 'config-env-docs' ? 'Skill-repo mode: check templates/stage-5-skill-repo.md structural checks instead (no .env/compose surface here).' : ''}
${planRefForAgents}
CHANGED FILES: ${JSON.stringify(changedFiles)}
Return each defect as a finding: {severity, file, line, defect, failure_scenario, fix}.
Do NOT tag auto_fixable -- that is decided by the Stage 5.8 fix-planner, not you.`,
      { label: `review:${lens}`, phase: 'Review', schema: REVIEW_SCHEMA, model: effectiveReviewModel }
    )
  )).then((rs) => rs.filter(Boolean))

  // Adversarial, evidence-required, default-refute verify pass -- same reviewer axis.
  // Returns confirmed findings carrying their ALREADY-MINTED finding_id (see runLenses's
  // raw-merge step below) plus verify_confidence/evidence copied from this call's verdict --
  // this IS the projection state-schema.md's review.json.confirmed[] needs; nothing further
  // to compute at persist time.
  const verifyFindings = async (rawFindings) => {
    if (rawFindings.length === 0) return []
    const verdicts = await agent(
      `Stage 5.7 verify pass for "${parse.feature_name}" (DEFAULT-REFUTE, EVIDENCE-REQUIRED: a
finding survives only if you attach a FRESH file:line quote, grep hit, or one-hop call-graph
fact from THIS call -- not copied from the original finding. When in doubt, refute.)
FINDINGS (indexed): ${JSON.stringify(rawFindings.map((f, i) => ({ i, ...f })))}
Return one verdict per index; evidence is required (non-null) when verdict=confirmed. Also
score confidence (0-1) on every verdict -- how sure you are given the evidence you found; this
value is persisted as review.json's verify_confidence and, in auto mode, gates auto-approval.`,
      { label: 'review:verify', phase: 'Review', schema: { type: 'array', items: VERIFY_VERDICT_SCHEMA }, model: effectiveReviewModel }
    )
    const byIdx = new Map((verdicts || []).filter((v) => v.verdict === 'confirmed' && v.evidence).map((v) => [v.finding_index, v]))
    return rawFindings
      .map((f, i) => (byIdx.has(i) ? { ...f, verify_confidence: byIdx.get(i).confidence, evidence: byIdx.get(i).evidence } : null))
      .filter(Boolean)
  }

  // Fix-planner: applies the auto_fixable rubric (plan section 4.3) -- NOT the reviewing lens.
  const planFixes = async (confirmed) => {
    if (confirmed.length === 0) return []
    return await agent(
      `Stage 5.8 fix-planner for "${parse.feature_name}". For each CONFIRMED finding, apply the
auto_fixable rubric: true only if (1) it corrects an explicit existing contract, (2) it does NOT
change a user-observable default, (3) failure_scenario names a concrete reproducible input, and
(4) this run's independence is "ok" (this run's independence: "${independence}"${independence === 'degraded' ? ' -- DEGRADED: every finding below MUST be marked auto_fixable:false with reason "degraded independence (rubric #4)", regardless of how criteria 1-3 evaluate' : ''}).
Anything failing (1), (2), or (4) is auto_fixable:false with reason naming which criterion
failed -- these are NEVER auto-fixed, always surfaced.
CONFIRMED FINDINGS (indexed): ${JSON.stringify(confirmed.map((f, i) => ({ i, ...f })))}`,
      { label: 'review:fix-plan', phase: 'Review', schema: { type: 'array', items: FIX_SPEC_SCHEMA }, model: effectiveReviewModel }
    )
  }

  // Custom gate -- deliberately NOT vanilla runGatedFix. "green" ignores
  // auto_fixable=false findings (design decisions never gate the loop, never
  // burn the review budget, and never appear in the fix agent's payload).
  // reviewPassN counts reviewGate() CALLS, not fix-loop iterations -- it starts at 0 for the
  // pre-loop initial call and increments on every subsequent re-review. This is honest about a
  // fact the code can't avoid: reviewGate() re-executes runLenses() (and therefore this mint
  // step) on EVERY call, so a later loop's "f1" is NOT the same defect as an earlier loop's "f1"
  // unless the ids are scoped per pass. See the passLabel-prefixed ids below.
  let reviewPassN = 0
  const reviewGate = async () => {
    const passLabel = reviewPassN
    reviewPassN += 1
    const reports = await runLenses()
    // Mint finding_id HERE, at the merge point, before verify -- the only place all lenses'
    // output is in one array. IDs are loop-scoped, not globally stable: `f<passLabel>-<n>`, e.g.
    // the pre-loop initial pass mints f0-1/f0-2/..., the re-review after fix-loop iteration 1
    // mints f1-1/f1-2/..., etc. Concretely: fix-loop iteration N's fix_specs/decisions (in
    // review-fix.json's data.loops[N-1]) reference ids minted by pass (N-1) -- the reviewGate()
    // call that ran BEFORE that iteration's fix agent; that same iteration's reverify field
    // reports the ids minted by pass N -- the re-review that ran immediately AFTER the fix. A
    // consumer reading review-fix.json must therefore resolve an id against the pass it names,
    // not assume a stable cross-loop identity (that guarantee does not exist in this design).
    // `let`, not `const` -- the only touch to this line itself -- because the optional
    // REVIEW_PASSES===2 branch immediately below may extend this array with a second pass's
    // findings before verify. When REVIEW_PASSES===1 (default), nothing below this line runs and
    // `raw` is exactly this merge, unchanged (passes:1 stays byte-for-byte the existing design).
    let raw = reports.flatMap((r) => r.findings || []).map((f, i) => ({ ...f, finding_id: `f${passLabel}-${i + 1}` }))

    // Optional second pass (recall, review_fix.passes:2 -- section 4.1 / D17). NOT a second
    // fan-out and NOT a vote: ONE completeness-critic call, at the separate/cheaper
    // SECOND_PASS_MODEL, given pass 1's findings as read-only context and told to find what pass 1
    // MISSED, not to re-review or re-judge them (that stays the verify pass's job below, run once,
    // over the union). Findings are fingerprint-deduped against pass 1's (same fingerprint() as
    // the section 4.2 oscillation guard) so a critic finding landing on a region pass 1 already
    // flagged never double-counts into verify.
    if (REVIEW_PASSES === 2) {
      const critic = await agent(
        `You are the Stage 5.7 SECOND-PASS COMPLETENESS CRITIC for "${parse.feature_name}". Pass 1
already ran and reported the findings below -- do NOT re-review from scratch and do NOT re-judge
them (the verify pass, not you, decides whether they hold up). Your ONLY job is RECALL: find
defects pass 1 MISSED -- an un-flagged side-effect, a config/env/docs drift, an off-by-one/boundary
condition, or a claim pass 1 made that does not actually check out. A different look catches
different bugs than a stronger repeat of the same look; do not resubmit anything already listed
below.
PASS 1 FINDINGS (context only -- do not restate): ${JSON.stringify(raw.map(({ severity, file, line, defect }) => ({ severity, file, line, defect })))}
${planRefForAgents}
CHANGED FILES: ${JSON.stringify(changedFiles)}
Return each NEW defect as a finding: {severity, file, line, defect, failure_scenario, fix}.
Do NOT tag auto_fixable -- that is decided by the Stage 5.8 fix-planner, not you.`,
        { label: 'review:completeness-critic', phase: 'Review', schema: { type: 'array', items: REVIEW_FINDING_SCHEMA }, model: SECOND_PASS_MODEL }
      )
      const pass1Tagged = raw.map((f) => ({ ...f, pass: 1 }))
      const pass2Raw = (critic || []).map((f, i) => ({ ...f, finding_id: `f${passLabel}-${raw.length + i + 1}`, pass: 2 }))
      const seen = new Set(pass1Tagged.map((f) => fingerprint(f)))
      raw = [...pass1Tagged, ...pass2Raw.filter((f) => !seen.has(fingerprint(f)))]
    }

    const confirmed = await verifyFindings(raw)
    const fixSpecs = await planFixes(confirmed)
    const autoFixable = fixSpecs.filter((f) => f.auto_fixable)
    const designDecisions = fixSpecs.filter((f) => !f.auto_fixable)
    return {
      green: autoFixable.length === 0,
      fail_count: autoFixable.length,
      failures: autoFixable.map((f) => ({ name: `fix:${f.finding_index}`, detail: f.spec, file: confirmed[f.finding_index]?.file })),
      _raw: raw,
      _confirmed: confirmed,
      _designDecisions: designDecisions,
      _autoFixable: autoFixable,
    }
  }

  let review = await reviewGate() // ALWAYS runs once -- Stage 5.7 always executes when
                                   // reviewEnabled; only Stage 5.8's fix loop is mode-gated.
  let loops = []
  let loopN = 0
  // 'off': report only, Stage 5.8 NEVER runs (see section 4.2) -- gate the loop condition
  // explicitly rather than relying on the budget alone (a mode='off' run should not spend
  // even one fix attempt, regardless of reviewBudget.max).
  while (REVIEW_MODE !== 'off' && !review.green && reviewBudget.remaining() > 0) {
    reviewBudget.used += 1
    loopN += 1
    log(`review-fix: ${review.fail_count} auto-fixable finding(s) -- fix attempt ${loopN}/${reviewBudget.max} (own review budget, separate from the shared fix budget)`)
    // Oscillation guard: refuse to re-attempt a finding whose fingerprint already
    // appears in a PRIOR loop's fixed_fingerprints (see plan "Oscillation guard").
    const priorFingerprints = new Set(loops.flatMap((l) => l.fixed_fingerprints))
    // review._autoFixable holds FIX_SPEC_SCHEMA objects (finding_index/auto_fixable/spec) --
    // no file/line/lens of their own. Dereference back to the confirmed finding the spec was
    // computed FROM (review._confirmed[f.finding_index]) before fingerprinting -- fingerprint()
    // needs {file, lens, line}, which only the finding object carries.
    // GENERAL RULE (applies everywhere a FIX_SPEC_SCHEMA object is read in this block, including
    // the survivingHigh computation below): FIX_SPEC_SCHEMA carries only finding_index/
    // auto_fixable/reason/spec (section 6.2) -- ANY finding-level field (severity, file, line,
    // lens) must be read off review._confirmed[f.finding_index], never off the fix-spec object
    // itself, which has no such field and would silently read undefined.
    const thisLoopFingerprints = review._autoFixable.map((f) => fingerprint(review._confirmed[f.finding_index]))
    const oscillating = thisLoopFingerprints.filter((fp) => priorFingerprints.has(fp))
    if (oscillating.length > 0) {
      log(`review-fix: ${oscillating.length} finding(s) re-appeared after being marked fixed -- oscillation, not a fresh bug. Pausing for human adjudication.`)
      await closeRun('paused', 'review-fix oscillation detected')
      return { status: 'paused', stage: 'review-fix', reason: 'oscillation', oscillating }
    }
    // Fix agent edits code -> implementer work, so it stays under MODEL_CAP like
    // every other fix agent in this file (contrast with reviewer/verify/fix-planner
    // above, which dispatch at effectiveReviewModel, never capModel()).
    await agent(
      `Fix ONLY these confirmed, auto-fixable review findings for "${parse.feature_name}"
(do NOT touch design-decision findings -- those are reported, never fixed).
FINDINGS TO FIX: ${JSON.stringify(review.failures)}
${envelopeNote(slug, `review-fix`, `Append one entry to data.loops[] with fix_specs=${JSON.stringify(review._autoFixable.map((f) => ({ finding_id: review._confirmed[f.finding_index]?.finding_id, auto_fixable: true, spec: f.spec })))} (finding_id mapped from FIX_SPEC_SCHEMA.finding_index HERE in JS -- the sidecar is id-keyed, never index-keyed; the fix agent is handed the ready-to-write objects because its own payload above carries neither the spec objects nor the ids), decisions=one {finding_id, action:"approved", mode:"interactive", reason:"workflow auto-apply (D4)"} per fix_spec (Workflow mode has no human channel), and fixed_fingerprints=${JSON.stringify(thisLoopFingerprints)}. Do NOT write reverify here -- the re-review that would confirm it has not run yet; it is back-filled by the persist:review-fix call below from this loop's post-fix reviewGate() result.`)}`,
      { label: `fix:review#${loopN}`, phase: 'Review', model: capModel('opus', MODEL_CAP) }
    )
    review = await reviewGate() // the re-review that immediately follows this loop's fix
    loops.push({
      loop: loopN,
      fixed_fingerprints: thisLoopFingerprints,
      // Computed HERE in JS, from the pass that just ran -- NOT something the fix agent's
      // envelopeNote above could have written (it ran before this re-review existed).
      reverify: { status: review.green ? 'pass' : 'fail', remaining_findings: review.failures },
    })
  }

  const designDecisions = review._designDecisions || []
  // Only TRUE high-severity confirmed findings count as "surviving HIGH" -- section 4.2 scopes
  // /sdlc's blocking posture to HIGH, not "any unresolved auto-fixable finding regardless of
  // severity." FIX_SPEC_SCHEMA objects (finding_index/auto_fixable/reason/spec, section 6.2)
  // carry NO `severity` of their own -- both branches below dereference it through the
  // CONFIRMED finding the spec was computed from (review._confirmed[f.finding_index]), the
  // same pattern the oscillation-guard fingerprint step above already uses for the same reason.
  const survivingHigh = [
    ...(review.green ? [] : review._autoFixable
      .filter((f) => review._confirmed[f.finding_index]?.severity === 'high')
      .map((f) => ({ finding_index: f.finding_index, severity: 'high', detail: f.spec, file: review._confirmed[f.finding_index]?.file }))),
    ...designDecisions.filter((f) => review._confirmed[f.finding_index]?.severity === 'high'),
  ]
  reviewSurvivingHigh = survivingHigh
  reviewDesignDecisions = designDecisions

  // review.json's confirmed[] is a PROJECTION (finding_id + verify_confidence + evidence
  // only) -- state-schema.md deliberately keeps the full finding object out of confirmed[]
  // (it's already in findings[], tagged with the same finding_id). Project it here rather
  // than dumping review._confirmed (which carries every raw field) straight into the prompt.
  const confirmedProjected = (review._confirmed || []).map((f) => ({
    finding_id: f.finding_id, verify_confidence: f.verify_confidence, evidence: f.evidence,
  }))
  await agent(
    `Persist Stage 5.7 review for slug "${slug}".
${envelopeNote(slug, 'review', `Write data.lenses=${JSON.stringify(REVIEW_LENSES)}, data.reviewer_model="${effectiveReviewModel}" (the EFFECTIVE dispatch tier -- already bumped per §5.4 independence if that applied this run; not necessarily the raw REVIEW_MODEL resolution), data.independence="${independence}" (§5.4 -- "ok" or "degraded"), data.passes_run=${REVIEW_PASSES} (1 or 2 -- section 4.1 / D17; 1 means the single-fan-out design, unchanged), data.second_pass_model=${REVIEW_PASSES === 2 ? `"${SECOND_PASS_MODEL}"` : 'null'} (the model actually dispatched for the completeness critic this run; null when passes_run is 1, since no critic ran), data.findings=${JSON.stringify(review._raw || [])} (the full raw merged finding objects, each carrying its finding_id -- and, when passes_run is 2, a pass:1|2 field set at this same merge point, never by the reviewing/critic agent itself, see §6.2 -- NOT the projected confirmed shape), data.confirmed=${JSON.stringify(confirmedProjected)} (PROJECTED: finding_id + verify_confidence + evidence ONLY), data.deferred_debt (see Appendix B -- run the Appendix B TASKS.md dedup-append algorithm as part of this same persist call, steps 1-5). Do NOT write fix_loops_run/max_fix_loops on this sidecar -- those belong on review-fix.json only (see the review-fix persist call below).`)}`,
    { label: 'persist:review', phase: 'Review', model: capModel('haiku', MODEL_CAP) }
  )
  // Separate persist call, separate sidecar -- review-fix.json's counters are NOT part of
  // review.json's shape (state-schema.md keeps them on distinct files). Only runs when a fix
  // loop actually executed.
  if (loopN > 0) {
    await agent(
      `Persist Stage 5.8 review-fix for slug "${slug}".
${envelopeNote(slug, 'review-fix', `Write data.fix_loops_run=${loopN}, data.max_fix_loops=${reviewBudget.max}, data.final_pass_count, data.final_fail_count, data.remaining_failures[] -- computed from the already-appended data.loops[] entries (fix_specs/decisions/fixed_fingerprints per loop, written by each iteration's fix agent). Also backfill each loop entry's reverify field from ${JSON.stringify(loops)} (one {loop, fixed_fingerprints, reverify} object per completed iteration, keyed by loop number) -- this is the pass-N gate result computed in JS immediately after that loop's fix, not something the fix agent could know at its own call time.`)}`,
      { label: 'persist:review-fix', phase: 'Review', model: capModel('haiku', MODEL_CAP) }
    )
  }

  // Post-fix validation (plan section 4.2): a review-fix loop edits code AFTER Stage 5's
  // validate gate already passed once (and after Stages 5.5/5.6). Re-run that SAME gate --
  // reusing the `validateGate` const already defined above at Stage 5, one call, no new budget
  // -- to catch a regression the fix loop itself introduced. Only when a fix actually ran.
  if (loopN > 0) {
    const revalidate = await validateGate()
    if (!revalidate.green) {
      log(`review-fix: post-fix validate regression -- ${(revalidate.failures || []).length} new failure(s) introduced by the fix loop.`)
      await closeRun('paused', 'review-fix introduced a validate regression')
      return { status: 'paused', stage: 'review-fix', reason: 'post-fix-validate-regression', failures: revalidate.failures }
    }
  }

  // Budget exhaustion is LOG-ONLY here, never a pause of its own -- blocking is decided once,
  // below, by severity + reviewBlocking (an earlier draft paused unconditionally here,
  // regardless of mode or severity, which both hard-blocked sdlc-lite and over-blocked /sdlc on
  // LOW/MED findings; removed -- the survivingHigh + reviewBlocking check below already covers
  // this case correctly, since an unresolved TRUE-high finding at budget exhaustion IS in
  // survivingHigh).
  if (!review.green && reviewBudget.remaining() === 0) {
    log(`review-fix: ${review.fail_count} auto-fixable finding(s) persist after ${reviewBudget.max} review-budget attempts (blocking decided below, per severity + reviewBlocking).`)
  }

  // D4 / section 4.2: the Workflow tool has no mid-run human-prompt primitive, so
  // 'interactive' mode HERE means auto-apply-then-ALWAYS-pause-before-Stage-6 -- never true
  // per-finding approve/edit/skip (that stays prose-path-only). Pause whenever there is
  // anything a human hasn't seen yet: unresolved design decisions, OR any fix was applied
  // this run (loopN>0) -- even if the run is otherwise green and non-blocking for /sdlc-lite.
  // This is INDEPENDENT of reviewBlocking (which only governs /sdlc's HIGH-severity gate below).
  if (REVIEW_MODE === 'interactive' && (designDecisions.length > 0 || loopN > 0)) {
    log(`review-fix: 'interactive' mode on the Workflow always pauses before Stage 6 (D4) -- ${designDecisions.length} design-decision finding(s), ${loopN} fix loop(s) this run.`)
    await closeRun('paused', 'interactive-mode review pause before Stage 6')
    return { status: 'paused', stage: 'review-fix', reason: 'interactive-mode-pause', designDecisions, loops_run: loopN }
  }

  // REVIEW_MODE !== 'off' is REQUIRED here, not decorative: 'off' means "report only; Stage 5.8
  // does not run at all" (section 4.2/6.1) -- yet Stage 5.7 (the review) still ran and its
  // findings are real. Without this guard, an 'off' run with >=1 surviving true-HIGH finding
  // (the fix loop never even attempted, since the while-loop's own condition already excludes
  // REVIEW_MODE==='off') would otherwise pause /sdlc anyway -- the ONE mode documented as least
  // intrusive would become the one mode that can still hard-block PR creation. Report-only must
  // mean report-only.
  if (survivingHigh.length > 0 && reviewBlocking && REVIEW_MODE !== 'off') {
    log(`review-fix: ${survivingHigh.length} surviving HIGH finding(s) -- pausing before PR (review_fix.blocking, default true for /sdlc; always false for sdlc-lite).`)
    await closeRun('paused', 'unresolved HIGH review findings')
    return { status: 'paused', stage: 'review-fix', survivingHigh }
  } else if (survivingHigh.length > 0) {
    log(`review-fix: ${survivingHigh.length} surviving HIGH finding(s) -- WARNING only (${REVIEW_MODE === 'off' ? "mode='off' is report-only by design, never blocks" : 'sdlc-lite never blocks'}). Listed in the handoff report.`)
  }
} else {
  // Previously-missing else branch: mirrors the evalsSkipped pattern at line 564-567 exactly
  // (`if (evalsSkipped) { log(...) } else { ... }`) -- a self-skip is a log line, no sidecar,
  // no agent call. NOTE (confirmed live, not this stage's bug): this file never appends to
  // run.json.stages_skipped for ANY stage -- every existing self-skip, including evalsSkipped
  // above, is log-only. state-schema.md's stages_skipped convention is honored on the
  // prose/overlay paths (which manage run.json by direct instruction), not by this Workflow
  // script today. This else branch matches the existing log-only pattern rather than inventing
  // new stages_skipped-writing behavior this file doesn't otherwise have (see plan §4.1's
  // "Workflow-path caveat").
  log(`Stage 5.7 skipped -- ${!reviewOptedIn ? 'not opted in (no --review-model flag and no review_fix.enabled:true -- opt-in, permanently, D8)' : reviewOptedOut ? 'opted out (--no-review)' : 'docs-only/no-surface diff (section 5.3 gate 1; does not apply in skill-repo mode)'}.`)
}
```

Note the `/sdlc` vs `/sdlc-lite` divergence is **not** a new branching mechanism — it reuses the
existing early-return `pauseOnBudget`-style pattern (matching lines 597/619/669/688), evaluated at
the *end* of the Review phase. `phase('Deliver')` and the Stage 6 `if (MODE === 'sdlc') {...} else
{...}` branch (lines 692–733) are **unchanged except for one injected note variable** — the same
pattern the existing `rebuildNote` const (line 699) already uses for the deploy-delta warning.
Add, alongside `rebuildNote`:

```js
// Threads §4.2's promised handoff-report surfacing into the SAME prompt rebuildNote already
// uses -- without this, Stage 6 never reads stage-outputs/review.json and "listed prominently
// in the handoff report" would depend on the agent noticing it unprompted.
const reviewNote = (reviewSurvivingHigh.length > 0 || reviewDesignDecisions.length > 0)
  ? `Review->Fix (Stage 5.7/5.8) surfaced ${reviewSurvivingHigh.length} surviving finding(s) and ${reviewDesignDecisions.length} design-decision finding(s) this run -- read stage-outputs/review.json and list them prominently in the report.`
  : ''
```

and append `${reviewNote}` next to `${rebuildNote}` in both the `/sdlc` PR prompt (step 4, line
~712) and the `sdlc-lite` handoff prompt (step 3, line ~727) — Stage 6 only ever sees a tree that
already cleared (or explicitly warned past) the review gate, now also told what it warned past.

**`fingerprint()`** is the one genuinely new small helper function the Workflow script needs (not
shown above in full — implementer detail, same shape as the existing `envelopeNote`/`makeBudget`
helpers): it builds the composite string from §4.2's spec
(`file + ":" + lens + ":" + floor(line / 10)`, no hash — the file has zero require/import
statements today and this fingerprint is only an in-memory Set-equality key, so a crypto
dependency buys nothing), over a *finding* object — see the
`review._confirmed[f.finding_index]` dereference in the loop code above; a `FIX_SPEC_SCHEMA`
object alone has no `file`/`lens`/`line` to fingerprint. No new changed-files-surface helper is
needed — the existing `touched` Set (`touchedSurfaces(changedFiles, discipline)`, already computed
at line 558) is reused directly, per Design Decision D9.

### 7.3 Args string-guard (process hardening item, ships in this same file edit)

**Insert between line 12 (closing `}` of `export const meta = {...}`) and line 14 (the
`// --- MODEL-TIER CAP` comment)** — confirmed by reading the whole file: the first `args?.`
access is `args?.model_cap` at line 30, so any guard must land before it:

```js
// ---------------------------------------------------------------------------
// ARGS STRING-GUARD -- some Workflow hosts deliver `args` as a JSON STRING, not
// an object, so every `args?.x` access below would silently read `undefined`
// off a string rather than throwing -- masking the bug as "no args were
// passed." Parse defensively before ANY args?.xxx access in this file.
// ---------------------------------------------------------------------------
if (typeof args === 'string') {
  try { args = JSON.parse(args) } catch { args = {} }
}
```

This is a toolkit-wide convention, not specific to this script — add it to whatever template/
skeleton future `*.workflow.js` files are scaffolded from, so no future workflow script has to
rediscover it. (Verify with the async-function-body `node --check` wrapper noted in `CLAUDE.md`'s
three-way-sync section — top-level `return`/`await` are legal in the Workflow's execution context
but `node --check` mis-flags them without that wrapper.)

**Second guard, same file edit — a deterministic `--model` junk-string normalization.** §5.2
already states the rule in prose ("unknown value → ignore, warn once, fall through"); confirmed
live this is currently enforced nowhere in code — `MODEL_CAP = args?.model_cap ?? 'sonnet'` (line
30) only falls back on nullish, and `capModel()` (line 25) returns `defaultTier` unchanged for any
cap not in `MODEL_TIER_RANK`, so a forwarded junk string like a typo'd `--model fable` silently
uncaps every Opus dispatch with zero warning — the single highest-priority hazard in this plan
(§5.1). Making the AC grep-verifiable means landing the guard in code, not leaving it as prose
discipline alone. **Insert between line 27 (closing `}` of `capModel()`) and line 30
(`const MODEL_CAP = ...`):**

```js
if (args?.model_cap != null && !(args.model_cap in MODEL_TIER_RANK)) {
  log('model_cap not a tier — ignoring; did you mean --review-model?')
  args.model_cap = null
}
```

With this in place, line 30's `args?.model_cap ?? 'sonnet'` now correctly falls through to
`'sonnet'` (or the configured cap) for any unrecognized value, matching §5.2's rule exactly.

### 7.4 Overlay edits (Copilot + Codex, `/sdlc` + `/sdlc-lite` — four files, same rollout phase)

All four overlays already state up front that they "execute every stage inline... one stage at a
time" — there is no parallel sub-agent dispatch and, absent a reachable external reviewer
integration, no second model at all. State this plainly rather than let an overlay silently imply
a genuine independent-model review (Opus, by default, or an explicitly-opted-in Fable) the way
canonical prose can.

**`copilot/skills/sdlc/SKILL.md`** — insert between the existing "## Stage 5.6 — Flow simulation"
section and "## Stage 6 — Create PR":

```markdown
## Stage 5.7 — Adversarial review (inline, sequential)

**Opt-in, permanently — never runs by default.** Runs after Stage 5.6 flowsim, before Stage 6,
only when explicitly turned on this run (`--review-model <name>`, or an explicit
`pipeline.review_fix.enabled: true`; default reviewer `opus` once enabled — see
`skills/sdlc/templates/models.md`). An omitted `pipeline.review_fix` block, or
`enabled` left unset, means OFF — there is no default-on flip. Skipped when not opted in,
`--no-review` was passed, `pipeline.review_fix.enabled: false`, or the changed-files-gate reports a
docs-only diff — **unless a `.claude-plugin/marketplace.json` exists at the repo root**, in which
case this is a
skill repo, `.md` skill files ARE the code surface (there is no separate `.env`/compose surface to
gate on here), and this docs-only self-skip does not apply — Stage 5.7 runs, with the
config/env/docs lens repointed to `templates/stage-5-skill-repo.md`'s structural checks in place of
env/compose checks. (This mirrors D6 / plan §5.3 gate 1's exemption on the canonical/Workflow side;
this overlay runtime has no other skill-repo detection of its own, so the marketplace-manifest
check above IS its skill-repo signal — see the design note after these two overlay inserts.)

**No parallel sub-agents on this runtime.** Run each of the four lenses — correctness,
plan⇌code alignment, config/env/docs consistency, security (checklists:
`skills/sdlc/templates/review-correctness-checklist.md`, `skills/sdlc/templates/review-security-checklist.md`) — as one sequential inline pass over the
diff, re-reading it fresh for each lens. If a genuinely separate reviewer integration is
configured and reachable (e.g. an MCP tool exposing Fable), call it once per lens instead of
self-reviewing; otherwise review under an adversarial persona in the session model itself and say
explicitly in the Stage 7 report which mode ran.

Collect findings (`{severity, file:line, defect, failure_scenario, fix}`), then run one
adversarially-skeptical, evidence-required verify pass (default-refute: drop anything not
independently confirmable from the diff). Write `stage-outputs/review.json`. Zero confirmed
findings → skip Stage 5.8.

## Stage 5.8 — Fix-prompt generation + approve loop

For confirmed findings, draft a structured fix spec per finding, applying the auto_fixable rubric
(a bug fixing an explicit contract vs. a product/design decision — see
`skills/sdlc/templates/models.md`). Per `pipeline.review_fix.mode` (default `interactive`):
- **`interactive`**: present each fix spec for approve / edit / skip. Approved specs run through
  the existing Stage 2/4 implement+fix machinery inline, then a fresh adversarial re-review of the
  touched files (this loop iteration's own pass) decides whether another iteration is needed. Loop
  until clean or `max_fix_loops` (own budget, separate from the Stage 4 fix budget).
- **`auto`**: after `auto_approve_after` consecutive approvals, or confidence ≥
  `confidence_threshold`, apply and continue — EXCEPT `auto_fixable: false` findings (design
  decisions), which are always surfaced, never auto-applied.
- **`off`**: report only.

**Post-fix validation (once, after the loop exits — not per iteration):** if any fix was applied
this run, re-run the Stage 5 `validate` gate exactly once before Stage 6. A regression there pauses
the run for **both** `/sdlc` and `/sdlc-lite` — an objective test break, unlike the severity-gated
review-finding blocking below, stops both modes rather than handing off broken code (see the
canonical prose's "Post-fix validation").

Write a single `stage-outputs/review-fix.json` with `data.loops[]` (one entry per pass) — never
numbered `review-fix-<n>.json` files. `/sdlc` treats a surviving HIGH-severity confirmed finding as
blocking Stage 6; stop and report rather than opening the PR.
```

**`copilot/skills/sdlc-lite/SKILL.md`** — same insertion, with the blocking-posture paragraph
replaced:

```markdown
`/sdlc-lite`'s posture is **warn-and-hand-off, not blocking**: a surviving high-severity confirmed
finding is reported prominently in the handoff report (consistent with the existing warn-only
secret scan) but does not prevent handoff — you decide whether to fix before committing.
```

**`codex/skills/sdlc/SKILL.md`, `codex/skills/sdlc-lite/SKILL.md`** — byte-identical to the two
Copilot insertions above, with the same path-substitution pattern these files already use
elsewhere (e.g. `.agents/skills/sdlc/templates/models.md (canonical:
skills/sdlc/templates/models.md)`, and `.agents/skills/sdlc/SKILL.md` cross-references in
place of `.github/skills/sdlc/SKILL.md`).

**Design note — why the marketplace-manifest check, not a shared `skill_repo_mode` flag:**
confirmed live, `copilot/skills/sdlc/SKILL.md` has **zero** existing mentions of skill-repo mode at
all (`grep -i 'skill-repo\|skill repo'` returns nothing) — this overlay runtime has no prior
skill-repo detection to inherit, unlike the canonical Workflow path where `skillRepo` is already a
resolved boolean threaded through the whole script. Rather than leave D6's exemption silently
unimplemented on this leg (the contradiction this finding exists to catch), the docs-only skip
clause above tests for `.claude-plugin/marketplace.json` directly — the same file this repo's own
setup already treats as the skill-repo signal (see `AGENTS.md`'s repo layout). This is a
narrower, single-purpose check scoped to this one gate, not a claim that the overlays gain full
skill-repo mode (discipline overrides, the Stage-substitutions table, etc. remain
canonical/Workflow-only per `CLAUDE.md`'s three-way-sync contract) — only this specific self-skip
gate needed the carve-out to avoid contradicting D6.

### 7.5 `scripts/validate_skills.py` — new soft-warning check

Mirrors the existing `model_cap_pointer_warnings()` (line 293) but scoped to the two skills that
ship this stage, kept in a **separate set** from `MODEL_CAP_FAN_OUT_SKILLS` (that set is
specifically about the implement/fan-out tier cap; conflating the two would misrepresent what
each check verifies):

```python
# D: the review-fix skills -- sdlc and sdlc-lite ship an adversarial Review->Fix
# stage governed by the reviewer-model axis contract at
# skills/sdlc/templates/models.md. Deliberately separate from
# MODEL_CAP_FAN_OUT_SKILLS: different axis, and brainstorm*/dead-code-review
# have no review stage.
REVIEW_STAGE_SKILLS = {"sdlc", "sdlc-lite"}
REVIEW_MODEL_REF = "models.md"


def review_model_pointer_warnings(skills_root: Path) -> list[str]:
    """D: soft-warn when sdlc/sdlc-lite's canonical SKILL.md doesn't reference
    the shared reviewer-model contract (`models.md`)."""
    warnings: list[str] = []
    for name in sorted(REVIEW_STAGE_SKILLS):
        skill_file = skills_root / name / "SKILL.md"
        if not skill_file.exists():
            continue
        content = skill_file.read_text(encoding="utf-8")
        if REVIEW_MODEL_REF not in content:
            warnings.append(
                f"{skill_file}: review-stage skill does not reference the shared "
                f"reviewer-model contract (`{REVIEW_MODEL_REF}`)"
            )
    return warnings
```

Wire into `main()` next to the existing call (line 359):

```python
    all_warnings.extend(model_cap_pointer_warnings(skills_root))
    all_warnings.extend(review_model_pointer_warnings(skills_root))
```

This only inspects the two canonical files; it does not walk the Copilot/Codex overlays
(consistent with the existing, human-reviewed pointer convention there).

### 7.6 `CLAUDE.md` edits

**Durable write-up location (read before the two edits below):** this repo's `.gitignore` line 19
ignores `plans/` ("consumer-side artifacts — this is a plugin repo," per its own comment) — this
plan file itself, `plans/toolkit-fable-review-fix-loop.md`, is untracked and **absent from every
fresh clone**. Any checked-in file that permanently points at it (rather than at this plan's
*design*, informally, during the PR that implements it) would be a dangling reference the moment
that PR merges. This diff therefore commits the durable parts — the design contract and the case
study — as a new tracked file, `docs/REVIEW-FIX-STAGE.md` (design summary: the reviewer-model axis,
the two enablement precedence chains, the `auto_fixable` rubric, the schemas, D1–D17 verbatim from
§8, and the regression-corpus table from §11), and has `CLAUDE.md`/`README.md` reference *that*
path, never `plans/...`.

**"Workflow-backed skills" section** — append to the `/sdlc` + `/sdlc-lite` bullet:

> `sdlc-pipeline.workflow.js` mirrors every canonical prose stage, including the Review→Fix stage
> (`review`/`review-fix`). Confirmed live: `agent({model:'fable'})` dispatches `claude-fable-5`
> natively on this seam — no spike or fallback dispatch mode was needed (see
> `docs/REVIEW-FIX-STAGE.md` "Dispatch").

**"Model cap" paragraph** — append:

> A second, independent axis exists for `/sdlc` and `/sdlc-lite` only: the **reviewer-model axis**
> (`models.code_review` / `--review-model`, default `opus`, canonical contract at
> `skills/sdlc/templates/models.md`), which selects the adversarial Review→Fix stage's
> reviewer. The stage is opt-in, permanently — it never runs unless explicitly enabled. `fable`
> remains a valid, explicit opt-in value (usage-billed since Claude Fable 5's 2026-07-07
> promotional-access sunset), never the default. This axis is NOT a value on the
> `haiku < sonnet < opus` ladder, is NOT subject to the Sonnet-first default, and must NEVER be
> passed through `capModel()`. Keep the two axes mechanically separate in any future edit.

### 7.7 `README.md` edits

- `/sdlc` skills-table row: append " Optional, opt-in adversarial Review→Fix stage after flowsim
  (reviewer axis, default Opus once enabled — `--review-model <name>` or
  `pipeline.review_fix.enabled: true` to turn on, `--no-review` always wins) surfaces defects a
  green test/flowsim run structurally can't catch." Also drop the row's stale "No flags;" phrase
  (README.md line 79) —
  the same pre-existing §3 drift as `docs/CONVENTIONS.md`/`SKILL.md`, third and last surface;
  without this, the appended `--no-review` text would sit in the same cell as "No flags".
- `/sdlc-lite` row: append " Same optional Review→Fix stage as `/sdlc`, warn-only on surviving
  findings (consistent with its warn-only secret scan) rather than blocking handoff."
- project.json key-reference table: add a row — `` `/sdlc`, `/sdlc-lite` | `pipeline.review_fix.*` (reviewer-model axis — independent of `models.cap`) ``.
- New "## Case studies" section (none currently exists — confirmed by grep) placed after the
  "Model & cost reference" table:

  ```markdown
  ## Case studies

  **Why the Review→Fix stage exists.** A `/sdlc-lite` run reported everything green — 969→981
  tests passing, flowsim 7/7 match, plan-validate 8/8, clean container logs. Three independent
  adversarial review passes (a different model from the implementer, run manually) then found 6
  real bugs the green suite never caught — a double-decoded URL, an hourly in-memory state reset
  hammering an external API, a mis-classified recurrence rule, a stale frontend query-key
  invalidation, an over-broad geo deny-list, and a missing env-var default — plus a 7th surfaced
  by a live-data check. Total cost: ~240k tokens across 3 passes, each 1–6 minutes. See
  `docs/REVIEW-FIX-STAGE.md` for the full write-up and the Review→Fix stage design.
  ```

  (`plans/toolkit-fable-review-fix-loop.md` — this planning document — is `.gitignore`'d in this
  repo and absent from a fresh clone; `docs/REVIEW-FIX-STAGE.md` is the tracked file this and
  `CLAUDE.md`'s pointer resolve to. See §7.6's "Durable write-up location" note.)

---

## 8. Design decisions (resolved)

Every open question raised across the seven grounding passes, resolved here — no dangling forks.

| # | Question | Decision | One-line rationale |
|---|---|---|---|
| D1 | Does `--model fable` double as shorthand for enabling review? | **No.** Dropped entirely. | `models.md`'s own "unknown value → ignore, warn once, fall through" rule already defines `--model fable`'s behavior today; overloading it would either silently no-op the cap or require a breaking change to a file 5 other skills read. `--review-model fable` is the only entry point. |
| D2 | Does the reviewer axis belong as a row in `models.md`'s cap table? | **No.** New sibling file `templates/models.md`. | Fable isn't rank-comparable to haiku/sonnet/opus; folding it into the `min(default,cap)` table invites a future author to add `fable` to `MODEL_TIER_RANK`, silently reactivating the exact bug this plan exists to prevent. |
| D3 | Naming collision with `pipeline.skip_review`? | **Renamed to `pipeline.review_fix.*`.** | `skip_review` already gates a different, existing feature (Stage 6's post-PR `/review` diff pass); a same-word new key one line away in `project.json` is a guaranteed future misread. |
| D4 | Is `interactive` mode achievable inside the Workflow tool? | **No — documented Workflow limitation, not a prose downgrade.** Degrades to auto-fix-then-pause. | The Workflow has no mid-run human-prompt primitive; every existing pause point is a hard stop-and-return. True per-finding conversation stays prose-path-only (Claude/Copilot/Codex sessions can literally ask). |
| D5 | Shared fix budget or separate? | **Separate** `pipeline.review_fix.max_fix_loops` (default 3). | Review findings are a categorically different failure surface discovered after all four Verify-phase gates already passed; sharing the counter makes pause attribution ambiguous and creates accidental cross-stage starvation. |
| D6 | Does Stage 5.7/5.8 run in skill-repo mode? | **Stage 5.7 adapts** (config-env-docs lens repoints to `stage-5-skill-repo.md` checks); **Stage 5.8 unchanged.** | Correctness + plan-alignment review of prose/JS is exactly the kind of adversarial second-opinion this plan's own case study demonstrates value for — skipping wholesale throws away the plan's own motivating evidence. Only the env/compose-specific lens needs repointing. |
| D7 | Numbered `review-fix-<n>.json` or single cumulative file? | **Single `review-fix.json`** with `data.loops[]`. | Matches the only existing multi-iteration sidecar precedent in this repo, `eval-fix.json` — a single cumulative file, not per-iteration files. No other stage in `state-schema.md` uses a numbered-file pattern for loop iterations. |
| D8 | Default posture: on-with-opt-out, or opt-in? | **Opt-in, permanently.** No Phase-4 default-on flip. | Claude Fable 5's cheap/promotional access ends 2026-07-07 (it is now billed via paid usage credits), so there is no longer a cheap reviewer model to justify a default-on posture. The default reviewer is now Opus — capable, but a real token cost — and, exactly as this plan always argued would be true for an Opus-tier reviewer, that cost argues for opt-in, not default-on. This is also unlike the near-zero-cost secret scan: adversarial review is an LLM judgment call with a real false-positive rate, and defaulting it on risks the same gate-disabling dynamic `SKILL.md`'s own Soft-stop philosophy warns against. |
| D9 | Docs-only skip — which primitive? | **Reuse the existing `touched` Set** (`touchedSurfaces(changedFiles, discipline)`, already computed once at `sdlc-pipeline.workflow.js` line 558 and implementing `templates/changed-files-gate.md`'s surface classification) — no new helper. | The original draft's "reuse the no-test-surface degeneracy check" pointed at nothing real; `touched` is the actual, already-in-scope primitive Stage 5/5.5 already gate on, and reusing it (not a fresh parser) keeps `discipline.*_globs` overrides consistent across all three consumers. |
| D10 | Does `--review-model opus` get lowered by `models.cap`? | **No — fully independent for all four values**, not just `fable`. | The plan's stated design goal (implementer Sonnet, reviewer Opus by default) is independence; special-casing only `fable` as exempt while lowering an explicit `--review-model opus` would be an inconsistent surprise. |
| D11 | Is the Agent/Task seam guaranteed to accept `model: "fable"`? | **Yes — confirmed live (§5.5), and still true after Fable's 2026-07-07 sunset.** `agent({model:'fable'})` dispatches `claude-fable-5` natively; no spike or persona-fallback needed. | Directly observed this session dispatching this plan's own Fable reviewer agents — settled, not a future spike. Fable's dispatchability is independent of its default status: it remains fully dispatchable post-sunset, just usage-billed instead of free/plan-included (§5.1, §5.5, D16) — that cost shift, not a dispatch regression, is why it is no longer the default (see D8). |
| D12 | Should item #2 of the process-hardening retro (resume re-checks blockers) ship here? | **No — routed to `docs/PHASE-1-STATE-ENVELOPE.md` §1B as an addendum**, not attempted in this plan. | `/sdlc --resume` (Phase 1B) is listed "deferred, not started" — there is no replay bug to fix in code that doesn't exist yet. Per the user's own standing instruction, the Phase 1 plan is canonical for deferred work. |
| D13 | Should the two consumer-repo gotchas (WSL inotify, pydantic `extra`) ship as toolkit code? | **No — routed to `examples/GOTCHAS.md.example`** as generalized entries, not a toolkit-code change. | Neither touches a file this plan opens; the toolkit itself has no pydantic Settings or WSL runtime of its own. |
| D14 | Does `--no-fable-review` need a positive-force counterpart flag? | **No — negative form only**, matching `--no-cache`/`--no-verify` precedent. | `--review-model <name>` already doubles as an implicit enable; there's no existing precedent in this repo for a redundant bare positive-force flag. |
| D15 | Zero-flag-by-design contradiction in `docs/CONVENTIONS.md`? | **Treated as pre-existing stale documentation**, corrected as a companion edit (§3, §6.4) rather than blocking this plan. | `--model` already ships and is documented in two other live files; the "zero-flag by design" line describes a state the repo already left behind. |
| D16 | If the resolved reviewer model can't be dispatched at runtime, what happens? | **Fall back to the highest available of `opus`/`sonnet`/`haiku`, preferring `opus`** — logged once. `review.json.data.reviewer_model` records the *effective* model actually dispatched (§5.2, §7.2). | This is a **general availability safety net**, not a Fable-specific one: `fable` is explicitly **not** an unavailability case — it remains fully dispatchable after its 2026-07-07 promotional-access sunset (D11/§5.5), just billed via paid usage credits instead of being free/plan-included. Since the default reviewer is now `opus` (§5.2), the fallback target and the default coincide in the common case — this mechanism exists for a genuine dispatch failure on whichever model resolves, not because a cheap default became unreachable. Distinct from D1/§5.2's invalid-*config* fall-through (bad names, not runtime reachability). Forcing a specific reviewer deliberately is `--review-model <name>` (e.g. `fable` or `opus`), a first-class choice separate from this fallback. |
| D17 | 2nd review pass — a 2nd Opus, or a cheaper different model? | **A cheaper different model (default Sonnet) as a completeness critic, unioned.** | Recall comes from a different look at the diff, not a stronger repeat of the same look; union + the existing default-refute verify pass means a cheaper second pass can only *add* confirmed findings, never dilute the result (the verify pass still gates the combined set before anything is confirmed). A full 2nd-Opus fan-out remains available for a team that wants it via `second_pass_model: "opus"`; `"haiku"` maximizes diversity-and-cheapness for the common case where the implementer itself resolved to Sonnet. |

---

## 9. Risks & mitigations, and Rollout (shippable increments)

### 9.1 Guardrails baked into the design (from the adversarial pre-mortem)

| Risk | Mitigation | Where specified |
|---|---|---|
| Reviewer cries wolf, users learn to `--no-review` forever | Per-lens false-positive circuit breaker (auto-demote a lens under 40% confirmed-rate, re-promote at 60%) — **Phase 4**, ships once enough opt-in runs accumulate confirmed-rate data to demote against | §4.1, §6.3 (`_review-stats.json`), §9.2 Phase 4 |
| One reviewer call reviews an entire huge decomposed diff, blowing cost | Cost bound (`max_diff_lines`/`max_files`) + partition-by-lane fallback | §4.1 |
| Fix A silently reintroduces defect B (or itself), loop spins in budget | Fingerprint-based oscillation guard, hard pause on any repeat | §4.2 |
| `auto_fixable` becomes an ungrounded LLM vibe-check | Deterministic-first 4-criterion rubric, default-deny | §4.3 |
| Reviewer verify pass rubber-stamps its own hallucinated finding | Evidence-required verify (fresh quote/grep/call-graph fact, not re-judgment) | §4.1 |
| `REVIEW_MODEL` silently swallowed by `capModel()` | Bypasses `capModel()` entirely; only the code-editing fix agent uses `capModel('opus', MODEL_CAP)` | §5.1, §7.2 |
| Reviewer and implementer resolve to the same tier (no real independence) — now the common way this happens is `--model opus` alone, since the reviewer's own default is Opus | Independence bump-or-flag (§5.4); degraded runs can never auto-fix | §5.4, §4.3 rubric criterion #4 |
| Adversarial review runs (and costs tokens) on every run, unasked | The stage is **opt-in, permanently** (D8) — it only runs when explicitly enabled; no default-on burn-in ever ships | §5.3, D8 |
| Resolved reviewer model can't be dispatched at runtime — review silently no-ops | Runtime-availability fallback to the highest available of `opus`/`sonnet`/`haiku` (opus preferred), logged; sidecar records the effective model. Not a Fable-specific risk — Fable remains dispatchable post-sunset, just usage-billed (D16). | §5.2, D16 |

### 9.2 Rollout — 4 shippable increments (Phases 1–3 the core stage, Phase 4 the circuit
breaker), each with a dogfood gate

**Phase 0 (resolved, not a ship):** confirmed live — `agent({model:'fable'})` dispatches
`claude-fable-5` natively (§5.5); recorded in `templates/models.md` §Dispatch. No spike
needed before Phase 1.

**Phase 1 — Stage 5.7 review only, opt-in.** Ships: `--review-model <name>` and `--no-review`
(both opt-in-scoped — nothing resolves by default; `--no-review` always wins per §5.3 even during
this opt-in phase), 3-lens dispatch (parallel on Workflow, sequential on prose/overlays),
evidence-required verify pass, `stage-outputs/review.json` — **including its `data.deferred_debt`
field and the Appendix B `TASKS.md` dedup-append algorithm** (it is part of `review.json`'s shape,
not a separate surface; the `persist:review` agent/step, §7.2, executes Appendix B's steps 1–5 as
part of the same persist call that writes the rest of `review.json`) — `review` in
`run.json.stages_completed`, the args string-guard (§7.3), `templates/models.md` and
`templates/review-correctness-checklist.md` (new files), and the companion `test.baseline_failures`
config key (§12, item #3 — a small, non-blocking addition; Stage 5's validate gate already
separates new-vs-preexisting failures via prompt judgment today, so Phase 1 does not gate on this
key existing). **Also ships here, not deferred:** the four
Copilot/Codex overlay edits (§7.4), worded for the **permanent** opt-in posture (matching the
canonical prose's own opt-in wording, which never changes — D8) — the overlay *files* are not a
later-phase leg; they get exactly **one** later sentence added, at Phase 4, about the
false-positive circuit breaker (see §7's preamble and the Phase 4 entry below).
- *Dogfood gate:* run Stage 5.7 against fixtures recreating the 5 auto-catchable defects in §10's
  regression corpus and confirm equivalent findings surface unprompted; run it against a known-clean
  trivial diff in this repo and confirm zero HIGH findings; `validate_skills.py` passes (§7.5);
  **Appendix B's two acceptance criteria also gate this phase**: running Stage 5.7 twice on an
  unchanged diff appends zero duplicate `TASKS.md` rows the second time, and a `deferred_debt[]`
  item is confirmed to touch only `TASKS.md` (never `skills/`, `copilot/skills/`, or `templates/`).

**Phase 2 — Stage 5.8 fix-spec generation + `interactive` approve.** Ships: fix-planner + rubric,
approve/edit/skip UX (prose path) / auto-fix-then-pause (Workflow path), re-verify, own
`max_fix_loops` budget, `stage-outputs/review-fix.json`.
- *Dogfood gate:* a real run with ≥1 confirmed finding demos the full approve→fix→reverify loop;
  a forced 2-fake-unresolvable-finding run hits `max_fix_loops` and pauses cleanly (no spin); the
  oscillation guard is exercised once with a seeded repeat-defect fixture.

**Phase 3 — `auto` mode + design-decision guard.** Ships: `auto_approve_after`/
`confidence_threshold` gating, the `auto_fixable` rubric enforcement as a hard branch.
- *Dogfood gate:* a defect #5-shaped fixture (an arguably-correct-depending-on-intent filter) is
  surfaced to the human and never auto-fixed, even mid-approve-streak; a low-risk trivial plan
  completes fully unattended in `auto` mode.

**There is no "flip default to on" phase.** An earlier draft of this rollout carried a Phase 4 that
flipped the stage's default to on-with-opt-out, gated on a burn-in. That phase is **dropped
entirely** (D8, §5.3): Claude Fable 5's cheap/promotional access ends 2026-07-07, so there is no
longer a cheap-enough reviewer to justify a default-on posture, and the current default reviewer
(Opus) is capable but a real token cost — which argues for opt-in permanently, not a future flip.
Rollout stops at 3 core-stage phases plus one circuit-breaker phase (renumbered below); nothing in
this plan schedules a later default-on increment.

**Phase 4 — false-positive circuit breaker.** Ships: `.claude/pipeline/_review-stats.json` (schema
in §6.3), the persist agent's writer-side update to it (both the Workflow's `persist:review` step
and the four prose/overlay paths), and `REVIEW_LENSES`'s demotion-aware filter in §7.2. Deliberately
last — it needs confirmed-rate history to demote against, which only accumulates once repos have
been running Stage 5.7 opted-in for a while; building the breaker before there's any history to
demote against would have nothing to key off of. This is re-gated on **data accumulated across
opt-in runs**, not a default-on burn-in (there is none — see above).
- *Dogfood gate:* seed `_review-stats.json` with a synthetic 20-run window for one lens at a 30%
  confirmed-rate; confirm the next run excludes that lens from dispatch and records it in
  `review.json.data.demoted_lenses`; seed 5 consecutive ≥60% runs and confirm re-promotion.

---

## 10. Acceptance criteria (binary, covering every new surface)

- [ ] **Config key `pipeline.review_fix`**: absent → `enabled` defaults to `false` — the stage is
      OFF, regardless of skill-repo mode (opt-in, permanently — D8). Never errors.
- [ ] **Opt-in posture (permanent, D8):** with `pipeline.review_fix` absent (or `enabled` unset)
      and no `--review-model`/`--no-review` flag, Stage 5.7 does not run — "omitted → OFF" is the
      permanent behavior; there is no phase or later default at which "omitted" resolves to ON. On
      the **prose/overlay** paths, `review` lands in `run.json.stages_skipped` (state-schema.md's
      convention). On the **Workflow** path this is evidenced by the else-branch log line (§7.2),
      per §4.1's Workflow-path caveat — the Workflow script does not append to `stages_skipped` for
      any stage today, a pre-existing gap this plan does not fix.
- [ ] **`project.json` config actually reaches the Workflow:** with
      `pipeline.review_fix.enabled: false` in `.claude/project.json` and no flags, a Workflow-path
      run skips Stage 5.7 and logs the skip reason (§7.2's else branch) — proving `PARSE_SCHEMA` +
      the bootstrap step-1 resolution list (§7.2's prerequisite edits) actually populate
      `cfg.review_fix`, not only the prose path reading the file directly. (Not evidenced via
      `stages_skipped` on this path — see the caveat above.)
- [ ] **Flag outranks config (§5.3):** `--review-model sonnet` with
      `pipeline.review_fix.enabled: false` in `project.json` still runs Stage 5.7 — the explicit
      opt-in flag wins over the standing config, mirroring `models.md`'s `--model` vs
      `models.cap` precedence.
- [ ] **Independence resolution (§5.4):** `--review-model sonnet` on a default (Sonnet-capped) run
      dispatches the reviewer at `opus` and records `review.json.data.independence: "ok"`; when the
      implementer's effective tier is already `opus`, the run records `"degraded"` and the
      fix-planner marks every finding that run `auto_fixable: false` with `reason` citing rubric
      criterion #4.
- [ ] **Runtime-availability fallback (§5.2 / D16):** with the resolved reviewer model unavailable
      at dispatch (simulate: the resolved tier is unreachable on this host — a general
      dispatch-failure test, not a Fable-provisioning test, since Fable is never treated as an
      unavailability case), the stage falls back to the highest available of `opus`/`sonnet`/
      `haiku` (opus preferred), logs one `... unavailable — falling back to <tier>` line, still
      produces `review.json`, and records `data.reviewer_model` as the *effective* model actually
      dispatched, never the unreachable resolved name. When `opus` itself is the unavailable
      resolved value, it steps down to the highest available of `sonnet`/`haiku` rather than
      skipping the stage.
- [ ] **Explicit Opus review (§5.2):** `--review-model opus` (or `models.code_review:
      "opus"`) dispatches the review/verify/fix-planner agents at `opus` and records
      `data.reviewer_model: "opus"` — a first-class choice, resolved the same way as `fable`, never
      lowered by `models.cap` (D10).
- [ ] **`--model fable` does not un-cap the fan-out:** `--model fable` with no `--review-model`
      resolves the fan-out cap to `sonnet` (or the configured `models.cap`) with one warning, per
      `models.md`'s invalid-input rule, and does NOT enable review — `review.json` is
      absent/skipped and no agent in the run dispatches at `opus` as a side effect of the typo.
- [ ] **Flag `--review-model <name>`**: overrides `models.code_review` for this run only
      (flag > project.json > default, mirroring `models.md`'s shape). Unknown value → one
      warning, falls through.
- [ ] **Flag reaches the Workflow path**: `--review-model X` on the ultracode/Workflow path
      produces `reviewer_model: "X"` in `review.json` — i.e. `skills/sdlc/SKILL.md`'s and
      `skills/sdlc-lite/SKILL.md`'s `Workflow({ args: {...} })` invocation blocks both carry the
      resolved `review_model`/`no_review` keys (§7.1), and the script reads them (§7.2). Grep both
      `SKILL.md` files for `review_model:` to confirm the invocation-block edit shipped, not just
      the script-side read.
- [ ] **`--no-review`**: fully skips Stages 5.7 AND 5.8 — no `review.json`/`review-fix.json`
      written. Prose/overlay paths record `review` (and `review-fix` if applicable) in
      `run.json.stages_skipped`; the Workflow path logs the skip (§4.1's Workflow-path caveat).
- [ ] **`REVIEW_MODEL` never reaches `capModel()`**: grep-verifiable — every reviewer/verify/
      fix-planner `agent()` call in the Review phase passes `model: effectiveReviewModel` (derived
      from `REVIEW_MODEL`, possibly independence-bumped per §5.4 — never lowered by `capModel()`);
      only the file-editing fix agent uses `capModel('opus', MODEL_CAP)`.
- [ ] **Sidecar `stage-outputs/review.json`**: written even when `confirmed == []` (zero findings,
      still recorded as a completed stage).
- [ ] **Sidecar `stage-outputs/review-fix.json`**: single cumulative file, never
      `review-fix-<n>.json`; `data.loops[]` has one entry per iteration.
- [ ] **Design-decision guard**: a finding tagged `auto_fixable: false` is never auto-approved in
      `auto` mode regardless of approve-streak or confidence — enforced as a hard branch (the fix
      agent's payload structurally excludes it), verified by the defect-#5-shaped Phase 3 fixture.
- [ ] **Oscillation guard**: a seeded repeat-defect fixture pauses the run with a side-by-side
      report rather than spending a third fix attempt.
- [ ] **Blocking posture**: `/sdlc` pauses (`run.json.status="paused"`) before PR creation on a
      surviving HIGH confirmed finding; `/sdlc-lite` reports it in the handoff and proceeds.
- [ ] **Post-fix validation**: a seeded fixture where the fix loop's own edit breaks an existing
      test causes exactly one re-run of the Stage 5 validate gate after the loop exits (not
      per-iteration), and pauses **both** `/sdlc` and `/sdlc-lite` — not the severity-gated
      review-finding path, a separate, unconditional-on-mode check (§4.2).
- [ ] **Handoff/PR report threading**: a run with ≥1 surviving finding or design decision produces
      a PR body (`/sdlc`) or handoff report (`/sdlc-lite`) that names the count and points at
      `stage-outputs/review.json` — via the `reviewNote` variable injected into the Stage 6 prompt
      (§7.2), the same mechanism the existing `rebuildNote` uses.
- [ ] **Cost bound**: a synthetic >1500-line diff triggers partitioned review (`data.partitioned:
      true`), not one call over the full diff.
- [ ] **Optional second review pass (`agents.code_review_passes: 2`, D17)**: with `passes: 2`,
      exactly one completeness-critic call runs — dispatched at `models.code_review_second_pass` (default
      `sonnet`, resolved like the reviewer axis, never through `capModel()`) — after the pass-1
      lens fan-out returns; its findings are unioned into pass 1's (fingerprint-deduped via the
      same `fingerprint()` as §4.2's oscillation guard) *before* the single default-refute verify
      pass runs once over the combined set — never a second verify pass, never a vote/consensus.
      `review.json` records `data.passes_run: 2` and `data.second_pass_model` (the effective model
      dispatched for the critic). With `passes: 1` (default, and whenever the key is omitted), no
      second pass runs at all: `data.passes_run: 1`, `data.second_pass_model: null`, and Stage 5.7
      behaves exactly as it did before this addition.
- [ ] **False-positive circuit breaker (Phase 4 — see §9.2/§6.3)**: a lens whose 20-run
      confirmed-rate, recorded in `.claude/pipeline/_review-stats.json`, is seeded below 40% is
      excluded from that run's `REVIEW_LENSES` dispatch and appears in `data.demoted_lenses`; 5
      consecutive ≥60% runs re-promote it. Not present in Phases 1–3.
- [ ] **Non-interactive fallback**: an `interactive`-mode run with no human channel (background/CI)
      completes via auto-fix-then-pause (Workflow) rather than hanging — concretely, the Workflow
      ALWAYS pauses before Stage 6 whenever `REVIEW_MODE === 'interactive'` and there is a design
      decision or any fix loop ran (§7.2), even when `reviewBlocking` would otherwise let the run
      through.
- [ ] **`off` mode still reviews**: with `pipeline.review_fix.mode: "off"`, Stage 5.7 still runs
      and writes `review.json` (findings included), but the Stage 5.8 fix-loop `while` never
      executes even once (`loopN` stays 0) — grep-verifiable via the `REVIEW_MODE !== 'off'` loop
      guard in §7.2.
- [ ] **`off` mode never blocks Stage 6:** with `pipeline.review_fix.mode: "off"` and ≥1
      confirmed auto-fixable finding (any severity, including HIGH) surviving the (never-run)
      fix loop, `/sdlc` still creates the PR — the `survivingHigh` blocking gate's
      `REVIEW_MODE !== 'off'` condition (§7.2) is what makes report-only mean report-only; the
      surviving finding(s) still appear in `review.json` and the run log, just never pause
      `run.json.status`. Distinguish from a HIGH-severity confirmed **design decision** in `off`
      mode (`auto_fixable: false`), which is likewise never blocking under this same guard — `off`
      mode's contract is "report, never gate," full stop, regardless of finding kind.
- [ ] **Skip path is not a silent no-op**: when `reviewEnabled` is `false` (never opted in — the
      permanent default, D8 — opted out via `--no-review`, or a non-skill-repo docs-only diff),
      the Workflow's `else` branch (§7.2) logs the skip reason —
      the same log-only behavior as the existing `evalsSkipped` branch (§4.1's Workflow-path
      caveat: this file does not append to `stages_skipped` for any stage today). On the
      prose/overlay paths, `review`/`review-fix` land in `run.json.stages_skipped` per
      `state-schema.md`'s documented convention.
- [ ] **Cross-tool overlays**: all four of `copilot/skills/sdlc*/SKILL.md`,
      `codex/skills/sdlc*/SKILL.md` document the sequential-inline, no-parallel-dispatch framing
      and ship as files at **Phase 1** — worded for the **permanent** opt-in posture (D8; no later
      reword of the enablement sentence, because there is no default-on flip) — with only the
      circuit-breaker sentence added later, at Phase 4 (§7's preamble, §9.2 Phases 1/4). No overlay
      is deferred behind its matching canonical-prose change; only one of its sentences is added on
      the same later schedule the canonical prose's own circuit-breaker mention follows.
- [ ] **`validate_skills.py`**: passes with the new `review_model_pointer_warnings()` check wired
      in; both canonical `SKILL.md` files reference `models.md`.
- [ ] **Naming collision resolved**: `pipeline.review_fix` and the pre-existing
      `pipeline.skip_review` are documented, in the same file, as two independent toggles.
- [ ] **`docs/CONVENTIONS.md` / `skills/sdlc/SKILL.md` drift fix**: the stale "zero-flag by design"
      claim and the stale "No flags" Arguments section are corrected in the same PR.
- [ ] **`docs/REVIEW-FIX-STAGE.md` exists** (§7.6) containing the reviewer-axis contract, both
      precedence chains, the `auto_fixable` rubric, D1–D17, and the regression-corpus table; a grep
      of tracked files for `plans/toolkit-fable-review-fix-loop` returns nothing; every
      `CLAUDE.md`/`README.md` review-stage reference resolves to the `docs/` path, not `plans/...`.

---

## 11. Regression corpus — the 7 case-study defects mapped to review lenses

This is the dogfood corpus for Stage 5.7 (Phase 1's fixture set), and it corrects the original
draft's "each is a concrete instance the stage would have caught automatically" overclaim — true
for 5 of 7, not all 7.

| # | Defect | Catching lens | Model needed? | Auto-fixable or design-decision? |
|---|---|---|---|---|
| 1 | `_unwrap_ddg_href` double-decodes URLs | `correctness` — checklist item #3 | **No** — cheap grep (`unquote` near `parse_qs`) catches it before spending review tokens | auto-fixable |
| 2 | Job-worker self-exit resets in-memory weather state hourly | `correctness` — checklist item #4 | Yes — cross-subsystem side-effect judgment | auto-fixable |
| 3 | `backfill_event_dates` marks one-off events recurring on any weekday word | `correctness` — checklist item #7 | Yes — semantic judgment | auto-fixable |
| 4 | GUI radius change doesn't refetch (wrong query key invalidated) | `correctness` (#8) **and** `plan-alignment` (acceptance criterion unmet) — dual-lens catch | Yes | auto-fixable |
| 5 | Over-broad geo deny-list drops in-range cross-county destinations | `correctness` flags it as a finding | Yes | **design-decision — routes to human, never auto-fixed.** Canonical test case for the §4.3 rubric and the Phase 3 dogfood gate. |
| 6a | `JOB_WORKER_MAX_UPTIME` missing from `.env.example` | `config-env-docs` — checklist item #5 | **No** — cheap grep (diff env-var names across code/`.env.example`/compose) | auto-fixable |
| 6b | Silent-failure warning skipped on an early return | **Gap in the original 8-item checklist — closed here.** New checklist item #9: "Early-return / short-circuit branches — do they skip a warning/log/metric that other paths emit?" | Yes | auto-fixable (once #9 is added — see Appendix A) |
| 7 | (live-data) feed still leaked ungeocodable Pasco rows | **Not covered by any lens — all three are static-code reviewers; this was only visible by inspecting live output data.** | — | **Acknowledged gap, out of scope.** A future "live-output spot-check" lens is a legitimate but separate idea — not scope-crept into this plan. |

**Net:** 5 of 7 defects are cleanly caught by the 3 lenses (2 of those via cheap grep, no model
spend); 1 is a design decision the guard correctly routes to a human instead of fixing; 1
(live-data leak) is a hard, acknowledged gap the static lenses cannot reach.

---

## 12. Companion changes (scoped explicitly — not all six retro items belong in this diff)

The multi-session Fable retro surfaced six process-hardening items beyond the Review→Fix stage
itself. They do not all belong in this plan's diff:

| # | Item | Touches toolkit code? | Verdict | Where it lands |
|---|---|---|---|---|
| 1 | Decompose must own every touched TEST file (a failing test file with no owning lane can only report a blocker, never fix it) | Yes — `templates/stage-2a-decompose.md`, `stage-2b-dispatch.md`, `sdlc-pipeline.workflow.js` decompose step | **IN** — ships in Phase 1; small, and de-risks the fix loop this plan's own acceptance criteria depend on | This plan, companion diff |
| 2 | On resume, blockers are claims to RE-CHECK, not state to replay | No code to touch yet — `/sdlc --resume` (Phase 1B) is listed "deferred, not started" | **OUT** | Addendum to `docs/PHASE-1-STATE-ENVELOPE.md` §1B, cross-linked from here (D12) |
| 3 | `test.baseline_failures` config key (separate pre-existing environmental failures from real regressions) | Yes — `.claude/project.json` schema + Stage 5's failure partition | **IN — small, non-blocking.** Stage 5's validate gate already separates new-vs-preexisting failures via prompt judgment ("Report only NEW failures as failures... note pre-existing separately," confirmed live at the validate agent's own prompt) — this key is a future formalization, not a Phase 1 gating dependency for Stage 5.7/5.8 to function. | This plan, Phase 1 (§9.2), non-blocking |
| 4 | Workflow `args` string-guard preamble | Yes — one line in `sdlc-pipeline.workflow.js`, already opened by this change | **IN** — trivial, ships with §7.3 | This plan, §7.3 |
| 5 | WSL/`drvfs` inotify GOTCHA (file-watch under-fires on `/mnt/c`) | No toolkit code — documentation for consumer repos | **OUT of toolkit code**, IN as content | `examples/GOTCHAS.md.example`, "Infra" section (D13) |
| 6 | pydantic `extra='forbid'` → `'ignore'` for Settings loaded from a CWD with an undeclared-key `.env` | No toolkit code — toolkit has no pydantic Settings of its own | **OUT of toolkit code**, IN as content | `examples/GOTCHAS.md.example`, new "Config/Settings" note (D13) |

**Mini acceptance criteria for the IN items:**
- **#1**: a plan with 2+ decompose lanes where lane B's edit breaks an existing test file NOT in
  lane B's `files[]` list results in that test file being assigned to lane B (or a dedicated
  test-cleanup lane) automatically — never reported as an unowned blocker.
- **#3**: `.claude/project.json` → `test.baseline_failures` (list of test IDs) or
  `test.baseline_failures_file` (path) is read by Stage 5's failure partition; a full-suite run
  whose failures exactly match the baseline reports `new_failures: []`.
- **#4**: `sdlc-pipeline.workflow.js` begins with the string-guard; `node --check` (with the
  async-function-body wrapper) passes.
- **#5/#6**: a diff to `examples/GOTCHAS.md.example` adds one generalized entry each (no
  project-specific paths), under "Infra" and a new "Config/Settings" subsection respectively.

---

## Appendix A — the correctness review checklist (new file: `skills/sdlc/templates/review-correctness-checklist.md`)

Per this repo's "no inline templates or long checklists" rule (`CLAUDE.md` skill-authoring rule 4),
this content is a **new template file**, not inlined into `SKILL.md`. Canonical `SKILL.md`
references it as `` `templates/review-correctness-checklist.md` `` (lint-checked by
`validate_skills.py`'s template-reference resolution check); the four overlays reference it via
the full-path, human-reviewed pointer form already used for `models.md` elsewhere in those
files (e.g. `` `skills/sdlc/templates/review-correctness-checklist.md` ``).

Distilled from the bug-classes this session's fixes touched — the concrete content for Stage 5.7's
correctness reviewer, and a `GOTCHAS.md` candidate for any DB-backed Python + query-cache-frontend
repo. **Item #9 is new** (closes the §11 defect-6b coverage gap identified during synthesis):

```
Discovery/backend review checklist:
1. WHERE touching a nullable col inside NOT/AND — is NULL handled explicitly?
   (`NOT (x IS NULL AND col ~* rx)` drops rows when col is also NULL → add `col IS NOT NULL AND`)
2. `x or DEFAULT` / `if x:` on config — should [] / 0 / "" mean "user cleared it", not "unset"?
3. URL/text decoding — decoded exactly once? (parse_qs already unquotes; a second unquote corrupts)
4. Restart / self-exit / lifecycle change — what in-memory state resets, and who pays (external APIs)?
5. New env var or default — identical value in code, .env.example, compose, AND GET-defaults?
   Imported from ONE source, not re-typed?
6. json.loads on stored/user data — wrapped in try/except with a sane fallback?
7. Keyword heuristics — does an incidental match misclassify? Require explicit signals.
8. Frontend mutation onSuccess — invalidates EVERY query key the changed setting feeds?
9. Early-return / short-circuit branches — do they skip a warning/log/metric that other
   paths emit? (A silent-failure path that returns early before its sibling paths' logging
   call is a defect class of its own — this closes the gap the original checklist missed.)
```

**Cheap grep/lint (no model needed):** #3 (`unquote` near `parse_qs`), #5 (diff env-var names
across code/`.env.example`/compose), #6 (`json.loads` outside a `try`), #2 (`or _DEFAULT` on a
settings read). **Needs the LLM reviewer:** #1 (nullability needs schema knowledge), #4
(cross-subsystem side-effects), #7 (semantics), #8 (the query-key dependency graph), #9
(control-flow comparison across sibling branches). A good split: run the grep-able items as a
pre-review lint gate before spending reviewer-model tokens on the ones needing judgment.

---

## Appendix B — `deferred_debt[]`: the Review→Fix stage also surfaces scoped-out repo debt

A recurring pattern the original retro found: fixes correctly stayed in scope, but each pass
*surfaced* real repo debt it deliberately didn't touch. That debt evaporates unless captured. The
mechanism (toolkit work, specified below) is separate from the illustrative Teacup examples (fenced
below as **example output only** — not part of this toolkit change).

**Mechanism:** `deferred_debt[]` is a field on the existing `review.json` sidecar (not a new
top-level file — it's a byproduct of the same review pass). Each entry gets a
`debt_hash = sha256(file + ":" + line + ":" + description)[:12]` — the **dedup key**, required so
re-running Stage 5.7 on an unchanged repo doesn't append duplicate `TASKS.md` rows every run
(mirrors the gotcha flywheel's dedup discipline referenced in `AGENTS.md`).

**`TASKS.md` auto-append algorithm** (runs once, at the end of Stage 5.7):
1. For each `deferred_debt[]` item, compute `debt_hash`.
2. Scan all `TASKS.md` rows (Active/Pending + Blocked + Done) for an existing `_debt_hash: <hash>_`
   marker.
3. Found → skip (already tracked, whatever its current state).
4. Not found → append one row to `## Active / Pending`, using `TASKS.md`'s own documented
   optional-metadata convention:
   ```
   - [ ] (P{1 if high, 2 if med, 3 if low}) {description} — scoped out by /sdlc review, {file}:{line} _debt_hash: {hash}_
   ```
   No `plans/tasks/task-N-slug.md` file is created — a lightweight pointer row only; a human or a
   later `/task` invocation promotes it if picked up.
5. Emit one report line: "N deferred-debt items appended to TASKS.md (M already tracked, skipped)."

**Acceptance criteria:**
- [ ] Running Stage 5.7 twice on an unchanged diff appends zero duplicate `TASKS.md` rows the
      second time.
- [ ] A `deferred_debt[]` item never causes a `skills/`, `copilot/skills/`, or `templates/` file to
      be edited — it only ever touches `TASKS.md`.
- [ ] `data.deferred_debt` is additive to the existing `review.json` shape.

**Example output (Teacup session, illustrative only — not toolkit work, never implemented here):**

- **HIGH — broken test import breaks full-suite signal:**
  `backend/tests/test_loved_ones_relationship_circle.py:21` imports `app.api.v1.birthdays` (moved
  to `app.modules.birthdays.router`). One-line import fix + test-image rebuild.
- **HIGH — phantom column (not migration drift):** no migration creates `logged_at`;
  `backend/app/services/signal_confidence.py:43-47` queries `food_logs.logged_at` (table has
  `date`/`created_at`). Rewrite `_nutrition_confidence` to use `date`.
- **HIGH — 2× scrape budget:** `discovery_schedules` has an enabled weekly `community_discovery`
  row for both the real and TEST household — disable the test one.
- **MED — 14 ghost discoveries:** real-household rows, identical `created_at`, generic titles, no
  `agent_jobs` — delete by that timestamp.
- **MED — CLAUDE.md port drift:** doc says `5433`; `.env` and standard is `5432`.
- **MED — frontend tsc noise:** 121 errors hide new ones; add `"target": "es2017"` to kill
  Set-iteration errors cheaply, then triage the rest.
- **LOW — mount fix:** add a scripts bind mount so script tests stop needing host runs.
