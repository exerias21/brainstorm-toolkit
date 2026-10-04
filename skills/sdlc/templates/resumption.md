# Resumption (`--resume`) — shared contract

Canonical for `/sdlc`. Its terminal stage is a hand-off that writes
`handoff.json`, never a PR.

`/sdlc <plan> --resume` picks up a paused/failed prior run instead of restarting
from Stage 1 — which would both re-spend every green stage and **overwrite the
failure evidence you're resuming to fix**. Behavior:

1. Read `.claude/pipeline/<slug>/run.json` (slug derived from the plan file
   exactly as Stage 1 does it). **If absent** → error: "no prior run for
   `<slug>` — run `/sdlc <plan>` without `--resume` to start fresh." Do not
   create a fresh run under `--resume`.
2. **Staleness guard.** If `run.json.plan_hash` ≠ the current plan file's hash,
   the plan changed since the paused run — **reject**: "plan `<slug>` changed
   since the paused run; start fresh (`/sdlc <plan>`) or revert the plan." Don't
   try to reconcile. (Optional/additive: a per-stage `prompt_hash` mismatch —
   the *toolkit* changed a stage's prompt since the run — may *warn* rather than
   reject; skip the check entirely when the field is absent.)
3. **Reconcile before trusting it.** If `run.json.stages_completed` is shorter than the
   passing sidecars actually on disk (a stage advanced its sidecar but the orchestrator never
   wrote it back to `run.json` — measured live at 31+ minutes stale on one run), rebuild it as
   a **union, never a replacement**: every name already in `stages_completed` that
   legitimately has no sidecar (today, only `secret-scan` — see `secret-scan.md` and
   `state-schema.md`) **plus** every `stage-outputs/<stage>.json` whose `status` is `"pass"`,
   in canonical pipeline order. Never shrink `stages_completed` to match the sidecar count —
   that silently drops `secret-scan` and reintroduces the exact sidecar ⇔ `stages_completed`
   false equivalence the next step corrects.
4. Determine the resume point: a stage is done when its `stage-outputs/<stage>.json` shows
   `status: "pass"` — **except `secret-scan`, which writes no sidecar by design** and is done
   when its name is already in the (reconciled) `run.json.stages_completed`. Done stages are
   **skipped and their output reused**. Resume at the first non-passing stage — normally the
   one `run.json.stage` names / the one that paused.
5. If a reused stage-output references a file that no longer exists (e.g. the
   plan was edited to remove a step) → reject with a clear error; don't be
   clever.
6. If the paused stage no longer exists in the current pipeline (a toolkit
   upgrade split it) → "stage `<old>` no longer in pipeline — start fresh." (A
   `--resume-from <stage>` override is a possible future addition; not v1.)
7. From the resume point onward, behave **identically to a fresh run** — same
   gates, same **shared 3-iteration fix budget** (it starts fresh for the
   resumed stages), same envelope updates; set `run.json.status = "in_progress"`
   on pickup.

Resume reads the prior sidecars off disk, so `--resume` always runs these prose stages.
