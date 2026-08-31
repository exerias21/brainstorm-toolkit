# Output verbosity — shared contract

Canonical for `/sdlc` (and its Copilot/Codex overlays).
Loaded at Stage 0/1, before any stage prints.

**Default `quiet`.** Stage narration is re-read by every later turn in the same session, so it
compounds — an audited run averaged 468k context across 5,321 orchestrator turns, and narration is
the cheapest part of that to give up. Detail is not lost: every stage already writes its sidecar
under `.claude/pipeline/<slug>/stage-outputs/`, which is the durable record.

Under `quiet`, each stage prints **one** line and nothing else:

```
<stage> · <verdict> · model: <tier> (cap: <cap|none>)
```

and the run closes with a single summary table at Stage 7. Do not narrate intermediate reasoning,
restate file contents, echo sub-agent output, or recap what a stage is about to do.

**Always printed, even under `quiet`** — these are the run's contract, not narration:

- the per-dispatch `model: <tier> (cap: <cap|none>)` line (the cap is only as real as this
  line — `validate_skills.py` soft-warns that a fan-out skill *references* `model-cap.md`, it does
  NOT check that the line is printed, so nothing but this instruction enforces it),
- every gate verdict and any PAUSE/soft-stop block,
- the `Next:` seam line,
- warnings: the Stage 0 config-presence check, the reviewer-axis cost note, the session-model nudge.

Set `pipeline.output.verbosity: "normal"` in `.claude/project.json` to restore full narration.
Read with graceful-skip — a missing `project.json` means `quiet`, which is the point: the savings
must not depend on a config file that the audited repo never had.
