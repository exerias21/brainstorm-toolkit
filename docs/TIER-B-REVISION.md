# Brainstorm Result: Tier B Revision

**Method**: dogfooded `/brainstorm` (Steps 1–7). Step 0 (Plan mode) skipped per
auto-mode session policy. Step 4b ran four lens subagents in parallel.

**Date**: 2026-04-25

## Direction

Drop ~70% of the original Tier B. The original 7 items were a generic
code-repo production-readiness playbook applied wholesale to a *skills-repo*.
The Inversion lens correctly diagnosed this as cargo-cult: B1 (eval thresholds),
B2 (coverage diff), B5 (numeric tolerance), B6 (pytest cache) defend Python
test surfaces this repo doesn't have.

Replace with a **two-track Tier B**:

- **Track 1 — Toolkit-self Tier B**: gates that defend the silent-failure
  surface of a skills repo. Smaller, sharper, all S/M effort. These ship in
  *this* repo's dev cycle and benefit any future skill change.
- **Track 2 — Consumer-pipeline Tier B**: the original B1/B2/B5/B6 belong
  here, scoped to `/sdlc`'s plugin-resident eval-runner. Because the runner
  is now plugin-resident (item 3 from this session), changes here benefit
  every consumer automatically without re-running setup.

Selection rule applied: each item must (a) defend against a real failure
mode the Inversion lens identified, AND (b) survive the Constraint-Removal
filter — i.e., remain valuable whether Phase 1 (run.json state envelope)
ever ships or not. The First-Principles "Pre-Merge Reality Check" is parked
as a long-term north star, not a Tier B item — its L effort and prod-replay
infra dependency exceed Tier B's "ship this month" budget.

## Implementation Steps

### Track 1 — Toolkit-self Tier B (this repo)

1. **B1' — Copilot overlay parity check.**
   - File: `scripts/validate_skills.py`.
   - For each skill that has both `skills/<name>/SKILL.md` and
     `copilot/skills/<name>/SKILL.md`, diff the frontmatter `metadata`
     blocks and warn on bundled-resource references missing in the override.
   - Pattern to follow: existing per-skill validation loop in
     `validate_skills.py`. Add an overlay-parity sub-check.
   - **Diagnostic level: warning, not error.** Existing override-less skills
     are fine; the check fires only when an override exists and diverges
     from the canonical metadata or is missing a referenced resource.
   - Defends against: skill drift (Inversion #1).

2. **B2' — Template-reference linter.**
   - File: `scripts/validate_skills.py` (extend in place — `validate_skill()`
     already takes a path and returns a problem list, the right shape for
     this check). Do NOT create a separate `validate_template_refs.py`;
     keep `validate_skills.py` as the single source of truth.
   - Grep each `SKILL.md` for `templates/<name>` references; verify each
     referenced file exists. **Resolution order**: (1) the skill's own
     `<skill-dir>/templates/<name>` (e.g., `skills/sdlc/templates/...`),
     (2) the repo-root `templates/<name>`. A reference that resolves in
     either location passes; only fails if both miss.
   - Already partially in `templates/stage-5-skill-repo.md` HARD checks;
     promote to a first-class validator that runs on every `/sdlc --skill-repo`.
   - Defends against: template/path breakage (Inversion #3).

3. **B3' — `setup.sh` round-trip smoke test in CI.**
   - **Files**: `scripts/ci/setup-roundtrip.sh` (NEW, vendor-agnostic;
     create `scripts/ci/` directory) AND
     `.github/workflows/setup-roundtrip.yml` (NEW, thin GHA wrapper;
     create `.github/workflows/` directory — first GHA workflow in this
     repo).
   - **Shell-script contract**: executable bit set (`chmod +x` after
     creation, also via `git update-index --chmod=+x` so it persists);
     idempotent (cleans `/tmp/sdlc-roundtrip-$$` before each setup.sh
     invocation, uses a unique path so concurrent runs don't collide);
     non-zero exit on any failure (missing skill, setup.sh error, marketplace
     drift). Operations:
     1. Run `setup.sh --target /tmp/sdlc-roundtrip-$$/copy --tools both`.
     2. Run `setup.sh --target /tmp/sdlc-roundtrip-$$/no-copy --tools both --no-copy-scripts`.
     3. **Marketplace assertion**: for each entry in
        `.claude-plugin/marketplace.json` `plugins[0].skills`, verify the
        corresponding `.claude/skills/<name>/SKILL.md` exists in the
        copied target. Catches unregistered skills.
     4. Cleanup `/tmp/sdlc-roundtrip-$$/`.
   - **GHA workflow**: triggers `on: { pull_request: {}, push: { branches: [main] } }`.
     Failure surface: nonzero exit from the script fails the GHA check
     (default behavior). Step is named `setup-roundtrip` so it shows up
     clearly in PR check status.
   - Reframes original B3 (migration round-trip) for a skills-repo: the
     setup.sh install IS our "migration".
   - Defends against: plugin-install path assumptions (Inversion #4),
     unregistered skills slipping through (gotcha B3').

4. **B4' — Cycle-time + blocked-reason fields in `TASKS.md`.**
   - **Files**: `templates/TASKS.md.template`, `skills/status/SKILL.md`,
     and (if it exists) `copilot/skills/status/SKILL.md` for overlay
     parity per CLAUDE.md rule 8.
   - Add: structured `started_at` / `completed_at` / `blocked_reason` fields
     per row (kept human-readable; e.g., as inline italics or a small
     metadata block). **Fields are additive and optional**: existing rows
     in consumer repos without them remain valid; `/status` treats absent
     fields as "unknown" rather than as a missing-data error.
   - Update `/status` to compute and surface cycle time and blocked-reason
     summaries. If a Copilot overlay of `/status` exists, mirror the same
     parsing + summary logic there.
   - Was original B7. Kept as-is — universally cheap, useful, survives both
     Phase-1 worlds.

5. **B5' — Pre-tool poka-yoke for secret patterns.** *(Claude consumers only.)*
   - **Files**:
     - `examples/GOTCHAS.md.example` — append the recommended secret-regex
       set under a `## Secret Patterns (recommended for hooks)` section.
     - `templates/AGENTS.md.template` — add a new top-level section
       `## Hooks (Claude-only)` describing the optional PreToolUse hook on
       `Write`/`Edit`. Keep the section under ~40 lines to respect the
       250-line ceiling on the rendered AGENTS.md.
     - `templates/project.json.example` — add `pipeline.poka_yoke` (default
       `false`) to the existing `pipeline` block, with a `_comment`
       documenting that enabling it requires the corresponding hook to be
       configured in `.claude/settings.json` (which `/repo-onboarding`
       writes when the user opts in).
     - `skills/repo-onboarding/SKILL.md` — add an opt-in prompt step
       *after* the project.json bootstrap step (where the consumer's
       `.claude/project.json` is created), asking "Enable secret-blocking
       PreToolUse hook? (recommended for production repos)". On yes:
       set `pipeline.poka_yoke: true` AND write the hook config to
       `.claude/settings.json`. On no: leave both unset.
   - **Copilot equivalent**: none — Copilot does not support Claude's
     PreToolUse hook format. For Copilot consumers, the Stage 6 gitleaks
     scan (Tier A A3) remains the only secret defense. Document this
     explicitly in the new AGENTS.md hooks section so Copilot users
     are not misled.
   - Toyota lens: prevent defects rather than detect them. Stage 6's
     gitleaks scan becomes the *second* line of defense for Claude
     consumers and the *only* line for Copilot consumers.
   - Defends against: agent writing a secret into a file (today only
     caught at commit time, only on Claude). Tier A A3 already covers
     commit-time on both tools.

### Track 1 (continued) — Vetting reinforcements

Added 2026-04-25 from a follow-up question: `/brainstorm` Step 7 today is a
single fresh-context validator. One agent has one perspective. A multi-lens
vet — same shape as `/sdlc` Stage 1.5 (paths/completeness/gotchas) — would
catch more.

8. **B8' — Multi-agent vet for `/brainstorm`.**
   - **Files**: `skills/brainstorm/SKILL.md` and `copilot/skills/brainstorm/SKILL.md`.
   - Add `--vet [light|deep|ultra|none]` flag to argument-hint and Arguments section.
   - **Modes** (cost increases left to right):
     - `none`: current single Step 7 validator (today's behavior).
     - `light`: 3 Haiku agents (paths / completeness / gotchas) — reuse the
       prompts from `skills/sdlc/templates/stage-1.5-sanity-check.md` so the
       vetting language is consistent across skills. Add to a new "Step 6.5
       — multi-agent vet" between Save (Step 6) and current single-agent
       Step 7. ~30s, ~3 small agents.
     - `deep`: light + 1 Sonnet "stress-test" agent that tries to find a way
       the plan could fail (a focused inversion check). ~5× cost of light.
     - `ultra`: deep + 2 Opus agents:
       - **architectural-coherence** (Opus): does the plan's structure
         actually fit the codebase's existing architecture? Flags
         layering violations, abstraction mismatches, and "the plan
         works in isolation but contradicts existing patterns" issues
         that a one-feature-at-a-time validator misses.
       - **edge-case-divergence** (Opus): for each acceptance criterion,
         enumerate 3–5 edge cases the plan does NOT explicitly handle.
         Surfaces "happy path only" plans before they get implemented.
       Premium tier for migrations, security-critical work, public-API
       breaking changes, or anything where a wrong call has high blast
       radius. ~25× cost of light, but cheaper than a botched implementation.
   - **Auto-promotion** based on plan attributes when `--vet` is omitted:
     - `<5` implementation steps → `none` (just the existing Step 7).
     - `5–15` steps → `light`.
     - `>15` steps or cross-module touchpoints → suggest `deep` to the user.
     - Plan touches DB migrations, auth/secrets, public API contracts, or
       deploy/rollback paths → suggest `ultra`. The skill detects these by
       grepping the plan's "Files to change" and "Implementation Steps"
       sections for migration/auth/secret/api/deploy keywords.
     - User can always pass `--vet <mode>` explicitly to override the
       suggestion.
   - **Copilot overlay**: same flag, but agents run sequentially in main
     context (no parallel fan-out). Document this in the override.
   - Defends against: shipping plans whose paths/gotchas/completeness
     gaps would only surface during `/sdlc` Stage 1.5 — costlier to fix
     post-implementation than at plan-time.

9. **B9' — Default-on vet contract for BRD → PBI (forward-looking).**
   - **Files**: `skills/post-deploy-verify/SKILL.md` (existing stub references
     BRD/PBI artifacts), `BRAINSTORM-PIPELINE.md` (Phase 2 description).
   - The BRD → PBI skill itself doesn't exist yet (Phase 2 of the broader
     plan). This item documents the contract that future skill must obey:
     vetting is **default-on, not opt-in**, because bad PBIs poison the
     entire downstream pipeline.
   - **3 default-on vet agents per PBI batch**:
     1. **Testability agent** (Haiku): each PBI must have at least one
        testable acceptance criterion. Untestable AC → PAUSE, ask user
        to clarify.
     2. **Traceability agent** (Haiku): each PBI must map to a `REQ-NNN`
        in the BRD. Orphan PBI → PAUSE.
     3. **Coverage agent** (Sonnet): for each `REQ-NNN`, at least one PBI
        must cover it. Uncovered REQ → PAUSE.
   - On any CRITICAL flag, the BRD → PBI flow PAUSES and asks the user;
     it does NOT proceed to `/sdlc` with bad PBIs.
   - Add a `## Companion: BRD → PBI vetting (forward-looking contract)`
     section to `skills/post-deploy-verify/SKILL.md` documenting this so
     it travels with the skill it composes with.
   - Add a Phase-2 note to `BRAINSTORM-PIPELINE.md` mentioning vetting is
     default-on for BRD → PBI.
   - Defends against: untestable, orphan, or uncovered PBIs flowing into
     `/sdlc` and producing implementations that don't trace back to the BRD.

### Track 2 — Consumer-pipeline Tier B (eval-runner.py + `/sdlc`)

6. **B6' — Eval thresholds in `project.json`.**
   - File: `scripts/eval-runner.py`, `templates/project.json.example`.
   - Original B1. Add `eval.thresholds` block (defaults per Q3 resolution
     above): `{ min_pass_rate: 0.85, max_flake_retries: 3, min_coverage_delta: 0 }`.
     Enforce in `run_all_tests` exit-code logic.
   - **Read with `.get()` defaults — never KeyError.** Use
     `config.get("eval", {}).get("thresholds", {}).get("min_pass_rate", None)`-style
     access. Missing key → fall through to prior binary pass/fail.
   - Plugin-resident now (item 3) — every consumer benefits.
   - **Migration**: existing consumer `project.json` files without an
     `eval.thresholds` block fall back to the prior binary
     pass/fail behavior (no regression). Defaults take effect only when
     the block is added explicitly; the example template documents the
     defaults *and* the recommended-prod-bound stricter set
     (`min_pass_rate: 0.98, max_flake_retries: 1, min_coverage_delta: 0.02`)
     but leaves the active block commented-out so existing consumers
     opt in deliberately.

7. **B7' — Numeric tolerance + ignored-fields in `diff_json`.**
   - File: `scripts/eval-runner.py:diff_json`.
   - Original B5. Read tolerance config from a per-feature `meta.json`
     (e.g., `{"tolerance": {"numeric": 1e-6, "ignore_fields": ["timestamp", "id"]}}`).
   - **Missing meta.json → treat as empty config** (`{}`): no tolerance,
     no ignored fields, behavior identical to today. Never hard-fail
     `diff_json` because of an absent or malformed config — log a warning
     and continue with defaults.
   - Plugin-resident — ships once, benefits everyone.

### Cross-Module Touchpoints

- `validate_skills.py` (B1', B2') — single source of truth, extend rather
  than duplicate.
- `setup.sh` (B3') — already exercised by `templates/stage-5-skill-repo.md`
  HARD checks; CI workflow makes it durable.
- `templates/AGENTS.md.template` (B5') — onboarding entry point for hook
  recommendations. Touches every new consumer repo.
- `scripts/eval-runner.py` (B6', B7') — plugin-resident, so changes here
  flow to every consumer without setup re-runs.

### Open Questions — RESOLVED 2026-04-25

- **B3' CI vendor**: ship **both**. Portable smoke test in
  `scripts/ci/setup-roundtrip.sh` (the actual round-trip logic). Thin GHA
  wrapper at `.github/workflows/setup-roundtrip.yml` calls the script.
  Consumers on GitLab/Jenkins/CircleCI copy the script and write a small
  vendor-specific wrapper.
- **B5' poka-yoke default**: **opt-in, loudly recommended in
  `/repo-onboarding`**. Onboarding prompts: "Enable secret-blocking
  PreToolUse hook? (recommended for production repos)" and writes the
  config based on the answer. AGENTS.md template documents the option.
  Default-off because false-positive rate is unknown and a hook firing
  mid-edit on innocuous patterns is worse than no hook at all.
- **B6' threshold defaults**: ship **generous**, document strict as the
  recommended ratchet for prod-bound repos:
  ```json
  "thresholds": {
    "min_pass_rate": 0.85,
    "max_flake_retries": 3,
    "min_coverage_delta": 0,
    "_recommended_for_prod_bound_repos": {
      "min_pass_rate": 0.98, "max_flake_retries": 1, "min_coverage_delta": 0.02
    }
  }
  ```
  Reasoning: day-1 false positives erode trust in the whole pipeline. Teams
  ratchet up once stable. Reverse path (disable thresholds because they
  fail too often) rarely recovers.

## Appendix: Alternatives Considered

### Conventional Approach A — "Ship Tier B as drafted"
**Why not chosen**: Inversion lens identified that B1/B2/B5/B6 defend a
test surface this repo doesn't have. Shipping them in this repo would have
been generic-playbook theater.

### Conventional Approach B — "Re-bucket around new pipeline shape"
**Partially adopted**: the Track 1 / Track 2 split is exactly this — group
by where work lands (toolkit-self vs eval-runner). The lens findings made
it sharper than a bare re-bucket.

### Conventional Approach C — "Defer some Tier B for post-deploy-verify probes"
**Why not chosen as primary**: post-deploy-verify is a stub awaiting Phase 2
BRD/PBI artifacts. Adding probes now would be premature — the artifacts
they'd consume don't exist. Revisit when Phase 2 lands.

### Wildcard 1 — First Principles: "Pre-Merge Reality Check"
**Why not chosen**: brilliant north star but L effort, requires prod-replay
infra most consumers don't have. Park as a future major feature, not
Tier B. Reference: replays the change against recent prod traffic in a
disposable replica before merge.

### Wildcard 2 — Inversion: "Failure-Mode-First Tier B"
**Adopted as the primary frame**. The Track 1 items B1', B2', B3' are
direct outputs of the Inversion analysis. The diagnosis "70% of Tier B is
cargo-cult" reshaped the entire revision.

### Wildcard 3 — Cross-Domain (Toyota TPS): "Jidoka + Andon + Poka-yoke"
**Partially adopted**. B5' (pre-tool poka-yoke for secrets) is a direct
import. The full TPS vision (andon cord, takt time, heijunka) is too
ambitious for Tier B — it's a Phase 4+ aspiration alongside the broader
pipeline. Keep the philosophy ("prevent, don't detect") as a North Star.

### Wildcard 4 — Constraint Removal: "Stateless-Survivors Tier B"
**Adopted as the selection criterion**. Every item in the revised Tier B
above passes the test "valuable whether Phase 1 exists or not". The two
items it explicitly drops (run-history correlation, cross-stage artifact
diffing) were never in the original Tier B but would have been tempting
to add as Phase-1-lite shims.

---

## Validation (Step 7) — completed

Fresh-context validation agent ran against this plan. Verified:
- All cited file paths exist (`validate_skills.py`, `eval-runner.py`,
  `setup.sh`, `templates/*`, `.claude-plugin/marketplace.json`).
- `eval-runner.py` has `run_all_tests` (line 244) and `diff_json` (line 180)
  — B6'/B7' have real landing zones.
- `validate_skills.py` already iterates both `skills/` and `copilot/skills/`
  and tracks `copilot_override_names` (lines 147–188) — B1' extension is
  well-suited.
- `project.json.example` already has `eval` and `pipeline` blocks — B6'
  thresholds and B5' `pipeline.poka_yoke` slot in cleanly.

Issues addressed (incorporated above):
1. B3' now creates `.github/workflows/` if absent (first GHA workflow in
   this repo).
2. B5' now explicitly scoped to Claude consumers; Copilot equivalent
   documented (none — relies on Stage 6 gitleaks).
3. B2' now commits to extend-in-place in `validate_skills.py`; alternate
   `validate_template_refs.py` path dropped.
4. B4' and B6' now note additive/optional migration so existing consumer
   repos remain valid without changes.

Unresolved — moved to Open Questions: B3' workflow vendor (GHA vs
workflow-agnostic doc + sample); B5' default-on vs opt-in via
`pipeline.poka_yoke`; B6' threshold defaults (0.95 / 2 / 0 — generous
or strict).
