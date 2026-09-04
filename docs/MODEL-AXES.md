# Model axes — design record

Maintainer reference. **Not shipped by `setup.sh`**, so it costs consumers nothing. The runtime
contract lives in `skills/sdlc/templates/models.md`, which every fan-out skill loads on every
run; anything here is background that a running agent does not need.

Moved out of `models.md` in 2026-08 for that reason — it was ~500 words of record being re-read
on every pipeline run.

---

## Reasoning effort — partial support, stated honestly

Reasoning effort is **not uniformly settable**, so there is deliberately no
`models.*_effort` config key. Adding one would create a knob that silently does nothing on
the default path — the exact failure this contract exists to prevent.

| Path | Effort settable? |
|---|---|
| Agent definition frontmatter (`agents/*.md`) | **Yes** — `effort:` |
| **Prose path (the default, and the only path on Copilot/Codex)** | **No** — the Agent tool exposes `model` but has no `effort` parameter |

A sub-agent dispatched from prose inherits the session effort. If you need a stage to think
harder today, **raise its tier** — that works on every path. Revisit if the Agent tool ever
gains the parameter.

---

## Runtime regimes

  `agent()` that omits `model` inherits the session tier and **bypasses the cap**, so every
  dispatch must be wrapped.
- **Copilot** → stages run inline in the session model; the cap is **advisory** (no
  sub-agent tier to lower). The `agents.*` counts still apply.
- **Codex** → advisory too, but for a different reason worth keeping straight. Codex *does*
  have native subagents (`.codex/agents/*.toml`, parallel, `max_threads`) — it is not
  structurally inline-only like Copilot. What blocks tiering is that **per-subagent model
  override is reported regressed upstream** (subagents inherit the parent model), so the
  fan-out runs single-model.

  > **Reported, not verified here** — from web research on 2026-07-13, not a hands-on Codex
  > install, and an upstream bug that may already be fixed. Re-check before relying on the
  > limitation *or* its absence. Describes Codex only; changes nothing about tier defaults

---

## Independence: why the reviewer is never re-tiered (2026-09-04)

Stage 5.7 compares the reviewer's resolved value to the implementer's effective tier. The
original rule *corrected* a collision by bumping the reviewer one tier up, or marked the run
`degraded` when already at the ceiling. Two facts made the bump a defect rather than a
safeguard:

1. The reviewer's default is `opus`, the ceiling. A bump can only fire when the reviewer is
   *below* the ceiling — i.e. only when the user set `models.code_review` / `--review-model`
   explicitly. The bump therefore never protected a default; it only overrode explicit config.
2. Under the standing `cap: sonnet`, the implementer is `sonnet`, so `code_review: "sonnet"` —
   the exact edit the stage's own cap-warning recommends — always collided and always ran
   Opus. The log line advised a knob the rule then undid.

The fix keeps the *observation* (a same-tier reviewer is weaker, so the run is `degraded` and
nothing auto-fixes) and drops the *correction*. Consequence to keep in mind when editing either
axis: an explicit Axis 2 value is always the dispatched value. If a repo wants a stronger
reviewer, it says so; the toolkit never spends Opus on the user's behalf.

Related harness knob, for the record: Claude Code's `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1`
(v2.1.257+) overrides every sub-agent dispatch, per-invocation `model` included. On a repo with
the review stage enabled it collapses Axis 2 onto whatever it forces and defeats independence
silently; `CLAUDE_CODE_SUBAGENT_MODEL` without `_FORCE` is only a default for dispatches that
omit `model`, which this contract never does, so it is harmless here.

---

## Migration from the old keys

The old keys are **no longer read** (clean break, 2026-07-26):

| Old | New |
|---|---|
| `pipeline.sanity_check.model` | `models.sanity` |
| `pipeline.sanity_check.focuses` | `agents.sanity_focuses` |
| `pipeline.review_fix.model` | `models.code_review` |
| `pipeline.review_fix.second_pass_model` | `models.code_review_second_pass` |
| `pipeline.review_fix.lenses` | `agents.code_review_lenses` |
| `pipeline.review_fix.passes` | `agents.code_review_passes` |
| `pipeline.review_fix.max_fix_loops` | `agents.code_review_max_fix_loops` |
| `pipeline.decompose_min_tasks` | `agents.decompose_min_tasks` |

`pipeline.review_fix.enabled` / `.mode` / `.blocking` stay under `pipeline.review_fix` — they
are stage *behavior*, not model or count selection. (`.confidence_threshold`,
`.auto_approve_after`, `.max_diff_lines` and `.max_files` were specified but never built; they
have been removed rather than left standing as config that reads like behavior.)

A repo still using an old key silently gets the built-in default. `/repo-onboarding`
rewrites the block; `/repo-health` flags leftovers.

