# Model-tier cap — shared contract

Canonical spec for the **model-tier cap**, referenced by every fan-out skill
(`/sdlc`, `/sdlc-lite`, `/brainstorm`, `/brainstorm-deep`, `/brainstorm-team`)
so the rule lives in **one** place. A skill needs only a one-line pointer to
this file plus the print-then-dispatch rule below — do not inline the syntax or
the nudge text (keeps skills under their line ceilings).

## What it is

A **ceiling on sub-agent model tier**, not a swap. Tiers rank:

```
haiku (1)  <  sonnet (2)  <  opus (3)
effective_tier = min(default_tier, cap)     # cap only ever lowers
```

So `cap = sonnet` turns every Opus dispatch into Sonnet while **Haiku stays
Haiku and Sonnet stays Sonnet** — you save on the expensive calls without
upgrading the cheap ones.

**Sonnet-first default:** the fan-out skills default the effective cap to
`sonnet` — in the Workflow, `MODEL_CAP = args?.model_cap ?? 'sonnet'`; in prose,
the dispatch sites read "Sonnet by default". So **out of the box Opus sites run
Sonnet**; `--model opus` (cap = opus = no ceiling) is the deliberate opt-up to
Opus for a run. Haiku sites stay Haiku regardless. A decompose lane flagged
`opus` for high complexity therefore also dispatches Sonnet unless the run opts
up — that matches "Sonnet is enough 99% of the time".

The cap governs **sub-agent dispatch only** — never the session orchestrator
(the model running the skill). See "Session nudge" below.

## Resolution (precedence)

```
--model <tier>  >  project.json  models.cap  >  skill default
```

- **`--model <tier>`** (per-run flag): an explicit one-off **escape hatch**. It
  wins **both directions** — `--model opus` may *raise* a standing `sonnet`
  config for a single run (intentional: you asked for it explicitly this run).
- **`project.json` → `models.cap`**: the standing policy. Optional; absent = no
  cap. Read with graceful-skip.
- **skill default**: the tiers hard-coded in each stage.

### Invalid / malformed input — fall through, never guess

- `--model` with an unknown value (`sonet`, `gpt4`), or no argument → **ignore
  the flag, warn once, fall through to `models.cap`** (then default).
- `models` present but malformed (a string, `cap: true`, or a non-tier value) →
  **treat as absent** (no cap).
- `cap == default_tier` → no-op.
- Valid caps are exactly `haiku`, `sonnet`, `opus`.

## Prose dispatch rule (the DEFAULT path — this is what makes the cap real)

On the prose path (non-ultracode Claude), the orchestrator dispatches
sub-agents itself, so the cap is only as real as this rule. **Before every
fan-out Agent dispatch**, compute the resolved tier and print it on its own
line, then dispatch at that tier:

```
model: <resolved-tier> (cap: <cap|none>)
```

`validate_skills.py` asserts this line sits adjacent to each fan-out dispatch —
a missing one fails validation, so a dropped cap check breaks CI, not your bill.
On the **Workflow** path the same resolution is enforced in code by
`capModel()` at the `agent()` seam (`skills/sdlc/workflows/*.workflow.js`); the
skill passes the resolved cap as `args.model_cap`.

## Runtime regimes

- **Claude + ultracode** → Workflow `capModel()` at each `agent()` seam
  (deterministic — but applied **per call**: an `agent()` that omits `model`
  inherits the main-loop/session tier and **bypasses the cap**, so a new dynamic
  workflow must wrap *every* dispatch in `capModel()` and read
  `MODEL_CAP = args?.model_cap ?? 'sonnet'`). The orchestrator/session model that
  runs the control flow is never capped.
- **Claude, no ultracode** → prose dispatch rule above (checked by the validator).
- **Copilot / Codex** → stages run **inline in the session model** (no separate
  parallel sub-agents), so the cap is **advisory** here — there is no sub-agent
  tier to lower. Honor it by setting the session model (nudge below).

## Session nudge

When a cap is active, emit **once per session** (skills can't read the host
model, so don't try to detect — just don't repeat):

```
Sub-agents capped at <cap>. For full savings, also set your session model to
<cap> — the session orchestrator isn't governed by this cap.
```

Tool-agnostic wording ("set your session model") — not `/model`, which is
Claude-specific.
