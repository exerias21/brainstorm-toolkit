# Flow: brainstorm-toolkit in OpenAI Codex CLI

End-to-end user journey for Codex CLI users. Codex CLI's [Agent Skills](https://platform.openai.com/docs/guides/codex-cli) protocol (2026 spec) makes our `SKILL.md` files first-class — much like Copilot's. The toolkit ships a Codex-specific overlay tree at `codex/skills/` for skills whose canonical version uses Claude-only primitives.

## Install

**`setup.sh` (works today from a local clone)**:

```bash
git clone <this-repo-url> ~/brainstorm-toolkit
cd /path/to/your-repo
bash ~/brainstorm-toolkit/setup.sh --target . --tools codex
```

Or install for every supported agent in one go:

```bash
bash ~/brainstorm-toolkit/setup.sh --target . --tools all
```

After install you have:

- `.agents/skills/<name>/SKILL.md` for every cross-tool skill, with Codex-tuned overlays for `/sdlc` and `/sdlc-lite` (sequential, no Plan mode).
- `AGENTS.md` + `CLAUDE.md` at repo root (Codex reads `AGENTS.md`).
- `TASKS.md` at repo root.
- `scripts/eval-runner.py`, `scripts/check_docker_logs.py` — invoked by skills via terminal.
- `.claude/project.json.example` (rename to `.claude/project.json`; Codex skills read it too).

## Where skills live

Codex CLI scans `<repo>/.agents/skills/<name>/SKILL.md` per the 2026 Agent Skills spec — that is the install path `setup.sh` writes to when `--tools codex` (or `--tools all`) is passed.

## Skills available

| Skill | Availability | Notes |
|---|---|---|
| `/task` | Yes | Identical to canonical — no flags; always TDD on current branch |
| `/sdlc-lite` | Yes (sequential overlay) | Full /sdlc pipeline minus the git writes — hands you the validated changes to commit. Plan / task-id / range / ad-hoc input. Sequential, no Plan mode |
| `/sdlc` | Yes (sequential overlay) | No parallel agents; linear plan→implement→test→PR. Skill-repo mode auto-detected |
| `/brainstorm`, `/brainstorm-team`, `/dead-code-review` | Yes (Copilot-shaped overlay falls through) | See [FLOW-COPILOT.md](FLOW-COPILOT.md) for behavior; sequential where Claude is parallel |
| `/flowsim`, `/gotcha`, `/status`, `/test-check`, `/eval-harness`, etc. | Yes | Cross-tool by design; identical content |
| `/plan-html <plan>` | Yes | Renders any markdown plan as a self-contained shareable HTML page (zero JS, embedded CSS). Identical on all three tools. |

If a Codex-specific override doesn't exist at `codex/skills/<name>/`, `setup.sh` falls through to the canonical `skills/<name>/SKILL.md`. Overrides today: `/sdlc`, `/sdlc-lite`. The rest install canonically.

## Daily inner loop

```
   /repo-onboarding        ← once
        │
        ▼
   ┌─ Small bounded ask ──────────────────┐
   │  /task "add formatPhone util"        │
   │  → TDD loop, 1 row in TASKS.md       │
   └──────────────────────────────────────┘
        or
   ┌─ Mid-sized task ─────────────────────┐
   │  /sdlc-lite "wire orders into queue" │
   │  → impl → evals → tests → validate   │
   │    (leaves changes for you to commit)│
   └──────────────────────────────────────┘
        or
   ┌─ Feature-sized ask ──────────────────┐
   │  /brainstorm                         │
   │  → plans/brainstorm-<slug>.md        │
   │  → /sdlc plans/brainstorm-<slug>.md  │
   └──────────────────────────────────────┘

   /plan-html <plan> — render any plan as shareable HTML when handing off
```

## When to use `/task` vs `/sdlc-lite` vs `/sdlc`

`/sdlc-lite` and `/sdlc` run the same pipeline; only the ending differs.

| Skill | Input | Terminal action |
|---|---|---|
| `/task <description>` | ad-hoc ask | TDD red-green → green commit on current branch |
| `/sdlc-lite <plan \| task-id \| range \| desc>` | plan, task(s), or ask | full pipeline → validated changes left for you to commit |
| `/sdlc <plan-file>` | plan file | full pipeline → PR |

None of the three skills take flags. `/sdlc`'s skill-repo mode is auto-detected from `.claude-plugin/marketplace.json` at the repo root.

## Invocation

Codex CLI exposes installed skills as slash commands the same way Copilot does — `/sdlc plans/foo.md`, `/task add hello util`, `/sdlc-lite task-007`. The runtime contract (frontmatter parsing, `argument-hint`, tool gating) follows the Codex CLI Agent Skills spec; see the upstream Codex CLI docs for the canonical reference. Our skills declare `metadata.brainstorm-toolkit-applies-to: codex` (or include `codex` in a multi-tool list) so `setup.sh` routes them into `.agents/skills/`.

## See also

- [FLOW-CLAUDE-CODE.md](FLOW-CLAUDE-CODE.md) — same toolkit, Claude Code flow
- [FLOW-COPILOT.md](FLOW-COPILOT.md) — same toolkit, Copilot flow (closer analog)
- [../AGENTS.md](../AGENTS.md) — skill authoring rules for contributors
- [../README.md](../README.md) — install + skills table
