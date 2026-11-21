# Step 7.5 — Size the plan against one execution session (body)

Loaded by `skills/brainstorm/SKILL.md` Step 7.5.

A plan is usually executed in a **fresh session** (`/sdlc <plan>`), so the plan itself
decides how big that session gets. Say so at authoring time, when splitting is cheap — not
during execution, where it isn't.

Estimate from the plan's own shape and state it in one line:

- **files touched** and **implementation steps** (both already parsed above),
- **surfaces** crossed (backend / frontend / data / docs),
- whether the steps are **sequentially dependent** (they must share a session) or
  **independent** (they need not).

Then print, once:

```
plan size: <n> steps across <m> files, <k> surface(s) — <one execution session | splittable>
```

**"Splittable" is information, not an instruction.** Recommend a split only when the steps
are **independent**, because then a second session costs nothing but re-reading the plan,
and each slice starts clean. Never split a sequentially-dependent chain to hit a number;
that trades real working context for a metric.

If the user shares the last run's cost report, prefer its measured number over this
estimate.
