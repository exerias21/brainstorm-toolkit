## Brainstorm Result: AI-native SDLC playbook — the four additions, cut to size

### Direction

Anthropic's AI-native SDLC playbook proposes six stages; four of its practices are genuinely
missing here. A five-agent Opus design pass followed by an adversarial critic cut all four to
roughly a fifth of their designed size, and the cuts are the point: every deleted piece was
machinery guarding against a problem created by a decision we then removed.

The organising idea is the playbook's own sentence — **"a skill is an advisory control while a
hook is the deterministic layer behind it."** That is the doctrine this repo half-embodies
(`enforce-model-cap.sh` is the deterministic layer behind the `models.cap` prose) and never
states. It is also the diagnosis of a measured failure: in an audited `/sdlc` run the skill said
**"Read `skills/sdlc/templates/<x>.md` now"** at nine points, the model read **zero** of them
(795 lines of stage contract unread), and nothing detected it. So the doctrine lands **first**,
before any code — written after the hooks, it would be written to ratify hooks already chosen,
which is exactly the trap it exists to name.

Four things shrank, and one repair set appeared that nobody asked for:

- **Test immutability** ships as a **detector**, not a preventer. The preventer's own risk list
  concedes a `Bash`-driven `sed -i` routes around a `Write|Edit` matcher; everything expensive in
  it bought the half it had already conceded is porous. The detector is cross-tool and
  deterministic on all three runtimes.
- **Metrics** shrink to one line: `run-cost-report.sh` computes five real numbers and then
  discards them into an empty marker file. Persisting them is a change from a discard.
- **Findings→plan** shrinks to one sentence: `/repo-health` already writes a `.next-action`
  sentinel; `/brainstorm` already authors plans correctly. Changing which command the sentinel
  names *is* the loop closure.
- **Eval gating** splits: its repairs are free and land now; the money gate lands after Phase 1,
  because its own paths filter fires on every Phase 1 PR.

The repair set exists because the critic verified four currently-shipping defects while checking
the designs. Two of them are load-bearing for the eval gate you approved: `skill-eval.py` has no
`--max-budget-usd` flag at all, so the `$2` cap cannot be passed, and `load_baseline()` reads a
shape `baseline.json` does not have, so the cost-regression guard has never once fired.

### Conventions & reuse

- **Follow:** `scripts/hooks/enforce-model-cap.sh` for any hook shape — `set -u`, stdin read,
  `CLAUDE_PROJECT_DIR` → `git rev-parse --show-toplevel` → `PWD` root resolution (`:24-27`), and a
  PY probe that proves the interpreter **runs** rather than merely resolves (`:28-32`, the Windows
  Store `python3` stub).
- **Reuse:** the envelope's `plan_hash` idiom — `sha256:<hex>` captured at stage N, compared at
  stage N+1 to detect the artifact was rewritten mid-run (`skills/sdlc/templates/state-schema.md:83`).
  The test-immutability detector is *the same mechanism*; it must not become a second expression
  in a new file with a new format. Store the armed hash in the run envelope the way `plan_hash`
  already is.
- **Reuse:** `scripts/ci/test-hooks.sh` as the regression harness for anything deterministic
  (`:2-11` states that is its purpose).
- **Reuse:** `close-tasks.sh`'s `board` subcommand shape for any read-only JSON emitter — never
  writes, exits 0 whenever `--file` parses, additive fields never bump `schema`.
- **Reuse:** the gotcha flywheel's **objective trigger** as the house pattern for any gate, rather
  than inventing a fourth escape-hatch/confirm shape (CLAUDE.md: the protocol is "centralized in
  `skills/gotcha/SKILL.md`").
- **New (justified):** `--max-budget-usd` on `skill-eval.py`, because the flag genuinely does not
  exist and the approved `$2` cap cannot be expressed without it. **Lowering-only** — it may reduce
  the per-case budget, never raise it above the case's own value.
- **Doc drift (all verified, all fixed by this plan):**
  - `docs/PROSE-FIDELITY.md:63-64` still says *"Reach for the Workflow when a step must be
    mechanically guaranteed at scale"* — routing readers to an artifact CLAUDE.md says was deleted
    and must never return, in the document that exists to explain the prose-only thesis.
  - `CLAUDE.md` and `AGENTS.md` are distinct blobs, not a symlink, and have drifted.
  - `state-schema.md:150` marks sidecar `started_at`/`ended_at` **required**; 0 of 22 sidecars on
    this machine carry them, which makes `/sdlc-status`'s median-cycle-time instruction dead.
  - Three spellings of the fix-loop counter exist in the wild (`data.fix_iterations_used`,
    `data.plan_check.fix_iterations_used`, `data.fix_loops_used`). **Do not add a fourth.**

### Implementation Steps

#### Phase 1 — deterministic, local, free (no CI spend, no consumer migration)

1. **The doctrine, in `CLAUDE.md` + `AGENTS.md`.** Insert a short routing rule — roughly four
   questions an author applies to decide whether a rule earns a hook or stays prose. Ground it in
   the repo's real occupants (`enforce-model-cap.sh`, `stop-gate.sh`, `next-action.sh`) and in the
   failure that motivates it (nine unopened template pointers). State the tension honestly: a hook
   is **also** a second expression, and this repo deleted its Workflow because a second expression
   drifted — so the rule must say when that trade is worth paying. Keep it tight; every line here
   is paid on every run. Files: `CLAUDE.md`, `AGENTS.md`.

2. **Fix the two doc-drift defects the doctrine depends on.** Correct
   `docs/PROSE-FIDELITY.md:63-67`'s dangling Workflow reference (it currently recommends reaching
   for a deleted artifact), and reconcile the `CLAUDE.md` / `AGENTS.md` divergence. Neither file is
   under `SHIPPED_GLOBS`, so this step needs no version bump — which is why it front-loads for free.
   Files: `docs/PROSE-FIDELITY.md`, `CLAUDE.md`, `AGENTS.md`.

3. **Repair `skill-eval.py` — the eval gate is untrustworthy without this.** Three fixes:
   (a) add `--max-budget-usd` to the argparse block (`:1063-1065`), resolving **lowering-only**
   against each case's own budget; (b) fix `load_baseline()` so the 2× cost-regression guard
   (`:959-966`) can actually fire — `baseline.json`'s top-level keys are `_comment` / `_runs` /
   `cases`, so `baseline.get(name)` is `None` for every case today; (c) split the exit code so a
   *harness* failure and an *assertion* failure are distinguishable (1 vs 2) — a gate that cannot
   tell "the skill regressed" from "the runner broke" gets disabled the first time it is wrong.
   Files: `scripts/ci/skill-eval.py`.

4. **Repair or delete the `tasks-closeout` eval case.** Verified broken: the fixture's
   `## Active / Pending` section contains only an HTML comment, so neither asserted row exists, and
   no `result.json` for it exists under any result dir. Either add the rows to the fixture or delete
   the case — a permanently-red case in a suite you are about to gate on is worse than no case.
   Files: `evals/skills/cases/`, `evals/skills/fixtures/mini-fastapi/`.

5. **Widen `SHIPPED_GLOBS` to `scripts`.** `setup.sh:288-294` copies the whole `scripts/` tree into
   every consumer (then strips `scripts/ci`), but `check_contracts.py:537` watches only
   `scripts/hooks` — so a change to `close-tasks.sh`, `merge-hook.py` or `record-decision.sh` does
   **not** trip `version-freshness`, and a consumer's cached plugin keeps serving the old copy. This
   is a hole in the check added in `5232045`. Files: `scripts/ci/check_contracts.py`.

6. **Persist the run-cost numbers instead of discarding them.** `run-cost-report.sh:125` does
   `: > .cost-reported` — an empty marker — after computing turns, average context, peak context,
   cache-read total and estimated USD. Write those five into the envelope's `data.cost` instead.
   **Two constraints the design missed:** this makes a Stop hook mutate `run.json`, which
   `stop-gate.sh`, `--resume`'s `plan_hash` check and `close-tasks.sh reconcile` all read — so the
   write must be additive-only, atomic (tmp + `os.replace` — the idiom lives inline at
   `scripts/merge-hook.py:89-97`, not in any named helper), and must never touch a field `--resume`
   validates. Add `data.cost` to `state-schema.md` as an additive field. Files:
   `scripts/hooks/run-cost-report.sh`, `skills/sdlc/templates/state-schema.md`.

7. **Expose `stages_skipped` in the board's `runs[]`.** One line in `close-tasks.sh`'s `do_board`
   run assembly — the field already exists in every envelope and is the cheapest real signal of what
   a pipeline actually ran. Additive; does not bump `schema`. Files: `scripts/close-tasks.sh`.

8. **Test-immutability detector — `arm` / `verify` / `disarm`, no hook.** A cross-tool CLI that
   records the sha256 of the failing test at red-stage and re-checks it at close-out. **Reuse the
   envelope**: the armed hash belongs alongside `plan_hash` in the run envelope `/task` already
   writes, not in a new `.claude/.protected-tests` file with a third run-identity namespace. Emit a
   clear violation line on mismatch. Wire `/task` to arm at red and verify at close-out, and state
   plainly in the prose that this is a **detector, not a preventer** — it proves the test was not
   rewritten; it does not stop a rewrite.

   **Two placement rules, because the obvious choices are both wrong.** It goes at
   **`scripts/protect-tests.sh`**, NOT `scripts/hooks/` — every file in `scripts/hooks/` is a wired
   hook (`enforce-model-cap`, `next-action`, `reseed-context`, `run-cost-report`, `stop-gate`), and
   putting a CLI there tells the next reader it is one. It belongs beside `close-tasks.sh`, which is
   what it actually resembles. And `scripts/ci/test-hooks.sh`'s own docstring (`:2-11`) scopes it to
   "the hooks that make policy DETERMINISTIC" — adding a non-hook's cases makes that statement stale
   the moment it lands, so **widen the harness's scope line to "deterministic controls" in the same
   commit**. One harness, not two; a second test file would be one more thing to keep aligned.

   Files: `scripts/protect-tests.sh` (new), `skills/task/SKILL.md`, `scripts/ci/test-hooks.sh`,
   `skills/sdlc/templates/state-schema.md`.

9. **Close the loop in one sentence.** `/repo-health` already writes a `.claude/.next-action`
   sentinel naming the highest-impact command. When a finding carries enough substance to need a
   plan rather than a fix, name `/brainstorm <finding>` instead of `/sdlc <fix>`. `/brainstorm`
   already writes the plan file, already uses `plan.md.template` verbatim, already appends the
   `TASKS.md` rows with a correct `_plan:` tag, and already asks the user. **Do not touch the
   "never modifies code, never opens a PR" line** — `scripts/ci/forbidden-phrases.txt` pins its
   occurrence count at 2, and editing it turns every subsequent PR red. Files:
   `skills/repo-health/SKILL.md`.

10. **`docs/ENFORCEMENT.md` — worked examples only.** After step 8, so the occupant list is written
    once and is not stale on day one. No cross-tool cost table (it restates `docs/SEAM.md:95-99`),
    no new-hook checklist (the two shipped hooks already demonstrate it). **Cite-only, never
    `**Read ... now**`** — `check_docs_load_vs_cite` fails a Read-now pointer into `docs/`.
    Files: `docs/ENFORCEMENT.md` (new), `CLAUDE.md` (one citation).

11. **Version bump, last commit of the phase.** Steps 6, 8 and 9 touch `scripts/hooks/`, `skills/`
    and `templates/` — already under `SHIPPED_GLOBS` — so `check_version_freshness` fails without a
    bump. **Steps 7 and 8 also touch top-level `scripts/`, which is only watched because step 5
    widened `SHIPPED_GLOBS`** — so step 5 must land before them, or those two changes ship
    unwatched and a consumer's cached plugin keeps serving the old copy. That is a real ordering
    dependency, not a formality. Bump **both** `.claude-plugin/plugin.json` and
    `.claude-plugin/marketplace.json` (currently `0.5.0`). Files: `.claude-plugin/plugin.json`,
    `.claude-plugin/marketplace.json`.

#### Phase 2 — the money gate (after Phase 1 lands)

12. **`.github/workflows/skill-evals-smoke.yml`.** Paths filter on `skills/**`, `agents/**`,
    `copilot/**`, `codex/**`, `templates/**`, `scripts/hooks/**`, `CLAUDE.md`. Run 1–2 named cases
    with `--max-budget-usd 2` (the flag step 3 added). **Must include
    `pip install -r evals/skills/fixtures/mini-fastapi/requirements.txt`** — `skill-evals.yml` has
    no pip step anywhere, so without it the gate is red on run one. **Fork preflight:** a PR from a
    fork has no API key — skip cleanly rather than failing closed on a contributor. Full `--all`
    stays on the weekly cron. No retry loop (it doubles spend on exactly the runs a human is about
    to read, and converts a one-flake red into a silent green), no PR-comment step (the job summary
    is already on the same page). Files: `.github/workflows/skill-evals-smoke.yml`.

### Cross-Module Touchpoints

- **`/task`** gains the arm/verify calls (step 8) — the only skill whose flow changes.
- **`/repo-health`** gains one routing sentence (step 9) and remains read-only; it still writes only
  the sentinel it already writes.
- **`/sdlc-status`** reads `data.cost` once step 6 persists it — no change required, but it is where
  the numbers become visible.
- **Consumer repos:** this plan adds **no new `project.json` keys**, so no `/repo-onboarding` re-run
  is needed anywhere. That was the original concern and the cuts dissolved it: the only key any
  design proposed (`pipeline.test_immutability`) died with the preventer.
- **Overlays:** verified not required — `copilot/skills` holds brainstorm, brainstorm-team,
  dead-code-review, sdlc; `codex/skills` holds sdlc only. None of the touched skills has an overlay.
  **Guard:** if any step later grows a stage-body edit inside `skills/sdlc/SKILL.md` rather than a
  template, it silently becomes a three-leg edit.

### Open Questions

- **Which 1–2 cases** form the smoke set (step 12). `task-health-endpoint` is the obvious candidate
  but its `pytest_green` assertion has reportedly never passed in Actions — verify before pinning it,
  or the gate is born red.
- **Does `data.cost` belong in the envelope at all**, given a Stop hook writing the file `--resume`
  validates is a genuine behaviour change? The alternative is a sibling `cost.json` sidecar, which
  costs a file but touches nothing `--resume` reads. Decide at implementation time with the
  atomicity constraint in hand.
- **Line ceilings are unenforced** — `validate_skills.py` has no line-count check. Three designs
  treated the ceiling as a merge gate; it is adjudicated by a human reviewer only. Worth knowing
  before arguing about `/task`'s length.

### Appendix: Alternatives Considered

- **Test-immutability as a `PreToolUse` preventer** (the designed Item 1) — rejected. Its own risk
  list concedes a `Bash`-driven `sed -i` routes around a `Write|Edit` matcher, and the expensive
  parts (installer surgery on shipped wiring, a tri-state config key, Windows path casefolding, a
  self-exemption to avoid deadlocking on its own marker, 8 of 12 test cases, a `hooks/hooks.json`
  entry it forgot) all bought the porous half. The detector delivers the stated value in full.
- **A `.claude/.protected-tests` JSONL store** — rejected as a second expression of `plan_hash` and
  a third run-identity namespace beside `run.json.feature_slug` and `TASKS.md`'s `_plan:`.
- **A `close-tasks.sh metrics` subcommand** (the designed Item 3) — rejected. Its `not_computable[]`
  array was longer than its metric list, over N=8 runs, for one developer; two of its five metrics
  duplicated `/repo-health` Check 11 and the board's existing `tasks[]`.
- **`/repo-health` authoring `plans/health-*.md`** (the designed Item 5) — rejected. Five independent
  brakes (recurrence cache, eligibility allowlist, minimum item count, a hard cap of 1, filename+row
  dedup) plus a default-off key plus a confirm gate, all guarding against plan spam created by
  deciding a machine should author plans unprompted. It also breaks `forbidden-phrases.txt`, squeezes
  the description char budget past its ceiling, and produces an artifact `setup.sh` gitignores in
  every consumer.
- **Full `--all` evals on every config PR** — rejected on cost; eight skill commits shipped in one
  session would have been eight full suite runs.
- **`/repo-onboarding --merge-new-keys`** — rejected as unnecessary once the plan stopped adding
  config keys. A `/repo-health` drift check remains the right shape **if** a future change does add
  keys.
- **`intent.md` / `spec.md` as separate stages** (playbook Stages 1–2) — rejected. This repo collapses
  both into one brainstorm plan, which is correct for a solo developer; adding a stage is cost with
  no gate behind it.
- **`bands.yaml` control bands, 1σ/2σ/3σ** (playbook Stage 6) — rejected. Needs a metric with a stable
  baseline and a team to route findings.
- **Managed settings / sandbox / `permissions.deny`** (playbook Stage 5) — rejected as org-policy
  machinery for fleets.
