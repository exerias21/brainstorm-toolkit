---
name: codify
description: >
  Convert a single finding from /hunt or /full-audit into a Semgrep rule
  and a CodeQL query so the same pattern can be swept fleet-wide and
  enforced at PR time. Use when the user says /codify <finding-id>,
  "turn this into a lint rule", "make a Semgrep rule from this",
  "write a CodeQL query for this", or wants to prevent the same bug
  shape from coming back.
argument-hint: "<finding-id>   # e.g. 'authz-02', or path to a finding md file"
metadata:
  brainstorm-toolkit-applies-to: claude copilot
---

# /codify — turn a finding into a sweepable rule

One finding tells you about one bug; a rule tells you about every
recurrence of that bug shape across the codebase (and, when committed
to the linter, every future recurrence at PR time). This skill writes
the rule pair — Semgrep for fast pre-commit / CI, CodeQL for deep
dataflow analysis — based on the finding's pattern.

## Scope and rules

- **Read-only over the codebase**, write-only under
  `./rules/{semgrep,codeql}/`. No `Edit` of source code. The rules are
  generated as new files; running them is the user's call (CI
  workflow, pre-commit hook).
- **Authorized review of owned source.** Rules generated here are
  meant for the user's own fleet — they encode the user's safe-shape
  conventions, not generic OWASP rules.
- The skill **does not** auto-publish to a shared rule pack. The
  user decides whether a rule graduates from local to org-wide.

## Args

- **`<finding-id>`** — short ID resolved against
  `plans/findings/*-<sha>.md` / `plans/audit-<sha>.md`, or a direct
  path to the finding markdown.
- If no arg given, list available finding IDs and ask which one.

## Procedure

### 1. Read the finding

Extract:
- Category (drives which library imports the CodeQL template uses).
- Language of the vulnerable file (drives Semgrep `languages:` field).
- The vulnerable shape — the exact code form the finding flagged.
- The safe shape — the codebase's recommended replacement, if the
  finding's recommendation names one.

If the finding's confidence is <8, refuse — low-confidence patterns
make noisy rules. Improve the finding first.

### 2. Sweep the codebase for the same shape

Before writing the rule, grep for the vulnerable shape across the
repo. Two outcomes:

- **One occurrence**: the rule is still useful as a regression guard,
  but flag this to the user — "only one site today; this rule prevents
  recurrence."
- **Multiple occurrences**: list every additional `file:line` the
  sweep found. The user may want to file these as additional findings
  before merging the rule (otherwise CI starts failing on day one).

### 3. Identify the codebase's safe-by-default helper

If the finding's recommendation cites a helper (e.g. `db.query_param`
over raw SQL, `safe_outbound_get` over `requests.get`, `require_can_view`
over manual checks), grep for that helper. If it exists, the Semgrep
rule's `pattern-not` should match the safe shape, and the CodeQL
rule's `isBarrier` predicate should treat it as a sanitizer. If it
doesn't exist yet, note that the rule will need an exception list
until the helper is introduced.

### 4. Write the rule pair

Create `./rules/semgrep/<finding-id>.yaml` from
`templates/semgrep-rule.template.yaml`, filling in:
- `id`, `message`, `severity` (ERROR for confidence ≥ 9, WARNING for 8).
- `languages` from the finding's file.
- `metadata.cwe` if the finding includes it.
- `pattern-either` with the vulnerable shape(s).
- `pattern-not` with the safe-by-default helper.
- `fix` (optional) if a one-step autofix is safe.

Create `./rules/codeql/<finding-id>.ql` from
`templates/codeql-rule.template.ql`, filling in:
- Language import and TaintTracking import for the file's language.
- `isSource` — the framework's request/input primitive.
- `isSink` — the dangerous-primitive call shape.
- `isBarrier` — the safe-by-default helper, if found.
- `@security-severity` derived from `exploitability × blast_radius`
  in the finding (clamp to 0.0–10.0).

### 5. Print integration instructions

Show the user how to wire each rule into local checks and CI. Don't
modify CI files in this skill — recommend the change, let the user
apply it via `/sdlc` or manually.

Example output:
```
Rules written:
  ./rules/semgrep/<finding-id>.yaml
  ./rules/codeql/<finding-id>.ql

Local Semgrep run:
  semgrep --config ./rules/semgrep/ <path>

Suggested CI wiring:
  - Add `./rules/semgrep/` to the existing Semgrep CI step
  - Register the CodeQL query in `.github/codeql/codeql-config.yml`

Current sweep: <N> additional sites in the repo match this rule
(see ./rules/semgrep/<finding-id>.review.txt) — file each as a
follow-up finding or fix before enabling the rule in CI to avoid
day-one breakage.
```

If the rule pair has multiple sites in the codebase, write the list
to `./rules/semgrep/<finding-id>.review.txt` so the user has a
durable record.

## Why both Semgrep and CodeQL

- **Semgrep**: AST-pattern matching, fast (<1s for most patterns),
  language-agnostic, fits pre-commit hooks and PR CI gates. Catches
  the *shape* of the bug at the call site.
- **CodeQL**: dataflow-aware, catches taint that survives variable
  passing, function calls, and serialization round-trips. Slower (CI
  minutes), but catches the cases Semgrep misses (source far from
  sink, taint through a helper).

Writing both keeps the bug-class door closed at two layers: AST
pattern at PR time, dataflow at audit time.

## When this skill triggers

- User types `/codify <finding-id>`
- User says "turn this into a lint rule", "Semgrep rule for this",
  "CodeQL query", "let's prevent this bug class from coming back"
- After `/full-audit`, on each surviving High finding

## When NOT to use

- Confidence <8 finding — the pattern is FP-prone, the rule will be
  noisier than the finding was.
- One-off findings unique to a specific feature being deleted — the
  rule outlives the finding only when the bug shape is general.
- For dep-CVE vulnerabilities — those are handled by SCA tools, not
  pattern rules.
