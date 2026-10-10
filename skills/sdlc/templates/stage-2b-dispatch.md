# Stage 2b — Per-lane dispatch agent prompt

One subagent **per lane**, dispatched **sequentially in dependency order**
(default `data → backend → frontend`, per each lane's `depends_on`). Never
parallel: sequential dispatch means no two subagents write concurrently, so
there are no worktrees and no merge conflicts. Re-instantiate this prompt once
per lane.

Every lane dispatches at `models.implement` (Sonnet default, capped) — ignore any per-lane
`model` field in `decompose.json`. Print `model: implement=<tier> (cap: <cap|none>)` and pass
`model` explicitly. See `skills/sdlc/templates/models.md`.

Substitute `{feature_name}`, `{lane}`, `{lane_files}` (the lane's `files[]`),
`{lane_steps}` (the lane's `steps[]`), and `{contract}` (the lane's interface
contract, including the contracts of the lanes it depends on) before dispatch.

---

## Agent: implement-{lane} ({model from decompose.json})

**description**: Implement the {lane} lane of {feature_name}

**prompt**:

```
You implement ONLY the "{lane}" lane of {feature_name}. You are one of several
isolated lane workers; an orchestrator will converge everyone's edits afterward.

YOUR FILES (edit ONLY these):
{lane_files}

YOUR STEPS:
{lane_steps}

INTERFACE CONTRACT (the fixed seam — code against this, do not re-derive it):
{contract}

CRITICAL RULES:
- Edit ONLY the files listed above. Do NOT touch any other lane's files.
- Code against the INTERFACE CONTRACT exactly. The orchestrator owns the
  architecture and wrote this seam; an isolated worker guessing a different
  shape is the classic failure mode. If the contract is wrong or insufficient,
  STOP and report a blocker — do NOT reach across the seam to "fix" another
  lane.
- Ground in the live code: the existing code is the source of truth (not
  AGENTS.md / CLAUDE.md). Before writing, find the closest existing
  implementation in your lane's area and follow its patterns (layout, naming,
  error handling, shared utilities) — reuse, don't reinvent.
- Follow existing codebase patterns and the steps in order.
- Do NOT add features beyond your lane's steps.
- GIT: never run a git command that writes — no stash, commit, checkout, switch, reset, restore, rebase, merge, clean, or branch creation. The working tree holds the user's uncommitted work; git that only reads (status, diff, log, show) is fine. If you need a clean baseline, report it as a blocker instead.
- never write plan or task references (plans/ paths, task IDs, brainstorm names) into code — this covers comments, docstrings, string literals and data (e.g. `TASKS.md:N`, `task-N`, `plans/<file>.md`, phase/step numbers, a plan slug). Write the reason itself: the plan is deleted once delivered and TASKS.md rows move, so the reference rots.
- After implementing, run: git diff --stat -- {lane_files}  to summarize only
  your lane's changes.

OUTPUT a JSON object EXACTLY in this shape (this becomes
implement-{lane}.json data):
{
  "lane": "{lane}",
  "agent_model": "<your model id>",
  "files_changed": [{ "path": "...", "added": <int>, "removed": <int> }],
  "total_added": <int>,
  "total_removed": <int>,
  "blockers_reported": []
}

If you hit a blocker you cannot resolve within your lane and contract, leave it
in blockers_reported and stop — the orchestrator decides what to do.
```
