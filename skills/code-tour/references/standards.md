# Documentation standards — what is actually standard, and what is just opinion

Researched from primary sources (2026). Read this before Step 4 of `SKILL.md`.

The most useful thing this file does is **separate genuine standards from widely
repeated opinion**. A lot of documentation advice is asserted with the confidence
of a specification and is in fact one influential book's position. Knowing which
is which lets you follow a real convention where one exists and make a defensible
judgement call where none does — rather than inventing house style and presenting
it as best practice.

## Contents

- [The short version](#the-short-version)
- [PEP 257 and what it actually mandates](#pep-257-and-what-it-actually-mandates)
- [Choosing a docstring style](#choosing-a-docstring-style)
- [Docstring vs comment vs external doc](#docstring-vs-comment-vs-external-doc)
- [Type hints: do not repeat types](#type-hints-do-not-repeat-types)
- [Private helpers, tests, `__init__`](#private-helpers-tests-__init__)
- [Length and over-documentation](#length-and-over-documentation)
- [Where a tour fits: Diátaxis and neighbours](#where-a-tour-fits-diátaxis-and-neighbours)
- [ADRs — the other half of "why"](#adrs--the-other-half-of-why)
- [Evidence on onboarding](#evidence-on-onboarding)
- [LLM-authored documentation](#llm-authored-documentation)
- [Consensus vs contested — the summary table](#consensus-vs-contested--the-summary-table)

## The short version

If you read nothing else:

1. PEP 257 is advisory. It says so itself: *"conventions, not laws or syntax."*
2. Pick ONE style (Google or NumPy) per project and do not mix.
3. Comments and docstrings should carry the **why**; the code already shows the
   what. This is the one point every source agrees on.
4. With type annotations present, do not repeat types in the docstring.
5. Private (`_`-prefixed) symbols are **exempt** from docstring requirements by
   both PEP 8 and every major linter's rule design. Documenting them anyway is a
   legitimate audience-driven choice — just know it is a choice, not compliance.
6. Verify LLM-authored docstrings mechanically. Hallucinated parameter and
   behaviour claims are a documented, measured problem.

## PEP 257 and what it actually mandates

PEP 257 is Active/Informational, created 2001, last substantively revised 2003.
Every other style guide defers to it. It also explicitly disclaims authority —
violating it earns, in its own words, only *"some dirty looks."*
([PEP 257](https://peps.python.org/pep-0257/),
[mirror](https://docutils.sourceforge.io/docs/peps/pep-0257.html))

**Closer to a rule:**

- A docstring is a string literal that is the FIRST statement in a module,
  function, class, or method. (This is mechanical — it is how `__doc__` gets set.)
- All modules should normally have docstrings; all functions and classes
  *exported by* a module should too.
- Always `"""triple double quotes"""`; `r"""..."""` if it contains backslashes.

**Convention only:**

- One-liners on one line, closing quotes on the same line.
- Imperative mood — "Return the result", not "Returns the result".
- Multi-line: summary, blank line, elaboration, closing `"""` on its own line.
- **Do not replicate the signature in the docstring body.** Explicitly prohibited.

PEP 8 adds a rule frequently missed: docstring and comment prose should wrap
around **72 characters**, shorter than the 79/99 used for code. numpydoc
independently lands on 75 for the same terminal-readability reason — two
independent sources converging on nearly the same number is as close to a real
standard as this area gets.
([PEP 8](https://raw.githubusercontent.com/python/peps/main/peps/pep-0008.rst),
[numpydoc](https://numpydoc.readthedocs.io/en/latest/format.html))

## Choosing a docstring style

Three live options, one dead one. In practice this is a **two-style duopoly on a
reST substrate**.

| Style | Used by | Tooling | Suits |
|---|---|---|---|
| **Google** | Google, Chromium, most application code | Sphinx `napoleon`; readable as plain text with no tool at all | General application/service code, shorter docstrings |
| **NumPy/numpydoc** | NumPy, SciPy, pandas — dominant in scientific Python | `numpydoc` or `napoleon` | Libraries with many parameters, long docstrings, worked examples |
| **reST field lists** (`:param:`) | Older Sphinx-first projects | Native to `autodoc`, no extension | Sphinx cross-referencing without adopting Google/NumPy; denser, less readable raw |
| **Epytext** | Legacy (Epydoc, discontinued) | `pydoctor` parses it for compatibility | Nothing new — historical dead end |

Sphinx's `napoleon` extension parses both Google and NumPy and converts to reST,
which is why those two dominate. Its documentation is explicit: pick one, *"the
two styles should not be mixed"*, and the choice is otherwise *"largely
aesthetic."*
([napoleon](https://www.sphinx-doc.org/en/master/usage/extensions/napoleon.html))

Ruff ships `convention = "google" | "numpy" | "pep257"`, which confirms these as
the operative tool-recognised set.

> The claim that NumPy style is *better* for long docstrings and Google *better*
> for short ones is widely repeated but traces to secondary sources. Treat it as
> a reasonable heuristic, not a verified finding.

**For this skill:** match whatever the repo already uses. If there is none,
Google style is the safer default for application code — it reads acceptably as
plain text, which matters when the audience is reading source rather than
generated HTML.

## Docstring vs comment vs external doc

The clearest consensus in the entire area, converged on independently by PEP 8,
Google's style guide, and the standard texts:

- **Docstrings describe the contract** — what it does, arguments, returns,
  exceptions, side effects. Aimed at a caller who may never read the body.
  Google's guide: describe *"calling syntax and semantics, but generally not
  implementation details."*
- **Comments carry what the code cannot express — chiefly WHY.** Google's
  documentation guide: *"The primary purpose of inline comments is to provide
  information that the code itself cannot contain, such as why the code is
  there."*
- **External docs** carry what should not live in code at all — architecture,
  onboarding, cross-cutting concerns.

PEP 8's own example is the canonical illustration: prefer
`x = x + 1  # Compensate for border` over `x = x + 1  # Increment x`. And its
flat statement: **"Comments that contradict the code are worse than no
comments."**

**Comment rot** is the mechanism behind that warning: comments are neither
type-checked nor executed, so nothing forces them to track the code. When they
drift, readers stop trusting *all* comments, not just the stale one.
([origin of the term](https://lenholgate.com/blog/2003/10/comment-rot.html))

> **Opinion, not standard** — flagged because it is often cited as though it
> were: *Clean Code*'s position that *"every use of a comment represents a
> failure to express yourself in code"*, and McConnell's *"how can I improve the
> code so that this comment isn't needed?"* These are influential and worth
> knowing. No PEP or major style guide asserts them. They also apply far better
> to *what* comments than to *why* comments — no amount of renaming makes a
> function explain the outage that motivated its retry logic.

**The practical consequence for this skill:** the docstrings it produces
deliberately carry more "why" than a strict contract-only reading of PEP 257
would put there. That is a defensible choice for a teaching audience, and it is
worth being explicit that it is a choice. For a published library API, lean
harder toward contract; for a codebase someone must maintain or learn, the
reasoning is the valuable part.

## Type hints: do not repeat types

The clearest *shift* in practice since ~2015, and near-consensus at the tooling
level:

- **Google style**: when annotations are present, do not repeat type information
  — *"the annotation serves this purpose; the docstring focuses on semantic
  behavior and constraints."*
- **Sphinx napoleon**: documents PEP 484 annotations as an alternative to types
  in docstrings, with `napoleon_attr_annotations` defaulting to `True` since
  Sphinx 3.4.
- **PEP 484 itself** treats docstrings as the fallback for the residue types
  cannot express — not a place to restate them.

> **Contested at the spec level.** numpydoc's published format guide still
> requires types in Parameters/Returns regardless of annotations. Its own issue
> tracker calls this *"tedious and also error prone"*, and some numpy-ecosystem
> projects deliberately deviate.
> ([numpydoc#356](https://github.com/numpy/numpydoc/issues/356))

**Rule:** if the project uses numpydoc strictly, follow it. Otherwise, describe
semantics and constraints, not types. `count: int` in the signature plus
`count: number of retries; must be positive` in the docstring is right — the
docstring adds the constraint the type cannot express.

## Private helpers, tests, `__init__`

This is where the standards are **weakest** and the community most divided, so it
is where you should be most explicit about making a judgement call.

**Private (`_`-prefixed) symbols:**

- PEP 8's position is that non-public methods should have *"descriptive comments
  after the `def` line"* — a comment, not necessarily a docstring.
- Tooling encodes the same: ruff/pydocstyle's `D102` (missing docstring in public
  method) does **not** fire on a name starting with `_`.

So a private helper with no docstring is **compliant**, not a gap.

> **The judgement call this skill makes, stated openly.** For a teaching or
> onboarding audience, private helpers are often the *most* valuable things to
> document — they exist because someone extracted them for a reason, and that
> reason is recorded nowhere else. This skill therefore documents them by
> default. That is a deliberate deviation from the exempt-by-default norm, driven
> by audience, and you should say so in your report rather than implying the
> standards require it. For a published library, the norm is the better default.

**Test functions:** no PEP or major style guide takes a position. Practitioner
folklore favours them (a docstring surfaces in verbose runner output and speeds
triage); tooling defaults skip them (per-file-ignores for `D` rules in test
directories is a common config). Genuinely optional — decide by whether the suite
functions as a specification.

**`__init__.py` and `__init__`:** PEP 257 requires package docstrings listing
submodules, and public `__init__` methods to have docstrings (`D104`, `D107`).
numpydoc's convention **excludes `D107`**, preferring constructor parameters
documented once in the *class* docstring. A direct, named disagreement between
two established conventions — pick one and be consistent.

## Length and over-documentation

- **No PEP or style guide specifies a maximum docstring length.** The only
  numeric guidance anywhere is the ~72–75 character *line width* above.
- numpydoc gives a structural anti-verbosity rule: method docstrings keep only a
  brief summary and See Also, deferring detail to the class docstring.

> **Contested.** "Excessive commenting is an anti-pattern" and "a docstring
> longer than the function it documents is a smell" are widely repeated and
> reasonable, but they are secondary-source opinion with no standards backing and
> no measurable threshold. The counter-case is straightforward: a five-line
> function implementing a security boundary or a subtle concurrency guard can
> justify a long explanation, because the consequence of misunderstanding it is
> severe and the reasoning appears nowhere else. **Length should track
> consequence, not line count** — and a reviewer who sees a long docstring on a
> short function should ask whether the reasoning is load-bearing, not
> reflexively cut it.

The one sanctioned way to *reduce* docstring bulk without losing information is
the type-hint rule above: let annotations carry types, and the prose shrinks to
semantics.

## Where a tour fits: Diátaxis and neighbours

**Diátaxis** splits documentation four ways by reader need — tutorials
(learning), how-to guides (a goal), reference (information), explanation
(understanding) — on two axes, action/cognition and study/work.
([diataxis.fr](https://diataxis.fr/))

Real adopters include Canonical/Ubuntu (first-party confirmed); Cloudflare,
Gatsby and Django are repeatedly cited but were verified only via secondary
sources. Its predecessor is the **Divio documentation system** — same four
categories, same author (Daniele Procida), still live.

> **Documented criticism.** Hillel Wayne's *"My Problem With the Four-Document
> Model"* argues it is not a complete taxonomy: migration guides, troubleshooting
> runbooks, glossaries and architecture docs do not fit cleanly, so presenting it
> as exhaustive oversells it. Diátaxis's own guidance also frames it as a compass,
> not a blueprint, and endorses partial application.
> ([HN discussion](https://news.ycombinator.com/item?id=36610846))

**A guided tour deliberately mixes modes** — it is mostly explanation, has
tutorial properties, and points into reference. Diátaxis would call that a
weakness. The justification is audience: a person learning a codebase needs
orientation and reasoning together, and splitting them across two documents means
they read neither. Say this openly rather than mislabelling the tour.

**A guided reading path is not novel.** Microsoft's
[CodeTour](https://github.com/microsoft/codetour) VS Code extension stores
step-by-step, line-anchored walkthroughs as a `.tour` file checked into the repo,
explicitly pitched as an onboarding artifact. **Literate programming** (Knuth) is
the older ancestor — but it embeds narrative *in* the source, whereas a tour is a
separate sequenced index *into* existing source. There is no "MADR for tours";
markdown in the repo is the lowest-friction form.

Other frameworks worth knowing:

- **The Good Docs Project** — active since 2019, peer-reviewed templates
  (README, how-to, tutorial, reference…), releases through v1.5.0 (Dec 2025).
- **arc42** — a 12-section template specifically for *architecture*
  documentation. Fills the structural gap Diátaxis's "explanation" quadrant
  leaves open.
- **standard-readme** — the one spec-like README standard, machine-checkable.
  Mandatory: title, short description, TOC (if >100 lines), install, usage.
- **Google developer documentation style guide** — editorial (voice, tense,
  grammar), not architectural. Complements a taxonomy rather than competing.

## ADRs — the other half of "why"

**Architecture Decision Records** capture *why* at a level docstrings cannot: a
short, numbered, immutable file per significant decision. Nygard's original
(2011) format is Title / Status / Context / Decision / Consequences, kept in
version control, never rewritten — a reversal is a new superseding ADR.
**MADR** is the actively maintained superset (v4.0.0, Sept 2024), adding decision
drivers, considered options, and pros/cons.
([adr.github.io](https://adr.github.io/), [MADR](https://github.com/adr/madr))

**Relevant to this skill because they divide the labour:**

- A **docstring** explains why *this function* is shaped this way.
- An **ADR** explains why *the system* chose this approach over alternatives.
- The **tour** points at both and supplies the order.

If, while reading, you find reasoning that is genuinely architectural — a
decision that was hard to reverse, is surprising without context, and had real
alternatives — it may belong in an ADR rather than crammed into a docstring.
Suggest it; do not silently expand a docstring into a design document.

> **Documented failure mode:** without discipline on what counts as
> "architectural", ADR logs become a catch-all that buries the load-bearing ones.
> The accepted heuristic is the three-part test above.
> ([InfoQ](https://www.infoq.com/articles/architectural-decision-record-purpose/))

## Evidence on onboarding

The strongest *peer-reviewed* evidence found, and it directly supports why the
tour exists:

**Steinmacher, Silva & Gerosa, "Barriers Faced by Newcomers to Open Source
Projects"** (OSS 2014) — a systematic review of 21 studies producing a
hierarchical model of five barrier categories: **(1) finding a way to start**,
(2) social interactions, (3) understanding an unfamiliar codebase,
(4) documentation problems, (5) newcomers' own knowledge gaps.
([Springer](https://link.springer.com/chapter/10.1007/978-3-642-55128-4_21),
[PDF](https://www.ime.usp.br/~gerosa/papers/Steinmacher2014_Chapter_BarriersFacedByNewcomersToOpen.pdf))

"Finding a way to start" being a *top* barrier is the empirical case for an
ordered reading path over a well-organised folder. Documentation gaps and slow
social response ranked alongside raw code complexity — meaning the bottleneck is
frequently orientation, not difficulty.

Industry practice points the same way: Stripe pairs every new engineer with a
"spin-up buddy" and has them build a real integration early. GitLab publishes its
onboarding handbook and edits it through the same merge-request flow as code.

> **Treat the numbers as folklore.** "25% faster with a buddy", "2–3 days to
> first commit", "60% reduction in time-to-productivity" are repeated across
> onboarding-vendor blogs, not controlled studies. Directionally plausible;
> not evidence.

**A practical implication worth passing to the user:** documentation alone does
not close the onboarding gap. Both the peer-reviewed barriers and the industry
practice point at pairing a written path with a named human contact. If someone
is preparing a repo for onboarding, say that.

## LLM-authored documentation

Relevant because this skill *is* LLM-authored documentation, and the failure
modes are documented rather than hypothetical.

**The problem.** LLM-generated documentation *"often produce[s] incomplete,
unhelpful, or factually incorrect outputs"*, and naive approaches *"hallucinate
non-existent components, especially in large or proprietary repositories."* This
is the stated motivation for **DocAgent**, a multi-agent system with
Reader/Searcher/Writer/Verifier roles.
([DocAgent, arXiv:2504.08725](https://arxiv.org/abs/2504.08725))

**Two findings that shaped this skill's procedure:**

1. **DocAgent uses dependency-ordered ("topological") traversal so the model
   never documents code before it has seen that code's dependencies.** This is
   independent research support for Step 3's insistence on reading in dependency
   order — it is not merely tidy, it measurably reduces fabrication.
2. **Drift is measurable and real.** CASCADE generates unit tests from docstring
   prose and runs them against the implementation, finding 13 previously
   unreported doc/code mismatches in open-source Java projects.
   ([CASCADE, arXiv:2604.19400](https://arxiv.org/abs/2604.19400))

There is also a compounding risk worth naming: stale or wrong docstrings now
*steer downstream LLM coding assistants*, so a fabricated explanation propagates
into generated code, reviews, and tests rather than merely misleading a human.

**The mitigation is Step 5, and it is not optional.** Never accept an
LLM-authored docstring's parameter, return, or exception claims on faith. Run a
signature-consistency checker (`pydoclint`, or ruff's preview `DOC` rules — see
`tooling.md`), run the test suite, and execute any claim that can be executed.

> Flagged: no docstring-specific hallucination-rate benchmark was found. The
> qualitative failure modes are well documented; precise rates are not.

## Consensus vs contested — the summary table

| Claim | Status |
|---|---|
| PEP 257 is advisory, not enforced | **Consensus** — its own text |
| Public modules/classes/functions get docstrings | **Consensus** |
| Docstrings describe the contract; comments carry the why | **Consensus** — PEP 8, Google, Clean Code converge |
| Stale comments are worse than none | **Consensus** — PEP 8 explicit |
| Pick one style per project, never mix | **Consensus** — napoleon explicit |
| Do not restate the signature in the docstring | **Consensus** — PEP 257 explicit |
| Private `_` symbols exempt from required docstrings | **Consensus** — PEP 8 + linter rule design |
| Docstring prose lines ~72–75 chars | **Consensus** — PEP 8 and numpydoc independently |
| Omit types when annotations are present | **Near-consensus in tooling; contested in numpydoc's spec** |
| `__init__` needs its own docstring | **Contested** — PEP 257 yes, numpydoc no |
| Test functions need docstrings | **No standard either way** |
| "Over-documentation is a smell" | **Opinion** — influential, no standards backing |
| "Good code needs no comments" | **Opinion** — Clean Code/McConnell, not a spec |
| Diátaxis is a complete taxonomy | **Contested** — Wayne's critique |
| Onboarding metrics ("2–3 days to first commit") | **Industry folklore**, not measured research |
| "Finding a way to start" is a top newcomer barrier | **Peer-reviewed** — Steinmacher et al. |

### Source access note

`peps.python.org`, `google.github.io`, `docs.astral.sh`, `diataxis.fr`,
`adr.github.io` and several others returned HTTP 403 to automated fetching.
Primary-source text was obtained via mirrors (`docutils.sourceforge.io`,
`raw.githubusercontent.com`) wherever possible. Claims resting only on
search-result snippets are flagged inline above.
