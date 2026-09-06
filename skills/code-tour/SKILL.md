---
name: code-tour
description: >
  Turn a codebase into teaching material: audit docstring coverage, write why-focused
  docstrings, and generate a guided reading path (TOUR.md). Use whenever someone wants a
  codebase documented for humans, not an API reference — onboarding a new hire, "explain this
  codebase", "add docstrings", "help someone learn this repo", or when docs say WHAT but not
  WHY. Triggers on /code-tour, /docstrings, /codetour, /onboarding-docs. Unlike /repo-onboarding
  (contract files) and /repo-health (read-only sweep), this writes documentation into the source.
metadata:
   brainstorm-toolkit-applies-to: claude copilot codex
---

# Code Tour — documentation as teaching material

Most generated documentation restates the code. `get_user(user_id)` gets a user
by id — the reader already knew that, and the docstring cost them a line of
screen space. The documentation that earns its keep answers what the code cannot
say for itself: **why this approach, what the alternative was, and what breaks if
you change it.**

That is what this skill produces. Two artifacts:

1. **Docstrings** on every module, class, and function — stating the mechanism,
   then the reasoning, then the rejected alternative where one existed.
2. **A guided tour** (`TOUR.md` or `PYTHON-TOUR.md`) — a dependency-ordered
   reading path with what to look for at each stop, a cross-cutting pattern
   index, graded exercises, and an honest list of what readers should *not* copy.

Conventions come from `references/standards.md` (read at Step 4, before the first docstring is
written); `references/tour-structure.md` at Step 6; `references/language-notes.md` if the
codebase is not Python.

## Procedure

### Step 1 — Agree the scope and the convention

Ask before writing. Three questions, and the answers change the work
substantially:

1. **Scope** — the whole repo, one package, or the files a reader needs most?
   A 100k-line monolith should not get a blanket pass; pick the spine.
2. **Audience** — new team members, external contributors, or people being
   *trained* on engineering practice? Training audiences want the reasoning and
   the rejected alternatives; contributors want contracts and invariants.
3. **Convention** — does the repo already use a docstring style? Match it. If it
   uses none, propose one from `references/standards.md` and say why.

If the repo already has good documentation in places, say so and propose filling
gaps rather than rewriting. Replacing an author's accurate explanation with your
own paraphrase destroys information and reads as churn in the diff.

### Step 2 — Survey before you write

Run the bundled audit to find the real gap:

```bash
# the script ships inside this skill's directory (e.g. .claude/skills/code-tour/scripts/)
python3 <skill-dir>/scripts/docstring_audit.py <path>              # per-file gaps + coverage
python3 <skill-dir>/scripts/docstring_audit.py <path> --json       # machine-readable
python3 <skill-dir>/scripts/docstring_audit.py <path> --include-tests
```

It parses with `ast` (never imports the code) and exits non-zero below `--min`,
so it doubles as a CI gate.

Report the numbers to the user before starting. "187 of 267 symbols documented;
the gaps cluster in private helpers and CLI entry points" is a plan. It also
gives you an honest before/after to quote at the end.

For non-Python codebases, see `references/language-notes.md` — the workflow is
identical, only the extraction differs.

### Step 3 — Read the code before you document it

This is the step that separates useful documentation from confident fabrication,
and it is the one under time pressure you will be tempted to skip.

**Read every file you intend to document, fully, before writing any docstring.**
Not the signature — the body, the call sites, and the tests that exercise it. You
cannot explain why a guard exists without knowing what happens when it is
removed, and a docstring that describes behaviour the function does not have is
worse than no docstring: it is a confident lie that readers will trust and
maintainers will not notice.

**Read in dependency order** — leaves first, entry points last. It gives you the tour's
structure for free, and never documenting code before its dependencies is the main defence
against fabricated descriptions (evidence: `references/standards.md`).

Watch for these while reading; they become the best docstrings and the tour's
"look for" notes:

- **Guards whose absence would be silent.** A check that prevents a wrong answer
  rather than an exception. These are invisible to a reader and vanish in
  refactors precisely because nobody documented why they were there.
- **Rejected alternatives still visible in the code** — a comment saying "was X",
  a git-history note, a deliberately verbose construct where a terse one exists.
- **Asymmetries.** Two similar things treated differently. There is always a
  reason, and it is usually the most interesting fact about the module.
- **Anything that looks like a mistake but is not.** Duplication that resists
  DRYing, a broad `except`, a manual loop where a comprehension would do. If you
  cannot work out why, ask — do not paper over it, and do not "fix" it.
- **Domain knowledge a reader will not have.** Explain it inline, briefly, at the
  point of use.

If you genuinely cannot determine why something is the way it is, say so in the
docstring ("unclear why this ordering matters; changing it breaks
`test_foo`") or ask the user. An honest uncertainty is worth more than an
invented rationale, and it flags the question for whoever does know.

### Step 4 — Write docstrings that carry the reasoning

**Read `references/standards.md` now** — it separates genuine standards (PEP 257, Google/NumPy
styles, docstring vs comment, type-hint duplication) from contested opinion, so you follow a
real convention instead of inventing house style.

The shape that works, in rough priority order. Not every docstring needs every
part — a two-line pure function needs one sentence:

1. **One line: what it does**, in the imperative. This is the part a reader
   skims.
2. **How, when the mechanism is non-obvious.** Skip when the body is three
   obvious lines.
3. **Why this way** — the load-bearing part. What was the alternative, and what
   does this choice buy or cost?
4. **What breaks if you change it.** Invariants, ordering constraints, the test
   that will fail.
5. **Args/Returns/Raises** only where they add information the signature does not
   already carry. See `references/standards.md` on not restating type hints.

Judgement calls worth getting right:

- **Do not restate the signature, and do not repeat types.** PEP 257 explicitly
  prohibits replicating the signature, and where type annotations exist, current
  Google-style and Sphinx guidance is to describe semantics and constraints
  instead of naming types again. `retries: must be positive; each adds ~2s of
  latency` earns its line. `retries (int): the number of retries` does not.
- **Length follows consequence, not line count.** A one-line function guarding a
  security boundary may deserve fifteen lines of docstring; a thirty-line
  data-shuffling function may need two. Ask what a reader loses by not knowing.
- **Private helpers and nested functions often deserve the most** — for a
  learning audience. They exist because someone extracted them for a reason, and
  that reason is recorded nowhere else. Be aware this is a *deliberate deviation*
  from the norm: PEP 8 and every major linter exempt `_`-prefixed symbols from
  required docstrings, expecting a brief comment instead. For a teaching or
  handover audience the deviation is worth it; for a published library API it is
  usually not. Decide from the audience you agreed in Step 1, and say which way
  you went in your report rather than implying the standards demanded it.
- **Module docstrings orient.** What is this file for, what does it depend on,
  what depends on it, and where should a reader go next.
- **Test docstrings explain what would break.** A test's name says what it
  checks; the docstring should say why that matters and what class of bug it
  catches. In repos where the suite is the specification, this is the highest
  value documentation in the project. (No standard requires them either way.)
- **Do not document dunder methods** whose semantics come from the language
  (`__repr__`, `__enter__`) unless the implementation is surprising.
- **Architectural reasoning may not belong in a docstring at all.** If what you
  are about to write explains a system-wide decision that was hard to reverse and
  had real alternatives, that is an Architecture Decision Record, not a docstring
  (see `references/standards.md`). Suggest one; do not quietly expand a function's
  docstring into a design document.

Write for the reader who is about to *modify* this code, not the one calling it
from outside. The caller has the signature and the types; the modifier needs the
reasoning.

### Step 5 — Verify every claim you make

Documentation asserting things that are not true is the failure mode of this entire
exercise — the measured weakness of LLM-authored documentation — and docstrings now steer
downstream coding assistants, so a fabricated explanation propagates into generated code.

Treat this step as mandatory, not as polish:

- **Run the test suite.** Docstring edits should not change behaviour — if tests
  now fail, you edited code, not documentation.
- **Run a signature-consistency checker** if the project has one available
  (`pydoclint`, or ruff's `DOC` rules). It mechanically verifies that documented
  parameters, returns and exceptions match the actual code — precisely the class
  of claim you are most likely to get wrong. See `references/tooling.md`.
- **Re-run the coverage audit** and quote the before/after honestly.
- **Execute any claim you can execute.** If a docstring says `bool("false")` is
  `True`, or that a helper returns `[]` on a missing file, run it. This costs
  seconds and catches real errors.
- **Check cited line numbers, symbol names, and file paths** — especially in the
  tour, and especially after your own edits shift line numbers.
- **Re-read your longest docstrings once, cold.** Cut anything that restates the
  code. If a paragraph would not change what a reader does, it is decoration.

Anything you could not verify belongs in your final report as an open question,
not smoothed over with confident prose.

### Step 6 — Write the guided tour

Read `references/tour-structure.md` for the full template. The essentials:

- **Order by dependency**, not alphabetically or by size. Start with the files
  that depend on nothing.
- **Group into sessions** with realistic time estimates. Say which sessions are
  skippable.
- **Per stop: what to read, what to look for, and a question to answer.** The
  question is what turns reading into engagement — ask something whose answer is
  in the code, so a reader can check themselves.
- **A cross-cutting pattern index** — the recurring ideas, each mapped to the
  files demonstrating them. This is what a reader takes to their next project,
  and it is the part they will come back to.
- **Graded exercises**, from "predict this output" through "add a feature" to
  "fix the limitation the code documents about itself". Ground them in the actual
  repo, and make sure the tests give a safety net.
- **A "what not to copy" section.** Every real codebase contains shortcuts,
  deliberate compromises, and outright debt. Naming them teaches judgement, and
  its absence teaches readers to copy the debt. If the code already labels its
  own compromises, collect them; if not, you have found them while reading.

Include a setup section that gets a reader to a passing test run in a few
minutes. A reader who can run the tests can experiment; one who cannot will only
read passively.

### Step 7 — Offer to gate it in CI

Optional, and worth proposing rather than doing unasked — a coverage gate that
fails an unprepared team's build is unwelcome. If they want it,
`references/tooling.md` has current linter and CI configuration, and the bundled
audit script already exits non-zero below a threshold.

## What bad output looks like

Recognise these in your own drafts:

- **Restating the signature.** "Takes a user_id and returns a user." Delete it.
- **Inventing rationale.** Confident explanation of a decision you did not verify.
  If you are guessing, say you are guessing, or ask.
- **Uniform length.** Every docstring the same size means length was driven by a
  template rather than by what each function actually needed explaining.
- **Documenting the obvious at the expense of the subtle.** A thorough docstring
  on a getter and nothing on the concurrency-sensitive one nearby.
- **Style drift.** Three conventions in one file because each was written fresh.
- **Tour claims nobody checked** — wrong line numbers, symbols that do not exist,
  commands that do not run.
- **Cheerleading.** "This elegant abstraction..." Describe, do not admire.
  Documentation that flatters the code loses the reader's trust for the parts
  that matter.

## Output summary

Report at the end:

- Coverage before and after, from the audit script.
- Which files were documented, and which were deliberately skipped and why.
- The tour's path, and roughly how long it takes to work through.
- Anything you could not explain and want the user to confirm — this list is a
  feature, not an admission. It is where the institutional knowledge that only
  lives in someone's head gets surfaced.
- Confirmation that the test suite still passes.
