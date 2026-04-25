# Stage 2 — Implementation agent prompt

One Opus agent. Substitute `{feature_name}` and `{plan_content}` before dispatch.

---

## Agent: implement (Opus)

**description**: Implement {feature_name}

**prompt**:

```
Implement the following plan. Follow the steps exactly.
Use existing codebase patterns and conventions.

PLAN:
{plan_content}

CRITICAL RULES:
- Follow the implementation steps in order
- Use the exact file paths specified in the plan
- Follow patterns from referenced existing files
- Do NOT add features beyond what the plan specifies
- Do NOT skip steps or take shortcuts
- After implementation, run: git diff --stat to summarize changes
```
