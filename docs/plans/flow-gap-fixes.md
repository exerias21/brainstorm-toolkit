## Brainstorm Result: Flow-gap fixes and the drift-prevention layer

> **Revision 2.** Revision 1 was stress-tested by a fresh-context Opus validation agent which
> **refuted five load-bearing claims** and rated it unsafe to execute. Every correction below is
> evidence-backed and is recorded in *Appendix: What revision 1 got wrong*, because two of the
> errors were of a kind this repo keeps repeating — describing a mechanism without reading it.

### Direction

An 8-agent review found 16 code/contract gaps. This plan takes the **5 HIGH bugs**, two
**explicitly elected MEDIUMs** (G7; G9+G10 as one problem), the **two macOS portability bugs**,
and a **drift-prevention layer** — because the review found the mechanical cause of much of the
doc rot: `scripts/ci/check_contracts.py` lints the skill trees but **not `CLAUDE.md` and not
`docs/*.md`**, so those files have never been checked by anything.

**The prevention layer is worth doing and is not the headline.** Revision 1 called widening the
lint scope "the single highest-leverage change"; that was measured and is false. Running the
existing citation check over `CLAUDE.md`, `AGENTS.md` and all 14 `docs/*.md` yields **14
findings, all 14 inside the two files already marked `⚠ Historical design record`** — and **none
of the three defects revision 1 cited as motivation would have been caught**: `docs/FLOW.md`'s
stale "planned" claim used a path that resolved fine, `docs/CONVENTIONS.md`'s deleted-script
claim named a bare `.js` file that the citation regex cannot match by construction, and
`CLAUDE.md`'s missing template names were an *omission*, which a check on cited paths can never
detect. The widening is cheap hygiene with a real but modest payoff. Claiming more than that is
the same overconfidence the review exists to correct.

What *does* carry weight is the prevention layer's second half. Three of four ideation lenses
independently refused the "add more checks" framing, arguing **a check verifies a lie after it
is told; deleting the restatement makes the lie unsayable.** That principle survives; its naive
implementation did not (see step 4). The one mechanism that addresses the most expensive defect
class found — claims about the **outside world** — is the `recheck-by` pin. `docs/MODEL-AXES.md`
asserted a Codex bug was live for ~2 months after upstream fixed it, and that stale premise had
propagated into a *shipped* template. Nothing locally-derived catches that, because nothing
local changed.

**Phases 1 and 2–3 should ship as separate PRs**, for a mechanical reason rather than a
stylistic one: **Phase 1 touches no shipped content at all.** `SHIPPED_GLOBS` is
`("skills","agents","copilot","codex","templates","scripts")` with `scripts/ci` excluded, so
Phase 1's files (`scripts/ci/`, `CLAUDE.md`, `AGENTS.md`, `README.md`, `docs/**`) need no version
bump and cannot break a consumer. Phases 2–3 touch `scripts/hooks/`, `skills/`, `copilot/`,
`codex/` — all shipped, all cache-keyed on version. That boundary is real; revision 1 rejected
it on the weaker ground that "prevention gets deferred."

### Conventions & reuse

- **Reuse:** `scripts/py.sh` — *the* canonical interpreter resolver, whose own header says
  *"One resolver, cited from everywhere, is the fix — not 14 copies of a probe."* Step 6 must
  source it or match its full contract (`$BRAINSTORM_PYTHON` → `project.json` `python` → probe
  `python3 python py`). **Do not copy `enforce-model-cap.sh:29`** — it is the odd one out, probing
  only `python3 python`, and the `python` config key landed in `1802fd7`.
- **Reuse:** `CITATION_ALLOWLIST` (`check_contracts.py:266-272`), an existing
  `{(file, ref): reason}` dict — the shape any new check's exemptions copy.
- **Reuse:** `_exclude_fixtures()` / `FIXTURE_EXCLUDE_PREFIX` (`check_contracts.py:60-84`) — the
  existing structural-exclusion helper. New path exclusions extend it rather than inlining a filter.
- **Reuse:** `model_cap_pointer_warnings()` (`validate_skills.py:328-346`) — explicitly *"a soft
  warning, not a validation failure."* It is the precedent for both step 3's warn-only posture and
  step 8's new check.
- **Reuse:** the pinned-count allowlist idiom from `5232045` (`path/glob:N`, bare = 1). A bare
  allowlist grants permanent immunity; a pinned count reports an excess *and* a stale pin.
- **Reuse:** `docs/FLOW.md:105` already models the exact shape step 2 generalises — a historical
  marker *plus a pointer to the live contract that superseded it.*
- **Reuse:** `scripts/ci/test-hooks.sh` as the one harness for deterministic controls, and
  `check_contracts.py --self-test` for new checks. Every new check lands with its fixture in the
  same commit.
- **New (justified):** `<!-- assert-manual: recheck-by YYYY-MM-DD "<claim>" -->`, because nothing
  in the repo can express "this claim is about something outside this repo and will go stale with
  no local edit." The only genuinely new artifact here.
- **Doc drift (already fixed, uncommitted — do not re-fix):** the 21-item docs sweep and the flat
  500-line ceiling have landed. `CLAUDE.md`/`AGENTS.md` byte-identical; `models.md`'s Codex claim
  corrected. **The tree already carries a 0.7.0 → 0.7.1 bump** — step 14 must not double-bump.

### Implementation Steps

#### Phase 1 — prevention (no shipped content; ships as its own PR)

1. **Mark every `docs/*.md` as `live contract` or `historical record` — and do it FIRST.**
   Revision 1 ordered this fourth, which would have landed step 2 red: all 14 findings the
   widened citation scope produces are inside `REVIEW-FIX-STAGE.md` and
   `PHASE-1-STATE-ENVELOPE.md`, and this step is what exempts them. Historical files are exempt
   from the content checks below — an amending instrument is never re-verified, only the
   consolidated text is.
   **Close the loophole in the same step**, because exempting-by-marker is otherwise a one-line
   silencer for any check: (a) a `historical record` marker MUST carry a pointer to the live
   contract that superseded it, and the lint must require that pointer to resolve —
   `docs/FLOW.md:105` already models this; (b) pin the *count* of historical files using the
   `path/glob:N` idiom, so adding one is a visible, reviewed diff rather than a silent exemption.
   Files: every `docs/*.md`, `scripts/ci/check_contracts.py`.

2. **Widen the lint scope — and widen the RIGHT functions.** Revision 1 widened only
   `citation_scope_files()`. But `run_all()` (`:612-627`) shows **`forbidden-phrases` and
   `collapsed-pairs` consume `scope_files()`**, and *forbidden-phrases is the one mechanism that
   could actually have caught the `docs/CONVENTIONS.md` Workflow claim*, since
   `sdlc-pipeline.workflow.js` is exactly a rename-invalidated phrase. So widen **both**
   `scope_files()` and `citation_scope_files()` to cover `CLAUDE.md`, `AGENTS.md` and
   `docs/*.md`. This matters immediately: steps 3, 4 and 12 rewrite prose across ~20 files, which
   is the shape that has corrupted this repo six times, and `COLLAPSED_PAIR_RE` does not cover
   these files today. Decide `glob` vs `rglob` explicitly — with non-recursive `docs/*.md` the
   `docs/plans/**`, `docs/archive/**`, `docs/gap-analysis/**` exclusions are dead code; with
   `rglob` they are required.
   **Measured before/after (Stage 1.5): widening produces exactly ONE finding, not a wall.**
   Running the real `check_forbidden_phrases` and `check_collapsed_pairs` over
   `CLAUDE.md` + `AGENTS.md` + `docs/*.md` gives `forbidden-phrases: 0` and
   `collapsed-pairs: 1` — `docs/LOOP-HYGIENE.md:89`, ``same command named twice: `/compact` ``.
   **Fix that one site in this step** so the widening lands green. (An earlier estimate of ~50
   findings simulated over `TASKS.md`, `GOTCHAS.md` and `README.md`, none of which this step
   adds to scope.) Files: `scripts/ci/check_contracts.py`, `docs/LOOP-HYGIENE.md`.

3. **Add the `recheck-by` pin as a permanent WARN, not a failure.** Support
   `<!-- assert-manual: recheck-by YYYY-MM-DD "<claim>" -->`; parse, compare to today, report
   expired pins naming the claim. **Warn-only permanently** — revision 1 hedged this as "at
   first"; commit to it. Three grounded reasons: `check_contracts.py` exits 1 on any finding and
   runs in `setup-roundtrip`, so a date-triggered failure is indistinguishable from a real
   contract break and trains people to ignore both; `model_cap_pointer_warnings()` is this repo's
   own precedent for exactly this; and a stale external claim is never urgent *on the day it
   expires*, so blocking a PR buys nothing. Additionally surface expired pins in
   `/repo-health`'s gotchas-currency sweep, where a periodic due-list actually belongs.
   Then **pin the claims that already burned us**: the Codex subagent-model behavior in
   `docs/MODEL-AXES.md` and `skills/sdlc/templates/models.md`, the Copilot/Codex frontmatter
   leniency in `CLAUDE.md` rule 10, and the Codex discovery-cap figures. Dates ~6 months out.
   **Phase-1 scope correction (Stage 1.5 auto-patch):** the two `skills/**` pin sites —
   `skills/sdlc/templates/models.md` and `skills/repo-health/SKILL.md` — are under
   `SHIPPED_GLOBS` and would break this phase's "touches nothing shipped" property, which is the
   whole reason it ships as its own PR. **Those two pins move to Phase 2**, which already edits
   shipped files and carries the version bump. Phase 1 pins only the unshipped sites.
   Files: `scripts/ci/check_contracts.py`, `docs/MODEL-AXES.md`, `CLAUDE.md`, `AGENTS.md`.
   *(Deferred to Phase 2: the `models.md` Codex pin and the `/repo-health` expired-pin due-list.)*

4. **`no-cardinality`: narrowed drastically, and paired with a consistency check.** Revision 1
   proposed banning derivable counts in prose. Measured, that pattern is **~11% precise**: the
   digit form `[0-9]+ (hooks|checks|skills|agents|lenses)` returns **7 hits in `CLAUDE.md` +
   `docs/*.md`, of which 0 are the defect**; widened to number-words it returns 28 hits of which
   **3** are real. It also has no fenced-code stripper to rely on (`check_contracts.py` has none),
   and it would flag `docs/CONVENTIONS.md:256` *"Six corruptions have shipped this way"* — a
   historical tally that is the whole point of the sentence.
   So scope it to **number-words only, for `{checks, hooks, skills, agents}` only, outside code
   fences, in `live contract` docs only** — which catches the 3 real sites at roughly 50%
   precision. Fix those 3 (`CLAUDE.md:359` and `docs/EVALS.md:15` "six checks", `CLAUDE.md:253`
   "five hooks"). Widen later on evidence, never on principle.
   **And add the check that actually fits the best site:** `README.md:159` *"It also wires five
   hooks"* is immediately followed by exactly five bullets. Deleting the number makes that
   sentence worse; a **header-count == list-length** consistency check is the right mechanism
   there. Files: `scripts/ci/check_contracts.py`, `CLAUDE.md`, `AGENTS.md`, `README.md`,
   `docs/EVALS.md`.

#### Phase 2 — the five HIGH bugs (shipped content; separate PR)

5. **Restore the missing template pointers in the Copilot and Codex `/sdlc` overlays — but not
   as one undifferentiated bug.** The counts are **8 and 9**, not 7 and 8: canonical − copilot =
   `changed-files-gate`, `resumption`, `stage-1.5-sanity-check`, `stage-2-implement`,
   `stage-2a-decompose`, `stage-2b-dispatch`, `stage-2c-converge`, `state-schema`; Codex misses
   those plus `envelope-staleness`. Revision 1 omitted `changed-files-gate` entirely.
   **Split them by judgment:** `stage-1.5-sanity-check`, `stage-2-implement`, `resumption`,
   `state-schema`, `changed-files-gate` are unambiguous — the overlay says "Run Stage 1.5 inline"
   and "Run `/sdlc` Stage 2 inline" with no body to read. But `copilot/skills/sdlc/SKILL.md:138`
   says **"This runtime has no sub-agent seam"**, which is a *real* reason `stage-2a/2b/2c` do
   not apply; those want an explicit "not applicable on this runtime" note, not a pointer. A
   check that warns on all 8 produces 3 permanent allowlist entries on day one.
   Files: `copilot/skills/sdlc/SKILL.md`, `codex/skills/sdlc/SKILL.md`.

6. **`next-action.sh`: use the canonical resolver, and stop eating the sentinel.** Replace the
   three bare `command -v python3` gates (`:74`, `:165`, `:185`) — it is the last script in the
   repo on that form — and **move `rm -f "$NEXT_ACTION_FILE"` (`:101`) inside the branch that
   actually parsed the file**; it currently sits outside the `if command -v python3` block that
   closes at `:100`, so on a Windows Store `python3` stub the handoff is deleted with zero
   output, on the one hook that closes the loop. **Source `scripts/py.sh` rather than inlining a
   10th copy of the probe** — `py.sh`'s own header names that as the anti-pattern.
   Test fixture is non-trivial and should be budgeted: it needs a scratch bin dir with a fake
   `python3` that resolves but exits nonzero, prepended to `PATH`, with `python` working. Assert
   `Next:` on stdout **and** that the sentinel survives when it cannot render.
   Files: `scripts/hooks/next-action.sh`, `scripts/ci/test-hooks.sh`.

7. **`run-cost-report.sh`: write cost to the newest terminal envelope.** The loop (`:135-147`,
   assignment at `:143`) reassigns on every unmarked terminal match with no recency comparison,
   so the alphabetically-last glob entry wins. Track max `updated_at` (ISO-8601 sorts lexically)
   and assign only on a beat. Cosmetic misattribution until Phase 1 of the previous plan made the
   numbers *persisted* state; now it is durable corruption, stamped fire-once via
   `.cost-reported`. Fixture needs **three** artifacts, not two: the hook exits at `:123` unless
   `transcript_path` is an existing JSONL file, so a synthetic transcript is required alongside
   the two crafted envelopes. Files: `scripts/hooks/run-cost-report.sh`, `scripts/ci/test-hooks.sh`.

8. **Add a cross-skill template-pointer check (a NEW check, not a tightening).** Revision 1 said
   step 5's gap was exempted by `validate_skills.py:309-312`'s "deliberate simplification"
   comment. It is not: `find_bundled_resource_refs()` (`:144-154`) matches only
   `TEMPLATE_REF_RE` — the *skill-local* `` `templates/<x>` `` form — while every dropped pointer
   is the *cross-skill* `` `skills/sdlc/templates/<x>.md` `` form, matched by
   `CROSS_TEMPLATE_REF_RE` (`:28-33`), which that block never calls; and `:314` resolves against
   `canonical_dir / "templates"`, where a cross-skill ref would not exist anyway. **The existing
   exemption never sees this shape.** So write a new soft check using `CROSS_TEMPLATE_REF_RE`,
   modelled on `model_cap_pointer_warnings()`. Leave the existing exemption alone — its rationale
   is sound for its own scope. Files: `scripts/validate_skills.py`.

9. **Make every stage advance `run.json` — from the orchestrator, not from sub-agent prompts.**
   Revision 1 named five templates; **two of them write nothing at all.**
   `stage-2-implement.md` (42 lines) and `stage-2c-converge.md` are *fenced prompts handed to a
   sub-agent* — they contain no `run.json`, no `stage-outputs`, no "State write". The orchestrator
   writes those sidecars, at `skills/sdlc/SKILL.md:209` and `:215-216`. Putting orchestrator state
   instructions inside a sub-agent's prompt would be a genuine defect, so **`skills/sdlc/SKILL.md`
   belongs in this step's file list and revision 1 omitted it.**
   Of the rest: `stage-1.5-sanity-check.md:47` and `stage-3-evals.md:48` have a `**State write**`
   line to extend; `stage-5-validate.md:93` says `**Writes**`, so there is no such line to append
   to — handle it explicitly.
   The underlying bug stands: `resumption.md:20-24` navigates by `stage` / `stages_completed` /
   `updated_at` and `state-schema.md:56,88` says they refresh every transition, but nothing does
   it, so an interrupted run sends `--resume` back to the start. Add the resume reconcile (rebuild
   from `stage-outputs/*.json` when `stages_completed` is shorter), which also repairs existing
   envelopes. Fix the `secret-scan` false equivalence at **both** sites — `resumption.md:22` and
   **`state-schema.md:88`**, a third site revision 1 missed — since `secret-scan.md:36` says
   "**No sidecar.**" by design.
   Files: `skills/sdlc/SKILL.md`, `stage-1.5-sanity-check.md`, `stage-3-evals.md`,
   `stage-5-validate.md`, `resumption.md`, `state-schema.md`.

10. **Narrow `setup.sh`'s seed-template rewrite.** The sed at **`:266-267`** (not `:262-265`)
    rewrites any backticked `` `templates/<x>.template` ``; `skills/plan-html/SKILL.md:109` is
    skill-local *and* a `.template`, so post-install it reads
    ``Read `.claude/templates/plan.html.template` (sibling of this SKILL.md)`` — a path that does
    not exist, in a sentence that now contradicts itself. **Reproduced** in a scratch install.
    It is the **only** such site (7 backticked `.template` refs; 6 are seed names), so the
    `AGENTS.md|TASKS.md|CHEATSHEET.md` alternation is a correct superset. Also fix why CI missed
    it: `check_install_refs.py:28-30`'s `REF_RE` puts the tool prefix *outside* the capture group
    and `resolve()` (`:36-45`) tries `skill_dir / ref` first, so the rewritten path re-resolves
    against the base the rewrite moved away from. Files: `setup.sh`, `scripts/ci/check_install_refs.py`.

*(Steps 10b–10e below were found during Phase 1 and delivered with Phase 2 in `f739a5e`.)*

10b. **Add a SCOPE GATE to `/sdlc` Stage 0 — push back on an oversized plan and take only what
    it can.** Today `/sdlc` has no such gate: Stage 0 resolves a plan file, marks *every* matching
    `Active / Pending` row `[~]`, and proceeds regardless of size. **This was observed live** —
    this very plan (15 steps, 4 phases, carrying its own embedded "Not one `/sdlc` session"
    verdict) was accepted whole and silently, and a human had to intervene to split it.

    **The repo already computes the signal and throws it away.** `skills/brainstorm/SKILL.md:252`
    prints `plan size: <n> steps across <m> files, <k> surface(s) — <one execution session |
    splittable>` at authoring time, and **nothing consumes it** — `grep` for `splittable` outside
    brainstorm's own `SKILL.md` returns nothing. So the fix is not a new heuristic; it is giving
    the existing one a reader.

    **And the park machinery already exists too.** `skills/sdlc/templates/queue-mode.md:39-52`
    carries stop conditions, the park protocol, `status: "paused"`, the mandatory
    `.claude/.next-action` sentinel and the resume line — but it is reachable only via `--queue`.
    The scope gate reuses that protocol rather than inventing a second one.

    Behavior to implement, in Stage 0 immediately after `parse.json` is written:
    - Compute plan size from `parse.json` (`implementation_step_count`, `files_to_change`,
      surfaces via `changed-files-gate.md`) — the same quantities brainstorm already uses.
    - **Prefer the plan's own `#### Phase N` boundaries over an arbitrary cut.** If the plan
      declares phases, take the lowest phase with open rows and park the rest. Only fall back to
      a step-count cut when a plan has no phases. **Never split a sequentially-dependent chain to
      hit a number** — that trades real working context for a metric, and `/brainstorm` Step 7.5
      already states this rule; restate the pointer, not the rule.
    - **Honor an explicit DEFERRED marker.** This plan's Phase 4 says it cannot be verified on
      this machine; Stage 0 marked its row `[~]`-free only because a human read that. A phase the
      plan itself defers must never be pulled into scope.
    - **Push back visibly, then proceed** — do not stop and ask. Print the taken/parked split as a
      gate verdict (always printed, even under `quiet`), record `run.json.data.scope_gate`
      (`{plan_total_steps, plan_phases, taken, parked, deferred, why, resume}`), mark `[~]` only on
      the rows actually taken, and drop the `.next-action` sentinel naming the resume command.
      Silence here is the whole defect: a gate that decides quietly is indistinguishable from no
      gate.
    - **Threshold config:** `pipeline.scope.max_steps_per_run` (suggest default 8, the point past
      which this plan's own validator called a run oversized), `--no-scope-gate` to force whole-plan
      execution. Any config key added here must also land in `templates/project.json.example` and
      `docs/CONFIG.md` or `check_contracts.py`'s config-keys check will fail it.
    - **Two-leg edit:** canonical prose plus the Copilot and Codex `/sdlc` overlays. Coordinate
      with step 5, which is already editing both overlays — do them in one pass, not two.

    Files: `skills/sdlc/SKILL.md`, `skills/sdlc/templates/queue-mode.md` (extract the park
    protocol so both callers share it), `copilot/skills/sdlc/SKILL.md`,
    `codex/skills/sdlc/SKILL.md`, `templates/project.json.example`, `docs/CONFIG.md`.

10c. **Repair the `.next-action` seam — it is dead in this repo right now.** Found by the
    pipeline-observer audit of the Phase-1 run, not by any review lens. Two coupled defects:
    - **The contract contradicts itself.** `docs/SEAM.md:37` heads the rule **"Dedup by `cmd`"**
      and then specifies *"append only if that exact **line** isn't already present."* Those are
      different keys. Two writers proposing the same command with different `source` values both
      append, so the file grows duplicates that dedup was supposed to prevent. Pick `cmd` (the
      heading is right — the command is the action; `source` is provenance) and make the mechanism
      match.
    - **Which parks the whole seam.** `docs/SEAM.md:128`: *"if more than one line is pending, the
      hook parks (prints)."* With duplicates accumulating, the file reached **5 pending lines** and
      no `Next:` could fire at all. The loop-closing mechanism was non-functional and **nothing
      reported that** — the failure is silent by construction, because a parked hook looks exactly
      like a hook with nothing to say.
    Add: dedup on `cmd`; drop an entry whose plan/target no longer exists or is already delivered;
    and surface depth (`⚠ N actions pending — seam parked`) so a parked seam announces itself.
    Files: `scripts/hooks/next-action.sh`, `docs/SEAM.md`, `scripts/ci/test-hooks.sh`.

10d. **Reconcile must not rebuild `stages_completed` from sidecars alone.** Step 9 proposes
    "rebuild from `stage-outputs/*.json` when `stages_completed` is shorter." The observer measured
    the terminal envelope at **6 entries against 5 sidecars** — legitimately, because
    `secret-scan.md:36` says *"**No sidecar.**"* by design. A naive rebuild silently **drops
    `secret-scan`**, which is the same false equivalence step 9 already fixes in `resumption.md:22`
    and `state-schema.md:88` — reintroduced by step 9's own repair. Reconcile must union the
    sidecar-derived set with the sidecar-less stages, not replace it.
    Files: `skills/sdlc/templates/resumption.md`.

10e. **Fix the skill-repo Stage 5.7 gating contradiction.** `skills/sdlc/SKILL.md:242-244` says
    review is *"Opt-in, permanently OFF by default"*; the skill-repo substitution table at `:300`
    says Stage 5.7 is *"**adapt, never self-skip**"* — stated unconditionally, in a table whose
    other rows say "skip". This run resolved it correctly (review skipped, template never loaded),
    but the table row is a plausible misread that would turn a default-off stage on for every
    skill repo. Reword the row to "adapt **when enabled**, never self-skip".
    Files: `skills/sdlc/SKILL.md`, `copilot/skills/sdlc/SKILL.md`, `codex/skills/sdlc/SKILL.md`.

#### Phase 3 — elected MEDIUMs + the decompose-gate fix

11. **Give pipeline envelopes explicit addressing (G9 + G10, one problem).** `protect-tests.sh`
    `find_envelope()` (`:113-133`) takes the **last** sorted match; `stop-gate.sh:125-131` breaks
    on the **first**. With any other run open the detector arms and verifies a *foreign* envelope
    and reports clean — it **fails open exactly when the repo is busiest**. Add `--slug` to
    `arm|verify|disarm`; `/task` passes its own (`skills/task/SKILL.md:85`, `:98` pass none
    today). Fallback: prefer `pipeline == "task"`, tie-break newest `started_at` — the same
    recency rule as step 7. Delete the `find_envelope` docstring's *"Mirrors run-cost-report.sh's
    scan"*: that scan is step 7's bug. Files: `scripts/protect-tests.sh`, `skills/task/SKILL.md`,
    `scripts/ci/test-hooks.sh`.

12. **Stop `/sdlc`'s ad-hoc path orphaning a second envelope.** Stage 0 case 4 routes through
    `/task` Sections 1–2, whose step 5 (`skills/task/SKILL.md:32-34`) writes
    `.claude/pipeline/task-<N>-<slug>/run.json` at `in_progress`; `/sdlc` owns a different
    directory and terminalizes only its own. The orphan then feeds `next-action.sh`'s stale-run
    warning on every Stop and makes `stop-gate.sh` re-run the unit suite indefinitely under
    `pipeline.stop_gate: "tests"`. Reuse `task-<N>-<slug>` as the run slug, as `queue-mode.md:25`
    already does. **Three-leg edit** (Stage 1.5 auto-patch): both overlays carry their own ad-hoc
    line (`copilot/skills/sdlc/SKILL.md:76`, `codex/skills/sdlc/SKILL.md:75`). Files:
    `skills/sdlc/SKILL.md`, `copilot/skills/sdlc/SKILL.md`, `codex/skills/sdlc/SKILL.md`.

13. **Fix the plugin-only install trap (G7) — document *and* repair.** `README.md:117-125`
    Option A never mentions `setup.sh`, so a plugin-only user never receives `scripts/`:
    close-out reports `tasks: 0 closed` forever, rows stay `[~]`, no decisions recorded, detector
    never arms — and the Stage 6 caveat makes the model report it *politely*. **This run takes the
    documentation half only** (Stage 1.5 auto-patch — see step 16 for why): (a) README Option A
    states you still run `bash <plugin>/setup.sh --target . --tools claude --no-hooks` to get
    `scripts/`; (b) broaden the `stage-6-handoff.md:36-39` caveat so it names the plugin-only
    install as a cause, not only `--no-copy-scripts`, so the close-out miss is reported as a known
    install gap rather than politely. Files: `README.md`, `skills/sdlc/templates/stage-6-handoff.md`.

13b. **Make the Stage 2 decompose gate weigh files, not just steps.** Observed on this plan's own
    Phase 1 run: `task_count = 4 < 6` routed a change spanning ~20 files and three new CI checks to a
    single agent (`implement.json.data.gate.note`). The gate in `skills/sdlc/templates/stage-2-gate.md`
    decomposes only when `task_count >= agents.decompose_min_tasks`; add `len(files_to_change)` as a
    second trigger (a named threshold, overridable, e.g. `agents.decompose_min_files`), keeping the
    surfaces-disjoint requirement. Any new key lands in `templates/project.json.example` **and**
    `docs/CONFIG.md`. Files: `skills/sdlc/templates/stage-2-gate.md`, `templates/project.json.example`,
    `docs/CONFIG.md`.

14. **Version bump — only if Phase 2/3 ships, and mind the existing one.** Phases 2–3 touch
    `skills/`, `copilot/`, `codex/`, `scripts/hooks/` — all under `SHIPPED_GLOBS`. **Two
    corrections to revision 1:** `check_version_freshness` is **git-history based** (`:548-609`,
    `git log -L`), so it reads green for the entire `/sdlc` run regardless of what changes — it
    cannot "fail without this"; the bump is needed for the *commit*, not the run. Current version
    is **0.8.0** (committed with Phase 2); bump from there.
    Files: `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`.

#### Phase 5 — plugin-root-aware script citations (split out of step 13 by Stage 1.5)

16. **Make shipped prose find `scripts/` under a plugin-only install.** Step 13 originally bundled
    this with the README fix. Stage 1.5 measured the real scope: **21 backticked `scripts/…`
    citations across 11 shipped files** (`stage-6-handoff.md` ×4; `skills/task`, `state-schema.md`,
    `skills/sdlc`, `skills/sdlc-status`, `skills/repo-onboarding`, and both `/sdlc` overlays ×2
    each; `skills/repo-health` and two `code-tour` references ×1) against the 3 files step 13
    named. That is a four-fold scope increase, and it has an **undesigned mechanism**: skill prose
    cannot expand `${CLAUDE_PLUGIN_ROOT}` the way `hooks/hooks.json` does, so "plugin-root-aware" is
    not yet a thing a sentence can be. Design first — candidates: a single stated resolution rule
    ("`scripts/<x>` resolves against the repo root if present, else the plugin root above this
    skill's base directory") cited from each site; or `setup.sh`-style prefix rewriting done by the
    plugin loader; or making the plugin install copy `scripts/` on first use. Only Claude
    plugin-only installs are affected — Copilot and Codex always install through `setup.sh`, which
    copies `scripts/`. Mind `GOTCHAS.md:69`: invoke as `bash …` / `bash scripts/py.sh …`, never a
    bare `.sh` or `python3`. Files: the 11 listed above, once the mechanism is chosen.

#### Deferred — cannot be verified on this machine

15. **The two macOS portability bugs — own follow-up, not this run.** Both were flagged
    *unverified* by the review and this machine has only bash 5.2, so neither can be reproduced
    here; fixing unreproduced bugs blind is how a wrong cause gets enshrined.
    (a) `protect-tests.sh` expands an empty `FILES` array under `set -u` (`:40` `set -u`, `:66`
    `FILES=()`) — an error on bash 3.2, macOS's system bash. **Two sites, not one:** `:240` and
    **`:77`'s `[ "${#FILES[@]}" -ge 1 ]`**, reachable via `arm` with no arguments, which revision
    1 missed. Guard: `"${FILES[@]+"${FILES[@]}"}"`.
    (b) `stop-gate.sh:170` uses `timeout(1)`, absent on stock macOS, so the shell returns 127 and
    `:175-178` misreports it as "`test.unit` command not found" — detect absence and run without
    the timeout rather than reporting a wrong cause.
    Files: `scripts/protect-tests.sh`, `scripts/hooks/stop-gate.sh`, `scripts/ci/test-hooks.sh`.

### Cross-Module Touchpoints

- **`/task`** gains `--slug` on its arm/verify calls (step 11) — the only skill whose flow changes.
- **`/sdlc`** changes in three places: `SKILL.md` gains the Stage 2 transition writes (step 9),
  Stage 0's ad-hoc path stops creating a second envelope (step 12), and the overlays regain 8 and
  9 pointers (step 5).
- **`/repo-health`** gains the expired-pin due-list (step 3) and stays read-only.
- **`/sdlc-status` and `/repo-health`** both consume `envelope-staleness.md`, which reads
  `stage`/`status`/`updated_at` — step 9 fixes their input, not just `--resume`'s.
- **Consumer repos:** no new `project.json` keys, so no `/repo-onboarding` re-run. Step 13 changes
  what a plugin-only consumer does at install time — a README plus prose-path change, no migration.
- **Codex tiering (newly unblocked, deliberately not in this plan):** correcting `models.md`
  established that Codex resolves `model` per-subagent today, so Axis 1 there is advisory only
  because nothing implements it. A capability decision, not a bug fix.

### Open Questions

- **Is step 4 worth doing at all at ~50% precision?** It catches 3 real sites. The honest case for
  keeping it is that those 3 sites are *recurrences* — D4 and D7 existed because someone earlier
  wrote "four checks" and "three hooks" when those were correct. The honest case against is that a
  half-precise linter gets allowlisted into uselessness. Decide before implementing, not during.
- **Does the historical-marker loophole close properly?** Step 1's two mitigations (a resolving
  pointer to the superseding contract, a pinned count) are untested designs. If they prove
  awkward, exempting-by-marker is still better than today's unmarked ambiguity — but say so
  rather than letting the loophole stand silently.
- **Nine MEDIUM/LOW gaps remain out of scope**, per the scope decision: G6, G8, G11, G12, G13,
  G14, G15, G16. All have verified evidence in the synthesis.
- **Four "needs verification" items survive** beyond the macOS pair: the three fix-loop counter
  spellings, whether Copilot's hook runtime fires an event named `Stop`, `next-action.sh`'s
  `CODEX_HOME` gate, and whether plugin-root citation resolution works at runtime.

### Appendix: Alternatives Considered

**Conventional approaches**

- **A — "Fix the five, fence the rest"** (prevention last). Not chosen: a check written after its
  bug encodes that bug's shape, not its class.
- **B — "Prevention first, then fix into a green gate"**. **Chosen for ordering**, matching how
  `version-freshness` was added in `5232045`.
- **C — "Two PRs: bugs now, prevention separate"**. Revision 1 rejected this; **revision 2 adopts
  its PR boundary** on the mechanical ground revision 1 missed — Phase 1 touches nothing under
  `SHIPPED_GLOBS`, so it needs no version bump and cannot break a consumer. The rejection reason
  ("prevention gets deferred") is weaker than a hard packaging boundary.

**Wildcards** (all four declined the "add more checks" framing; three converged independently on
*delete the restatement rather than check it*)

- **Inversion — The No-Cardinality Rule** (S). **Adopted, drastically narrowed, as step 4.** The
  principle holds; the naive regex measured ~11% precision and would have flagged the repo's own
  corruption tally.
- **Constraint Removal — Truth Pins** (M). **Adopted in part as step 3** — the `assert-manual:
  recheck-by` half; the countable-pin half is redundant once step 4 narrows. Its "what survives
  both extremes" argument is why it won: the pin is the same artifact whether a free script or an
  infinite-compute reader evaluates it.
- **First Principles — Source-of-Truth Transclusion** (M). Not chosen: `<!-- gen:start -->`
  markers plus a generator is more machinery than the narrowed step 4, and still misses
  external-world claims. Revisit if `docs/CONFIG.md` drifts again — it is the one file with a
  real generation story.
- **Cross-Domain (legal codification) — The Consolidated Text** (M). Not chosen wholesale, but its
  central insight **is step 1**: amending-instrument vs consolidated-text became the mandatory
  `live contract` / `historical record` marker. The YAML-register half was the heaviest option for
  the least expensive defect class.

### Appendix: What revision 1 got wrong

Recorded because two of these are a kind this repo repeats — *describing a mechanism without
reading it* — and because a plan that hides its own correction teaches nothing.

1. **Overstated the prevention payoff.** Called the citation widening "the single
   highest-leverage change"; measurement shows it catches **none** of the three defects it cited.
   Kept, honestly scoped.
2. **Widened the wrong function.** `forbidden-phrases` and `collapsed-pairs` read `scope_files()`,
   not `citation_scope_files()` — and forbidden-phrases is the one check that could have caught
   the deleted-Workflow claim.
3. **Misdescribed `validate_skills.py`.** Claimed an existing exemption covered the dropped
   overlay pointers. It uses a skill-local regex and never sees the cross-skill form. It is a new
   check, not a tightening.
4. **Named two files that write nothing.** `stage-2-implement.md` and `stage-2c-converge.md` are
   sub-agent prompts; the orchestrator writes their sidecars, and `skills/sdlc/SKILL.md` was
   missing from the file list.
5. **Got the version-freshness mechanism backwards.** It is git-history based and reads green for
   an entire uncommitted run; and the tree already holds a 0.7.1 bump.
6. **Ordered Phase 1 so it landed red** — the scope widening before the marker that exempts the
   14 findings it produces.
7. **Undercounted the overlay gap** (8/9, not 7/8) and missed `changed-files-gate` entirely; also
   missed `protect-tests.sh:77` and `state-schema.md:88`.
8. **Treated `test-hooks.sh` fixtures as free.** Two need real scaffolding — a fake `python3` on
   `PATH`, and a synthetic JSONL transcript.
