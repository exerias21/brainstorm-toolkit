# Naming Conventions

**Status**: canonical. New skills, artifacts, and flags follow these rules. See "Migration Policy" for how existing inconsistencies are handled.

**Drafted**: 2026-04-25, dogfooded `/brainstorm` (4 lens agents in parallel — first principles, inversion, cross-domain k8s, constraint removal). See "Provenance" at the bottom.

**Pre-requisite for**: Phase 1 (state envelope, `/pbi`, `/sdlc --inspect`, `/sdlc --resume`, profile filtering) and every phase after.

---

## Goals

1. **Prevent real bugs.** Conventions exist to defend against silent failures (case-sensitive path lookups breaking on Linux CI, decimal stage numbers sorting incorrectly, ID prefix collisions, JSON key drift between skills). Aesthetic consistency is a side-effect, not the goal.
2. **Stay enforceable.** Anything in this doc must be lintable by `validate_skills.py`. Conventions that can't be checked rot.
3. **Be incremental.** New artifacts follow the standard from day one. Existing artifacts migrate when their skill is touched anyway. We don't churn for cosmetics.

---

## The two-axis split (identity vs metadata)

Lifted from Kubernetes RFC 1123 + label/annotation discipline. The k8s lesson:

- **Identity** = anything machine-parsed: looked up by path, used as a primary key, embedded in URLs, regex-matched. Strict rules. No room for variation.
- **Metadata** = anything queryable but not identity: descriptive frontmatter, JSON config keys, freeform annotations. Looser rules; namespaced extensions allowed.

**Identity** in brainstorm-toolkit: skill names, stage names, artifact IDs, file/directory paths, command-line flags.

**Metadata** in brainstorm-toolkit: SKILL.md frontmatter values, `project.json` keys, in-prose descriptions, template substitution variables.

Apply different strictness to each.

---

## Identity rules (strict)

All identity-form names match this regex:

```
^[a-z0-9]([a-z0-9-]*[a-z0-9])?$
```

Translation: lowercase letters and digits only, hyphens allowed only in the middle (not as first or last char), single-character names allowed.

This is RFC 1123 — the same rule Kubernetes enforces on every Pod, Service, and CRD. Filesystem-safe across Linux/macOS/Windows. Greppable. Sortable.

### Skill names

Form: lowercase-kebab matching the skill's directory and frontmatter `name`.

```
skills/<name>/SKILL.md   # name in frontmatter == directory name == slash-command
```

Examples (all current skills already comply):
- `brainstorm`, `sdlc`, `task`, `status`, `gotcha`, `flowsim` — single-token
- `repo-onboarding`, `test-check`, `e2e-loop`, `eval-harness`, `dead-code-review`, `data-source-pattern`, `logging-conventions`, `post-deploy-verify`, `brainstorm-team` — multi-token kebab

Future Phase-1+ skills: `pbi`, `brd-ingest`, `pbi-decompose`, `approve`, `deploy`, `monitor`, `rollback`, `coverage`. All compliant.

### Stage names

Form: lowercase-kebab semantic verb or verb-phrase. **Never decimal-versioned.**

Use these names in `run.json.stage` and `stage-outputs/<name>.json`:

```
parse              # Stage 1
sanity-check       # Stage 1.5
implement          # Stage 2
generate-evals     # Stage 3
eval-fix           # Stage 4
validate           # Stage 5 (test suite)
plan-validate      # Stage 5.5 (api/ui/data validators)
flowsim            # Stage 5.6
secret-scan        # Stage 6 step 2
pr-create          # Stage 6 step 3
report             # Stage 7
```

Human-facing prose in `SKILL.md` may continue using "Stage 1.5" labels for cognitive clarity, but the **machine-readable name** in JSON sidecars and run state is always the semantic kebab form.

**Why not zero-padded integers** (`01-parse`, `02-sanity-check`)? Because future stage insertions force renumbering of every stage after the insertion point — same fragility as decimals, just shifted. Semantic names are stable.

**Ordering** of stages lives in an explicit array in `run.json` or the SKILL.md, not in the names.

### Artifact IDs

Form: lowercase 2-to-4-letter prefix + hyphen + zero-padded 3-digit sequence (overflows naturally to 4+ digits).

| Type | Prefix | Examples |
|---|---|---|
| Task | `task` | `task-001`, `task-042`, `task-1337` |
| PBI | `pbi` | `pbi-001`, `pbi-007` |
| BRD | `brd` | `brd-001` |
| Requirement | `req` | `req-001`, `req-014` |
| SonarQube issue | `sonar` | `sonar-122` (3-letter prefix to prevent future collision) |

Rules:
- **Prefix is at least 2 characters.** Single-letter prefixes (`t-1`) collide with future ID types.
- **Zero-padded to at least 3 digits.** Stable alphabetic sort: `pbi-001`, `pbi-009`, `pbi-010` sort correctly; `pbi-1`, `pbi-9`, `pbi-10` do not.
- **Lowercase prefix.** Mixed-case (`PBI-007` vs `pbi-007`) creates two IDs for the same thing.
- **Padding overflow is fine.** `pbi-1000` is still sortable against `pbi-001` because Python/grep/git all sort by codepoint.

### File and directory paths

Form: lowercase-kebab segments, each segment matching the RFC 1123 regex.

| Path | Role | Tracked? |
|---|---|---|
| `requirements/brd-001.md` | Human-authored input specs (BRDs) | Yes |
| `pbis/pbi-001.md` | PBI artifacts (frontmatter + acceptance criteria — the "what") | Yes |
| `plans/brainstorm-<slug>.md` | Implementation plans (the "how" — from `/brainstorm`, `/pbi`, `/pbi-decompose`) | Per-repo (gitignored on plugin repo, often tracked on consumers) |
| `plans/tasks/task-001.md` | Task plan stubs | Same as `plans/` |
| `delivery/pbi-001.json` | Machine-generated, persistent artifacts (delivery manifests, BRD-coverage reports, post-deploy verification matrices) | Yes |
| `delivery/post-deploy-<env>-<timestamp>.json` | Post-deploy verification results | Yes |
| `.claude/pipeline/<slug>/` | Machine-generated, ephemeral state (per-run state envelope) | No (always gitignored) |

Persistence rule: stakeholders read `delivery/`; only `--resume` and post-mortem tooling reads `.claude/pipeline/`.

**Filenames inside identity paths are also lowercase-kebab.** No `Plans/`, no `pbi_001.md`, no `BRD-001.md`.

**One canonical role per directory — exclusivity is enforced.** A given artifact type lives in exactly one directory; cross-storage is forbidden. Concretely:
- BRDs live in `requirements/` and *only* `requirements/`. A BRD in `plans/` is a bug.
- PBIs live in `pbis/` and only `pbis/`. A PBI front-matter file in `plans/tasks/` is a bug.
- Post-deploy results live in `delivery/` and only `delivery/`. A `plans/post-deploy-*.json` is a bug.
- Run state lives in `.claude/pipeline/` and only `.claude/pipeline/`. A run.json in `delivery/` is a bug.

Rationale: state-envelope code stores paths and looks them up. Two homes for one concept = one of them is silently stale, and `--resume` picks the wrong one.

### Slug derivation

Every identity-form slug used by `/sdlc`, `/pbi`, branch naming, and pipeline state is derived deterministically from the source plan file. Same input → same slug, every time, on every OS.

Algorithm:
1. Start with the plan filename minus its extension (e.g., `plans/brainstorm-add-orders.md` → `brainstorm-add-orders`).
2. Strip the leading well-known prefix if present (`brainstorm-`, `team-brainstorm-`, `pbi-NNN-`, `task-NNN-`) → `add-orders`.
3. Lowercase. Replace any character not in `[a-z0-9-]` with `-`. Collapse runs of `-`. Trim leading/trailing `-`.
4. Result must match the identity regex `^[a-z0-9]([a-z0-9-]*[a-z0-9])?$`. If it doesn't (e.g., the plan filename was empty or all-symbols), the slug derivation FAILS and the calling skill stops with a clear error.

This is mechanical, predictable, and case-insensitive — the latter critical because case-mismatched slugs ("AddOrders" vs "addorders") are the exact bug the lowercase-FS rule defends against.

### Command-line flags

Form: lowercase-kebab. Specific patterns:

- **Boolean negation**: `--no-X` (e.g., `--no-eval`, `--no-flowsim`). Existing `--skip-X` flags continue to work as aliases (back-compat); `--no-X` is the canonical form going forward.
- **Boolean positive**: bare `--X` (e.g., `--force`, `--background`, `--dry-run`).
- **Numeric limits**: `--max-X` or `--min-X` (e.g., `--max-fix-loops`, `--max-hops`).
- **Modes / enums**: `--X <value>` (e.g., `--vet light`, `--profile core`, `--tools both`).
- **Targeted runs**: `--X <id>` (e.g., `--pbi pbi-007`, `--sonar sonar-122`, `--inspect <slug>`).

---

## Metadata rules (looser, namespaced)

### Skill frontmatter

YAML frontmatter at the top of every `SKILL.md`. Keys follow these rules:

- **Top-level keys**: `name`, `description`, `argument-hint`, `metadata`, `disable-model-invocation` (Copilot-specific). These are Claude Code / Copilot ecosystem keys; don't rename.
- **Toolkit-scoped extensions** live under `metadata` with prefix `brainstorm-toolkit-`. Pattern: `metadata.brainstorm-toolkit-<scope>: <value>`.
  - `metadata.brainstorm-toolkit-applies-to: claude | copilot | claude copilot`
  - `metadata.brainstorm-toolkit-profile: core | pipeline | both`
  - Future toolkit-scoped keys follow this pattern.
- **Values for enum keys are lowercase-kebab** matching the identity rule (because they're effectively identifiers — looked up in `setup.sh` filtering logic).

### `project.json` keys

Form: snake_case (lowercase, underscore separator).

This intentionally diverges from CLI flag kebab-case because:
- `project.json` is JSON, not CLI. JSON ecosystem (linters, schemas, JS access via `cfg.eval_runner`) prefers underscores.
- All existing keys are already snake_case (`e2e_max_fix_loops`, `gotchas_file`, `main_branch`). Migrating would break consumers for no benefit.

Convention:
- Top-level keys: `test`, `logs`, `eval`, `gotchas_file`, `main_branch`, `modules`, `pipeline`.
- Nested keys: also snake_case (`eval.thresholds.min_pass_rate`, `pipeline.skip_secret_scan`).
- **Leading underscore for "metadata-not-config"**: `_comment`, `_runner_options`, `_thresholds_comment` are documentation strings the runner ignores. Pattern in use; codify it.

### Stage-output JSON keys

Form: snake_case (matches `project.json` ecosystem).

```json
{
  "status": "pass",
  "summary": "3 agents OK",
  "started_at": "2026-04-25T10:00:00Z",
  "ended_at": "2026-04-25T10:00:28Z",
  "data": {
    "agent_results": [...]
  }
}
```

### Template substitution variables

Form: `{snake_case}` curly-brace placeholders.

Why this differs from identity rules: template variables are NOT identifiers in the system. They're substitution syntax in a templating language, like Helm's `.Values.fooBar` or Jinja's `{{ var }}`. Different layer, different rule.

```
{feature_name}, {plan_file}, {feature_slug}, {results_json}, {file_paths}
```

---

## Filename conventions (ecosystem-respecting exceptions)

Some filenames must follow external ecosystem conventions, not RFC 1123. These exceptions are explicit and finite:

| File | Form | Why exception |
|---|---|---|
| `SKILL.md` | UPPERCASE | Claude Code skill spec; required form |
| `AGENTS.md`, `CLAUDE.md`, `TASKS.md`, `GOTCHAS.md`, `README.md`, `LICENSE` | UPPERCASE | Markdown ecosystem convention for top-level project docs; recognized by GitHub UI, agent SDKs, IDEs |
| Design docs in `docs/` (e.g., `CONVENTIONS.md`, `BRAINSTORM-PIPELINE.md`, `TIER-B-REVISION.md`, `PHASE-1-STATE-ENVELOPE.md`) | UPPERCASE-KEBAB | Project convention for design docs; visually distinguishes from runtime artifacts |
| Skill bundled resources (e.g., `skills/sdlc/templates/stage-2-implement.md`) | lowercase-kebab | Identity (Loaded by skill at runtime via path lookup) |

The rule: **identity paths are RFC 1123; doc filenames follow ecosystem.** When in doubt, ask: "is this file looked up by a tool, or read by a human?" Tool lookup → identity rules. Human reading → ecosystem.

---

## Migration policy

**Skill names**: NO renames, NO aliases. All current skill names already comply with RFC 1123 (the audit found zero non-compliant skills). The earlier flagged `/gotcha vs GOTCHAS.md` was a false alarm — the skill operates on the file; they correctly follow different conventions.

**Artifact IDs**: aliases supported indefinitely. `task-N` (legacy, no padding) is recognized as equivalent to `task-NNN` by any code that resolves task IDs. New artifacts use the canonical zero-padded form. No batch migration.

**Flags**: aliases supported indefinitely. `--skip-eval` continues to work; `--no-eval` is the canonical form. Help text shows both with `--no-X` first.

**Paths**: forward-only. New artifacts land in canonical directories. Existing artifacts in old layouts stay where they are — moving them would break references in tracked plan files.

**Frontmatter**: forward-only. `metadata.brainstorm-toolkit-applies-to` (current) is canonical. Legacy top-level `applies-to` continues to work in `setup.sh` (already documented in code) but is deprecated.

**Stages**: opt-in. Existing skills using "Stage 1.5" prose remain. New skills, plus the run.json schema in Phase 1, use semantic names. Conversions of existing skills happen when those skills are edited for other reasons.

The principle: **conventions defend against future bugs; they don't justify retroactive churn.**

---

## Enforcement (`validate_skills.py` lints)

The standard is enforceable, not just documented. `validate_skills.py` grows these checks as Phase 1 1B/1C/1E land:

| Lint | Severity | What it catches |
|---|---|---|
| Skill name matches `^[a-z0-9]([a-z0-9-]*[a-z0-9])?$` | error | Filesystem-portability bug across Linux/macOS/Windows |
| Skill `name` in frontmatter == directory basename | error | Setup.sh routing miss |
| `metadata.brainstorm-toolkit-applies-to` present and ∈ {`claude`, `copilot`, `claude copilot`} | error | Tool routing bug |
| `metadata.brainstorm-toolkit-profile` present and ∈ {`core`, `pipeline`, `both`} | error (after Phase 1 1E lands) | Profile filter bug |
| Bundled resource references in SKILL.md prose resolve to real files | error | Broken `templates/` references |
| Marketplace.json registers every skill in `skills/*/` | error | Unregistered skill won't ship |
| `project.json` keys are snake_case | warning | Drift watch |
| Flag examples in argument-hint follow `--no-X` for negation | warning | Drift watch |
| Consumer `.gitignore` contains `.claude/pipeline/` after `setup.sh` runs | error (after Phase 1 1A lands) | Run-state leakage into version control |
| Slug derivation matches the algorithm in this doc (single Python helper, used by every consumer) | error | Cross-OS case-mismatch bugs |
| Identity paths contain no uppercase characters | error | Linux/macOS portability |
| Stage names in `run.json` and `stage-outputs/*.json` filenames match `^[a-z0-9]([a-z0-9-]*[a-z0-9])?$` | error (after Phase 1 1A lands) | Sort-order and lookup bugs |

Errors block CI; warnings show up in the report and accumulate. After Phase 1 ships, warnings can graduate to errors with a deprecation window.

---

## The four MVP rules (load-bearing for Phase 1)

If only four conventions ever stick, these are the four. They're load-bearing because Phase 1's state envelope reads or writes them:

1. **Skill names match RFC 1123 + are identical to their directory + match `name` in frontmatter.** State envelope keys runs by skill name.
2. **Stage names are semantic lowercase-kebab, never decimal-versioned.** Used as `run.json.stage` and `stage-outputs/<name>.json` filenames; sort and lookup must be stable.
3. **Artifact IDs are lowercase 2-to-4-letter prefix + zero-padded sequence.** `--resume` and `--inspect` look up runs and PBIs by ID; mixed-case or unpadded IDs cause silent mis-matches.
4. **One canonical role per directory** (`requirements/`, `pbis/`, `plans/`, `delivery/`, `.claude/pipeline/`). State envelope stores paths; two homes for one concept = silent corruption.

The other rules in this doc (frontmatter, JSON keys, template vars, flag negation) are quality-of-life. The four above are correctness.

---

## Decided (settled by this doc)

These were "open" in earlier drafts; the brainstorm + validator pass closed them. Recorded here so future readers don't reopen them as bikeshedding.

- **Empty-state for ID counters** — fresh repos start at `<prefix>-001` (e.g., `task-001`, `pbi-001`). Repos with legacy `task-N` rows continue working; new artifacts use the canonical zero-padded form.
- **Multi-word identifiers in the same prefix family** — no sub-IDs (`pbi-007a` / `pbi-007-1` are forbidden). PBIs don't subdivide. If you need more granularity, decompose into multiple PBIs (`pbi-008`, `pbi-009`).
- **Phase-2 / Phase-6 skill names** (`/brd-ingest`, `/pbi-decompose`, `/approve`, `/deploy`, `/monitor`, `/rollback`, `/coverage`) — locked as canonical. All comply with the identity rule. No bikeshedding when these are built.
- **Stage naming in `run.json`** — semantic kebab (`parse`, `sanity-check`, `implement`...), never decimals. Settled in this doc, supersedes any earlier "open question" framing in `PHASE-1-STATE-ENVELOPE.md`.

## Open questions

These remain genuinely unresolved but are non-blocking:

1. **`/sdlc` argument-hint syntax**: standardize how flags are documented in argument-hint strings. Today some show `[--vet light|deep|ultra|none]` (pipe-separated) and others show `[--profile <core|pipeline|both>]` (angle-brackets + pipe). Pick one before Phase 1 1E ships.

2. **Slug-collision policy**: if two `/sdlc` runs derive the same slug (e.g., a user runs `/sdlc plans/brainstorm-feature.md` twice in different working trees), should the second invocation auto-append a suffix (`feature-2`), error out, or silently overwrite? Recommend: error out unless `--force-slug` is passed. Lock before Phase 1 1A ships.

---

## Provenance

This document is the output of a dogfooded `/brainstorm` session on 2026-04-25, run on the brainstorm-toolkit repo itself. Four lens agents (First Principles, Inversion, Cross-Domain Analogy, Constraint Removal) ran in parallel to stress-test the convention proposals before drafting.

**Key insights that shaped the doc**:

- **First Principles** identified four load-bearing axes (IDs, stages, paths, skill names) and explicitly deferred four cosmetic ones (flag prefixes, casing of unrelated files, template vars, JSON key style). The "MVP rules" section above is this finding distilled.
- **Inversion** ranked conventions by blast radius. The lowercase-FS rule and decimal-stage rule are in the "errors" tier of `validate_skills.py` lints because of this lens — they cause real bugs that hide locally and bite in CI.
- **Cross-Domain Analogy (Kubernetes RFC 1123)** contributed the **identity vs metadata split**. Without it, this doc would over-constrain frontmatter (which benefits from namespaced extensibility) or under-constrain skill names (which must be filesystem-safe across all major OSes).
- **Constraint Removal** revealed that the standard is **mostly descriptive, not prescriptive** — most existing skills already comply. The "Migration policy" section is shaped by this finding: don't churn what already works; just write down the rule that codifies it. Specifically caught my false-positive recommendation to rename `/gotcha → /gotchas` (the skill doesn't need renaming; it already complies).

**Productive disagreement**: Cross-Domain proposed migrating frontmatter from `brainstorm-toolkit-applies-to` to k8s-style `brainstorm-toolkit/applies-to`. Constraint Removal correctly noted this would force a migration with no functional benefit (YAML parses both, downstream tooling already works). Resolution: adopt the *philosophy* of identity-vs-metadata (the load-bearing insight) without changing the wire format (cosmetic).

**One false-positive corrected**: my pre-brainstorm audit flagged `/gotcha vs /gotchas` as an inconsistency. The skill is the *action* (identify gotchas); `GOTCHAS.md` is the *collection*. Two different conventions, both correct. No rename needed.

**Phase 1 dependency**: this document is a prerequisite for Phase 1 implementation. Sub-deliverable 1A (state envelope) reads stage names; 1B (`--resume`) keys on artifact IDs; 1D (`/pbi`) writes to `pbis/`; 1E (profile filtering) reads frontmatter `metadata.brainstorm-toolkit-profile`. All four depend on the rules above being settled.
