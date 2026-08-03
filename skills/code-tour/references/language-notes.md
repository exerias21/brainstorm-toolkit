# Applying the workflow to non-Python codebases

The `SKILL.md` procedure is language-neutral — survey, read, document the why,
build the tour, verify. Only the extraction mechanics and the naming conventions
change. This file covers the differences.

## Contents

- [What stays the same](#what-stays-the-same)
- [Coverage auditing without the bundled script](#coverage-auditing-without-the-bundled-script)
- [Per-language conventions](#per-language-conventions)
- [Mixed-language repositories](#mixed-language-repositories)

## What stays the same

Every step of the procedure, and every judgement in it:

- Read the code before documenting it.
- Document the reasoning, not the signature — this is the point regardless of
  language, and it is what no doc-comment convention specifies for you.
- Length follows consequence, not line count.
- Verify claims by running them.
- The tour's dependency ordering, pattern index, exercises, and "what not to
  copy" section are language-independent.

The one universal that changes shape: most languages have a **doc-comment**
syntax that a generator consumes, and most have a convention for what a
generator expects. Match the local convention rather than importing Python's.

## Coverage auditing without the bundled script

`scripts/docstring_audit.py` is Python-only (it uses `ast`). For other languages,
get the coverage number from the ecosystem's own tooling where it exists, and fall
back to counting when it does not.

The number matters less than having a *consistent* before/after. If no tool
exists, a `grep`-based count of exported symbols versus preceding doc comments is
adequate for a delta, and you should say in your report that it is approximate
rather than presenting it as precise.

Be careful with a naive grep: it usually cannot distinguish a doc comment from an
ordinary comment, and it will miss nested or generic declarations. Prefer a real
parser when the language ships one (`go doc`, `tsc` with declaration output,
`rustdoc`'s JSON output).

## Per-language conventions

### Go

- **Syntax:** `//` comments immediately preceding the declaration, no blank line.
- **Convention:** the comment begins with the identifier's name — `// Parse reads
  ...` for `func Parse`. This is enforced by convention and checked by linters
  (`revive`, formerly `golint`).
- **Coverage:** `go doc` shows what is exported and documented. `revive` with the
  `exported` rule flags undocumented exported symbols.
- **Note:** Go's culture strongly favours documenting exported identifiers and
  leaving unexported ones to inline comments — closely parallel to Python's
  public/private split.

### TypeScript / JavaScript

- **Syntax:** JSDoc/TSDoc block comments, `/** ... */`.
- **Convention:** with TypeScript types present, do NOT repeat types in
  `@param {Type}` tags — the same reasoning as not restating Python type hints.
  TSDoc omits types by design; JSDoc includes them because plain JS has none.
- **Coverage:** `eslint-plugin-jsdoc` has rules for required doc comments.
  TypeDoc will report what it cannot document.
- **Note:** distinguish TSDoc (Microsoft, TypeScript-oriented) from JSDoc — they
  differ on tags. Match whichever the repo already uses.

### Rust

- **Syntax:** `///` for the item that follows, `//!` for the enclosing
  module/crate.
- **Convention:** Markdown body; a `# Examples` section whose code blocks are
  COMPILED AND RUN by `cargo test`. This is the strongest executable-documentation
  story of any mainstream language — take advantage of it, because an example that
  cannot drift is worth several paragraphs that can.
- **Coverage:** `#![warn(missing_docs)]` makes undocumented public items a
  compiler warning. `cargo doc` builds the output.
- **Note:** also document `# Panics`, `# Errors`, and `# Safety` (mandatory for
  `unsafe`) — these are the reasoning-carrying sections, and the ecosystem
  expects them.

### Java / Kotlin

- **Syntax:** Javadoc `/** ... */`, or KDoc for Kotlin.
- **Convention:** `@param`, `@return`, `@throws`. Javadoc culture is more
  ceremonial than most; resist filling every tag with restatement. An `@return
  the result` line is pure noise.
- **Coverage:** the `javadoc` tool reports missing comments; Checkstyle's
  `JavadocMethod` enforces them.

### C#

- **Syntax:** XML doc comments, `///` with `<summary>`, `<param>`, `<returns>`.
- **Coverage:** compiler warning CS1591 for missing XML comments on public
  members, enabled via `<GenerateDocumentationFile>`.
- **Note:** the XML verbosity tempts pure restatement. The `<remarks>` element is
  where reasoning belongs and is chronically underused — put the why there.

### Ruby

- **Syntax:** `#` comments preceding the definition; YARD tags (`@param`,
  `@return`) if the project uses YARD.
- **Coverage:** `yard stats --list-undoc`.

### Shell

- Often the worst-documented and most load-bearing code in a repository —
  deployment, CI, and setup scripts frequently encode operational knowledge that
  exists nowhere else.
- No doc-comment standard. A header block stating purpose, expected environment,
  arguments, and side effects is the convention worth adopting. Note especially
  what the script assumes about its environment, since that is invisible and is
  what breaks.
- Prioritise these even when they are not the "main" language: a 40-line deploy
  script may carry more institutional knowledge per line than anything else in
  the repo.

### SQL / migrations

- Comment the WHY of a schema decision (why this index, why denormalised here,
  why this column is nullable) — the schema itself shows the what.
- Migrations are historical records; a comment explaining why a migration was
  necessary is often the only surviving trace of a production incident.

## Mixed-language repositories

Most real repos are polyglot. Two adjustments:

1. **Audit and report per language**, not as one blended number. "94% Python,
   40% TypeScript" is actionable; a combined "71%" is not.
2. **Order the tour by the request path, not by language.** If a request crosses
   a TypeScript frontend, a Python API, and a Go worker, the tour should follow
   the request. Grouping by language would split the one story a reader most
   needs — how a request actually flows — across three disconnected sessions.

Where a boundary is crossed (an HTTP call, a queue message, a subprocess), that
boundary deserves its own stop. Cross-language seams are where the contracts are
implicit and where the interesting bugs live, and they are almost never
documented on either side.
