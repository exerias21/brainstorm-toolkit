# Levers roadmap — what to pull, in what order

Consolidated from `00`–`05`. Effort scale: S (≤half day, prose-only), M (1–2 days), L (multi-day
or new infrastructure). "Tools" = which runtimes get the behavior (C = Claude Code,
G = Copilot, X = Codex).

> **Status as of 2026-07-26: Waves 1–3 are SHIPPED (L1–L11). Only L12 and L13 remain.**
> The effort/prereq/risk columns below are preserved as the original planning record — they
> describe what was *estimated* before the work, not what is left. The **Status** column is the
> live one. Ordering rationale below the table is likewise historical.

---

## The levers, ranked

| # | Lever | Status | Closes | Effort | Prereqs | Tools | Risk |
|---|---|---|---|---|---|---|---|
| L1 | **Diagnosis block in pause messages** (inline triage-lite: class + one recommended command) | ✅ shipped | gap 2 (60%) | **S** | none | CGX | none — prose in existing skills |
| L2 | **Re-entry rows at Stage 6 / close-out** ("verify PR #N deployed → /post-deploy-verify") | ✅ shipped | gap 5 | **S** | none | CGX | none |
| L3 | **Codex/Copilot seam parity fixes** (inline `Next:` fallback on the brainstorm handoff; peek-vs-consume rule written down) | ✅ shipped | gap 3 (partial) | **S** | none | CGX | none |
| L4 | **`/next` skill + conductor agent** (decision ladder; read-only; `--go` opt-in) | ✅ shipped | gap 1 | **M** | none (better with L6) | CGX (agent dispatch C-only) | low — read-only default |
| L5 | **Phase 1B `--resume`** (already fully specced in `docs/PHASE-1-STATE-ENVELOPE.md`) | ✅ shipped | gap 2 enabler | **M** | none — spec exists | CGX | low — spec answered the edge cases |
| L6 | **Structured multi-slot sentinel** (JSON-lines; `source`/`confirm`; kills the gotcha-vs-pipeline slot race) | ✅ shipped | gap 3 | **M** | none | CGX | low — backward-compatible parse |
| L7 | **`/triage <slug>` skill** (classify paused envelope → drafted fix action; REVIEW-FIX schema reuse) | ✅ shipped | gap 2 | **M** | L5 (for executable re-entry), L1 (derisks the table) | CGX | low |
| L8 | **`next_action` in the envelope + condition-derived "plan with no run" warning** | ✅ shipped | gap 3 | **S/M** | L6 | CG (hook), X via `/next` | low — additive schema |
| L9 | **Auto-continue Stop-hook mode** (`decision: block` chaining; opt-in knob, confirm-guard, hop budget) | ✅ shipped (opt-in, default off) | gaps 1+3+4 (the actual loop) | **M** | L4, L6; verify Copilot block-equivalent | **C** (G maybe, X no) | **medium — runaway-chain guardrails are the feature** |
| L10 | **`/sdlc --queue`** (state+priority selection, re-scan between items, stop conditions) | ✅ shipped | gap 4 | **M** | none (better after L4) | CGX | low — no git writes by construction |
| L11 | **`/pr-followup <pr>`** (PR threads/CI → classified → `/sdlc` on the branch) | ✅ shipped | gap 5 | **M/L** | L7's classification table | CGX (GitHub tooling varies) | medium — external-input handling |
| L12 | **Unattended delivery worker** (AUTONOMOUS-DISCOVERY pattern over the task queue) | ⏳ **deferred** — `scripts/loop-runner.sh` covers the attended batch case; the daemon remains an opt-in docs pattern | gap 4 ceiling | **L** | L4, L5, L7, L10 + real attended usage | deployment, not a skill | high — keep as docs/ pattern, opt-in infra |
| L13 | **Phase 6 `/deploy` / `/monitor` / `/rollback`** | ⏳ **deferred** | gap 5 ceiling | **L** | roadmap-scoped | — | as per BRAINSTORM-PIPELINE.md |

## Recommended sequence *(historical — Waves 1–3 are done; kept for the rationale)*

**Wave 1 — prose-only, ship immediately (L1, L2, L3).** No new skills, no schema changes;
three-way-sync edits to existing SKILL.md files + overlays. After this wave: every pause names
its recommended action, every delivery leaves its follow-up in the queue, and the seam behaves
the same on all three runtimes. The loop is still human-cranked, but every crank point now has
a labeled handle.

**Wave 2 — the two missing agents (L4, L5, L7, L6).** `/next` first (it's useful with zero
other changes and its ladder is where all future routing lands), then `--resume` + `/triage`
as a pair (recommendation without executable re-entry is half a feature), with the structured
sentinel (L6) landing alongside since `/next` and the gotcha seam both want it. After this
wave the user's ask is met in *attended* form: **"what's next" and "what's the fix" each cost
one command instead of an investigation.**

**Wave 3 — the loop itself (L8, L9, L10).** Durable next-action state, then auto-continue
chaining on Claude, then queue mode as the cross-tool equivalent. After this wave:
`/brainstorm foo` → plan → pipeline → next backlog item → … runs hands-off until a PR,
a red run, or a budget parks it — with every park being a resumable next-action, never a dead
end.

**Wave 4 — downstream and unattended ceilings (L11, L12, L13).** Only after Waves 1–3 have
real usage; each is independently justifiable and none blocks the others.

## Implementation pre-flight (applies to every wave — from `CLAUDE.md`)

- **New skills** (`/next`, `/triage`, `/pr-followup`): copy an existing skill's shape; register
  in `.claude-plugin/marketplace.json`; README table row; honest
  `metadata.brainstorm-toolkit-applies-to`; ≤100 lines for the utility skills; run
  `scripts/validate_skills.py` + the `setup.sh` round-trip.
- **Every prose change to `/sdlc` / `/sdlc` stage contracts** (L1, L2): prose first, then
  `sdlc-pipeline.workflow.js`, then the four overlays — the three-way-sync contract. L1's
  pause-message change touches the workflow's pause strings too.
- **Every new agent dispatch** (`/next`'s state-join, `/triage`'s classifier): Sonnet-first /
  Haiku-preferred, model-cap contract per `skills/sdlc/templates/models.md`; these are read
  jobs — there is no case for Opus.
- **Hook changes** (L6, L8, L9): the hook stays no-model, exit-0, never-blocks *in print mode*;
  auto-continue is a separately-gated mode, and `setup.sh`'s idempotent hook-wiring needs the
  new mode's knob plumbed.
- **Sentinel readers peek; only the hook consumes.** Write it into the seam contract doc the
  moment a second reader exists.

## What NOT to build (anti-levers)

- **A monolithic "orchestrator" skill that owns the whole loop.** The toolkit's strength is
  small skills sharing file contracts; the loop should emerge from queue + seam + conductor,
  each independently testable and independently skippable. (Same reasoning that kept the
  Workflow script a mirror of prose stages, not a replacement.)
- **Auto-continue default-on, or auto-continue into `/sdlc`.** The soft-stop philosophy
  ("earn the interruption" / never surprise with git writes) is load-bearing; the loop parks
  at PRs by design.
- **A second queue.** TASKS.md is the queue. Anything that wants future work done writes a row
  there (or a parked next-action). A parallel job store for the loop would split the state the
  conductor reads — the exact failure mode the state envelope was built to end.
