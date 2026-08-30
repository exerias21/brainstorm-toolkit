# Gap 1 — The conductor: a `/next` skill + next-step agent

**Gap:** the toolkit has no owner for the question *"given everything on disk right now, what
is the next step — and shall I start it?"* Every transition between skills is either a
one-shot printed hint (`Next: /sdlc plans/…`) or a prose instruction inside a skill that
only works while that skill's session is still alive.

**Lever:** a small, cheap, cross-tool **`/next` skill** backed (on Claude) by a **conductor
agent definition** in `agents/`. Read-only by default; recommendation first, execution opt-in.

---

## Evidence the role is missing (and that its logic already exists, scattered)

1. **`agents/` contains only workers.** `e2e-test-runner`, `sdlc-pipeline`,
   `ux-plan-validator` — each executes a stage. None reads cross-run state and routes.
2. **The next-step decision procedure is written down three times, as prose, executable by
   nobody on demand:**
   - `skills/brainstorm/SKILL.md` Step 8 — flow-continuity rules (established-flow detection,
     `/sdlc` as the safe default, the vendored-skill mis-route guard, "confirm before the
     PR-writing path").
   - `skills/repo-health/SKILL.md` roll-up — a full priority ladder for "Suggested next"
     (unapplied migration > dep HIGH > stale pipeline run > test failure > stale gotcha > …).
   - `skills/status/SKILL.md` — "no active task — next up: <first pending>".
3. **The state needed to decide is already durable and machine-readable** — that was Phase 1A's
   whole point — but the only readers are humans running `/status`. The envelope records
   `pipeline`, `stage`, `status`, `base_commit`, `stages_completed`, per-stage sidecars; the
   sentinel records a pending handoff; TASKS.md records the backlog; git records the branch and
   dirty tree. Nobody joins them.
4. **The seam evaporates.** `/brainstorm` Step 8's momentum logic lives in the session's chat
   context. Close the laptop after the plan is written and the loop's "program counter" is
   gone — the sentinel prints once at the next Stop and deletes itself.

## Proposed shape

### `/next` — the skill (cross-tool, `claude copilot codex`)

```
/next [--go] [--quiet]
```

**Inputs (all optional, all read-only):**
- `.claude/pipeline/*/run.json` (+ latest sidecar of any non-terminal run)
- `.claude/.next-action` (peek — do NOT consume; the Stop hook owns deletion)
- `TASKS.md` (pending / in-progress rows)
- `plans/*.md` newer than any pipeline envelope referencing them (a plan with no run)
- git: current branch, dirty tree, whether HEAD has commits not in any envelope
- `.claude/project.json` (`main_branch`, discipline knobs)

**Output:** exactly one recommended command with a one-line rationale, plus at most two
alternatives. Example:

```
Next: /sdlc plans/brainstorm-radius-refetch.md
Why:  plan saved 20m ago; no pipeline run references it; sdlc is the established flow.
Also: /plan-html plans/brainstorm-radius-refetch.md (preview) · /status (full queue)
```

**The decision ladder** (highest first — this consolidates the three scattered prose versions
into the one canonical copy the other skills then *cite*, per the repo's "reference, don't
inline" rule):

1. **Paused/failed pipeline run on this branch** → hand off to the fix recommender
   (`/triage <slug>`, see `02-FIX-RECOMMENDER.md`); until that exists, summarize the failing
   sidecar and recommend the concrete re-entry command.
2. **Non-terminal (`in_progress`) run whose work looks landed** (`base_commit` ancestor of
   HEAD) → recommend reconciliation (`/status --prune-stale`).
3. **Pending sentinel** → surface it verbatim (it is the most recent skill's own routing
   decision; don't second-guess it).
4. **A plan file with no pipeline run** → recommend the pipeline, applying `/brainstorm`
   Step 8's exact continuity + safety rules (`/sdlc` default; `/sdlc` only with confirm;
   vendored-skill guard).
5. **`[~]` in-progress TASKS.md row** → recommend resuming it (`/sdlc task-N`).
6. **`[ ]` pending TASKS.md rows** → recommend the top one (`/task` if small, `/sdlc N`
   otherwise; a run of related rows → `/sdlc N-M`).
7. **Nothing queued** → recommend ideation or hygiene: `/brainstorm` (if the session has an
   open thread) or `/repo-health` (if the last sweep is old / absent).

**`--go`:** execute the top recommendation instead of printing it — with the same safety
asymmetry the toolkit already enforces everywhere: anything that writes git history (`/sdlc`)
still requires an explicit confirm; `/sdlc`, `/task`, `/status` may proceed.

### The conductor agent (Claude-only enhancement, `agents/conductor.md`)

On Claude, `/next` may dispatch one **Haiku** agent to do the state-join (glob + JSON reads +
git plumbing) so the main context stays clean; on Copilot/Codex the skill does the same reads
inline. Model-cap contract applies as everywhere else — this is a Haiku-tier read job, never
Opus; there is nothing to opt up.

## Why a skill + agent, not a hook

The Stop hook is the *delivery channel*, not the brain: it must stay dumb (pure file read, no
model, exits 0, never blocks — its own header says so). The conductor is a *model* job — it
reads state and applies judgment (is this run stale or mid-flight? is this plan for the
toolkit's own vendored skills?). Keep them layered:

- **Hook** = transport (print the hint, later possibly auto-continue — see
  `03-SEAM-HARDENING.md`).
- **`/next`** = the decision, on demand, any tool.
- **Conductor agent** = the optional Claude-side executor of the decision's legwork.

## Fit with the toolkit's rules (pre-flight for whoever implements)

- Small utility skill, target ≤100 lines; the decision ladder is the whole content — no
  inline templates needed.
- `metadata.brainstorm-toolkit-applies-to: claude copilot codex` — the reads are plain files;
  only the optional agent dispatch is Claude-only (same split `/brainstorm` Step 7 uses).
- Read-only default matches `/status`'s posture; `--go` is the single documented exception,
  mirroring `--prune-stale`'s confirm-gated pattern.
- Register in `.claude-plugin/marketplace.json`, README table, and update `/brainstorm` Step 8
  / `/repo-health` roll-up / `/status` to **cite** the ladder instead of restating it (the
  same consolidation move the gotcha flywheel already made for capture-at-loop-exit).

## What this lever does NOT solve

- It answers "what next" **once per invocation**. Making the system loop *without* the user
  typing `/next` is the seam/auto-continue problem (`03`) and the backlog-driver problem (`04`).
- It routes a paused run to triage but doesn't do the triage — that's `02`.
