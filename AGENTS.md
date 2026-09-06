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

**Per-tool overlays replace the canonical `SKILL.md`, not the canonical resources.** `setup.sh`
installs the overlay's files and then fills in any of `templates/`, `references/`, `scripts/`, `assets/`
the overlay does not carry from the canonical skill (`install_overlay`). So an overlay cites the same
`skills/<name>/templates/<file>` paths the canonical does and never inlines a body; it ships its own
copy of a directory only when the content must genuinely differ for that tool.

### Rationale prose — two kinds, one of which ships

The house style attaches a reason to most rules. That is deliberate and it stays.
But two very different things wear the same coat, and only one of them earns a
place in a file that loads on every run:

- **Failure-mode rationale — KEEP.** It names what the *model* will do wrong and
  why, and it is the enforcement. "You will be tempted to run the tests inline —
  shell traffic was ~53% of main-thread tokens on an audited run"; "this is the
  step that keeps getting skipped, which leaves the loop dead"; "guessing here
  compounds through the entire `/sdlc` run"; "a dispatch with no `model` bypasses
  the cap with zero log line". Strip the reason from any of these and the rule
  reads as a preference the model overrides the first time it is inconvenient.
- **Design-history rationale — MOVE to `docs/`.** It records what the design used
  to be or why a maintainer chose it. "This replaces the former Stages 5, 5.5 and
  5.6"; "it now coexists instead of racing"; "the dogfood showed exactly this";
  the `/sdlc-lite` merge changelog; the Workflow autopsy. Every one of these is
  true, useful to a maintainer, and paid for on every consumer run. `docs/` is
  not shipped by `setup.sh`, so a citation there costs nothing.

**The test:** does the sentence change what the model *does on this run*, or does
it explain to a person why the file looks like this? The second belongs in
`docs/LOOP-HYGIENE.md`, `docs/MODEL-AXES.md`, `docs/PROSE-FIDELITY.md`,
`docs/CONFIG.md`, or `docs/CONVENTIONS.md` (Migration policy) — all of which
already exist for exactly this.

**Two corollaries, both already violated at least once:**

- **A skill must not restate a template it also tells the model to read now.**
  If the line says `**Read skills/sdlc/templates/<x>.md now**`, the paragraph
  after it is a gate, not a summary. This is the same "gate in the skill, body
  in the template" rule stated from the reader's side.
- **A runtime note addressed to Copilot/Codex belongs in the Copilot/Codex
  overlay, not in a shared template.** A shared template is read by all three
  runtimes; a "no sub-agent seam?" callout in one is dead text on Claude and
  costs on every run. The overlay `SKILL.md` is the only file guaranteed loaded
  on the runtime that needs it — `--resume` can skip any given template.

**What is NOT a violation:** the same rule stated in several skills that never
load each other (`Sonnet by default` appears across ~20 files). Progressive
disclosure means a rule stated once in a file nobody else opens propagates
nowhere. Each of those sites should be a one-line pointer to
`skills/sdlc/templates/models.md`, not a re-derivation of the contract — but the
repetition itself is required, not redundant.

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
2. **Claude-only features** (Plan mode, sub-agents via the Agent tool, hooks) → mark the skill `claude` only in `skills/`. If the skill is still useful on Copilot in a simplified form, create a Copilot-optimized override in `copilot/skills/<name>/SKILL.md` (see rule 9).
3. **Keep each SKILL.md tight — and know which ceiling you are under.** Two
   different numbers get cited as "the limit" and they are not the same rule:

   - **Upstream (Anthropic / the open Agent Skills spec): 500 lines.** A hard
     ceiling. Nothing in this repo is close to it.
   - **This repo's house rule: ≤100 lines for a utility skill, ≤300 for an
     orchestration skill.** Stricter than upstream on purpose, because a skill
     here ships to three runtimes and its stage bodies already have a home in
     `templates/`. Treat it as a soft target with real slack: a few lines over
     is not worth a restructure, and buying a line back is only worth it when
     the line was not earning its place anyway. Past ~300, ask whether a stage
     body belongs in `templates/` instead — that is the actual signal, not the
     count.

   Cite the house rule as the house rule. Do not justify it as "Anthropic's
   guidance" — the upstream number is looser, and the mismatch has been used to
   argue both directions.

   Three named exceptions, decided and not reopened each time they are re-measured:

   | Skill | Ceiling | Why |
   |---|---|---|
   | `sdlc` | ~330 lines | Orchestration surface; every stage body is already in `templates/`. What remains is gate + contract, and it is 15 stages' worth. |
   | `brainstorm` | ~320 lines | A conversational flow; splitting mid-flow costs more in comprehension than it saves in tokens. Grew deliberately when the question-asking ceiling was removed — an interview that stops early is the expensive failure here. |
   | `code-tour` | no line ceiling | Its prose **is** the product — the fabrication warnings and the "what bad output looks like" rubric are the output spec, not a wrapper around a template. Judge it on duplication, not length. |

   A skill over its ceiling without an entry in that table is a finding.
   **Adding a row is a deliberate decision, not a way to close the finding.**

4. **Frontmatter `description` — a hard budget, because it is always resident.**
   Every skill's name + description loads into every session on every turn,
   whether or not the skill ever fires, on all three runtimes. Codex caps the
   whole discovery listing at **8,000 characters** (or 2% of context) and
   silently shortens descriptions from the end — dropping skills entirely when
   over. Claude Code truncates each description at 1,536 chars and caps the
   listing at ~1% of context. `setup.sh` installs the full 13-skill set, so this
   repo's descriptions are measured against those ceilings **as a set**.

   - Target **≤550 characters** per description; 600 is the ceiling.
   - Keep the whole set under **7,500 characters** (measured, not estimated —
     parse the frontmatter, don't `grep -c`).
   - **Front-load trigger keywords in the first ~15 words.** Codex truncates
     from the end; a description whose distinctive phrases are in its last
     sentence loses them first, silently.
   - Explanation, neighbour-routing and "what this skill is NOT" belong in the
     body, never the description. `gotcha` (464 chars) is the reference shape:
     what it does + one clear when.
5. **No inline templates or long checklists.** Reference `templates/*.template` files instead.
6. **Graceful skip on missing config** — read `.claude/project.json` keys with fallbacks; skills must work with an empty or missing `project.json`.
7. **Copilot uses Agent Skills, not prompt-file shims.** Consumer repos should receive `.github/skills/<name>/SKILL.md`, including any bundled resources referenced by the skill.
8. **Claude helper agents stay in `.claude/agents/`.** VS Code can discover Claude-format agents there, so this repo does not maintain a duplicate `.github/agents/` tree for the current Claude-only helper agents.
9. **Copilot overlay pattern.** `copilot/skills/<name>/SKILL.md` overrides the canonical `skills/<name>/SKILL.md` for Copilot distribution. Use this when a skill needs Claude-specific features (Plan mode, agents) in its canonical version but can still provide value as a simplified Copilot slash command. `setup.sh` prefers the override when it exists; otherwise falls through to the canonical version. Overrides must set `metadata.brainstorm-toolkit-applies-to: copilot` and pass `validate_skills.py` independently.
10. **Portable frontmatter subset.** The Agent Skills spec GitHub Copilot and OpenAI Codex document is `name`, `description`, `license`, `metadata`, `compatibility`, `allowed-tools` only — a strict consumer hard-errors on any other key. Claude-only keys (`argument-hint`, `disable-model-invocation`, ...) may appear on the canonical `skills/<name>/SKILL.md` (the Claude install source); `setup.sh` strips them for the `.github/skills/` and `.agents/skills/` installs. `copilot/skills/<name>/SKILL.md` and `codex/skills/<name>/SKILL.md` overlays must never declare them by hand — `check_contracts.py`'s `portable-frontmatter` check enforces this.

## Unified contracts

- **`AGENTS.md`** — repo-wide agent instructions. Consumer repos symlink (POSIX) or copy `CLAUDE.md` → `AGENTS.md`.
- **`TASKS.md`** — markdown checkbox list at repo root; the portable, durable task tracker. It is the **only** cross-tool backlog: `/sdlc-status`, the `--queue` loop and the Stop hooks all read it, and it survives the session (`/repo-health` does not read it today). Claude Code's native task list (`TaskCreate`/`TaskUpdate`) is a **separate, session-scoped progress indicator** — `/task` mirrors its one item and `/sdlc` mirrors its stage list, both Claude-only and both skipped silently elsewhere. Never let a decision depend on the native list, and never treat it as a substitute for a `TASKS.md` row: it is a view, not a record.
- **`GOTCHAS.md`** — project-specific pitfalls; consulted by `/gotcha` and the sanity-check stage of `/sdlc`.
- **`.claude/project.json`** — optional per-project config (test commands, eval runner, modules list); every key is optional, missing keys are skipped.
- **Gotcha flywheel** — the loop-exit capture protocol is centralized in `skills/gotcha/SKILL.md` ("Capture at loop-exit"). `/task` and `/sdlc` auto-draft a gotcha **only on an objective trigger** (a fix-loop that failed-then-recovered, or the user voicing surprise), routed through gotcha's dedup — never a vibe-gate. When capture is declined, both drop a `/gotcha <text>` `.next-action` sentinel; the seam is Stop-hook-backed on all three runtimes, with an inline `Next:` fallback for when no hook is wired/trusted yet — full contract at `docs/SEAM.md` (also the home of the separate `stop-gate.sh` test-rerun hook and its mutual-exclusion rule with the sentinel). `/brainstorm` injects area-scoped gotchas at Step 2 (entry), not only at validation.
- **Model tiers — two independent axes, canonical contract in
  `skills/sdlc/templates/models.md`.** Read it before touching any dispatch
  site; do not restate it here.
  - **Axis 1 (fan-out tier):** `--model <tier>` > `.claude/project.json`
    `models.cap` > default. `models.cap` is a **ceiling, never a target**. The
    fan-out is **Sonnet-first by default** everywhere — Opus is an explicit
    opt-up. Keep it that way when adding a dispatch.
  - **Axis 2 (reviewer model, `/sdlc` only):** `models.code_review` /
    `--review-model`, default `opus`, stage permanently opt-in. **Not on the
    haiku<sonnet<opus ladder; `models.cap` never lowers it.** Its cost is
    bounded by fan-out width (`agents.code_review_lenses`,
    `agents.code_review_max_lenses`, default 4) instead. An explicit
    `models.code_review` is always the dispatched value — a reviewer that lands
    on the implementer's tier marks the run `independence: degraded` rather
    than being bumped to a higher tier.
  - **Keep the two axes mechanically separate in any future edit.** Prose is
    the default enforcement surface: each dispatch resolves its tier and
    prints `model: <tier> (cap: <cap|none>)` before dispatching. The opt-in
    `pipeline.enforce_cap` PreToolUse hook (`scripts/hooks/enforce-model-cap.sh`,
    Claude only) makes Axis 1 deterministic by rewriting an over-cap dispatch
    `model`, exempting `review:`-prefixed dispatches (Axis 2).
  - Adding or rewording a fan-out dispatch is a **two-leg edit**: canonical
    prose, then the Copilot/Codex overlays. `validate_skills.py` soft-warns if a
    fan-out skill drops the `models.md` pointer.

## When modifying skills

- Read the affected skill's `SKILL.md` fully before editing.
- If changing a contract (e.g., where a skill writes files), update the consumers too — grep across `skills/`, `copilot/skills/`, and `README.md`.
- If a skill exists in both `skills/` (canonical) and `copilot/skills/` (override), changes may need to be reflected in both. The Copilot override is a separate file, not a patch.
- Avoid adding Claude-only features to cross-tool skills unless the skill also has a Copilot override.

### Renaming or deleting a skill — never `s|/old|/new|g`

A global substitution rewrites every sentence that *talks about* the name, not just the
name. It has silently corrupted this repo **six times**: a `FLOW.md` diagram showing `/sdlc`
doing "branch → commit → push → PR" (it does no git writes), `` `sdlc`, `sdlc`, or `task` ``,
and three table rows collapsing into one command are all artifacts of it. Nothing catches
this — `validate_skills.py` and `check_install_refs.py` only prove *paths resolve*.

Grep first, read every hit, edit by hand. Attribution sentences ("absorbed from the former
X", "replaces X") must keep the OLD name — that is the whole point of the sentence. Then run
two checks: one for the **same command named twice in one sentence** (the shape of a collapsed
pair), and one for the **fact the rename invalidated** — after the pipeline merge that was
`grep -rn "opens a PR\|touches git history"`, which found wrong-fact prose no token check
could see. Both commands, with the six case studies, are written out under "Migration policy" in
`docs/CONVENTIONS.md`.

## Execution model — prose only

Every skill is prose. There is **one** expression of each pipeline stage (the canonical
`skills/<name>/SKILL.md`) plus per-tool overlays where a runtime genuinely differs.

**Nothing in this repo runs a Workflow.** The one that existed (`sdlc-pipeline.workflow.js`,
1,398 lines mirroring the prose, plus a smaller one in `/brainstorm-deep`) was deleted because
the prose↔Workflow sync leg had no automated guard and drifted. Do not add one back for the
same reason — see `docs/PROSE-FIDELITY.md` for the full case history.

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

**`/sdlc` absorbed the former `/sdlc-lite`** — the two duplicated every stage, so keeping both
cost more than the merge did. The survivor took the `/sdlc` name, does **no git writes**, and
hands you a validated tree; see `docs/FLOW.md` for what each side of the merge contributed.

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
(`test-runner`, `e2e-test-runner`, `plan-conformance-validator`) are each named at a real
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
| `model:` | pins a default tier | **A default, not an override** — since **v2.1.251** the dispatch site's per-invocation `model` outranks frontmatter (order: per-invocation > frontmatter > `CLAUDE_CODE_SUBAGENT_MODEL` > session). So it does NOT bypass the ladder. Still prefer pinning at the dispatch site — that is where the `--model` > `models.cap` resolution is printed and auditable — but a frontmatter tier is a safe floor for an agent that must never run hot (`test-runner` pins `haiku`) |

Also weigh, before adding one:

- **Cross-tool blindness.** `setup.sh` copies `agents/` for **Claude only**. Copilot and Codex
  have no agent-definition concept, so anything encoded in frontmatter is invisible to two of
  three runtimes.
- **Restart, but only sometimes.** Claude Code *watches* `.claude/agents/` and picks up an
  added or edited file within seconds, no restart needed. Three cases still need one, and the
  first is the one that bites a consumer: creating a scope's **first** agent file in a **new**
  `agents/` directory (i.e. a fresh `setup.sh` install), an agents dir under `--add-dir`, and a
  session started with `--disable-slash-commands`. Editing an existing agent is live.
- **`tools:` is an allowlist the harness tops up.** Treat it as "no Write/Edit", not as an
  exact set. Accepts a comma- or space-separated string or a YAML list. Command-scoped forms
  like `Bash(git log:*)` are **not** a documented value here — if the agent needs git, it needs
  plain `Bash`. The one documented scoped form is `Agent(type-a, type-b)`, restricting which
  subagents may be spawned. A misspelled tool name is **silently dropped**; if every entry
  resolves to nothing the dispatch fails outright with "would be spawned with zero tools".
- **Plugin agents ignore three fields.** `hooks`, `mcpServers` and `permissionMode` are dropped
  when an agent loads from a plugin — which is how this repo ships. Don't encode behaviour in
  them. Plugin agents are addressed `brainstorm-toolkit:<name>`; the bare name works only for a
  **vendored** copy (a project agent under `.claude/agents/`), which is why the dispatch sites
  say "or bare `<name>` when vendored".

**The one standing exception, recorded rather than hidden:** `e2e-test-runner` declares no
`tools:` and no `model:`, so by the rule above it earns nothing and should be an inline role
prompt. It needs the full tool set to run a browser suite and apply fixes, so there is no
boundary to enforce. It is kept because it is dispatched by name at two real sites and its
prompt is long enough to be worth a file — but it is the exception, not the pattern. A fourth
agent without a `tools:` restriction should be an inline role prompt instead;
`scripts/validate_skills.py` warns on one.

If you do add or edit one: `name` must match the filename stem, register it in
`.claude-plugin/marketplace.json` under `plugins[].agents`, and never let the prose claim a
tier or a read-only posture that the frontmatter doesn't enforce. `scripts/validate_skills.py`
checks all of this.

## Testing changes

This repo runs three tiers of testing, cheapest first — see `docs/EVALS.md`: static
prose/contract checks (below, free, every push), `scripts/eval-runner.py`'s fixture-based
pytest evals, and `scripts/ci/skill-eval.py`'s headless outcome evals on a fixture repo
(costs real money — nightly/on-demand only, never per push). Verify manually by:
1. Running `python scripts/validate_skills.py` from the repo root — this covers skills
   **and** `agents/` frontmatter (missing `name`/`description`, a prose model-tier or
   read-only claim the frontmatter doesn't enforce, marketplace registration drift).
2. Running `python scripts/ci/check_contracts.py` — proves the prose and the config
   agree: every `project.json` key a skill names exists in
   `templates/project.json.example`, every repo-path citation resolves, no forbidden
   (rename-invalidated) phrase survives, and no sentence names the same command twice.
   `--self-test` exercises the four checks against a synthetic tree.
3. Running `bash scripts/ci/test-hooks.sh` — the regression harness for the hooks that make
   policy deterministic instead of prose-enforced (`scripts/hooks/enforce-model-cap.sh`,
   `scripts/hooks/stop-gate.sh`): scratch project dirs, sample stdin JSON, assertions on
   stdout. Exits 1 on the first failing case.
4. Running `bash setup.sh --target /tmp/test-repo --tools both` against a scratch repo.
5. Invoking the changed skill in both Claude Code and Copilot when the skill targets both tools.
6. Confirming the skill runs without referencing removed files or broken paths.

For the Python helpers in `scripts/`, run them against the examples or a known input and check output.
