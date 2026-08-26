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
   brainstorm-toolkit-applies-to: claude copilot codex
---

# Repo Onboarding / Discovery

This skill inspects the current repository and generates the config files that
the rest of the toolkit reads. Run this **once per repo** after dropping the
toolkit's skills and scripts in place. After it finishes, `/test-check`,
`/eval-harness`, and `/sdlc-lite` should work with no further setup.

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
- `stack.up` / `stack.down` / `stack.rebuild` — how to bring the runnable stack up and
  down for **manual verification**; propose only from a detected orchestrator, never
  invent one (see the detection table). `rebuild` is the force-recreate variant used
  when a dependency manifest changed.
- `stack.url` — the local URL to open once it is up, if a port is discoverable from
  compose/Procfile/framework config
- `eval.runner` — only if `scripts/eval-runner.py` exists (from the toolkit)
- `eval.features_dir` — `evals/` if dir exists, otherwise blank
- `gotchas_file` — `GOTCHAS.md` (default)
- `main_branch` — from git
- `modules` — inferred from top-level code directories (`src/`, `api/`, `web/`, `packages/*`, etc.)
- `models.cap` — the standing **sub-agent model-tier ceiling** for every fan-out
  skill (`/sdlc-lite`, `/dead-code-review`, `/brainstorm-*`, …). A ceiling, not a swap:
  tiers rank `haiku (1) < sonnet (2) < opus (3)` and `effective = min(default, cap)`
  — the cap only ever *lowers*, so `cap: "sonnet"` runs Opus sites at Sonnet while
  Haiku/Sonnet sites are untouched. Governs **sub-agent dispatch only**, never the
  session orchestrator. Valid values: exactly `haiku`, `sonnet`, `opus`; absent =
  no cap (skills still default Sonnet-first, but a written cap makes it enforced
  policy). Full contract: `skills/sdlc/templates/models.md`. **Default the
  proposal to `{ "cap": "sonnet" }`** — it's the right ceiling for almost every
  repo (keeps quality on review/verify stages while cutting Opus cost); propose
  `haiku` only if the user wants to squeeze the cheap mechanical sweeps, or omit
  it only if they explicitly want uncapped Opus fan-out.

**When unsure, leave the key out.** A missing key causes skills to skip that step
gracefully — that's better than a wrong command. (Exception: `models.cap` — prefer
proposing `sonnet` over omitting, per above.)

### Step 3 — Show the proposal, then walk the model choices

First print the proposed `project.json` with a one-line rationale per detected key
(`Detected Python + pytest → test.unit`; `docker-compose services [api, web] → logs.* + stack.*`;
`no eval runner → eval.* left blank`; `main branch from origin HEAD`; …).

**Then ask the model questions explicitly — do not bury them in "does this look right?".**
Detection can't decide these, they are the main cost/quality levers, and a user who is
never asked never discovers the key exists. Ask all four at once — prefer the host's **built-in
interactive question UI** (the multiple-choice picker it already uses to ask you to choose an
approach): one question per key, options as choices, recommended default first. Where the host has
no such UI, print a numbered list and take the answers in a single reply. Default first so "just
accept" is one
keystroke, and state the cost direction in each option:

| Ask | Key | Options (default first) |
|---|---|---|
| **Ceiling for every sub-agent fan-out — implementers, fix agents, sanity + review lenses.** The single biggest cost lever. | `models.cap` | `sonnet` (Sonnet-first standing default) · `haiku` (cheapest; fine for sweeps/monitoring) · `opus` (**no ceiling** — every stage runs at its own full default tier) · omit |
| **Which model pre-flights your plan before any code is written** (Stage 1.5, never gated — it runs on *every* `/sdlc-lite` run). Say plainly that the built-in is Haiku and that **`models.cap` cannot raise it** — this key is the only lever. | `models.sanity` / `.focuses` | omit → 3 Haiku agents (`paths`, `completeness`, `gotchas`) · `sonnet` (better judgment on `completeness`, which asks whether the plan hangs together) · fewer focuses to cut cost (`paths` is mechanical; drop `gotchas` when there's no `GOTCHAS.md`) |
| **Enable the adversarial Review→Fix stage?** Off unless you say yes — it never runs by accident. | `pipeline.review_fix.enabled` / `.model` | `false` (default) · `true` + reviewer `opus` · `true` + reviewer `fable` (usage-billed, explicit opt-in) |
| **How many review lenses?** Ask only if the stage was just enabled. One reviewer call per lens at the reviewer model, so this scales the stage's cost roughly linearly. | `agents.code_review_lenses` | omit → all four (`correctness`, `plan-alignment`, `config-env-docs`, `security`) · `["correctness", "security"]` (half cost; good default for app code) · `["correctness"]` (quarter cost; highest-yield single lens) |
| **How do you bring this app up for manual verification?** Confirm or correct what was detected. | `stack.up` / `stack.rebuild` / `stack.url` | the detected compose/dev commands · corrected by the user · omit (skills then say which key is missing instead of guessing) |

Explain the interaction once, because it surprises people: **`models.cap` is a ceiling, not a
target** — it can only *lower* a stage's default tier, never raise it. So `plan_validate.model:
"opus"` under `models.cap: "sonnet"` still dispatches Sonnet. If a per-stage tier is meant to
actually take effect, the cap must be at or above it. Close with the open catch-all: *"Anything
else to add, remove, or correct?"*

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
5. **Update `.gitignore`.** The toolkit's working files are *local* working
   files — they churn every run, they are personal to whoever is driving, and
   they are a merge-conflict magnet in any repo with more than one contributor.
   Ensure these lines are present (create `.gitignore` if missing; append under a
   `# brainstorm-toolkit` comment — don't duplicate lines that already exist):
   ```gitignore
   # brainstorm-toolkit — local working state, not shared contract
   .claude/pipeline/
   .claude/.next-action
   .claude/.auto-continue-hops
   .claude/project.json
   TASKS.md
   plans/
   ```

   Why each:
   - `.claude/pipeline/` — per-run `/sdlc-lite` + `/sdlc-lite` envelopes; one dir per
     run, pure churn if tracked.
   - `.claude/.next-action` / `.auto-continue-hops` — the seam's scratch files.
   - `.claude/project.json` — **machine-specific.** It holds test commands, paths
     and runner invocations that differ per checkout. The committed template is
     `.claude/project.json.example`; a fresh clone copies it and edits locally.
   - `TASKS.md` — a personal work queue, rewritten constantly.
   - `plans/` — personal planning artifacts.

   **Ignoring these does not break the cross-tool contract.** Copilot and Codex
   read these files off disk in the working copy; `.gitignore` governs what gets
   *shared*, not what gets *read*. The contract is per-checkout, and it still holds.

   **Keep tracked:** `.claude/project.json.example` (the bootstrap template),
   `.claude/settings.json` (hook wiring the team does share), `AGENTS.md`,
   `GOTCHAS.md`, and any committed agent/skill definitions.

   Note the knock-on: with `project.json` ignored, a fresh clone has the example
   but not the real file, so `/repo-health` Check 9 will flag "config inert" until
   someone copies it. That is the intended nudge, not a false positive.

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
| `docker-compose.yml` | `logs.command` = `docker compose logs {service} --tail={tail}`, `logs.services` from compose services; `stack.up` = `docker compose up -d --build`, `stack.down` = `docker compose down`, `stack.rebuild` = `docker compose up -d --build --force-recreate`; `stack.url` from the first published host port |
| Kubernetes manifests | `logs.command` = `kubectl logs deploy/{service} --tail={tail}`; leave `stack.*` unset — a cluster is not a local up/down |
| `package.json` with a `dev`/`start` script and no compose file | `stack.up` = that script (`npm run dev`); no `stack.rebuild` unless a build step is separate |
| `go.mod` | `test.unit` = `go test ./...` |
| `Cargo.toml` | `test.unit` = `cargo test` |
| Top-level dirs like `api/`, `web/`, `worker/` | `modules` list |
| `.git/HEAD` or `origin` default | `main_branch` |
| Always (standing policy) | `models.cap` = `"sonnet"` — Sonnet-first ceiling for sub-agent fan-out; propose `haiku` to squeeze cheap sweeps, omit for uncapped Opus |
| Repo uses this toolkit | gitignore the local working state: `.claude/pipeline/`, `.claude/.next-action`, `.claude/.auto-continue-hops`, `.claude/project.json`, `TASKS.md`, `plans/`. Keep `.claude/project.json.example` tracked as the bootstrap template |
