# Tooling — linting, coverage, generation, CI

Researched 2026. Read at Step 7 of `SKILL.md`, or whenever the user asks how to
enforce documentation rather than just write it.

**Read the status column before recommending anything.** Several tools that
still dominate blog posts and Stack Overflow answers are archived. Recommending a
dead tool is worse than recommending none — it costs the team a migration later.

## Contents

- [What is dead](#what-is-dead)
- [Linting: ruff `D` and `DOC`](#linting-ruff-d-and-doc)
- [Consistency checking: pydoclint](#consistency-checking-pydoclint)
- [Coverage measurement](#coverage-measurement)
- [Formatting: docformatter](#formatting-docformatter)
- [Doc generators](#doc-generators)
- [Doctests](#doctests)
- [CI patterns](#ci-patterns)
- [Comparison table](#comparison-table)
- [Practical rules](#practical-rules)

## What is dead

Lead with this, because these are what a search will surface:

- **pydocstyle** — repo **archived Nov 2023**. Its own README: *"The Pydocstyle
  project is officially deprecated... We highly recommend pydocstyle users to
  switch over to ruff."*
  ([PyCQA/pydocstyle](https://github.com/PyCQA/pydocstyle))
- **flake8-docstrings** — last release Jan 2023, a thin wrapper around
  pydocstyle, so it inherits the deprecation.
- **darglint** — **archived Dec 2022**; the maintainer stepped away from Python.
  Also notoriously slow (hours on large codebases).
  ([darglint](https://github.com/terrencepreilly/darglint))
- **darglint2** — the community fork exists but has itself gone quiet (no
  releases in the past year).

Replacements: ruff's `D` rules for the first two, `pydoclint` for the last two.

## Linting: ruff `D` and `DOC`

Ruff reimplements pydocstyle natively in Rust. Enable and pin a convention:

```toml
# pyproject.toml
[tool.ruff.lint]
select = ["D"]

[tool.ruff.lint.pydocstyle]
convention = "google"   # or "numpy" | "pep257"
```

**Pinning a convention matters more than it looks.** Setting it *disables every
D-rule not in that convention's list*. Leaving bare `D` selected turns on
mutually contradictory rules — D203 vs D211, D212 vs D213 — which will fight each
other and produce unfixable lint errors.
([Ruff FAQ](https://docs.astral.sh/ruff/faq/))

Rules worth knowing (numbering inherited from pydocstyle):

- **D100–D107** — missing docstring in module / class / method / function /
  package / magic method / nested class / `__init__`.
- **D200, D205, D212/D213** — one-liner and summary-line placement.
- **D400–D403** — ends with a period, imperative mood, **no signature in the
  docstring**, capitalisation.
- **D417** — *undocumented-param*: an argument in the signature is not
  documented. Only enforced under the `google`/`numpy` conventions, not bare
  `pep257`.

**Ruff's `DOC` ruleset** (DOC101–504) is a native reimplementation of pydoclint,
covering args, returns, raises, and yields consistency. As of this research it
remains **`--preview`-gated and has not graduated to stable**, and some rules
(DOC201 on one-line docstrings, DOC502 on inherited re-raises) have known
false positives.
([ruff#12434](https://github.com/astral-sh/ruff/issues/12434),
[discussion #15833](https://github.com/astral-sh/ruff/discussions/15833))

> Check ruff's current changelog before relying on `DOC` being stable — the
> graduation date was not verifiable at time of research.

## Consistency checking: pydoclint

`pydoclint` verifies that a docstring's Args/Returns/Yields/Raises sections match
the actual signature and implementation. **This is the tool that catches
LLM-authored fabrication**, so it matters directly to this skill's Step 5.

- Actively maintained — v0.9.1, July 2026.
- **1,000–4,600× faster than darglint** (2.0s vs 49 min on numpy; 2.4s vs 3+
  hours on scikit-learn).
- Supports NumPy, Google and Sphinx styles; runs standalone or as a flake8 plugin
  (`flake8 --select=DOC`).
  ([jsh9/pydoclint](https://github.com/jsh9/pydoclint))

Expect to disable a couple of sub-rules — DOC201 handles one-line docstrings
poorly, DOC502 misfires on inherited methods re-raising a parent's documented
exceptions.

**Recommend pydoclint standalone today** rather than ruff `DOC`, precisely
because it is stable while ruff's version is not.

## Coverage measurement

Both tools check **presence only** — that a docstring exists, not that it is any
good. Do not let a coverage badge imply quality.

**interrogate** (v1.7.0, Apr 2024) — AST walk, `--fail-under=N` (default 80),
`--style [sphinx|google]`, `--generate-badge` for an SVG.
([docs](https://interrogate.readthedocs.io/)) A GitHub Action exists
(`JackMcKew/python-interrogate-check`).

**docstr-coverage** — same job, built around **CI diffing**: it can fail a PR
when coverage drops *relative to the base branch*.
([repo](https://github.com/HunterMcGushion/docstr_coverage))

**Which to pick:** `interrogate` for a greenfield project where an absolute
threshold is achievable; `docstr-coverage` for a brownfield codebase, where a
regression gate is the only workable option (see rule 4 below).

The skill's own `scripts/docstring_audit.py` covers the same ground with no
dependency and adds per-symbol qualified names — useful during the work. For
permanent CI enforcement, prefer one of the maintained tools above.

## Formatting: docformatter

A **formatter, not a linter** — it rewrites existing docstrings to a PEP 257
subset (quote style, blank lines, wrapping, trailing whitespace). It does not add
missing docstrings and does not measure anything. Maintained under PyCQA, latest
release Apr 2026.

```toml
[tool.docformatter]
recursive = true
wrap-summaries = 82
blank = true
```

Run it *before* the linter in pre-commit so mechanical issues never reach the
lint stage.

## Doc generators

| Tool | Status | Best for |
|---|---|---|
| **Sphinx** + `autodoc` + `napoleon` | De facto standard; deepest ecosystem (intersphinx, viewcode, gallery) | API-first docs, cross-project linking, scientific Python. reST-native; Markdown via MyST as an add-on |
| **MkDocs** + `mkdocstrings` | Markdown-native, simpler config. **Material for MkDocs entered maintenance mode in early 2026**, successor "Zensical" | Markdown-first teams — but check the Material/Zensical transition before committing long-term |
| **pdoc** | Zero-config, no build step, live-reload server, maintained by the mitmproxy project | Small/medium libraries wanting API docs with essentially no setup |
| **pydoctor** | Active but niche (Twisted ecosystem) | Only if already in that ecosystem |

Choose by markup preference and cross-referencing needs, not by popularity.

## Doctests

Still shipped, still useful, **not a test strategy**. Current guidance: keep them
for simple illustrative "here's how you call this" examples; do not chase doctest
coverage as a metric. The long-standing critique holds — once fixtures and mocks
are involved, a doctest becomes unreadable.

Wire them into a normal run with `pytest --doctest-modules` so they act as
regression protection against examples drifting. `xdoctest` is a stricter
alternative some projects prefer.

Note that **Rust's `cargo test` runs doc examples by default** — if the codebase
is Rust, examples in docs are already compiled and executed, which is the
strongest executable-documentation story of any mainstream language. See
`language-notes.md`.

## CI patterns

**Pre-commit — format, then lint, then gate coverage:**

```yaml
# .pre-commit-config.yaml
repos:
  - repo: https://github.com/PyCQA/docformatter
    rev: v1.7.7
    hooks:
      - id: docformatter
        args: [-i]

  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: v0.16.1
    hooks:
      - id: ruff-check
        args: [--fix]
      - id: ruff-format      # must come AFTER ruff-check when using --fix

  - repo: https://github.com/econchick/interrogate
    rev: 1.7.0
    hooks:
      - id: interrogate
        args: [--fail-under=90]
        pass_filenames: false
        always_run: true
```

**Regression gate — fail only when coverage DROPS** (the pattern that works on a
brownfield codebase), adapted from
[`epassaro/docstr-cov-workflow`](https://github.com/epassaro/docstr-cov-workflow):

```yaml
name: docstring-coverage
on: [push, pull_request]
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: actions/setup-python@v5
        with: { python-version: '3.x' }
      - run: pip install docstr-coverage
      - name: Resolve base and head
        run: |
          if [[ "${{ github.event_name }}" == 'push' ]]; then
            echo "BASE=$(git rev-parse HEAD^)" >> $GITHUB_ENV
          else
            echo "BASE=${{ github.event.pull_request.base.sha }}" >> $GITHUB_ENV
          fi
      - run: git checkout $BASE && echo "BASE_COV=$(docstr-coverage -p)" >> $GITHUB_ENV
      - run: git checkout ${{ github.sha }} && docstr-coverage --fail-under=$BASE_COV
```

**Using this skill's own auditor in CI** (no dependency to install):

```yaml
      - run: python3 scripts/docstring_audit.py src/ --min 90
```

It exits 1 below the threshold and 2 on a parse error, so both fail the build —
and a parse error fails loudly rather than being counted as a clean audit.

## Comparison table

| Tool | Job | Maintained? | Recommend? |
|---|---|---|---|
| pydocstyle | Style lint | **No — archived 2023** | No → ruff `D` |
| flake8-docstrings | Style lint (wrapper) | Stale since Jan 2023 | No → ruff `D` |
| darglint | Signature consistency | **No — archived 2022** | No → pydoclint |
| darglint2 | Fork of above | Stagnant | No |
| **ruff `D`** | Style lint | Yes, active | **Yes** |
| ruff `DOC` | Signature consistency | Yes, but **`--preview` only** | Not yet — use pydoclint |
| **pydoclint** | Signature consistency | Yes (v0.9.1, Jul 2026) | **Yes** |
| **interrogate** | Presence coverage + badge | Yes (v1.7.0) | **Yes** — absolute threshold |
| **docstr-coverage** | Presence coverage, CI diff | Yes | **Yes** — regression gate |
| **docformatter** | Auto-format docstrings | Yes (Apr 2026) | **Yes** |
| Sphinx + napoleon | Generator | Yes, standard | Yes |
| MkDocs + mkdocstrings | Generator | Yes (watch Zensical) | Yes |
| pdoc | Generator, zero-config | Yes | Yes, small projects |
| doctest / `--doctest-modules` | Executable examples | Stdlib | Yes, illustrative only |

## Practical rules

1. **Drop pydocstyle, flake8-docstrings and darglint.** All archived. ruff `D`
   and pydoclint replace them, faster and maintained.
2. **Always pin a convention** (`convention = "google"`), never bare `D` — the
   full rule set contains mutually contradictory rules.
3. **Use pydoclint standalone, not ruff `DOC`, until `DOC` leaves preview.**
4. **Split presence from correctness.** Coverage tools prove a docstring exists;
   pydoclint proves its claims match the code. Neither substitutes for the other,
   and only the second catches fabrication.
5. **Gate on regression, not an absolute floor, on an existing codebase.** An
   absolute `--fail-under` on brownfield code either blocks every merge or gets
   set so low it means nothing.
6. **Format before linting** in pre-commit, so mechanical issues never surface as
   lint failures.
7. **Enforce in CI, not only pre-commit** — local hooks are skippable with
   `--no-verify`.
8. **Never ship LLM-authored docstrings without a consistency check.**
   Hallucinated parameter and behaviour claims are documented and measured (see
   `standards.md`). This is the single most important rule in this file for work
   produced by this skill.
9. **Introduce gates gradually.** Proposing a 95% gate on a repo at 40% produces
   a build nobody can merge into. Start at current coverage, ratchet upward.
10. **Do not present a coverage badge as a quality signal.** It measures presence
    only. Say so when reporting it.
