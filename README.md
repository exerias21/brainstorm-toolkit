# brainstorm-toolkit

Cross-tool plugin for **Claude Code, GitHub Copilot and Codex**: focused, low-token skills for brainstorming, SDLC, eval-driven development, and repo onboarding. Single AGENTS.md and TASKS.md contract so both agents work from the same source of truth.

## Why this exists

Most AI-agent task systems bolt on heavyweight task databases, multi-agent orchestrators, and inline templates that balloon every command to hundreds of lines. brainstorm-toolkit goes the other direction:

- **One skill = one SKILL.md file**, deliberately short. The pipeline's shared stage bodies live once in `skills/sdlc/templates/`, and a stage that self-skips never opens the template it is skipping: a flag nobody passed costs nothing.
- **Markdown-native contracts.** `AGENTS.md`, `TASKS.md`, `GOTCHAS.md` and `.claude/project.json`. Claude Code, GitHub Copilot, Cursor and friends all read the same files.
- **No central registry**, no dual persistence, no ralph-loop autonomous runners by default. `/sdlc` is the heaviest thing in here and it's still one file plus the templates for the stages a given run actually reaches. (Unattended looping exists but is strictly opt-in: `scripts/loop-runner.sh` only runs when you invoke it, and self-advancing requires setting `pipeline.loop.auto_continue: true`, which is off out of the box and never chains a `confirm` action.)

## Skills

| Skill | Applies to | Use for |
|---|---|---|
| `README.md` | Claude + Copilot + Codex | Print every installed skill + the typical chains. The always-current view; `CHEATSHEET.md` is the printable companion. |
| `/brainstorm` | Claude + Copilot + Codex † | Conversational feature ideation with lens-divergent wildcards (Plan mode on Claude, linear on Copilot) |
| `/brainstorm-team` | Claude + Copilot + Codex † | 6-agent team for competitive + product research incl. a lateral-thinking agent (sequential on Copilot) |
| `/task` | Claude + Copilot + Codex | Create one bounded task and execute it with TDD on the current branch. No flags, always TDD |
| `/sdlc` | Claude + Copilot + Codex † | The full pipeline, ending in a validated working tree you commit yourself. [Details below.](#the-pipeline-sdlc) |
| `/sdlc-status` | Claude + Copilot + Codex | Readout **and** recommendation: task counts, the active task, any stalled pipeline run, then one recommended next command. Read-only. |
| `/repo-onboarding` | Claude + Copilot + Codex | Generate AGENTS.md + TASKS.md + project.json + GOTCHAS.md |
| `/code-tour` | Claude + Copilot + Codex | Turn a codebase into teaching material: why-focused docstrings plus a guided reading path (`TOUR.md`) with exercises. |
| `/repo-health` | Claude + Copilot + Codex | Read-only hygiene sweep (dead code + tests + deps + secrets + gotchas-currency); prints a scored report and the highest-impact next command. |
| `/test-check` | Claude + Copilot + Codex | Run configured tests + log audit after changes (one-shot, no fix loop) |
| `/test-check --loop` | Claude + Copilot + Codex † | Run e2e/browser tests in a fix loop with flaky-test guard (dispatches `e2e-test-runner` agent on Claude, inline on Copilot). Reach for this instead of hand-composing a Playwright agent fan-out; it fixes what it finds. |
| `/gotcha` | Claude + Copilot + Codex | View/append project pitfalls. Auto-drafted at loop-exit by `/task`, `/sdlc` on real traps (objective trigger), and injected at `/brainstorm` start |
| `/flowsim` | Claude + Copilot + Codex | Trace claimed plan flows through source code and flag mismatches |
| `/dead-code-review` | Claude + Copilot + Codex † | Parallel dead-code / dead-doc / stale-plan scan with before-and-after test verification (sequential on Copilot). This is the built-in answer to "launch a few agents and clean up everything no longer needed". |
| `/plan-html` | Claude + Copilot + Codex | Render any markdown plan as a self-contained, shareable HTML page (embedded CSS, zero JS, native `<details>` collapsibles, light/dark mode). Opt-in: pass the plan file as the argument; no auto-emit. Use to share plans with stakeholders or scroll-engage long plans in a browser. |

All skills run on all three tools. † marks skills with a Copilot-optimized overlay at `copilot/skills/<name>/` that runs the same stages sequentially (no parallel sub-agents or Plan mode) because Copilot's VS Code agent mode doesn't yet support those primitives; when it does, overlays will be upgraded. Codex shares those constraints, so `setup.sh` installs the Copilot overlay for Codex too (a Codex-specific override at `codex/skills/<name>/` wins when one exists; today `/sdlc`). Skills without a † rely only on file I/O + test runners and run identically on all three tools.

## The pipeline: `/sdlc`

`/sdlc` is the heaviest thing in the toolkit and the reason most of the rest exists.

```
sanity → implement → evals → fix → validate → plan-validate → flowsim → hand-off
```

**It does no git writes.** No commit, no branch, no push, no PR, at any stage. It hands back a
validated working tree and a suggested commit message; you decide what to commit and when.
That is the whole design: full pipeline discipline on work you still review yourself, which is
what makes it safe to point at a branch that already has an open PR.

**What it takes.** A plan file, a task id, a task range (`1-5`), or a plain description.

**What it does on its own.** Stage 2 splits a large multi-surface plan into per-lane subagents
plus a converge step; small or single-surface plans run one agent. There is no flag for this,
the gate is automatic.

**Two flags worth knowing:**

| Flag | Effect |
|---|---|
| `--resume` | Pick up a paused or failed prior run from its state envelope, keyed on the resolved slug |
| `--queue [N]` | Attended backlog loop: works pending `TASKS.md` rows by priority, re-scans between items so work added mid-run joins, and parks on anything paused. Still no git writes |

The adversarial Review→Fix stage is **off unless you turn it on**, and warn-only on surviving
findings rather than blocking the hand-off, matching its warn-only secret scan. See the case
study below for why it exists.

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
          │                                   │
          └──► /sdlc <plan>  ──► full ────────┘
                    sanity → implement → evals → fix → validate → flowsim
                    (no git writes; it hands you a validated tree)

   Anytime:
     /repo-health   — scored hygiene sweep
     /sdlc-status   — what's active, what's left?
     /flowsim       — verify a plan's claimed flows match the code
     /gotcha        — capture a pitfall
```

## Install

### Option A: Claude Code plugin

If you use the Claude Code plugin system, add this repo as a marketplace source or install directly:

```bash
# In Claude Code:
/plugin marketplace add exerias21/brainstorm-toolkit
/plugin install brainstorm-toolkit
```

### Option B: `setup.sh` (Claude, Copilot, or both)

For Copilot users, or if you prefer file-based installs:

```bash
# Clone this repo once, anywhere
git clone https://github.com/exerias21/brainstorm-toolkit.git ~/brainstorm-toolkit

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
  and `plans/`. These churn every run and are personal to whoever is driving. Idempotent:
  re-running never duplicates a line. `.claude/project.json.example` stays **tracked** as the
  bootstrap template (the pattern matches the exact filename, not the `.example` sibling), as
  do `.claude/settings.json`, `AGENTS.md` and `GOTCHAS.md`. Ignoring these does not break the
  cross-tool contract: Copilot and Codex read them off disk, and `.gitignore` governs sharing,
  not reading.
- `templates/AGENTS.md.template` → `<target>/AGENTS.md` if missing. `CLAUDE.md` is written as a **copy** of `AGENTS.md` (setup.sh never symlinks; WSL/NTFS and Windows git handle symlinks poorly); keep the two in sync.
- `templates/TASKS.md.template` → `<target>/TASKS.md` if missing.
- `templates/CHEATSHEET.md.template` → `<target>/CHEATSHEET.md` if missing. This is the printable companion to `README.md`; once present, setup leaves user edits alone.
- `templates/project.json.example` → `<target>/.claude/project.json.example` (left for you to rename and edit).

It also wires three hooks (skip with `--no-hooks`; the Claude-plugin install in Option A gets them automatically):

- a **Stop** hook running `scripts/hooks/next-action.sh`, which surfaces the `.next-action` seam as `Next: <command>` (Claude `.claude/settings.json`, Copilot `.github/hooks/`, Codex `.codex/hooks.json`);
- a **model-cap** hook running `scripts/hooks/enforce-model-cap.sh` on Claude's `PreToolUse` for the Agent tool. Inert until `.claude/project.json` sets `pipeline.enforce_cap: true`; then a sub-agent dispatch above `models.cap` is rewritten to the cap (reviewer dispatches, prefixed `review:`, are exempt) and you see each rewrite as a system message. Makes the cap deterministic instead of prose-enforced.
- a **reseed** hook running `scripts/hooks/reseed-context.sh`, wired as Claude `SessionStart` (matcher `compact|clear`) and Codex `PostCompact`. It re-points the session at the loop's on-disk state after a compaction, so long `--queue` runs survive auto-compaction. Merged into existing hook config with `jq` and deduped by command string, so re-running is idempotent; without `jq` installed setup skips it and prints the entry to add by hand.

Re-running `setup.sh` is safe: it skips existing files unless you pass `--force`. Install only for one tool with `--tools claude` or `--tools copilot`.

### Option C: `sync-global.sh` (user-scope, no plugin, no marketplace)

Options A and B install **per repo**. Option C installs **once, globally**, for machines where
the plugin route isn't available: an org policy that sets `disableSideloadFlags` (blocking
`--plugin-dir`), a locked-down marketplace, or simply not wanting a plugin registration:

```bash
git clone https://github.com/exerias21/brainstorm-toolkit.git ~/brainstorm-toolkit

bash ~/brainstorm-toolkit/scripts/sync-global.sh --dry-run   # preview, writes nothing
bash ~/brainstorm-toolkit/scripts/sync-global.sh             # apply
```

It copies `skills/*` → `~/.claude/skills/<name>/` and `agents/*` → `~/.claude/agents/`, then
`jq`-merges the Stop and `SessionStart` hooks into `~/.claude/settings.json` with **absolute**
paths. Claude Code discovers all of it natively: no plugin, no sideload flag.

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
  **Re-run the script after every `git pull`:** that explicit step is the point.
- **Hook paths are hardcoded on purpose.** `${CLAUDE_PLUGIN_ROOT}` only expands inside the
  plugin runtime; in a global `settings.json` it stays a literal and the hook silently no-ops.
  The same applies to a *repo-relative* command like `bash scripts/hooks/next-action.sh`, which is fine
  in a project-scoped `.claude/settings.json` (which is what `setup.sh` writes), but as a
  **global** hook it fires in every repo and fails in each one lacking that file.
  `--prune-relative-hooks` cleans that up.
- **Pruning is scoped per skill directory.** The sync runs `rsync --delete` *inside each skill
  directory it owns*, never against `~/.claude/skills/` as a whole, so a file you deleted
  from a toolkit skill disappears on the next sync, while unrelated user skills installed by
  other tools are never touched. (`--delete` here is rsync's flag, used internally; it is not
  a `sync-global.sh` option. To remove what the script installed, use `--uninstall`.)
- **Token weight.** A global sync makes all 13 skills resident in *every* repo, and several
  (`/sdlc`, `/sdlc-status`) assume the `AGENTS.md` / `.claude/project.json` contract.
  Use `--skills` to install just the ones that travel well: `/brainstorm`, `/brainstorm-team`,
  `/gotcha`, and keep the pipeline skills per repo via
  `setup.sh`.

Don't run Option C **and** Option A together: double registration means each skill is discovered
twice and the Stop hook fires twice, and `next-action.sh` consumes the sentinel on first read, so
the second pass sees an empty seam. The script warns if it detects the plugin still enabled.

### Windows note

`setup.sh` is bash; run it under **WSL, Linux, or macOS**. It writes `CLAUDE.md` as a plain copy of `AGENTS.md` (never a symlink; Windows-native git and WSL/NTFS handle symlinks inconsistently); keep the two files in sync.

## The cross-tool contract

Every consumer repo gets four shared files:

| File | Purpose | Read by |
|---|---|---|
| `AGENTS.md` | Architecture + agent conventions | Claude Code (via `CLAUDE.md` copy), Copilot, Cursor, Codex |
| `TASKS.md` | Markdown checkbox task queue | All agents, humans, GitHub UI |
| `GOTCHAS.md` | Project-specific pitfalls | `/gotcha`, `/sdlc` sanity check |
| `.claude/project.json` | Runner config (tests, logs, eval) | `/test-check`, `/sdlc` |

Every `project.json` key is optional: skills skip steps gracefully when config is missing. A repo with no `project.json` still gets useful behavior from `/brainstorm`, `/task`, `/gotcha`, etc.

## Configuration

`.claude/project.json` configures test commands, log audits, the eval runner, model tiers and
agent counts. **Every key is optional**, and a missing key means the skill skips that step
rather than guessing, so a repo with no `project.json` still works.

- **[docs/CONFIG.md](docs/CONFIG.md):** the full key reference, plus which skill reads which key.
- **[templates/project.json.example](templates/project.json.example):** a commented starting point.
- `/repo-onboarding` writes the file for you, and asks about the choices detection can't make.

## Cost

The fan-out is Sonnet-first by default, and `models.cap` is a ceiling you can lower. A typical
`/sdlc` run costs a couple of dollars; the read-only skills cost fractions of a cent.

**[docs/COST.md](docs/COST.md)** has the per-skill table: what each one dispatches, tokens per
run, and cost per run at current list pricing.

One finding worth pulling forward, because it redirects most cost-tuning effort: on an audited
run, **81% of tokens were the orchestrator's own context**, not the sub-agent fan-out. Shell
traffic was ~53%, file bodies read into context instead of delegated ~18%, narration ~7%.
Lowering model tiers addressed the remaining 19%. Measure before you tune;
`scripts/token-audit.py` does the measuring.

## Case study: why the Review→Fix stage exists

 A `/sdlc` run reported everything green: 969→981
tests passing, flowsim 7/7 match, plan-validate 8/8, clean container logs. Three independent
adversarial review passes (a different model from the implementer, run manually) then found 6
real bugs the green suite never caught: a double-decoded URL, an hourly in-memory state reset
hammering an external API, a mis-classified recurrence rule, a stale frontend query-key
invalidation, an over-broad geo deny-list, and a missing env-var default, plus a 7th surfaced
by a live-data check. Total cost: ~240k tokens across 3 passes, each 1–6 minutes. See
`docs/REVIEW-FIX-STAGE.md` for the full write-up and the Review→Fix stage design.

## Documentation

- **[docs/CONFIG.md](docs/CONFIG.md):** every `.claude/project.json` key, and which skill reads it.
- **[docs/COST.md](docs/COST.md):** per-skill model dispatch, tokens per run, and cost per run.
- **[docs/CONVENTIONS.md](docs/CONVENTIONS.md):** naming rules for skills, stages, artifact IDs and paths, plus the migration policy for renaming one safely.
- **[docs/MODEL-AXES.md](docs/MODEL-AXES.md):** why the model-tier ceiling and the reviewer model are two independent axes, and why only one of them is capped.
- **[docs/FLOW.md](docs/FLOW.md):** one visual reference for the whole toolkit across Claude Code, Copilot, and Codex: install, the end-to-end flow diagram, the entry-skill picker, per-runtime differences, and model tiers.
- **[docs/AUTONOMOUS-DISCOVERY.md](docs/AUTONOMOUS-DISCOVERY.md):** optional pattern for running discovery skills unattended on a schedule: a watcher daemon driving the headless `claude` CLI against a job queue. Reference only, not shipped by `setup.sh`.
- **[docs/LOOP-HYGIENE.md](docs/LOOP-HYGIENE.md):** how to keep a many-hour `/sdlc --queue` or auto-continue run context-cheap. The loop can't self-compact; the lever is **batch handoff:** a fresh process every `pipeline.loop.batch_size` completed items, plus a reseed hook that re-points at the on-disk envelope after a compact/clear.
- **[docs/SEAM.md](docs/SEAM.md):** the `.claude/.next-action` contract: multi-slot, one JSON entry per line, append-and-dedup, `confirm: true` for anything that writes git history.

## Supporting scripts

- **`scripts/eval-runner.py`:** runs pytest + fixture-based pipeline evals. Auto-discovers features from `evals/*/`. See `skills/test-check/SKILL.md` step 6.
- **`scripts/check_docker_logs.py`:** audits logs for errors/tracebacks. Accepts `--log-command` and `--services`. Works with Docker, kubectl, journalctl, or any log source.
- **`scripts/ci/check_install_refs.py`.** CI guard: installs the toolkit into a scratch repo and fails the build if any template citation in a shipped skill does not resolve there. Runs in the `setup-roundtrip` workflow.
- **`scripts/validate_skills.py`:** validates skill metadata, name-to-directory alignment, and Copilot-targeted skills against Claude-only capability leakage.
- **`scripts/loop-runner.sh`:** batch-handoff queue runner for long backlogs. Drives `/sdlc --queue` in a **fresh headless process every `pipeline.loop.batch_size` completed items**, so context resets at a clean item boundary instead of growing all run. Batch size resolves `--queue X` flag > `pipeline.loop.batch_size` > `pipeline.loop.max_items` > 5. See `docs/LOOP-HYGIENE.md`.
- **`scripts/hooks/next-action.sh`:** the Stop hook behind the `.next-action` seam. Reads the sentinel once, prints `Next: <command>`, deletes it. With `pipeline.loop.auto_continue: true` it instead **executes** a single non-`confirm` entry (`decision: block`), bounded by `pipeline.loop.max_hops`. See `docs/SEAM.md`.
- **`scripts/sync-global.sh`:** user-scope installer for machines without the plugin route (see *Install → Option C*). Copies `skills/*` and `agents/*` into `~/.claude/` and `jq`-merges the Stop + `SessionStart` hooks with absolute paths. `--dry-run` previews, `--uninstall` reverses. Copies rather than symlinks, so re-run it after each `git pull`.
- **`scripts/hooks/reseed-context.sh`:** installed as a Claude `SessionStart` hook (matcher `compact|clear`) and a Codex `PostCompact` hook. After a compaction or clear it re-points the orchestrator at the loop's durable on-disk state (pipeline envelope + sentinel), so auto-compaction stays lossless for a long `--queue` run.
- **`scripts/token-audit.py`:** audits where a Claude Code session's tokens actually went. Reads the local transcript store (`~/.claude/projects/**`, read-only, stdlib only, no network) and reports the main-thread vs sub-agent split, per-model-tier cost, a context-drag verdict, and the most expensive sub-agents. `--check-cap sonnet` asserts no sub-agent exceeded a tier and names the reviewer axis when it is the cause.

  ```bash
  python scripts/token-audit.py --list                                  # find the session
  python scripts/token-audit.py --session <uuid> --check-cap sonnet     # full breakdown
  ```

  Use it before tuning cost; the intuitive levers are usually the wrong ones. On an audited run, **81% of tokens were the orchestrator's own context**, not the sub-agent fan-out: shell traffic ~53%, file bodies written into context instead of delegated ~18%, narration only ~7%. Lowering model tiers addressed the remaining 19%.

## Maintaining this repo

This repo is the canonical source. Consumer repos are populated by `setup.sh`; to propagate updates, re-run `setup.sh --force` in each consumer repo. There is intentionally no auto-sync.

See `AGENTS.md` for skill authoring rules (frontmatter, ceilings, contracts).
