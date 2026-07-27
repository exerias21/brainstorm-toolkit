# Gap analysis — the loop that never closes

**Date:** 2026-07-07
**Scope:** deep-dive review of the toolkit's end-to-end flow with one question in mind:
*can a user hand the system a task (or a brainstorm seed) and have it loop — plan → build →
verify → next step — without a human re-typing every transition?*
**Verdict:** no, and the missing piece is not another worker skill. It is a **conductor** —
the agent/skill role that reads the current state and either prompts the next step or
recommends the fix action. Everything below decomposes that one finding into concrete,
independently pullable levers.

These are maintainer docs (they live in `docs/`, ship nowhere, per the placement rule in
`CLAUDE.md`). No code or skill changes are made by this analysis — it is the map, not the work.

---

## The loop the user wants

```
   ┌─────────────────────────────────────────────────────────┐
   │                                                         │
   ▼                                                         │
 seed ──▶ /brainstorm ──▶ plan ──▶ pipeline ──▶ validated ───┤
   ▲            ▲                    │  │        work        │
   │            │                    │  └─ paused/red ──▶ ❓ │  ← "recommend the fix"
   │            │                    ▼                       │
   │            └──── learnings ── gotchas                   │
   │                                                         │
   └────────── "what's next?" ◀── TASKS.md backlog ◀─────────┘  ← "prompt the next step"
```

Two arrows are marked: **"recommend the fix"** (the red path — a paused run becomes a
concrete next action) and **"prompt the next step"** (the green path — a finished run feeds
the next iteration). Neither arrow has an owner today.

## The flow as built

`docs/FLOW.md` is accurate about what exists. Trace its diagram to its terminal nodes:

| Path | Terminal node | What happens after |
|---|---|---|
| `/task` | "row closed in TASKS.md" | nothing — no next-task prompt |
| `/sdlc-lite` | "validated working tree — you commit" | nothing — user commits, loop ends |
| `/sdlc` | "branch → push → PR → /review" | nothing — no PR watch, no merge/deploy re-entry |
| any pipeline **pause** (Stage 4/5.5/5.6 budget exhausted) | "Fix manually, then re-run `/sdlc {plan_file}`" | human debugs alone; re-run **restarts from Stage 1 and overwrites state** (no `--resume` — Phase 1B is deferred) |

Every terminal node is a **dead end that a human must restart by typing a command**. The only
machinery bridging skills is:

1. **The `.next-action` sentinel + Stop hook** (`scripts/hooks/next-action.sh`): one line,
   fire-once, deleted on print, *informational only* — it prints `Next: /sdlc-lite plans/…`
   and hopes the user types it. See [`03-SEAM-HARDENING.md`](03-SEAM-HARDENING.md).
2. **Prose "continue the flow" instructions** inside `/brainstorm` Step 8, `/brainstorm-deep`,
   `/brainstorm-team` — they keep momentum *within one session* but the logic lives in chat
   context, evaporates at session end, and exists nowhere as a reusable decision procedure.
3. **Detection-only surfacing**: `/status`, `/repo-health` Check 7, and the Stop hook's stale-run
   warning all *flag* a stalled pipeline — none of them *recommends or performs* the
   reconciliation.

## The core finding: workers without a conductor

Inventory of `agents/`: `e2e-test-runner`, `sdlc-pipeline`, `ux-plan-validator`.
All four are **workers** — they execute a stage. There is no agent whose job is to look at the
repo's state (TASKS.md, `.claude/pipeline/*/run.json`, the sentinel, git, open PRs) and answer
*"what should happen next, and shall I start it?"*

Worse, the *decision logic* for that role already exists — scattered and duplicated as prose in
three places, executable by nobody:

- `/brainstorm` Step 8's flow-continuity rules ("if `/sdlc` was used this session → continue
  with `/sdlc`; else `/sdlc-lite` is the safe default").
- `/repo-health`'s "Suggested next" priority ladder (migration > dep HIGH > stale pipeline run
  > test failure > …).
- `/status`'s "no active task — next up: <first pending>".

Consolidating that scattered logic into one owned role is the single highest-leverage change
this analysis proposes.

## Gap inventory → lever documents

| # | Gap | Symptom | Lever doc |
|---|---|---|---|
| 1 | **No conductor / next-step agent** | every skill-to-skill transition is human-typed; next-step logic duplicated as prose in 3 skills | [`01-CONDUCTOR-AGENT.md`](01-CONDUCTOR-AGENT.md) |
| 2 | **No fix-action recommender on the red path** | all pauses end in "fix manually, then re-run"; re-run restarts from scratch | [`02-FIX-RECOMMENDER.md`](02-FIX-RECOMMENDER.md) |
| 3 | **The seam channel is too weak to carry a loop** | single-slot, fire-once, human-only, contended sentinel; Codex degrades to a printed line | [`03-SEAM-HARDENING.md`](03-SEAM-HARDENING.md) |
| 4 | **Nothing drives the backlog** | TASKS.md pending rows sit until a human picks one; `/task` is explicitly one-at-a-time | [`04-BACKLOG-LOOP.md`](04-BACKLOG-LOOP.md) |
| 5 | **No downstream re-entry** | PR review comments, merges, and deploys never feed back into the loop; Phase 6 unbuilt | [`05-DOWNSTREAM-CLOSURE.md`](05-DOWNSTREAM-CLOSURE.md) |
| — | **Prioritized roadmap** | which levers to pull, in what order, with prereqs | [`06-LEVERS-ROADMAP.md`](06-LEVERS-ROADMAP.md) |

## Relationship to the existing roadmap docs

This analysis does not duplicate the existing design corpus — it plugs the hole between them:

- **`BRAINSTORM-PIPELINE.md`** ranked "no resumable state" as gap #1 and built it (state
  envelope, shipped). But the envelope was, at the time of this analysis, **written far more
  than it was read** — the two consumers that would close the loop (`--resume` 1B, `--inspect`
  1C) were still deferred. State without a reader is a journal, not a loop. *(Both have since
  shipped — `--resume` as L5, the inspect surface as `/status` + `/next`.)*
- **`docs/REVIEW-FIX-STAGE.md`** was, at the time of this analysis, the designed-but-unbuilt
  fix-recommender for the **green** path — adversarial review of code that passed everything.
  The **red** path (a run that paused mid-pipeline) had no equivalent design anywhere;
  `02-FIX-RECOMMENDER.md` fills that. *(Both have since shipped — the green path as Stages
  5.7/5.8, the red path as `/triage`.)*
- **`docs/AUTONOMOUS-DISCOVERY.md`** already documents the watcher-daemon pattern for
  unattended *data discovery*. `04-BACKLOG-LOOP.md` shows the same pattern is the ceiling
  option for unattended *delivery* — with much stronger guardrails.
- **Phase 6** (deploy/monitor/rollback, `/monitor` feeding failures back into TASKS.md) is the
  only place the existing roadmap draws a back-edge — and it's the last, unbuilt phase.
  `05-DOWNSTREAM-CLOSURE.md` extracts the cheap parts that don't need Phase 6.

## Reading order

Read this file, then `01` and `02` (the two missing agents — the direct answer to "I'm missing
an agent that will prompt the next step or recommend the fix action"), then `03`–`05` (the
plumbing those agents need), then `06` for sequencing.
