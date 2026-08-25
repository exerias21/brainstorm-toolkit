# Models — the single model-selection contract

**Every model-tier and reviewer-count knob in this toolkit lives in one place: the
`models` and `agents` blocks of `.claude/project.json`.** This file is the canonical
spec for all of them. A skill needs only a one-line pointer here plus the
print-then-dispatch rule — never inline the syntax (keeps skills under their line
ceilings).

Supersedes the former `model-cap.md` and `review-model.md`, which were split across
two files and left the per-stage tiers scattered under `pipeline.*`.

## The config surface

```json
"models": {
  "cap": "sonnet",
  "sanity": null,
  "implement": null,
  "code_review": "opus",
  "code_review_second_pass": "sonnet"
},
"agents": {
  "sanity_focuses": ["paths", "completeness", "gotchas"],
  "code_review_lenses": ["correctness", "plan-alignment", "config-env-docs", "security"],
  "code_review_passes": 1,
  "code_review_max_fix_loops": 3,
  "decompose_min_tasks": 6
}
```

Every key is optional; a missing key means the built-in default. There is **no
back-compat with the old `pipeline.*.model` keys** — they are no longer read (see
*Migration* at the end).

## Two axes — keep them mechanically separate

This is the one rule a future edit must not break.

| | **Axis 1 — the fan-out ladder** | **Axis 2 — the adversarial reviewer** |
|---|---|---|
| Keys | `models.cap`, `models.sanity`, `models.implement` | `models.code_review`, `models.code_review_second_pass` |
| Values | `haiku` \| `sonnet` \| `opus` | `haiku` \| `sonnet` \| `opus` \| `fable` |
| Capped? | **Yes** — everything passes through `capModel()` | **Never** — must not touch `capModel()` |
| Stages | 1.5, 2, 5.5, and every other fan-out | 5.7 / 5.8 only |

**`fable` must never be passed to `capModel()`.** It is not a fourth rung on the ladder;
`capModel()` would silently no-op it back to the call site's default with zero error and
zero log line. This is the highest-priority hazard in this file.

## Axis 1 — the cap is a CEILING, not a setting

```
haiku (1)  <  sonnet (2)  <  opus (3)
effective_tier = min(stage_tier, cap)      # the cap only ever LOWERS
```

`cap = sonnet` turns every Opus dispatch into Sonnet while **Haiku stays Haiku**. You save
on the expensive calls without upgrading the cheap ones.

**The consequence that surprises everyone:** a stage whose built-in tier is `haiku` cannot
be raised by the cap. `models.cap: "opus"` does not raise it; `--model opus` does not raise
it — both only lower. **The per-stage key is the only lever.** That is precisely why
`models.sanity` exist: Stage 1.5 defaults to Haiku and is never
gated, so before these keys existed it ran at Haiku on every run with no escape hatch.

**Sonnet-first default:** the effective cap defaults to `sonnet`
(`MODEL_CAP = args?.model_cap ?? 'sonnet'`), so out of the box Opus sites run Sonnet.
`--model opus` (cap = opus = no ceiling) is the deliberate opt-up.

The cap governs **sub-agent dispatch only** — never the session orchestrator running the
skill. See *Session nudge*.

### Per-stage tiers (Axis 1)

| Key | Stage | Built-in default | Raise it when |
|---|---|---|---|
| `models.sanity` | 1.5 plan pre-flight | `haiku` (all focuses) | `completeness` is judging whether a plan hangs together — judgment work. Never gated, so this costs on **every** run |
| `models.implement` | 2 implement / lanes | `sonnet` (effective) | **⚠ RESERVED — not yet wired.** Both Stage 2 dispatch sites hard-code `capModel('opus', cap)`, so this key is read by nothing today. Steer the implementer with `--model` / `models.cap` instead. The name is reserved so it stays stable when wired |

Each replaces the built-in default for that stage, **then still passes through the cap**:
default still dispatches Sonnet unless you also pass `--model opus`. These are defaults
*within* Axis 1, never a new axis.

**Wired today: `models.sanity` only.** `models.implement` is reserved
(see the table). A key that parses but gates nothing is the exact failure this contract exists to
prevent, so it is labelled rather than quietly listed alongside the working two.

### Resolution (Axis 1)

```
--model <tier>  >  models.<stage>  >  built-in stage default        (then capped)
--model <tier>  >  models.cap      >  no cap                        (the ceiling itself)
```

`--model <tier>` is a per-run escape hatch that wins **both directions** — it may raise a
standing `sonnet` config for one run, because you asked explicitly.

## Axis 2 — the reviewer

```
--review-model <value>  >  models.code_review  >  default "opus"
```

Valid: `fable`, `opus`, `sonnet`, `haiku`. `opus` is the default. `fable` opts into a model
outside the ladder entirely — chosen for being a *different model from the implementer*,
not for being cheaper.

**Fable is billed, not free.** Claude Fable 5's promotional/plan-included access ended
2026-07-07. It remains exactly as dispatchable (`agent({model:'fable'})` works), but is now
billed via paid usage credits outside plan limits. That cost shift — not a dispatch
regression — is why it is an explicit opt-in rather than the default.

`models.code_review_second_pass` (default `sonnet`) is read only when
`agents.code_review_passes` is `2`. Recall comes from a *different look*, not a stronger
repeat — so a cheaper, different model is the point.

**Runtime-availability fallback.** If a resolved reviewer truly cannot be dispatched, fall
back to the highest available of `opus`/`sonnet`/`haiku`, preferring `opus`, logged once.
`fable` being billed is **not** an unavailability case.

### The cap interaction users misread — say it out loud

`models.cap` does **not** govern Axis 2. That is deliberate (a capped reviewer collapses onto
the implementer and defeats independence), but from outside it reads as a bug, and the
independence check *hides* it: `cap: sonnet` puts the implementer on sonnet, which **satisfies**
the same-tier check, so the reviewer stays at full `opus` and no bump/degrade line ever fires.
The user sees `cap: sonnet` next to N Opus agents with nothing connecting the two.

So when a cap is set **and** the reviewer outranks it, emit once:

```
review: reviewer runs <model> on <n> lens(es) + verify + fix-planner. models.cap (<cap>) does
        NOT govern this axis — lower it with models.code_review, or cut the fan-out with
        agents.code_review_max_lenses.
```

A **log line only.** Never "fix" the interaction by routing the reviewer through `capModel()` —
it silently no-ops back to the call site's default tier, with zero error and zero log line.

Axis 2's cost is `(lenses + verify + fix-planner) x reviewer model`, and every one of those
calls is at the reviewer model — so **fan-out width, not `models.cap`, is what bounds it.**

## Agent counts (`agents.*`)

Cost on the fan-out stages scales roughly linearly with these, since each is one agent or
one reviewer call.

| Key | Default | Effect |
|---|---|---|
| `agents.sanity_focuses` | all 3 | Which Stage 1.5 checks run. `paths` is mechanical file-existence; `completeness` is the judgment-heavy one; `gotchas` only helps when `GOTCHAS.md` exists |
| `agents.code_review_lenses` | all 4 | Which Stage 5.7 reviewer lenses fan out. `correctness` is the highest-yield single lens; add `security` for auth/endpoints/user input |
| `agents.code_review_max_lenses` | `4` | Caps HOW MANY lenses dispatch (the row above picks WHICH). Applied AFTER circuit-breaker demotion, truncating in list order — so `1` keeps `correctness`. Set it to cut review cost without having to know the lens names, and without re-editing the list if the defaults change. Any non-integer or non-positive value falls through to `4`; never let it resolve to `0`, which silently disables the stage instead of failing it |
| `agents.code_review_passes` | `1` | `2` adds one completeness-critic call at `code_review_second_pass` |
| `agents.code_review_max_fix_loops` | `3` | Stage 5.8's own budget, separate from Stage 5's shared budget |
| `agents.decompose_min_tasks` | `6` | Stage 2 decompose gate threshold |

An unrecognized entry in any list is ignored with one warning — the lists are deliberately
open so a repo can add its own.

## Reasoning effort — partial support, stated honestly

Reasoning effort is **not uniformly settable**, so there is deliberately no
`models.*_effort` config key. Adding one would create a knob that silently does nothing on
the default path — the exact failure this contract exists to prevent.

| Path | Effort settable? |
|---|---|
| Workflow `agent()` (ultracode only) | **Yes** — `opts.effort`: `low`\|`medium`\|`high`\|`xhigh`\|`max` |
| Agent definition frontmatter (`agents/*.md`) | **Yes** — `effort:` |
| **Prose path (the default, and the only path on Copilot/Codex)** | **No** — the Agent tool exposes `model` but has no `effort` parameter |

Since the prose path is the source of truth and covers every non-ultracode run, effort
inherits the session effort there. If you need a stage to think harder today, **raise its
tier** — that works on every path. Revisit if the Agent tool ever gains the parameter.

## Prose dispatch rule (the DEFAULT path — this is what makes any of it real)

On the prose path the orchestrator dispatches sub-agents itself, so these keys are only as
real as this rule. **Before every fan-out dispatch**, print the resolved tier on its own
line, then dispatch at it:

```
model: <resolved-tier> (cap: <cap|none>)
```

Where a stage also has a count knob, print the resolved list too — e.g.
`sanity focuses: paths, completeness (2 of 3 defaults)`. A reduced fan-out must never be
silent. `validate_skills.py` checks that fan-out skills point at this file.

## Runtime regimes

- **Claude + ultracode** → `capModel()` at each `agent()` seam. Applied **per call**: an
  `agent()` that omits `model` inherits the session tier and **bypasses the cap**, so every
  dispatch must be wrapped.
- **Claude, no ultracode** → the prose rule above.
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
  > or `capModel()` anywhere.

## Invalid input — fall through, never guess

- Unknown `--model` / `--review-model` value, or none → ignore the flag, warn once, fall
  through to config, then default.
- Malformed `models` block (a string, `cap: true`, a non-tier value) → treat as absent.
- `cap == default_tier` → no-op.

## Session nudge

When a cap is active, emit **once per session** (skills can't read the host model — don't
detect, just don't repeat):

```
Sub-agents capped at <cap>. For full savings, also set your session model to
<cap> — the session orchestrator isn't governed by this cap.
```

Tool-agnostic wording — not `/model`, which is Claude-specific.

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
