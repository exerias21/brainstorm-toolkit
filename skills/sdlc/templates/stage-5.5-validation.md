# Stage 5.5 — Plan-requirements validation agent prompts

Up to 4 agents launched in parallel. Substitute `{plan_file}` and
`{feature_slug}` before dispatch.

**Dispatch by agent type**, not by file path — `brainstorm-toolkit:ux-plan-validator`
(plugin install) or the bare `ux-plan-validator` (vendored via `setup.sh`). The
definition then arrives as the agent's system prompt and the prompts below only need to
supply the focus and inputs. Only if neither type resolves, dispatch
`general-purpose` and have it read the definition from
`${CLAUDE_PLUGIN_ROOT}/agents/ux-plan-validator.md` or
`.claude/agents/ux-plan-validator.md` — a bare `.claude/agents/…` path does not exist
under a plugin-only install. See `docs/CONVENTIONS.md` → "Agent dispatch".

---

## Agent: api (Sonnet)

**description**: Validate API requirements for {feature_name}

**prompt**:

```
You are a UX Plan Validator with focus="api".
(If you were dispatched as `general-purpose` rather than by agent type, read the
ux-plan-validator definition first — see the dispatch note at the top of this file.)

Plan file: {plan_file}
Feature: {feature_slug}

Validate that every API endpoint specified in the plan exists, returns the
correct status code, and has the expected response shape. Use the project's
configured auth flow — check README.md / CLAUDE.md / .claude/project.json
for test credentials or auth instructions.

Return a structured pass/fail report per endpoint.
```

---

## Agent: ui (Sonnet)

**description**: Validate UI requirements for {feature_name}

**prompt**:

```
You are a UX Plan Validator with focus="ui".
(If you were dispatched as `general-purpose` rather than by agent type, read the
ux-plan-validator definition first — see the dispatch note at the top of this file.)

Plan file: {plan_file}
Feature: {feature_slug}

Validate that every frontend component and page specified in the plan
renders correctly. If the project has a configured UI audit tool, use it.
Otherwise, inspect components via direct file reads.

Return a structured pass/fail report per component/page.
```

---

## Agent: data (Haiku)

**description**: Validate DB schema for {feature_name}

**prompt**:

```
You are a UX Plan Validator with focus="data".
(If you were dispatched as `general-purpose` rather than by agent type, read the
ux-plan-validator definition first — see the dispatch note at the top of this file.)

Plan file: {plan_file}
Feature: {feature_slug}

Validate that all database tables, columns, and indexes specified in the
plan exist. Read the project's DB connection helper (check CLAUDE.md or
the project's conventions for how to connect) and query accordingly.

Return a structured pass/fail report per table/column.
```

---

## Agent: cross-module (Haiku)

**description**: Validate cross-module integration for {feature_name}

**prompt**:

```
Read the plan file: {plan_file}
Feature: {feature_slug}

Check the "Cross-Module Touchpoints" section of the plan.
For each touchpoint mentioned, verify:
- If it references a registration (e.g., a router, service, or allow-list
  name), grep for it
- If it references an AI/assistant flow or recognized intent, check that
  it is registered
- If it references a frontend page layout change, verify the component import

Return a structured pass/fail report per touchpoint.
```
