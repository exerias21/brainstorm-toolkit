# Gap 5 — No downstream re-entry: the loop ends at the PR

**Gap:** the pipeline's last back-edge is the Stage 4–5.6 fix loop. After Stage 6, everything
is outbound: PR created, `/review` fired once into the chat, report printed, done. PR review
comments, CI results, the merge itself, and the deployed system's behavior never re-enter the
loop as work items. The one knowledge back-edge that *does* exist — the gotcha flywheel — closes
the **learning** loop, not the **work** loop.

**Levers:** cheap TASKS.md re-entry rows at Stage 6 (today), a PR-followup skill (near-term),
and the already-specced Phase 6 `/monitor` back-edge (the roadmap's own answer, unbuilt).

---

## The missing back-edges, concretely

| Event after Stage 6 | What should happen in a closed loop | What happens today |
|---|---|---|
| Reviewer leaves change requests on the PR | comments become a fix run on the branch | nothing — the session that made the PR is usually gone; no skill reads PR comments |
| CI fails on the PR | failure becomes a triage + fix run | nothing — the toolkit never looks at CI |
| PR merges | post-merge verification fires (`/post-deploy-verify` plan-fallback); TASKS row for "verify <slug> deployed" closes | nothing — merge is invisible; `/post-deploy-verify` exists and works via plan fallback but only if a human remembers it |
| Deploy goes out | `/monitor` polls health; failures re-enter as new tasks | Phase 6 — unbuilt (`BRAINSTORM-PIPELINE.md`) |
| A gotcha-worthy trap surfaced | durable GOTCHAS.md entry, injected into the *next* brainstorm/implement | ✅ this one works — capture at loop-exit + scoped injection at `/brainstorm` Step 2 |

Note the asymmetry: the toolkit invested heavily in the *pre-merge* verification ladder
(evals → test-check → plan-validate → flowsim → designed review-fix) and in the *knowledge*
loop, while the *post-merge* half of the lifecycle has exactly one partially-usable skill and
one unbuilt phase.

## Lever A — re-entry rows at Stage 6/close-out (prose-only, ship anytime)

The cheapest closure is to make the pipeline **leave its own follow-up in the queue** it
already maintains. At `/sdlc` Stage 6 (and `/sdlc` close-out), append conditional rows:

- Always (PR path): `- [ ] (P2) verify PR #N of <slug> — merged & deployed → /post-deploy-verify plans/<slug>.md`
- If the deploy-delta surface was touched (the changed-files gate already computes this for
  the Stage 7 rebuild warning): a `(P1)` row naming the rebuild.
- If a soft-stop was overridden: the debt row (already specified in the soft-stop tier — this
  lever just generalizes the mechanism).

With gap 4's queue driver, these rows make the loop literally self-feeding: a delivery run
enqueues its own verification run. Without it, they at least surface in `/sdlc-status` and `/next`
instead of living in nobody's memory. Cost: a few lines of prose in two skills + overlays
(three-way-sync applies). No new artifacts, no new skills.

## Lever B — `/pr-followup <pr>` (the PR back-edge as a pull, not a push)

A small skill that makes "react to what happened to my PR" a single command:

1. Read the PR's state: review threads, requested changes, CI status (via the available
   GitHub tooling on the runtime — `gh` locally, MCP GitHub tools on hosted runtimes).
2. Classify each open thread the way `/triage` classifies sidecars (gap 2): actionable code
   change / question needing a human answer / stale.
3. Draft the fix batch and run it through **`/sdlc` on the PR branch** — which is
   *exactly* the use case `/sdlc`'s own description already advertises ("full discipline
   on work you'll review + commit yourself, e.g. onto an open PR branch"). The skill is the
   missing connector between the PR and that advertised use.
4. Close the loop in the envelope: the run's `run.json` records `pr_followup_of: <pr>`.

Push-based watching (the session subscribes to PR events and reacts) exists on some runtimes
(hosted Claude Code exposes PR-activity subscription), but a pull-based skill is
runtime-neutral, matches the toolkit's cross-tool posture, and composes with `/next` (rung:
"open PR with unresolved change requests → `/pr-followup`").

## Lever C — promote `/post-deploy-verify` from "remembered" to "routed"

The skill already solves its hard problem (probe machinery + plan-fallback so it works without
the Phase-2 BRD world). Its gap is *invocation*: nothing routes to it. Three routings, all
small:

- The Lever A row (above) — queue-based.
- A `/next` ladder rung: merged PR whose slug has no `post-deploy-verify` record → recommend it.
- Its findings must land somewhere loop-shaped: failed probes append TASKS.md rows (same
  re-entry convention as everything else), not just a red/yellow/green matrix in chat.

## Lever D — Phase 6, scoped honestly

`/deploy`, `/monitor`, `/rollback` remain the roadmap's real downstream closure, and
`/monitor`'s spec ("feeds failures back into TASKS.md as new PBIs") is the fully-autonomous
version of this whole document. Nothing here blocks on it, and everything here survives it:
Levers A–C are the manual-cadence versions of the same back-edges, and the TASKS.md re-entry
convention they establish is exactly the contract `/monitor` would write into.

## Design principle worth writing down

Every lever above is one rule applied four times: **any event that demands future work must
end as a TASKS.md row (or a parked next-action), because those are the only two places the
loop looks.** A report, a chat message, or a PR comment that isn't reflected into the queue is
invisible to every conductor, driver, and status readout this analysis proposes. When
implementing any downstream feature, the acceptance test is: *"after this fires, does `/next`
know about the resulting work without being told?"*
