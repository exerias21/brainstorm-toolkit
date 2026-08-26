# AGENTS.md — brainstorm-toolkit

Instructions for AI coding agents (Claude Code, GitHub Copilot, Cursor, Codex, etc.) working in this repo.

## What this repo is

**brainstorm-toolkit** is a cross-tool plugin: a collection of SKILL.md-style slash commands that work in both Claude Code and GitHub Copilot. The design goal is **low token weight** — each skill is a focused, single-purpose file, and skills share a unified AGENTS.md / TASKS.md / project.json contract rather than embedding templates and checklists inline.

## Layout

```
.claude-plugin/            # Plugin + marketplace manifests
skills/<name>/SKILL.md     # Canonical skills (source of truth, Claude-first)
skills/<name>/references/  # Runtime reference a skill LOADS — shipped into consumers by setup.sh
copilot/skills/<name>/     # Copilot overrides (only skills that differ from canonical)
codex/skills/<name>/       # Codex overrides (sequential; falls through to copilot/ then canonical)
agents/                    # Claude-only sub-agent definitions
scripts/                   # Shared helpers (eval-runner.py, check_docker_logs.py)
templates/                 # AGENTS.md / TASKS.md / project.json templates for consumer repos
docs/                      # Maintainer/architecture docs + see-also targets — NOT installed into consumers
examples/                  # GOTCHAS.md.example
setup.sh                   # Installer — copies skills into a target repo (Claude / Copilot / Codex)
README.md                  # User-facing docs
```

### `docs/` vs `skills/<name>/references/` — the placement rule

Both hold `.md` reference material; they differ in **who reads them and whether they ship**:

- **`docs/`** — maintainer/architecture docs, and any doc a skill merely *cites* / *see-also's*
  (`FLOW.md`, `CONVENTIONS.md`, `REVIEW-FIX-STAGE.md`, `PHASE-1-STATE-ENVELOPE.md`). `setup.sh` does
  **not** copy `docs/`, so these are **zero token weight** in consumer repos. A citation is a one-line
  pointer (`naming per docs/CONVENTIONS.md`) — the reader jumps to the plugin repo.
- **`skills/<name>/references/`** — material a skill's prompt instructs the agent to **open and load**
  at runtime (`sdlc/templates/` review checklists — e.g. the correctness/security lens rubrics).
  `setup.sh` copies the whole skill tree, so this ships into every consumer that installs the skill —
  and pays its weight only there.

**Placement test:** does the skill **LOAD** the file to do its job (→ `references/`), or merely
**CITE** it (→ `docs/`)? A citation is a pointer, not a payload. Never move a maintainer/see-also doc
into `references/` — that ships it (installed once per tool — up to three identical copies under
`--tools all`) to every consumer for readers who never open it.

**Per-tool overlays replace the canonical skill tree wholesale** (`setup.sh` installs the overlay
*instead of* the canonical). So an overlaid skill's runtime references must live in the overlay's own
`references/` (`copilot/skills/<name>/references/`, `codex/skills/<name>/references/`) — a canonical
`references/` file under an overlaid skill won't reach that tool. Tool-specific references live there.

## Skill authoring rules

1. **Frontmatter must include toolkit routing metadata** under `metadata.brainstorm-toolkit-applies-to`. Use `claude` for Claude-only skills or `claude copilot` for dual-tool skills. Example:
   ```yaml
   ---
   name: status
   description: ...
   metadata:
     brainstorm-toolkit-applies-to: claude copilot
   ---
   ```
   `setup.sh` uses this metadata to decide whether the skill is copied to `.github/skills/<name>/` (Copilot) in addition to `.claude/skills/<name>/` (Claude). The installer still accepts the legacy top-level `applies-to:` key for backward compatibility, but new edits in this repo should use `metadata`.
2. **Claude-only features** (Plan mode, sub-agents via the Agent tool, hooks) → mark the skill `claude` only in `skills/`. If the skill is still useful on Copilot in a simplified form, create a Copilot-optimized override in `copilot/skills/<name>/SKILL.md` (see rule 8).
3. **Keep each SKILL.md tight.** Target ceilings: small utility skills ≤100 lines, larger orchestration skills ≤250 lines. If a skill grows beyond this, split it or move embedded content into `templates/`.
4. **No inline templates or long checklists.** Reference `templates/*.template` files instead.
5. **Graceful skip on missing config** — read `.claude/project.json` keys with fallbacks; skills must work with an empty or missing `project.json`.
6. **Copilot uses Agent Skills, not prompt-file shims.** Consumer repos should receive `.github/skills/<name>/SKILL.md`, including any bundled resources referenced by the skill.
7. **Claude helper agents stay in `.claude/agents/`.** VS Code can discover Claude-format agents there, so this repo does not maintain a duplicate `.github/agents/` tree for the current Claude-only helper agents.
8. **Copilot overlay pattern.** `copilot/skills/<name>/SKILL.md` overrides the canonical `skills/<name>/SKILL.md` for Copilot distribution. Use this when a skill needs Claude-specific features (Plan mode, agents) in its canonical version but can still provide value as a simplified Copilot slash command. `setup.sh` prefers the override when it exists; otherwise falls through to the canonical version. Overrides must set `metadata.brainstorm-toolkit-applies-to: copilot` and pass `validate_skills.py` independently.

## Unified contracts

- **`AGENTS.md`** — repo-wide agent instructions. Consumer repos symlink (POSIX) or copy `CLAUDE.md` → `AGENTS.md`.
- **`TASKS.md`** — markdown checkbox list at repo root; the portable task tracker shared by Claude's `TaskCreate` mirror and Copilot's TODO reading.
- **`GOTCHAS.md`** — project-specific pitfalls; consulted by `/gotcha` and the sanity-check stage of `/sdlc`.
- **`.claude/project.json`** — optional per-project config (test commands, eval runner, modules list); every key is optional, missing keys are skipped.
- **Gotcha flywheel** — the loop-exit capture protocol is centralized in `skills/gotcha/SKILL.md` ("Capture at loop-exit"). `/task` and `/sdlc` reference it and auto-draft a gotcha **only on an objective trigger** (a fix-loop that failed-then-recovered, or the user voicing surprise), routed through gotcha's dedup — never a vibe-gate. `/task` and `/sdlc` also drop a `/gotcha <text>` `.next-action` sentinel when capture is declined; the seam is Stop-hook-backed on all three runtimes (Claude `.claude/settings.json`, Copilot `.github/hooks/`, Codex `.codex/hooks.json` — Codex has a Stop hook with the same `decision:block` contract, shipped by the plugin/`setup.sh`); writers also print an inline `Next:` fallback for when no hook is wired/trusted yet. `/brainstorm` injects area-scoped gotchas at Step 2 (entry), not only at validation.
- **Model cap** — `.claude/project.json` `models.cap` (or the per-run `--model <tier>` flag) is a **ceiling** on sub-agent model tier for the fan-out skills (`/sdlc`, `/brainstorm*`). The fan-out is **Sonnet-first by default** — the Workflows default `model_cap` to `'sonnet'` and the prose dispatch sites say "Sonnet by default"; Opus is an explicit opt-up via `--model opus`. Keep it that way when adding a fan-out dispatch (default Sonnet, not Opus). Canonical contract: `skills/sdlc/templates/models.md`. Prose is the only enforcement surface — each fan-out dispatch resolves the tier (`--model` > `models.cap` > default) and prints `model: <tier> (cap: <cap|none>)` before dispatching; `validate_skills.py` soft-warns if a fan-out skill drops the `models.md` pointer. Adding/rewording a fan-out dispatch means updating both legs (prose, overlays). A second, independent axis exists for `/sdlc` only: the **reviewer-model axis** (`models.code_review` / `--review-model`, default `opus`, canonical contract at `skills/sdlc/templates/models.md`), which selects the adversarial Review→Fix stage's reviewer. The stage is opt-in, permanently — it never runs unless explicitly enabled. `fable` remains a valid, explicit opt-in value (usage-billed since Claude Fable 5's 2026-07-07 promotional-access sunset), never the default. This axis is NOT a value on the `haiku < sonnet < opus` ladder, is NOT subject to the Sonnet-first default, and must NEVER be passed through `capModel()`. Keep the two axes mechanically separate in any future edit. Because `models.cap` cannot bound Axis 2, the review stage's cost is bounded by its **fan-out width** instead: `agents.code_review_lenses` selects which lenses, `agents.code_review_max_lenses` (default `4`) caps how many, applied after circuit-breaker demotion and in list order. When a cap is set and the reviewer outranks it, the stage must say so out loud rather than let the user read `cap: sonnet` next to N Opus agents — a log line only, never a `capModel()` call.

## When modifying skills

- Read the affected skill's `SKILL.md` fully before editing.
- If changing a contract (e.g., where a skill writes files), update the consumers too — grep across `skills/`, `copilot/skills/`, and `README.md`.
- If a skill exists in both `skills/` (canonical) and `copilot/skills/` (override), changes may need to be reflected in both. The Copilot override is a separate file, not a patch.
- Avoid adding Claude-only features to cross-tool skills unless the skill also has a Copilot override.

## Execution model — prose only

Every skill is prose. There is **one** expression of each pipeline stage (the canonical
`skills/<name>/SKILL.md`) plus per-tool overlays where a runtime genuinely differs.

`skills/sdlc/workflows/sdlc-pipeline.workflow.js` — 1,398 lines of JS mirroring the prose —
was **deleted**. It ran only when "ultracode" was explicitly enabled, it could not do
`--resume` or interactive review approval, it carried two features the prose described as real
but marked unimplemented, and the prose↔Workflow sync leg had **no automated guard** (CLAUDE.md
said so outright: "keeping them in sync is on the author"). In the audited session it was
invoked zero times; the Workflow tool *was* called five times and every call passed an inline
ad-hoc script instead. It was the least capable of the three expressions and the most expensive
to maintain. `/brainstorm-deep` carried the last remaining Workflow (205 lines, one fan-out);
it was deleted too, so **nothing in this repo runs a Workflow any more**. Do not add one back:
a Workflow is a second expression of a stage with no automated guard keeping it in sync with
the prose, and every attempt at that here has ended the same way.

**So a stage-contract change is now a two-leg edit:** the canonical prose, then the
Copilot/Codex overlays (which have no Workflow and never did — the prose is all they run).
`validate_skills.py` guards the prose↔overlay parity leg with a soft warning.

### Where the canonical stage prose lives: `skills/sdlc/templates/`

`skills/sdlc/` holds the skill **and** `templates/`, the shared stage bodies that
`/sdlc` and its Copilot/Codex overlays all load. `setup.sh` ships that tree to every
tool root in step 1b (`install_shared_templates()`) and rewrites the citation prefix, so
an overlay opens the same file the canonical skill does — the overlays must **point at
the templates, never inline them**. `scripts/ci/check_install_refs.py` runs in CI and
fails the build if any cited template does not resolve in a fresh install.

Each stage's body lives in **one** template there — `output-verbosity`, `resumption`,
`stage-1.5-sanity-check`, `stage-2-gate`, `stage-2-implement`, `stage-2a/2b/2c`,
`stage-3-evals`, `fix-loop`, `stage-5-validate`, `stage-5.7-review-fix`, `secret-scan`,
`stage-5-skill-repo`, `changed-files-gate`, `convention-grounding`, `envelope-staleness`,
`models`, `state-schema` — and `skills/sdlc/SKILL.md` stays thin per stage: a short
framing paragraph, the gate/skip rule that decides *whether* to run, and a
`**Read skills/sdlc/templates/<x>.md now**` pointer.

Two rules follow, and both are load-bearing:

- **Edit the template, not the skill.** A stage-contract change is one edit in
  `skills/sdlc/templates/` plus the overlays. Copying a stage body into a `SKILL.md`
  re-creates the canonical↔overlay drift the split exists to prevent.
- **The gate goes in the skill, the body goes in the template.** A stage that self-skips
  (no `eval.runner`, review not opted in, no plan target, not a skill repo) must be able to
  decide that *without* opening the template it is skipping. That is where most of the
  saving comes from: a default run never loads `stage-5.7-review-fix.md` at all.

**There was once a second pipeline skill.** `/sdlc` opened a PR; `/sdlc-lite` stopped at
the edge of git. They duplicated every stage, and the lite one deferred to the other's
prose 15 times, so a lite run loaded all 1,069 lines of it. The PR-opening variant was
deleted, what mattered was folded in, and the survivor took the `/sdlc` name back — it
does **no git writes** and hands you a validated tree.

Folded in, each closing a gap that existed on its own: Stage 1 plan parsing (the decompose
gate reads `parse.json` and the lite path had no writer for it), skill-repo mode (this repo
*is* a skill repo), the vendored-skill guard, the soft-stop tier (now in
`changed-files-gate.md`) and four safety rules. Dropped: branch/commit/push/`gh pr create`,
the `pr-create.json` sidecar and `pipeline.skip_review`.

Two flags gate whole templates rather than sections — `--queue` (`queue-mode.md`) and the
review stage's opt-in. Keep it that way: a flag nobody passed should cost nothing.


## When adding a new skill

- Copy the shape of a similar existing skill; don't invent new conventions.
- Add the skill's directory path to `.claude-plugin/marketplace.json` under `plugins[0].skills`.
- Set `metadata.brainstorm-toolkit-applies-to` honestly.
- Update the skills table in `README.md`.

## When adding a sub-agent (`agents/`) — usually: don't

Sub-agent definitions are a **different artifact from skills**, with their own failure mode.
An earlier four-agent set went almost entirely undispatched: every dispatch site named
`subagent_type: general-purpose` and pasted the role prompt in from a template, so the agent
files sat there costing maintenance and buying nothing. The three that survive
(`test-runner`, `e2e-test-runner`, `ux-plan-validator`) are each named at a real dispatch
site — check that before adding a fourth.

**The rule:**

> Create an agent definition **when and only when** you need an enforced `tools:` restriction,
> on a Claude-only agent whose prose has explicitly exempted it from the model-cap axis.
> Otherwise: a role prompt in `templates/` + `subagent_type: general-purpose` + an explicit
> `model:` at the dispatch site.

Frontmatter buys exactly three things nothing else can, and two of them are usually dead here:

| Field | Unique capability | Usually |
|---|---|---|
| `description:` | auto-delegation — Claude picks the agent unprompted | **Dead** — every skill names its agent explicitly, and auto-delegation is unreliable in practice |
| `tools:` | an **enforced** boundary; prose saying "you are read-only" is advisory | **The real win** — verified enforced: a declared allowlist omits Bash/Write entirely |
| `model:` | pins a tier | **Usually hostile** — it bypasses `capModel()` and the `--model` > `models.cap` ladder. Pin at the dispatch site instead, except where a skill has explicitly exempted the site (`/status`'s inline reads) |

Also weigh, before adding one:

- **Cross-tool blindness.** `setup.sh` copies `agents/` for **Claude only**. Copilot and Codex
  have no agent-definition concept, so anything encoded in frontmatter is invisible to two of
  three runtimes.
- **A restart tax.** The agent registry loads at session start, so a new or edited agent file
  does nothing until the session restarts. An inline role prompt takes effect immediately.
- **`tools:` is an allowlist the harness tops up.** Treat it as "no Write/Edit", not as an
  exact set. Command-scoped forms like `Bash(git log:*)` are **not** a documented value here —
  if the agent needs git, it needs plain `Bash`.

If you do add or edit one: `name` must match the filename stem, register it in
`.claude-plugin/marketplace.json` under `plugins[].agents`, and never let the prose claim a
tier or a read-only posture that the frontmatter doesn't enforce. `scripts/validate_skills.py`
checks all of this.

## Testing changes

There is no automated test suite for the skills themselves (they are prompts, not code). Verify manually by:
1. Running `python scripts/validate_skills.py` from the repo root — this covers skills
   **and** `agents/` frontmatter (missing `name`/`description`, a prose model-tier or
   read-only claim the frontmatter doesn't enforce, marketplace registration drift).
2. Running `bash setup.sh --target /tmp/test-repo --tools both` against a scratch repo.
3. Invoking the changed skill in both Claude Code and Copilot when the skill targets both tools.
4. Confirming the skill runs without referencing removed files or broken paths.

For the Python helpers in `scripts/`, run them against the examples or a known input and check output.
