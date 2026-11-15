# Hand-off note format

A hand-off note lets a fresh session continue another session's work without its transcript.
`runner.sh` asks for one automatically when it rotates a runner (the prompt it sends asks for
exactly this shape and saves the reply to `.claude/parallel/runners/<name>/handoff-<n>.md`).
Use the same shape when you rotate by hand or move a lane to a new driver.

```markdown
## Goal
<the lane's goal, from its brief>

## Done
- <change> -- <file paths>, commit <sha> on lane/<name>

## In progress
<exact state of anything half-done: which file, which function, what is uncommitted>

## Next steps
1. <first concrete action>
2. ...

## Decisions and constraints
- <what was ruled, by whom (human, orchestrator, brief), and where it is recorded>

## Open questions and denials
- <anything refused, verbatim, and whether it went to the orchestrator>
```

Rules:

- Under 60 lines. It is a pointer to the work (branch, commits, result file), not a copy of it.
- Facts with provenance: a commit sha, a command and its exit code, a `path:line`. "Tests pass"
  without the command is a claim the next session will over-trust.
- Uncommitted work is named file by file. Better: commit it on the lane branch before rotating.
- Denials are copied verbatim and marked as already escalated or not. The new session must not
  retry a denied action by another route.
