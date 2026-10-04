# Models — the single model-selection contract

**Every model-tier and reviewer-count knob in this toolkit lives in one place: the
`models` and `agents` blocks of `.claude/project.json`.** This file is the canonical
spec for all of them. A skill needs only a one-line pointer here plus the
print-then-dispatch rule — never inline the syntax (keeps skills under their line
ceilings).

## Contents

- [The config surface](#the-config-surface)
- [Two axes — keep them mechanically separate](#two-axes--keep-them-mechanically-separate)
- [Axis 1 — the cap is a CEILING, not a setting](#axis-1--the-cap-is-a-ceiling-not-a-setting)
- [Axis 2 — the reviewer](#axis-2--the-reviewer)
- [A third kind — `models.planner` (advisory, neither axis)](#a-third-kind--modelsplanner-advisory-neither-axis)
- [Agent counts (`agents.*`)](#agent-counts-agents)
- [Reasoning effort — not settable here](#reasoning-effort--not-settable-here)
- [Prose dispatch rule (the DEFAULT path)](#prose-dispatch-rule-the-default-path--this-is-what-makes-any-of-it-real)
- [Runtime regimes](#runtime-regimes)
- [Invalid input — fall through, never guess](#invalid-input--fall-through-never-guess)
- [Session nudge](#session-nudge)
- [Migration from the old keys](#migration-from-the-old-keys)

## The config surface

```json
"models": {
  "cap": "sonnet",
  "sanity": null,
  "planner": "opus",
  "code_review": "opus",
  "code_review_second_pass": "sonnet"
},
"agents": {
  "sanity_focuses": ["paths", "completeness", "gotchas"],
  "code_review_lenses": ["correctness", "plan-alignment", "config-env-docs", "security"],
  "code_review_max_lenses": 4,
  "code_review_passes": 1,
  "code_review_max_fix_loops": 3,
  "decompose_min_tasks": 6,
  "decompose_min_files": 12
}
```

Every key is optional; a missing key means the built-in default. `models.sanity` accepts a
string or a per-focus map (*Per-stage tiers* below); `models.planner` is a session-model
recommendation, not a dispatch tier (*A third kind* below). The old `pipeline.*.model`
keys are no longer read (see *Migration* at the end).

## Two axes — keep them mechanically separate

This is the one rule a future edit must not break.

| | **Axis 1 — the fan-out ladder** | **Axis 2 — the adversarial reviewer** |
|---|---|---|
| Keys | `models.cap`, `models.sanity` | `models.code_review`, `models.code_review_second_pass` |
| Values | `haiku` \| `sonnet` \| `opus` | `haiku` \| `sonnet` \| `opus` \| `fable` |
| Stages | 1.5, 2, and every other fan-out | 5.7 / 5.8 only |

Never route an Axis 2 value through the Axis 1 cap, and never let a dispatch omit `model`: a
dispatch with no `model` inherits the session tier and bypasses the cap with zero error and
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
`models.sanity` exists: Stage 1.5's `paths` focus defaults to Haiku and is never gated, so
before this key existed the whole stage ran at Haiku on every run with no escape hatch.

**Sonnet-first default:** the effective cap defaults to `sonnet`;
`--model opus` (cap = opus = no ceiling) is the deliberate opt-up.

The cap governs **sub-agent dispatch only** — never the session orchestrator running the
skill. See *Session nudge*.

### Per-stage tiers (Axis 1)

**Wired today: `models.sanity` only** — Stage 1.5 plan pre-flight. Built-in **per-focus**
defaults: `paths: haiku` (mechanical — does the file/symbol exist?), `completeness: sonnet` and
`gotchas: sonnet` (both judgment calls — on this repo, Haiku `completeness` checks repeatedly
misread "not yet implemented" as a plan gap). `models.sanity` accepts either a **string**
(`haiku|sonnet|opus`, applies to every focus — the original shape, unchanged) or a **map**
(e.g. `{"completeness": "opus"}`), where a focus missing from the map keeps its built-in
default. Either shape's resolved values **then still pass through the cap**:
`models.sanity: "opus"` under `cap: "sonnet"` dispatches Sonnet unless you also pass `--model
opus`. An invalid value (unknown tier, or a map entry that isn't one) falls through to that
focus's own built-in default — never a guess (*Invalid input* below). A key that parses but
gates nothing is the failure this contract exists to prevent, so per-stage keys are added when a
dispatch site reads them, not in advance.

### Resolution (Axis 1)

```
--model <tier>  >  models.<stage>  >  built-in stage default        (then capped)
--model <tier>  >  models.cap      >  no cap                        (the ceiling itself)
```

`models.sanity` follows the same ladder above, but resolved **per focus**: that focus's map
entry, else the string value (if `models.sanity` is a string), else that focus's own built-in
default (`paths: haiku`, `completeness: sonnet`, `gotchas: sonnet`) — then capped as usual.

`--model <tier>` is a per-run escape hatch that wins **both directions** — it may raise a
standing `sonnet` config for one run, because you asked explicitly.

**Enforcement (Claude, opt-in).** Prose is the default enforcement surface. With
`pipeline.enforce_cap: true`, a PreToolUse hook on the Agent tool rewrites any dispatch `model`
above the cap down to it and fills in a missing `model` (a pinned agent definition keeps its
pin). Axis 2 is exempt by a marker: every reviewer dispatch's `description` starts `review:`.
The hook cannot see `--model`, so under enforcement the config cap is policy — raise it in
`project.json` for a run that needs Opus. Each rewrite is reported as a `systemMessage`.

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

### Independence — observed, never enforced by re-tiering

The reviewer should differ from the implementer's effective tier. When the two collide, the
stage **still dispatches the value you configured** and marks `review.json.data.independence`
`"degraded"` (findings surfaced, never auto-fixed), with one log line. It never bumps the
reviewer to a higher tier on your behalf — an explicit Axis 2 value is always the dispatched
value.

**Checked twice, printed twice.** This same collision is computed from the rule above at two
points in `/sdlc`: once at Stage 0, from the resolved config alone, before any stage has spent a
token; and again at Stage 5.7, immediately before the reviewer dispatches. Both print the same
line:

```
review: reviewer (<model>) and implementer (<tier>) resolve to the same tier — independence
        degraded; findings are surfaced, never auto-fixed. Set models.code_review to a
        different tier (or fable) to restore it.
```

Stage 0 computes this from this section alone — the resolved `models.code_review` /
`--review-model` against the implementer's effective tier (its stage default, capped) — and
**must never open `stage-5.7-review-fix.md`** to do so: that template is opt-in and permanently
OFF by default, and a default run must never load it just to run this check.

### The cap interaction — say it out loud

`models.cap` does **not** govern Axis 2 (a capped reviewer collapses onto the implementer and
defeats independence). From outside it reads as a bug: `cap: sonnet` next to N Opus lenses with
nothing connecting the two. So when a cap is set **and** the reviewer outranks it, Stage 5.7
emits its cap-interaction line once — the literal text lives in `stage-5.7-review-fix.md`, the
file open at emit time. Axis 2's cost is `(lenses + verify + fix-planner) x reviewer model`, so
**fan-out width, not `models.cap`, is what bounds it.**

## A third kind — `models.planner` (advisory, neither axis)

`models.planner` (default `"opus"`; `haiku|sonnet|opus|fable`) is not a dispatch tier — it never
governs a sub-agent, and `models.cap` never lowers it. It is a **session-model recommendation**
for `/brainstorm` and `/brainstorm-team`'s planning conversation, which runs on your host session
model, not a sub-agent (same reason there is no `models.*_effort` key — see *Reasoning effort*
below). Both skills print it once per session, reusing the *Session nudge* wording below and
never detecting the host model:

```
Planning runs on your session model. Recommended: <planner> — switch before the
clarifying rounds if you aren't on it.
```

An invalid value (unrecognized tier) falls through to the default, per *Invalid input* below.

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
| `agents.decompose_min_files` | `12` | Stage 2 decompose gate's OR partner — decompose when `task_count` OR `len(files_to_change)` clears its threshold, catching a small step count that spans a large file count |

An unrecognized entry in any list is ignored with one warning — the lists are deliberately
open so a repo can add its own.

## Reasoning effort — not settable here

There is deliberately **no `models.*_effort` key** — the Agent tool exposes `model` but no
`effort` parameter, so the key would silently do nothing. To make a stage think harder, **raise
its tier**. Background: `docs/MODEL-AXES.md`.

## Prose dispatch rule (the DEFAULT path — this is what makes any of it real)

On the prose path the orchestrator dispatches sub-agents itself, so these keys are only as
real as this rule. **Before every fan-out dispatch**, print the resolved tier on its own
line, then dispatch at it:

```
model: <resolved-tier> (cap: <cap|none>)
```

Where a stage also has a count knob, print the resolved list too — e.g.
`sanity focuses: paths, completeness (2 of 3 defaults)`. A reduced fan-out must never be
silent. Stage 1.5 additionally has a per-focus tier, so its `model:` line names each dispatched
focus instead of one resolved tier — `model: paths=<t>, completeness=<t>, gotchas=<t> (cap:
<cap|none>)` — see `stage-1.5-sanity-check.md`. `validate_skills.py` checks that fan-out skills
point at this file.

## Runtime regimes

- **Claude** → parallel sub-agents; the tier resolved below is passed at each dispatch.
  Claude Code also has `CLAUDE_CODE_SUBAGENT_MODEL` (a default for dispatches that omit
  `model`) and `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1` (v2.1.257+, overrides *every* dispatch,
  frontmatter included). The former is a safe floor under this contract; the latter collapses
  Axis 2 onto Axis 1 and defeats reviewer independence — do not set it on a repo that enables
  the review stage.
- **Copilot** → stages run inline in the session model; the cap is **advisory** (there is no
  sub-agent tier to lower). The `agents.*` counts still apply.
- **Codex** → product fact, not toolkit behavior: Codex has native subagents
  (`.codex/agents/*.toml`, parallel, `max_threads`) and per-subagent `model` override works
  today. But **this toolkit's Codex overlay dispatches no sub-agents** — every stage runs
  inline in the session model, the same shape as Copilot — so **the cap is advisory on Codex
  today**, for a different reason than Copilot's (no sub-agent seam here vs. structurally
  inline there). Codex executors (e.g. a GPT model dispatched via `.codex/agents/*.toml`) are
  not planned. Background: `docs/MODEL-AXES.md`.

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

The `pipeline.*` model keys were renamed to `models.*` / `agents.*`. A repo still using an old
key silently gets the built-in default. Full mapping: `docs/MODEL-AXES.md`.
