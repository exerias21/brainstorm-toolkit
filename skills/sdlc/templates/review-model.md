# Reviewer model — shared contract

Canonical spec for the **reviewer-model axis** — the model dispatched for the adversarial
Review→Fix stage (Stage 5.7 review / Stage 5.8 fix loop) in `/sdlc` and `/sdlc-lite`. Sibling to
`model-cap.md`, but a **wholly independent axis**: a skill needs only a one-line pointer to this
file — do not inline the resolution syntax or the dispatch note (keeps skills under their line
ceilings).

## What it is

A **model selection for the adversarial reviewer**, independent of the implement/fan-out ceiling
(`--model` / `models.cap` / `model-cap.md`). `model-cap.md`'s entire contract is
`effective_tier = min(default_tier, cap)` over the closed rank `haiku(1) < sonnet(2) < opus(3)`
(`capModel(defaultTier, cap)` — see `model-cap.md`). Fable is not a fourth rung on that ladder — it
is chosen for being a *different model from the implementer*, not for being cheaper or pricier.

**`fable` must never be passed to `capModel()`.** Doing so silently no-ops it back to whatever tier
the call site already defaults to, with zero error and zero log line. This is the single
highest-priority implementation hazard on this axis.

**Fable demotion note.** Claude Fable 5's promotional/plan-included access ends 2026-07-07
(11:59:59 PM PT). After that date it remains exactly as dispatchable as before —
`agent({model:'fable'})` still works — but it is now billed via paid usage credits, outside plan
weekly limits, rather than being free/plan-included. That cost shift, not a dispatch regression, is
why `fable` is no longer the default reviewer model: it demotes to an explicit, cost-aware
`--review-model fable` opt-in. The default reviewer model is **`opus`**.

## Resolution — reviewer MODEL (independent precedence chain)

```
--review-model <value>            (explicit, wins outright)
  > project.json  pipeline.review_fix.model
  > skill default: "opus"
```

Valid values: `fable`, `opus`, `sonnet`, `haiku`. `opus`, `sonnet`, and `haiku` pin the reviewer to
a fan-out tier (`opus` is the default). `fable` opts into a model outside the tier ladder entirely
— a deliberate, cost-aware choice, not a stand-in for the default.

### Invalid / malformed input — fall through, never guess

Follows `model-cap.md`'s own rule verbatim: an unknown `--review-model` value, or a malformed
`pipeline.review_fix.model`, is **ignored with one warning**, falling through to the next
precedence level — never a hard failure, never a guess.

### Runtime-availability fallback

A resolved model *name* (above) is a separate concern from a resolved model the runtime/account
**cannot dispatch at all**. `fable` is explicitly NOT an unavailability case — Claude Fable 5
remains fully dispatchable after its 2026-07-07 sunset, it is simply no longer free, so an explicit
`--review-model fable` opt-in never routes through this fallback on cost or plan-limit grounds.

If a reviewer dispatch fails because the resolved model truly cannot be dispatched, **fall back to
the highest available of `opus`/`sonnet`/`haiku`, preferring `opus`** — logged once (`review:
<model> unavailable — falling back to <tier>`). Because the default reviewer is already `opus`,
the fallback target and the default coincide in the common case — this is a general availability
safety net, not a mechanism that exists because Fable used to be the cheap default and is now gone.

The **effective** model actually dispatched (after this fallback, and after the independence bump
below) — not the raw resolved name — is what `review.json.data.reviewer_model` records, so the
sidecar never claims a review ran on a model that wasn't available.

## Cost surface — fan-out width, and the cap interaction users misread

The stage's cost is `(lenses + verify + fix-planner) × reviewer model`, and **every one of those
calls is at the reviewer model** — so the width of the fan-out, not `models.cap`, is what bounds it.

**Fan-out width** resolves in three steps, in this order:

1. `pipeline.review_fix.lenses` selects **which** lenses (absent → the four defaults).
2. Circuit-breaker demotion drops any lens the rolling ledger marks demoted.
3. `pipeline.review_fix.max_lenses` truncates **how many** survive, in list order. Absent, or any
   non-integer / non-positive value → `4`. Never let it resolve to `0` — an empty fan-out silently
   disables the stage rather than failing it.

Truncation is list-ordered so a `max_lenses: 1` run keeps `correctness`, the highest-yield lens.

**The interaction to warn about.** `models.cap` does not govern this axis — deliberately, since a
capped reviewer would collapse onto the implementer and defeat independence. But from outside it
reads as a bug, and the independence check *hides* it: `cap: sonnet` puts the implementer on
sonnet, which **satisfies** the same-tier check, so the reviewer stays at full `opus` and no
bump/degrade line ever fires. The user sees `cap: sonnet` and N `opus` agents, with nothing
connecting the two.

So when a cap is set **and** the reviewer outranks it, emit once:

```
review: reviewer runs <model> on <n> lens(es) + verify + fix-planner. models.cap (<cap>) does
        NOT govern this axis — lower it with pipeline.review_fix.model, or cut the fan-out with
        pipeline.review_fix.max_lenses. See templates/review-model.md.
```

This is a **log line only**. Never "fix" the interaction by routing the reviewer model through
`capModel()` — that silently no-ops it back to the call site's default tier, with zero error and
zero log line, and is the highest-priority hazard on this axis (see above).

## Resolution — ENABLEMENT (a separate precedence chain from model choice)

```
--no-review                                          → OFF, always wins
--review-model <value>                                → ON (explicit opt-in)
pipeline.review_fix.enabled: true                    → ON (explicit opt-in), subject to auto-off gates
pipeline.review_fix.enabled: false | omitted | absent → OFF (default)
```

**Opt-in, permanently.** There is no default-on flip, planned or scheduled.
`pipeline.review_fix.enabled` defaults to `false`, and an absent `pipeline.review_fix` block also
means OFF — "omitted" never resolves to ON. The stage activates only on an explicit
`--review-model <name>` flag or an explicit `pipeline.review_fix.enabled: true` in `project.json`.
`--no-review` always wins over either.

**Auto-off gates** (apply even when the chain above resolves ON): a docs-only / no-code-surface
diff self-skips the stage — **except in skill-repo mode**, where `.md` skill files *are* the code
surface, so this gate is skipped entirely and Stage 5.7 adapts instead of self-skipping.

## Independence enforcement

At dispatch time, resolve both the implementer's effective tier (`capModel('opus', MODEL_CAP)`) and
the reviewer's resolved value. If the reviewer value is one of the three tier names (not `fable`)
**and** it resolves to the *same* tier the implementer used — whether from an explicit
`--review-model {opus|sonnet|haiku}` override or from the default resolution itself — independence
is not established: bump the reviewer one tier up (`sonnet` → reviewer runs `opus`; if the
implementer is already `opus`, mark `data.independence = "degraded"` in `review.json` and warn
once). The bumped value is the *effective* dispatch tier — every reviewer/verify/fix-planner call,
and `review.json.data.reviewer_model`, use it once a bump applies. Any finding produced under a
`"degraded"` run fails the auto-fixable rubric's independence criterion and can never be
auto-fixed — only surfaced.

`fable` is independent of the tier ladder by construction, so this check only applies when the
reviewer resolves to one of the three tier names. The single most common way a run lands in
`"degraded"` needs no `--review-model` flag at all: `--model opus` (bumping the implementer to
`opus`) combined with the unmodified default reviewer (`opus`) is a same-tier collision that cannot
be bumped any higher.

## Dispatch — settled (confirmed live)

**Confirmed:** `agent({model:'fable'})` dispatches `claude-fable-5` natively on the Claude
Agent/Task seam and the Workflow's `agent()` helper — no persona-fallback dual-path needed, and
this remains true after Fable's 2026-07-07 sunset. Stage 5.7/5.8 dispatch the
reviewer/verify/fix-planner agents with `model: REVIEW_MODEL` **directly, never through
`capModel()`** — exactly as `agent()` calls elsewhere already do for `haiku`/`sonnet`/`opus`.
`fable` still must never be passed to `capModel()` (that ladder only ranks haiku/sonnet/opus) —
what's settled here is only that the dispatch seam *accepts* the literal string `"fable"`, not that
it should ever go through the cap.

The runtime-availability fallback above (a genuine dispatch failure on whichever model resolves) is
a separate, retained safety net — a one-line model swap at the dispatch seam, not a second review
mechanism, and not keyed to Fable specifically.

**Out of scope here:** the Copilot/Codex overlays have no parallel sub-agent seam at all; they
review under an adversarial persona in the session model, or a reachable MCP reviewer if
configured. That approximation is unaffected by this dispatch confirmation — it was never a "does
the seam accept fable" question on that runtime, since there is no seam to ask.
