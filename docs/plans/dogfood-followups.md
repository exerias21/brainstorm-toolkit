## Brainstorm Result: Dogfood follow-ups — the pipeline's own state stores, reconciled

> **Revision 2.** Revision 1 was stress-tested by a fresh-context Opus validator and rated **not safe
> to run**: its new cross-store check was mostly noise on real data and missed the incident it was
> built for, and its new `_manual_` tag leaked through three code paths. Corrections are recorded in
> *Appendix: What revision 1 got wrong*.

### Direction

Running `/sdlc` and `/flowsim` on this repo, with an observer agent watching, surfaced nine gaps. Most
share one shape: **two of the pipeline's state stores describe the same fact and nothing checks they
agree** — rows stayed open after their work shipped, so the Stage 0 scope gate (which trusts
`TASKS.md`) nearly re-ran finished work; a plan's `#### Phase` headings disagreed with its rows'
`_phase:` tags; `/flowsim` reads a cache no step writes; `/brainstorm` saves plans to a folder this
repo gitignores; the scope gate is undefined for a plan with zero rows and takes rows only a human
can do; and skill-repo `/sdlc` runs silently skip the plan check.

This plan fixes the nine **and makes cross-store drift loud** — but by extending the reconciler this
repo already has, not by inventing a new balance check. `scripts/close-tasks.sh reconcile` already
reports `terminal_envelope_open_rows`; it is noisy only because it does not know which phases a run
took (run today, it flags `flow-gap-fixes`' two legitimately-parked Phase 5 rows). Teach it phases,
and it catches the real case with no noise. That is the cross-domain lens's "trial balance" idea
(double-entry books must balance at close), applied to the machinery that exists.

**One limit, stated plainly:** the incident that motivated this — ten rows left open after
`f739a5e` — happened because that work was done **outside** the pipeline, so no envelope recorded it.
No deterministic check over envelopes can see work that never had one. Catching that needs a claim-vs-
commit judgement: the Jev plan's Phase 9 ("delivered but still open"). This plan does not pretend
otherwise.

Owner decisions: **plans in a skill repo go to `docs/plans/`**; **skill-repo `/sdlc` runs get the
plan-conformance axis back**; **human-only rows carry a `_manual_` tag**.

### Conventions & reuse

- **Extend `close-tasks.sh reconcile`** (`terminal_envelope_open_rows`, `scripts/close-tasks.sh:625-638`)
  rather than adding a parallel balance check. It already exempts `_followup_` rows (`FOLLOWUP_RE`,
  `:166`); `_manual_` joins that exemption.
- **Follow "gate in the skill, body in the template."** The scope gate's body is written out three
  times (canonical `skills/sdlc/SKILL.md:145-177`, Copilot `:118-133`, Codex `:117-132`) and has
  already drifted — the overlays' verdict line drops `(deferred: [...])`. One template fixes both.
  **The pointer must be backticked** — `**Read \`skills/sdlc/templates/scope-gate.md\` now**`, the
  form at `skills/sdlc/SKILL.md:41` — or neither `validate_skills.py` (`CROSS_TEMPLATE_REF_RE`) nor
  `check_install_refs.py` can see it.
- **Reuse the skill-repo detection idiom** (`skills/sdlc/SKILL.md:192`) for `/brainstorm`.
- **Reuse `stage-5-validate.md`'s plan axis as written** — including each runtime's delta (Claude
  dispatches the `plan-conformance-validator` agent; the overlays run it as one inline pass,
  `copilot/skills/sdlc/SKILL.md:198-203`). Point at it; do not re-specify a dispatch.
- **Reuse `scripts/ci/test-hooks.sh`** — the "deterministic controls" harness — for `close-tasks.sh`
  cases. `close-tasks.sh` currently has **no CI coverage at all**; this plan adds its first.
- **New (justified): `skills/sdlc/templates/scope-gate.md`**, and `run.json.data.scope_gate.taken_phases`
  (an integer list, accumulated across runs). Name the template in `CLAUDE.md` + `AGENTS.md`'s
  canonical-template list (byte-identical). Nothing enforces that list, so check it by hand.

### Implementation Steps

#### Phase 1 — skill-repo plan check, adoption ownership, tag docs

1. **Skill-repo mode keeps the plan check.** `skills/sdlc/templates/stage-5-skill-repo.md:3-5` says it
   replaces *"the standard Stage 5 (full test suite) and Stage 5's plan-vs-diff check."* Replace only
   the test half: keep every structural HARD/SOFT check **and** run `stage-5-validate.md`'s plan axis
   (§2) whenever there is a plan target, with each runtime keeping its existing delta. **State the
   gating rule explicitly:** the requirements axis gates as it does elsewhere; the flow axis stays
   advisory, because skill-repo mode has no test evidence to witness it (`stage-5-validate.md:68-76`),
   and structural checks are not flow evidence. Results go in `validate.json` beside
   `data.mode = "skill-repo"`. Update the skill-repo table in all three `/sdlc` legs. **Stage 1.5
   auto-patch:** the documented skill-repo `validate` data shape (`state-schema.md:246-261`) has only
   `checks` / `soft_checks`; add the plan-axis fields the standard shape already uses —
   `requirements[]`, `flow[]`, `flow_witnessed` — so the new axis writes documented fields. Files:
   `skills/sdlc/templates/stage-5-skill-repo.md`, `skills/sdlc/templates/state-schema.md`,
   `skills/sdlc/SKILL.md`, `copilot/skills/sdlc/SKILL.md`, `codex/skills/sdlc/SKILL.md`.
2. **Who owns `run.json.pipeline` when `/sdlc` adopts `/task`'s envelope.** `state-schema.md:85`
   defines `pipeline` as *"which skill wrote this run"* and is silent on adoption. Rule: `/sdlc` sets
   `pipeline: "sdlc"` and records additive `data.adopted_from: "task"`. Note one consequence in one
   sentence: `protect-tests.sh`'s no-`--slug` fallback prefers `pipeline == "task"` (`:169`), so an
   adopted envelope drops out of that preference — low risk, since `/task` always passes `--slug`.
   Files: `skills/sdlc/templates/state-schema.md`, the three `/sdlc` legs (Stage 0 case 4).
3. **Document both row tags** — `_followup_` (undocumented today) and the new `_manual_` — in
   `templates/TASKS.md.template`'s conventions block, **including that tags live in the trailer after
   the last ` — `**. Files: `templates/TASKS.md.template`.
4. **Version bump 0.9.0 → 0.10.0.** Files: `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`.

#### Phase 2 — the scope gate, `_manual_` everywhere, and a phase-aware reconciler

5. **Move the scope gate's body into `skills/sdlc/templates/scope-gate.md`** (backticked pointer in
   each leg; the canonical verdict line, `(deferred: [...])` included, becomes the one version). Add:
   - **Zero rows.** Fall back to the plan's `#### Phase N` headings — lowest phase not marked
     `DEFERRED` or `EXTERNAL` — and say in the verdict that rows were absent.
   - **`_manual_` rows** are never taken or marked `[~]`; the verdict lists them as
     `needs you: <titles>`; a phase whose only open rows are `_manual_` is reported, not taken.
   - **Record `run.json.data.scope_gate.taken_phases: [int]`** alongside the existing free-text
     `taken`. **Accumulate it:** a re-run of `/sdlc <plan>` reuses the slug and overwrites the
     envelope (the `flow-gap-fixes` Phase 2 envelope is already gone), so union with the prior value
     before writing.
   Files: `skills/sdlc/templates/scope-gate.md` (new), the three `/sdlc` legs, `CLAUDE.md`, `AGENTS.md`.
6. **`_manual_` in every row selector, matched only in the tag trailer.** Revision 1 fixed only the
   scope gate; the tag leaks through three more paths:
   - `skills/sdlc/templates/queue-mode.md` Select (`:18-19`) picks "the highest-priority
     Active/Pending row" — a P1 `_manual_` row would be chosen first. Exclude it (one edit; the
     overlays point at the template).
   - `/sdlc` Stage 0 case 3 (task range) marks every resolved row `[~]` — skip `_manual_` there too,
     in all three legs.
   - `scripts/close-tasks.sh`: `reconcile` must exempt `_manual_` exactly as it exempts
     `_followup_`; `board` must strip it from titles (`BARE_TAG_STRIP_RE`, `:173`) and expose a
     boolean `manual` field (documented in `docs/BOARD-JSON.md`; additive, no `schema` bump).
   - **Trailer-only matching.** `FOLLOWUP_RE`, `PHASE_RE` and `PLAN_TAG_RE` all match the whole line
     today — the very ambiguity found while authoring this plan (three of its own rows mention
     `_manual_` in their titles). Match `_manual_` only after the last ` — `; apply the same rule to
     `_followup_` while there.
   Files: `skills/sdlc/templates/queue-mode.md`, the three `/sdlc` legs, `scripts/close-tasks.sh`,
   `docs/BOARD-JSON.md`.
7. **Make `reconcile` phase-aware** — the actual cross-store check. Warn only when a **terminal**
   envelope's `taken_phases` covers phase P **and** P still has `[ ]`/`[~]` rows that are neither
   `_followup_` nor `_manual_`. Envelopes with no `taken_phases` (every run before this change) keep
   today's behaviour. Add one zero-noise structural check: any row's `_phase: N_` with no
   `#### Phase N` heading in its plan (it would catch `flow-gap-fixes`' `_phase: 4_` row, whose phase
   is headed `#### Deferred`). The scope gate runs `reconcile` scoped to the plan before taking,
   **warn-only**, and prints its findings in the verdict — pushing back visibly, then proceeding.
   Files: `scripts/close-tasks.sh`, `skills/sdlc/templates/scope-gate.md`.
8. **First CI coverage for `close-tasks.sh`**, in `scripts/ci/test-hooks.sh`: trailer-only tag
   matching (a title that *mentions* `_manual_` is not a manual row); `reconcile` exempts
   `_manual_` / `_followup_`; phase-aware `reconcile` stays silent on a legitimately-parked later
   phase and fires on an open row inside a taken phase; `board` strips the tag and sets `manual`.
   Files: `scripts/ci/test-hooks.sh`.
9. **Version bump.** Files: `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`.

#### Phase 3 — lint and skill fixes

10. **`check_contracts.py` check `portable-invocation`**, per `docs/plans/windows-portability-and-hygiene.md`
    step 5 (`:95-101`) — noting two stale details in that spec: it calls this "check 7" (check 7 is now
    `no-cardinality`; this will be the tenth) and cites "the existing five checks" (`run_all` registers
    nine). (a) No bare `python3 ` in `scope_files()` (probe idiom and prose *about* it exempt via the
    existing allowlist convention); (b) every `hooks/hooks.json` command starts with an interpreter
    token. `--self-test` case seeded with one violation of each. Files: `scripts/ci/check_contracts.py`.
11. **The citation check sees `bash scripts/…` citations.** Widen `CITATION_RE` (`:378-381`) to accept
    an optional `bash `/`sh `/`python3? `/`py ` prefix, an optional `scripts/py.sh `, and arguments
    before the closing backtick. **Measured by the validator:** 28 new citations get checked; exactly
    **one** fails — `docs/JEV.md:55` `` `bash scripts/jev-key.sh set` ``, a planned script cited on
    purpose. Reword that sentence (describe the command without the path form) rather than allowlist
    a path that does not exist. `CITATION_RE` also feeds the historical-doc pointer check (`:695`);
    widening only makes that more lenient. Negative test required. Files:
    `scripts/ci/check_contracts.py`, `docs/JEV.md`.
12. **`/flowsim` writes the cache its step 0 reads** (`plans/flowsim-<slug>.json`, the file
    `state-schema.md:282` already calls its canonical output): the flows array plus `written_at`,
    creating `plans/` if missing. Reword its "Flowsim is read-only" rule to "never edits source" —
    it now writes one file of its own. One leg; no overlays. Files: `skills/flowsim/SKILL.md`.
13. **`/brainstorm` writes `docs/plans/<topic-slug>.md` in a skill repo**, detected as `/sdlc` does,
    and uses that path in the rows, the sentinel and the hand-off lines; elsewhere unchanged. Tell
    Step 6 to tag human-only rows `_manual_` in the trailer. **Two legs** (canonical: 8 body sites —
    `:192, 195, 200, 209, 270, 295, 315, 318` — leaving the description and the `~/.claude/plans`
    mention alone; Copilot: 7 — `:167, 169, 171, 184, 224, 229, 235`); Codex falls through to
    Copilot's overlay (`setup.sh:213-219`). Edit each site by hand. **Knock-ons in the same step:**
    `scripts/hooks/next-action.sh:178` scans only `plans/brainstorm-*.md`, so extend the pending-plan
    nudge to `docs/plans/*.md` in a skill repo; `/plan-html` would write a *tracked*
    `docs/plans/<slug>.html` beside the plan — add `docs/plans/*.html` to this repo's `.gitignore`;
    `state-schema.md:281` ("Plan files stay in `plans/`") gains the skill-repo location; refresh
    `docs/plans/README.md`'s index (it lists 5 of 11 plans). Files: `skills/brainstorm/SKILL.md`,
    `copilot/skills/brainstorm/SKILL.md`, `scripts/hooks/next-action.sh`, `.gitignore`,
    `skills/sdlc/templates/state-schema.md`, `docs/plans/README.md`.
14. **Version bump.** Files: `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`.

*(Backlog hygiene done at authoring time: three stale rows closed with evidence; the conflicting
"docs/plans is the wrong home" row closed as decided; the `portable-invocation` row and the duplicate
`/brainstorm` skill-repo-detection row retagged to this plan; the two human-verification rows in
`windows-portability-and-hygiene` tagged `_manual_`.)*

### Cross-Module Touchpoints

- **`/sdlc`** — skill-repo Stage 5 regains the plan axis; the scope gate moves to a template, records
  `taken_phases`, handles zero rows and `_manual_`, and runs a warn-only reconcile; case 3 skips
  `_manual_`; case 4 states adoption ownership. Three legs each.
- **`scripts/close-tasks.sh`** — `reconcile` gains phase awareness and the `_manual_` exemption;
  `board` gains a `manual` field; trailer-only tag matching. First CI coverage.
- **`/brainstorm`**, **`/flowsim`**, **`next-action.sh`** — plan location and its knock-ons; the flowsim cache.
- **`check_contracts.py`** — `portable-invocation`, widened citations.
- **Consumers** — `_manual_` and `_followup_` documented in `TASKS.md.template`; the `board` field is
  additive. No new `project.json` keys.

### Open Questions

- **Structural checks vs flow evidence (step 1).** Structural HARD checks do not witness a flow, so
  in skill-repo mode the flow axis stays advisory. If that proves too weak — the defect `/flowsim`
  caught on 2026-09-19 would still only warn — revisit with evidence rather than guessing now.
- **Work done outside the pipeline** stays invisible to any envelope-based check (see Direction). The
  Jev plan's Phase 9 is where that belongs.
- **`docs/plans/` as the long-term home was contested** by an older row; the owner chose it.

### Appendix: Alternatives Considered

- **A. One phased plan split by file ownership** — **chosen**, now three phases after validation.
- **B. Two plans (contract vs lint)** — not chosen; the scope gate already splits phases.
- **C. Only the four one-liners** — not chosen; leaves the gaps that caused today's detours.
- **Wildcard — First Principles, "Ledger-and-mirrors":** `TASKS.md` as the only hand-written store.
  Not chosen: it crowns the store that drifted worst, and it is gitignored here.
- **Wildcard — Inversion, "Single-source kill switch":** delete other stores; hard-stop on undefined
  scope. Not chosen: a hard stop deadlocks CI. Its "delete the dead cache read" was weighed for step 12
  and rejected because `state-schema.md` names the file as `/flowsim`'s canonical output.
- **Wildcard — Cross-Domain, "Trial balance gate":** **adopted in spirit** — as a phase-aware
  `reconcile`, not the step-count comparison revision 1 invented.
- **Wildcard — Constraint Removal, "invariant checker":** half adopted — steps 10–11 cover committed
  prose; the local-store half runs at Stage 0, since `TASKS.md` and `.claude/pipeline/` never reach CI.

### Appendix: What revision 1 got wrong

1. **Its cross-store check was noise.** "Open-row count disagrees with step count" fired on three
   *finished* phases of `flow-gap-fixes` and on eight `jev-integration` phases (one of which that plan
   says must get no rows) — and **stayed silent** on the ten delivered-but-open rows, which balanced
   perfectly. Rows and steps are not 1:1 by `/brainstorm`'s own contract. Replaced by a phase-aware
   `reconcile` (step 7) plus a zero-noise heading/tag check.
2. **`_manual_` leaked** through `--queue` Select, the task-range path, `reconcile` (drift) and `board`
   (titles). Step 6 covers all four.
3. **Its test step targeted nothing** — "add a case to whatever tests the gate's row parsing": nothing
   does. Step 8 adds `close-tasks.sh`'s first CI coverage.
4. **The template pointer was unbackticked**, invisible to both reference checks.
5. **Step 1 over-specified a dispatch** the overlays do inline, and left gating ambiguous.
6. **It missed the knock-ons of moving plans** (`next-action.sh`'s nudge, a tracked `.html`, a stale
   schema line and index) and a duplicate backlog row.
7. **Phase 1 was too big** for one session once those were added; it is now three phases.
