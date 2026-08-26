# Step 6.5 — Multi-agent vet (mode-gated)

Loaded by `skills/brainstorm/SKILL.md` **only when a vet mode is explicitly requested**. The
default run skips this stage without opening this file — that is the point of the split.

Before the single-agent validator in Step 7, optionally run a multi-lens vet
using the `--vet [light|deep|ultra|none]` flag. Multiple agents catch issues
one validator misses.

**Mode resolution** when `--vet` is not passed explicitly:
- `<5` implementation steps in the saved plan → `none` (skip this step; go
  straight to Step 7).
- `5–15` steps → `light`.
- `>15` steps OR plan has a "Cross-Module Touchpoints" section listing more
  than one module → suggest `deep` to the user; proceed with `light` if
  they decline.
- Plan grep finds keywords (`migration`, `auth`, `secret`, `oauth`,
  `public api`, `deploy`, `rollback`, `prod`) in "Files to change" or
  "Implementation Steps" → suggest `ultra` to the user. These flag
  high-blast-radius plans where extra scrutiny is worth it (opt up with
  `--model opus` for the vet reviewers if warranted).
- User can always override the suggestion via explicit `--vet <mode>`.

**Mode behavior**:

#### `none`
Skip Step 6.5 entirely. Step 7 (single validator) runs alone.

#### `light` — 3 Haiku agents in parallel
Reuse the three prompts at `skills/sdlc/templates/stage-1.5-sanity-check.md`
(`paths`, `completeness`, `gotchas`) so vetting language is consistent across
skills. Substitute `{plan_file}` = the saved plan path from Step 6 and
`{feature_name}` = the topic slug. Dispatch all three Haiku agents in a single
message. Cost: ~3 small agents, ~30s.

#### `deep` — `light` + 1 Sonnet stress-test agent
After the 3 Haiku agents return, dispatch one Sonnet agent with this prompt:

> Read the plan at {plan_file}. Try to find a way it would fail. Apply
> inversion: assume the plan is wrong, and identify the single most likely
> mode of failure under realistic load, edge cases, or operator error.
> Report under 250 words: name the failure mode, the step that introduces
> it, and a one-line fix.

#### `ultra` — `deep` + 2 top-tier agents in parallel
Model cap applies: these two reviewers are **Sonnet by default** (Opus only on
`--model opus` opt-up), resolved per
`skills/sdlc/templates/models.md` (`--model <tier>` > `project.json`
`models.cap` > default). Before dispatch, print `model: <tier> (cap: <cap|none>)`
and emit the session-model nudge once when a cap is active.
After Sonnet stress-test, dispatch the two agents (Sonnet by default; Opus on
`--model opus` opt-up) in a single message:

1. **architectural-coherence** (capped tier — Sonnet by default). Prompt:
   > Read the plan at {plan_file} and the project's CLAUDE.md/AGENTS.md.
   > Check whether the plan's structure fits the codebase's existing
   > architecture: layering, abstraction boundaries, naming conventions,
   > module ownership. Flag any contradiction with existing patterns —
   > "the plan works in isolation but violates the established X
   > convention." Cap report at 300 words.

2. **edge-case-divergence** (capped tier — Sonnet by default). Prompt:
   > Read the plan at {plan_file}. For each acceptance criterion,
   > enumerate 3–5 edge cases the plan does NOT explicitly handle:
   > nulls, empty inputs, concurrent writes, partial failures, auth
   > expiry, off-by-one boundaries, etc. Surface "happy-path only"
   > plans. Cap at 400 words.

#### Processing results

1. Collect all vet-mode reports.
2. **If issues found**: surface them to the user. For HIGH-confidence
   findings (`paths` flag a non-existent file; `architectural-coherence`
   flags a layering violation), auto-revise the plan. For lower-confidence
   findings, ask the user to adjudicate.
3. After revisions, save the updated plan back to the same path
   (overwrite — the saved plan is the source of truth).
4. Proceed to Step 7 with the post-vet plan.
