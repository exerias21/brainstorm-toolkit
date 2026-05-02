# Phase 1 — Pipeline State Envelope (+ `/pbi`, `--inspect`)

**Date drafted**: 2026-04-25
**Source**: `BRAINSTORM-PIPELINE.md` Phase 1 + dogfood feedback from teacup
SDLC runs (PRs #23–#25) and the architectural concern that Phase 1 not
"clobber the current setup for local development."

**Pre-requisite**: [`docs/CONVENTIONS.md`](CONVENTIONS.md) — every identity-form
name in this plan (skill names, stage names, artifact IDs, paths, flags) must
comply with the conventions there. Conventions land first; Phase 1 implements
against them.

---

## Goal

Make `/sdlc` runs produce **durable, machine-readable state** that survives
session boundaries, enables resumption, and lets future skills (BRD→PBI,
PBI-targeted runs, post-deploy verification) compose without each one
reinventing storage. **Without changing the local-dev experience** for
anyone who doesn't actively opt into the new capabilities.

This phase delivers four user-visible additions, all built on one shared
state contract:

1. A transparent state journal under `.claude/pipeline/<slug>/`
2. `/sdlc --resume` to pick up a crashed/paused run
3. `/sdlc --inspect <slug>` to print a human-readable status
4. `/pbi <description>` — direct PBI authoring without a BRD, ready for
   `/sdlc --pbi` (Phase 3) or just `/sdlc <plan>` today
5. **Profile filtering** (`core` / `pipeline`) — keep one plugin, support
   two workflows; default is dev-centric so local users don't carry
   enterprise pipeline skills they'll never use
6. **`/standardize` skill** (1F) — apply repo-specific patterns the
   onboarding skill detects; closes the "no cleanup/standardize command"
   gap raised during dogfood
7. **Skill naming collision decision** (1G) — resolve the Claude
   Code vs Copilot duplicate-name visual collision (docs-only fix vs full
   `-cc`/`-gh` rename)

---

## Design rules (non-negotiable)

These rules exist because teacup has been shipping real PRs with the
current `/sdlc` for weeks. Phase 1 must not break that flow.

1. **Backward compat is non-negotiable.** Running `/sdlc <plan>` after
   Phase 1 produces the same PR with the same content as it does today.
   No new required flags, no new required config keys. If a consumer
   never reads the new state files, they see no behavior change.

2. **State is a transparent side-effect, never a contract.** `/sdlc`
   writes `run.json` and `stage-outputs/*.json` as it goes. **No skill
   is required to read them.** They are available for orchestrators
   that want them (CI gates, post-mortem dashboards, `--resume`).

3. **Gitignored by default.** `setup.sh` ensures `.claude/pipeline/`
   is in the consumer's `.gitignore`. State is **local-only**. After a
   `/sdlc` run, `git status` does not surface state-envelope noise.

4. **`--resume` is opt-in, never automatic.** A fresh `/sdlc <plan>`
   run starts from Stage 1 and overwrites any prior `run.json` for the
   same slug. Resumption only happens with explicit `--resume`. No
   accidental "you ran the same thing twice and it picked up stale
   state" surprises.

5. **No CI vendor lock-in.** State files are vendor-neutral JSON. The
   schema does not know about Jenkins, GHA, GitLab CI, or any specific
   orchestrator. CI integration is a *separate* skill (proposed for a
   later phase: `/ci-manifest` or similar) that reads the state files
   and emits whatever shape the CI vendor wants.

If any sub-task below appears to violate one of these rules, the
sub-task is wrong, not the rule.

---

## Implementation Steps

### 1A — State envelope foundations

Files modified:
- `skills/sdlc/SKILL.md` — every stage writes a JSON sidecar
- `skills/sdlc/templates/state-schema.md` — NEW; documents `run.json`
  and `stage-outputs/*.json` shapes
- `setup.sh` — adds `.claude/pipeline/` to consumer's `.gitignore`
  (creates `.gitignore` if missing)
- `templates/AGENTS.md.template` — short subsection documenting the
  state journal so consumers know it exists

State layout:
```
.claude/pipeline/<feature-slug>/
  run.json
  stage-outputs/
    sanity-check.json
    impl-summary.json
    eval-results.json
    flowsim.json          # mirror of plans/flowsim-<slug>.json (dual-write)
    validation.json       # plan-vs-delivered checklist results
    pr.json               # branch + PR URL
```

Behavior:
- At Stage 1, `/sdlc` creates the directory and writes `run.json`
  with `{stage: "parse", status: "in_progress", started_at, args}`.
- Each stage that completes writes its sidecar with
  `{status: "pass|fail|paused", summary, data: {...}}`.
- On stage transition, `run.json` is updated with the new stage name.
- On `pass` end-state, `run.json.status = "complete"`. On unrecoverable
  failure, `run.json.status = "failed"` with the failing stage recorded.
- All writes are **best-effort**: if the disk is full or the dir is
  unwritable, log a warning and continue. State writes never fail a
  pipeline run.

### 1B — `/sdlc --resume`

Files modified:
- `skills/sdlc/SKILL.md` — add `--resume` to argument-hint and Args;
  add a "Resumption" section near the top of the stages
- `copilot/skills/sdlc/SKILL.md` (if/when overlay exists) — same

Behavior:
- `/sdlc <plan> --resume`:
  1. Reads `.claude/pipeline/<slug>/run.json`. If absent, errors with
     "no prior run for `<slug>` — run `/sdlc <plan>` (without --resume)
     to start fresh."
  2. Identifies the next stage to run from `run.json.stage` and the
     stage-outputs directory (any stage whose sidecar shows
     `status: "pass"` is skipped).
  3. Resumes from the first non-passing stage. Earlier-passing stages'
     outputs are reused, not re-run.
  4. From there, behaves identically to a fresh `/sdlc` run.
- Slug is derived from the plan file the same way today's Stage 1 does
  it (no new arg).

Edge cases:
- If the prior run was at a stage that no longer exists in the current
  pipeline (e.g., the user upgraded the toolkit and Stage 5.5 split
  into 5.5a/5.5b), `--resume` reports "stage `<old>` no longer in
  pipeline — start fresh or pass `--resume-from <stage>`."
- If a stage-output sidecar references a file path that no longer
  exists (e.g., the plan was edited), the resume is rejected with a
  clear error. Don't try to be clever.

### 1C — `/sdlc --inspect <slug>`

Files modified:
- `skills/sdlc/SKILL.md` — add `--inspect` mode
- `skills/sdlc/templates/inspect-format.md` — NEW; the human-readable
  output template

Behavior:
- `/sdlc --inspect <slug>` reads `.claude/pipeline/<slug>/` and prints
  a single human-readable status block. No Agent calls, no Bash beyond
  reading the JSON files. Pure formatting.

Output shape:
```
SDLC run: <feature-slug>
Started:   2026-04-25T10:00:00Z
Status:    paused_for_review (Stage 5.5)
Plan:      plans/brainstorm-add-orders.md
Branch:    sdlc/add-orders (pushed; PR #42)

Stages:
  ✓ Stage 1   parse           (2s)
  ✓ Stage 1.5 sanity-check    (28s)  3 agents OK
  ✓ Stage 2   implement       (4m)   12 files changed
  ✓ Stage 3   generate-evals  (45s)  4 evals created
  ✓ Stage 4   eval-fix        (2m)   1 fix loop, all green
  ✓ Stage 5   validation      (1m)   no regressions
  ⏸  Stage 5.5 plan-validate   PAUSED — 1 mismatch (api focus)
    └── plans/flowsim-add-orders.json: orders.payment_method missing

Last update: 2026-04-25T10:08:23Z (3 min ago)
Resume:      /sdlc plans/brainstorm-add-orders.md --resume
```

Args:
- `--inspect <slug>` (required if `--inspect` is passed)
- Without `--inspect`, the rest of `/sdlc` runs as today.
- A bare `/sdlc --inspect` (no slug) lists all runs in
  `.claude/pipeline/` with one-line summaries.

### 1E — Profile filtering (`core` / `pipeline`)

**Why**: keep one plugin, support two distinct workflows without forcing
local-dev users to install pipeline skills (`/post-deploy-verify`, future
`/brd-ingest`, `/pbi-decompose`, `/approve`, `/deploy`, `/monitor`,
`/rollback`, `/coverage`) they'll never use. **Default profile is `core`
(dev-centric)** — local development, current `/brainstorm → /sdlc → PR`
flow. Pipeline workflows opt in via `--profile pipeline` (or `both`).

This avoids a premature plugin split. Two repos to maintain isn't worth
it when one repo + a flag does the job, and consumers can validate the
full pipeline locally before ever standing up Jenkins/CI.

Files modified:
- All `skills/<name>/SKILL.md` and `copilot/skills/<name>/SKILL.md` —
  add `metadata.brainstorm-toolkit-profile` frontmatter (`core`,
  `pipeline`, or `both`; default `core` when absent for safety).
- `setup.sh` — add `--profile {core|pipeline|both}` flag; **default
  `core`**. Include profile filter in the existing per-skill check that
  decides whether to copy.
- `scripts/validate_skills.py` — validate `metadata.brainstorm-toolkit-profile`
  is one of the three allowed values when present.
- `templates/AGENTS.md.template` — short subsection documenting profiles
  so consumers know how to opt into pipeline skills.
- `README.md` — explain the profile choice in the skills table; add a
  "Profile" column.

Profile assignments (current and future):

| Skill | Profile | Notes |
|---|---|---|
| `/brainstorm`, `/brainstorm-team` | `core` | Ideation; universal |
| `/sdlc` | `core` | Backbone; both worlds use it |
| `/task`, `/status` | `core` | Lightweight authoring + readout |
| `/repo-onboarding` | `core` | Bootstraps any repo |
| `/test-check`, `/e2e-loop`, `/eval-harness` | `core` | Test infrastructure |
| `/flowsim` | `core` | Plan-vs-code at file level |
| `/gotcha`, `/data-source-pattern`, `/logging-conventions` | `core` | Knowledge / pattern skills |
| `/dead-code-review` | `core` | Hygiene |
| `/pbi` (1D, this phase) | `core` | Lightweight single-PBI authoring |
| `/post-deploy-verify` | `pipeline` | Deployed-vs-BRD verification (currently a stub) |
| `/brd-ingest` (Phase 2) | `pipeline` | Future |
| `/pbi-decompose` (Phase 2) | `pipeline` | Future |
| `/approve` (Phase 4) | `pipeline` | Future |
| `/deploy`, `/monitor`, `/rollback`, `/coverage` (Phase 6) | `pipeline` | Future |

Behavior:
- `setup.sh` (no flag) → `--profile core` (default; dev-centric).
- `setup.sh --profile pipeline` → installs only pipeline-tagged skills.
- `setup.sh --profile both` → installs everything (current behavior;
  preserved as the explicit way to get the full set).
- `setup.sh --profile core` against a consumer that previously had
  pipeline skills installed: **does not delete** the existing pipeline
  skills (they stay in `.claude/skills/`); they just aren't refreshed.
  Consumers who want a clean core-only install can `rm -rf` the
  pipeline skill directories first. Setup.sh prints a one-line note
  when this case is detected.

Backward compat: existing `setup.sh` invocations without `--profile`
get `core`. Consumers who previously got `/post-deploy-verify` from a
`--profile`-less install (like teacup did) keep it; they just won't
get future updates to it unless they pass `--profile pipeline` or
`--profile both`. **The first install of a fresh consumer never gets
pipeline skills by default** — they have to ask.

Effort: ~half-day. Touches the same surface as 1A (setup.sh + skill
frontmatter), so bundling makes sense.

### 1D — `/pbi <description>` skill

Files added:
- `skills/pbi/SKILL.md` — NEW
- `copilot/skills/pbi/SKILL.md` — Copilot overlay (sequential vetting)
- `.claude-plugin/marketplace.json` — register the skill
- `README.md` — add to skills table

Files modified:
- `templates/AGENTS.md.template` — short note in skills section

Purpose: a lightweight authoring skill for the common case where a
developer has *one* bounded unit of work in mind and wants to ship it
without spinning up a BRD. Produces the same PBI artifact shape that
Phase 2's BRD→PBI flow will produce, so the two compose cleanly when
Phase 2 lands.

Argument shape:
```
/pbi "<description>" [--vet light|deep|ultra|none] [--brd-ref req-NNN[,req-MMM]] [--run]
```

Behavior:
1. **Read project context**: `AGENTS.md`/`CLAUDE.md`,
   `.claude/project.json` (modules array), `GOTCHAS.md` if present.
2. **Generate the PBI artifact** at `pbis/pbi-NNN.md` where `<NNN>`
   is a monotonic counter (highest existing PBI ID + 1; starts at 001).
   Frontmatter:
   ```yaml
   ---
   id: pbi-007
   title: "Short title from description"
   status: draft
   brd_refs: [req-001]   # empty if --brd-ref omitted; or the user-provided list
   modules: [api, web]    # inferred from description + project.json modules
   acceptance_criteria:
     - "User can do X"
     - "API responds with Y for input Z"
   files_likely_touched:
     - api/routes/orders.py
     - web/src/components/OrderForm.tsx
   ---
   ```
3. **Vet** (using the `--vet` mode resolution from B8' for `/brainstorm`):
   - Default: `none` for `<5` ACs (it's already bounded), `light` for
     `5–10` ACs, `deep` if the PBI touches >2 modules.
   - Same multi-agent shape as `/brainstorm --vet`: paths /
     completeness / gotchas, then optional Sonnet stress-test, then
     optional Opus architectural-coherence + edge-case-divergence.
4. **Write a plan file** at `plans/pbi-<NNN>-<slug>.md` derived from
   the PBI's ACs and files_likely_touched, in the same shape `/sdlc`
   already consumes today.
5. **If `--run`**: invoke `/sdlc plans/pbi-<NNN>-<slug>.md` immediately.
   Otherwise just print the PBI ID and plan path so the user can review
   before running.

Composition with Phase 2/3:
- Phase 2's `/pbi-decompose` produces the same `pbis/pbi-NNN.md`
  shape — the only difference is multiplicity (one PBI vs. N).
- Phase 3's `/sdlc --pbi pbi-NNN` reads the PBI's plan link from the
  PBI artifact, so `/pbi` and `/sdlc --pbi` work end-to-end the day
  Phase 3 lands.
- Until Phase 3, `/pbi --run` provides the same convenience by
  forwarding the resulting plan path to today's `/sdlc <plan>` form.

Why a separate skill (not a flag on `/brainstorm` or `/task`):
- `/brainstorm` is exploratory, multi-approach, full Plan-Mode flow.
- `/task` is single-row TASKS.md authoring, lighter than a PBI.
- `/pbi` is "I know what I want; produce a Phase-2-compatible PBI
  with vetting, ready for SDLC." That's a distinct mental model
  worth its own entry point.

---

## Acceptance Criteria

Phase 1 is done when **all** of these hold:

1. A consumer running `/sdlc <plan>` today gets the same PR with the
   same content as before. (Backward-compat smoke test.)
2. After a `/sdlc` run, `git status` is clean (state files are
   gitignored).
3. `/sdlc --inspect <slug>` returns the example output shape above for
   any prior run, without spawning agents.
4. `/sdlc <plan> --resume` correctly skips already-passed stages and
   resumes from the first non-passing one.
5. `/pbi "add a new orders endpoint" --vet light --run` produces a
   PBI file, a plan file, and a PR — end to end.
6. `setup.sh` adds `.claude/pipeline/` to consumer `.gitignore` if
   it's not already present, and does NOT touch any other gitignore
   entries.
7. `validate_skills.py` passes (now 21 skills with `/pbi` added).
8. `setup.sh` round-trip CI smoke (`scripts/ci/setup-roundtrip.sh`)
   passes both with and without `--no-copy-scripts`.
9. The new `--resume` and `--inspect` flags are documented in
   `skills/sdlc/SKILL.md`'s Arguments section.
10. Tier C item "round-trip CI asserts user docs preserved across
    `--force`" is added (came out of teacup install dogfood).
11. `setup.sh --profile core` (default) installs only core-tagged
    skills; `setup.sh --profile pipeline` installs only pipeline-tagged
    skills; `setup.sh --profile both` installs everything.
12. `setup.sh` with no `--profile` flag defaults to `core` and prints
    the chosen profile in its header so consumers know what they got.
13. Every skill has a `metadata.brainstorm-toolkit-profile` value in
    {`core`, `pipeline`, `both`}; `validate_skills.py` enforces this.
14. `BRAINSTORM-PIPELINE.md` documents the trigger conditions under
    which a future two-plugin split would be revisited.

---

## What's NOT in Phase 1

These belong to later phases. Calling them out so reviewers don't
mistake their absence for a gap.

- **BRD ingestion** (`/brd-ingest`, `requirements/brd-NNN.md`) — Phase 2.
- **Multi-PBI decomposition** (`/pbi-decompose`) — Phase 2.
  `/pbi` produces one PBI; `/pbi-decompose` produces many from a BRD.
- **Approval gates** (`approval.json`, `--approve-pbis`,
  `/approve`) — Phase 4.
- **Plan-vs-delivered scorecard** (extends Stage 5.5) — Phase 5.
- **Deploy / monitor / rollback skills** — Phase 6.
- **CI manifest export skill** — separate phase, depends on Phase 1
  state being stable. Could fold into Phase 6 or stand alone.
- **Worktree isolation for parallel implementers** — Tier C, depends
  on Phase 1.
- **Shared `context-cache.json` across sub-agents** — Tier C, depends
  on Phase 1.

---

## Open Questions

1. **`/pbi` ID counter source of truth**: file `pbis/.next-id` (small,
   simple) vs. computed each time from the highest existing PBI ID
   (no extra file, but slightly more work)? Recommend computed —
   one less file to gitignore-or-not-gitignore.

2. ~~`run.json.stage` naming~~ — **decided** in
   [`docs/CONVENTIONS.md`](CONVENTIONS.md): semantic kebab names
   (`parse`, `sanity-check`, `implement`, ...), never numeric.

3. **`--resume` after a toolkit upgrade**: if a stage's prompt changed
   between when the prior run executed it and the resume invocation,
   should we re-run that stage? Recommend: yes, re-run any stage whose
   prompt-template hash differs from the cached value in
   `stage-outputs/<stage>.json.prompt_hash`. Adds a small field per
   sidecar.

4. **`/pbi` vetting default**: should vetting be opt-in (`--vet none`
   default) or scope-promoted (today's `/brainstorm` model)? Recommend
   the same auto-promotion as `/brainstorm`'s B8' design — keeps the
   mental model consistent across skills.

5. **`.claude/pipeline/` cleanup**: should `/sdlc` clean up runs older
   than N days? Recommend: no, ever — local disk is cheap, and
   `--inspect` showing old runs is occasionally useful. A separate
   `/sdlc --prune` could land later if it becomes a real pain.

---

## Estimated effort

| Sub-phase | Effort | Blast radius |
|---|---|---|
| 1A — state envelope | 3 days | Touches every `/sdlc` stage; needs careful backward-compat tests |
| 1B — `--resume` | 2 days | Self-contained once 1A lands |
| 1C — `--inspect` | 1 day | Pure formatting; trivial |
| 1D — `/pbi` skill | 2 days | New skill, no existing-skill churn |
| 1E — profile filtering | 0.5 day | Touches every SKILL.md frontmatter (mechanical) + setup.sh |
| 1F — `/standardize` skill (+ onboarding handoff) | 2 days | New skill; modifies `/repo-onboarding` to emit a standards profile |
| 1G — skill naming collision decision | 0.1 – 2 days | Either docs-only (5 min) or full `-cc`/`-gh` rename (1.5–2 days) |
| **Total** | **~2 weeks** | Phase 1 unblocks Phases 2, 3, 5; lots of downstream value |

---

## 1F — `/standardize` skill (a.k.a. `/cleanup`)

**Status**: deferred, design open. A reminder routine fires 2026-05-10 to
revisit. Captured here so it isn't lost.

**Problem**: there is no skill that enforces or applies repo-specific
patterns once they're known. `/repo-health` *reports* drift, `/dead-code-review`
*finds* unused code, but nothing **applies** a consistent pattern (logging
discipline, error-handling shape, import order, naming, file layout) across
the codebase. Users either do it by hand or accumulate inconsistency.

**Proposed shape**:

- **`/standardize [--dry-run] [scope]`** — read a repo-local *standards
  profile* and apply or report on conformance. Scope can be a path, a glob,
  or a module name from `project.json`.
- **Standards profile lives at `.claude/standards.md`** (or a frontmatter
  block in `AGENTS.md` if the user prefers one file). Lists the patterns
  this repo follows: e.g. "all DB calls go through `db/` module", "loggers
  named `log = logging.getLogger(__name__)`", "no `print()` outside scripts".
- **`/repo-onboarding` writes the initial standards profile.** Onboarding
  already inspects the codebase to fill in `project.json` and AGENTS.md;
  it should also detect dominant patterns and propose a starter
  `standards.md` for the user to review/edit. This is the "know what to
  onboard" handoff the user called out — onboarding decides *what the
  standards are*, `/standardize` *applies them*.
- **Modes**:
  - `--dry-run` (default): list violations grouped by rule, with file:line.
  - apply mode: edit files in place, leave a TASKS.md entry summarizing.
- **Non-goals**: not a linter replacement (defer to ruff/eslint for syntax
  rules); not a refactorer (defer to AST tools); operates only on patterns
  that are too project-specific or too AI-judgement-shaped for those tools.

**Open design questions**:
1. Is the standards profile a single markdown file or a structured YAML?
   Markdown is more user-editable; YAML is more enforceable. Recommend
   markdown with a light structured header (rule id + scope + intent).
2. Should `/standardize` run as a `/sdlc` stage when changes touch a
   "standardized" area? Probably no — keep it explicit; auto-running risks
   surprise edits inside an `/sdlc` PR.
3. Where does `/dead-code-review` fit? It's already its own skill; leave
   it. `/standardize` is about *positive* patterns; `/dead-code-review`
   is about *removing* unused code. Different modes, can coexist.

---

## 1G — skill naming collision (Claude Code vs Copilot)

**Status**: open question, captured during 2026-04-26 dogfood. Decision
deferred pending evidence of a real misfire.

**Problem**: the toolkit installs identical skill names into
`.claude/skills/<name>/` and `.github/skills/<name>/`. When both runtimes
are active in the same VS Code workspace, the slash listing shows e.g.
`/brainstorm` twice with no indicator of which tool will dispatch it.

**Why it's open**: the dispatch is actually unambiguous — typing into the
Claude Code prompt routes to `.claude/`; typing into Copilot's chat routes
to `.github/`. The collision is purely *visual* (autocomplete dedup) and
only matters when both runtimes are concurrently active.

**Two options**:

- **Option A — documentation-only fix (~5 minutes)**: add a note to
  `AGENTS.md.template` clarifying that the slash command dispatches based
  on which prompt you typed it into, and that duplicate names in
  autocomplete are expected. Recommended unless evidence accumulates.
- **Option B — full rename to `-cc` / `-gh` suffixes (1.5–2 days)**:
  ~20 skills × SKILL.md updates, marketplace.json, validate_skills.py,
  README skills table, AGENTS.md.template skills list, every cross-skill
  reference (`/sdlc` mentions `/flowsim` etc.), and setup.sh tool-routing.
  Add ~½ day for an alias layer if back-compat is required (otherwise
  every consumer install breaks on update).

**Decision criteria for picking Option B over A**:
1. User reports a real misfire (running the wrong tool's skill), not just
   visual ambiguity.
2. Copilot's slash UI starts surfacing both `.claude/` and `.github/`
   skills in one combined menu.
3. A future toolkit feature genuinely needs distinct skill identities per
   tool (e.g., per-tool auto-update streams).

Until any of those, recommend Option A and close this item.

---

## Phase 1 status snapshot (2026-04-26)

| Sub-phase | Status | PR / location |
|---|---|---|
| 1A — state envelope | ✅ shipped | PR #2 merged |
| 1B — `/sdlc --resume` | ⏳ deferred | not started |
| 1C — `/sdlc --inspect` | ⏳ deferred | not started |
| 1D — `/pbi` skill | ⏳ deferred | not started |
| 1E — profile filtering | ⏳ deferred | not started |
| 1F — `/standardize` skill | ⏳ design open | reminder fires 2026-05-10 |
| 1G — naming collision | ⏳ decision pending | recommend Option A unless misfire reported |

Adjacent shipped work that informed Phase 1 (not part of the original
plan but worth noting here):

- Stop hook + `.claude/.next-action` sentinel (PR #3) — enables
  `/brainstorm → /sdlc` auto-handoff via `Next: /...` system message.
- `/cheatsheet` + `/repo-health` skills + CHEATSHEET.md (PR #4) —
  discovery + hygiene-sweep counterparts to the standardize/cleanup gap
  that 1F will fill.

---

## Provenance

This plan emerged from:
- The original 5-agent brainstorm (`docs/TIER-B-REVISION.md` and
  `BRAINSTORM-PIPELINE.md` Phase 1 description) which proposed the
  state envelope.
- A follow-up dogfood pass after the first real consumer-repo install
  (teacup). The teacup PR history (PRs #23–#25, the manual PR-A/B/C
  Sign-of-the-Day split) revealed that the multi-PR pattern is real
  and that the toolkit can support it once Phase 1 + Phase 3 land.
- The architectural concern raised during that dogfood ("going the
  Jenkins route changes plugin behavior — make sure local dev still
  works") which produced the 5 design rules above.
- The user-suggested addition of `/pbi <description>` for direct
  single-PBI authoring without a BRD.
- The user-suggested addition of `/sdlc --inspect <slug>` for
  human-readable run status.
