---
name: repo-onboarding
description: >
  Inspect a repository and generate the cross-tool contract files this toolkit's
  skills rely on: AGENTS.md, TASKS.md, .claude/project.json, and GOTCHAS.md. Use
  when onboarding a new repo to the workflow toolkit, when the user says "set up
  this repo for the toolkit", "generate AGENTS.md", "create project.json", or asks
  how the codebase is laid out, or when /onboard, /discovery, /codelearn, or
  /init-toolkit is invoked.
metadata:
  brainstorm-toolkit-applies-to: claude copilot codex
---

# Repo Onboarding / Discovery

This skill inspects the current repository and generates the config files that
the rest of the toolkit reads. Run this **once per repo** after dropping the
toolkit's skills and scripts in place. After it finishes, `/test-check`,
`/repo-health` and `/sdlc` should work with no further setup.

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
   - `evals/` directory → already set up for the eval runner
   - `tests/eval/` directory → already has eval tests

5. **Branch info**:
   - `git remote -v` + `git symbolic-ref refs/remotes/origin/HEAD` → default branch name

6. **Existing docs**:
   - `README.md`, `CLAUDE.md` → skim for existing commands and conventions

7. **Sweep the whole repo, then account for every key.** The fingerprints above are the
   common cases, not the contract. Walk the actual tree (honour `.gitignore`; skip
   `.git/`, `node_modules/`, `venv/`, build output) and also read `Makefile` / `Justfile`
   / `Taskfile.*` targets, `.github/workflows/*` (where the real test/lint/build commands
   are usually written down), `.env.example`, `Procfile`, `pytest.ini` / `tox.ini` /
   `setup.cfg`, `migrations/` / `alembic/` / `prisma/`, workspace globs, published ports.

   Then **drive the proposal from the key registry, not from what you happened to
   notice**: open `.claude/project.json.example` (in the plugin repo itself, the same file
   lives under its templates dir) and put **every** key in one bucket — `detected` (evidence),
   `not applicable` (with why), or `unknown` (ambiguous). That list is what makes the scan
   exhaustive rather than best-effort, and it is the only way a key nobody thought to look
   for gets noticed. Carry it into Step 2; report the `unknown` ones in Step 6.

### Step 2 — Propose the config

If `.claude/project.json` already exists, first run `bash scripts/migrate-project-json.sh check`
(toolkit path: repo-local `scripts/`; else the plugin root, this skill's base directory two levels
up, `<base>/../..`; else `~/.claude/brainstorm-toolkit/`) and offer `apply` for any dead keys it
lists. Headless: apply (a `.bak` is written) and list the moves in the report.

Build a draft `project.json` from what you found. Fill in:

- `test.unit` — from detected test framework
- `test.frontend` — if a separate frontend package was detected
- `test.e2e` — if Playwright/Cypress/etc. was detected
- `logs.command` — from detected orchestration (docker / kubectl / file tail)
- `logs.services` — from compose services or k8s deployments
- `stack.up` / `stack.rebuild` — how to bring the runnable stack up for **manual
  verification**; propose only from a detected orchestrator, never
  invent one (see the detection table). `rebuild` is the force-recreate variant used
  when a dependency manifest changed.
- `stack.url` — the local URL to open once it is up, if a port is discoverable from
  compose/Procfile/framework config
- `eval.runner` — only if `scripts/eval-runner.py` exists (from the toolkit)
- `eval.features_dir` — `evals/` if dir exists, otherwise blank
- `gotchas_file` — `GOTCHAS.md` (default)
- `main_branch` — from git
- `coauthor_trailer` — whether commit messages this toolkit writes or suggests carry a
  `Co-Authored-By: Claude <noreply@anthropic.com>` trailer. **Detection cannot decide this
  — ask (Step 3).** Default `false`. Do not infer it from existing history: a repo whose
  log already shows the trailer may have been committed by a different tool or by a
  contributor who wants it, and neither implies consent for this checkout.
- `discipline.data_globs` — the default `**/migrations/**` misses alembic: when a
  `**/alembic/versions` tree exists, propose adding `**/alembic/**`.
- `discipline.frontend_globs` — when the frontend root is not `frontend/` (e.g. `portal/` holding
  a `package.json` plus `.ts`/`.tsx` files), propose globs rooted there (`portal/**/*.tsx`, ...).
- `modules` — inferred from top-level code directories (`src/`, `api/`, `web/`, `packages/*`, etc.)
- `models.implement`, `models.code_review`, `models.cap` — **choices, not detection** (Step 3).
  `models.cap` is a ceiling that only lowers; absent = no ceiling. **Recommend omitting it**;
  propose `haiku` or `sonnet` only to squeeze cost. Every other `models.*` key exists with its
  default and is edited in `project.json` (`.claude/project.json.example`). Contract:
  `skills/sdlc/templates/models.md`.

**When unsure, leave the key out.** A missing key causes skills to skip that step
gracefully — that's better than a wrong command.

### Step 3 — Show the proposal, then walk the choices detection can't make

**Interactive sessions only.** When there is nobody to answer — a headless `claude -p`
run, a CI job, any non-interactive invocation — **do not ask and do not stop.** Take each
row's documented default (`models.implement: "sonnet"`, review off, no `models.cap`, `coauthor_trailer: false`,
`stack.*` as detected or omitted, the full default `.gitignore` set with no extra paths, no `autoCompactWindow`), then go straight to Steps 4–5 so the repo is actually
onboarded, naming every assumed value in the Step 6 report so it is one edit to correct.

First print the proposed `project.json` with a one-line rationale per detected key
(`Detected Python + pytest → test.unit`; `docker-compose services [api, web] → logs.* + stack.*`;
`no eval runner → eval.* left blank`; `main branch from origin HEAD`; …).

**Then interview the repo's owner about the stack and the architecture — read first, ask
second, and ask as many rounds as it takes.** Step 1 read the code; this is where you find
out what the code cannot tell you. There is no question cap: keep going until you could
write `AGENTS.md` without inventing anything. Ground every question in something you
actually saw — "I see `api/` and `worker/` but no queue client; how does work reach the
worker?" beats "describe your architecture", because the first proves you read the repo and
gives them something concrete to correct. Cover at least:

- **Stack beyond the manifests** — the datastore and why it, the cache, the queue, external
  services and which are load-bearing, anything running in production that has no file in
  this repo.
- **Architecture and request flow** — entry point through to persistence, which modules own
  which responsibility, where the seams are, what talks to what. Draw back what you inferred
  from the scan and ask what is wrong; a correction is faster to give than a description.
- **What is deliberately unusual** — every repo has a decision that reads as a mistake and
  isn't. Ask for it directly; it is the highest-value thing you can put in `AGENTS.md`, and
  it is invisible to a scan.
- **Where the bodies are** — the flaky area, the module nobody touches, the migration that
  must run in a certain order. These become `GOTCHAS.md` entries, not architecture prose.
- **How work actually ships** — branch and review conventions, what must pass before merge,
  what is enforced by CI versus by habit.

Take the answers into Step 4 (`AGENTS.md`) and into `GOTCHAS.md`; anything that resolves a
config key goes into the proposal above. Skip this interview entirely when non-interactive,
per the rule at the top of this step.

**Then ask the choices detection can't make — do not bury them in "does this look right?".**
**Read `skills/repo-onboarding/references/step-3-choices.md` now**: one batch, one question per
key, recommended default first, via the host's interactive question UI when it has one. It covers
`models.implement`, the Review→Fix stage and `models.code_review`, `models.cap`, `models.sanity`,
review lenses, `stack.*`, the `.gitignore` selection, `coauthor_trailer` and `autoCompactWindow`,
plus the note that `models.cap` is a ceiling, never a target. Step 5 writes exactly what these
answers chose.

### Step 4 — Write AGENTS.md (architecture summary)

If `AGENTS.md` is missing (or the user asks to regenerate it), produce one by filling in the placeholders in `templates/AGENTS.md.template`. Derive each section from the scan:

- **Project summary** — 1–3 sentences. Infer from `README.md`, package name, top-level structure.
- **Tech stack** — bullet list from detected stack (language, framework, DB, test/build tools).
- **Architecture at a glance** — 5–10 bullets covering: top-level module layout, how requests flow (entry point → router → service → data), key cross-module dependencies. Do NOT invent what you can't see.
- **Build / test / run** — concrete commands, preferring what's already in `README.md` or `package.json` scripts. If unsure, say "TODO: confirm with maintainer" inline.

Keep each section terse. AGENTS.md is read by every agent, every session — brevity beats completeness.

### Step 5 — Write the files

After the user confirms or adjusts — or immediately, with the recorded defaults, when
Step 3 was skipped as non-interactive. **This step always runs.** Reaching Step 5 and
writing nothing is a failed onboarding, not a cautious one:

1. Write `.claude/project.json` (create `.claude/` if missing).
2. Write `AGENTS.md` at repo root. If `CLAUDE.md` is also missing, **copy** it — never symlink, matching `setup.sh` (WSL/NTFS and Windows git both struggle with symlinks). Keep the two in sync.
3. If no `TASKS.md`, copy `templates/TASKS.md.template` to repo root.
4. If no `GOTCHAS.md` at repo root, create one from `examples/GOTCHAS.md.example`.
5. **Update `.gitignore`.** The toolkit's working files are *local* working
   files — they churn every run, they are personal to whoever is driving, and
   they are a merge-conflict magnet in any repo with more than one contributor.
   Write **only what Step 3's `.gitignore` answer chose** — the user decides what stays
   out of git; don't append a fixed list over their answer. Create `.gitignore` if
   missing; append under a `# brainstorm-toolkit` comment; don't duplicate lines that
   already exist. The machine-state lines are always written (pure run state, never
   useful in history); the rest only if selected, then any extra paths the user named:
   ```gitignore
   # brainstorm-toolkit — local working state, not shared contract
   .claude/pipeline/
   .claude/.next-action
   .claude/.auto-continue-hops
   .claude/.stop-gate-hops
   ACTION_ITEMS.md
   .claude/project.json   # if selected
   TASKS.md               # if selected
   plans/                 # if selected
   ```
   Write the entries without the `# if selected` annotations.

   **Keep tracked:** `.claude/project.json.example` (the bootstrap template),
   `.claude/settings.json` (hook wiring the team does share), `AGENTS.md`,
   `GOTCHAS.md`, and any committed agent/skill definitions.

   **Auto-compact window** (Step 3, Claude only): when the user chose a value, merge
   `"autoCompactWindow": <tokens>` into `.claude/settings.json` (create it if missing; keep every
   existing key, never overwrite the file). Omitted → leave the file untouched.

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
   - "See current work queue with `/sdlc-status`."

## What NOT to do

- **Do not overwrite an existing `project.json`** without explicit confirmation.
  If one already exists, read it, show the user what's there vs. what you'd
  propose, and ask.
- **Do not infer commands that haven't been verified.** If you see `pytest.ini`
  but no actual tests pass, still propose the pytest command but flag it.
- **Do not generate evals.** That's the pipeline's Stage 3. This skill
  only sets up the config needed for evals to work if the user chooses to use them.
- **Do not stop at a proposal.** Scanning, printing a config and not writing it is this
  skill's most likely failure, because the analysis *looks* like the deliverable. It
  isn't — on a from-scratch repo the written files are. With nobody to confirm, assume
  the defaults and write (Step 3). The one exception stays the first rule above: an
  **existing** `project.json` still needs explicit confirmation to overwrite.

## Detection heuristics reference

| Signal | Implies |
|---|---|
| `package.json` with `"test"` script | `test.unit` or `test.frontend` = `npm test` (or pnpm/yarn equivalent) |
| `pyproject.toml` with `[tool.pytest]` | `test.unit` = `pytest` |
| `playwright.config.*` at root | `test.e2e` = `npx playwright test` |
| `docker-compose.yml` | `logs.command` = `docker compose logs {service} --tail={tail}`, `logs.services` from compose services; `stack.up` = `docker compose up -d --build`, `stack.rebuild` = `docker compose up -d --build --force-recreate`; `stack.url` from the first published host port |
| Kubernetes manifests | `logs.command` = `kubectl logs deploy/{service} --tail={tail}`; leave `stack.*` unset — a cluster is not a local up/down |
| `package.json` with a `dev`/`start` script and no compose file | `stack.up` = that script (`npm run dev`); no `stack.rebuild` unless a build step is separate |
| `go.mod` | `test.unit` = `go test ./...` |
| `Cargo.toml` | `test.unit` = `cargo test` |
| Top-level dirs like `api/`, `web/`, `worker/` | `modules` list |
| `.git/HEAD` or `origin` default | `main_branch` |
