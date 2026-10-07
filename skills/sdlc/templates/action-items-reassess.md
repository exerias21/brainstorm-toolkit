# Action items — reassess (shared)

Loaded from Stage 6 step 3 only when `pipeline.action_items.reassess` is true **and** the
`open_hash` from the last `waves` run differs from the bare file
`.claude/pipeline/.action-items-hash`. The gate lives in `stage-6-handoff.md`; if you are here, it
passed. This step **never fails Stage 6**: any error below ends the step, not the run.

The deterministic rules in `close-tasks.sh waves` cannot see a dependency or conflict that no
`Files:` line names. One agent proposes `_after:` / `_lane:` / `_conflicts:` tags for those;
code decides what is applied. **At most one agent per run** — never one per row.

## Dispatch

Resolve the tier per `skills/sdlc/templates/models.md` (Axis 1, **Sonnet by default** — `--model`
> `models.cap` > default, never above the cap), then print the line before dispatching:

```
model: <resolved-tier> (cap: <cap|none>)
```

One `general-purpose` agent, explicit `model:` — a dispatch with no `model` bypasses the cap with
no log line. No `agents/` file. Input: the `waves` JSON you already hold plus the plan-phase
excerpts (the `#### Phase N` section from the plan file) for every `now` and `next` row. Prompt
must carry, verbatim:

> GIT: never run a git command that writes — no stash, commit, checkout, switch, reset, restore, rebase, merge, clean, or branch creation. The working tree holds the user's uncommitted work; git that only reads (status, diff, log, show) is fine.

and also say: you are read-only; do not edit `TASKS.md` or any file; return JSON only — a list of
`{row, tag, evidence}` where `row` is a needle that whole-token matches exactly one open row,
`tag` is `after:<plan>[:<phase>]`, `conflicts:<plan>[:<phase>]` or `lane:<name>`, and `evidence`
is one line **copied exactly** from the plan text that justifies it. No evidence, no proposal;
return `[]` when nothing is certain. A guessed `_after:` parks the queue.

## Verify, then apply

For each proposal, in order:

1. Confirm `evidence` appears verbatim (after trimming surrounding whitespace) in the text of the
   plan the row belongs to. Not found → rejected.
2. Apply with `bash scripts/close-tasks.sh tag --file TASKS.md --row '<row>' --add '<tag>'` and
   read its JSON. An `{error, code}` reply (unknown plan, ambiguous needle, bad grammar) →
   rejected.

You never edit `TASKS.md` by hand and never touch checkbox state; `tag` is the only writer.
Rejected proposals go to `data.waves.rejected[]` as `{row, tag, reason}` and are never retried or
applied another way.

## Finish

If anything was applied, regenerate (`bash scripts/close-tasks.sh waves --file TASKS.md --write <file>`)
and use that result for `data.waves`. Then write the final `open_hash` — from the regenerated JSON,
or the original when nothing changed — to `.claude/pipeline/.action-items-hash` so the next run
skips this step until the open rows change. The hash lives in that bare file, never in a
subdirectory: `board` and envelope staleness read any subdirectory of `.claude/pipeline/` as a run.
