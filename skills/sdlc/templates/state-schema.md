# State Envelope Schema

`/sdlc` writes a transparent state journal under `.claude/pipeline/<feature-slug>/` as it runs. This file documents the on-disk shape so consumers (orchestrators, dashboards, the future `/sdlc --resume` and `/sdlc --inspect`) can read it without inventing their own contract.

**Status**: schema_version 1. Backward-compatible field additions are allowed without bumping the version; field renames or removals require a version bump.

**Design rules** (from `docs/PHASE-1-STATE-ENVELOPE.md`):

1. State is a transparent **side-effect**, never a contract. No skill is required to read these files; they're available for those that want to.
2. State writes are **best-effort**. If the disk is full or the directory is unwritable, `/sdlc` logs a warning and continues. State writes never fail a pipeline run.
3. State is **gitignored**. `setup.sh` ensures consumers' `.gitignore` lists `.claude/pipeline/`.

---

## Directory layout

```
.claude/pipeline/<feature-slug>/
  run.json
  stage-outputs/
    parse.json
    sanity-check.json
    implement.json
    generate-evals.json
    eval-fix.json
    validate.json
    plan-validate.json
    flowsim.json
    secret-scan.json
    pr-create.json
```

Stage filenames use the **canonical kebab names** from `docs/CONVENTIONS.md` "Stage names" — `parse`, `sanity-check`, `implement`, `generate-evals`, `eval-fix`, `validate`, `plan-validate`, `flowsim`, `secret-scan`, `pr-create`. Never decimal-versioned (no `stage-1.5.json`).

In `--skill-repo` mode, the skipped stages (`generate-evals`, `eval-fix`, `validate`, `plan-validate`, `flowsim`) write **no sidecar**. `validate.json` is replaced by a skill-repo-shaped sidecar that records the structural-check results from `templates/stage-5-skill-repo.md`.

---

## `run.json` — the top-level run record

Updated whenever the pipeline transitions stages. Always reflects the *current* state of the run.

```json
{
  "schema_version": 1,
  "feature_slug": "add-orders",
  "plan_file": "plans/brainstorm-add-orders.md",
  "plan_hash": "sha256:<hex>",
  "args": {
    "dry_run": false,
    "skip_eval": false,
    "skip_flowsim": false,
    "max_fix_loops": 3,
    "skill_repo": false,
    "background": false
  },
  "started_at": "2026-04-26T10:00:00Z",
  "updated_at": "2026-04-26T10:08:23Z",
  "stage": "plan-validate",
  "status": "in_progress",
  "stages_completed": ["parse", "sanity-check", "implement", "generate-evals", "eval-fix", "validate"],
  "stages_skipped": []
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `schema_version` | int | yes | Currently `1`. Bumped only on breaking change. |
| `feature_slug` | string | yes | Derived from plan filename per CONVENTIONS.md slug-derivation. RFC 1123-compliant. |
| `plan_file` | string | yes | Path relative to repo root, as passed to `/sdlc`. |
| `plan_hash` | string | yes | `sha256:<hex>` of the plan file's contents at Stage 1. Lets a future `--resume` detect plan edits. |
| `args` | object | yes | Snapshot of CLI args. Snake_case keys. Boolean flags appear here even when `false`, so resumers don't have to assume defaults. |
| `started_at` | ISO 8601 string | yes | UTC, second precision. |
| `updated_at` | ISO 8601 string | yes | Refreshed on every stage transition. |
| `stage` | string | yes | Canonical kebab name of the *current* stage. On terminal states, holds the last attempted stage. |
| `status` | enum | yes | One of `in_progress`, `complete`, `failed`, `paused`. `paused` means the pipeline stopped and `--resume` would pick it up. |
| `stages_completed` | string array | yes | In execution order. Each name appears once. A stage is "completed" when its sidecar's status is `pass`. |
| `stages_skipped` | string array | yes | Stages explicitly skipped (e.g., `--skip-eval`, `--skill-repo` skips, `--skip-flowsim`). Distinct from "not yet run." |

---

## `stage-outputs/<stage>.json` — per-stage sidecars

Written when a stage finishes (or pauses, or fails). One file per stage; the stage filename matches the stage name.

```json
{
  "schema_version": 1,
  "stage": "sanity-check",
  "status": "pass",
  "started_at": "2026-04-26T10:00:05Z",
  "ended_at": "2026-04-26T10:00:33Z",
  "summary": "3 agents OK; 0 issues",
  "prompt_hash": "sha256:<hex>",
  "data": { ... stage-specific ... }
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `schema_version` | int | yes | Currently `1`. |
| `stage` | string | yes | Canonical kebab name. Must match the filename. |
| `status` | enum | yes | One of `pass`, `fail`, `paused`. `pass` means the stage completed and the pipeline may proceed. `fail` is terminal. `paused` means human intervention needed. |
| `started_at` / `ended_at` | ISO 8601 strings | yes | UTC, second precision. |
| `summary` | string | yes | One-line human summary suitable for `--inspect`. |
| `prompt_hash` | string | optional | `sha256:<hex>` of the SKILL.md prompt template that drove this stage. Lets `--resume` detect toolkit upgrades that changed how a stage runs (per Open Question #3 in the plan: re-run any stage whose `prompt_hash` differs from the cached value). |
| `data` | object | yes | Stage-specific payload. May be `{}` for stages with no structured output. Shape per stage below. |

### Per-stage `data` shapes

Below is the shape each stage's `data` field is expected to take. These are the contracts `--resume` and `--inspect` will rely on; new keys are additive and safe.

#### `parse`
```json
{
  "feature_name": "Add Orders Endpoint",
  "files_to_change": ["api/routes/orders.py", "..."],
  "implementation_step_count": 6,
  "acceptance_criteria_count": 4
}
```

#### `sanity-check`
```json
{
  "agents": [
    { "focus": "paths",        "status": "pass", "issue_count": 0 },
    { "focus": "completeness", "status": "warn", "issue_count": 1 },
    { "focus": "gotchas",      "status": "pass", "issue_count": 0 }
  ],
  "auto_patched": false,
  "issues": []
}
```

#### `implement`
```json
{
  "agent_model": "claude-opus-4-6",
  "files_changed": [
    { "path": "api/routes/orders.py", "added": 42, "removed": 0 },
    { "path": "api/schemas/order.py", "added": 18, "removed": 0 }
  ],
  "total_added": 60,
  "total_removed": 0,
  "blockers_reported": []
}
```

#### `generate-evals`
```json
{
  "evals_created": [
    "tests/eval/test_add_orders_eval.py",
    "tests/eval/features/add-orders/fixtures/happy.json"
  ],
  "skipped_reason": null
}
```

#### `eval-fix`
```json
{
  "fix_loops_run": 2,
  "max_fix_loops": 3,
  "final_pass_count": 8,
  "final_fail_count": 0,
  "remaining_failures": []
}
```

#### `validate` (standard mode)
```json
{
  "layers": {
    "logs":     { "status": "pass" },
    "frontend": { "status": "skip", "reason": "no frontend files changed" },
    "backend":  { "status": "pass", "tests_run": 142, "tests_failed": 0 },
    "e2e":      { "status": "skip", "reason": "test.e2e not configured" },
    "eval":     { "status": "pass" }
  },
  "new_failures": [],
  "preexisting_failures": []
}
```

#### `validate` (skill-repo mode — replaces standard layers)
```json
{
  "mode": "skill-repo",
  "checks": {
    "validate_skills":            { "status": "pass" },
    "marketplace_registration":   { "status": "pass" },
    "template_reference_resolve": { "status": "pass" },
    "setup_sh_dry_install":       { "status": "pass" }
  },
  "soft_checks": {
    "line_count_ceiling":  { "status": "pass" },
    "readme_skills_table": { "status": "pass" },
    "copilot_overlay_parity": { "status": "n/a" }
  }
}
```

#### `plan-validate`
```json
{
  "validators_launched": ["api", "ui", "data", "cross-module"],
  "validators_skipped":  [],
  "totals": { "checks": 12, "passed": 12, "failed": 0 },
  "failures": []
}
```

#### `flowsim`
```json
{
  "report_path": "plans/flowsim-add-orders.md",
  "json_path":   "plans/flowsim-add-orders.json",
  "flow_count": 4,
  "mismatches": 0,
  "unclear": 1,
  "missing": 0
}
```

#### `secret-scan`
```json
{
  "tool": "gitleaks",
  "files_scanned": ["api/routes/orders.py", "api/schemas/order.py"],
  "high_findings": 0,
  "medium_findings": 0
}
```

#### `pr-create`
```json
{
  "branch": "sdlc/add-orders",
  "pr_url": "https://github.com/org/repo/pull/42",
  "pr_number": 42,
  "commit_sha": "abc1234"
}
```

---

## Lifecycle

1. **Stage 1 (`parse`)**: `/sdlc` `mkdir -p .claude/pipeline/<slug>/stage-outputs/`, then writes initial `run.json` with `stage: "parse"`, `status: "in_progress"`, captures `args` and `plan_hash`. On Stage 1 completion, writes `stage-outputs/parse.json`.
2. **Subsequent stages**: when a stage starts, `run.json.stage` and `run.json.updated_at` are updated. When the stage finishes, its sidecar is written and `run.json.stages_completed` is appended.
3. **Skipped stages** (e.g., `--skill-repo` skips `generate-evals`): added to `run.json.stages_skipped`; no sidecar is written.
4. **Terminal states**:
   - All stages pass → `run.json.status = "complete"`.
   - Unrecoverable failure → `run.json.status = "failed"`; the failing stage's sidecar has `status: "fail"`.
   - Pause for human review (eval max-loops, plan-validate failure persists) → `run.json.status = "paused"`.
5. **Re-running `/sdlc <plan>`** (without `--resume`): overwrites the prior `run.json` and `stage-outputs/` for the same slug. Slug-collision policy (different plan files deriving the same slug) is deferred to a later phase per `docs/CONVENTIONS.md` open questions; current behavior is overwrite.

## Best-effort failure mode

If `mkdir -p`, `chmod`, or any state-write fails (disk full, read-only volume, permissions), `/sdlc` logs a single-line warning to stderr (`[state-envelope] write failed: <error>; continuing`) and proceeds with the pipeline. **State writes never fail a pipeline run.** The pipeline run can still produce a PR even if state was never persisted.

## What does NOT live here

- **Plan files**: stay in `plans/` (or wherever the user passes them); `run.json.plan_file` points to them.
- **`/flowsim` JSON**: `plans/flowsim-<slug>.json` remains the canonical location for `/flowsim`'s structured output. `stage-outputs/flowsim.json` is a *summary* sidecar, not a duplicate.
- **PBI / BRD artifacts**: `pbis/pbi-NNN.md`, `requirements/brd-NNN.md` (Phase 2/3). Run state may *reference* these by ID but never copies them.
- **Delivery artifacts** (Phase 5+): `delivery/pbi-NNN.json` is for stakeholder-readable, persistent reports. `.claude/pipeline/` is ephemeral local state only.
