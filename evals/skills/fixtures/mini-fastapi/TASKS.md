# TASKS.md

Current work items for AI agents (Claude Code, GitHub Copilot, etc.) and humans working in this repo.

**Conventions:**
- `[ ]` — pending
- `[~]` — in progress
- `[x]` — done
- Topmost unchecked item is the **active task** unless another is marked `[~]`.
- Keep entries concise. One line per task. Link to `plans/tasks/task-N-<slug>.md` for detail.

**Optional metadata** (additive — rows without these still parse fine):
- After the task line, append italicised key/value markers `_started_at: YYYY-MM-DD_`,
  `_completed_at: YYYY-MM-DD_`, `_blocked_reason: <short reason>_`.
- Multiple markers may chain on the same line, separated by `·` (middle dot).
- `/sdlc-status` reads these to surface cycle time (completed_at − started_at) and
  blocked-reason summaries. Missing fields are reported as "unknown", never as
  errors.

## Active / Pending

<!-- task-health-endpoint appends a row here. -->

## Blocked

<!-- Tasks waiting on something. Include why via _blocked_reason: <reason>_. -->

## Done

<!-- Completed items, most recent first. Cycle time computed from started_at / completed_at. -->
