# Stage 2 — Implementation agent prompt

One implement agent — **Sonnet by default** (Opus only on `--model opus`
opt-up), per the model cap (`skills/sdlc/templates/model-cap.md`). Substitute
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

CRITICAL RULES:
- Follow the implementation steps in order
- Use the exact file paths specified in the plan
- Follow patterns from referenced existing files; prefer extending existing
  modules over creating new ones
- Do NOT add features beyond what the plan specifies
- Do NOT skip steps or take shortcuts
- After implementation, run: git diff --stat to summarize changes
```
