---
name: docstring-sync
description: >
  Repair docstrings and comments that drifted from their code: stale or wrong claims,
  param/return mismatches, placeholder text, and pointers to plan files or tickets that rot.
  Deterministic checks run first; an LLM rewrites only the flagged ones, and you review the diff.
  Never commits. Use on /docstring-sync, "fix stale docstrings", "docstrings are out of date", or
  "clean up legacy comments".
argument-hint: "[path...] [--changed] [--pointers-only] [--all] [--limit N] [--report] [--include-tests] [--include-runtime-docstrings]"
metadata:
  brainstorm-toolkit-applies-to: claude copilot codex
---

# Docstring Sync — repair drifted docs, don't repaint them

A docstring or comment that once matched its function and no longer does is worse than a
missing one: it is a confident, trusted lie. This skill finds the ones that drifted and
edits only what is wrong — it does not rewrite accurate author prose, and it does not add
teaching depth to code that never had any.

**A plan reference never belonged in a docstring to begin with.** Comments like
`# plans/LAUNCH_REQUIREMENT_PHASES.md ... Do not reintroduce.` rot the moment that path moves
or the plan file is gitignored out of existence — the pointer outlives the reason it pointed
to. The COMMENTS rule now carried in every code-writing prompt in this toolkit is the
prevention; this skill is remediation for code written before that rule existed.

Deterministic checks run first and own every mechanical judgment — a script decides what is a
stale pointer, a placeholder stub, or a param/return mismatch, and nothing it can already
decide is ever sent to a model. Only the survivors need judgment, and even then the rewrite
touches exactly the flagged sentence or section. You always get a diff to review before
anything is committed — this skill never commits.

## Scope and flags

**Flags you pass to `/docstring-sync`** — most are forwarded straight to the script; two are
directives this skill itself interprets, marked below:

| Flag | Meaning |
|---|---|
| positional `path...` | limit discovery to these paths; default is the whole repo via `git ls-files -co --exclude-standard` |
| `--changed` | scope to `git diff --name-only HEAD` plus untracked, non-ignored files (read-only); combined with a positional `path...`, scans the intersection — changed files under those paths, not every file under them |
| `--pointers-only` | the fast legacy-cleanup path: plan/ticket/TASKS.md pointer and placeholder findings only, no param/return or missing-docstring checks |
| `--all` | widen triage from candidates (a docstring with an existing finding) to every docstring in scope — only meaningful together with the triage step below; costs roughly 3x the triage tokens |
| `--limit N` | scan (and so edit) at most N discovered files this run, deterministic order, default 25 — the scan is the state, so re-running continues where the last run stopped |
| `--include-tests` | include test files in the docstring checks (they are already scanned for pointers by default) |
| `--report` *(skill directive, not a script flag)* | scan and print findings only; never edits, never triages |
| `--include-runtime-docstrings` *(skill directive, not a script flag)* | also rewrite docstrings the script marked `runtime_visible` (FastAPI/Flask route text, CLI `--help`, doctests) — off by default because these are behavior, not just documentation |

**Flags the script itself accepts**, beyond the pass-through ones above
(`bash scripts/py.sh <skill-dir>/scripts/docstring_check.py --help` is authoritative):
`--json` (machine-readable output, used at Step 3), `--claims-out <file>` and `--verdicts-in
<file>` (the triage step below), `--snapshot` (Step 6), `--verify-docs-only <file>` (Step 8), and
`--self-test` (the script's own CI self-check — not part of this procedure).

## Resolving this skill's own files

A fresh install (`setup.sh`, or the Claude plugin cache) puts this skill's `scripts/` and
`references/` under whatever directory holds this file — `.claude/skills/docstring-sync/`,
`.github/skills/docstring-sync/`, `.agents/skills/docstring-sync/`, or the plugin's own
`skills/docstring-sync/`. There is no `skills/docstring-sync/` at the repo root in any of those —
that path only exists inside this plugin repo itself. Resolve this file's own directory now
(Claude Code reports it as "Base directory for this skill"; Copilot and Codex resolve a skill's
relative paths from its own root the same way, per the Agent Skills spec) and call it
`<skill-dir>` for the rest of this file — every `<skill-dir>/scripts/...` and
`<skill-dir>/references/...` path below is relative to it, never the repo root. `scripts/py.sh`
is the one exception: it is the shared interpreter-resolver `setup.sh` ships to the *repo root*
(see `scripts/py.sh` itself), so it stays repo-root-relative even though the script it runs does
not — if `--no-copy-scripts` was used, `scripts/py.sh` was never installed and these commands
have no interpreter to resolve through; invoke the Python inside `<skill-dir>/scripts/` directly
in that case.

A sub-agent you dispatch (Steps 4 and 7) never gets this resolution — it only sees the literal
prompt text you hand it. Resolve `<skill-dir>` yourself before each dispatch and pass the
resolved path, not the bare citation.

## Procedure

### 1. Agree scope

Resolve the flags above. Say what you're about to scan before you scan it — a whole-repo run
and a `--changed`-scoped run are very different commitments.

### 2. Test baseline, if configured

Read `.claude/project.json` `test.*`. Run whatever is configured (`test.unit`, `test.frontend`)
and record pass/fail counts. No `project.json`, or no `test.*` keys configured, means **no
baseline** — say so and proceed; the docs-only AST/comment-line guard in Step 8 is the primary
safety net regardless of whether tests exist.

### 3. Run the script — report counts per kind before touching anything

Run `bash scripts/py.sh <skill-dir>/scripts/docstring_check.py <scope-flags> --json`.
Report the findings grouped by kind (`POINTER`, `PLACEHOLDER`, `THIN`, `MISSING`, `BODY_NEWER`)
**before any file is touched** — a plan, not a surprise. `MISSING` is always report-only in this
run; it never queues an edit. On `--report` or `--pointers-only`, stop here: print the summary
and end without triaging or editing anything.

### 4. Triage — find only, one pass before any edit

Skipped entirely on `--report` or `--pointers-only` — there is nothing to judge on either of
those runs.

Run `bash scripts/py.sh <skill-dir>/scripts/docstring_check.py <scope-flags>
--claims-out <scratch-file> --json` (a scratch path under the OS temp directory, same as Step 6's
snapshot — nothing lands in the repo; pass `--all` through if the run was given it). Group the
written claims by the leading path segment of each claim's id (`<path>::<symbol>::<sentence>`) so
each group is exactly one file's claims, plus that file's full source for any symbol the run's
`oversized` list names instead of a capped evidence string.

Dispatch one triage sub-agent per file group, using
`<skill-dir>/references/triage-prompt.md` as the role prompt verbatim — **parallel,
single message, multiple tool calls on Claude**; on Copilot and Codex, run each group inline and
sequentially in this session, per the standing runtime note in `skills/repo-health/SKILL.md`.
Before each dispatch, resolve the tier (`models.docstring_sync`, Sonnet by default) per
`skills/sdlc/templates/models.md`, print `model: docstring_sync=<tier> (cap: <cap|none>)` and pass
`model` explicitly.

Merge every sub-agent's `{id: {verdict, quote?}}` object into one verdicts file, then run
`bash scripts/py.sh <skill-dir>/scripts/docstring_check.py <scope-flags> --verdicts-in
<merged-file> --json` (same scope flags, including `--all`, as the `--claims-out` call above) to
fold the results into `STALE` findings.

### 5. One confirmation

A single confirmation to proceed with edits — not a per-finding approve/edit/skip loop. Show
every `STALE` finding with its claim sentence and verifying quote side by side, not just a bare
count, so what's about to be accused is visible before anything is touched. On "no", or on a
non-interactive run with no channel to ask, treat the run exactly like `--report`: print the
summary and stop. An opinion nobody confirmed must not become an edit.

### 6. Snapshot before editing

Run `bash scripts/py.sh <skill-dir>/scripts/docstring_check.py <scope-flags> --snapshot`.
Prints a path under the OS temp directory — nothing lands in the repo, so no new gitignore
entry. Keep this path; Step 8 verifies against it.

### 7. Rewrite fan-out, at most `--limit` files

The confirmed edit set is the Phase 1 `certain` `PLACEHOLDER`/`THIN`/`POINTER` findings plus this
run's `STALE`/`certain` findings from Step 4 — never a `suspect` finding, and never `MISSING`.
Batch that set by file, roughly 8 files per batch, capped overall at `--limit` files (default 25;
a run that hits the cap says so and that a re-run continues from where this one stopped).

Dispatch one rewrite sub-agent per batch, using `<skill-dir>/references/rewrite-prompt.md` as the
role prompt verbatim, **prefaced with the two absolute paths it asks the sub-agent to read**:
`<skill-dir>/references/rewrite-rules.md` and the sibling code-tour skill's own
`references/standards.md` (same parent directory as `<skill-dir>`, i.e.
`<skill-dir>/../code-tour/references/standards.md`) — resolve both yourself and hand over the
literal paths; the sub-agent has no base directory of its own to resolve a bare citation against.
Same parallel-Claude / inline-sequential-Copilot-Codex shape and the same `model: docstring_sync=<tier>
(cap: <cap|none>)` print, per batch, before each dispatch. **Triage and rewrite are separate passes with
the human confirmation between them: neither may both accuse and fix** — a pass that does both
grades its own accusation (`skills/sdlc/templates/stage-5.9-cleanup.md`'s framing for the same
split). Roll up each sub-agent's `{symbol, action, unresolved}` list into the run's report.

### 8. Verify

Run `bash scripts/py.sh <skill-dir>/scripts/docstring_check.py <scope-flags> --verify-docs-only <snapshot-path>`,
then `bash scripts/py.sh <skill-dir>/scripts/docstring_check.py <touched-files> --json`.
The first call proves the edit is docs-only: a Python file's AST with docstrings stripped must
be unchanged, and every changed line in a non-Python file must be a comment or blank line. A
non-Python file containing a multi-line string construct (a backtick template literal, a
`'''`/`"""` block, a YAML `|`/`>` block scalar, a shell heredoc) is compared verbatim instead —
the output says so under `note:` — since per-line comment stripping cannot tell a data line
inside one of those from a real comment. The second re-scans exactly the files you touched — **zero remaining `certain`-severity `POINTER`
findings are allowed**; if one remains, the run is not done. Then re-run whatever test baseline
Step 2 established. A regression here means you edited behavior, not documentation.

### 9. Report

- Findings per kind, before and after.
- Files touched, and how many were left for a future run because of `--limit`.
- Rewrite outcomes grouped by `unresolved.reason` (`runtime_visible`, `no-recoverable-plan`,
  `ambiguous-cannot-verify`) — a pointer whose reason could not be recovered keeps its bare
  instruction with the pointer dropped, listed here for a human to fill in, never guessed at.
- `git diff --stat`.
- A suggested commit message. **This skill never commits** — the diff is yours to review and
  commit.

## Not this skill

- **Teaching-depth docstrings for a learning audience** — writing docstrings and a guided
  reading path where good documentation never existed — is `/code-tour`'s job, not this one's.
  This skill repairs; it does not add depth code never had.
- **A diff-scoped pass inside `/sdlc`** already exists: Stage 5.9's `docstring-currency` cleanup
  lens checks only the functions that run's diff changed. Use this skill for a standing pass
  over the rest of the repo.
