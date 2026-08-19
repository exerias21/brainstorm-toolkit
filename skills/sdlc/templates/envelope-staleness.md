# Envelope staleness — shared scan

Canonical procedure for "find non-terminal pipeline envelopes and decide which are stale."
Loaded by `/status`, `/repo-health` (Check 7), `/next`, `/sdlc` and `/sdlc-lite`.

It lives in one file because it was written out five times and **had already drifted**:
`/sdlc`'s main-branch false-positive fix never reached `/status`. Five copies of a rule with
one copy fixed is worse than no rule.

## The scan

Glob `.claude/pipeline/*/run.json`.

- **Directory absent → skip silently.** It is gitignored and local-only; most repos won't have
  one. This is never a finding.
- For each run read `pipeline`, `stage`, `status`, `updated_at`, `base_commit`.
- **Non-terminal** = `status` is `in_progress` or `paused`.
- **Stale** = non-terminal AND `updated_at` older than
  `.claude/project.json::discipline.staleness_hours` (default `24`).

## The reconcile hint

If a flagged run records `base_commit` and that commit is already an ancestor of HEAD
(`git merge-base --is-ancestor <base_commit> HEAD`), the work landed outside the pipeline.
Append: *"looks committed outside the pipeline — reconcile."*

**Read-only.** Every caller surfaces this; none rewrites the envelope. `/status --prune-stale`
is the one confirm-gated exception, and it deletes envelopes rather than editing them.

## False-positive guards — the part that drifted

These are not optional polish; without them the scan cries wolf on every healthy repo.

1. **Skip entirely on the `main_branch`** (`.claude/project.json::main_branch`, default `main`).
   Main accumulates merges, so *every* merged run's `base_commit` is an ancestor of HEAD and
   every run looks reconcilable. Continuation is a feature-branch concern. This is the fix that
   existed in `/sdlc` and nowhere else.

2. **At most one report per scan.** Take the **single most-recently-updated** qualifying run,
   never one line per historical envelope.

3. **Silence when nothing changed.** A *complete* run whose recorded final commit still equals
   HEAD is not a finding. Only report a complete run when HEAD has advanced past its
   `commit_sha` (from `pr-create.json` / `handoff.json`) — that means follow-up work landed
   outside the pipeline.

## Caller-specific framing

The scan is identical everywhere; only the verb changes.

| Caller | Uses it for |
|---|---|
| `/status` | one line per non-terminal run, so a stalled pipeline can't hide |
| `/repo-health` Check 7 | a scored finding + the reconcile hint |
| `/next` | rung input — a paused run outranks a fresh task |
| `/sdlc`, `/sdlc-lite` | continuity detection at Stage 0/1 — **prompt, never auto-act** |
