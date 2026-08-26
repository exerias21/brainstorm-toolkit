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

inherits the session effort there. If you need a stage to think harder today, **raise its
tier** — that works on every path. Revisit if the Agent tool ever gains the parameter.

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

