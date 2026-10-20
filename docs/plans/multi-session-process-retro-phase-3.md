## Brainstorm Result: Multi-session process retro, Phase 3 (question advisor and ask-gate)

### Direction
Ship Phase 3 of `docs/plans/multi-session-process-retro.md`, with the decisions recorded in
DECISIONS.md on 2026-10-19 applied: the advisor's tier is `models.question_advisor` (default
Sonnet, capped like every fan-out role, no exemption), and the gate is a shell hook under
`scripts/hooks/`, not JavaScript. Everything is opt-in: with no config a repo sees no change.

Before the orchestrator asks the operator anything, a read-only advisor reviews its draft
questions: it drops a question already answered by the decision log, a ticked `TASKS.md` row or
the code; measures instead of asking where a configured "measure first" source can answer; fixes
stale premises; and rewrites the rest in plain words with measured numbers, recommendation first,
at most 4. The orchestrator then records the approved questions with a script that hashes them,
and asks only those. On Claude, an opt-in PreToolUse hook on `AskUserQuestion` denies a question
whose hash is not in a fresh approval file. A consumer measured the payoff on its first run: of
three drafted operator questions, two were dropped and only one reached the operator.

Version stays 0.18.25 (Phases 1–2 are uncommitted in the same tree).

### Conventions & reuse
- Follow: agent definition with an enforced `tools:` allowlist and no Write/Bash —
  `agents/plan-conformance-validator.md` (`tools: Read, Grep, Glob`). Register it in
  `.claude-plugin/marketplace.json` `plugins[0].agents`.
- Follow: opt-in PreToolUse hook that is inert unless `project.json` opts in, resolves Python via
  `_pyresolve.sh`, and warns visibly when no interpreter resolves — `scripts/hooks/enforce-model-cap.sh`.
  Wire it in `hooks/hooks.json` and in `setup.sh` the way `install_model_cap_hook` does
  (`setup.sh` "Install the PreToolUse(Agent) model-cap hook").
- Follow: hook regression cases in `scripts/ci/test-hooks.sh` (scratch project dir, stdin JSON,
  assert on stdout), like the enforce-model-cap matrix.
- Follow: a new fan-out role gets a `models.<role>` key in `templates/project.json.example` with a
  `_comment`, and a row in `skills/sdlc/templates/models.md`'s role table.
- Follow: a repo-root helper script with subcommands and JSON output — `scripts/record-decision.sh`,
  `scripts/close-tasks.sh`.
- Reuse: `scripts/sync-global.sh` already copies `scripts/` wholesale and reads `hooks/hooks.json`
  at run time, so it needs no edit (never list hook scripts in it).

### Implementation Steps

#### Phase 3 — Question advisor and ask-gate
1. **Approval helper.** New `scripts/question-advice.sh` with two subcommands, one shared
   normalisation (trim, collapse whitespace, lowercase) and sha256 of each question's text:
   `approve` reads a JSON list of question strings (or an `AskUserQuestion` `questions` array) on
   stdin and writes `.claude/pipeline/_advice/approved.json` = `{written_at, hashes[]}`; `check`
   reads a PreToolUse payload on stdin and prints `allow` or `deny: <reason>`, where deny means a
   question hash is missing or `written_at` is older than 45 minutes. Python through `scripts/py.sh`
   or the hook resolver; never a bare `python3`.
   Files: `scripts/question-advice.sh`
2. **Advisor agent.** New `agents/question-advisor.md`, `tools: Read, Grep, Glob` (enforced
   read-only; it writes nothing — the orchestrator runs `approve`). Its prompt: given draft
   questions, `DECISIONS.md`, ticked `TASKS.md` rows and the `measure_first` sources, return JSON
   `{dropped: [{question, reason, answer}], ask: [{question, header, options}]}` with at most 4 in
   `ask`, each in plain words with measured numbers and the recommended option first. No `model:`
   pin; the dispatch site passes `models.question_advisor`. Register it in marketplace.json.
   Files: `agents/question-advisor.md`, `.claude-plugin/marketplace.json`
3. **Operator-gate template.** New `skills/sdlc/templates/operator-gate.md`: the protocol for the
   orchestrator (draft → dispatch the advisor at `models.question_advisor`, printing
   `model: question_advisor=<tier> (cap: <cap|none>)` → `bash scripts/question-advice.sh approve`
   with the `ask` list → ask exactly those texts → report the dropped ones with their answers in one
   line each). Sub-agents never ask the operator; they return draft questions to the orchestrator.
   Works without hooks (it is the whole control on Copilot/Codex, where the advisor pass runs
   inline).
   Files: `skills/sdlc/templates/operator-gate.md`
4. **Gates in the skills.** `/sdlc` and `/brainstorm` gain one gate line each: when
   `pipeline.question_advisor.enabled` is `true`, read `skills/sdlc/templates/operator-gate.md` before
   asking the operator anything; otherwise never open it. Mirror in the Copilot and Codex `/sdlc`
   overlays and the Copilot `/brainstorm` overlay (inline advisor pass there).
   Files: `skills/sdlc/SKILL.md`, `skills/brainstorm/SKILL.md`, `copilot/skills/sdlc/SKILL.md`,
   `codex/skills/sdlc/SKILL.md`, `copilot/skills/brainstorm/SKILL.md`
5. **Ask-gate hook.** New `scripts/hooks/ask-gate.sh`, PreToolUse matcher `AskUserQuestion`. Inert
   (no output) unless `pipeline.question_advisor.gate` is `true`. Allows when the file flag
   `.claude/pipeline/_advice/off` exists (an env var cannot be set in a running session). Otherwise
   runs `question-advice.sh check` and on deny emits a PreToolUse `permissionDecision: "deny"` whose
   reason points at `operator-gate.md`. Malformed input or no interpreter never blocks; no
   interpreter with the gate opted in emits a visible `systemMessage`. Wire it in `hooks/hooks.json`
   (and its description) and in `setup.sh` next to the model-cap hook.
   Files: `scripts/hooks/ask-gate.sh`, `hooks/hooks.json`, `setup.sh`
6. **Config and model role.** `templates/project.json.example`: `models.question_advisor`
   (`"sonnet"`) with `_comment`, and `pipeline.question_advisor` = `{enabled: false, gate: false,
   measure_first: []}` with a `_comment` (example `measure_first` entry: a command or file the advisor
   reads before asking). `skills/sdlc/templates/models.md` role-table row. `docs/CONFIG.md` rows.
   Files: `templates/project.json.example`, `skills/sdlc/templates/models.md`, `docs/CONFIG.md`
7. **Tests and docs.** `scripts/ci/test-hooks.sh` cases: inert without config; allow with a fresh
   approval; deny an unapproved question; deny a stale approval; allow under the off flag; malformed
   stdin allows; `approve` then `check` round-trip with whitespace/case differences. `README.md`
   agents/hooks mention. Run `bash scripts/py.sh scripts/validate_skills.py`,
   `bash scripts/py.sh scripts/ci/check_contracts.py`, `bash scripts/ci/test-hooks.sh`.
   Files: `scripts/ci/test-hooks.sh`, `README.md`

8. **Binding corrections from the sanity check** (apply across steps 1–7):
   - Hashing and normalisation live in Python (`hashlib`, UTF-8, BOM stripped, all whitespace
     including `\r` collapsed), never `sha256sum`; both subcommands resolve Python through
     `scripts/hooks/_pyresolve.sh` (`hooks_resolve_python`). `written_at` is epoch seconds.
   - `measure_first` entries are files the advisor reads, or commands **the orchestrator** runs
     before dispatch and passes in as output — the advisor has no Bash. `operator-gate.md` says so.
   - The advisor reads ticked rows by Grep for `- [x]` in `TASKS.md`, and is told planned work does
     not exist yet (never drop a question as answered by code that is only planned). Its body never
     says "read-only" in prose beyond what `tools:` enforces. The dispatch names
     `brainstorm-toolkit:question-advisor` (or bare `question-advisor` when vendored) and passes an
     explicit `model`, printing the usual `model: <tier> (cap: <cap|none>)` line.
   - `setup.sh`: `install_pretooluse_hook_claude` is hard-coded to `enforce-model-cap.sh` / matcher
     `Agent`; parameterise it (script, matcher, label) or add a sibling, add the `[hooks]` echo line,
     and keep the timeout (10) equal to `hooks/hooks.json`. Run `bash scripts/ci/setup-roundtrip.sh`.
   - `ask-gate.sh` calls the helper as `bash "<dir>/../question-advice.sh" check`, emits deny as
     `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"..."}}`,
     and fails open (no output) on any error.
   - Copilot/Codex runtime notes (inline advisor pass, no hook) go in the overlays, not in
     `operator-gate.md`. The gate line in skills avoids the literal `AskUserQuestion` (it trips
     `validate_skills.py`'s Claude-only pattern for Copilot-targeted skills) — say "asking the
     operator". `operator-gate.md` and README state the limit: the gate covers the question tool
     only, not a question typed as plain text, and the off flag bypasses it.
   - Extra tests: multi-question payload with one unapproved (deny), empty `hashes`, missing
     `_advice` dir, future `written_at`, CRLF/trailing-`\r` text, opted-in with no interpreter
     (visible `systemMessage`).
   - Docs: `docs/CONFIG.md` hook-to-keys table row for `ask-gate.sh`; README hook and agent lists;
     AGENTS.md's agent and policy-hook prose updated without a numeric count (the no-cardinality
     check); add `operator-gate` to AGENTS.md's template list. New keys are optional, so no
     `migrate-project-json` entry.

### Cross-Module Touchpoints
- `scripts/sync-global.sh`: no edit (copies `scripts/`, reads `hooks.json`); CI's
  `shell-install-parity` check covers it.
- `scripts/hooks/enforce-model-cap.sh` sees the advisor dispatch like any other Agent call; the
  dispatch passes `model`, so nothing changes there.
- Copilot and Codex have no PreToolUse on a question tool; `operator-gate.md` is the whole control.

### Open Questions
- None; advisor tier and hook language are recorded in DECISIONS.md.

### Appendix: Alternatives Considered
- **Advisor writes `approved.json` itself.** Rejected: needs Write/Bash on the agent and an agent
  computing hashes the hook must reproduce byte for byte; a script both sides call cannot drift.
- **Opus pinned in the agent frontmatter.** Rejected per DECISIONS.md (Sonnet default, capped).
- **`hooks/ask-gate.js`.** Rejected per DECISIONS.md (shell hook convention, test-hooks.sh coverage).
- **Env-var off switch.** Rejected: an env var cannot be set inside a running session; a file flag can.
