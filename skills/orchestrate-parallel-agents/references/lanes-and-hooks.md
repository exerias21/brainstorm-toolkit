# Lane checkouts and project hooks

## Seeding a new lane

A new worktree holds tracked files only, so `lanes.sh create` seeds it in two steps:

1. **Copy** what `.worktreeinclude` lists: `.env`, local config, small gitignored inputs the
   tests read. Keep large or private data out of that file (captures, production exports):
   copying it into every lane spreads it.
2. **Set up** with `pipeline.parallel.lane_setup` from `.claude/project.json`, a command run in
   the new worktree's root (exit 3 if it fails; the lane is kept). Build dependency folders here
   instead of copying them: a venv holds absolute paths, and on a Windows drive under WSL
   (`/mnt/c`, `/mnt/e`) a fresh worktree's first `uv sync` was measured to give a broken venv
   (packages failed to import) until `uv sync --locked --reinstall --link-mode=copy`. Examples:
   `"uv sync --locked --directory engine --link-mode=copy"`, `"npm --prefix portal ci"`. The
   merge queue runs the same setup in its clean checkout.

## Git hooks are off for checkouts

`lanes.sh create`, `lanes.sh sync` and the merge queue's clean checkout run git with
`core.hooksPath=/dev/null`: a post-checkout hook that regenerates tracked files (measured
2026-11-15) left new lanes dirty and made the queue's "clean" copy refuse to rebase. Work
inside the lane still runs the hooks as usual.

## What `lanes.sh` records

Besides the worktree, `lanes.sh` keeps two files in `.claude/parallel/` that the merge queue
reads: `reviews.tsv` (`reviewed`: lane branch, sha, verdict, time, lane_id) and `reservations.tsv`
(`reserve-migration`: lane, number, folder, time). Only the orchestrator writes them, through
those subcommands: a writer never records its own review. `remove` drops a lane's
reservations; review rows stay, as history. How the queue uses both: `merge-queue.md`.

## A quiet lane (`lanes.sh list`)

`list` prints `quiet=<N>m` for every lane: the minutes since its branch last moved (created,
committed or rebased), read from the branch's reflog. A lane quiet for 60 minutes or more
that is not held is marked `STALE` (`--stale-after <minutes>` changes that for one call).
Nothing polls and no exit code changes: read it when a notification is overdue and before a
hand-off.

- `unlanded=0` with `STALE`: the lane landed and was never removed, or its writer never
  committed.
- `unlanded=<n>` with `STALE`: work is waiting on someone: a writer that stopped, a review
  nobody ran, an accepted lane nobody landed.
- `quiet=unknown`: the branch has no reflog. It is never marked.

The flag cannot see uncommitted edits, a runner still inside a call, or a review or queue
attempt (none of those move the lane's branch). Before acting, check `runner.sh status` and
the runner's `verdict.json` (missing means its call has not finished). Then resume the
writer, re-brief, land, hold (`lanes.sh held`) or remove the lane.

## The `tests changed` list (`lanes.sh verify`)

After the scope verdict, `verify` lists each changed file that looks like a test by name,
with its added and removed line counts, or says `tests changed: 0`. It is the verifier's
reading list (`verifier-brief.md`), never a gate: the exit code is the scope check's alone.
A project that names its tests another way gives the verifier its test paths in the brief.

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
