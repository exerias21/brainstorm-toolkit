# Stage 1.5 — Sanity-check agent prompts

Three Haiku agents launched in parallel. Substitute `{plan_file}` and
`{feature_name}` before dispatch.

---

## Agent: paths (Haiku)

**description**: Verify plan file paths and patterns for {feature_name}

**prompt**:

```
Read the plan at {plan_file}. For every file path mentioned:
1. Verify the file exists (use Glob or ls)
2. If the plan references a specific function, class, symbol, or
   import path, grep for it in the actual file to confirm it's valid
3. If the plan says "follow the pattern in X", read X and verify
   the plan's description matches what's actually there

Report a JSON array:
[{path: "file.py", exists: true/false, issues: ["description"]}]
```

---

## Agent: completeness (Haiku)

**description**: Check plan completeness for {feature_name}

**prompt**:

```
Read the plan at {plan_file}. Check for common missing-step categories:
1. Creates a DB migration → does the plan mention running/applying it?
2. Creates a new API endpoint → does the plan mention registering it
   with the router / app (whatever pattern this project uses)?
3. Creates a new frontend component → does the plan mention importing
   it in the parent page/layout?
4. Adds a new config key or environment variable → is it documented in
   the project's config files or example env?
5. Adds a new database table → does the plan mention indexes?
6. Adds a new background job or scheduled task → does the plan mention
   registering it with the scheduler?

Infer the project's patterns from its README, CLAUDE.md, and existing
code before flagging. A check only fails if the project would actually
need that step.

Report: [{check: "description", status: "pass/fail", detail: "..."}]
```

---

## Agent: gotchas (Haiku)

**description**: Scan plan for known gotchas in {feature_name}

**prompt**:

```
Read the plan at {plan_file}.

Then read the project's gotchas file — path is `gotchas_file` in
`.claude/project.json` (default `GOTCHAS.md` at repo root). If the
file does not exist, report: {status: "no-gotchas-file"} and exit.

Cross-reference each step in the plan against every gotcha in
GOTCHAS.md. For each plan step, flag if any gotcha applies.

Report: [{step: "N", gotcha: "title from GOTCHAS.md", suggestion: "fix"}]
```
