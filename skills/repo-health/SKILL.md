---
name: repo-health
description: >
  Read-only repo hygiene sweep: runs dead-code, tests, dependency audit, secret scan, and
  gotchas-currency in parallel, rolling findings into a single scored report. Use when the user
  says /repo-health, asks for a "hygiene check", "weekly sweep", "is this repo healthy", "what
  should I clean up", or before a release. Never modifies code — produces a report and a
  `.next-action` suggestion. Run after merges land, not mid-implementation. For a deep dead-code
  investigation use /dead-code-review; for PR-scoped review use /sdlc's Stage 5.
argument-hint: "[--no-dead-code] [--no-tests] [--no-deps] [--no-secrets] [--no-gotchas] [--no-migrations] [--no-pipeline-state] [--no-memory]"
metadata:
  brainstorm-toolkit-applies-to: claude copilot codex
---

# Repo Health

Composes existing checks into one weekly-sweep workflow. Read-only: produces
a scored report and drops a `.claude/.next-action` with the highest-impact
next command. Never modifies code, never opens a PR.

## Arguments

- `--no-dead-code` / `--no-tests` / `--no-deps` / `--no-secrets` / `--no-gotchas`
  / `--no-migrations` / `--no-pipeline-state` / `--no-memory`:
  opt out of any individual check. Default: run all eight. Each check
  self-skips silently when its surface is absent (no migrations dir, no
  pipeline envelopes, no memory pointer), so a repo without that surface
  never sees the check — these are **project-agnostic by construction**.
  Skipped checks appear in the report as `skip` with the reason.

## Procedure

Launch all enabled checks **in parallel** on Claude Code (single message,
multiple tool calls). On Copilot and Codex — neither has a sub-agent seam — run each check **inline in this
session, sequentially**, and report only the structured result per check; never paste raw
tool output into your context. Every 'dispatch a ... agent' below means that inline on
those runtimes. Each check returns a
small structured result that the rollup composes.

### Check 1 — Dead code (Haiku agent)

Dispatch one Haiku agent with this prompt:

```
Scan the repo for unused exports, files with zero callers, and skipped
tests (xit/it.skip/@pytest.mark.skip/test.skip). Use Grep + Glob, not
Read on every file — keep token cost low. Report a JSON object:
  {"unused_exports": [{file, symbol}], "orphan_files": [path],
   "skipped_tests": [{file, name, reason}]}
Cap each list at 20 entries; note the cap in the response if hit.
```

Skip if `--no-dead-code`.

### Check 2 — Tests (procedural)

Read `.claude/project.json`. If `test.unit` is configured, run it; if
`test.frontend` is configured AND frontend files exist, run it too. Capture
pass/fail counts. Don't fix failures — just report.

If `.claude/project.json` doesn't exist or has no `test.*` keys, mark this
check `skip` with reason `no test commands configured`.

### Check 3 — Dependency audit (procedural)

Detect package manager from project files in repo root (and one level deep
for monorepos):

| File | Command |
|---|---|
| `package.json` | `npm audit --omit=dev --json` (parse `vulnerabilities`) |
| `pyproject.toml` or `requirements.txt` | `pip-audit --format json` if available, else `safety check --json` |
| `Cargo.toml` | `cargo audit --json` |
| `go.mod` | `govulncheck ./...` (text output; count CRITICAL/HIGH lines) |

If none detected, mark `skip` with reason `no recognized package manifest`.
If the tool is missing on PATH, mark `skip` with reason `<tool> not
installed` (don't fail — many envs lack these).

Important: for audit tools that commonly exit non-zero when they find
vulnerabilities (`npm audit`, `pip-audit`, `safety check`, `cargo audit`),
do **not** treat that exit code by itself as a fatal failure. Capture the
stdout/stderr or JSON report, parse the findings, and continue the sweep.
Only mark the check `error`/`skip` if the tool is missing or it fails to
produce usable output.

Report counts of HIGH/CRITICAL vulnerabilities only. MEDIUM/LOW are noise
for a sweep.

### Check 4 — Secret scan (procedural)

Run `gitleaks detect --no-git --source . --report-format json
--report-path /tmp/repo-health-secrets-$$.json --exit-code 0` if available.
If `gitleaks` is not installed, fall back to a regex sweep using the same
pattern set as `/sdlc` Stage 6 (AWS keys, GitHub tokens, private-key
blocks, OpenAI/Anthropic keys, generic api/secret/token strings). Scope
the regex sweep to tracked files only (`git ls-files`) to avoid scanning
node_modules / .venv / build output.

Report HIGH-severity finding count and the tool used.

### Check 5 — Gotchas currency (Haiku agent)

If `GOTCHAS.md` (or the path in `.claude/project.json::gotchas_file`) does
not exist, mark `skip` with reason `no GOTCHAS.md`.

Otherwise dispatch one Haiku agent:

```
Read GOTCHAS.md. For each gotcha, identify the concrete file paths,
function names, or symbols it references. Grep the repo for each
reference. Report:
  {"stale_gotchas": [{title, missing_reference}]}
A gotcha is "stale" only if EVERY referenced anchor is missing — a partial
miss likely just means the file was renamed and the gotcha still applies
to the new location. Cap the list at 10.
```

### Check 6 — Migration drift (procedural)

Catches the "migration file merged but never applied to the live DB" class
(a version-pointer check, not a schema diff). Read `.claude/project.json`:

- If no `migrations.dir` key → `skip` with reason `no migrations.dir configured`.
- Glob `migrations.dir` for `NNN_*` / `VNNN__*` files; take the highest `NNN`
  as the **repo head**.
- If `migrations.applied_check` is configured (a shell command or SQL that
  prints the applied version), run it to get the **applied head** and compare.
  Repo head > applied head → `warn`: "N migration(s) in repo not applied to
  the configured DB (repo @ NNN, applied @ MMM)."
- If `applied_check` is absent, report informationally: "repo has N migrations;
  applied state unknown — set `migrations.applied_check` or run
  `/repo-health`." Never fail; never connect to a DB without an
  explicit configured command.

### Check 7 — Pipeline-state freshness (procedural)

Catches state envelopes left `in_progress` after the work was committed outside the
pipeline. Run the shared scan in `skills/sdlc/templates/envelope-staleness.md` — including
its false-positive guards — and report each stale run plus the reconcile hint. Read-only:
report, never rewrite the envelope. Absent `.claude/pipeline/` → `skip` silently.

### Check 8 — Memory-pointer staleness (procedural, repo-local only)

**Scope guard**: only inspect a *repo-local* memory pointer if the project
declares one (`.claude/project.json::discipline.memory_index`, e.g. a committed
`MEMORY.md`). **Never read the user-global `~/.claude/...` memory dir** — that
is personal, out of repo scope, and not this skill's business. If no repo-local
memory index is configured → `skip` with reason `no repo-local memory index`.

When one exists, dispatch a Haiku agent: count entries, flag pairs of entries
whose `name:` slugs are near-duplicates (Levenshtein < 5), and flag any entry
whose `description:` references a file path that no longer exists. Report
`{count, near_duplicates: [[a,b]], dangling: [{name, missing_path}]}`. Cap at 10.

### Check 9 — Config inertness (procedural, cheap)

A pure file-existence test, no agent. If `.claude/project.json.example` exists and
`.claude/project.json` does **not**, report one HIGH finding:

```
config inert — .claude/project.json.example exists but project.json does not.
Every gated setting is silently unread: models.cap (sub-agent tier ceiling),
pipeline.* (review lenses, verbosity, context threshold), test/eval commands.
Fix: cp .claude/project.json.example .claude/project.json  (then trim to taste)
```

This is worth a check of its own because the failure is **silent by design**: skills
graceful-skip on missing config, so an unread `project.json` is indistinguishable from a
deliberate no-config run.

If both files exist, or neither does, → `pass`.

**Also report (informational, not scored):** when `project.json` exists but omits
`agents.code_review_max_lenses` *and* sets `models.cap`, note that the adversarial review
stage's reviewer is not governed by `models.cap` (see `skills/sdlc/templates/models.md`).

**Token-cost follow-up (pointer, never run here).** When Check 9 reports a finding, or when the
user asks where their tokens went, point at:

```
python scripts/token-audit.py --list
python scripts/token-audit.py --session <uuid> --check-cap <tier>
```

Name it; don't run it as part of the sweep.

### Check 10 — Rules drift (Sonnet agent)

Skip with reason `no AGENTS.md/CLAUDE.md` when neither exists at repo root. Otherwise diff the
rules file's claims against `git diff --name-only <main_branch>...HEAD` (empty → fall back to
the last 20 commits on `main_branch` itself); empty either way → skip with reason `no diff`.

Dispatch one agent, Sonnet by default per `skills/sdlc/templates/models.md` (print the `model:`
line):

```
Read AGENTS.md/CLAUDE.md and the changed-file list. For every rule or "where things live"
pointer this change makes FALSE, emit a Fix row with the minimal edit. For a new durable
invariant this change establishes, emit at most three Add rows of one line each. List what was
checked and is still true. Report {"fix": [{rule, edit}], "add": [line], "checked_ok": [claim]}.
Cap each list at 10. CLAUDE.md and AGENTS.md are byte-identical in this repo -- a Fix or Add row
touching one must mirror the same edit into the other and say so in the row.
```

### Check 11 — Backlog drift (procedural, cheap)

**New reader:** this check is the first thing in `/repo-health` to read `TASKS.md`.
Skip with reason `no TASKS.md` or `no .claude/pipeline/` when either is absent, and
`no close-tasks.sh` when the script did not install (`--no-copy-scripts`).

Run `bash scripts/close-tasks.sh reconcile --file TASKS.md` — read-only, never pass
`--apply` here (`/repo-health` is read-only by contract; `/sdlc-status --reconcile` owns
the write). Report `drift_count` and up to 10 findings, each with its line and type.
The fix command is `/sdlc-status --reconcile`.

## Roll-up

Compute a score: `100 - min(60, 10*high_findings + 5*high_deps + 4*unapplied_migrations + 3*stale_gotchas + 3*rules_drift_fixes + 3*backlog_drift + 2*test_failures + 2*stale_pipeline_runs + 1*orphan_files + 1*skipped_tests + 1*stale_memory + 5*config_inert)`. Floor at 40 — a single bad metric shouldn't drive the score to zero.

Print the report:

```
Repo Health Report — <date> (<branch>)

Score: 87 / 100  (▼ 5 from last sweep if .claude/pipeline/last-health.json exists)

  ✓ Dead code:     2 orphan files, 1 unused export, 3 skipped tests
  ✓ Tests:         142 passed, 0 failed (test.unit only — frontend skipped)
  ⚠ Dependencies:  1 HIGH (left-pad@1.3.0 — CVE-2026-XXXX)
  ✓ Secrets:       clean (gitleaks)
  ⚠ Gotchas:       1 stale ("Old auth middleware" — references removed module)
  ⚠ Migrations:    repo @ 232, applied @ 231 — 1 unapplied (run migrations)
  ⚠ Pipeline:      1 stale run ("todos-multi-notes" in_progress 3d; committed outside)
  ✓ Memory:        no repo-local index (skipped)
  ✓ Config:        project.json present, matches project.json.example
  ⚠ Rules:         1 fix ("AGENTS.md still says Stage 6 opens a PR")

Suggested next: apply pending migration 232 (the highest-blast finding)
                /sdlc to fix the dep vuln
                /gotcha to revise the stale entry

Run again with --no-deps if dep audit is too slow on this repo.
```

The "Suggested next" is the highest-impact actionable command (priority:
unapplied migration > dep HIGH > stale pipeline run > test failure > stale
gotcha > orphan file > skipped test > stale memory). Only
append this command to `.claude/.next-action` if the repo is already set up
for that integration (for example, the file already exists or `.gitignore`
already covers `.claude/.next-action` or `.claude/`). Append ONE structured line,
deduped by `cmd` (multi-slot seam; set `confirm:true` only if the command writes
git history; see `docs/SEAM.md`):
`line='{"cmd":"<suggested command>","source":"repo-health","confirm":false}'; grep -qF "$line" .claude/.next-action 2>/dev/null || echo "$line" >> .claude/.next-action`.
Otherwise, print the suggestion in the report only. If no actionable findings,
write nothing — clean repos shouldn't nag.

Optionally cache the report at `.claude/pipeline/last-health.json` only if
that cache location already exists or is already gitignored. This is
best-effort — failing to write the cache never fails the run.
