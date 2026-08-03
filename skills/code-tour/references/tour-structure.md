# Tour structure — the template, and why each part is there

Read this at Step 6 of `SKILL.md`, when the docstrings are written and you are
composing the guided reading path.

## Contents

- [Why a tour, separately from docstrings](#why-a-tour-separately-from-docstrings)
- [The template](#the-template)
- [Section-by-section guidance](#section-by-section-guidance)
- [Worked example of one stop](#worked-example-of-one-stop)
- [Where a tour sits in Diátaxis](#where-a-tour-sits-in-diátaxis)
- [Common failure modes](#common-failure-modes)

## Why a tour, separately from docstrings

Docstrings are **reference** material: complete, precise, and consulted at the
moment you are looking at a specific function. They are indexed by the code's own
structure, which means they answer "what is this?" and never "where do I start?"

A reader arriving at an unfamiliar 30-file repo has a different problem. They do
not need completeness, they need a PATH — a small number of files in a sensible
order, with someone pointing at the parts that matter. Alphabetical order teaches
nothing. File size teaches nothing. Dependency order teaches, because it mirrors
how the system was built.

Note that a guided reading path is not a widely standardised artifact the way a
README or a changelog is. Tooling exists (VS Code's CodeTour extension stores
tours as JSON; literate programming inverts the relationship entirely), but there
is no dominant convention. A plain markdown document in the repo is the
lowest-friction form: it diffs, it reviews in a PR, it needs no extension
installed, and it renders on any git host.

## The template

Adapt rather than follow mechanically — a 5-file library does not need five
sessions. The order of sections is the part worth keeping.

```markdown
# A Guided Tour of <the codebase>

<1-3 sentences: what this document is and what the reader gets from it>

**Who this is for:** <assumed knowledge, and what this does NOT teach>
**How long:** <realistic estimate, and which sections are skippable>

## 0. Orientation
### What the system does
<the smallest accurate description, plus one diagram if it earns its place>
### Why this codebase teaches well
<what makes it worth studying — be specific, and honest if parts are ugly>
### Set up
<commands that get to a passing test run; verify these actually work>
### How to read the docstrings
<any conventions a reader should know before starting>

## Session 1 — <theme> (~<time>)
<one line on the theme and what the session builds toward>

### Stop 1.1 — `path/to/file` (<size>)
<one line: what this file is>
**Look for:** <the specific thing worth noticing>
**Ask yourself:** <a question whose answer is in the code>

### Stop 1.2 — ...

## Session 2 — ...

## Cross-Cutting Patterns
<table: pattern | where to see it | the idea>

## Exercises
### Warm-up — read and predict
### Beginner — small, safe changes
### Intermediate — real design decisions
### Advanced — architectural

## What Not to Copy
<the deliberate compromises, shortcuts, and debt — named>

## Quick Reference
<commands, related docs>
```

## Section-by-section guidance

### Orientation

The reader has not decided to invest yet. Earn it: say what the system does in
the smallest accurate description, then say what makes it worth their time.

The **setup section is load-bearing** and is the part most often skimped. A reader
who can run the test suite can experiment — break something, see what fails, form
a hypothesis. A reader who cannot is reduced to reading passively, which is a
fraction as effective. Verify the commands yourself; a setup section that does not
work is worse than none, because it strands the reader before they start.

State assumed knowledge honestly. If the domain is unfamiliar (networking,
finance, bioinformatics), say whether the reader needs it. Usually they do not,
and saying so removes a reason to bounce.

### Sessions and stops

**Order by dependency.** Start with files that import nothing from the project.
Each stop should only rely on what came before. This is discoverable while
reading in Step 3 — by the time you have read everything, the graph is in your
head.

**Group into sessions of 1–3 hours** with a theme, and mark which are skippable.
A reader with one afternoon should know which two sessions to pick.

**Every stop needs three things:**

- *What to read* — file plus size, so the reader can budget. Say explicitly when
  a file should be skimmed rather than read: a 1200-line module with four
  interesting functions should say so and name them.
- *Look for* — the specific thing worth noticing. This is where the tour adds
  value over "go read the file". Point at the subtle guard, the asymmetry, the
  rejected alternative.
- *Ask yourself* — a question whose answer is IN the code. This converts passive
  reading into active checking. Good questions have a definite answer the reader
  can verify ("what would collide if this key were a concatenated string?"), not
  open-ended reflection ("what do you think about this design?").

Where a stop teaches something that generalises beyond this repo, say so
explicitly — a **The lesson:** line. That is what the reader carries to their
next project, and it is why they will recommend the tour to someone else.

### Cross-cutting patterns

A table mapping each recurring idea to the files demonstrating it. This is the
highest-value section per line, and the one readers return to after finishing.

It also does something the per-file walk cannot: it shows that a pattern appearing
in four unrelated modules is a deliberate architectural choice rather than four
coincidences. Readers rarely infer that from sequential reading.

Keep it to ideas that genuinely recur. A "pattern" with one instance is just a
thing that happened.

### Exercises

Grade them, because readers arrive at different levels and an exercise that is
too hard reads as a dead end.

- **Warm-up — read and predict.** No code written. "What does this return when
  the input is empty?" Cheap, and it verifies the reader is actually reading.
- **Beginner — small, safe changes.** Add something following an existing
  pattern. The test suite is the safety net, which is why setup mattered.
- **Intermediate — real design decisions.** Extend a system in a way that
  requires understanding *why* it is shaped as it is.
- **Advanced — architectural.** Point these at limitations the codebase
  documents about itself. If the code says "production would need cross-process
  locking", that is an exercise, and a genuinely valuable one because the problem
  is real rather than invented.

Ground every exercise in the actual repo. "Implement a linked list" teaches
nothing about this codebase. Verify that the exercises are actually possible —
check that the thing you are asking a reader to add does not already exist.

### What not to copy

The section that most distinguishes a teaching document from a sales pitch, and
the one most often omitted.

Every real codebase contains shortcuts, deliberate compromises, and debt. A tour
that presents all of it as exemplary teaches readers to copy the debt — and it
costs the document credibility with anyone experienced enough to spot the
problems themselves.

Name them, and say WHY each was acceptable in context and what would replace it
in production. That teaches judgement, which is the harder and more valuable
lesson: not "here is the right way" but "here is a defensible trade-off and the
conditions under which it stops being defensible."

If the codebase already labels its own compromises, collect them — that is the
easiest and most credible version. If it does not, you will have found them
while reading in Step 3.

## Worked example of one stop

Weak — describes, does not teach:

> ### Stop 3.2 — `validator.py`
> This file validates input. It has a `validate()` function that checks the
> fields and returns errors. Read it to understand validation.

Strong — points at something specific, generalises, and asks a checkable question:

> ### Stop 3.2 — `validator.py` (180 lines)
>
> Input validation, and the clearest example of fail-closed design in the repo.
>
> **Look for:** `_check_range` returns `False` for unparseable input rather than
> raising. Trace one call — the caller treats a `False` as "reject", so malformed
> input is refused rather than crashing the request. Then notice `_check_enum`
> does the opposite and raises. The asymmetry is deliberate; the docstring
> explains which failures are user error and which are programmer error.
>
> **The lesson:** decide, per failure, whether the caller can do something useful
> with it. Return a value when they can; raise when they cannot.
>
> **Ask yourself:** what happens if a new validator forgets this convention and
> returns `None` on failure? Which existing test catches it — if any?

## Where a tour sits in Diátaxis

If the project uses the Diátaxis framework (tutorials / how-to guides /
reference / explanation), a tour is not a clean fit for any single quadrant, and
it is worth being explicit about that rather than mislabelling it:

- It has **tutorial** properties: ordered, guided, learning-oriented.
- It is mostly **explanation**: it exists to build understanding, not to complete
  a task.
- It points INTO **reference** (the docstrings) rather than duplicating them.

Diátaxis warns against mixing modes in one document, and a tour deliberately
does. The justification is the audience: someone learning a codebase needs
orientation and reasoning together, and splitting them across two documents means
they read neither. If the project is strict about Diátaxis, file the tour under
explanation and keep the exercises clearly separated at the end.

## Common failure modes

- **Unverified claims.** Line numbers that shifted, symbols that were renamed,
  commands that do not run. Every factual claim is checkable — check it. This is
  the fastest way to lose a reader's trust, and it compounds: one wrong line
  number makes them doubt everything else.
- **Alphabetical or directory order.** Reveals that no thought went into the path.
- **No time estimates.** Readers cannot plan, so they do not start.
- **Cheerleading.** "This elegant abstraction..." Describe; let the reader judge.
- **Duplicating the docstrings.** The tour points at things; it does not restate
  them. If a stop reproduces a docstring, cut it and reference the symbol.
- **Exercises with no safety net.** If the tests do not cover the area, say so,
  or the reader cannot tell whether their change worked.
- **Written for the author.** The test is whether someone who has never seen the
  repo can follow it. If a stop only makes sense to someone who already knows the
  answer, rewrite it.
