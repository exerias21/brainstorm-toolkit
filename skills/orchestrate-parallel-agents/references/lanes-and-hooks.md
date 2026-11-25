# Lane checkouts and project hooks

## Git hooks are off for checkouts

`lanes.sh create`, `lanes.sh sync` and the merge queue's clean checkout run git with
`core.hooksPath=/dev/null`: a post-checkout hook that regenerates tracked files (measured
2026-11-15) left new lanes dirty and made the queue's "clean" copy refuse to rebase. Work
inside the lane still runs the hooks as usual.

## Tests that need gitignored inputs

A test that reads a file only the main folder has (a capture folder, a CSV export) fails in
every lane and in the queue's clean checkout. Either list the input in `.worktreeinclude`
(when it is small and not private) or, better, have the project make that test skip when its
input is absent. That is a project fix: name the tests in your report and leave the change to
the project's own work queue; do not count those failures against a lane.

## Interaction with project commit hooks

Some projects gate `git commit` with a hook (a Claude Code `PreToolUse` hook, a git
`pre-commit`) that runs the whole suite, sometimes for many minutes. Hooks in the project's
settings are tracked files, so they fire inside every lane too: each small lane commit then
pays the full suite, often against the main folder rather than the lane, and a runner's
10-minute Bash limit can kill it.

- The merge queue is the gate for lanes. Lane commits should not re-run the main tree's suite;
  the lane's own check is its fast test command.
- If the project's hook does run on lane commits, tell the human, with what it costs per
  commit. Exempting lane worktrees (for example branches `lane/*`, or any worktree other than
  the main one) is the project's decision. Do not edit, disable or bypass a project hook from
  this skill (the one exception to editing: a diff the human approved under skill section 13),
  and never brief a lane to use `--no-verify`.
- A hook keyed on `CLAUDE_PROJECT_DIR` sees the lane as the project root. Test one lane
  commit before dispatching a wave (`runners.md`).
- Until the project decides, keep lane commits few (one per finished step) and say in the
  brief that a commit may take as long as the hook does.
