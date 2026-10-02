## Brainstorm Result: Model-tier gaps + an opt-in extras pack

> Written 2026-09-25 from a review of four model-tier gaps (each verified against the tree
> with file:line evidence), plus a discovery pass over the owner's other repos
> (poc-contractor, bdt-rewrite, user-level skills). Other repos are **read-only sources**.
> Nothing here edits them.

### Direction

Two tracks in one plan. **Track 1** closes four model-tier gaps in prose, with one new
deterministic guard:

- correct the Codex docs claim (docs only; Codex executors are not planned);
- surface degraded reviewer independence early and in the final report;
- an **opt-in, cap-bounded** escalation of the fix loop's last try;
- a `models.planner` key that `/brainstorm`'s session nudge reads;
- a CI check that turns CLAUDE.md rule 4's description budget from a hand measurement into
  a gate.

**Track 2** ships seven generic skills from the owner's other repos as an **opt-in extras
plugin**: a sibling `extras/skills/` tree, a second `marketplace.json` plugin, and
`setup.sh --extras`. The default set's always-resident description budget (7,024 of 7,500 by a
YAML parse, leaving room for less than one full-length skill
characters) stays untouched. Each port is generalized first (repo paths, client data and
product names stripped; failure-mode rationale kept), then reviewed with `/skill-creator`.

The budget check comes from the *Inversion* wildcard, taken without its freeze. The rest
is the conventional option the owner chose question by question.

---

### Conventions & reuse

- Follow: the print-then-dispatch rule `model: <tier> (cap: <cap|none>)`,
  `skills/sdlc/templates/models.md` "Prose dispatch rule". An escalated dispatch appends
  `, escalated` and never skips the line.
- Follow: the cap is a ceiling that only lowers (`models.md` "Axis 1"). Escalation is
  `min(stage_tier + 1, cap)`, so under the default `cap: sonnet` it is a no-op, and the
  plan says so out loud rather than hiding it.
- Follow: the independence contract, observed and never enforced by re-tiering
  (`models.md` "Independence", `skills/sdlc/templates/stage-5.7-review-fix.md:145-156`).
  The new lines surface it; behaviour does not change.
- Follow: the existing *Session nudge* block (`models.md` "Session nudge"). It is
  tool-agnostic, once per session, and never detects the host model. The planner nudge
  reuses its wording shape.
- Follow: every new config key lands in **both** `templates/project.json.example` (with a
  `_comment`) and `docs/CONFIG.md`. `check_contracts.py`'s `config-keys` check enforces only
  the example file (`load_registry()`); nothing checks `CONFIG.md`, so a lane must edit it
  deliberately and Stage 5 must grep it for each new key. `AGENTS.md` is a byte-identical copy
  of `CLAUDE.md`, so any CLAUDE.md edit (rule 4) lands in both.
- Follow: Stage 7 is a three-leg edit, in `skills/sdlc/SKILL.md` (Stage 7),
  `copilot/skills/sdlc/SKILL.md` and `codex/skills/sdlc/SKILL.md`.
- Follow: `check_contracts.py`'s check-plus-`--self-test` shape. Each check gets a seeded
  violation it must catch.
- Reuse: `setup.sh`'s per-skill install loop (`setup.sh:180`, `install_overlay`,
  `strip_nonportable_frontmatter`) for the extras loop. Don't write a second installer.
- Reuse: `scripts/ci/setup-roundtrip.sh`'s forward (3) and reverse (3b) marketplace
  assertions, extended to the extras plugin and tree.
- New (justified): `extras/skills/` as a sibling of `skills/`, not a subfolder. `setup.sh:180`
  and roundtrip 3b both iterate `skills/*/`, and extras must not trip either or install by
  default.
- New (justified): a second `marketplace.json` plugin `brainstorm-toolkit-extras`
  (`source: "./extras"`, its own `extras/.claude-plugin/plugin.json`, `skills:
  ["./skills/..."]` relative to that source). It is the host-native opt-in: a consumer
  installs it separately, and its descriptions cost budget only there. It cannot share the
  core plugin's `source: "./"` root -- strict mode still loads that root's default `agents/`
  and `hooks/hooks.json` for a second plugin sourced there, so both would fire twice with
  both plugins installed; a separate plugin root is the documented fix.
- Doc drift: `models.md` Runtime regimes (~`:196-199`) and `docs/MODEL-AXES.md:37-45` say
  Codex per-sub-agent tiers "can apply here too"; `codex/skills/sdlc/SKILL.md:20,166-176`
  runs single-agent with "no sub-agent seam". The overlay is right; the docs are fixed
  here.

---

### Implementation Steps

#### Phase 1 — Model-tier gaps (prose + one CI check)

1. **Codex docs correction.** In `skills/sdlc/templates/models.md` Runtime regimes and
   `docs/MODEL-AXES.md:37-45`, keep the product fact (Codex resolves `model` per sub-agent,
   under the existing `assert-manual` pin) and change the toolkit claim. This toolkit's
   Codex overlay dispatches no sub-agents, so Axis 1 is **advisory on Codex today**, the
   same practical effect as Copilot for a different reason. Record Codex executors (e.g. a
   GPT model via `.codex/agents/*.toml`) as not planned, one line in `MODEL-AXES.md`.
2. **Degraded independence, early and late.**
   (a) Stage 0: when the resolved `models.code_review` equals the implementer's effective
   tier and the review stage is ON, print the existing degraded line at Stage 0, before any
   spend, instead of only at dispatch. Compute the collision from `models.md`'s
   *Independence* section, which is always loaded. **Never open `stage-5.7-review-fix.md`
   for this**: it is opt-in, and a default run must never load it.
   (b) Stage 7: add `independence: degraded — findings surfaced only, never auto-fixed` when
   `review.json.data.independence == "degraded"`. Three legs: canonical plus both overlays.
   Put the gate sentence in `skills/sdlc/SKILL.md` Stage 5.7 and the wording in
   `stage-5.7-review-fix.md` (gate in the skill, body in the template).
3. **Opt-in last-try escalation.** New key `pipeline.fix_loop.escalate_last` (default
   `false`). When it is true, the **final** Stage 5 fix-loop iteration dispatches at
   `min(stage_tier + 1, effective_cap)` and prints `model: <tier> (cap: <cap>, escalated)`.
   Under the default `cap: sonnet` nothing changes. The fix agent's built-in tier is Sonnet
   whatever the cap (the cap only lowers), so the case where the key *does* act is
   `models.cap: "opus"` (or `--model opus`): iterations 1–2 run Sonnet, the last runs Opus.
   State both cases in the key's `_comment`, `CONFIG.md` and `fix-loop.md`. Stage 5.7/5.8 is excluded: it has its own budget and Axis
   2 is not on the ladder. Copilot/Codex: no sub-agent seam, so the overlay prints the
   suggestion (`re-run with --model opus`) in the PAUSED block instead. In `fix-loop.md`,
   also state that without the key, retries stay on the same tier by design.
   `enforce-model-cap.sh` needs no change (an escalation within the cap is never rewritten);
   add one `test-hooks.sh` case that proves it.
4. **`models.planner`.** New key (default `"opus"`; values `haiku|sonnet|opus|fable`;
   advisory). `models.md` documents it as a third kind, a session-model *recommendation*
   that is on neither axis. Print, once:
   `Planning runs on your session model. Recommended: <planner> — switch before the
   clarifying rounds if you aren't on it.` Reuse the Session-nudge wording and never detect
   the host model. Insertion points differ per file (four legs):
   `skills/brainstorm/SKILL.md` "Step 0: Set the frame"; `skills/brainstorm-team/SKILL.md`
   "Before Invoking — Load Project Context"; `copilot/skills/brainstorm/SKILL.md` top of
   "Step 1: Understand the Seed" (it has no Step 0); `copilot/skills/brainstorm-team/SKILL.md`
   "Before starting — load project context". No
   SKILL.md `model:` frontmatter: it is turn-scoped and would pin only the first turn of a
   multi-turn session.
4b. **Per-focus sanity tiers** (owner decision 2026-09-25). Built-in Stage 1.5 defaults
   become `paths: haiku` (mechanical: does the file or symbol exist?), and `completeness:
   sonnet` plus `gotchas: sonnet` (judgment). On this repo, Haiku completeness checks
   repeatedly misread "not yet implemented" as a plan gap. `models.sanity` accepts either a
   string (all focuses, today's meaning, unchanged) or a map (`{"completeness": "opus"}`,
   unlisted focuses keep their built-in default). Each value still passes through the cap.
   An invalid value falls through to the default (models.md "Invalid input"). Edit
   `stage-1.5-sanity-check.md` ("Which tier"), `models.md` (Per-stage tiers + config
   surface), `templates/project.json.example` (`models.sanity` comment), `docs/CONFIG.md`,
   and every overlay line that states the Haiku default (grep `models.sanity` and
   "3 Haiku" across `skills/`, `copilot/`, `codex/`, README, `docs/COST.md`). The printed
   line becomes per focus: `model: paths=haiku, completeness=sonnet, gotchas=sonnet (cap: …)`.
5. **Description-budget CI check.** `scripts/ci/check_contracts.py` gains
   `description-budget`: parse every default-set `skills/*/SKILL.md` frontmatter
   description (a real parse, never a `grep -c`). Fail when the set total is over 7,500;
   warn when a single description is over 550 and fail over 600. Measure the extras set
   separately against its own ceiling (same numbers). Add a `--self-test` seeded violation.
   Update CLAUDE.md rule 4 to cite the check. **Measured baseline (2026-09-25, PyYAML):**
   set total 7,024; the max is `repo-onboarding` at 594, which would warn from day one. Trim
   that description to ≤550 in the same step (trigger words kept first), so the check ships
   clean. `brainstorm` sits at 549.
6. **Park the Jev doc-claims verb.** In `docs/plans/jev-integration.md`, add a second judge
   verb `classify-claim`: a Choice asking "is this line asserting the present or recording
   the past?". It comes from poc-contractor's `audit_doc_claims.py`, which uses Jev for the
   rhetorical judgement only and never for verifying facts. It is a future `/repo-health`
   docs-currency check once `scripts/judge.py` exists. Docs only.
7. **Version bump.** `.claude-plugin/plugin.json` and `marketplace.json`.

#### Phase 2 — Extras infrastructure (no skills yet)

8. **Tree and manifest.** Create `extras/skills/` (with a `README.md` stating the opt-in
   rule and the porting bar) and a second `marketplace.json` plugin
   `brainstorm-toolkit-extras` with an empty-safe skills list.
9. **`setup.sh --extras`.** The core loop at `setup.sh:180` is inline, not a function.
   **First extract it** into a parameterized function (source tree, destination, gate) that
   core calls unchanged, then call it for `extras/skills/*/` behind `--extras`. Never
   copy-paste a second loop. Same frontmatter stripping (`strip_nonportable_frontmatter`),
   overlay fill-in (`install_overlay`) and `applies-to` routing. Off by default. Include it
   in `--help` and the install summary. Codex/Copilot need no extras-specific overlay story:
   the existing `codex/ → copilot/ → canonical` fallback covers them.
10. **CI coverage.** `setup-roundtrip.sh:56` hardcodes `data["plugins"][0]`. First resolve
    each plugin's `skills` **by name** (`brainstorm-toolkit`, `brainstorm-toolkit-extras`),
    then add forward and reverse registration for the extras plugin and a second reverse
    loop over `extras/skills/*/`, plus a `--extras` install that is asserted to land them
    and a default install asserted **not** to. `validate_skills.py` already iterates plugins
    generically (`:489`). `validate_skills.py` and `check_contracts.py` scan
    `extras/skills/` too (citations, portable frontmatter, COMMENTS/GIT pins where the
    extras dispatch file-editing sub-agents). Add `extras` to `check_contracts.py`'s `SHIPPED_GLOBS`
    (read by `check_version_freshness`), so an `extras/` change with no version bump fails CI
    the same way a core change does.
11. **Docs.** A README "Extras (opt-in)" section with its own table and the install
    commands for the marketplace and `setup.sh --extras`. Add a CLAUDE.md layout line for
    `extras/`. No CI checks README table parity, so run GOTCHAS' manual
    `rows == unique(rows) == skills on disk == marketplace` check by hand for both tables.
    **Version bump.**

#### Phase 3 — Ports A: red-check, dependency-vetting

**Source locations** (absolute, so a fresh session can find them; read-only, never edit
them): poc-contractor = `E:\programming\poc-contractor\.claude\skills\<name>\`; bdt-rewrite =
`E:\programming\bdt-rewrite\.claude\skills\land-external-export\`. If a path has moved, stop
and ask. Do not search the disk for a replacement.

For every port: read the source fully; generalize it (strip repo paths, product names,
client or PII details, and repo-specific case data; keep failure-mode rationale in
anonymised form); set `metadata.brainstorm-toolkit-applies-to` honestly; keep the
description ≤550 characters with trigger words first; **write** the generalized file to
`extras/skills/<name>/SKILL.md` (LF line endings; both sources are CRLF); then run `/skill-creator` to review
the ported skill (structure, triggering, clarity). A description-optimization *eval* loop
is optional and **manual**, because it spawns paid runs. Register each in the extras
plugin and README table.

12. **`extras/skills/red-check/`** from `poc-contractor/.claude/skills/red-check`: a guard
    or regression test is trusted only after it has been watched failing with the fix
    reverted. Keep the four incident cases as anonymised illustrations. Its method writes to the working tree
    (`git stash` / `git apply -R`); state that it must not run inside a caller that promises no
    git writes (e.g. an `/sdlc` sub-agent) unless that caller carves out the exception.
13. **`extras/skills/dependency-vetting/`** from `poc-contractor/.claude/skills/dependency-vetting`,
    with the release **cooldown changed to 5 days** (owner decision), configurable via a new
    `deps.cooldown_days` key (default `5`, in `project.json.example` and `CONFIG.md`),
    keeping the CVE-fix override and the vetting checklist. Drop the repo's package counts.
14. **Version bump.**

#### Phase 4 — Ports B: verify-by-effect trio

15. **`extras/skills/external-review/`** from `poc-contractor/.claude/skills/external-review`,
    generalized from Google Antigravity `agy` to "a second model family's CLI": a
    configurable command (`external_review.cmd`, deliberately not under `review`/
    `pipeline.review_fix`, which is the unrelated Stage 5.7 review; documented in both config
    files), with the
    operational traps (wrong-cwd silent success, exit 0 with no work) kept as the checklist.
    A no-command run prints how to configure it and stops.
16. **`extras/skills/pdf-inspect/`** from `poc-contractor/.claude/skills/pdf-inspect` plus
    its `inspect_pdf.py` (stdlib zlib + regex). Genericize away from the source repo's
    generator. The script runs via `bash scripts/py.sh`, never bare `python3`.
17. **`extras/skills/device-truth/`**, the *method* from `poc-contractor/.claude/skills/bug-hunter`:
    drive the built app on a real device or emulator, measure what is on screen rather
    than the narrative, and score journeys (truthful / disclosed / complete / legible /
    recoverable). Platform commands become a short per-stack table (Android `adb`, iOS
    simulator, web via the browser tools). The repo's address-sampling script is not
    ported.
18. **Version bump.**

#### Phase 5 — Ports C: data landing

19. **`extras/skills/data-discovery/`**: merge `poc-contractor`'s `data-source-pattern`
    with the shared shape of its four `*-discovery` skills into one generic skill. It picks
    a pattern (discovery pipeline / seed script / direct API), keeps a per-source
    `sources.json`, chooses WebSearch or a headless browser, handles session-cookie auth,
    trust tiers, dedup-upsert and a cost report per run. The county skills are **not**
    ported. One anonymised worked example shows the shape. Drop the repo's
    `discovery_driver.py` paragraph.
20. **`extras/skills/land-external-export/`** from `bdt-rewrite/.claude/skills/land-external-export`:
    stage the drop into a gitignored directory before opening it; record SHA-256, size and
    row count, never contents; measure against the promised row count; assert
    identity-domain compatibility before any join. Strip every path, table name and client
    detail. The source's PII incident becomes one anonymised sentence of failure-mode
    rationale.
21. **Version bump.**

---

### Cross-Module Touchpoints

- **`/sdlc` + both overlays**: Stage 0 warning, Stage 7 line, fix-loop escalation (Phase 1).
- **`/brainstorm`, `/brainstorm-team` + Copilot overlays**: the planner nudge.
- **`scripts/hooks/enforce-model-cap.sh`**: unchanged, but gains a regression case proving
  an escalation within the cap passes through.
- **`setup.sh`, `setup-roundtrip.sh`, `validate_skills.py`, `check_contracts.py`**: the extras
  tree and the budget check.
- **`docs/plans/jev-integration.md`**: gains the parked `classify-claim` verb.
- **Consumers**: nothing changes unless they opt in to extras or set the new keys.

### Open Questions

Decided by the owner in this session (2026-09-25), recorded so they are not re-litigated:
Codex executors are not planned; escalation is opt-in and cap-bounded, last try only;
degraded independence is surfaced both early and in Stage 7; the planner tier is a
config key read by a nudge, with no frontmatter pin; extras ship as a separate plugin;
the budget check fails CI; the cooldown is 5 days; brainstorm-deep is not ported (ask
`/brainstorm` to go deeper instead); Jev scripts are parked behind the judge seam.

Still open, decide at execution time:
- The extras set's own budget ceiling. Recommended: the same 7,500 / 550 numbers,
  measured separately.
- Whether `red-check` should later graduate into core (for example as a `fix-loop.md` rule).
  Revisit after it has been used.

### Appendix: Alternatives Considered

- **Build Codex executors now** (GPT via `.codex/agents/*.toml`): not chosen. It is large,
  needs a real Codex install to verify, and has no current need.
- **Escalation: document-only / pause-and-offer**: not chosen. Pause-and-offer survives as
  the Copilot/Codex fallback line.
- **Refuse same-tier review**: not chosen, because it overrides an explicit setting.
- **Planner pin via `model:` frontmatter**: not chosen; it is turn-scoped, so `/brainstorm`'s
  later turns would run unpinned.
- **Fold ports into existing skills / trim-then-add**: not chosen, because of the budget and
  lost standalone triggers.
- **Port brainstorm-deep**: not chosen by the owner, since it was never used.
- **Port the four county discovery skills / bug-fixer / bug-squasher / regulation-verify /
  postgres-schema-design / logging-conventions / cheatsheet**: stay repo-specific (their
  shape is captured by `data-discovery`), or user-level for reference material.
- **Port a no-Jev version of `audit_doc_claims`**: not chosen; its own docs say the rule
  half alone misfires.
- **Wildcard: Zero-Weight Skills** (trim harder): buys about one skill, not seven.
- **Wildcard: One Knob, One Shelf** (shared resolver + lazy descriptions): no host supports
  lazy descriptions.
- **Wildcard: The Freeze**: the moratorium was rejected; **its budget CI check was adopted**
  (step 5).
- **Wildcard: Reserve Desk**, as a router skill in core: implementable (~300 characters)
  but triggers weaker than full descriptions. Rejected for the separate plugin. Revisit if
  opt-in discovery proves too low.
