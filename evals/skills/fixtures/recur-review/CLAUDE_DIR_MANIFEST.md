# recur-review: `.claude/` files to create verbatim

These files belong to this fixture but could not be written under `.claude/` yet. Create each
one at the path shown (relative to this fixture directory), then `git add -f` the
`.claude/pipeline/` files (the repo `.gitignore` ignores that directory) and delete this manifest.
Used by `evals/skills/cases/sdlc-recurring-catch.json` and `sdlc-recurring-catch-once.json`
(the latter removes `earlier-b` with `pre_setup_remove`).

`plans/current.md` is empty on purpose: `current/run.json`'s `plan_hash` is the SHA-256 of the
empty string, so `--resume` passes the staleness guard without the plan changing.

## `.claude/project.json`

```json
{
  "test": {
    "unit": "pytest -q"
  },
  "pipeline": {
    "output": {
      "verbosity": "quiet"
    },
    "review_fix": {
      "enabled": true
    }
  }
}
```

## `.claude/pipeline/earlier-a/run.json`

```json
{
  "schema_version": 1,
  "feature_slug": "earlier-a",
  "plan_file": "plans/earlier-a.md",
  "plan_hash": "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  "args": { "skill_repo": false },
  "pipeline": "sdlc",
  "started_at": "2026-11-01T10:00:00Z",
  "updated_at": "2026-11-01T10:20:00Z",
  "stage": "handoff",
  "status": "complete",
  "stages_completed": ["parse", "sanity-check", "implement", "validate", "review", "review-fix", "handoff"],
  "stages_skipped": ["generate-evals"],
  "data": {
    "review_findings": [
      {
        "category": "unvalidated-limit",
        "file": "api/list.py",
        "summary": "page limit taken from the query string without a lower bound",
        "outcome": "fixed"
      }
    ]
  }
}
```

## `.claude/pipeline/earlier-b/run.json`

```json
{
  "schema_version": 1,
  "feature_slug": "earlier-b",
  "plan_file": "plans/earlier-b.md",
  "plan_hash": "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  "args": { "skill_repo": false },
  "pipeline": "sdlc",
  "started_at": "2026-11-08T10:00:00Z",
  "updated_at": "2026-11-08T10:25:00Z",
  "stage": "handoff",
  "status": "complete",
  "stages_completed": ["parse", "sanity-check", "implement", "validate", "review", "review-fix", "handoff"],
  "stages_skipped": ["generate-evals"],
  "data": {
    "review_findings": [
      {
        "category": "unvalidated-limit",
        "file": "api/search.py",
        "summary": "limit parameter accepted as-is, negative value reaches the query",
        "outcome": "fixed"
      },
      {
        "category": "stale-env-name",
        "file": ".env.example",
        "summary": "env var renamed in code but not in .env.example",
        "outcome": "skipped"
      }
    ]
  }
}
```

## `.claude/pipeline/current/run.json`

```json
{
  "schema_version": 1,
  "feature_slug": "current",
  "plan_file": "plans/current.md",
  "plan_hash": "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  "args": { "skill_repo": false },
  "pipeline": "sdlc",
  "started_at": "2026-11-21T09:00:00Z",
  "updated_at": "2026-11-21T09:30:00Z",
  "stage": "review-fix",
  "status": "paused",
  "stages_completed": ["parse", "sanity-check", "implement", "validate", "review", "review-fix"],
  "stages_skipped": ["generate-evals"],
  "data": {
    "tasks": { "resolved": ["plans/current.md"] },
    "review_findings": [
      {
        "category": "unvalidated-limit",
        "file": "app.py",
        "summary": "parse_limit accepted zero and negative values",
        "outcome": "fixed"
      }
    ]
  }
}
```

## `.claude/pipeline/current/stage-outputs/implement.json`

```json
{
  "status": "pass",
  "files_changed": [{ "path": "app.py", "change": "modified" }],
  "data": {}
}
```

## `.claude/pipeline/current/stage-outputs/review.json`

```json
{
  "status": "pass",
  "data": {
    "lenses": ["correctness"],
    "reviewer_model": "opus",
    "independence": "ok",
    "passes_run": 1,
    "findings": [
      {
        "finding_id": "f0-1",
        "lens": "correctness",
        "category": "unvalidated-limit",
        "severity": "medium",
        "file": "app.py",
        "line": 10,
        "defect": "parse_limit accepted zero and negative values",
        "failure_scenario": "parse_limit('-3') returned -3, which reaches the query as a negative LIMIT.",
        "fix": "Fall back to the default when the value is not positive."
      }
    ],
    "confirmed": [
      { "finding_id": "f0-1", "verify_confidence": 0.92, "evidence": "app.py:10 -- `return value`" }
    ],
    "demoted_lenses": [],
    "deferred_debt": []
  }
}
```

## `.claude/pipeline/current/stage-outputs/review-fix.json`

```json
{
  "status": "pass",
  "data": {
    "fix_loops_run": 1,
    "max_fix_loops": 3,
    "final_pass_count": 2,
    "final_fail_count": 0,
    "remaining_failures": [],
    "loops": [
      {
        "loop": 1,
        "fix_specs": [
          { "finding_id": "f0-1", "auto_fixable": true, "spec": "Return the default when value <= 0 (app.py:10)." }
        ],
        "decisions": [
          { "finding_id": "f0-1", "action": "approved", "mode": "auto", "reason": "auto: auto_fixable" }
        ],
        "fixed_fingerprints": ["app.py:correctness:1"],
        "reverify": { "status": "pass", "remaining_findings": [] }
      }
    ]
  }
}
```
