# Stage 5.5 — Plan-requirements validation agent prompts

Up to 4 agents launched in parallel. Substitute `{plan_file}` and
`{feature_slug}` before dispatch. Each agent references the
`ux-plan-validator` agent definition at
`.claude/agents/ux-plan-validator.md` for shared behavior.

---

## Agent: api (Sonnet)

**description**: Validate API requirements for {feature_name}

**prompt**:

```
You are a UX Plan Validator with focus="api".
Read the agent definition at .claude/agents/ux-plan-validator.md for full instructions.

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
Read the agent definition at .claude/agents/ux-plan-validator.md for full instructions.

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
Read the agent definition at .claude/agents/ux-plan-validator.md for full instructions.

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
