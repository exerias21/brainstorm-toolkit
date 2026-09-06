# Stage 1.5 — Sanity-check agent prompts

Canonical for `/sdlc` Stage 1.5 — orchestration first, then the
per-focus agent prompts.

## Orchestration

Before spending implementation tokens, verify the plan is actually
correct. Launch the configured focus agents **in parallel** (single message) to
check different dimensions. This is cheap insurance — catches wrong file paths,
missing steps, and known gotchas before they become bugs.

Use the per-focus prompts below (sections: `paths`,
`completeness`, `gotchas`). Substitute `{plan_file}` and `{feature_name}`, then
dispatch the selected agents in a single message — one Agent call per section.

**Which focuses run — `agents.sanity_focuses`.** Read the array from
`.claude/project.json`; absent means all three defaults. Setting fewer cuts this stage's
cost roughly linearly (one agent per focus). `paths` is the cheapest and most mechanical
(file existence); `completeness` is the judgment-heavy one; `gotchas` is only useful when
a `GOTCHAS.md` exists. An unrecognized focus name is ignored with one warning.

**Which tier — `models.sanity`.** Built-in default is `haiku` for every
focus. `.claude/project.json` `models.sanity` (`haiku|sonnet|opus`)
**replaces that default for all focuses** when set. Reach for it when this stage is
reviewing *plans* rather than checking paths: `paths` is genuinely mechanical, but
`completeness` is asking "does this plan hang together?", which is the kind of judgment a
stronger reader does better. Raising it costs on **every** run that reaches Stage 1.5 —
which is every run, since the stage is never gated.

The resolved tier then passes through the **model cap** (`models.cap` / `--model`) as usual —
see `skills/sdlc/templates/models.md` for the ceiling rule and why `models.sanity` is the only
way to raise this stage above its `haiku` default.

Print `model: <tier> (cap: <cap|none>)` and the resolved focus list —
`sanity focuses: <a, b, …> (N of 3 defaults)` — before dispatching.

### Processing results

1. Collect each dispatched focus agent's report
2. **If issues found**: auto-patch the plan file with corrections. Log a short
   summary of what was fixed, then proceed to Stage 2 with the corrected plan.
3. **If critical issues** (plan references nonexistent files, entire approach
   is misguided): report to user and **STOP** — the plan needs human revision.
4. **If all clean**: proceed to Stage 2.

**State write**: write `stage-outputs/sanity-check.json` with
`data.agents` (focus, status, issue_count for each), `data.auto_patched`
(bool), and `data.issues`. Status is `pass` if every dispatched agent reported no
issues, `pass` with `auto_patched: true` if issues were auto-corrected,
`paused` if critical issues forced a stop.

---

## Agent: paths

**description**: Verify plan file paths and patterns for {feature_name}

**prompt**:

```
Read the plan at {plan_file}. For every file path mentioned:
1. Verify the file exists (use Glob or ls)
2. If the plan references a specific function, class, symbol, or
   import path, grep for it in the actual file to confirm it's valid
3. If the plan says "follow the pattern in X", read X and verify
   the plan's description matches what's actually there

**Symbol presence is the signal, not line numbers.** Line numbers in
plans are illustrative and drift constantly; the implement agent greps
anyway. Confirm the named symbol exists *somewhere* in the file. Do NOT
flag a line-number mismatch as an issue unless the symbol is absent
entirely (a wrong path/symbol is real; a wrong line is noise).

Report a JSON array:
[{path: "file.py", exists: true/false, issues: ["description"]}]
```

---

## Agent: completeness

**description**: Check plan completeness for {feature_name}

**prompt**:

```
Read the plan at {plan_file}. Check for common missing-step categories:
1. Creates a DB migration → does the plan mention running/applying it? AND is
   the migration number collision-safe? Compute the next number as
   `max(existing) + 1`, but **warn that it is not collision-safe across
   unmerged branches** — another in-flight branch may claim the same number
   (this repo may already have duplicate-numbered migrations). Suggest
   verifying the number at implementation time, or a timestamp-prefixed scheme
   if the project's migration tool allows it.
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

## Agent: gotchas

**description**: Scan plan for known gotchas in {feature_name}

**prompt**:

```
Read the plan at {plan_file}.

Then read the project's gotchas file — path is `gotchas_file` in
`.claude/project.json` (default `GOTCHAS.md` at repo root).

If the file does NOT exist, **bootstrap an empty stub** rather than
reporting absence as a dead end: write a minimal `GOTCHAS.md` with
frontmatter and an empty `## Active` section (use the same skeleton
`/gotcha` creates). Then report:
{status: "stub-created", note: "No GOTCHAS.md existed — created an empty
one. Add entries with /gotcha when work surfaces a non-obvious pitfall."}
This is a best-effort write; if it fails (read-only volume), fall back to
{status: "no-gotchas-file"} and continue — never fail the stage on it.

If the file exists, cross-reference each step in the plan against every
gotcha in it. For each plan step, flag if any gotcha applies.

Report: [{step: "N", gotcha: "title from GOTCHAS.md", suggestion: "fix"}]
```
