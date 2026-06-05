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
    decompose.json          # Stage 2a — only when the gate fans out
    implement.json          # single-agent path
    implement-<lane>.json   # one per lane — only when decomposed
    converge.json           # Stage 2c — only when decomposed
    generate-evals.json
    eval-fix.json
    validate.json
    plan-validate.json
    flowsim.json
    secret-scan.json
    pr-create.json
```

Stage filenames use the **canonical kebab names** from `docs/CONVENTIONS.md` "Stage names" — `parse`, `sanity-check`, `decompose`, `implement`, `implement-<lane>`, `converge`, `generate-evals`, `eval-fix`, `validate`, `plan-validate`, `flowsim`, `secret-scan`, `pr-create`. Never decimal-versioned (no `stage-1.5.json`).

The Stage 2 sidecars are **mutually exclusive by path**: the single-agent path writes only `implement.json`; the decomposed path (Stage 2 gate fans out) writes `decompose.json`, one `implement-<lane>.json` per lane, and `converge.json`, and never writes `implement.json`. A run that never decomposes is byte-for-byte unchanged from the pre-decomposition envelope.

In skill-repo mode (auto-detected from `.claude-plugin/marketplace.json` at repo root), the skipped stages (`generate-evals`, `eval-fix`, `plan-validate`, `flowsim`) write **no sidecar**. `stage-outputs/validate.json` is still written in skill-repo mode, but as a skill-repo-shaped sidecar that records the structural-check results from `templates/stage-5-skill-repo.md`; in that case `data.mode = "skill-repo"`.

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
    "skill_repo": false
  },
  "pipeline": "sdlc",
  "base_commit": "abc1234",
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
| `args` | object | yes | Snapshot of run-time decisions. Snake_case keys. `/sdlc` is zero-flag — the only field currently recorded is `skill_repo` (auto-detected from `.claude-plugin/marketplace.json` presence at repo root). New additive fields are allowed. |
| `pipeline` | string | optional | Which skill wrote this run: `sdlc`, `sdlc-lite`, or `task`. Absent ⇒ assume `sdlc` (back-compat). Lets `/status`, `/repo-health`, and the Stop hook distinguish run types. |
| `base_commit` | string | optional | `git rev-parse HEAD` captured at Stage 1, before any implementation commit. Powers **continuity detection** (is this branch's prior run an ancestor of HEAD?) and **reconciliation** (an `in_progress` run whose `base_commit` is already an ancestor of HEAD was almost certainly committed outside the pipeline). Additive; absent on older runs. |
| `started_at` | ISO 8601 string | yes | UTC, second precision. |
| `updated_at` | ISO 8601 string | yes | Refreshed on every stage transition. |
| `stage` | string | yes | Canonical kebab name of the *current* stage. On terminal states, holds the last attempted stage. |
| `status` | enum | yes | One of `in_progress`, `complete`, `failed`, `paused`. `paused` means the pipeline stopped and `--resume` would pick it up. |
| `stages_completed` | string array | yes | In execution order. Each name appears once. A stage is "completed" when its sidecar's status is `pass`. |
| `stages_skipped` | string array | yes | Stages explicitly skipped (e.g., stages skipped because their config was absent, or skill-repo-mode skips). Distinct from "not yet run." |
| `data.stage2_decomposed` | bool | optional | Set at Stage 2a. `true` when the gate fanned Stage 2 into per-lane subagents; `false` (or absent) for the single-agent path. Absent on runs written before this field existed. |
| `data.lanes` | string array | optional | Lane names from Stage 2a (e.g. `["data", "backend", "frontend"]`), in dependency dispatch order. `[]` when not decomposed. |

---

## `stage-outputs/<stage>.json` — per-stage sidecars

Written when a stage finishes (or pauses, or fails). One file is written per stage that emits a sidecar; the stage filename matches the stage name. `report` is an exception and does not write a sidecar.

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

#### `decompose` (Stage 2a — only when the gate fans out)
```json
{
  "gate_inputs": {
    "surfaces_touched": ["data", "backend", "frontend"],
    "surface_count": 3,
    "task_count": 15,
    "decompose_min_tasks": 6,
    "files_disjoint": true
  },
  "gate_decision": "decompose",
  "lanes": [
    {
      "lane": "data",
      "files": ["migrations/0007_orders.sql", "models/order.py"],
      "steps": ["add orders table", "add Order model"],
      "depends_on": [],
      "model": "sonnet",
      "contract": "Order(id, user_id, total_cents, status); table `orders` with index on (user_id, status)."
    },
    {
      "lane": "backend",
      "files": ["api/routes/orders.py", "api/schemas/order.py"],
      "steps": ["POST /orders", "GET /orders/{id}"],
      "depends_on": ["data"],
      "model": "sonnet",
      "contract": "POST /orders -> 201 {id}; GET /orders/{id} -> 200 OrderOut. Uses Order model from the data lane."
    }
  ]
}
```
`gate_decision` is `decompose` or `single-agent`. When `single-agent`, no
`decompose.json` is written at all — the gate inputs that produced a
no-decompose decision are still summarized in the `implement.json` `summary`.
Each lane's `model` is `sonnet` (default) or `opus` (lane flagged
high-complexity in 2a). `depends_on` lists lane names that must complete first;
2b dispatches in a dependency-respecting order.

#### `implement-<lane>` (one per lane — only when decomposed)
Same shape as `implement` (above), plus a `lane` discriminator:
```json
{
  "lane": "backend",
  "agent_model": "claude-sonnet-4-5",
  "files_changed": [
    { "path": "api/routes/orders.py", "added": 42, "removed": 0 }
  ],
  "total_added": 42,
  "total_removed": 0,
  "blockers_reported": []
}
```
The filename embeds the lane (`implement-backend.json`); the canonical stage
name in `run.json.stages_completed` is still `implement` (recorded once after
2c, not per lane).

#### `converge` (Stage 2c — only when decomposed)
```json
{
  "merged_files": ["api/routes/orders.py", "models/order.py", "..."],
  "integration_fixes": [
    { "file": "api/routes/orders.py", "fix": "import Order from models.order" }
  ],
  "import_check": { "status": "pass", "unresolved": [] },
  "symbol_collisions": []
}
```
`import_check.status` is `pass` or `fail`; `unresolved` lists imports/symbols
that could not be resolved across the union of lane edits. `symbol_collisions`
lists any name defined by more than one lane. A non-empty `unresolved` or
`symbol_collisions` that 2c cannot fix is fed into the Stage 4 fix loop.

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

#### `handoff` (sdlc-lite mode — replaces `pr-create`)
```json
{
  "branch": "feature-branch",
  "files_changed": ["api/routes/orders.py"],
  "committed": false,
  "suggested_commit_msg": "feat: add orders endpoint"
}
```
`/sdlc-lite` does no git writes; it records what it would commit and leaves
the tree for the user. `committed` is always `false`.

---

## Lifecycle

1. **Stage 1 (`parse`)**: `/sdlc` `mkdir -p .claude/pipeline/<slug>/stage-outputs/`, then writes initial `run.json` with `stage: "parse"`, `status: "in_progress"`, captures `args` and `plan_hash`. On Stage 1 completion, writes `stage-outputs/parse.json`.
2. **Subsequent stages**: when a stage starts, `run.json.stage` and `run.json.updated_at` are updated. When the stage finishes, its sidecar is written and `run.json.stages_completed` is appended.
3. **Skipped stages** (e.g., stages skipped because their config was absent, or skill-repo-mode skips `generate-evals`): added to `run.json.stages_skipped`; no sidecar is written.
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
