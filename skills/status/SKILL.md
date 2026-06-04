---
name: status
description: >
  Show a quick readout of the current work queue: task counts by state, the active
  task, and the most recently completed task. Also surfaces any non-terminal
  pipeline runs (so a stalled /sdlc or /sdlc-lite run can't hide). Reads
  TASKS.md and .claude/pipeline/ directly — no subagents, no dashboards.
  Invoke via /status or when the user asks "what's left?", "current task?",
  "status". Read-only by default; `--prune-stale` is an opt-in, confirm-gated
  cleanup of stale/orphaned pipeline envelopes.
argument-hint: "[--prune-stale]"
metadata:
   brainstorm-toolkit-applies-to: claude copilot codex
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
7. **Scan pipeline run-state** (the discipline signal). Glob
   `.claude/pipeline/*/run.json`. If the dir is absent, skip this block
   silently (it's gitignored/local-only; many repos won't have it). For each
   run, read `pipeline`, `stage`, `status`, `updated_at`, `base_commit`. List
   any **non-terminal** run (`status` is `in_progress` or `paused`), and flag
   it **stale** when `updated_at` is older than ~24h (or
   `.claude/project.json::discipline.staleness_hours`). If a stale run's
   `base_commit` is already an ancestor of HEAD
   (`git merge-base --is-ancestor`), append "(looks committed outside the
   pipeline — reconcile)". This is read-only: surface it, don't rewrite it.
8. **Print a 3–7 line summary**:

   ```
   TASKS: N pending · M in_progress · K done · B blocked
   Active:  (P<pri>) <title> — plans/tasks/task-<N>-<slug>.md
   Last done: <title> (cycle: <D> days, or "unknown")
   Median cycle (last 10): <D> days  (omit if all unknown)
   Blocked reasons: <reason1> ×N · <reason2> ×M  (omit if no blocked rows)
   Pipeline: <slug> @ <stage> (<pipeline>, in_progress 3d — reconcile)  (omit if none non-terminal)
   ```

   If there's no active task, say "no active task — next up: <first pending>".
   A non-terminal pipeline run is the one thing worth making loud — it's how a
   skipped/abandoned pipeline becomes visible instead of lingering in JSON.

## `--prune-stale` (opt-in cleanup — the one write exception)

Detection alone leaves stale envelopes flagged forever. `/status --prune-stale`
lets you actually clear them — confirm-gated, never automatic:

1. Find pipeline runs that are **non-terminal** (`in_progress`/`paused`) **and**
   either older than `discipline.staleness_hours` (default 24) **or** whose
   `base_commit` is not a real git object (`git cat-file -e <base_commit>` fails
   — a synthetic/placeholder base that nothing will ever reconcile).
2. **List them and ask for one confirmation** before touching anything: show
   each slug, stage, age, and why it qualifies.
3. On confirm, for each: if its `base_commit` is an ancestor of HEAD (work
   landed), set `run.json.status = "abandoned"` and append a one-line note; if
   it's a synthetic/garbage envelope, remove the `.claude/pipeline/<slug>/`
   directory. Report what was pruned.

Without `--prune-stale`, `/status` is **pure read** (default). The flag is the
documented, confirm-gated exception — it's the only path that writes.

## Rules

- Pure read by default, no file writes. The sole exception is `--prune-stale`
  above, which is explicit and confirm-gated.
- No subagent calls, no multi-step workflows.
- Keep the output under 6 lines unless the user asks for detail.
- If the user wants more (e.g., "show all pending"), list them in a compact table but still no subagent.
- Missing `_started_at_` / `_completed_at_` / `_blocked_reason_` markers are
  reported as "unknown"; never raise an error or refuse to summarize.
