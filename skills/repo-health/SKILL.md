---
name: repo-health
description: >
  Read-only repo hygiene sweep. Runs dead-code, tests, dependency audit,
  secret scan, and gotchas-currency in parallel; rolls findings into a
  single scored report. Use this when the user says /repo-health, asks
  for a "hygiene check", "weekly sweep", "is this repo healthy",
  "what should I clean up", or before a release. Read-only — produces a
  report and a `.next-action` suggestion, never modifies code.
argument-hint: "[--no-dead-code] [--no-tests] [--no-deps] [--no-secrets] [--no-gotchas]"
metadata:
  brainstorm-toolkit-applies-to: claude copilot
---

# Repo Health

Composes existing checks into one weekly-sweep workflow. Read-only: produces
a scored report and drops a `.claude/.next-action` with the highest-impact
next command. Never modifies code, never opens a PR.

For deeper or more action-oriented variants:
- Use `/dead-code-review` directly for a thorough multi-agent scan.
- Use `/test-check` for the full test+log audit pipeline.
- The future `/cleanup` skill will turn this report into mechanical PRs.

## Arguments

- `--no-dead-code` / `--no-tests` / `--no-deps` / `--no-secrets` / `--no-gotchas`:
  opt out of any individual check. Default: run all five. Skipped checks
  appear in the report as `skip` with the reason.

## Procedure

Launch all enabled checks **in parallel** on Claude Code (single message,
multiple tool calls). On Copilot, run sequentially. Each check returns a
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

## Roll-up

Compute a score: `100 - min(60, 10*high_findings + 5*high_deps + 3*stale_gotchas + 2*test_failures + 1*orphan_files + 1*skipped_tests)`. Floor at 40 — a single bad metric shouldn't drive the score to zero.

Print the report:

```
Repo Health Report — <date> (<branch>)

Score: 87 / 100  (▼ 5 from last sweep if .claude/pipeline/last-health.json exists)

  ✓ Dead code:     2 orphan files, 1 unused export, 3 skipped tests
  ✓ Tests:         142 passed, 0 failed (test.unit only — frontend skipped)
  ⚠ Dependencies:  1 HIGH (left-pad@1.3.0 — CVE-2026-XXXX)
  ✓ Secrets:       clean (gitleaks)
  ⚠ Gotchas:       1 stale ("Old auth middleware" — references removed module)

Suggested next: /sdlc to fix the dep vuln
                /gotcha to revise the stale entry

Run again with --no-deps if dep audit is too slow on this repo.
```

The "Suggested next" is the highest-impact actionable command (priority:
dep HIGH > test failure > stale gotcha > orphan file > skipped test). Drop
this command into `.claude/.next-action` so the Stop hook surfaces it.
If no actionable findings, write nothing — clean repos shouldn't nag.

Optionally cache the report at `.claude/pipeline/last-health.json` so a
future run can show the delta. This is best-effort — failing to write the
cache never fails the run.

## When this skill triggers

- User types `/repo-health`
- User asks "is this repo healthy", "weekly hygiene check", "what should
  I clean up", "any tech debt I'm missing"
- Pre-release sanity sweep
- New maintainer inheriting an unfamiliar repo (run alongside
  `/repo-onboarding`)

## When NOT to use

- Mid-implementation — health sweeps are noisy when you're actively
  changing things. Run after merges land.
- For a deep dead-code investigation — `/dead-code-review` is the
  multi-agent thorough variant.
- For PR-scoped review — use `/review` or `/sdlc`'s Stage 5.5 instead.
