# Config contract: `.claude/project.json`

> **✓ Live contract — current and maintained.**

Every key is optional. Skills skip a step gracefully when its key is missing, so a repo with
no `project.json` at all still gets useful behavior from `/brainstorm`, `/task` and `/gotcha`.
Split out of `README.md` so the front page stays a tour rather than a reference.

Start from [`templates/project.json.example`](../templates/project.json.example), which
carries an inline comment for every key. `/repo-onboarding` writes this file for you.

This page mirrors `templates/project.json.example`; that file is the registry
`scripts/ci/check_contracts.py` validates against — update it first.

## Filling it out

A guide for getting from an empty repo to a correct file. The reference below it is the
complete key list; this part is the order to think in.

- [Fastest path: `/repo-onboarding`](#fastest-path-repo-onboarding)
- [A minimal file and a recommended file](#a-minimal-file-and-a-recommended-file)
- [Block by block: the question each answers](#block-by-block-the-question-each-answers)
- [A worked example](#a-worked-example)
- [Common mistakes](#common-mistakes)
- [Check your file](#check-your-file)

### Fastest path: `/repo-onboarding`

Let the skill write the file. It scans the repo (manifests, compose
services, CI workflows, test config, migrations) and walks **every** key in
`project.json.example`, putting each in one bucket: **detected** (with evidence), **not
applicable** (with why) or **unknown**. The unknowns are reported at the end, so a key nobody
thought to look for still gets noticed.

It then asks the choices detection cannot make, in one batch with the recommended answer
first:

| It asks | Key | Recommended |
|---|---|---|
| Which model implements the work | `models.implement` | `sonnet` |
| Review stage on, and which model reviews | `pipeline.review_fix.enabled` + `models.code_review` | on + `opus` |
| A ceiling for every fan-out | `models.cap` | omit (no ceiling) |
| Which model pre-flights the plan | `models.sanity` / `agents.sanity_focuses` | omit (built-in per-focus defaults) |
| How many review lenses (only if review is on) | `agents.code_review_lenses` | all four, or `["correctness", "security"]` to halve the cost |
| How to bring the app up for manual verification | `stack.up` / `stack.rebuild` / `stack.url` | what it detected |
| What git should ignore | `.gitignore` entries, not a config key | `project.json`, `TASKS.md`, `plans/` |
| Co-author trailer on suggested commits | `coauthor_trailer` | `false` |

Run headless (CI, `claude -p`) and it asks nothing: it takes those defaults, writes the file
anyway and names every assumed value in its report so each is one edit to correct.

### A minimal file and a recommended file

Every key is optional, so a file can be three lines. This is enough for `/test-check` and for
`/sdlc` to know where your tests live and what your trunk is called:

```json
{
  "main_branch": "main",
  "test": {
    "unit": "pytest tests/ -q"
  }
}
```

The recommended file adds the cost and quality levers worth deciding on day one: Sonnet
implements, Opus reviews, plus the gotchas file and the module list:

```json
{
  "main_branch": "main",
  "test": {
    "unit": "pytest tests/ -q"
  },
  "models": {
    "implement": "sonnet",
    "code_review": "opus"
  },
  "pipeline": {
    "review_fix": {
      "enabled": true
    }
  },
  "gotchas_file": "GOTCHAS.md",
  "modules": ["api", "web", "worker"]
}
```

### Block by block: the question each answers

| Block | The question it answers | Notes |
|---|---|---|
| `main_branch` | What is trunk called? | Continuity detection stays quiet on it. Detected from `origin/HEAD`. |
| `test.unit` | How do I run the backend tests? | Keep it **clean-checkout-safe**: no network, credentials or running services. It runs in the `test-runner` agent whenever a backend surface changed, and the opt-in stop gate re-runs it. Put anything that needs a database or an API key behind a different command. |
| `test.frontend` | How do I run the frontend tests? | Runs when a frontend surface changed. |
| `test.e2e` | How do I run the browser suite? | Without it, touching the frontend raises a soft-stop each run ("frontend changed but no visual check ran"), so set it or accept the prompt. `e2e_max_fix_loops`, `e2e_patterns_file` and `e2e_rerun_failed_only` tune `/test-check --loop` only. |
| `logs.*` | How do I read service logs? | `command` takes `{service}` and `{tail}`; `services` lists what to audit. |
| `stack.*` | How do I bring the app up to click through it? | `up`, `rebuild` (force-recreate, for when a dependency manifest changed) and `url`. Printed at hand-off, **never auto-run**. |
| `eval.*` | Is there an eval runner? | `runner` is what turns Stage 3 on; without it the stage is skipped. `features_dir` and `thresholds.min_pass_rate` tune the runner. |
| `models.*` | Which tier does each role use? | One key per role; unset means the built-in default (Sonnet-first, Haiku for the mechanical checks). `cap` is a ceiling that only lowers, and absent means no ceiling. `code_review` and `code_review_second_pass` are a separate axis the cap never touches. If `code_review` lands on the implementer's tier the run is marked `independence: degraded` and findings are surfaced, never auto-fixed. [Table below.](#models) |
| `agents.*` | How many agents does each fan-out dispatch? | Review lenses, sanity focuses, cleanup lenses, and the thresholds that make Stage 2 split into lanes (`decompose_min_tasks`, `decompose_min_files`). |
| `pipeline.review_fix` | Is the adversarial review on? | `enabled` (off by default, permanently) and `mode` (`interactive`, `auto`, `off`). |
| `pipeline.scope` | How is an oversized plan cut? | `max_steps_per_run` is the fallback cut for a plan with no phase headings. |
| `pipeline.loop` | How does `--queue` and the auto-continue loop behave? | `max_items`, `batch_size`, `max_hops`, `auto_continue` (off by default). |
| `pipeline.fix_loop` | Should the last fix attempt escalate a tier? | `escalate_last`, off by default. |
| `pipeline.cleanup` | Is the cleanup pass on? | `enabled` and `mode`, off by default. |
| `pipeline.output` | How chatty is the run? | `verbosity`: `quiet` (default) or `normal`. |
| `pipeline.stop_gate` | Should a red `test.unit` block the Stop event mid-run? | `"off"` (default) or `"tests"`; `stop_gate_timeout` is in seconds. Claude and Codex only. |
| `pipeline.enforce_cap` | Should `models.cap` be enforced by a hook? | Claude only. Rewrites an over-cap dispatch to the cap; the reviewer is exempt. |
| `pipeline.action_items` | Do you want the generated `ACTION_ITEMS.md` waves? | `enabled`, `file`, `reassess`. See the reference below. |
| `pipeline.tasks.close_in_place` | Should closed rows stay on their lines? | `true` flips a closed row to `[x]` where it stands, so `TASKS.md:N` citations stay valid. |
| `discipline` globs | Which paths count as frontend, backend, data, docs, deploy-delta? | Override only for a non-standard layout; see below. |
| `migrations` | Where are migrations, and how do I tell what is applied? | `/repo-health` only. `dir` and `applied_check`. |
| `gotchas_file` | Where do pitfalls live? | Default `GOTCHAS.md`. |
| `modules` | What are the top-level code areas? | Read by `/brainstorm`. |
| `coauthor_trailer` | Should a suggested commit message credit Claude? | `false` unless you opt in. |

#### Models

The roles you will most often touch: `implement` (the implementer, the decomposer and every
lane), `fix` (the Stage 5 fix-loop agent), `validate` (the plan-conformance check),
`test_runner` (Haiku by default), `code_review` and `code_review_second_pass` (the reviewer
axis), and `planner` (an advisory session-model nudge for `/brainstorm`, not a dispatch). The
full role table is in the reference below.

#### When to override the `discipline` globs

The defaults cover common layouts. Override a list only when yours does not match, and note
that an override **replaces** the default list, so carry over the patterns you still want.

- **Migrations outside a `migrations/` directory.** The default `data_globs` catches
  `**/migrations/**`; an alembic tree at `engine/alembic/versions/` is missed. Add
  `engine/alembic/versions/**`.
- **A frontend root not named `frontend/`.** The defaults key on file extension, but a
  TypeScript-only tree such as `portal/**/*.ts` is classed as backend (`**/*.ts` is a default
  backend glob). Put `portal/**/*.ts` in `frontend_globs` and narrow `backend_globs`.
- **Lockfiles and compose files.** `deploy_delta_globs` flags "rebuild required, not restart"
  when the diff touches one. Add `docker-compose.yml`, or a nested `engine/requirements.txt`.

### A worked example

A polyglot repo: a Python engine with alembic migrations, a Next.js portal, and Postgres in
compose.

```json
{
  "main_branch": "main",
  "python": "python3",
  "test": {
    "unit": "cd engine && pytest tests/unit -q",
    "frontend": "cd portal && pnpm test --run",
    "e2e": "cd portal && npx playwright test --reporter=json"
  },
  "logs": {
    "command": "docker compose logs {service} --tail={tail}",
    "services": ["engine", "portal", "db"]
  },
  "stack": {
    "up": "docker compose up -d --build",
    "rebuild": "docker compose up -d --build --force-recreate",
    "url": "http://localhost:3000"
  },
  "models": {
    "implement": "sonnet",
    "code_review": "opus"
  },
  "agents": {
    "code_review_lenses": ["correctness", "security"]
  },
  "migrations": {
    "dir": "engine/alembic/versions",
    "applied_check": "docker compose exec -T db psql -U app -tAc \"select version_num from alembic_version\""
  },
  "discipline": {
    "frontend_globs": ["portal/**/*.ts", "portal/**/*.tsx", "portal/**/*.css"],
    "backend_globs": ["engine/**/*.py"],
    "data_globs": ["engine/alembic/versions/**", "**/*.sql"],
    "deploy_delta_globs": ["engine/requirements.txt", "engine/Dockerfile", "portal/package.json", "portal/pnpm-lock.yaml", "docker-compose.yml"]
  },
  "pipeline": {
    "review_fix": {
      "enabled": true
    },
    "action_items": {
      "enabled": true
    },
    "tasks": {
      "close_in_place": true
    }
  },
  "gotchas_file": "GOTCHAS.md",
  "modules": ["engine", "portal"]
}
```

- `test.unit` points at `tests/unit`, the suite that needs no database. Integration tests that
  need the compose `db` service stay out of it.
- `portal/**/*.ts` is listed under `frontend_globs`, and `backend_globs` is narrowed to the
  engine, so a portal change is classed as frontend and `test.frontend` and `test.e2e` run
  for it.
- `data_globs` carries the alembic path because the default `**/migrations/**` would miss it.
- `deploy_delta_globs` lists the nested manifests and the compose file, so a dependency bump
  prints "rebuild required" in the report.
- `agents.code_review_lenses` trimmed to two lenses roughly halves the review stage's cost.
- `action_items.enabled` and `close_in_place` are opt-ins; leave them out for a repo that does
  not use waves.
- No `models.cap`: the defaults are already Sonnet-first, so there is nothing to lower.

### Common mistakes

- **Treating `models.cap` as "use this model".** It only lowers. To raise a role, set that
  role's own key (`models.implement`, `models.fix`, ...). Omit `cap` unless you want a ceiling.
- **Using a key from an older layout.** Model and lens settings that once lived in the
  sanity-check and review-fix blocks of `pipeline` moved to `models` and `agents`
  (the map is in [MODEL-AXES.md](MODEL-AXES.md)). An old key is not an error: it is silently
  ignored and you get the built-in default. The reviewer is `models.code_review`; the sanity
  focuses are `agents.sanity_focuses`; the sanity model is `models.sanity`. Only `enabled` and
  `mode` stay under `pipeline.review_fix`.
- **Expecting a flag to pick a model.** No flag does. Edit the key.
- **Keys nothing reads.** A key such as an integration-test command under `test` is not a toolkit key. It is fine as
  a note to humans and is never run. If you want it run, wire it into `test.unit`.
- **A `test.unit` that needs services or credentials.** It will fail on a clean checkout and
  in the stop gate. Point it at the suite that runs without them.
- **Forgetting `test.e2e` on a frontend repo.** Not an error, but each run that touches the
  frontend raises a soft-stop asking about the missing visual check.
- **Believing a hand-written `ACTION_ITEMS.md` switches the feature on.** It does not, and it
  is never overwritten. Only `pipeline.action_items.enabled: true` or a generated file (first
  line is the generated banner) opts in; `enabled: false` always vetoes.
- **Invalid JSON.** No trailing commas and no `//` or `/* */` comments. A key starting with
  `_` (such as `_comment`) is the supported way to leave a note, and is ignored.

### Check your file

Run this from the repo root. It loads `.claude/project.json`, fails loudly if the JSON does
not parse, and lists every key that is not in `.claude/project.json.example` (which `setup.sh`
installs), so a typo or a dead key shows up. Comment keys (starting with `_` or `//`) are skipped. From a
toolkit checkout use `bash scripts/py.sh` in place of `python`.

```bash
python -c "import json;f=lambda p:json.load(open(p));w=lambda u,e,p='':[x for k,v in u.items() if not k.startswith(('_','//')) for x in (w(v,e[k],p+k+'.') if k in e and isinstance(v,dict) and isinstance(e[k],dict) else [] if k in e else [p+k])];print('not in the example:',w(f('.claude/project.json'),f('.claude/project.json.example')) or 'none')"
```

`none` means every key is one the toolkit knows. A bare name is a typo or a key nothing reads.
The example leaves map-valued keys such as `models.sanity` as `null`, so the check does not
look inside them.

## Reference

`.claude/project.json`, all keys optional (`_comment` keys below are stripped for readability
— the real file's inline comments are more detailed than this page):

```json
{
  "test": {
    "unit": "pytest tests/ -v --tb=short",
    "frontend": "cd web && pnpm test --run",
    "e2e": "npx playwright test --reporter=json",
    "e2e_max_fix_loops": 3,
    "e2e_patterns_file": ".claude/e2e-patterns.md",
    "e2e_rerun_failed_only": true
  },
  "logs": {
    "command": "docker compose logs {service} --tail={tail}",
    "services": ["api", "web", "worker"]
  },
  "stack": {
    "up": "docker compose up -d --build",
    "rebuild": "docker compose up -d --build --force-recreate",
    "url": "http://localhost:3000"
  },
  "eval": {
    "runner": "bash scripts/py.sh scripts/eval-runner.py",
    "features_dir": "evals/",
    "thresholds": {
      "min_pass_rate": 0.85
    }
  },
  "python": "python3",
  "gotchas_file": "GOTCHAS.md",
  "main_branch": "main",
  "coauthor_trailer": false,
  "modules": ["api", "web", "worker"],
  "models": {
    "implement": "sonnet",
    "sanity": null,
    "planner": "opus",
    "code_review": "opus",
    "code_review_second_pass": "sonnet"
  },
  "agents": {
    "sanity_focuses": ["paths", "completeness", "gotchas"],
    "code_review_lenses": ["correctness", "plan-alignment", "config-env-docs", "security"],
    "code_review_max_lenses": 4,
    "code_review_passes": 1,
    "code_review_max_fix_loops": 3,
    "decompose_min_tasks": 6,
    "decompose_min_files": 12,
    "cleanup_lenses": ["over-engineering", "docstring-currency"],
    "cleanup_max_lenses": 2
  },
  "migrations": {
    "dir": "backend/migrations",
    "applied_check": "psql \"$DATABASE_URL\" -tAc \"select max(version) from schema_migrations\""
  },
  "discipline": {
    "staleness_hours": 24,
    "frontend_globs": ["**/*.tsx", "**/*.jsx", "**/*.vue", "**/*.svelte", "**/*.css", "**/*.scss"],
    "backend_globs": ["**/*.py", "**/*.go", "**/*.rb", "**/*.java", "**/*.ts"],
    "data_globs": ["**/migrations/**", "**/schema/**", "**/models/**", "**/*.sql"],
    "docs_globs": ["**/*.md", "docs/**"],
    "deploy_delta_globs": ["requirements.txt", "pyproject.toml", "poetry.lock", "package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "go.mod", "Cargo.toml", "Gemfile.lock", "Dockerfile", "**/Dockerfile"],
    "memory_index": null
  },
  "pipeline": {
    "skip_secret_scan": false,
    "poka_yoke": false,
    "enforce_cap": false,
    "stop_gate": "off",
    "stop_gate_timeout": 300,
    "scope": {
      "max_steps_per_run": 8
    },
    "output": {
      "verbosity": "quiet"
    },
    "context": {
      "cost_report": "on"
    },
    "fix_loop": {
      "escalate_last": false
    },
    "review_fix": {
      "enabled": false,
      "mode": "interactive"
    },
    "cleanup": {
      "enabled": false,
      "mode": "interactive"
    },
    "loop": {
      "max_items": 5,
      "batch_size": 5,
      "max_hops": 5,
      "auto_continue": false
    },
    "action_items": {
      "enabled": false,
      "file": "ACTION_ITEMS.md",
      "reassess": false
    },
    "tasks": {
      "close_in_place": false
    }
  }
}
```

`coauthor_trailer` decides whether a commit message this toolkit writes or suggests ends with
`Co-Authored-By: Claude <noreply@anthropic.com>`. It is **`false` unless you opt in:** attribution is a disclosure choice rather than a default, and some DCO / commit-lint setups
reject unrecognized trailers. `/repo-onboarding` asks the question outright rather than
guessing, and never infers consent from trailers already in `git log`. Only two surfaces read
it, because they are the only two that touch commit text: `/task`, on the runs where you asked
it to commit, and `/sdlc`'s Stage 6 hand-off, which *prints* a suggested commit and never runs
one.

**Every model and agent-count knob lives in `models` and `agents`.** Full contract:
`skills/sdlc/templates/models.md`.

There are **two independent axes**, and conflating them is the classic mistake:

| | Axis 1: the fan-out ladder | Axis 2: the adversarial reviewer |
|---|---|---|
| Keys | `models.<role>` (`sanity`, `implement`, `fix`, `validate`, `test_runner`, `e2e`, `cleanup`, `reassess`, `brainstorm`, `brainstorm_team`, `dead_code_review`, `repo_health`, `docstring_sync`), bounded by `models.cap` | `models.code_review`, `.code_review_second_pass` |
| Values | `haiku` \| `sonnet` \| `opus` | `haiku` \| `sonnet` \| `opus` \| `fable` |
| Capped? | yes, everything passes through the cap | **never** |

**No CLI flag selects a model.** Every tier is a `project.json` key. Each dispatch role has its
own key (`models.implement`, `models.fix`, `models.validate`, ... — table below); a repo that
sets none runs every role at its built-in default, which is Sonnet-first (Haiku for the
mechanical checks). The only way to raise a role is its own key.

`models.cap` is a **ceiling**, not a setting: `effective = min(models.<role> ?? default,
models.cap ?? no ceiling)`. **Absent means no ceiling.** `"sonnet"` lowers every Opus
dispatch while leaving Haiku agents alone: you cut Opus spend without upgrading the cheap
ones. Because the cap only *lowers*, it can never raise a role; set that role's key instead.

**Recommended pairing: Sonnet implements, Opus reviews.** Set `models.implement: "sonnet"`
(the default) and turn the review stage on with `pipeline.review_fix.enabled: true` plus
`models.code_review: "opus"`. The implementer spends most of the tokens; a stronger,
different reviewer catches what it missed and keeps the review independent.

| Key | Controls | Default |
|---|---|---|
| `sanity` | `/sdlc` Stage 1.5 and `/brainstorm` vet-light focuses (string or map) | `paths` haiku, `completeness` / `gotchas` sonnet |
| `implement` | `/sdlc` implementer, decomposer, every 2b lane, Stage 5.9 cleanup-apply | `sonnet` |
| `fix` | `/sdlc` Stage 5 fix-loop agent | `sonnet` |
| `validate` | `/sdlc` Stage 5 plan-conformance-validator | `sonnet` |
| `test_runner` | `test-runner` dispatches (`/sdlc`, `/test-check`) | `haiku` |
| `e2e` | `e2e-test-runner` dispatches (`/sdlc`, `/test-check --loop`) | `sonnet` |
| `cleanup` | `/sdlc` Stage 5.9 cleanup lenses | `sonnet` |
| `reassess` | `/sdlc` Stage 6 reassess agent | `sonnet` |
| `brainstorm` | `/brainstorm` explorers, vet-deep, vet-ultra | `sonnet` |
| `brainstorm_team` | `/brainstorm-team` teammates | `sonnet` |
| `dead_code_review` | `/dead-code-review` lenses (string or map `server`/`client`/`data`/`docs`/`scripts`) | `server`/`client`/`data` sonnet, `docs`/`scripts` haiku |
| `repo_health` | `/repo-health` checks (string or per-check map) | each check's built-in tier |
| `docstring_sync` | `/docstring-sync` triage + rewrite | `sonnet` |
| `code_review`, `code_review_second_pass` | Axis 2: Stage 5.7 reviewers (never capped) | `opus`, `sonnet` |
| `planner` | advisory session-model nudge | `opus` |

`models.sanity` resolves **per focus**, not as one tier for the whole stage. Built-in
defaults: `paths: haiku` (mechanical — does the file/symbol exist?), `completeness: sonnet`
and `gotchas: sonnet` (both judgment calls — a cheap tier tends to misread "not yet
implemented" as a plan gap). So only `paths` defaults to Haiku; the other two focuses
already default to Sonnet. `models.sanity` accepts either a **string** (`haiku|sonnet|opus`,
replaces every focus — the original shape, unchanged) or a **map** (`{"completeness":
"opus"}`), where a focus missing from the map keeps its own built-in default. Either shape's
resolved value then still passes through `models.cap` as usual. An invalid value (unknown
tier, or a map entry that isn't one) falls through to that focus's own built-in default.
Every map-or-string key follows the same rule. Full contract: `skills/sdlc/templates/models.md`.

**A third kind, `models.planner` — advisory, on neither axis.** Default `"opus"`
(`haiku|sonnet|opus|fable`). It is not a dispatch tier: it never governs a sub-agent, and
`models.cap` never lowers it. It is a session-model *recommendation* for `/brainstorm` and
`/brainstorm-team`'s planning conversation, which runs on your host session model, not a
sub-agent. Both skills print it once per session: "Planning runs on your session model.
Recommended: `<planner>` — switch before the clarifying rounds if you aren't on it." An
unrecognized value falls through to the default.

`agents.*` sets **how many** agents each fan-out stage dispatches. Cost scales roughly
linearly: one agent (or reviewer call) per entry, so trimming
`agents.code_review_lenses` to `["correctness", "security"]` roughly halves the review
stage. All of it governs sub-agents only, never the session orchestrator.

`pipeline.scope.max_steps_per_run` bounds Stage 0's scope gate for a plan-file `/sdlc` run
(default `8`) — the fallback step-count cut used only when the plan has no `#### Phase N`
headers to cut on instead. Task id / range / ad-hoc / `--queue` inputs never pass through this
gate; `--no-scope-gate` forces whole-plan execution for a single run without touching the config.

`pipeline.fix_loop.escalate_last` (default `false`) opts the **final** iteration of Stage 5's
shared 3-iteration fix budget into `min(stage_tier + 1, effective_cap)` on the
`haiku < sonnet < opus` ladder, printing `model: <tier> (cap: <cap>, escalated)`. Under
`models.cap: "sonnet"` this is a no-op; with no cap (or `"opus"`) iterations 1–2 run
`models.fix` (default Sonnet) and the last runs Opus. Excluded entirely
from Stage 5.7/5.8, which has its own separate budget and whose reviewer axis
(`models.code_review`) is not on this ladder. Without the key, every retry stays on the same
tier by design.

`pipeline.loop.*` tunes the backlog loop and is **entirely optional** (defaults
shown above). `max_items` caps how many TASKS.md rows one `/sdlc --queue`
invocation consumes; `batch_size` is read only by `scripts/loop-runner.sh` and
sets how many completed items a single headless process handles before context
is reset at a clean boundary; `max_hops` bounds the auto-continue chain.
`auto_continue` is **off by default** and Claude/Codex only. When true, the Stop
hook executes a single non-`confirm` `.next-action` entry instead of just
printing it, so the loop self-advances. It never chains a `confirm: true` action
(i.e. never a commit or any other git write). See `docs/LOOP-HYGIENE.md`.

`pipeline.action_items` (`enabled`, `file`, `reassess`) controls the generated `ACTION_ITEMS.md` — which open `TASKS.md` rows
can run now, which become ready next, grouped by lane (`bash scripts/close-tasks.sh waves`; JSON
shape in `docs/BOARD-JSON.md`). Resolution (`bash scripts/close-tasks.sh waves --file TASKS.md --gate` prints
`{enabled, file, reason}`): **`enabled: false` is a veto** — off whatever files exist; `enabled: true`
is on; when `enabled` is absent it is on only if the file named by `file` (default `ACTION_ITEMS.md`)
already exists and its first line is the generated banner (`<!-- generated — edit TASKS.md`). Read both
keys first; never test the default name when `file` is set. A hand-written file of that name never opts a repo in, and
even with `enabled: true` it is never overwritten (`waves --write` reports `write_skipped`). Both
the path and that check resolve against the `TASKS.md` directory, not the cwd. When
on, `/sdlc` Stage 6 regenerates the file right after it closes its rows, `/sdlc --queue` selects
from the now wave (an empty now wave parks), and `/sdlc-status` prints one line from it. The file
is derived, so `setup.sh` always gitignores it. `reassess` (default `false`) adds an opt-in step
to Stage 6: when the open-row set changed since the last run, one Sonnet agent proposes
`_after:` / `_lane:` / `_conflicts:` tags, and code applies only those whose evidence quote is
found verbatim in the plan, through `close-tasks.sh tag`. Model tier follows
`skills/sdlc/templates/models.md` (Axis 1, Sonnet by default).

`pipeline.tasks.close_in_place` (default `false`) makes `/sdlc` Stage 6 close rows with
`close-tasks.sh close --in-place`: a closed row flips to `[x]` (with its completion stamp) where it
stands instead of moving to `## Done`, so `TASKS.md:N` line citations stay valid. `moved[]` is empty in
that mode.

### Which skill reads which key

| Skill | Reads |
|---|---|
| `/test-check` | `test.*`, `logs.*` |
| `/sdlc` | `gotchas_file`, `eval.*`, `main_branch`, delegates to `/test-check` |
| `/gotcha` | `gotchas_file` |
| `/brainstorm` | `modules`, `models.brainstorm`, `models.sanity` (vet-light), `models.cap`, `models.planner` (session-model nudge) |
| `/brainstorm-team` | `models.brainstorm_team`, `models.planner` (session-model nudge) |
| `/sdlc` | `models.implement`, `.fix`, `.validate`, `.test_runner`, `.e2e`, `.cleanup`, `.reassess` (one key per dispatch role) |
| `/dead-code-review` | `models.dead_code_review` |
| `/repo-health` | `models.repo_health` |
| `/docstring-sync` | `models.docstring_sync` |
| `/test-check` | `models.test_runner`, `models.e2e` (`--loop`) |
| `/sdlc`, `/brainstorm`, `/brainstorm-team`, `/dead-code-review`, `/repo-health`, `/docstring-sync` | `models.cap` (sub-agent tier ceiling; absent = none) |
| `/sdlc` | `models.sanity` + `agents.sanity_focuses` (Stage 1.5 pre-flight, per focus; never gated, so it runs every time) |
| `/sdlc` Stage 5 fix loop | `pipeline.fix_loop.escalate_last` (final-iteration escalation; excluded from Stage 5.7/5.8) |
| `/sdlc` Stage 6 | `pipeline.tasks.close_in_place` |
| `/sdlc` Stage 6, `--queue` | `pipeline.action_items.enabled`, `.file`, `.reassess` (regenerate `ACTION_ITEMS.md`; queue selects from the now wave; `reassess` opt-in) |
| `/sdlc` | `models.code_review`, `models.code_review_second_pass`, `agents.code_review_*` (axis 2; never capped) |
| `/sdlc` | `pipeline.review_fix.*`: stage *behavior* only (`enabled`, `mode`). Opt-in, permanently off by default. (`blocking` was removed 2026-09: `/sdlc` does no git writes, so a HIGH finding is reported first in Stage 7, never gated) |
| `/sdlc` | `agents.decompose_min_tasks` / `agents.decompose_min_files` (Stage 2 decompose gate) |
| `/sdlc` Stage 0 | `pipeline.scope.max_steps_per_run` (scope gate; `--no-scope-gate` bypasses per-run) |
| `/sdlc --queue`, `scripts/loop-runner.sh`, `scripts/hooks/next-action.sh` | `pipeline.loop.*` (`max_items`, `batch_size`, `max_hops`, `auto_continue`) |
| `/sdlc` Stage 6 | `stack.up` / `stack.rebuild` / `stack.url`: printed as the manual-verification line at hand-off, never auto-run |
| `/sdlc` Stage 6 | `coauthor_trailer`: whether the *suggested* commit message carries the trailer (`/sdlc` prints it; it never commits) |
| `/task` | `coauthor_trailer` (only when you ask it to commit); otherwise reads TASKS.md directly |
| `/sdlc-status` | `pipeline.action_items.enabled`, `.file` (the waves line); otherwise reads TASKS.md and `.claude/pipeline/` directly |
| `scripts/py.sh` (every shipped Python invocation) | `python` |
| `scripts/hooks/enforce-model-cap.sh` (Claude `PreToolUse(Agent)`) | `pipeline.enforce_cap`, `models.cap` |
| `scripts/hooks/stop-gate.sh` (Claude/Codex `Stop`) | `pipeline.stop_gate`, `pipeline.stop_gate_timeout`, `test.unit`, `pipeline.loop.max_hops` |
| `scripts/hooks/run-cost-report.sh` (Claude/Codex `Stop`) | `pipeline.context.cost_report` |
| `/sdlc` Stage 5.9 | `pipeline.cleanup.*`, `agents.cleanup_lenses`, `agents.cleanup_max_lenses` |
| `/sdlc` Stage 5.7 | `agents.code_review_max_lenses` |
| `/sdlc` changed-files gate | `discipline.*` (`staleness_hours`, `*_globs`, `deploy_delta_globs`) |
| `/repo-health` | `migrations.dir`, `migrations.applied_check`, `discipline.memory_index` |
| `/sdlc` all stages | `pipeline.output.verbosity` |
| `/test-check --loop`, `e2e-test-runner` | `test.e2e_max_fix_loops`, `test.e2e_patterns_file`, `test.e2e_rerun_failed_only` |
| `scripts/eval-runner.py` | `eval.thresholds.min_pass_rate` |
| `/repo-onboarding` | writes all of the above |
