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
5. **Print a 3–5 line summary**:

   ```
   TASKS: N pending · M in_progress · K done
   Active:  (P<pri>) <title> — plans/tasks/task-<N>-<slug>.md
   Last done: <title>
   ```

   If there's no active task, say "no active task — next up: <first pending>".

## Rules

- Pure read, no file writes.
- No subagent calls, no multi-step workflows.
- Keep the output under 5 lines unless the user asks for detail.
- If the user wants more (e.g., "show all pending"), list them in a compact table but still no subagent.
