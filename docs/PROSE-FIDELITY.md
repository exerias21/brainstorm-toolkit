# Prose fidelity — prescriptive steps get followed, abstract steps get improvised

A design lesson from dogfooding the loop skills against real work (2026-07). It is the
single most useful thing we learned about *why* a skill sometimes does exactly what its
SKILL.md says and sometimes freelances — and what to do about it.

## The observation (two live runs, opposite outcomes)

Within the same afternoon, two skills ran on real tasks and produced opposite fidelity:

- **`/sdlc --queue` — FOLLOWED the prose.** After the DQ1/DQ2/DQ4 hardening, an
  agent-executed queue run wrote envelopes that conformed *exactly*: canonical keys
  (`feature_slug`, `plan_file`, `schema_version`), a distinct per-item slug
  (`n-attr-requester-attribution`, not the shared plan slug), canonical stage names
  (`implement`/`validate`/`handoff`), and queue metadata parked correctly in `data.*`.
  The *pre-fix* run of the same skill had improvised `slug`/`plan`/`mode` keys and
  `phase-0`/`phase-A` stages — and that shape was **not reproduced** after the fix.
- **`/brainstorm` Step 4b — IMPROVISED the prose.** In a parallel run, the skill's
  mandated "four lateral-thinking lenses" (First Principles / Inversion / Cross-Domain
  Analogy / Constraint Removal) were silently replaced with domain-research fan-out
  (OSS-tool surveys, pyATS deep-dives). Good work — but not the divergence the step
  exists to force.

## The principle

> **Concrete, checkable prose gets followed. Abstract prose gets interpreted.**

The `--queue` fix worked because it is *prescriptive and verifiable*: it names exact field
keys, an exact slug formula (`<plan-slug>-<row-id>`), and hard negatives ("never `phase-*`").
A monitor can `grep` an envelope and decide conformance in seconds — and, crucially, so can
the executing agent while it writes. Step 4b failed because "four lateral-thinking lenses" is
an *invitation to interpret*: the agent, handed a rich technical task, produced something
plausible for the domain instead.

This reframes the toolkit's "fidelity gap." It is **not** "agents always improvise." It is
"agents follow instructions they can check themselves against, and reinterpret the ones they
can't." That gap is closable with prose — proven, not theorized: the DQ fixes changed real
agent behavior.

## How to apply it when authoring / hardening a skill

For any step where the *output shape or state matters* (envelopes, sentinels, file paths,
schemas, gate contracts):

1. **Name the exact artifact.** Exact keys, exact filenames, exact command strings — not
   "the canonical envelope" but "`feature_slug`, `plan_file`, `plan_hash`, …".
2. **State a formula, not a vibe.** "slug = `<plan-slug>-<row-id>`", not "a distinct slug".
3. **Write the hard negatives.** "never `phase-*`", "never rename a canonical key",
   "never leave `status:in_progress` on a park". Negatives catch the specific improvisation
   you've seen.
4. **Make it grep-checkable.** If a reviewer (or the agent) can't mechanically verify the
   step was done, tighten it until they can. Cross-reference the schema/contract doc so
   "conformant" has one definition.

Reserve abstract framing for steps that are *genuinely open-ended and creative* — and accept
that those will be interpreted. If such a step nonetheless has a load-bearing structural
requirement (Step 4b's "produce four *distinct* wildcard entries in a labeled section"),
make **that** part prescriptive even while the content stays free.

## Corollary

Prose-hardening is a *cheaper* fidelity lever than porting a step to the deterministic
Workflow (which can't improvise because it's code). Reach for the Workflow when a step must
be mechanically guaranteed at scale; reach for prescriptive prose first when the step just
needs to be *followed*. The DQ fixes are the existence proof that the cheap lever works.

## Evidence trail

- `skills/sdlc/SKILL.md` Queue mode + `skills/sdlc/templates/state-schema.md`
  "Queued / multi-item runs" + `docs/CONVENTIONS.md` "Queued per-item slugs" — the
  prescriptive DQ1/DQ2/DQ4 prose that held.
- `skills/brainstorm/SKILL.md` Step 4b — the abstract step that got improvised; a candidate
  for the "make the structural part prescriptive" treatment above.
