# Stage 5 — Validate (shared)

Canonical for `/sdlc`. One stage, one gate, one sidecar.

One stage, one gate, one sidecar. It answers the two questions that matter after implement:
**does it run, and is it what the plan asked for?**

This replaces the former Stages 5, 5.5 and 5.6. They asked the same question three ways — "do
the tests pass", "does the code fulfill the plan" (four checklist agents), "does the flow match
the plan" (a narrative trace) — each with its own dispatch, sidecar, gate and pause, and each
paying its own round of orchestrator chatter. A current model does not need the plan-vs-diff
check partitioned into api/ui/data/cross-module lanes to do it well.

### 1. Run the suite — in a sub-agent, never inline

**Dispatch the `test-runner` agent** (by type: `brainstorm-toolkit:test-runner`, or bare
`test-runner` when vendored). It is pinned to **Haiku** and returns a structured pass/fail
summary — never raw output. Pass it the surfaces the diff touched (see
`templates/changed-files-gate.md`) so it skips suites for untouched surfaces.

**Do not run the test commands yourself.** Test output is the single largest source of shell
traffic, and shell traffic was ~53% of main-thread tokens on an audited run. Every line of
runner output you take directly is context you carry for the rest of the session; taken by the
agent, it dies with the agent. You need `{name, file, expected, actual}` to write a fix — you
do not need 400 lines of pytest.

You get back `{layers, failures[], preexisting[], green, totals}`. Report only **new** failures
as failures; `preexisting[]` is noted separately and does not gate.

- Log audit (if `logs.command` configured)
- Frontend unit tests (if `test.frontend` configured **and** the frontend surface was touched)
- Backend unit tests (if `test.unit` configured **and** the backend surface was touched)
- **E2E / visual check** — dispatch the `e2e-test-runner` agent (by type:
  `brainstorm-toolkit:e2e-test-runner`, or bare `e2e-test-runner` when vendored) if `test.e2e`
  is configured **and** the frontend surface was touched. It runs its own bounded fix loop with
  a flaky-test guard; its iterations count toward the shared budget. If the frontend surface was
  touched and no `test.e2e` is configured, raise a **soft-stop candidate** ("frontend changed
  but no visual check ran") — never pass silently. Its semantics (ask once, proceed on
  confirmation, proceed-and-document when non-interactive) are the **Soft-stop tier** section of
  `skills/sdlc/templates/changed-files-gate.md`.
- Eval regression (if `eval.runner` configured) — this is the only place evals run.

### 2. Check the delivery against the plan

**Skip when there is no plan target** (an ad-hoc `/sdlc` description) — there is nothing
to check against, and say so rather than passing silently.

Dispatch **one agent** — the `ux-plan-validator` (by type: `brainstorm-toolkit:ux-plan-validator`,
or bare `ux-plan-validator` when vendored), Sonnet by default per
`skills/sdlc/templates/models.md` — with the plan and the diff, and this brief:

> Verify the delivered change against the plan on two axes, and report them separately.
> **(a) Requirements:** walk every acceptance criterion and implementation step in the plan and
> mark it met / partially met / missing, with a `file:line` for each judgement. Feature
> completeness and behavioural correctness — not code style, which the tests and the review
> stage cover.
> **(b) Flow (the flowsim trace, inline):** trace each flow the plan claims through the actual
> source, in order, and flag
> `MISMATCH` (code does something different), `UNCLEAR` (can't follow it), or `MISSING` (the
> step isn't there). This catches the case where every individual criterion passes but the
> end-to-end path silently deviates — wrong ordering, a skipped step, a different module doing
> the work.
> Return `{requirements: [...], flow: [...], requirements_green: bool, flow_green: bool}`.
> `requirements_green` is false if any requirement is missing. `flow_green` is false if any flow
> step is `MISMATCH`/`MISSING`. Report the two independently — never collapse them into one
> verdict; the orchestrator gates them differently.

Give it the test results from step 1 as corroborating evidence.

**The flow axis only gates when it is witnessed.** Compute `witnessed` = step 1 produced real
results for the touched surfaces (any of `eval.runner`, `test.unit`, `test.frontend`, `test.e2e`
actually ran and returned — configured-but-skipped and unconfigured both count as *not* run).
Record it as `data.flow_witnessed`.

- **Witnessed** — the flow axis gates normally: `flow_green: false` fails the stage.
- **Unwitnessed** — the flow axis still runs and its findings are still reported, but they are
  **advisory only**: they cannot fail the stage and cannot enter the fix loop. Say so in the
  report (`flow: advisory — unwitnessed (no test evidence)`).

The reason is cost, not squeamishness. Unwitnessed, the flow trace is grep plus inference over a
diff, with no runtime evidence to falsify it — and a `MISMATCH` it invents does not cost one
agent call, it costs up to three fix-agent dispatches plus three full re-runs of this gate. Note
the asymmetry it corrects: Stage 5.7's reviewer is opt-in and still gets an evidence-required
verify pass *and* a false-positive circuit breaker; this axis is always-on and has neither, yet
it could open the same loop. Advisory-when-unwitnessed is the cheapest way to close that gap
without losing the signal.

The requirements axis (a) gates **unconditionally**, witnessed or not. It is grounded in two
texts that are both present — the plan and the diff — and it is the pipeline's only detector for
a plan step that was silently never implemented. A test suite cannot fail for a step nobody
wrote, especially one whose tests Stage 3 generated from the implementation in this same run.

Axis (b) **is** the flowsim step of the pipeline — it still runs as a stage of the process, it
just no longer writes its own sidecar (its results live in `validate.json`'s `data.flow[]`). For
a deeper interactive trace, `/flowsim` remains available as a standalone skill; this is its
inline, bounded form.

### 3. Gate

Green iff no new test failures **and** `requirements_green` **and** (`flow_green` **or** not
`data.flow_witnessed`). On failure, route into the shared fix loop
(`skills/sdlc/templates/fix-loop.md`; 3 iterations — Stage 5.7's budget is separate). A `MISMATCH` where the *code* is right and the
*plan* is stale is a `plan-wrong` class — pause and say so; do not "fix" code to match a stale
plan.

**Writes** `stage-outputs/validate.json` with `data.layers{logs,frontend,backend,e2e,eval}`,
`data.new_failures[]`, `data.preexisting_failures[]`, `data.requirements[]`, `data.flow[]`,
`data.flow_witnessed`. The former `plan-validate.json` and `flowsim-<slug>.json` sidecars are
gone; `/status` and `/repo-health` read `validate.json` for all of it.
