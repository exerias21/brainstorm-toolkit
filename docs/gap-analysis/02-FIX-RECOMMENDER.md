# Gap 2 — The fix recommender: turning a paused run into a next action

**Gap:** every red path in the pipeline terminates in a variant of *"fix manually, then
re-run."* No agent reads the failure evidence the pipeline already wrote and recommends —
let alone drafts — the fix action. And because `--resume` was deferred, the recommended
"re-run" is worse than it sounds: a fresh `/sdlc <plan>` **overwrites the prior envelope and
restarts from Stage 1**, discarding every green stage the paused run already paid for.

**Lever:** a **`/triage [<slug>]` skill** (the red-path sibling of the designed-but-unbuilt
Review→Fix stage), plus finally shipping **Phase 1B `--resume`** so the recommendation "resume
from Stage 4" is actually executable.

---

## The red paths as built (all dead ends)

| Where it pauses | The message | What the user gets |
|---|---|---|
| Stage 1.5 critical sanity finding | "report to user and STOP — the plan needs human revision" | issue list; no suggested plan edit, no `/brainstorm` re-entry |
| Stage 4 eval-fix budget exhausted | "Fix manually, then re-run `/sdlc {plan_file}`" | remaining-failures summary; re-run restarts from scratch |
| Stage 5 e2e `failed_after_max_iterations` | pause, same shape as Stage 4 | persistent-failure list |
| Stage 5.5 validators fail ×3 | "report to user and stop" | validation report |
| Stage 5.6 flowsim mismatch ×3 | "a human should adjudicate (sometimes the plan was wrong, not the code)" | file:line anchors — the *best* evidence of the lot, still no recommended action |
| Lane blocker in Stage 2b | "STOP and report" | blocker text |

Note what's true in every row: **the evidence is already structured and on disk**
(`eval-fix.json.data.remaining_failures[]`, `plan-validate.json.data.failures[]`,
`plans/flowsim-<slug>.json.mismatches[]`, lane `implement-<lane>.json.data.blockers_reported[]`).
The pipeline did the hard part — collecting machine-readable failure state — then hands the
human a prose apology instead of a diagnosis.

Detection downstream is also recommendation-free: `/status` flags the non-terminal run
("reconcile"), `/repo-health` Check 7 flags it, the Stop hook warns about it — three flaggers,
zero fixers. The only remediation that exists is destruction (`/status --prune-stale`).

## Proposed shape: `/triage [<slug>]`

Default slug: the single most-recently-updated non-terminal run on the current branch (the
same selection rule continuity detection already uses).

**Step 1 — classify.** Read `run.json` + the failing stage's sidecar and bucket the failure:

| Class | Signal | Recommended action shape |
|---|---|---|
| **Flaky / environmental** | failure not reproducible on a single re-run; e2e flake-guard tripped; log audit noise | re-run the one gate; if green, resume |
| **Real code defect** | eval/test failure with stable expected-vs-actual | drafted fix spec → a `/task` (or direct fix + resume) |
| **Plan is wrong** | flowsim MISMATCH where the code is defensible; Stage 1.5 critical; UNCLEAR markers | drafted plan edit → `/brainstorm` revisit of the specific section, then resume |
| **Config / prereq missing** | "no `eval.runner`", missing env var, unapplied migration | the one-line setup command, then resume |
| **Abandoned** | work landed outside the pipeline (`base_commit` ancestor of HEAD, tree clean) | close the envelope (`/status --prune-stale`) |

**Step 2 — recommend ONE action** in the same output shape as `/next` (one command, one
rationale, ≤2 alternatives). Where the class is "real code defect", *draft* the fix — the same
discipline the gotcha flywheel uses (auto-draft + one-tap confirm, never make the user
compose) — as either a ready-to-run `/task <drafted description>` or an inline fix spec.

**Step 3 — hand back an executable re-entry.** This is where the dependency bites:

> **Prerequisite: Phase 1B `--resume`** (`docs/PHASE-1-STATE-ENVELOPE.md`, deferred). Without
> it, every triage recommendation ends in "…then re-run `/sdlc <plan>` from Stage 1," which
> re-spends Stages 1–3 and — per `skills/sdlc/SKILL.md`'s own state-envelope section —
> *overwrites* the very evidence triage just read. 1B was specced in full (skip stages whose
> sidecar shows `pass`, resume from the first non-passing one, `prompt_hash` staleness rule).
> Shipping it is the single biggest enabler of the red-path loop and needs no new design work.

## Relationship to `docs/REVIEW-FIX-STAGE.md` (don't build this twice)

The Review→Fix design (Stage 5.7/5.8) is the **green-path** recommender: adversarial review of
a diff that passed everything, with a finding schema, an `auto_fixable` rubric, a verify pass,
and a bounded fix loop. `/triage` is the **red-path** recommender and should *reuse its
vocabulary rather than invent a parallel one*:

- A triage recommendation is a `REVIEW_FINDING_SCHEMA`-shaped object (`severity, file, line,
  defect, failure_scenario, fix`) sourced from sidecar evidence instead of a reviewer lens.
- The `auto_fixable` rubric transfers verbatim: "plan is wrong" and anything touching a
  user-observable default is a design decision → surfaced, never auto-fixed; a concrete
  reproducible failure with an explicit contract (the failing eval IS the contract) is
  auto-fixable.
- The "fix specs route through a gated fix loop with its own budget" pattern transfers too —
  but for triage v1, *recommend-only* is enough value; the fix loop is the v2 opt-up.

Two differences worth keeping: triage runs **on demand against a paused envelope** (not as a
pipeline stage), and it needs **no independent reviewer model** — it is reading objective
failure evidence, not adversarially second-guessing green code. Session model / Sonnet-tier is
right; the model-cap contract applies.

## Wiring into the loop

- `/next` ladder rung 1 routes paused runs here (`01-CONDUCTOR-AGENT.md`).
- The pause messages themselves should change from "Fix manually, then re-run `/sdlc {plan}`"
  to "Run `/triage <slug>` for a diagnosis, or fix manually and `/sdlc {plan} --resume`" —
  a one-line prose edit in `/sdlc` + `/sdlc-lite` + both overlays once the skill exists
  (three-way-sync contract applies).
- A `/triage`-drafted `/task` lands as a normal TASKS.md row, which means the backlog driver
  (`04-BACKLOG-LOOP.md`) picks it up — this is how a failure becomes a loop iteration instead
  of a dead end.

## Smallest useful increment

If a full skill is too much to start: add a **"Diagnosis" block to the existing pause
messages** — the failing stage's sidecar summarized into class + one recommended command,
inline, no new skill, no new agent. ~20 lines of prose per pipeline skill. It captures ~60% of
the value and derisks the eventual skill's decision table with real usage.
