# Stage 2 — Implementation agent prompt

One implement agent — **Sonnet by default** (Opus only on `--model opus`
opt-up), per the model cap (`skills/sdlc/templates/models.md`). Substitute
`{feature_name}` and `{plan_content}` before dispatch.

---

## Agent: implement (Sonnet by default; Opus on opt-up)

**description**: Implement {feature_name}

**prompt**:

```
Implement the following plan. Follow the steps exactly.

PLAN:
{plan_content}

GROUND IN THE LIVE CODE FIRST (before writing any code):
- The source of truth is the existing code, NOT AGENTS.md / CLAUDE.md — read
  those as hints, but verify against the code and follow the code when they
  disagree.
- Find the 2-3 closest existing implementations to what you're building (same
  layer, same kind of thing) and follow their patterns: file/module layout,
  naming, error handling, the data-access seam, shared utilities already
  available, and test style. Reuse them — do NOT introduce a parallel pattern
  when one already exists.
- If the plan has a `## Conventions & reuse` block, honor it AND re-verify it
  against the live code (the code may have moved since the plan was written).

- Follow patterns from referenced existing files; prefer extending existing
  modules over creating new ones.
- Use the EXACT file paths the plan specifies. A near-miss path silently creates
  a second home for something that already has one.
- Do NOT add features beyond what the plan specifies, and do NOT skip a step or
  take a shortcut. Scope creep here is invisible to the tests (nothing fails)
  and invisible to the plan check (it flags missing steps, not extra ones), so
  this instruction is the only thing preventing it.
GIT: never run a git command that writes — no stash, commit, checkout, switch, reset, restore, rebase, merge, clean, or branch creation. The working tree holds the user's uncommitted work; git that only reads (status, diff, log, show) is fine. If you need a clean baseline, report it as a blocker instead.
COMMENTS: never reference the plan in code — no plan file paths, plan/phase/step numbers, or TASKS.md rows in comments or docstrings. Write the reason itself; the plan does not ship with the code and its numbering means nothing once it is gone.
- After implementation, run: git diff --stat to summarize changes.
```
