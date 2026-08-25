---
name: sdlc-lite
description: >
  Sequential full-pipeline-minus-git skill for Copilot. Takes a plan file, a
  task id, a task range (e.g. "1-5"), or an ad-hoc description; runs
  implement → evals → validate; then hands off the
  validated changes for you to commit. No commit, no branch, no push, no PR.
  Copilot-optimized overlay of canonical /sdlc-lite — every stage runs inline
  (no parallel sub-agents, no Plan mode). Same stages as /sdlc; only /sdlc
  touches git.
argument-hint: "<plan-file | task-id | task-range | description> [--resume] [--queue [N]]"
metadata:
  brainstorm-toolkit-applies-to: copilot
disable-model-invocation: true
---

# sdlc-lite (Copilot Edition — Sequential)

Sequential version of `/sdlc-lite`. Canonical `/sdlc-lite` uses parallel agent
dispatch for the sanity-check on Claude; this overlay
runs every stage inline, one at a time. Same stages as `/sdlc`; the only
difference is Stage 6 — `/sdlc-lite` does **no git writes** (it hands you a
validated tree to commit), while `/sdlc` commits + opens a PR.

**Model-tier cap** (`models.cap` in `project.json`, or `--model <tier>`; flag > config > default — see `skills/sdlc/templates/models.md`) is honored wherever sub-agents are dispatched. On this runtime every stage runs inline in the session model, so the cap is advisory here — set your session model to the cap tier for the savings.

> **`skills/sdlc/templates/*` paths below are citations into the brainstorm-toolkit
The shared `skills/sdlc/templates/*` tree IS installed on this runtime (setup.sh ships it
and rewrites the citation prefix). Open the templates the stages name.
> skill tree wholesale, so `.github/skills/sdlc/` ships `SKILL.md` only. Do not try to
> open them; everything this overlay needs to execute is inlined here. Read them in the
> plugin repo only if you are changing the contract itself.

## When to use

| Skill | Input | Terminal action |
|---|---|---|
| `/task <description>` | ad-hoc ask | TDD red-green → commit only if you ask |
| `/sdlc-lite <plan \| task-id \| range \| desc>` | plan, task(s), or ask | full pipeline → validated changes left for you to commit |
| `/sdlc <plan-file>` | plan file | full pipeline → commit + PR |

Reuses `/sdlc`'s stage templates and state envelope verbatim — no new
templates, no new schema beyond `run.json.pipeline = "sdlc-lite"` and a
`handoff.json` sidecar at Stage 6.

## Prerequisites

- You are on the branch the changes should land on. This skill never switches
  branches and never commits.
- `.claude/project.json` optional. The eval stage and Stage 5's plan check skip
  silently when their config or a plan target is absent.

## Output verbosity (default: quiet)

**Default `quiet`.** Stage narration is re-read by every later turn in the same
session, so it compounds. Print **one** line per stage —
`<stage> · <verdict> · model: <tier> (cap: <cap|none>)` — and one summary table at
the final report. No intermediate narration, no restating file contents, no
echoing a review pass's full output. Detail already lives in the
`stage-outputs/` sidecars, which are the durable record.

**Always printed regardless of verbosity:** the per-dispatch `model:` line, every
gate verdict, any PAUSE block, the `Next:` seam line, and warnings (config-presence,
reviewer-axis cost note, session-model nudge).

`pipeline.output.verbosity: "normal"` in `.claude/project.json` restores full
narration. A missing `project.json` means `quiet` — by design: the saving must not
depend on a file the repo may never have created.

**Config-presence check (once, at the first stage).** If `.claude/project.json` is
absent while `.claude/project.json.example` is present, warn once — every gated
setting (`models.cap`, `pipeline.*`, test commands) is silently inert.

## Stage 0 — Resolve input

- **Plan file** (path ending `.md` that exists) → use as the plan, like `/sdlc`.
- **Task id** (`task-NNN` or a row number) → read that row + linked task file;
  its `parent_plan:` becomes the Stage 5 plan target.
- **Task range** (`N-M`, `task-N..task-M`, `tasks N-M`) → resolve every
  `Active / Pending` row in range; execute as a batch (one commit per task).
- **Ad-hoc description** → create a new row + task file via `/task`'s procedure.
- **`--queue [N]`** (attended backlog loop) → select `Active / Pending` rows by
  priority (top `N` or `pipeline.loop.max_items`, default 5; `P1>P2>P3`, `[~]`
  first) and loop the pipeline over them, **re-scanning `TASKS.md` between items**
  so rows added mid-run join the loop. Stop conditions (`pipeline.loop.*`): a
  `paused`/`failed` item **parks** the loop (write its `/status` hint to
  `.claude/.next-action`), a `confirm:true` next action parks it, and
  `max_items` / `max_consecutive_failures` (default 2) bound it. **No git writes;
  every park is a written next-action, never a dead end.** Each item's envelope
  stays **canonical** (`state-schema.md`: `feature_slug`/`plan_file` keys, required
  fields, canonical stage names — never `slug`/`plan` or `phase-*` stages; queue/phase
  data goes in `data.*`) with a **distinct per-item slug** `<plan-slug>-<row-id>` (never
  the shared plan slug — items would collide on one envelope dir). On park: set
  `run.json.status = "paused"` + `run.json.next_action = {cmd, confirm}`, **and — mandatory,
  don't skip it —** append the sentinel line:
  `line='{"cmd":"/sdlc-lite <plan> --queue","source":"sdlc-lite","confirm":false}'; grep -qF "$line" .claude/.next-action 2>/dev/null || echo "$line" >> .claude/.next-action`
  (plus a `confirm:true` line for the confirm action if it parked on one). The **sentinel is
  the ONLY thing the Stop hook surfaces**; `run.json.next_action` alone is invisible, so a park
  that sets only the envelope field leaves the loop dead.
- **Long runs — context hygiene:** a many-hour loop accumulates context in the one orchestrator
  session. Config knobs + the fresh-process-per-item escalation (Copilot has no compaction/reseed
  hook) are in `docs/LOOP-HYGIENE.md` (plugin repo).

Mark resolved rows `[~]`. Derive `slug` per `docs/CONVENTIONS.md`; initialize
`.claude/pipeline/<slug>/` with the canonical `run.json` — **including the computed
required fields that get dropped otherwise (DQ6):**
`plan_hash: "sha256:$(sha256sum <plan> | cut -d' ' -f1)"`, `started_at` = `updated_at`
= `"$(date -u +%Y-%m-%dT%H:%M:%SZ)"`. Omitting them breaks `--resume` + `/status`/`/repo-health` staleness.

**`--resume`:** if `--resume` was passed, read the existing `run.json` instead of
re-initializing — reject on a `plan_hash` mismatch, skip stages whose sidecar shows
`status: "pass"`, and resume at the first non-passing one (follows `/sdlc`'s
Resumption rules; error if there's no prior run).

## Stage 1.5 — Sanity check

Run `/sdlc` Stage 1.5 inline (sequential pre-flight). Not gated, not optional.
For a range, run once over the combined set. Stop and report on a real blocker.
`agents.sanity_focuses` selects which checks run (default all three); on this
runtime `models.sanity` is advisory like every tier — set your session
model instead.

## Stage 2 — Implement

**Runtime note — why there is no delegation rule here.** The canonical `/sdlc` forbids the
orchestrator from calling Write/Edit during Stage 2, because on Claude the implement work
belongs in a sub-agent whose context is discarded. **This runtime has no sub-agent seam**, so
that rule cannot apply: you *are* the implementer and you must write the files. The cost it
guards against is real here too, though, and the mitigation is different — keep the session
short and hand off at stage boundaries (`docs/LOOP-HYGIENE.md`), because every file you write
stays in your context for the rest of the run.


Run `/sdlc` Stage 2 inline, including its **auto-gate** (see
`.github/skills/sdlc/SKILL.md`), preceded by **live-code grounding**.

**Live-code grounding** (inlined from `skills/sdlc/templates/convention-grounding.md`;
scope the recon to the feature's target area, never the whole repo):

1. Find the **2–3 closest existing implementations** of the same kind of thing (another
   route, migration, component, CLI command) by grep/glob — let the code, not memory,
   tell you the shape.
2. Extract their patterns with `path:line` citations: where this kind of code lives,
   naming, error/logging shape, the data-access seam, dependency + import conventions,
   test layout.
3. Read `AGENTS.md` / `CLAUDE.md` / `GOTCHAS.md` / `.claude/project.json` as *stated
   intent only*. **Where a doc and the live code disagree, the code wins** — record it on
   the `Doc drift` line and make it actionable in the Stage 6 hand-off (nudge `/gotcha`
   if it is a genuine trap).
4. Prefer extending an existing module/helper/type over adding a parallel one; introduce
   a new pattern only when none fits, and say why.

Honor any `## Conventions & reuse` block already in the plan, re-verifying it against live
code (the code may have moved since the plan was written). A plan with no reuse and no
justified new pattern is a red flag — it usually means the recon was skipped.

Compute `surfaces_touched` (planned files vs.
the surface globs) and `task_count` (step count). **Decompose iff**
`surfaces_touched >= 2` AND `task_count >= DECOMPOSE_MIN_TASKS` (default `6`,
override via `agents.decompose_min_tasks`) AND the per-surface file sets are
disjoint.

- **Single-pass (default):** execute the plan/task steps inline, in order. No
  worker handoff. Follow the `Files` section (fill it in as you go).
- **Decompose (large multi-surface plan):** split the files into disjoint lanes
  (data / backend / frontend / docs) with a per-lane interface contract,
  implement each lane in dependency order (one fully before the next, editing
  only that lane's files and coding against the contract), then converge —
  reconcile imports / call sites / shared types and sweep for unresolved imports
  or symbol collisions. Record `stage2_decomposed` + `lanes` and write
  `decompose.json` / `implement-<lane>.json` / `converge.json`.

For a task range the gate sees the combined file/step set. After implementing,
run `git diff --stat` and confirm expected files were touched. Stop on any
blocker.

## Stage 3 — Generate evals

Same procedure as `/sdlc` Stage 3 (see `.github/skills/sdlc/SKILL.md`):
- new Python pure functions → `tests/eval/test_{slug}_eval.py`,
- scripts with `--input` fixtures → `<eval.features_dir>/{slug}/`,
- no testable surface → note and proceed.

**Skip silently if no `eval.runner` is configured.**

## Shared fix loop (Stages 5 / 5.5 / 5.6)

On a gate failure: parse the results, dispatch a fix for **only** those failures (no
refactor), re-run the gate. Max **3 iterations, used by Stage 5**. On
exhaustion, pause with the Diagnosis block from `/sdlc` (fastest path `/status`;
or name the class — flaky · code-defect · plan-wrong · config-missing — and one command),
then `--resume` reuses the green stages.

**Stage 4 was deleted.** It ran `eval.runner`, then Stage 5 ran the same command again as
its eval-regression layer — a strict prefix. Sharing this budget, its pause could halt a
run on self-authored evals before the real suite was ever consulted. Stage 3 still authors
the tests; Stage 5 runs them.

## Stage 5 — Validate (one stage)

**Tests: report structure, not output.** The canonical `/sdlc` dispatches a Haiku `test-runner`
sub-agent so raw suite output never enters the orchestrator's context. This runtime has no
sub-agent seam, so you run the suites yourself — but report only
`{layer, name, file, expected, actual}` per failure plus totals. Do not paste runner output
into your narration: it is the largest single source of context bloat, and it stays in your
context for the rest of the run.


Two parts, one gate, one `validate.json`:

1. **Run the suite** — `/test-check` over the touched surfaces; report only NEW failures as
   failures, note pre-existing ones separately. Includes eval regression when `eval.runner` is
   configured (the only place evals run).
2. **Check against the plan** — one pass over the plan + diff reporting **requirements**
   (met / partial / missing, each with a `file:line`) and **flow** (`MISMATCH` / `UNCLEAR` /
   `MISSING`) *separately*. Skip this part when there is no plan target, and say so.

**The flow axis only gates when it is witnessed.** Set `witnessed` = step 1 actually ran and
returned results for the touched surfaces (`eval.runner` / `test.unit` / `test.frontend` /
`test.e2e`); configured-but-skipped and unconfigured both count as not run. Record it as
`data.flow_witnessed`.
- Witnessed → flow gates normally.
- Unwitnessed → flow findings are reported as **advisory**: they cannot fail the stage and
  cannot open the fix loop. Say `flow: advisory — unwitnessed (no test evidence)`.

Unwitnessed, the flow trace is grep plus inference over a diff with nothing to falsify it, and
an invented MISMATCH costs up to three fix dispatches plus three re-runs of this gate — not one
call. The requirements axis gates unconditionally: it is grounded in two texts that are both
present, and it is the only detector for a plan step that was silently never implemented.

Green iff no new failures AND no missing requirement AND (no MISMATCH/MISSING flow step OR flow
is unwitnessed). Failures route through the shared fix loop. A MISMATCH where the code is right
and the plan is stale is `plan-wrong` — pause and say so; never edit code to match a stale plan.

This replaces the former Stages 5, 5.5 and 5.6, which asked the same question three ways.


## Stage 5.7 — Adversarial review (inline, sequential)

**Opt-in, permanently — never runs by default.** Runs after Stage 5, before Stage 6,
only when explicitly turned on this run (`--review-model <name>`, or an explicit
`pipeline.review_fix.enabled: true`; default reviewer `opus` once enabled — see
`skills/sdlc/templates/models.md`). An omitted `pipeline.review_fix` block, or
`enabled` left unset, means OFF — there is no default-on flip. Skipped when not opted in,
`--no-review` was passed, `pipeline.review_fix.enabled: false`, or the changed-files-gate reports a
docs-only diff — **unless a `.claude-plugin/marketplace.json` exists at the repo root**, in which
case this is a
skill repo, `.md` skill files ARE the code surface (there is no separate `.env`/compose surface to
gate on here), and this docs-only self-skip does not apply — Stage 5.7 runs, with the
config/env/docs lens repointed to `skills/sdlc/templates/stage-5-skill-repo.md`'s structural checks in place of
env/compose checks. (This mirrors D6 / plan §5.3 gate 1's exemption on the canonical/Workflow side;
this overlay runtime has no other skill-repo detection of its own, so the marketplace-manifest
check above IS its skill-repo signal.)

**Cap the fan-out with `agents.code_review_max_lenses`** (default `4`, inert until set): it
truncates the resolved list **in order** after circuit-breaker demotion, so `1` keeps
`correctness`. A non-integer or non-positive value falls through to `4` — never `0`, which would
silently disable the stage. Every lens runs at the **reviewer** model (`models.code_review`,
default `opus`), which `models.cap` does **not** govern; when a cap is set and the reviewer
outranks it, say so and point at `models.code_review` / `agents.code_review_max_lenses`.


**No parallel sub-agents on this runtime.** Run each **configured** lens
(`agents.code_review_lenses` in `.claude/project.json`; when the key is absent, all four
defaults below. Setting fewer cuts this stage's cost roughly linearly — it is one pass per
lens — so pick by what the diff risks; `correctness` is the highest-yield single lens. Print
the resolved list before starting.) The defaults: correctness,
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

**False-positive circuit breaker.** Even though this runtime reviews inline with no sub-agent seam,
it still updates the same cross-run ledger, `.claude/pipeline/_review-stats.json`: after each run,
append this run's raw/confirmed counts per lens and recompute demotion. A lens repeatedly producing
unconfirmable findings is auto-demoted from dispatch (skipped, and recorded in
`review.json.data.demoted_lenses`) until 5 consecutive runs at ≥60% confirmed-rate re-promote it.

## Stage 5.8 — Fix-prompt generation + approve loop

For confirmed findings, draft a structured fix spec per finding, applying the auto_fixable rubric
(a bug fixing an explicit contract vs. a product/design decision — see
`skills/sdlc/templates/models.md`). Per `pipeline.review_fix.mode` (default `interactive`):
- **`interactive`**: present each fix spec for approve / edit / skip. Approved specs run through
  the existing Stage 2/4 implement+fix machinery inline, then a fresh adversarial re-review of the
  touched files (this loop iteration's own pass) decides whether another iteration is needed. Loop
  until clean or `max_fix_loops` (own budget, separate from the shared fix budget).
- **`auto`**: apply every confirmed `auto_fixable: true` finding without prompting, bounded by
  `agents.code_review_max_fix_loops` — EXCEPT `auto_fixable: false` findings (design
  decisions), which are always surfaced, never auto-applied.
- **`off`**: report only.

**Post-fix validation (once, after the loop exits — not per iteration):** if any fix was applied
this run, re-run the Stage 5 `validate` gate exactly once before Stage 6. A regression there pauses
the run for **both** `/sdlc` and `/sdlc-lite` — an objective test break, unlike the severity-gated
review-finding blocking below, stops both modes rather than handing off broken code (see the
canonical prose's "Post-fix validation").

Write a single `stage-outputs/review-fix.json` with `data.loops[]` (one entry per pass) — never
numbered `review-fix-<n>.json` files. `/sdlc-lite`'s posture is **warn-and-hand-off, not blocking**: a surviving high-severity confirmed
finding is reported prominently in the handoff report (consistent with the existing warn-only
secret scan) but does not prevent handoff — you decide whether to fix before committing.

## Stage 6 — Hand off (no commit, no git writes)

Run the full pipeline, then **stop at the edge of git**. No commit, branch,
push, PR, or `/review`. You review and commit.

1. Secret scan the changed files (gitleaks if available, regex-fallback
   otherwise). **Warn-only** — surface findings (file:line) but never block.
   HIGH findings get a `⚠ HIGH:` prefix; worth scrubbing before you commit.
2. **Report, don't commit.** Show `git diff --stat`, the files changed, and a
   suggested commit message. Do NOT run `git add`, `git commit`,
   `git checkout -b`, `git push`, `gh pr create`, or `/review`. Leave the tree
   as the pipeline produced it.
   ```
   Suggested (run yourself):
     git add <files>
     git commit -m "feat: <title>"
   ```
   **Range**: changes from all tasks accumulate in the tree; you slice the
   commits when you review.
3. **Capture at loop-exit + seam** — run the shared protocol in
   `skills/gotcha/SKILL.md`. Auto-draft a gotcha entry **only** on an
   objective trigger — a fix-loop that **failed-then-recovered**, or the
   user voicing surprise — route it through gotcha's dedup, one-tap confirm.
   A clean run stays silent (no vibe-gating). If capture is
   **declined/deferred**, drop the seam sentinel instead:
   append ONE structured line deduped by `cmd` (multi-slot; see `docs/SEAM.md`):
   `line='{"cmd":"/gotcha <drafted text>","source":"sdlc-lite","confirm":false}'; grep -qF "$line" .claude/.next-action 2>/dev/null || echo "$line" >> .claude/.next-action`
   (never a bare `/gotcha`).
4. Mark each resolved `TASKS.md` row `[x]`, move to `Done`, set
   `status: completed` in the task file(s) — work is done and validated; only
   the commit is left to you.
5. **Leave re-entry rows** so the queue keeps the follow-up: when a
   manifest/lockfile/Dockerfile changed (deploy-delta), append
   `- [ ] (P1) rebuild <env> for {feature-slug} (dependency change — rebuild, not restart) — plans/{feature-slug}.md`;
   and a `- [ ] (P2) verify {feature-slug} deployed — `/repo-health` plans/{feature-slug}.md`
   row closes the loop the same way `/sdlc` Stage 6 does.
   **Then print the manual-verification line** from `.claude/project.json` `stack.*` (all
   keys optional): `stack.rebuild` on the deploy-delta case (a dependency changed, so a
   plain restart runs stale code), otherwise `stack.up`; append `stack.url` when set.
   **Printed, never auto-run** — you asked for a validated tree, not a running one. If a
   needed key is absent, name the key instead of guessing a command.

Write `stage-outputs/handoff.json` =
`{branch, files_changed[], committed: false, suggested_commit_msg}`.
Set `run.json.status = "complete"`. Also set `run.json.next_action = {cmd, confirm}`
(L8) to the proposed follow-up (`/repo-health` on complete;
`/status` on pause) so `/status` recovers the handoff after the sentinel fires;
omit when there's none.

## Stage 7 — Report

Summarize: branch the changes sit on (uncommitted), files changed, suggested
commit message, eval pass/fail, test-check summary, the Stage 5 plan check —
requirements verdict plus the flow axis and whether it was witnessed or advisory
(or "skipped — no plan target") — and anything left open. Make clear **nothing was
committed** — the next move is yours.

## Gotchas

- **Does no git writes.** No commit, branch, push, PR, or `/review`. Hands you
  a validated tree; you commit. Only `/sdlc` touches git history.
- **Stage 5's plan check runs whenever there's a plan to check.**
  when there is no plan target — not behind a frontmatter knob.
- **Don't fork `/sdlc`'s templates.** If a stage needs different copy, it's a
  `/sdlc` job — re-invoke as `/sdlc`.
- **Range accumulates in the tree** — all tasks' changes land uncommitted
  together; you slice the commits.
