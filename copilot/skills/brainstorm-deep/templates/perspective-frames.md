# Perspective frames — 8 frames

Frames are *lenses against the same idea*, not personas writing separate sections. Each frame is a Sonnet sub-agent. Default set is the first four; the rest are opt-in via `--frames <list>`.

Each agent receives:
- The agreed framing from Pass 1 (what we're solving)
- The user's clarification answers from Pass 2
- The frame prompt below

Each agent returns **≤300 words** in the requested shape. Frames inform the plan; user intent wins ties.

---

## 1. inversion (default)
**Intent**: what would make this fail catastrophically?

> Imagine the goal is to make this feature **fail badly**. What design choices, dependencies, or assumptions would guarantee failure? Name 5 specific failure-inducing choices, ranked by likelihood that the current plan accidentally makes them. For each, name the smallest change that prevents it.

**Output shape**: numbered list of 5, each `<choice> — likelihood — smallest preventer`.

---

## 2. pre-mortem (default)
**Intent**: it's 6 months later. This shipped. It failed. Why?

> It is six months from today. This feature shipped on schedule, on budget, and on spec — and it has clearly failed. Write the post-mortem. What was the root cause? What signals were ignored? What's the lesson for *now*, before we build it?

**Output shape**: 3 paragraphs — root cause, ignored signals, lesson-for-now. Concrete and specific.

---

## 3. steelman (default)
**Intent**: strongest case for not building this at all.

> Make the strongest possible argument for **not building this feature**. Assume a thoughtful skeptic on the team — they're not lazy or contrarian, they have real reasons. What are the three best reasons to drop this? For each, what would have to be true for the reason to bite hard?

**Output shape**: 3 reasons, each with the precondition that activates it.

---

## 4. adjacent-reuse (default)
**Intent**: what already half-solves this?

> Look at the codebase, the team's recent shipped features, and well-known external tools. What already exists that **half-solves** this problem? For each candidate, what would we need to add or change to make it solve the *full* problem? Is "extend the existing thing" cheaper than "build new"?

**Output shape**: 2–4 candidates, each with `<candidate> — what it does — gap to close — extend-vs-build verdict`.

---

## 5. ten-x-zero-one-x (opt-in)
**Intent**: stress-test ambition.

> Two scenarios. (a) This feature must be **10× cheaper** to build and run than the current plan implies — what's the smallest version that still delivers real value? (b) This feature must be **10× more ambitious** — same problem, much larger scope — what would that look like? Use both to triangulate the right ambition level.

**Output shape**: two paragraphs (one per scenario) and a one-line recommendation on which axis to lean toward.

---

## 6. first-principles (opt-in)
**Intent**: rederive from constraints, ignore convention.

> Forget how this is usually done. Starting only from the user's actual goal and the hard constraints surfaced in Pass 2, derive the design. What's the simplest mechanism that satisfies *only those constraints*? Compare it to the current plan — where do they differ, and why?

**Output shape**: derived design (≤150 words) + diff vs. current plan (≤150 words).

---

## 7. job-to-be-done (opt-in)
**Intent**: what's the user actually hiring this for?

> The user is "hiring" this feature to do a job for them. What's the **real job** beneath the surface request? What would the user fire it for failing to do? If we delivered the feature exactly as specified but failed at the underlying job, what would that look like?

**Output shape**: the surface ask, the real job, the failure mode that ships the surface ask but misses the job.

---

## 8. cost-of-delay (opt-in)
**Intent**: ship-now vs. wait math.

> What does waiting 3 months to ship this cost (in opportunity, compounding pain, lost user trust)? What does shipping it *now* cost (in rushed quality, scope creep, premature commitment)? Which side wins, and by how much?

**Output shape**: cost of waiting (one paragraph), cost of shipping now (one paragraph), verdict + rough margin.

---

## How to run (Copilot — sequential)

For each selected frame **in order**, run one chat turn using the frame's prompt: "Intent" + the bolded prompt above + the agreed framing + clarification answers. Capture the ≤300-word output, append it under the matching subsection in the plan's `## Perspective passes`, then move to the next frame.

No parallel dispatch on Copilot today — sequential is slower but the same total token cost. When Copilot adds a parallel sub-agent primitive, this overlay will be upgraded.
