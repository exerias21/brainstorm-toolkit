---
name: status
description: >
  Show a quick readout of the current work queue: task counts by state, the active
  task, and the most recently completed task. Reads TASKS.md directly — no subagents,
  no dashboards. Invoke via /status or when the user asks "what's left?", "current
  task?", "status".
metadata:
   brainstorm-toolkit-applies-to: claude copilot
---

# Status — one-glance work readout

## Flow

1. **Read `TASKS.md`** at the repo root. If missing, report "no TASKS.md yet — run `/repo-onboarding` or `/task <description>` to create one" and stop.
2. **Count checkbox states** across the file:
   - `[ ]` → pending
   - `[~]` → in progress
   - `[x]` → done
3. **Identify the active task**: the first `[~]` row, or if none, the first `[ ]` row.
4. **Identify the last completed**: the most recent `[x]` row (top of the `Done` section, or last `[x]` before it).
5. **Parse optional metadata markers** on each row (additive — absent fields are fine):
   - `_started_at: YYYY-MM-DD_`
   - `_completed_at: YYYY-MM-DD_`
   - `_blocked_reason: <short reason>_`

   Treat missing fields as **"unknown"** rather than as errors. Do not warn.
6. **Compute summaries**:
   - Cycle time per `[x]` row = `completed_at − started_at` in days, when both
     are present. Surface the median across the most recent ~10 done rows; skip
     rows where either field is unknown.
   - Blocked-reason rollup: count distinct `_blocked_reason: …_` values under
     the `Blocked` section.
7. **Print a 3–6 line summary**:

   ```
   TASKS: N pending · M in_progress · K done · B blocked
   Active:  (P<pri>) <title> — plans/tasks/task-<N>-<slug>.md
   Last done: <title> (cycle: <D> days, or "unknown")
   Median cycle (last 10): <D> days  (omit if all unknown)
   Blocked reasons: <reason1> ×N · <reason2> ×M  (omit if no blocked rows)
   ```

   If there's no active task, say "no active task — next up: <first pending>".

## Rules

- Pure read, no file writes.
- No subagent calls, no multi-step workflows.
- Keep the output under 6 lines unless the user asks for detail.
- If the user wants more (e.g., "show all pending"), list them in a compact table but still no subagent.
- Missing `_started_at_` / `_completed_at_` / `_blocked_reason_` markers are
  reported as "unknown"; never raise an error or refuse to summarize.
