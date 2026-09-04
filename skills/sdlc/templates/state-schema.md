# State Envelope Schema

`/sdlc` writes a state journal under `.claude/pipeline/<feature-slug>/` as it runs. This
file is the on-disk contract its consumers read: `--resume`, `/sdlc-status` and `/repo-health`.

Two rules bind at runtime. **State writes are best-effort** — on a full disk or unwritable
directory, log one line (`[state-envelope] write failed: <error>; continuing`) and proceed;
a state-write failure never fails a run. And **state is gitignored** — `setup.sh` adds
`.claude/pipeline/` to the consumer's `.gitignore`.

`schema_version: 1`. Additive fields need no bump; renames and removals do. Rationale and the
original design rules: `docs/PHASE-1-STATE-ENVELOPE.md` (plugin repo, not shipped).

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
    validate.json
    review.json             # Stage 5.7 -- only when the review stage is enabled; shape in stage-5.7-review-fix.md
    review-fix.json         # Stage 5.8 -- only when review.json.data.confirmed is non-empty; shape in stage-5.7-review-fix.md
    handoff.json            # Stage 6 hand-off
```

Stage filenames use the **canonical kebab names** from `docs/CONVENTIONS.md` "Stage names" — `parse`, `sanity-check`, `decompose`, `implement`, `implement-<lane>`, `converge`, `generate-evals`, `validate`, `review`, `review-fix`. Never decimal-versioned (no `stage-1.5.json`).

Note: `review-fix`'s internal `loops[]` index is a bounded loop counter (`max_fix_loops`, default 3), **not** an artifact ID — it is not zero-padded and does not fall under the `pbi-001`/`task-001` convention.

The Stage 2 sidecars are **mutually exclusive by path**: the single-agent path writes only `implement.json`; the decomposed path (Stage 2 gate fans out) writes `decompose.json`, one `implement-<lane>.json` per lane, and `converge.json`, and never writes `implement.json`. A run that never decomposes is byte-for-byte unchanged from the pre-decomposition envelope.

In skill-repo mode (auto-detected from `.claude-plugin/marketplace.json` at repo root), the skipped stage (`generate-evals`) writes **no sidecar**. `stage-outputs/validate.json` is still written in skill-repo mode, but as a skill-repo-shaped sidecar that records the structural-check results from `templates/stage-5-skill-repo.md`; in that case `data.mode = "skill-repo"`.

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
  "stage": "validate",
  "status": "in_progress",
  "stages_completed": ["parse", "sanity-check", "implement", "generate-evals", "validate"],
  "stages_skipped": []
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `schema_version` | int | yes | Currently `1`. Bumped only on breaking change. |
| `feature_slug` | string | yes | Derived from plan filename per CONVENTIONS.md slug-derivation. RFC 1123-compliant. |
| `plan_file` | string | yes | Path relative to repo root, as passed to `/sdlc`. |
| `plan_hash` | string | yes | `sha256:<hex>` of the plan file's contents at Stage 1. Lets `--resume` detect plan edits (a mismatch rejects the resume). |
| `args` | object | yes | Snapshot of run-time decisions. Snake_case keys. `/sdlc` is zero-flag — the only field currently recorded is `skill_repo` (auto-detected from `.claude-plugin/marketplace.json` presence at repo root). New additive fields are allowed. |
| `pipeline` | string | optional | Which skill wrote this run: `sdlc` or `task`. Absent ⇒ assume `sdlc` (back-compat). Lets `/sdlc-status`, `/repo-health`, and the Stop hook distinguish run types. |
| `base_commit` | string | optional | `git rev-parse HEAD` captured at Stage 1, before any implementation commit. Powers **continuity detection** (is this branch's prior run an ancestor of HEAD?) and **reconciliation** (an `in_progress` run whose `base_commit` is already an ancestor of HEAD was almost certainly committed outside the pipeline). Additive; absent on older runs. |
| `started_at` | ISO 8601 string | yes | UTC, second precision. |
| `updated_at` | ISO 8601 string | yes | Refreshed on every stage transition. |
| `stage` | string | yes | Canonical kebab name of the *current* stage. On terminal states, holds the last attempted stage. |
| `status` | enum | yes | One of `in_progress`, `complete`, `failed`, `paused`. `paused` means the pipeline stopped and `--resume` would pick it up. |
| `stages_completed` | string array | yes | In execution order. Each name appears once. A stage is "completed" when its sidecar's status is `pass`. |
| `stages_skipped` | string array | yes | Stages explicitly skipped (e.g., stages skipped because their config was absent, or skill-repo-mode skips). Distinct from "not yet run." |
| `next_action` | object | optional | Additive (L8 — the pending handoff, durable). `{"cmd": "...", "confirm": bool}`, mirroring a `.next-action` sentinel line, recording the next step this run proposed when it finished/paused. Lets `/sdlc-status` recover the proposed handoff from the envelope even after the fire-once sentinel was consumed — the loop's "program counter" survives in a file, not just chat context. **This is a `/sdlc-status` *fallback*, read on demand — it is NOT what the Stop hook auto-surfaces.** The `.next-action` **sentinel** is the only thing the hook reads; a park must write the sentinel too, never rely on this field alone (DQ5). Absent when the run proposed no next action. |
| `data.stage2_decomposed` | bool | optional | Set at Stage 2a. `true` when the gate fanned Stage 2 into per-lane subagents; `false` (or absent) for the single-agent path. Absent on runs written before this field existed. |
| `data.lanes` | string array | optional | Lane names from Stage 2a (e.g. `["data", "backend", "frontend"]`), in dependency dispatch order. `[]` when not decomposed. |

**`stages_completed` worked example** (supplementary — a full run with the Review→Fix stage on):

```json
{
  "stages_completed": [
    "parse", "sanity-check", "implement", "generate-evals",
    "validate", "review", "review-fix",
    "secret-scan", "handoff"
  ]
}
```

When `pipeline.review_fix.enabled` is `false`, `--no-review` was passed, or `review.json`'s
`confirmed[]` ends up empty, `review` and/or `review-fix` move to `stages_skipped` instead on the
prose/overlay paths — same documented convention as `generate-evals`'s own skill-repo-mode skip.

**Queued / multi-item runs (`/sdlc --queue`, L10).** A queue run stays on **this exact
schema** — it does **not** invent a parallel shape. Concretely (dogfood-hardened):
- Canonical keys only — `feature_slug`, `plan_file`, `plan_hash`, `schema_version`,
  `started_at`, `updated_at`, `args`. Never `slug`/`plan`/`mode`.
- `stage` / `stages_completed` hold **canonical stage names** (`implement`, `validate`,
  `handoff`, …). **Never** phase labels like `phase-B-implement` or `phase-0`.
- Queue/phase bookkeeping is **additive under `data`**: `data.queue_mode: true`,
  `data.phase` (a human label for the current batch), `data.tasks_done: ["N1", …]`,
  `data.max_items`. These are `data.*` extras, not top-level or stage fields.
- On a park between batches: `status: "paused"` + `next_action` set (see the `next_action`
  row above) + the resume line written to the sentinel (`docs/SEAM.md`). A parked queue run
  left `status:"in_progress"` is a bug (`/sdlc-status`/`/repo-health` will flag it stale).

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
| `summary` | string | yes | One-line human summary, read by `/sdlc-status`. |
| `prompt_hash` | string | optional | `sha256:<hex>` of the SKILL.md prompt template that drove this stage. Lets `--resume` detect toolkit upgrades that changed how a stage runs (per Open Question #3 in the plan: re-run any stage whose `prompt_hash` differs from the cached value). |
| `data` | object | yes | Stage-specific payload. May be `{}` for stages with no structured output. Shape per stage below. |

### Per-stage `data` shapes

Below is the shape each stage's `data` field is expected to take. These are the contracts `--resume` and `/sdlc-status` rely on; new keys are additive and safe.

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

#### `decompose` / `implement-<lane>` / `converge` (decomposed path only)
Shapes are the agent output contracts in `stage-2a-decompose.md`, `stage-2b-dispatch.md` and
`stage-2c-converge.md`. Two rules live here: on the `single-agent` path no `decompose.json` is
written — the gate inputs are summarized in `implement.json`'s `summary`; and the canonical
stage name in `run.json.stages_completed` is `implement`, recorded once after 2c, never per
lane.

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
  "preexisting_failures": [],
  "requirements": [
    { "criterion": "orders list paginates", "verdict": "met", "evidence": "app/orders.py:88" }
  ],
  "flow": [
    { "step": "POST /orders -> queue -> worker", "verdict": "OK", "evidence": "app/api.py:41" }
  ],
  "flow_witnessed": true
}
```

`requirements[].verdict` is `met` / `partial` / `missing`; `flow[].verdict` is `OK` / `MISMATCH`
/ `UNCLEAR` / `MISSING`. **`flow_witnessed`** records whether step 1 produced real test results
for the touched surfaces. It is a **gate input, not decoration**: when it is `false` the flow
axis is advisory — its findings are still written here and still reported, but they cannot fail
the stage or open the fix loop (`skills/sdlc/templates/stage-5-validate.md` §3). The requirements
axis gates either way. Both arrays are absent when there was no plan target to check against.

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


#### `handoff` (Stage 6)
```json
{
  "branch": "feature-branch",
  "files_changed": ["api/routes/orders.py"],
  "committed": false,
  "suggested_commit_msg": "feat: add orders endpoint"
}
```
`/sdlc` does no git writes; it records what it would commit and leaves
the tree for the user. `committed` is always `false`.

---

## What does NOT live here

- **Plan files**: stay in `plans/` (or wherever the user passes them); `run.json.plan_file` points to them.
- **`/flowsim` JSON**: `plans/flowsim-<slug>.json` is the canonical (and only) location for the standalone `/flowsim` skill's structured output. The pipeline writes **no** flowsim sidecar — the former Stage 5.6 flow trace was merged into Stage 5, and its results live in `validate.json`'s `data.flow[]`.
