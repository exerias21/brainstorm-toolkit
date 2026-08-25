# State Envelope Schema

`/sdlc` writes a transparent state journal under `.claude/pipeline/<feature-slug>/` as it runs. This file documents the on-disk shape so consumers (orchestrators, dashboards, `/sdlc --resume` and the future `/sdlc --inspect`) can read it without inventing their own contract.

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
    validate.json
    review.json             # Stage 5.7 -- only when a reviewer resolves (see the reviewer-model enablement chain, models.md)
    review-fix.json         # Stage 5.8 -- only when review.json.data.confirmed is non-empty; single cumulative file, data.loops[] holds one entry per iteration (NOT numbered review-fix-<n>.json files)
    secret-scan.json
    pr-create.json
```

Stage filenames use the **canonical kebab names** from `docs/CONVENTIONS.md` "Stage names" — `parse`, `sanity-check`, `decompose`, `implement`, `implement-<lane>`, `converge`, `generate-evals`, `validate`,  `review`, `review-fix`, `secret-scan`, `pr-create`. Never decimal-versioned (no `stage-1.5.json`).

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
| `pipeline` | string | optional | Which skill wrote this run: `sdlc`, `sdlc-lite`, or `task`. Absent ⇒ assume `sdlc` (back-compat). Lets `/status`, `/repo-health`, and the Stop hook distinguish run types. |
| `base_commit` | string | optional | `git rev-parse HEAD` captured at Stage 1, before any implementation commit. Powers **continuity detection** (is this branch's prior run an ancestor of HEAD?) and **reconciliation** (an `in_progress` run whose `base_commit` is already an ancestor of HEAD was almost certainly committed outside the pipeline). Additive; absent on older runs. |
| `started_at` | ISO 8601 string | yes | UTC, second precision. |
| `updated_at` | ISO 8601 string | yes | Refreshed on every stage transition. |
| `stage` | string | yes | Canonical kebab name of the *current* stage. On terminal states, holds the last attempted stage. |
| `status` | enum | yes | One of `in_progress`, `complete`, `failed`, `paused`. `paused` means the pipeline stopped and `--resume` would pick it up. |
| `stages_completed` | string array | yes | In execution order. Each name appears once. A stage is "completed" when its sidecar's status is `pass`. |
| `stages_skipped` | string array | yes | Stages explicitly skipped (e.g., stages skipped because their config was absent, or skill-repo-mode skips). Distinct from "not yet run." |
| `next_action` | object | optional | Additive (L8 — the pending handoff, durable). `{"cmd": "...", "confirm": bool}`, mirroring a `.next-action` sentinel line, recording the next step this run proposed when it finished/paused. Lets `/status` and `/status` recover the proposed handoff from the envelope even after the fire-once sentinel was consumed — the loop's "program counter" survives in a file, not just chat context. **This is a `/status` *fallback*, read on demand — it is NOT what the Stop hook auto-surfaces.** The `.next-action` **sentinel** is the only thing the hook reads; a park must write the sentinel too, never rely on this field alone (DQ5). Absent when the run proposed no next action. |
| `data.stage2_decomposed` | bool | optional | Set at Stage 2a. `true` when the gate fanned Stage 2 into per-lane subagents; `false` (or absent) for the single-agent path. Absent on runs written before this field existed. |
| `data.lanes` | string array | optional | Lane names from Stage 2a (e.g. `["data", "backend", "frontend"]`), in dependency dispatch order. `[]` when not decomposed. |

**`stages_completed` worked example** (supplementary — a full run with the Review→Fix stage on):

```json
{
  "stages_completed": [
    "parse", "sanity-check", "implement", "generate-evals",
    "validate", "review", "review-fix",
    "secret-scan", "pr-create"
  ]
}
```

When `pipeline.review_fix.enabled` is `false`, `--no-review` was passed, or `review.json`'s
`confirmed[]` ends up empty, `review` and/or `review-fix` move to `stages_skipped` instead on the
prose/overlay paths — same documented convention as `generate-evals`'s own skill-repo-mode skip. On the Workflow path this is logged, not array-appended (a
pre-existing gap, not new here).

**Queued / multi-item runs (`/sdlc-lite --queue`, L10).** A queue run stays on **this exact
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
  left `status:"in_progress"` is a bug (`/status`/`/repo-health` will flag it stale).

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
`symbol_collisions` that 2c cannot fix is fed into Stage 5's shared fix loop.

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


#### `review` (Stage 5.7 -- only when the reviewer-model axis resolves ON)
```json
{
  "lenses": ["correctness", "plan-alignment", "config-env-docs", "security"],
  "reviewer_model": "opus",
  "independence": "ok",
  "passes_run": 1,
  "second_pass_model": null,
  "diff_lines_reviewed": 340,
  "partitioned": false,
  "findings": [
    {
      "finding_id": "f0-1",
      "lens": "correctness",
      "severity": "high",
      "file": "api/scrapers/ddg.py",
      "line": 42,
      "defect": "_unwrap_ddg_href double-decodes the href (parse_qs then unquote again)",
      "failure_scenario": "A scraped URL whose query value contains %26 is corrupted to & before storage.",
      "fix": "Drop the second unquote() call; parse_qs already unquotes."
    }
  ],
  "confirmed": [
    { "finding_id": "f0-1", "verify_confidence": 0.93, "evidence": "api/scrapers/ddg.py:42 -- `unquote(parse_qs(qs)['u'][0])`" }
  ],
  "demoted_lenses": [],
  "deferred_debt": []
}
```
`findings` is the raw merged fan-out output across all lenses (each tagged with its producing
lens and a `finding_id`). `passes_run` (1 or 2) and `models.code_review_second_pass` (the effective model
dispatched for the completeness critic, or `null` when `passes_run` is 1) record whether
`agents.code_review_passes` was 2 for this run. When `passes_run` is 2, each item in `findings`
additionally carries `pass: 1` or `pass: 2` (set at merge time, never by the reviewing or critic
agent itself); a `passes_run: 1` run never adds this field, so its absence means pass 1. This
`pass` tag is unrelated to the loop-scoped `finding_id` numbering described next -- two independent
axes that happen to share the word "pass."

**`finding_id` is loop-scoped, not run-global**: it is minted as `f<reviewPass>-<n>` where
`reviewPass` starts at 0 for the pre-fix-loop initial review (the pass this top-level `review.json`
snapshot reflects) and increments by one on every subsequent re-review inside Stage 5.8's fix loop
-- a stable cross-loop id is not attempted because the lens dispatch re-runs on every call, so a
later loop's "same" index is not guaranteed to name the same defect. `confirmed` is the subset that
survived the adversarial verify sub-pass, referenced back by `finding_id`; each
`confirmed[].verify_confidence` is copied verbatim from that finding's verify-verdict `confidence`
value -- not a separately-computed number. `deferred_debt` entries are out-of-scope issues surfaced
incidentally during review (each with a `debt_hash` dedup key, auto-appended once each to
`TASKS.md`). **If `confirmed` is empty, OR `pipeline.review_fix.mode` is `"off"`, Stage 5.8 is
skipped entirely** -- no `review-fix.json` is written. On the prose/overlay paths, `review-fix` is
recorded in `run.json.stages_skipped` for this self-skip; on the Workflow path this is logged, not
array-appended (a pre-existing gap, not new here).

#### `review-fix` (Stage 5.8 -- single cumulative sidecar; only when `review.json.confirmed` is non-empty)
```json
{
  "fix_loops_run": 2,
  "max_fix_loops": 3,
  "final_pass_count": 3,
  "final_fail_count": 0,
  "remaining_failures": [],
  "loops": [
    {
      "loop": 1,
      "fix_specs": [
        { "finding_id": "f0-1", "auto_fixable": true, "spec": "Remove the second unquote() in _unwrap_ddg_href (api/scrapers/ddg.py:42)." }
      ],
      "decisions": [
        { "finding_id": "f0-1", "action": "approved", "mode": "interactive", "reason": null }
      ],
      "fixed_fingerprints": ["api/scrapers/ddg.py:correctness:4"],
      "reverify": { "status": "pass", "remaining_findings": [] }
    }
  ]
}
```
Mirrors the shared fix-loop sidecar shape (`fix_loops_run`/`max_fix_loops`/`final_pass_count`/
`final_fail_count`/`remaining_failures`) with a `loops[]` array added for per-iteration detail.
`decisions[].action` is one of `approved`, `edited`, `skipped`; in `auto` mode `action` is still
`approved` but `reason` is populated (e.g. `"auto: confidence 0.93 >= threshold 0.85"`). A finding
with `auto_fixable: false` can never appear with `action: "approved"` except under `interactive`
mode with an explicit human approval -- the fix-planner routes design-decision findings to a forced
human prompt regardless of `pipeline.review_fix.mode`.

**`loops[n].fix_specs`/`decisions` reference ids from the review pass that ran *before* that
iteration's fix agent, not from `loops[n]`'s own re-review.** Concretely: `loops[0]` (loop 1) fixes
findings minted by the pre-loop initial review (`review.json`'s own `f0-*` ids); its `reverify`
field reports the result of the re-review that ran immediately *after* the fix, which mints a fresh
`f1-*` set. `loops[1]` (loop 2), if it runs, fixes findings from that `f1-*` re-review, and so on.
An id is only ever meaningful paired with the pass that minted it -- there is no guaranteed stable
identity for "the same defect" across loops; the oscillation guard uses a content fingerprint for
that instead. Persisted `fix_specs`/`decisions` are **id-keyed** (`finding_id`), never index-keyed
-- the fix-planner's agent-return shape is index-keyed, but the JS maps each `finding_index` to its
confirmed finding's `finding_id` when interpolating the fix agent's envelope payload, so raw indices
never reach the sidecar.

**`reverify` is never written by the fix agent itself, on either path.** The fix agent runs
*before* its own loop's re-review exists, so it cannot know that result. On the Workflow, the fix
agent's envelope note writes only `fix_specs`/`decisions`/`fixed_fingerprints`; `reverify` is
back-filled by the `persist:review-fix` call after the loop, from the pass-N re-review result
already held in JS. On the Workflow, `decisions[].reason` is always `"workflow auto-apply"` (there
is no human channel there) rather than `null` -- the `null` shown in the example above is the
prose-path, human-interactive-approval case.

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

## `.claude/pipeline/_review-stats.json` — review circuit breaker (cross-run ledger)

Unlike every sidecar above, this file is **not per-run** — it is a rolling cross-run ledger, one
file per repo, keyed by lens. It backs the Review→Fix stage's false-positive circuit breaker
(repo-local, already covered by the existing `.claude/pipeline/` `.gitignore` entry):

```json
{
  "schema_version": 1,
  "lenses": {
    "correctness":     { "runs": [{ "raw": 3, "confirmed": 2, "ts": "2026-07-03T18:04:00Z" }], "demoted": false },
    "plan-alignment":  { "runs": [], "demoted": false },
    "config-env-docs": { "runs": [], "demoted": true },
    "security":        { "runs": [], "demoted": false }
  }
}
```

- `runs[]` is capped at the last 20 entries per lens (oldest evicted on push) — a rolling
  confirmed/raw ratio across the last 20 runs.
- `demoted` flips `true` once that lens's confirmed-rate (`sum(confirmed)/sum(raw)` over the
  window) drops under 40%, flips back `false` after 5 consecutive runs at ≥60%.
- **Writer:** the same Stage 5.7 persist step that writes `review.json` also appends this run's
  `{raw, confirmed, ts}` per dispatched lens to `_review-stats.json` and recomputes `demoted`, on
  **both** the Workflow and the prose/overlay paths (a Copilot/Codex run updates the same file at
  the same path — there is no separate per-tool ledger). The resolved lens list for the **next**
  run is `(cfg.review_fix?.lenses ?? DEFAULT_LENSES).filter(l => !stats.lenses[l]?.demoted)` —
  demotion never changes which lenses ran *this* run, only which ones are dispatched on subsequent
  runs.
- `review.json.data.demoted_lenses` is this run's *view* of which lenses were skipped because
  `_review-stats.json` already marked them demoted going in — the two files are consistent by
  construction (one reads what the other most recently wrote).
- This mechanism (the sidecar, the writer-side update, and the demotion-aware lens filter) is
  **active**: the per-lens ledger in `_review-stats.json` backs live lens demotion (a lens whose
  confirmed-rate drops under 40% is demoted; 5 consecutive runs at ≥60% re-promote it, capped at the
  last 20 runs per lens). `REVIEW_LENSES` filters out demoted lenses from dispatch on every run, and
  `review.json.data.demoted_lenses` records which lenses were skipped because this ledger already
  marked them demoted going in.

---

## Lifecycle

1. **Stage 1 (`parse`)**: `/sdlc` `mkdir -p .claude/pipeline/<slug>/stage-outputs/`, then writes initial `run.json` with `stage: "parse"`, `status: "in_progress"`, captures `args` and `plan_hash`. On Stage 1 completion, writes `stage-outputs/parse.json`.
2. **Subsequent stages**: when a stage starts, `run.json.stage` and `run.json.updated_at` are updated. When the stage finishes, its sidecar is written and `run.json.stages_completed` is appended.
3. **Skipped stages** (e.g., stages skipped because their config was absent, or skill-repo-mode skips `generate-evals`): added to `run.json.stages_skipped`; no sidecar is written.
4. **Terminal states**:
   - All stages pass → `run.json.status = "complete"`.
   - Unrecoverable failure → `run.json.status = "failed"`; the failing stage's sidecar has `status: "fail"`.
   - Pause for human review (validate failure persists) → `run.json.status = "paused"`.
5. **Re-running `/sdlc <plan>`** (without `--resume`): overwrites the prior `run.json` and `stage-outputs/` for the same slug. Slug-collision policy (different plan files deriving the same slug) is deferred to a later phase per `docs/CONVENTIONS.md` open questions; current behavior is overwrite.

## Best-effort failure mode

If `mkdir -p`, `chmod`, or any state-write fails (disk full, read-only volume, permissions), `/sdlc` logs a single-line warning to stderr (`[state-envelope] write failed: <error>; continuing`) and proceeds with the pipeline. **State writes never fail a pipeline run.** The pipeline run can still produce a PR even if state was never persisted.

## What does NOT live here

- **Plan files**: stay in `plans/` (or wherever the user passes them); `run.json.plan_file` points to them.
- **`/flowsim` JSON**: `plans/flowsim-<slug>.json` is the canonical (and only) location for the standalone `/flowsim` skill's structured output. The pipeline writes **no** flowsim sidecar — the former Stage 5.6 flow trace was merged into Stage 5, and its results live in `validate.json`'s `data.flow[]`.
- **PBI / BRD artifacts**: `pbis/pbi-NNN.md`, `requirements/brd-NNN.md` (Phase 2/3). Run state may *reference* these by ID but never copies them.
- **Delivery artifacts** (Phase 5+): `delivery/pbi-NNN.json` is for stakeholder-readable, persistent reports. `.claude/pipeline/` is ephemeral local state only.
