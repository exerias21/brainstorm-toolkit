---
name: repo-onboarding
description: >
  Inspect a repository and generate the cross-tool contract files this toolkit's
  skills rely on: `AGENTS.md` (architecture + agent instructions), `TASKS.md`
  (work queue), `.claude/project.json` (runner config), and `GOTCHAS.md` (pitfalls).
  Use when onboarding a new repo to the workflow toolkit, or when /onboard,
  /discovery, /codelearn, or /init-toolkit is invoked. Replaces the separate
  /codelearn skill — architecture discovery is part of onboarding here.
metadata:
   brainstorm-toolkit-applies-to: claude copilot
---

# Repo Onboarding / Discovery

This skill inspects the current repository and generates the config files that
the rest of the toolkit reads. Run this **once per repo** after dropping the
toolkit's skills and scripts in place. After it finishes, `/test-check`,
`/eval-harness`, and `/sdlc` should work with no further setup.

## When triggered

- User invokes `/repo-onboarding`, `/discovery`, `/onboard`, `/codelearn`, or `/init-toolkit`
- User says "set this repo up for the toolkit", "onboard this repo", "analyze this codebase", "bootstrap AGENTS.md"
- After the user runs `setup.sh` from the brainstorm-toolkit plugin

## Output

Produces (or offers to produce):
- `AGENTS.md` (at repo root) — architecture summary + agent conventions (absorbs /codelearn)
- `TASKS.md` (at repo root) — empty task queue from template
- `.claude/project.json` — the runner config contract
- `GOTCHAS.md` (at repo root) — empty template if missing
- A short report of what was detected and what was left blank

## Procedure

### Step 1 — Scan the repo

In the main context window (no subagents), survey the repo structure:

1. **Language / stack fingerprints**:
   - `package.json` → Node/JS/TS project. Note `scripts.test`, `scripts.e2e`, workspace layout.
   - `pyproject.toml` / `requirements.txt` / `Pipfile` → Python. Check for pytest config.
   - `go.mod` → Go. Test command is `go test ./...`.
   - `Cargo.toml` → Rust. Test command is `cargo test`.
   - `Gemfile`, `pom.xml`, `build.gradle`, etc. → flag the stack.

2. **Container/orchestration**:
   - `docker-compose.yml` / `compose.yml` → read service names
   - `Dockerfile` only → single-container app
   - `kubernetes/` or `k8s/` or Helm chart → kubectl-based logs
   - None → logs come from processes or log files directly

3. **Test infrastructure**:
   - `tests/` dir with `test_*.py` → pytest
   - `__tests__/`, `*.test.ts` → jest/vitest
   - `playwright.config.*` → e2e tests present
   - `vitest.config.*` / `jest.config.*` → unit test runner

4. **Eval/fixtures (rare — toolkit-specific)**:
   - `evals/` directory → already set up for eval-harness
   - `tests/eval/` directory → already has eval tests

5. **Branch info**:
   - `git remote -v` + `git symbolic-ref refs/remotes/origin/HEAD` → default branch name

6. **Existing docs**:
   - `README.md`, `CLAUDE.md` → skim for existing commands and conventions

### Step 2 — Propose the config

Build a draft `project.json` from what you found. Fill in:

- `test.unit` — from detected test framework
- `test.frontend` — if a separate frontend package was detected
- `test.e2e` — if Playwright/Cypress/etc. was detected
- `logs.command` — from detected orchestration (docker / kubectl / file tail)
- `logs.services` — from compose services or k8s deployments
- `eval.runner` — only if `scripts/eval-runner.py` exists (from the toolkit)
- `eval.features_dir` — `evals/` if dir exists, otherwise blank
- `gotchas_file` — `GOTCHAS.md` (default)
- `main_branch` — from git
- `modules` — inferred from top-level code directories (`src/`, `api/`, `web/`, `packages/*`, etc.)

**When unsure, leave the key out.** A missing key causes skills to skip that step
gracefully — that's better than a wrong command.

### Step 3 — Show the user the proposal

Present the proposed `project.json` to the user with a brief rationale for each
section:

```
Proposed .claude/project.json:
{ ... }

Detection notes:
- Detected Python + pytest → test.unit
- Detected docker-compose with services [api, web] → logs.*
- Didn't find an eval runner → left eval.* blank
- Main branch: main (from origin HEAD)
- Modules inferred from top-level dirs: [api, web]

Does this look right? Any keys to add, remove, or correct?
```

### Step 4 — Write AGENTS.md (architecture summary)

If `AGENTS.md` is missing (or the user asks to regenerate it), produce one by filling in the placeholders in `templates/AGENTS.md.template`. Derive each section from the scan:

- **Project summary** — 1–3 sentences. Infer from `README.md`, package name, top-level structure.
- **Tech stack** — bullet list from detected stack (language, framework, DB, test/build tools).
- **Architecture at a glance** — 5–10 bullets covering: top-level module layout, how requests flow (entry point → router → service → data), key cross-module dependencies. Do NOT invent what you can't see.
- **Build / test / run** — concrete commands, preferring what's already in `README.md` or `package.json` scripts. If unsure, say "TODO: confirm with maintainer" inline.

Keep each section terse. AGENTS.md is read by every agent, every session — brevity beats completeness.

### Step 5 — Write the files

After the user confirms (or adjusts):

1. Write `.claude/project.json` (create `.claude/` if missing).
2. Write `AGENTS.md` at repo root. If `CLAUDE.md` is also missing, symlink it to `AGENTS.md` on POSIX, else copy.
3. If no `TASKS.md`, copy `templates/TASKS.md.template` to repo root.
4. If no `GOTCHAS.md` at repo root, create one from `examples/GOTCHAS.md.example`.

### Step 5.5 — Offer secret-blocking PreToolUse hook (Claude only)

After the project.json bootstrap, ask the user:

> "Enable secret-blocking PreToolUse hook? (recommended for production repos)
> When enabled, Claude Code blocks Write/Edit if the about-to-be-written
> content matches a known secret shape (AWS keys, GitHub tokens, JWTs,
> private-key blocks). Default: off. (Copilot consumers: this hook is
> Claude-only — no effect for you.)"

- **On no**: leave both `pipeline.poka_yoke` and `.claude/settings.json`
  unchanged. Note in the report that the user declined.
- **On yes**:
  1. Set `pipeline.poka_yoke: true` in `.claude/project.json`.
  2. Write the PreToolUse hook entry into `.claude/settings.json` (create
     the file if missing; merge into existing `hooks.PreToolUse` list rather
     than overwriting). The schema is documented in
     `templates/AGENTS.md.template` under "Hooks (Claude-only)" — matcher is
     `"Write|Edit"`, `command` runs the secret-pattern scanner, non-zero
     exit blocks the tool call.
  3. If a `scripts/hooks/secret-scan.sh` is not already present in the repo,
     stub one out (or document where the user should drop it) using the
     pattern set in `examples/GOTCHAS.md.example` "Secret Patterns
     (recommended for hooks)".

### Step 6 — Report

Report what was written and suggest next steps:
   - "Try `/test-check` to see which steps run."
   - "Start a new feature with `/brainstorm [topic]` or `/task <description>`."
   - "See current work queue with `/status`."

## What NOT to do

- **Do not overwrite an existing `project.json`** without explicit confirmation.
  If one already exists, read it, show the user what's there vs. what you'd
  propose, and ask.
- **Do not infer commands that haven't been verified.** If you see `pytest.ini`
  but no actual tests pass, still propose the pytest command but flag it.
- **Do not generate evals.** That's a separate skill (/eval-harness). This skill
  only sets up the config needed for evals to work if the user chooses to use them.

## Detection heuristics reference

| Signal | Implies |
|---|---|
| `package.json` with `"test"` script | `test.unit` or `test.frontend` = `npm test` (or pnpm/yarn equivalent) |
| `pyproject.toml` with `[tool.pytest]` | `test.unit` = `pytest` |
| `playwright.config.*` at root | `test.e2e` = `npx playwright test` |
| `docker-compose.yml` | `logs.command` = `docker compose logs {service} --tail={tail}`, `logs.services` from compose services |
| Kubernetes manifests | `logs.command` = `kubectl logs deploy/{service} --tail={tail}` |
| `go.mod` | `test.unit` = `go test ./...` |
| `Cargo.toml` | `test.unit` = `cargo test` |
| Top-level dirs like `api/`, `web/`, `worker/` | `modules` list |
| `.git/HEAD` or `origin` default | `main_branch` |
