---
name: next
description: >
  The conductor — answers "given everything on disk right now, what is the next step,
  and shall I start it?" Joins pipeline run-state, the .next-action sentinel, TASKS.md,
  plan files, and git into ONE recommended command with a one-line rationale. Read-only
  by default; `--go` opt-in executes the top pick with the same git-write confirm
  asymmetry the toolkit enforces everywhere. Invoke via /next, or when the user asks
  "what's next?", "what should I do now?", "where were we?". This consolidates the
  next-step logic scattered across /brainstorm Step 8, /repo-health, and /status into
  one canonical decision ladder the others cite.
argument-hint: "[--go] [--quiet]"
metadata:
  brainstorm-toolkit-applies-to: claude copilot codex
---

# Next — the conductor

Recommendation first, execution opt-in. `/next` never surprises you: by default it
**prints one command and why**; `--go` runs it, still confirming before any git-history write.

## Step 1 — Join the state (read-only)

Gather these (all optional — skip any that's absent, never error):

- `.claude/pipeline/*/run.json` (+ the latest sidecar of any **non-terminal** run):
  `pipeline`, `stage`, `status`, `base_commit`, `updated_at`, and the optional
  **`next_action`** (`{cmd, confirm}`) — the durable handoff a run proposed, which
  survives after the fire-once sentinel was consumed. If the sentinel is empty but
  a recent run carries `next_action`, treat it as rung 3 (surface its `cmd`).
- `.claude/.next-action` — **peek only, do NOT delete** (the Stop hook owns consumption).
  It's **multi-slot JSON-lines**: each line is `{"cmd":…,"source":…,"confirm":…}` (or a legacy
  bare command). Extract each line's `cmd` — the same parse the hook does — never surface raw
  JSON. See `scripts/hooks/next-action.sh` and `docs/SEAM.md`.
- `TASKS.md` — `[ ]` pending / `[~]` in-progress rows (top of `Active / Pending`).
- `plans/*.md` newer than any pipeline envelope referencing them (a **plan with no run**).
- git: current branch, dirty tree, whether HEAD has commits not recorded in any envelope.
- `.claude/project.json` — `main_branch`, `discipline.staleness_hours`.

**On Claude (optional enhancement):** dispatch the one **Haiku** `conductor` agent to do this
glob + JSON + git-plumbing join off the main context, returning the joined facts. Dispatch it
**by type** — `subagent_type: "brainstorm-toolkit:conductor"` under a plugin install, or the
bare `conductor` when vendored by `setup.sh` (naming per `docs/CONVENTIONS.md` → "Agent
dispatch"); do not reference the definition by file path, which resolves under only one of
the two install modes. This is a single Haiku read job — never a fan-out, **no model-cap
plumbing** (the tier is pinned in the agent's own frontmatter, and this site is deliberately
exempt from the `models.cap` ladder).

```
Agent(
  subagent_type: "brainstorm-toolkit:conductor",   // bare `conductor` when vendored
  description: "Join next-step state",
  prompt: """
    Do your state-join over this repo and return the structured facts.

    Inputs:
      repo_root: {cwd}
      main_branch: {project.json main_branch, default 'main'}
      staleness_hours: {project.json discipline.staleness_hours, default 24}

    Apply the shared scan in skills/sdlc/templates/envelope-staleness.md
    (non-terminal + stale definitions, reconcile hint, and the false-positive
    guards: skip on main_branch, at most one report, silence when unchanged).

    Read-only: do not delete the sentinel, do not write any file.
  """
)
```

The agent declares `model: haiku` and `tools: Read, Grep, Glob, Bash`, so the read-only promise
is structural where it matters: it has **no Write and no Edit**, and therefore cannot create,
modify, or delete any file — including the sentinel it is forbidden to consume. `Bash` stays
because the join needs git state, and scoped forms like `Bash(git log:*)` are not a documented
value for this field. **On Copilot/Codex (and any time the agent is unavailable): do the reads
inline** — the agent is pure enhancement; the ladder below runs identically on the inline facts,
and the fallback is never an error worth reporting.

## Step 2 — Walk the decision ladder (highest match wins)

1. **Paused/failed pipeline run on this branch** → recommend **`/triage <slug>`** — the
   red-path fix recommender reads the failing sidecar, classifies it (flaky · code-defect ·
   plan-wrong · config-missing · abandoned), drafts the fix for a code defect, and hands back
   an executable `--resume` re-entry. (Triaging inline instead? Name the class and the one
   command that works today — flaky → re-run the gate; code-defect → `/task fix: <failure>`;
   plan-wrong → `/brainstorm` the step; config-missing → set it in `.claude/project.json` —
   then `/sdlc <plan> --resume` (or `/sdlc-lite <input> --resume`) reuses the green stages,
   fresh only if the plan was edited.)
2. **Non-terminal (`in_progress`) run whose work looks landed** (`base_commit` is an ancestor
   of HEAD) → recommend reconciliation: `/status --prune-stale`.
3. **Pending sentinel** (`.claude/.next-action` non-empty) → surface each line's **`cmd`**
   (parse the JSON `{cmd,source,confirm}`, or take a bare line as-is — same parse as the Stop
   hook; never print raw JSON). It's the most recent skill's own routing decision — don't
   second-guess it; flag any `confirm:true` entry as needing approval before it runs.
4. **A plan file with no pipeline run** → recommend the pipeline using `/brainstorm` Step 8's
   exact continuity + safety rules: `/sdlc-lite plans/<slug>.md` is the safe default; `/sdlc`
   only with an explicit confirm (it opens a PR); **vendored-skill guard** — if the plan
   targets `.claude/skills/**` (or `.github`/`.agents`), do NOT route through this repo's
   pipeline; file it upstream in the canonical toolkit repo instead.
   **Count a plan here only if it's a `plans/brainstorm-<slug>.md` with no
   `.claude/pipeline/<slug>/` envelope AND modified recently (~7 days)** — the same filter the
   Stop hook's "plan awaiting a run" warning uses. This skips meta-docs (e.g. a curated
   shortlist) and long-parked/deferred plans, which are not pending work.
5. **`[~]` in-progress TASKS.md row** → recommend resuming it: `/sdlc-lite task-<N>`.
6. **`[ ]` pending TASKS.md rows** → recommend the top one: `/task` if small and bounded,
   `/sdlc-lite <N>` otherwise; a run of related rows → `/sdlc-lite <N>-<M>`.
7. **Nothing queued** → recommend ideation or hygiene: `/brainstorm` (if the session has an
   open thread) or `/repo-health` (if the last sweep is old / absent).

## Step 3 — Output

Print exactly one recommendation + a one-line rationale, plus at most two alternatives
(omit the `Also:` line under `--quiet`):

```
Next: /sdlc-lite plans/brainstorm-radius-refetch.md
Why:  plan saved 20m ago; no pipeline run references it; sdlc-lite is the established flow.
Also: /plan-html plans/brainstorm-radius-refetch.md (preview) · /status (full queue)
```

## `--go` — execute the top pick

Run the top recommendation instead of printing it, with the toolkit's **safety asymmetry**:
- `/sdlc-lite`, `/task`, `/status`, `/plan-html`, `/repo-health` → proceed.
- Anything that writes git history (`/sdlc`) → **stop and confirm first**, exactly as `/brainstorm`
  Step 8 and `/status --prune-stale` do. A vendored-skill-guard hit (rung 4) → never auto-run;
  print the upstream-filing note.

## Rules

- **Pure read by default** — the only write path is `--go` executing a write-capable command,
  which keeps that command's own confirm gate. `/next` itself writes nothing and **never deletes
  the sentinel** (it peeks).
- One recommendation, not a report — for the full queue the answer is `/status`.
- Absent state (no pipeline dir, no TASKS.md, no plans) is normal: fall through the ladder to
  rung 7, don't warn.
- This ladder is the **canonical** next-step decision procedure; `/brainstorm` Step 8,
  `/repo-health`, and `/status` mirror slices of it.
