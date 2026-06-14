export const meta = {
  name: 'brainstorm-deep-pass3',
  description: 'Claude-only deterministic Pass 3 of /brainstorm-deep: the parallel perspective-frame fan-out + 3 plan-variant drafting. Mirrors the prose Pass 3 in skills/brainstorm-deep/SKILL.md, which stays the cross-tool source of truth. The interactive passes (1/2), variant SELECTION, and the pre-write expectation-contract gate stay in the main thread — a Workflow cannot converse with the user.',
  phases: [
    { title: 'Frames', detail: 'one Sonnet agent per selected frame, in parallel (true barrier)' },
    { title: 'Variants', detail: 'draft conservative/default/ambitious variants informed by the frames' },
  ],
}

// ---------------------------------------------------------------------------
// SCOPE — this Workflow is Pass 3's AUTONOMOUS slice only. /brainstorm-deep is a
// hybrid: Pass 1 (understand) and Pass 2 (saturate-by-questioning) are
// interactive dialogue, and variant selection + the expectation-contract
// pre-write gate are also interactive. Those CANNOT live in a Workflow (it
// orchestrates autonomous agents and can't pause for the user). So the main
// thread runs the conversation, gathers the agreed framing + clarifications +
// selected frames, and — only when ultracode is explicitly on — hands them to
// this Workflow to run the frame fan-out deterministically, then takes the
// returned drafts back for selection, assembly, the contract gate, and Write.
//
// The win: the parallel barrier is guaranteed (no silently-serialized or
// dropped frames), and each frame's output shape is schema-validated.
// ---------------------------------------------------------------------------

const framing = args?.framing ?? ''
const clarifications = args?.clarifications ?? '(none captured)'
const conventions = args?.conventions ?? '(no convention recon provided)'
const ambition = args?.ambition ?? null // 'conservative' | 'default' | 'ambitious' | null

if (!framing) throw new Error('brainstorm-deep-pass3: args.framing (the agreed "what we\'re solving") is required')

// The 8 frames, inlined from skills/brainstorm-deep/templates/perspective-frames.md
// (the script sandbox has no filesystem access, so the prompts live here; keep
// them in sync with the template if it changes).
const FRAMES = {
  'inversion': {
    intent: 'what would make this fail catastrophically?',
    prompt: 'Imagine the goal is to make this feature FAIL badly. What design choices, dependencies, or assumptions would guarantee failure? Name 5 specific failure-inducing choices, ranked by likelihood that the current plan accidentally makes them. For each, name the smallest change that prevents it.',
    shape: 'numbered list of 5, each: <choice> — likelihood — smallest preventer',
  },
  'pre-mortem': {
    intent: "it's 6 months later. This shipped. It failed. Why?",
    prompt: 'It is six months from today. This feature shipped on schedule, on budget, and on spec — and it has clearly failed. Write the post-mortem. What was the root cause? What signals were ignored? What is the lesson for NOW, before we build it?',
    shape: '3 paragraphs — root cause, ignored signals, lesson-for-now. Concrete and specific.',
  },
  'steelman': {
    intent: 'strongest case for not building this at all.',
    prompt: 'Make the strongest possible argument for NOT building this feature. Assume a thoughtful skeptic with real reasons. What are the three best reasons to drop this? For each, what would have to be true for the reason to bite hard?',
    shape: '3 reasons, each with the precondition that activates it.',
  },
  'adjacent-reuse': {
    intent: 'what already half-solves this?',
    prompt: 'Look at the codebase, the team\'s recent shipped features, and well-known external tools. What already exists that HALF-solves this problem? For each candidate, what would we need to add or change to make it solve the full problem? Is "extend the existing thing" cheaper than "build new"?',
    shape: '2–4 candidates, each: <candidate> — what it does — gap to close — extend-vs-build verdict',
  },
  'ten-x-zero-one-x': {
    intent: 'stress-test ambition.',
    prompt: 'Two scenarios. (a) This feature must be 10x cheaper to build and run than the current plan implies — what is the smallest version that still delivers real value? (b) This feature must be 10x more ambitious — same problem, much larger scope — what would that look like? Use both to triangulate the right ambition level.',
    shape: 'two paragraphs (one per scenario) + a one-line recommendation on which axis to lean toward.',
  },
  'first-principles': {
    intent: 'rederive from constraints, ignore convention.',
    prompt: 'Forget how this is usually done. Starting only from the user\'s actual goal and the hard constraints surfaced in Pass 2, derive the design. What is the simplest mechanism that satisfies ONLY those constraints? Compare it to the current plan — where do they differ, and why?',
    shape: 'derived design (≤150 words) + diff vs. current plan (≤150 words).',
  },
  'job-to-be-done': {
    intent: 'what is the user actually hiring this for?',
    prompt: 'The user is "hiring" this feature to do a job. What is the REAL job beneath the surface request? What would the user fire it for failing to do? If we delivered the feature exactly as specified but failed at the underlying job, what would that look like?',
    shape: 'the surface ask, the real job, the failure mode that ships the surface ask but misses the job.',
  },
  'cost-of-delay': {
    intent: 'ship-now vs. wait math.',
    prompt: 'What does waiting 3 months to ship this cost (opportunity, compounding pain, lost user trust)? What does shipping it NOW cost (rushed quality, scope creep, premature commitment)? Which side wins, and by how much?',
    shape: 'cost of waiting (one paragraph), cost of shipping now (one paragraph), verdict + rough margin.',
  },
}

const DEFAULT_FRAMES = ['inversion', 'pre-mortem', 'steelman', 'adjacent-reuse']

// Resolve + validate the requested frame list; drop unknowns (warn), keep order.
const requested = Array.isArray(args?.frames) && args.frames.length ? args.frames : DEFAULT_FRAMES
const selected = requested.filter((f) => {
  if (FRAMES[f]) return true
  log(`unknown frame "${f}" — skipping (valid: ${Object.keys(FRAMES).join(', ')})`)
  return false
})
if (!selected.length) throw new Error('brainstorm-deep-pass3: no valid frames selected')
if (selected.length > 8) throw new Error('brainstorm-deep-pass3: at most 8 frames')

const FRAME_SCHEMA = {
  type: 'object',
  required: ['frame', 'output'],
  properties: {
    frame: { type: 'string' },
    output: { type: 'string', description: 'the frame\'s stress-test, ≤300 words, in the requested shape' },
    contradicts_clarification: {
      type: ['string', 'null'],
      description: 'if this frame\'s finding contradicts a Pass-2 user clarification, name the conflict here (the main thread surfaces it for the user to resolve); else null',
    },
  },
}

const VARIANTS_SCHEMA = {
  type: 'object',
  required: ['variants'],
  properties: {
    variants: {
      type: 'array',
      items: {
        type: 'object',
        required: ['level', 'summary', 'outline', 'effort', 'risks'],
        properties: {
          level: { type: 'string', enum: ['conservative', 'default', 'ambitious'] },
          summary: { type: 'string', description: 'one paragraph' },
          outline: { type: 'array', items: { type: 'string' }, description: '5–10 implementation bullets' },
          effort: { type: 'string', description: 'estimated effort (S/M/L or a short phrase)' },
          risks: { type: 'array', items: { type: 'string' } },
        },
      },
    },
  },
}

const sharedContext = `AGREED FRAMING (what we're solving, from Pass 1):
${framing}

USER CLARIFICATIONS (from Pass 2):
${clarifications}

CONVENTIONS & REUSE (live-code recon from Pass 1; reuse over reinvent):
${conventions}`

// ----- Pass 3 step 3 — parallel frame fan-out (true barrier) -----------------
phase('Frames')

const frameResults = (await parallel(selected.map((name) => () => {
  const f = FRAMES[name]
  return agent(
    `You are the "${name}" perspective frame for a /brainstorm-deep session. You are a
lens against ONE idea, not a persona writing a section. Intent: ${f.intent}

${f.prompt}

OUTPUT SHAPE: ${f.shape}
Hard limit: ≤300 words. Frames INFORM the plan; user intent wins ties — if your finding
contradicts a user clarification above, do not override it, just flag it.

${sharedContext}

Return the structured object (frame="${name}").`,
    { label: `frame:${name}`, phase: 'Frames', schema: FRAME_SCHEMA, model: 'sonnet' }
  )
}))).filter(Boolean)

// Preserve the requested frame order in the output (parallel() returns in input order).
const conflicts = frameResults
  .filter((r) => r.contradicts_clarification)
  .map((r) => ({ frame: r.frame, note: r.contradicts_clarification }))

// ----- Pass 3 step 5 — draft plan variants, informed by the frames -----------
phase('Variants')

const levelInstruction = ambition
  ? `Produce ONLY the "${ambition}" variant (--ambition ${ambition} was set).`
  : `Produce all THREE variants: conservative (minimum viable, narrowest scope, smallest blast radius), default (what the conversation points at), ambitious (what we'd build if budget weren't a constraint).`

const variantsOut = await agent(
  `You are drafting the plan variants for a /brainstorm-deep session, INFORMED BY the
perspective frames below (they stress-tested the idea). ${levelInstruction}
Each variant: a one-paragraph summary, a 5–10 bullet implementation outline that REUSES
the conventions above (cite path:line where you can), an effort estimate, and key risks.
Frames inform but do not override user intent.

${sharedContext}

PERSPECTIVE-FRAME FINDINGS:
${frameResults.map((r) => `### ${r.frame}\n${r.output}`).join('\n\n')}

Return the structured object.`,
  { label: 'variants', phase: 'Variants', schema: VARIANTS_SCHEMA, model: 'sonnet' }
)

// Return structured drafts to the main thread. The main thread (interactive)
// presents variants for selection, surfaces any conflicts, assembles the final
// plan per the Output template, runs the expectation-contract pre-write gate,
// and Writes plans/brainstorm-deep-<slug>.md.
return {
  frames: frameResults.map((r) => ({ frame: r.frame, output: r.output })),
  conflicts,
  variants: variantsOut?.variants ?? [],
  note: 'Pass 3 autonomous slice complete. Main thread: present variants, resolve conflicts, assemble, run the four-section expectation-contract gate, then Write.',
}
