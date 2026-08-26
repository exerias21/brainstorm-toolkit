# brainstorm-toolkit

Cross-tool plugin for **Claude Code, GitHub Copilot and Codex**: focused, low-token skills for brainstorming, SDLC, eval-driven development, and repo onboarding. Single AGENTS.md and TASKS.md contract so both agents work from the same source of truth.

## Why this exists

Most AI-agent task systems bolt on heavyweight task databases, multi-agent orchestrators, and inline templates that balloon every command to hundreds of lines. brainstorm-toolkit goes the other direction:

- **One skill = one SKILL.md file**, deliberately short. The pipeline's shared stage bodies live once in `skills/sdlc/templates/`, and a stage that self-skips never opens the template it is skipping — a flag nobody passed costs nothing.
- **Markdown-native contracts** — `AGENTS.md`, `TASKS.md`, `GOTCHAS.md`, `.claude/project.json` — so Claude Code, GitHub Copilot, Cursor, and friends all read the same files.
- **No central registry**, no dual persistence, no ralph-loop autonomous runners by default. `/sdlc` is the heaviest thing in here and it's still one file plus the templates for the stages a given run actually reaches. (Unattended looping exists but is strictly opt-in: `scripts/loop-runner.sh` only runs when you invoke it, and self-advancing requires setting `pipeline.loop.auto_continue: true`, which is off out of the box and never chains a `confirm` action.)

## Install

### Option A — Claude Code plugin

If you use the Claude Code plugin system, add this repo as a marketplace source or install directly:

```bash
# In Claude Code:
/plugin marketplace add <this-repo-url>
/plugin install brainstorm-toolkit
```

### Option B — `setup.sh` (Claude, Copilot, or both)

For Copilot users, or if you prefer file-based installs:

```bash
# Clone this repo once, anywhere
git clone <this-repo-url> ~/brainstorm-toolkit

# Inside any target repo:
bash ~/brainstorm-toolkit/setup.sh --target . --tools both
```

`setup.sh` copies:

- `skills/*` → `<target>/.claude/skills/<name>/` (Claude), `<target>/.github/skills/<name>/` (Copilot), and `<target>/.agents/skills/<name>/` (Codex), for skills whose `metadata.brainstorm-toolkit-applies-to` includes that tool. When a Copilot-optimized override exists in `copilot/skills/<name>/`, that version is installed for Copilot instead of the canonical one; Codex prefers a `codex/skills/<name>/` override, then the Copilot overlay, then the canonical. The full skill directory is copied so bundled scripts, assets, and references stay available.
- Some Copilot-distributed skills are intentionally **manual-only** and set `disable-model-invocation: true`, which keeps them available as slash commands without making them auto-load on semantic matching.
- Legacy `.github/prompts/*.prompt.md` files from older installs are removed during Copilot installs so the workspace stops advertising prompt-file shims.
- `agents/*` → `<target>/.claude/agents/` (Claude-only helper agents; VS Code can also discover Claude-format agents from `.claude/agents/` when needed).
- `scripts/*` → `<target>/scripts/`.
- `.gitignore` gains the toolkit's **local working state**: `.claude/pipeline/`,
  `.claude/.next-action`, `.claude/.auto-continue-hops`, `.claude/project.json`, `TASKS.md`,
  and `plans/`. These churn every run and are personal to whoever is driving. Idempotent —
  re-running never duplicates a line. `.claude/project.json.example` stays **tracked** as the
  bootstrap template (the pattern matches the exact filename, not the `.example` sibling), as
  do `.claude/settings.json`, `AGENTS.md` and `GOTCHAS.md`. Ignoring these does not break the
  cross-tool contract: Copilot and Codex read them off disk, and `.gitignore` governs sharing,
  not reading.
- `templates/AGENTS.md.template` → `<target>/AGENTS.md` if missing. `CLAUDE.md` is written as a **copy** of `AGENTS.md` (setup.sh never symlinks — WSL/NTFS and Windows git handle symlinks poorly); keep the two in sync.
- `templates/TASKS.md.template` → `<target>/TASKS.md` if missing.
- `templates/CHEATSHEET.md.template` → `<target>/CHEATSHEET.md` if missing. This is the printable companion to `README.md`; once present, setup leaves user edits alone.
- `templates/project.json.example` → `<target>/.claude/project.json.example` (left for you to rename and edit).

It also wires two hooks (skip with `--no-hooks`; the Claude-plugin install in Option A gets them automatically):

- a **Stop** hook running `scripts/hooks/next-action.sh` — surfaces the `.next-action` seam as `Next: <command>` (Claude `.claude/settings.json`, Copilot `.github/hooks/`, Codex `.codex/hooks.json`);
- a **reseed** hook running `scripts/hooks/reseed-context.sh` — Claude `SessionStart` (matcher `compact|clear`) and Codex `PostCompact`. It re-points the session at the loop's on-disk state after a compaction, so long `--queue` runs survive auto-compaction. Merged into existing hook config with `jq` and deduped by command string, so re-running is idempotent; without `jq` installed setup skips it and prints the entry to add by hand.

Re-running `setup.sh` is safe — it skips existing files unless you pass `--force`. Install only for one tool with `--tools claude` or `--tools copilot`.

### Option C — `sync-global.sh` (user-scope, no plugin, no marketplace)

Options A and B install **per repo**. Option C installs **once, globally**, for machines where
the plugin route isn't available — an org policy that sets `disableSideloadFlags` (blocking
`--plugin-dir`), a locked-down marketplace, or simply not wanting a plugin registration:

```bash
git clone <this-repo-url> ~/brainstorm-toolkit

bash ~/brainstorm-toolkit/scripts/sync-global.sh --dry-run   # preview, writes nothing
bash ~/brainstorm-toolkit/scripts/sync-global.sh             # apply
```

It copies `skills/*` → `~/.claude/skills/<name>/` and `agents/*` → `~/.claude/agents/`, then
`jq`-merges the Stop and `SessionStart` hooks into `~/.claude/settings.json` with **absolute**
paths. Claude Code discovers all of it natively — no plugin, no sideload flag.

| Flag | Effect |
|---|---|
| `--dry-run` | Print every action plus a unified `settings.json` diff; write nothing |
| `--skills a,b,c` | Sync a subset instead of all 13 (see *token weight* below) |
| `--prune-relative-hooks` | Also drop pre-existing `next-action.sh` Stop hooks wired by a **relative** path |
| `--no-hooks` | Skip the `settings.json` wiring entirely |
| `--uninstall` | Remove exactly what this script installed |
| `--repo <dir>` | Toolkit root (default: the script's own parent) |

Four things worth knowing:

- **It copies, it never symlinks.** Symlinked skills and agents have known discovery bugs
  (missing from `/skills` autocomplete, "Unknown skill" at invoke, subagents not found), and a
  symlink would let a `git checkout` in the repo silently swap your live skills mid-session.
  **Re-run the script after every `git pull`** — that explicit step is the point.
- **Hook paths are hardcoded on purpose.** `${CLAUDE_PLUGIN_ROOT}` only expands inside the
  plugin runtime; in a global `settings.json` it stays a literal and the hook silently no-ops.
  The same applies to a *repo-relative* command like `bash scripts/hooks/next-action.sh` — fine
  in a project-scoped `.claude/settings.json` (which is what `setup.sh` writes), but as a
  **global** hook it fires in every repo and fails in each one lacking that file.
  `--prune-relative-hooks` cleans that up.
- **`--delete` is scoped per skill directory**, never to `~/.claude/skills/` as a whole, so
  unrelated user skills installed by other tools are never pruned.
- **Token weight.** A global sync makes all 13 skills resident in *every* repo, and several
  (`/sdlc`, `/status`) assume the `AGENTS.md` / `.claude/project.json` contract.
  Use `--skills` to install just the ones that travel well — `/brainstorm`, `/brainstorm-team`,
  `/gotcha` — and keep the pipeline skills per repo via
  `setup.sh`.

Don't run Option C **and** Option A together: double registration means each skill is discovered
twice and the Stop hook fires twice, and `next-action.sh` consumes the sentinel on first read, so
the second pass sees an empty seam. The script warns if it detects the plugin still enabled.

### Windows note

`setup.sh` is bash; run it under **WSL, Linux, or macOS**. It writes `CLAUDE.md` as a plain copy of `AGENTS.md` (never a symlink — Windows-native git and WSL/NTFS handle symlinks inconsistently); keep the two files in sync.

## The cross-tool contract

Every consumer repo gets four shared files:

| File | Purpose | Read by |
|---|---|---|
| `AGENTS.md` | Architecture + agent conventions | Claude Code (via `CLAUDE.md` copy), Copilot, Cursor, Codex |
| `TASKS.md` | Markdown checkbox task queue | All agents, humans, GitHub UI |
| `GOTCHAS.md` | Project-specific pitfalls | `/gotcha`, `/sdlc` sanity check |
| `.claude/project.json` | Runner config (tests, logs, eval) | `/test-check`, `/sdlc` |

Every `project.json` key is optional — skills skip steps gracefully when config is missing. A repo with no `project.json` still gets useful behavior from `/brainstorm`, `/task`, `/gotcha`, etc.

## Skills

| Skill | Applies to | Use for |
|---|---|---|
| `README.md` | Claude + Copilot + Codex | Print every installed skill + the typical chains. The always-current view; `CHEATSHEET.md` is the printable companion. |
| `/brainstorm` | Claude + Copilot + Codex † | Conversational feature ideation with lens-divergent wildcards (Plan mode on Claude, linear on Copilot) |
| `/brainstorm-team` | Claude + Copilot + Codex † | 6-agent team for competitive + product research incl. a lateral-thinking agent (sequential on Copilot) |
| `/task` | Claude + Copilot + Codex | Create one bounded task and execute it with TDD on the current branch — no flags, always TDD |
| `/sdlc` | Claude + Copilot + Codex † | The full pipeline — sanity → implement → evals → fix → validate → plan-validate → flowsim, then **hands you the validated changes to commit yourself** (no commit, branch, push, or PR — only `/sdlc` touches git). Stage 2 auto-decomposes large multi-surface plans into focused per-lane subagents + a converge step; small / single-surface plans run a single agent unchanged. Takes a plan file, a task id, a task range (`1-5`), or an ad-hoc description. Use to run full discipline on work you want to review and commit onto an open PR's branch. Same optional Review→Fix stage as `/sdlc`, warn-only on surviving findings (consistent with its warn-only secret scan) rather than blocking handoff. Supports `--resume` (same envelope-resume as `/sdlc`; resume keys on the resolved slug) and `--queue [N]` (attended backlog loop: selects pending TASKS.md rows by priority, re-scans between items so mid-run additions join, parks on any paused/confirm item — no git writes). |
| `/status` | Claude + Copilot + Codex | Readout **and** recommendation in one command. Prints TASKS.md counts + the active task, surfaces any non-terminal pipeline run, then walks a 7-rung ladder to ONE recommended next command with a one-line rationale — joining run-state, the `.next-action` sentinel, TASKS.md, plans and git. For a paused run it names the failure class (flaky · code-defect · plan-wrong · config-missing) and the command that fixes it. Absorbed the former `/next` and `/triage`. Read-only — it recommends, never executes. |
| `/repo-onboarding` | Claude + Copilot + Codex | Generate AGENTS.md + TASKS.md + project.json + GOTCHAS.md |
| `/code-tour` | Claude + Copilot + Codex | Turn a codebase into teaching material — audit docstring coverage (bundled AST script), write why-focused docstrings that carry the reasoning and the rejected alternative, then generate a guided reading path (`TOUR.md`) with a cross-cutting pattern index, graded exercises, and an honest "what not to copy" section. Grounded in researched, source-cited standards (PEP 257, Google/NumPy styles, Diátaxis, ADRs) that separate genuine consensus from contested opinion. For onboarding, handover, or preparing a repo as a training module. Complements `/repo-onboarding` (which documents the repo at architecture level; this documents the code beneath it). |
| `/repo-health` | Claude + Copilot + Codex | Read-only hygiene sweep (dead code + tests + deps + secrets + gotchas-currency); prints a scored report and the highest-impact next command. |
| `/test-check` | Claude + Copilot + Codex | Run configured tests + log audit after changes (one-shot, no fix loop) |
| `/test-check --loop` | Claude + Copilot + Codex † | Run e2e/browser tests in a fix loop with flaky-test guard (dispatches `e2e-test-runner` agent on Claude, inline on Copilot). Reach for this instead of hand-composing a Playwright agent fan-out — it fixes what it finds. |
| `/gotcha` | Claude + Copilot + Codex | View/append project pitfalls — auto-drafted at loop-exit by `/task`, `/sdlc` on real traps (objective trigger), and injected at `/brainstorm` start |
| `/flowsim` | Claude + Copilot + Codex | Trace claimed plan flows through source code and flag mismatches |
| `/dead-code-review` | Claude + Copilot + Codex † | Parallel dead-code / dead-doc / stale-plan scan with before-and-after test verification (sequential on Copilot). This is the built-in answer to "launch a few agents and clean up everything no longer needed". |
| `/plan-html` | Claude + Copilot + Codex | Render any markdown plan as a self-contained, shareable HTML page (embedded CSS, zero JS, native `<details>` collapsibles, light/dark mode). Opt-in: pass the plan file as the argument — no auto-emit. Use to share plans with stakeholders or scroll-engage long plans in a browser. |

All skills run on all three tools. † marks skills with a Copilot-optimized overlay at `copilot/skills/<name>/` that runs the same stages sequentially (no parallel sub-agents or Plan mode) because Copilot's VS Code agent mode doesn't yet support those primitives; when it does, overlays will be upgraded. Codex shares those constraints, so `setup.sh` installs the Copilot overlay for Codex too (a Codex-specific override at `codex/skills/<name>/` wins when one exists — today `/sdlc`). Skills without a † rely only on file I/O + test runners and run identically on all three tools.

## Model & cost reference

What each skill dispatches under the hood, and a rough order-of-magnitude
cost. Token counts are **per typical run**, not worst-case — a `/sdlc` run
on a tiny plan is closer to the low end, on a multi-module refactor the
high end. Costs use 2026-04 list pricing: Opus $15 / $75, Sonnet $3 / $15,
Haiku $1 / $5 per M tokens (input / output).

**These numbers assume the current skill set.** The pipeline's instruction load is ~16k tokens
per run after the 2026-08 consolidation (two pipeline skills merged into one, shared stage
bodies split into templates, opt-in stages gated so they load nothing when off) — down from
~26k. The fan-out below is unchanged; what shrank is what the orchestrator reads before it
starts.

| Skill | Orchestrator | Sub-agents (per run) | Tokens/run (rough) | Cost/run (rough) |
|---|---|---|---|---|
| `/status` | host model | none — reads `TASKS.md` | <1k | ~$0.00 |
| `/gotcha` | host model | none — read/append `GOTCHAS.md` | <1k | ~$0.00 |
| `/test-check` | host model | none — runs tests + log audit | 1k–3k | ~$0.01 |
| `/plan-html` | host model | none — markdown read → HTML write | 3k–10k | ~$0.01–$0.05 |
| `/task` | host model | none — inline TDD | 5k–15k | $0.02–$0.10 |
| `/repo-health` | host model | 2 × Haiku (dead-code + gotchas-currency); 3 procedural checks | 5k–20k | $0.02–$0.10 |
| `/flowsim` | host model | none — plan-vs-code grep | 10k–40k | $0.05–$0.40 |
| `/test-check --loop` | host model | 1 × Sonnet per fix iteration | 10k–30k / iter | $0.05–$0.30 / iter |
| `/repo-onboarding` | host model (Opus recommended) | 0–1 × Sonnet (pattern detection) | 20k–60k | $0.30–$1.00 |
| `/brainstorm-team` | host (Opus) | 6 × Sonnet teammates (4 parallel, 2 sequential) | 60k–150k | $0.60–$2.00 |
| `/brainstorm` | host (Opus) | 4 × Sonnet wildcard lenses (parallel); `--vet` adds a review pass | 20k–60k | $0.10–$0.60 |
| `/code-tour` | host model | none — AST script + docstring authoring | 20k–60k | $0.10–$0.60 |
| `/dead-code-review` | host (Opus) | up to 5 lenses (2 × Haiku, 2 × Sonnet, 1 × Opus-tier), only those the repo has | 60k–180k | $0.60–$2.20 |
| `/sdlc` | host (Opus) | 3 × Haiku (sanity) + 1 × Sonnet (implement) + 1 × Haiku (test-runner) + 1 × Sonnet (plan check); review stage opt-in | 90k–280k | $2.50–$9.00 |

**Notes / caveats**:

- The "host model" / "orchestrator" is whichever model is running the
  Claude Code or Copilot session — the toolkit doesn't pin it. Costs
  above assume Opus for Plan-mode-bearing and fan-out-heavy skills
  (`/brainstorm`, `/sdlc`, `/dead-code-review`)
  and whatever the user has selected otherwise.
- **Orchestrator context dominates real cost.** An Opus orchestrator
  carrying a 100k-token codebase context across 5 sub-agent dispatches
  pays the input cost 5× — agent dispatch fees themselves are usually
  10–20% of the bill. Keeping orchestrator context tight is the highest-
  leverage cost lever.
- Sonnet is the right default for parallel sub-agents that do bounded
  code-search / pattern-match / judgement work. Opus is reserved for
  cross-module reasoning where one wrong call costs more than the whole
  fan-out. Haiku is right when the task is "find the regex match" not
  "judge what to do about it."
- These numbers are calibration, not budgeting. Real runs vary 3–5× with
  repo size, plan complexity, and how much context the orchestrator has
  already accumulated when the skill fires.

## Case studies

**Why the Review→Fix stage exists.** A `/sdlc` run reported everything green — 969→981
tests passing, flowsim 7/7 match, plan-validate 8/8, clean container logs. Three independent
adversarial review passes (a different model from the implementer, run manually) then found 6
real bugs the green suite never caught — a double-decoded URL, an hourly in-memory state reset
hammering an external API, a mis-classified recurrence rule, a stale frontend query-key
invalidation, an over-broad geo deny-list, and a missing env-var default — plus a 7th surfaced
by a live-data check. Total cost: ~240k tokens across 3 passes, each 1–6 minutes. See
`docs/REVIEW-FIX-STAGE.md` for the full write-up and the Review→Fix stage design.

## Flows

- **[docs/FLOW.md](docs/FLOW.md)** — one visual reference for the whole toolkit across Claude Code, Copilot, and Codex: install, the end-to-end flow diagram, the entry-skill picker, per-runtime differences, and model tiers.
- **[docs/AUTONOMOUS-DISCOVERY.md](docs/AUTONOMOUS-DISCOVERY.md)** — optional pattern for running discovery skills unattended on a schedule: a watcher daemon driving the headless `claude` CLI against a job queue. Reference only, not shipped by `setup.sh`.
- **[docs/LOOP-HYGIENE.md](docs/LOOP-HYGIENE.md)** — how to keep a many-hour `/sdlc --queue` or auto-continue run context-cheap. The loop can't self-compact; the lever is **batch handoff** — a fresh process every `pipeline.loop.batch_size` completed items, plus a reseed hook that re-points at the on-disk envelope after a compact/clear.
- **[docs/SEAM.md](docs/SEAM.md)** — the `.claude/.next-action` contract: multi-slot, one JSON entry per line, append-and-dedup, `confirm: true` for anything that writes git history.

## Typical workflow

```mermaid
flowchart LR
    A[/repo-onboarding/]:::setup --> B[AGENTS.md + TASKS.md<br/>project.json + GOTCHAS.md]
    B --> C[/brainstorm/]
    B --> D[/task/]
    C --> F[plans/brainstorm-*.md]
    D --> H[inline TDD]
    F --> I[/sdlc {plan}/]:::core
    H --> J[you commit]
    I --> J
    J --> K[PR + merge]

    subgraph "Anytime, in parallel"
      N[/repo-health/<br/>scored sweep]
      O[/flowsim {plan}/<br/>plan-vs-code drift]
      P[/dead-code-review/<br/>deeper hygiene]
      Q[/gotcha/<br/>capture pitfall]
    end

    classDef setup fill:#e8e8ff,stroke:#5555aa
    classDef core fill:#e0ffe0,stroke:#338833
    classDef pipe fill:#fff0e0,stroke:#cc7733
```

Or in plain text:

```
   /repo-onboarding                (once per repo)
          │
          ▼
   AGENTS.md + TASKS.md + project.json + GOTCHAS.md + CHEATSHEET.md
          │
          ├──► /brainstorm   ──► plan file
          │                          │
          │                          ▼
          ├──► /task         ──► TDD inline ──┬──► you commit ──► PR
          │                                    │
          └──► /sdlc <plan>  ──► full ────────┘
                    sanity → implement → evals → fix → validate → flowsim
                    (no git writes — it hands you a validated tree)

   Anytime:
     /repo-health    — scored hygiene sweep
     /status         — what's active, what's left?
     /flowsim        — verify a plan's claimed flows match the code
     /gotcha         — capture a pitfall
```

## Config contract

`.claude/project.json` — all keys optional:

```json
{
  "test": {
    "unit": "pytest tests/ -v --tb=short",
    "frontend": "cd web && pnpm test --run",
    "e2e": "npx playwright test"
  },
  "logs": {
    "command": "docker compose logs {service} --tail={tail}",
    "services": ["api", "web"]
  },
  "eval": {
    "runner": "python3 scripts/eval-runner.py",
    "features_dir": "evals/"
  },
  "gotchas_file": "GOTCHAS.md",
  "main_branch": "main",
  "modules": ["api", "web", "worker"],
  "models": {
    "cap": "sonnet",
    "sanity": null,
    "code_review": "opus",
    "code_review_second_pass": "sonnet"
  },
  "agents": {
    "sanity_focuses": ["paths", "completeness", "gotchas"],
    "code_review_lenses": ["correctness", "plan-alignment", "config-env-docs", "security"],
    "code_review_passes": 1,
    "code_review_max_fix_loops": 3,
    "decompose_min_tasks": 6
  },
  "pipeline": {
    "loop": {
      "max_items": 5,
      "batch_size": 5,
      "max_hops": 5,
      "auto_continue": false
    }
  }
}
```

**Every model and agent-count knob lives in `models` and `agents`.** Full contract:
`skills/sdlc/templates/models.md`.

There are **two independent axes**, and conflating them is the classic mistake:

| | Axis 1 — the fan-out ladder | Axis 2 — the adversarial reviewer |
|---|---|---|
| Keys | `models.cap`, `.sanity`, `.implement`¹ | `models.code_review`, `.code_review_second_pass` |
| Values | `haiku` \| `sonnet` \| `opus` | `haiku` \| `sonnet` \| `opus` \| `fable` |
| Capped? | yes — everything passes through the cap | **never** |


`models.cap` is a **ceiling**, not a setting: `effective = min(stage_tier, cap)`. So
`sonnet` lowers every Opus dispatch while leaving Haiku agents alone — you cut Opus spend
without upgrading the cheap ones. Per-run override `--model <tier>` (precedence: flag >
`models.cap` > default) wins both directions. **The fan-out is Sonnet-first by default:**
out of the box `/sdlc` and `/brainstorm --vet ultra` run their fan-outs on Sonnet; `--model opus` is the deliberate opt-up.

**The consequence worth knowing:** because the cap only *lowers*, a stage whose built-in
tier is `haiku` cannot be raised by `models.cap` or `--model` at all. The per-stage key is
the only lever — which is why `models.sanity` exists. Stage 1.5 is
never gated, so it runs on every single run.

`agents.*` sets **how many** agents each fan-out stage dispatches. Cost scales roughly
linearly — one agent (or reviewer call) per entry — so trimming
`agents.code_review_lenses` to `["correctness", "security"]` roughly halves the review
stage. All of it governs sub-agents only, never the session orchestrator.


`pipeline.loop.*` tunes the backlog loop and is **entirely optional** (defaults
shown above). `max_items` caps how many TASKS.md rows one `/sdlc --queue`
invocation consumes; `batch_size` is read only by `scripts/loop-runner.sh` and
sets how many completed items a single headless process handles before context
is reset at a clean boundary; `max_hops` bounds the auto-continue chain.
`auto_continue` is **off by default** and Claude/Codex only — when true, the Stop
hook executes a single non-`confirm` `.next-action` entry instead of just
printing it, so the loop self-advances. It never chains a `confirm: true` action
(i.e. never a commit or any other git write). See `docs/LOOP-HYGIENE.md`.

### Which skill reads which key

| Skill | Reads |
|---|---|
| `/test-check` | `test.*`, `logs.*` |
| `/sdlc` | `gotchas_file`, `eval.*`, `main_branch`, delegates to `/test-check` |
| `/gotcha` | `gotchas_file` |
| `/brainstorm` | `modules`, `models.cap` |
| `/sdlc`, `/brainstorm-team`, `/dead-code-review` | `models.cap` (sub-agent tier ceiling) |
| `/sdlc` | `models.sanity` + `agents.sanity_focuses` (Stage 1.5 pre-flight — never gated, so it runs every time) |
| `/sdlc` | `models.code_review`, `models.code_review_second_pass`, `agents.code_review_*` (axis 2 — never capped) |
| `/sdlc` | `pipeline.review_fix.*` — stage *behavior* only (`enabled`, `mode`, `blocking`). Opt-in, permanently off by default |
| `/sdlc` | `agents.decompose_min_tasks` (Stage 2 decompose gate) |
| `/sdlc --queue`, `scripts/loop-runner.sh`, `scripts/hooks/next-action.sh` | `pipeline.loop.*` (`max_items`, `batch_size`, `max_hops`, `auto_continue`) |
| `/sdlc` Stage 6 | `stack.up` / `stack.down` / `stack.rebuild` / `stack.url` — printed as the manual-verification line at hand-off, never auto-run |
| `/task`, `/status` | (none — read TASKS.md directly) |
| `/repo-onboarding` | writes all of the above |

## Supporting scripts

- **`scripts/eval-runner.py`** — runs pytest + fixture-based pipeline evals. Auto-discovers features from `evals/*/`. See `skills/test-check/SKILL.md` step 6.
- **`scripts/check_docker_logs.py`** — audits logs for errors/tracebacks. Accepts `--log-command` and `--services`. Works with Docker, kubectl, journalctl, or any log source.
- **`scripts/ci/check_install_refs.py`** — CI guard: installs the toolkit into a scratch repo and fails the build if any template citation in a shipped skill does not resolve there. Runs in the `setup-roundtrip` workflow.
- **`scripts/validate_skills.py`** — validates skill metadata, name-to-directory alignment, and Copilot-targeted skills against Claude-only capability leakage.
- **`scripts/loop-runner.sh`** — batch-handoff queue runner for long backlogs. Drives `/sdlc --queue` in a **fresh headless process every `pipeline.loop.batch_size` completed items**, so context resets at a clean item boundary instead of growing all run. Batch size resolves `--queue X` flag > `pipeline.loop.batch_size` > `pipeline.loop.max_items` > 5. See `docs/LOOP-HYGIENE.md`.
- **`scripts/hooks/next-action.sh`** — the Stop hook behind the `.next-action` seam. Reads the sentinel once, prints `Next: <command>`, deletes it. With `pipeline.loop.auto_continue: true` it instead **executes** a single non-`confirm` entry (`decision: block`), bounded by `pipeline.loop.max_hops`. See `docs/SEAM.md`.
- **`scripts/sync-global.sh`** — user-scope installer for machines without the plugin route (see *Install → Option C*). Copies `skills/*` and `agents/*` into `~/.claude/` and `jq`-merges the Stop + `SessionStart` hooks with absolute paths. `--dry-run` previews, `--uninstall` reverses. Copies rather than symlinks, so re-run it after each `git pull`.
- **`scripts/hooks/reseed-context.sh`** — installed as a Claude `SessionStart` hook (matcher `compact|clear`) and a Codex `PostCompact` hook. After a compaction or clear it re-points the orchestrator at the loop's durable on-disk state (pipeline envelope + sentinel), so auto-compaction stays lossless for a long `--queue` run.
- **`scripts/token-audit.py`** — audits where a Claude Code session's tokens actually went. Reads the local transcript store (`~/.claude/projects/**`, read-only, stdlib only, no network) and reports the main-thread vs sub-agent split, per-model-tier cost, a context-drag verdict, and the most expensive sub-agents. `--check-cap sonnet` asserts no sub-agent exceeded a tier and names the reviewer axis when it is the cause.

  ```bash
  python scripts/token-audit.py --list                                  # find the session
  python scripts/token-audit.py --session <uuid> --check-cap sonnet     # full breakdown
  ```

  Use it before tuning cost — the intuitive levers are usually the wrong ones. On an audited run, **81% of tokens were the orchestrator's own context**, not the sub-agent fan-out: shell traffic ~53%, file bodies written into context instead of delegated ~18%, narration only ~7%. Lowering model tiers addressed the remaining 19%.

## Maintaining this repo

This repo is the canonical source. Consumer repos are populated by `setup.sh` — to propagate updates, re-run `setup.sh --force` in each consumer repo. There is intentionally no auto-sync.

See `AGENTS.md` for skill authoring rules (frontmatter, ceilings, contracts).
