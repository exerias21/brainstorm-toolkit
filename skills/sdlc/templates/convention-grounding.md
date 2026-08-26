# Convention grounding — reuse what exists, ground in live code

Purpose: stop plans and implementations from **re-inventing what the repo
already has**. The source of truth is the **live code**, not `AGENTS.md` /
`CLAUDE.md` / `docs/` — those are *hints that may be stale*. Read them, but
verify against the code and trust the code when they disagree.

Run this **before generating approaches** (the brainstorm skills) or **before
writing code** (Stage 2 of `/sdlc-lite`). Scope the recon to the
feature's target area — do not survey the whole repo.

## Procedure

1. **Locate the 2–3 closest existing implementations** to what's being built —
   same layer, same kind of thing (another API route, another migration,
   another form component, another scraper, another CLI command). Use
   grep/glob over the target directories; let the existing code, not memory,
   tell you the shape.
2. **Extract the patterns they follow**, each with a `path:line` citation:
   - where new code of this kind lives (directory / module layout)
   - naming (functions, files, types, routes, tables, events)
   - error-handling and logging shape
   - the data-access / IO seam everything routes through
   - dependency + import conventions; shared utilities already available
   - test layout and style for this kind of code
3. **Read `AGENTS.md` / `CLAUDE.md` / `GOTCHAS.md` / `.claude/project.json`** as
   *stated intent*. Where a doc and the live code disagree, **the code wins** —
   record the conflict on the `Doc drift` line of the output block. A conflict
   means the doc is stale, so **make the drift actionable, don't just note it**:
   - in a brainstorm skill, add a `- [ ] (P3) Reconcile <doc> drift: <X> — code
     does <Y>` row to `TASKS.md` alongside the plan, so the stale doc gets fixed
     on its own track;
   - in `/sdlc-lite`, surface the drift in the Stage 6 hand-off / PR
     body and nudge `/gotcha` if it's a genuine trap.
   This is the loop that keeps `AGENTS.md` / `CLAUDE.md` honest over time —
   grounding consumes them as hints *and* repairs them when they lie.
4. **Decide reuse vs. new.** Prefer extending an existing module / helper / type
   / pattern over introducing a parallel one. Only introduce a *new* pattern
   when no existing one fits — and state *why* explicitly.

## Output — a `## Conventions & reuse` block

Emit a compact block the rest of the work binds to. In the brainstorm skills it
becomes a section of the plan file; in `/sdlc-lite` Stage 2 it is the
checklist the implementation must honor (and re-verify against live code, since
code may have moved since the plan was written):

```
## Conventions & reuse
- Follow: <pattern> — see `path:line`
- Reuse: <existing module/helper/type> for <purpose> — `path`
- New (justified): <thing>, because <no existing pattern fits>
- Doc drift: <AGENTS.md/CLAUDE.md says X but the code does Y>   # omit if none
```

A plan with **no** reuse opportunities and **no** justified new patterns is a
red flag — it almost always means the recon was skipped and the work will
re-invent something that already exists.
