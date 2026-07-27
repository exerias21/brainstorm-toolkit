# brainstorm-toolkit

Cross-tool plugin for **Claude Code + GitHub Copilot**: focused, low-token skills for brainstorming, SDLC, eval-driven development, and repo onboarding. Single AGENTS.md and TASKS.md contract so both agents work from the same source of truth.

## Why this exists

Most AI-agent task systems bolt on heavyweight task databases, multi-agent orchestrators, and inline templates that balloon every command to hundreds of lines. brainstorm-toolkit goes the other direction:

- **One skill = one SKILL.md file**, deliberately short (37–250 lines each).
- **Markdown-native contracts** — `AGENTS.md`, `TASKS.md`, `GOTCHAS.md`, `.claude/project.json` — so Claude Code, GitHub Copilot, Cursor, and friends all read the same files.
- **No central registry**, no dual persistence, no ralph-loop autonomous runners by default. `/sdlc` is the heaviest thing in here and it's still one file. (Unattended looping exists but is strictly opt-in: `scripts/loop-runner.sh` only runs when you invoke it, and self-advancing requires setting `pipeline.loop.auto_continue: true`, which is off out of the box and never chains a `confirm` action.)

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
- `templates/AGENTS.md.template` → `<target>/AGENTS.md` if missing. `CLAUDE.md` is written as a **copy** of `AGENTS.md` (setup.sh never symlinks — WSL/NTFS and Windows git handle symlinks poorly); keep the two in sync.
- `templates/TASKS.md.template` → `<target>/TASKS.md` if missing.
- `templates/CHEATSHEET.md.template` → `<target>/CHEATSHEET.md` if missing. This is the printable companion to `/cheatsheet`; once present, setup leaves user edits alone.
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
| `--skills a,b,c` | Sync a subset instead of all 24 (see *token weight* below) |
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
- **Token weight.** A global sync makes all 24 skills resident in *every* repo, and several
  (`/sdlc`, `/sdlc-lite`, `/status`) assume the `AGENTS.md` / `.claude/project.json` contract.
  Use `--skills` to install just the ones that travel well — `/brainstorm`, `/brainstorm-team`,
  `/brainstorm-deep`, `/gotcha`, `/cheatsheet` — and keep the pipeline skills per repo via
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
| `.claude/project.json` | Runner config (tests, logs, eval) | `/test-check`, `/eval-harness`, `/sdlc` |

Every `project.json` key is optional — skills skip steps gracefully when config is missing. A repo with no `project.json` still gets useful behavior from `/brainstorm`, `/task`, `/gotcha`, etc.

## Skills

| Skill | Applies to | Use for |
|---|---|---|
| `/cheatsheet` | Claude + Copilot + Codex | Print every installed skill + the typical chains. The always-current view; `CHEATSHEET.md` is the printable companion. |
| `/brainstorm` | Claude + Copilot + Codex † | Conversational feature ideation with lens-divergent wildcards (Plan mode on Claude, linear on Copilot) |
| `/brainstorm-deep` | Claude + Copilot + Codex † | Clarification-heavy ideation for ambiguous or high-stakes ideas. Three-pass loop (understand → saturate → plan-with-alternates), perspective-frame sub-agents, expectation-contract output. Slower than `/brainstorm`, more rigorous. |
| `/brainstorm-team` | Claude + Copilot + Codex † | 6-agent team for competitive + product research incl. a lateral-thinking agent (sequential on Copilot) |
| `/task` | Claude + Copilot + Codex | Create one bounded task and execute it with TDD on the current branch — no flags, always TDD |
| `/sdlc-lite` | Claude + Copilot + Codex † | The full `/sdlc` pipeline with a different ending — sanity → implement → evals → fix → validate → plan-validate → flowsim, then **hands you the validated changes to commit yourself** (no commit, branch, push, or PR — only `/sdlc` touches git). Stage 2 auto-decomposes large multi-surface plans into focused per-lane subagents + a converge step; small / single-surface plans run a single agent unchanged. Takes a plan file, a task id, a task range (`1-5`), or an ad-hoc description. Use to run full discipline on work you want to review and commit onto an open PR's branch. Same optional Review→Fix stage as `/sdlc`, warn-only on surviving findings (consistent with its warn-only secret scan) rather than blocking handoff. Supports `--resume` (same envelope-resume as `/sdlc`; resume keys on the resolved slug) and `--queue [N]` (attended backlog loop: selects pending TASKS.md rows by priority, re-scans between items so mid-run additions join, parks on any paused/confirm item — no git writes). |
| `/status` | Claude + Copilot + Codex | Quick readout of TASKS.md counts + active task |
| `/next` | Claude + Copilot + Codex † | The conductor — joins pipeline run-state + `.next-action` sentinel + TASKS.md + plans + git into ONE recommended next command with a one-line rationale. Read-only by default; `--go` executes the top pick (still confirming before any git-history write). Consolidates the next-step ladder scattered across `/brainstorm` Step 8, `/repo-health`, and `/status`. |
| `/triage` | Claude + Copilot + Codex | The red-path fix recommender — turns a PAUSED/failed pipeline run into a diagnosis + one command. Classifies the failure from its sidecar (flaky / code-defect / plan-wrong / config-missing / abandoned), drafts the fix for a real code defect (reusing the Review→Fix finding schema + `auto_fixable` rubric), and hands back a `--resume` re-entry that reuses the run's green stages. Read-only by default; `--go` opt-in. `/next` rung 1 routes here. |
| `/pr-followup` | Claude + Copilot + Codex | The PR back-edge — reads an open PR's review threads + requested changes + CI status (`gh` locally / GitHub MCP hosted), classifies each open item with `/triage`'s vocabulary, drafts the fix batch, and runs it through `/sdlc-lite` on the PR branch (no git writes — you push). Turns "address the review feedback / CI failed" into one command; records `pr_followup_of` in the envelope. |
| `/sdlc` | Claude + Copilot + Codex † | Plan → implement → eval → test → flowsim → PR. Stage 2 auto-decomposes large multi-surface plans into focused per-lane subagents + a converge step (single agent for small / single-surface plans). Skill-repo mode auto-detected from `.claude-plugin/marketplace.json`. Optional, opt-in adversarial Review→Fix stage after flowsim (reviewer axis, default Opus once enabled — `--review-model <name>` or `pipeline.review_fix.enabled: true` to turn on, `--no-review` always wins) surfaces defects a green test/flowsim run structurally can't catch. `--resume` picks up a paused/failed run from the first non-passing stage (reusing the green stages) instead of restarting from Stage 1. |
| `/repo-onboarding` | Claude + Copilot + Codex | Generate AGENTS.md + TASKS.md + project.json + GOTCHAS.md |
| `/repo-health` | Claude + Copilot + Codex | Read-only hygiene sweep (dead code + tests + deps + secrets + gotchas-currency); prints a scored report and the highest-impact next command. |
| `/test-check` | Claude + Copilot + Codex | Run configured tests + log audit after changes (one-shot, no fix loop) |
| `/e2e-loop` | Claude + Copilot + Codex † | Run e2e/browser tests in a fix loop with flaky-test guard (dispatches `e2e-test-runner` agent on Claude, inline on Copilot). Reach for this instead of hand-composing a Playwright agent fan-out — it fixes what it finds. |
| `/gotcha` | Claude + Copilot + Codex | View/append project pitfalls — auto-drafted at loop-exit by `/task`, `/sdlc`, `/sdlc-lite` on real traps (objective trigger), and injected at `/brainstorm` start |
| `/eval-harness` | Claude + Copilot + Codex | Run pytest + fixture evals with optional fix loop |
| `/flowsim` | Claude + Copilot + Codex | Trace claimed plan flows through source code and flag mismatches |
| `/dead-code-review` | Claude + Copilot + Codex † | Parallel dead-code / dead-doc / stale-plan scan with before-and-after test verification (sequential on Copilot). This is the built-in answer to "launch a few agents and clean up everything no longer needed". |
| `/review-pr` | Claude + Copilot + Codex | On-demand code review for any PR or branch — wraps `/review`, persists to `plans/review-<id>.md`, optional `--post-comment`. Standalone counterpart to the post-PR review `/sdlc` already runs. |
| `/plan-html` | Claude + Copilot + Codex | Render any markdown plan as a self-contained, shareable HTML page (embedded CSS, zero JS, native `<details>` collapsibles, light/dark mode). Opt-in: pass the plan file as the argument — no auto-emit. Use to share plans with stakeholders or scroll-engage long plans in a browser. |
| `/data-source-pattern` | Claude + Copilot + Codex | Pattern guide for ingesting external data: discovery pipeline / seed script / direct API, plus how to author a web-discovery skill (WebSearch vs headless browser, session cookies, source trust tiers, dedup-upsert) |
| `/logging-conventions` | Claude + Copilot + Codex | Enforce structured logging discipline |
| `/post-deploy-verify` | Claude + Copilot + Codex | Stub — post-deploy BRD/PBI-vs-deployed-system verification matrix (depends on Phase 2 BRD/PBI artifacts; see `BRAINSTORM-PIPELINE.md`) |

All skills run on all three tools. † marks skills with a Copilot-optimized overlay at `copilot/skills/<name>/` that runs the same stages sequentially (no parallel sub-agents or Plan mode) because Copilot's VS Code agent mode doesn't yet support those primitives; when it does, overlays will be upgraded. Codex shares those constraints, so `setup.sh` installs the Copilot overlay for Codex too (a Codex-specific override at `codex/skills/<name>/` wins when one exists — today `/sdlc` and `/sdlc-lite`). Skills without a † rely only on file I/O + test runners and run identically on all three tools.

## Model & cost reference

What each skill dispatches under the hood, and a rough order-of-magnitude
cost. Token counts are **per typical run**, not worst-case — a `/sdlc` run
on a tiny plan is closer to the low end, on a multi-module refactor the
high end. Costs use 2026-04 list pricing: Opus $15 / $75, Sonnet $3 / $15,
Haiku $1 / $5 per M tokens (input / output).

| Skill | Orchestrator | Sub-agents (per run) | Tokens/run (rough) | Cost/run (rough) |
|---|---|---|---|---|
| `/cheatsheet` | host model | none — file I/O only | <1k | ~$0.00 |
| `/status` | host model | none — reads `TASKS.md` | <1k | ~$0.00 |
| `/gotcha` | host model | none — read/append `GOTCHAS.md` | <1k | ~$0.00 |
| `/data-source-pattern` | host model | none — reference doc | <1k | ~$0.00 |
| `/logging-conventions` | host model | none — reference doc | <1k | ~$0.00 |
| `/test-check` | host model | none — runs tests + log audit | 1k–3k | ~$0.01 |
| `/plan-html` | host model | none — markdown read → HTML write | 3k–10k | ~$0.01–$0.05 |
| `/task` | host model | none — inline TDD | 5k–15k | $0.02–$0.10 |
| `/repo-health` | host model | 2 × Haiku (dead-code + gotchas-currency); 3 procedural checks | 5k–20k | $0.02–$0.10 |
| `/review-pr` | host model | none — wraps the built-in `/review` primitive on the captured diff | 5k–30k | $0.02–$0.30 |
| `/eval-harness` | host model | 0–1 × Sonnet (optional fix loop) | 5k–30k | $0.02–$0.30 |
| `/flowsim` | host model | none — plan-vs-code grep | 10k–40k | $0.05–$0.40 |
| `/e2e-loop` | host model | 1 × Sonnet per fix iteration | 10k–30k / iter | $0.05–$0.30 / iter |
| `/repo-onboarding` | host model (Opus recommended) | 0–1 × Sonnet (pattern detection) | 20k–60k | $0.30–$1.00 |
| `/brainstorm` (`light`) | host (Opus) | 3 × Haiku lens agents | 20k–50k | $0.10–$0.40 |
| `/brainstorm` (`deep`) | host (Opus) | 3 × Haiku + 1 × Sonnet stress-test | 30k–70k | $0.20–$0.80 |
| `/brainstorm` (`ultra`) | host (Opus) | 3 × Haiku + 1 × Sonnet + 2 × Opus | 60k–120k | $1.00–$3.00 |
| `/brainstorm-deep` | host (Opus) | 4 × Sonnet perspective-frame agents (parallel) by default; `--frames` overrides; structured saturation Q&A stays inline | 30k–80k | $0.20–$0.80 |
| `/brainstorm-team` | host (Opus) | 6 × Sonnet teammates (4 parallel, 2 sequential) | 60k–150k | $0.60–$2.00 |
| `/dead-code-review` | host (Opus) | 3 × Haiku + 2 × Sonnet + 1 × Opus (parallel) | 80k–200k | $0.80–$2.50 |
| `/post-deploy-verify` | host model | 2 × Haiku + 1 × Sonnet **per PBI batch** | scales with batch | $0.10–$1.00 / batch |
| `/sdlc-lite` | host (Opus) | same fan-out as `/sdlc` minus the PR/review tail | 90k–280k | $2.50–$9.00 |
| `/sdlc` | host (Opus) | 3 × Haiku (sanity) + 1 × Opus (impl) + 2–4 × Haiku/Sonnet (validate) + optional Opus/Sonnet (eval-fix) + Sonnet (e2e) | 100k–300k | $3.00–$10.00 |

**Notes / caveats**:

- The "host model" / "orchestrator" is whichever model is running the
  Claude Code or Copilot session — the toolkit doesn't pin it. Costs
  above assume Opus for Plan-mode-bearing and fan-out-heavy skills
  (`/brainstorm`, `/brainstorm-deep`, `/sdlc`, `/dead-code-review`)
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

**Why the Review→Fix stage exists.** A `/sdlc-lite` run reported everything green — 969→981
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
- **[docs/LOOP-HYGIENE.md](docs/LOOP-HYGIENE.md)** — how to keep a many-hour `/sdlc-lite --queue` or auto-continue run context-cheap. The loop can't self-compact; the lever is **batch handoff** — a fresh process every `pipeline.loop.batch_size` completed items, plus a reseed hook that re-points at the on-disk envelope after a compact/clear.
- **[docs/SEAM.md](docs/SEAM.md)** — the `.claude/.next-action` contract: multi-slot, one JSON entry per line, append-and-dedup, `confirm: true` for anything that writes git history.

## Typical workflow

```mermaid
flowchart LR
    A[/repo-onboarding/]:::setup --> B[AGENTS.md + TASKS.md<br/>project.json + GOTCHAS.md]
    B --> C[/brainstorm/]
    B --> D[/task/]
    B --> E[/pbi/<br/>Phase 1D]
    C --> F[plans/brainstorm-*.md]
    E --> G[plans/pbi-NNN-*.md]
    D --> H[inline TDD]
    F --> I[/sdlc {plan}/]:::core
    G --> I
    H --> J[PR]
    I --> J
    J --> K[merge]
    K --> L[/post-deploy-verify/<br/>pipeline profile]:::pipe

    subgraph "Anytime, in parallel"
      M[/cheatsheet/<br/>discover]
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
          ├──► /pbi          ──► PBI + plan ──┐
          │                                    │
          ├──► /task         ──► TDD inline ──┼──► PR
          │                                    │
          └──► /sdlc <plan>  ──► autonomous ──┘
                                  implement → eval → test → flowsim → PR

   Anytime:
     /cheatsheet     — what skills are installed?
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
    "plan_review": null,
    "implement": null,
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
| Keys | `models.cap`, `.sanity`, `.plan_review`, `.implement`¹ | `models.code_review`, `.code_review_second_pass` |
| Values | `haiku` \| `sonnet` \| `opus` | `haiku` \| `sonnet` \| `opus` \| `fable` |
| Capped? | yes — everything passes through the cap | **never** |

¹ `models.implement` is **reserved, not yet wired** — both Stage 2 dispatch sites hard-code
`capModel('opus', cap)`. Steer the implementer with `--model` / `models.cap` for now.

`models.cap` is a **ceiling**, not a setting: `effective = min(stage_tier, cap)`. So
`sonnet` lowers every Opus dispatch while leaving Haiku agents alone — you cut Opus spend
without upgrading the cheap ones. Per-run override `--model <tier>` (precedence: flag >
`models.cap` > default) wins both directions. **The fan-out is Sonnet-first by default:**
out of the box `/sdlc`, `/sdlc-lite`, `/brainstorm --vet ultra`, and every ultracode
Workflow run Sonnet; `--model opus` is the deliberate opt-up.

**The consequence worth knowing:** because the cap only *lowers*, a stage whose built-in
tier is `haiku` cannot be raised by `models.cap` or `--model` at all. The per-stage key is
the only lever — which is why `models.sanity` and `models.plan_review` exist. Stage 1.5 is
never gated, so it runs on every single run.

`agents.*` sets **how many** agents each fan-out stage dispatches. Cost scales roughly
linearly — one agent (or reviewer call) per entry — so trimming
`agents.code_review_lenses` to `["correctness", "security"]` roughly halves the review
stage. All of it governs sub-agents only, never the session orchestrator.


`pipeline.loop.*` tunes the backlog loop and is **entirely optional** (defaults
shown above). `max_items` caps how many TASKS.md rows one `/sdlc-lite --queue`
invocation consumes; `batch_size` is read only by `scripts/loop-runner.sh` and
sets how many completed items a single headless process handles before context
is reset at a clean boundary; `max_hops` bounds the auto-continue chain.
`auto_continue` is **off by default** and Claude/Codex only — when true, the Stop
hook executes a single non-`confirm` `.next-action` entry instead of just
printing it, so the loop self-advances. It never chains a `confirm: true` action
(i.e. never `/sdlc`, which opens a PR). See `docs/LOOP-HYGIENE.md`.

### Which skill reads which key

| Skill | Reads |
|---|---|
| `/test-check` | `test.*`, `logs.*` |
| `/eval-harness` | `eval.*` |
| `/sdlc` | `gotchas_file`, `eval.*`, `main_branch`, delegates to `/test-check` |
| `/gotcha` | `gotchas_file` |
| `/brainstorm` | `modules`, `models.cap` |
| `/sdlc`, `/sdlc-lite`, `/brainstorm-deep`, `/brainstorm-team`, `/dead-code-review` | `models.cap` (sub-agent tier ceiling) |
| `/sdlc`, `/sdlc-lite` | `models.sanity` + `agents.sanity_focuses` (Stage 1.5 pre-flight — never gated, so it runs every time) |
| `/sdlc`, `/sdlc-lite` | `models.plan_review` (Stage 5.5 validator tier — a default *within* axis 1, still capped) |
| `/sdlc`, `/sdlc-lite` | `models.code_review`, `models.code_review_second_pass`, `agents.code_review_*` (axis 2 — never capped) |
| `/sdlc`, `/sdlc-lite` | `pipeline.review_fix.*` — stage *behavior* only (`enabled`, `mode`, `blocking`, thresholds). Opt-in, permanently off by default |
| `/sdlc`, `/sdlc-lite` | `agents.decompose_min_tasks` (Stage 2 decompose gate) |
| `/sdlc-lite --queue`, `scripts/loop-runner.sh`, `scripts/hooks/next-action.sh` | `pipeline.loop.*` (`max_items`, `batch_size`, `max_hops`, `auto_continue`) |
| `/sdlc-lite` Stage 6 | `stack.up` / `stack.down` / `stack.rebuild` / `stack.url` — printed as the manual-verification line at hand-off, never auto-run |
| `/task`, `/status` | (none — read TASKS.md directly) |
| `/repo-onboarding` | writes all of the above |

## Supporting scripts

- **`scripts/eval-runner.py`** — runs pytest + fixture-based pipeline evals. Auto-discovers features from `evals/*/`. See `skills/eval-harness/SKILL.md`.
- **`scripts/check_docker_logs.py`** — audits logs for errors/tracebacks. Accepts `--log-command` and `--services`. Works with Docker, kubectl, journalctl, or any log source.
- **`scripts/validate_skills.py`** — validates skill metadata, name-to-directory alignment, and Copilot-targeted skills against Claude-only capability leakage.
- **`scripts/loop-runner.sh`** — batch-handoff queue runner for long backlogs. Drives `/sdlc-lite --queue` in a **fresh headless process every `pipeline.loop.batch_size` completed items**, so context resets at a clean item boundary instead of growing all run. Batch size resolves `--queue X` flag > `pipeline.loop.batch_size` > `pipeline.loop.max_items` > 5. See `docs/LOOP-HYGIENE.md`.
- **`scripts/hooks/next-action.sh`** — the Stop hook behind the `.next-action` seam. Reads the sentinel once, prints `Next: <command>`, deletes it. With `pipeline.loop.auto_continue: true` it instead **executes** a single non-`confirm` entry (`decision: block`), bounded by `pipeline.loop.max_hops`. See `docs/SEAM.md`.
- **`scripts/sync-global.sh`** — user-scope installer for machines without the plugin route (see *Install → Option C*). Copies `skills/*` and `agents/*` into `~/.claude/` and `jq`-merges the Stop + `SessionStart` hooks with absolute paths. `--dry-run` previews, `--uninstall` reverses. Copies rather than symlinks, so re-run it after each `git pull`.
- **`scripts/hooks/reseed-context.sh`** — installed as a Claude `SessionStart` hook (matcher `compact|clear`) and a Codex `PostCompact` hook. After a compaction or clear it re-points the orchestrator at the loop's durable on-disk state (pipeline envelope + sentinel), so auto-compaction stays lossless for a long `--queue` run.

## Maintaining this repo

This repo is the canonical source. Consumer repos are populated by `setup.sh` — to propagate updates, re-run `setup.sh --force` in each consumer repo. There is intentionally no auto-sync.

See `AGENTS.md` for skill authoring rules (frontmatter, ceilings, contracts).
