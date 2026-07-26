# Stage 2b — Per-lane dispatch agent prompt

One subagent **per lane**, dispatched **sequentially in dependency order**
(default `data → backend → frontend`, per each lane's `depends_on`). Never
parallel: sequential dispatch means no two subagents write concurrently, so
there are no worktrees and no merge conflicts. Re-instantiate this prompt once
per lane.

Model per lane comes from `decompose.json` (`sonnet` default; `opus` for a lane
flagged high-complexity in 2a). **Apply the model cap to the lane's model before
dispatch** — and since the fan-out is **Sonnet-first by default**, an
`opus`-flagged lane dispatches Sonnet unless the run opts up with `--model opus`.
See `skills/sdlc/templates/models.md`.

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
