# Stage 5.9 — Cleanup pass (shared)

Canonical for `/sdlc`. **Opt-in, permanently OFF by default** — do not load this file unless
the stage is enabled (see the enablement rule in `skills/sdlc/SKILL.md`, resolved before this
file is ever opened).

**Out of scope by design: bug-hunting.** That's Stage 5.7's `correctness` lens. This stage is
quality-only — over-engineering and stale docstrings — because a stage that both hunts bugs and
fixes them ends up fixing what it just accused. Do not "helpfully" widen it later.

**No `/simplify`.** That skill is a Claude Code CLI built-in — not shipped by this plugin, not
present on Copilot or Codex, and versioned with the CLI instead of this repo. This file carries
the stage's own prose so the contract holds on every runtime.

## Contents

- [Enablement and scope](#enablement-and-scope)
- [Lenses and cost knobs](#lenses-and-cost-knobs)
- [Apply](#apply)
- [Re-validate — mandatory when anything was applied](#re-validate--mandatory-when-anything-was-applied)
- [State](#state)

## Enablement and scope

The gate itself already resolved ON in `skills/sdlc/SKILL.md` before this file was opened. Three
auto-off conditions apply even when the run opted in — re-check them here because a `--resume`
can reach this stage on a different sidecar set than the run that first evaluated the gate:

- **Stage 5 is not green** — `stage-outputs/validate.json` `status` is not `"pass"`. This is
  Constraint 3 in force: a stage that writes must never act on a codebase that hasn't been
  proven correct by real test evidence. There is no partial-credit path.
- **`implement` is in `run.json.stages_skipped`** — a validation-only / retro run has no diff
  this run produced, so there is nothing scoped to clean.
- **The diff is docs-only / touches no code surface** — per
  `skills/sdlc/templates/changed-files-gate.md`, none of `frontend`/`backend`/`data` is touched.

Any of the three ⇒ append `cleanup` to `run.json.stages_skipped` (this file was already opened,
so also write `stage-outputs/cleanup.json` with `status: "skip"` and `data.skipped_reason` set)
and go to Stage 6.

**Scope is exactly `implement.json` `data.files_changed[].path`** (fall back to
`changed-files-gate.md`'s `git diff` fallback only if that sidecar is absent) — **never** a
repo-wide sweep. That is what `/dead-code-review` and `/repo-health` are for. Neither lens below
may return, and the apply step must never act on, a finding whose `file` is outside this set.

## Lenses and cost knobs

**Which lenses run — `agents.cleanup_lenses`** (default: both). **How many — `agents.cleanup_max_lenses`**
(default `2`), truncating the resolved list in list order — a non-integer or non-positive value
falls through to `2`, and it must never resolve to `0`. Print the resolved list before
dispatching — `cleanup lenses: <a, b> (N of 2 defaults)` — same convention as
`agents.code_review_lenses`. An unrecognized lens name is ignored with one warning.

Dispatch **one `general-purpose` agent per selected lens, in one message on Claude** (sequential
inline passes on Copilot/Codex, per the standing runtime note in `skills/sdlc/templates/models.md`).
**Sonnet by default** (`--model opus` only, per `skills/sdlc/templates/models.md` — this rides
the Axis 1 cap ladder like every other fan-out stage, unlike Stage 5.7's reviewer axis). Print
`model: <tier> (cap: <cap|none>)` before dispatching. Each agent is find-only for this pass — its
role prompt says so explicitly, and it is given only the changed-file list plus the plan, never
the whole repo — and returns findings as `{lens, file, line, issue, minimal_fix, safe_to_apply}`.
`safe_to_apply` here is the agent's own opinion; the rubric below is what actually governs.

| Lens | Looks for | Never proposes |
|---|---|---|
| `over-engineering` | Speculative generality with one caller, an abstraction built for a second case that never arrived, a config key nothing reads, a wrapper that only forwards, error handling for a condition the type system already excludes, a parallel pattern where the repo already had one. | A rewrite. If the fix is bigger than a deletion plus its call-site updates, report it and leave it. |
| `docstring-currency` | Only on functions/classes **this run's diff actually changed**: `STALE` (says something no longer true — highest value, since a wrong docstring is worse than none), `THIN` (omits a new parameter, raise, or return shape), `MISSING` (public surface, no docstring). Follows the repo's existing docstring style — never imports one; `/code-tour` (`skills/code-tour/SKILL.md`) owns the why-focused house style, cited here rather than restated. | Touching a docstring on a function this run did not change. |

## Apply

Per `pipeline.cleanup.mode` (default `interactive`):

- **`interactive`**: print the full findings list once (grouped by lens), then a single
  confirmation for "apply the N `safe_to_apply` findings below?" — not per-finding approve/edit/skip
  (that granularity is Stage 5.8's, not this stage's). Apply on yes; on no, or on a non-interactive
  run with no channel to ask on, treat exactly like `mode: "off"` for this run and say why —
  the same proceed-and-document posture `changed-files-gate.md`'s soft-stop uses. This is
  Constraint 3 again: an opinion nobody witnessed confirming must not become an edit.
- **`auto`**: apply every `safe_to_apply: true` finding without prompting. Never applies a
  `safe_to_apply: false` finding regardless of mode — that branch is a hard gate, not a threshold.
- **`off`**: findings are written to `stage-outputs/cleanup.json` only; nothing is applied,
  `git diff` is identical before and after this stage runs.

**The `safe_to_apply` rubric (default-deny, orchestrator-enforced — never trust the lens agent's
self-report verbatim):** a finding is `safe_to_apply` only if it is **a deletion**, **a docstring
edit**, or **a rename with every call site named** in `minimal_fix`. Anything else — including
every `over-engineering` finding whose fix is not a pure deletion — is report-only regardless of
`mode`.

When `mode` is not `"off"` and at least one finding is `safe_to_apply`, dispatch **one** more
`general-purpose` agent — Sonnet by default, same model-line convention as above — given exactly
the confirmed `safe_to_apply` findings and their `minimal_fix`, to make **only** those edits, no
others. This is "the cleanup agent" that needs `Edit`, and it is the only point in this stage
that writes to the working tree. It never touches a file outside the Stage 0 scope above.

## Re-validate — mandatory when anything was applied

**If any edit was applied, re-run the Stage 5 gate exactly once** (`skills/sdlc/templates/stage-5-validate.md`,
or `stage-5-skill-repo.md` in skill-repo mode) before proceeding. This is Constraint 1: the
cleanup agent wrote, so it is disqualified from being the thing that verifies — the gate that
re-runs here is the same `test-runner` + plan-conformance dispatch Stage 5 already uses, never
the cleanup agent judging its own edit. A regression here is an objective break, not an opinion:
emit the shared `skills/sdlc/templates/fix-loop.md` **PAUSE block** and set `run.json.status =
"paused"` — do **not** proceed to Stage 6, and do not spend a fix-loop attempt trying to patch it
inline. When nothing was applied (report-only findings, or `mode: "off"`), skip the re-validate
— there is nothing to re-check.

## State

Write `stage-outputs/cleanup.json`:

```json
{
  "status": "pass",
  "data": {
    "lenses_run": ["over-engineering", "docstring-currency"],
    "findings": [
      {
        "lens": "over-engineering",
        "file": "api/scrapers/ddg.py",
        "line": 88,
        "issue": "ScraperConfig wrapper class has one caller and forwards every field unchanged",
        "minimal_fix": "inline the three fields at api/scrapers/ddg.py:41 (its one call site); delete the class",
        "safe_to_apply": false
      }
    ],
    "applied": [],
    "skipped_reason": null,
    "revalidate": { "ran": false, "green": null }
  }
}
```

`cleanup` is appended to `run.json.stages_completed` whenever this stage actually ran — even
with zero findings — matching Stage 5.7's own convention; a self-skip (the three auto-off
conditions above) goes to `stages_skipped` instead.

**Stage 7 report** (add when this stage ran, omit the line entirely when it self-skipped): one
line per applied change (`file:line — <issue>`), then the count left report-only, e.g.
`cleanup: 1 applied, 3 report-only`. Never claim more than `data.applied[]` actually contains.
