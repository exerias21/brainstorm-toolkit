# AGENTS.md — brainstorm-toolkit

Instructions for AI coding agents (Claude Code, GitHub Copilot, Cursor, Codex, etc.) working in this repo.

## What this repo is

**brainstorm-toolkit** is a cross-tool plugin: a collection of SKILL.md-style slash commands that work in both Claude Code and GitHub Copilot. The design goal is **low token weight** — each skill is a focused, single-purpose file, and skills share a unified AGENTS.md / TASKS.md / project.json contract rather than embedding templates and checklists inline.

## Layout

```
.claude-plugin/         # Plugin + marketplace manifests
skills/<name>/SKILL.md  # Canonical skills (source of truth)
agents/                 # Claude-only sub-agent definitions
scripts/                # Shared helpers (eval-runner.py, check_docker_logs.py)
templates/              # AGENTS.md / TASKS.md / project.json templates for consumer repos
examples/               # GOTCHAS.md.example
setup.sh                # Installer — copies skills into a target repo for Claude and/or Copilot
README.md               # User-facing docs
```

## Skill authoring rules

1. **Frontmatter must include `applies-to:`** — an array of `claude`, `copilot`, or both. Example:
   ```yaml
   ---
   name: status
   description: ...
   applies-to: [claude, copilot]
   ---
   ```
   `setup.sh` uses this to decide whether the skill is copied to `.github/prompts/` (Copilot) in addition to `.claude/skills/` (Claude).
2. **Claude-only features** (Plan mode, sub-agents via the Agent tool, hooks) → mark `applies-to: [claude]` only.
3. **Keep each SKILL.md tight.** Target ceilings: small utility skills ≤100 lines, larger orchestration skills ≤250 lines. If a skill grows beyond this, split it or move embedded content into `templates/`.
4. **No inline templates or long checklists.** Reference `templates/*.template` files instead.
5. **Graceful skip on missing config** — read `.claude/project.json` keys with fallbacks; skills must work with an empty or missing `project.json`.

## Unified contracts

- **`AGENTS.md`** — repo-wide agent instructions. Consumer repos symlink (POSIX) or copy `CLAUDE.md` → `AGENTS.md`.
- **`TASKS.md`** — markdown checkbox list at repo root; the portable task tracker shared by Claude's `TaskCreate` mirror and Copilot's TODO reading.
- **`GOTCHAS.md`** — project-specific pitfalls; consulted by `/gotcha` and the sanity-check stage of `/sdlc`.
- **`.claude/project.json`** — optional per-project config (test commands, eval runner, modules list); every key is optional, missing keys are skipped.

## When modifying skills

- Read the affected skill's `SKILL.md` fully before editing.
- If changing a contract (e.g., where a skill writes files), update the consumers too — grep across `skills/` and `README.md`.
- Avoid adding Claude-only features to cross-tool skills unless you also gate them behind an "if running under Claude" check.

## When adding a new skill

- Copy the shape of a similar existing skill; don't invent new conventions.
- Add the skill's directory path to `.claude-plugin/marketplace.json` under `plugins[0].skills`.
- Set `applies-to:` honestly.
- Update the skills table in `README.md`.

## Testing changes

There is no automated test suite for the skills themselves (they are prompts, not code). Verify manually by:
1. Running `bash setup.sh --target /tmp/test-repo --tools both` against a scratch repo.
2. Invoking the changed skill in both Claude Code and (if `applies-to` includes `copilot`) Copilot.
3. Confirming the skill runs without referencing removed files or broken paths.

For the Python helpers in `scripts/`, run them against the examples or a known input and check output.
