# Flow: brainstorm-toolkit in GitHub Copilot (VS Code)

End-to-end user journey for GitHub Copilot users working in VS Code agent mode or the Copilot CLI. Copilot's [Agent Skills](https://code.visualstudio.com/docs/copilot/customization/agent-skills) support (GA January 2026) makes our SKILL.md files first-class citizens.

## Install

**Option A — `gh skill install`** (GitHub CLI v2.90.0+, April 2026):
```bash
gh skill install <this-repo-url> --agent copilot
```
This writes skills into `.github/skills/<name>/` with tracking metadata.

**Option B — `setup.sh`** (works today from a local clone):
```bash
git clone <this-repo-url> ~/brainstorm-toolkit
cd /path/to/your-repo
bash ~/brainstorm-toolkit/setup.sh --target . --tools copilot
```

After install you have:
- `.github/skills/<name>/SKILL.md` for every cross-tool skill, including **sequential Copilot overlays** for `/sdlc`, `/dead-code-review`, `/brainstorm-team`, `/brainstorm` (see "Overlay semantics" below)
- `AGENTS.md` + `CLAUDE.md` at repo root (Copilot reads AGENTS.md natively)
- `TASKS.md` at repo root
- `scripts/eval-runner.py`, `scripts/check_docker_logs.py` — invoked by skills via terminal
- `.claude/project.json.example` (rename to `.claude/project.json`; Copilot skills read it too)

## VS Code settings

Copilot scans `.github/skills/`, `.claude/skills/`, and `.agents/skills/` **by default**. You can verify or extend with:

```json
// .vscode/settings.json
{
  "chat.agentSkillsLocations": {
    ".github/skills/**": true,
    ".claude/skills/**": true
  },
  "chat.useCustomizationsInParentRepositories": true
}
```

Run `/skills` in the VS Code chat panel to open the Configure Skills menu and verify what Copilot sees.

## Daily inner loop

```
   /repo-onboarding        ← once, to generate AGENTS.md + project.json + GOTCHAS.md
        │
        ▼
   ┌─ Small bounded ask ──────────────────┐
   │  /task "add formatPhone util"        │
   │  → TDD loop, 1 row in TASKS.md       │
   └──────────────────────────────────────┘
        or
   ┌─ Feature-sized ask ──────────────────┐
   │  /brainstorm    ← sequential walkthrough (Copilot overlay)
   │  → plans/brainstorm-<slug>.md        │
   │  → /sdlc plans/brainstorm-<slug>.md  ← sequential pipeline (Copilot overlay)
   └──────────────────────────────────────┘

   /status    — any time
   /gotcha    — when you discover a project-specific pitfall
```

## Skills available

| Skill | Availability | Notes |
|---|---|---|
| `/brainstorm` | Yes (sequential overlay) | No plan-mode break; linear walkthrough |
| `/task` | Yes | Identical to Claude version |
| `/status` | Yes | Identical |
| `/repo-onboarding` | Yes | Identical |
| `/test-check` | Yes | Identical — invokes configured test runners |
| `/gotcha` | Yes | Identical |
| `/eval-harness` | Yes | Invokes `scripts/eval-runner.py` |
| `/flowsim` | Yes | Cross-tool by design; reads plan + source + eval results |
| `/sdlc` | Yes (sequential overlay) | No parallel agents; linear plan→implement→test→PR |
| `/dead-code-review` | Yes (sequential overlay) | 6 sequential phases instead of 6 parallel Opus agents |
| `/brainstorm-team` | Yes (sequential overlay) | 5 research passes done in sequence |
| `/data-source-pattern` | Yes | Pattern guide, reads the same way |
| `/logging-conventions` | Yes | Reference guide; identical content |

## Overlay semantics

When a skill has a `copilot/skills/<name>/SKILL.md` overlay in the plugin repo, `setup.sh` installs **the overlay** to `.github/skills/<name>/` instead of the canonical. Overlays exist for skills whose canonical version depends on Claude-only primitives (Plan mode, the Agent tool, sub-agent spawning). The sequential versions are useful — just slower and lower-parallelism than the Claude originals.

When Copilot's VS Code agent mode gains parallel sub-agents (the Copilot CLI already has `/fleet`), these overlays can be upgraded in a future release.

## Cloud agent (github.com) specifics

Copilot's cloud agent (invoked via `@copilot` in issues/PRs or the agents panel) reads skills from `.github/skills/` in the repo at the time the task starts. Unique capabilities:

- **Playwright MCP built in** — the cloud agent has a browser via Playwright MCP server (enabled by default since July 2025). `/flowsim` and any future `/usersim` skill can use it without extra setup.
- **Runs in GitHub Actions** — ephemeral environment, scoped to one repo, one branch per task.
- **`allowed-tools` frontmatter respected** — a skill that needs shell access needs explicit consent.

For VS Code agent mode, Playwright MCP must be configured manually. For the Copilot CLI, shell access is available and skills can invoke `npx playwright test` directly.

## When to set `disable-model-invocation: true`

Some skills should be **manual-only** — don't auto-load on semantic match, only run when the user explicitly types `/skill-name`. Examples:

- Skills with side effects (deploy, push, send-notification)
- Skills with long runtimes (a full `/dead-code-review` walk)
- Skills you want users to opt into consciously

Add to the skill's frontmatter:
```yaml
disable-model-invocation: true
```
The skill still appears in the `/` slash menu (because `user-invocable` stays true) but Copilot won't pull it into context automatically.

Our `/brainstorm` overlay uses this — brainstorming is an intentional decision, not something you want the agent doing unprompted.

## Tips

- **Copilot CLI has `/fleet`** for parallel agents today (VS Code agent mode doesn't yet). If you live in the CLI, the sequential overlays can be augmented with `/fleet` manually for the multi-phase skills.
- **`gh skill search`** lets you find community skills. Our repo can be installed the same way.
- **The `/skills` menu shows what's loaded.** If a skill doesn't appear, check the frontmatter (`name` must match directory name, `description` must be present, file must be under a scanned location).
- **TASKS.md is the portable task source.** Copilot doesn't have Claude's native Tasks — the markdown IS the state.

## See also

- [FLOW-CLAUDE-CODE.md](FLOW-CLAUDE-CODE.md) — same toolkit, Claude Code flow
- [../AGENTS.md](../AGENTS.md) — skill authoring rules for contributors
- [../README.md](../README.md) — install + skills table
- [VS Code Agent Skills docs](https://code.visualstudio.com/docs/copilot/customization/agent-skills)
- [GitHub Copilot `gh skill` CLI](https://github.blog/changelog/2026-04-16-manage-agent-skills-with-github-cli/)
