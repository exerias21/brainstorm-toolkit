# Lane brief template

Fill one per writer. The brief is the worker's whole world: it knows only what is written
here, so anything you leave out it will guess. Paste it as the subagent prompt, or save it to
`.claude/parallel/briefs/<name>.md` and pass it with `runner.sh start <name> --prompt-file`.

```markdown
# Brief: @<name>

## Goal
<one or two sentences: the outcome, not the method>
The orchestrator checked on <date> that this is still open: <what was checked>. If you find it
is already done, prove it with the tests below and change nothing; report `already-done` with
the evidence.

## Where you work
- Worktree: <absolute path>   Branch: lane/<name>   Target: <main>
- Expected base: <sha from `lanes.sh create`'s base=, or the target tip>
- **First step:** run `git log --oneline -1`. If the sha does not start with the expected base
  (and you have made no commits yet), stop: append `blocked wrong base` to the board and report.
  Do nothing else first; a worktree on an old base wastes every later step.
- Commit on your lane branch as you go (small commits). Never push, merge, rebase onto
  anything but <target>, reset, or check out another branch. Never `--no-verify`. <If the
  project has a commit hook that runs its suite: "a commit may take up to <N> minutes; commit
  once per finished step.">

## You own (the only paths you may change)
- <path or glob>
- <path or glob>

## You must not touch
- <paths other lanes own>
- Shared bookkeeping: TASKS.md, decision logs, lock files, version numbers, migrations
  (unless listed above). If your goal seems to need one of these, stop and report `blocked`.

## Project rules that apply here
<quote the relevant lines from the project's CLAUDE.md / AGENTS.md word for word>

## Shared resources (leases)
- You may take: <resource names, or "none">
  `bash scripts/lease.sh acquire <res> --holder @<name> --ttl <s>`; release when done.
- If acquire is refused: append `blocked` to the board and stop. Do not wait in a loop.

## Done means
- Your test command passes in your worktree: `<pipeline.parallel.fast_test_command, or the
  targeted tests for your owned paths>`. It must finish well under 10 minutes; do not run
  the full suite (`<gate_command>`): the merge queue runs it once, at landing.
- Diff touches owned paths only: `git diff --name-only <target>...HEAD`
- <any other measurable check>
- Known failures that are not yours: <tests that fail in any fresh worktree, e.g. ones that
  need gitignored inputs, or "none">. Report them; do not fix them.

## Shell rules (your permissions match one command at a time)
- **One command per Bash call.** No `cd`, no `&&`, `;`, `|`, `>` or `2>&1`. A chained
  command matches no permission rule and is denied.
- Run every tool from the worktree root with its own directory flag:
  `<e.g. uv run --directory engine pytest tests/test_x.py -q>`,
  `<e.g. npm --prefix portal test -- --run src/x.test.ts>`.
- To read long output, rely on the tool's own quiet flags (`-q`, `--reporter=dot`), not a pipe.

## Working rules
- Run long commands in the background and wait for the notification; never poll.
- Never `pgrep -f <name>` without the bracket trick (`pgrep -f "[n]ame"`).
- If a tool call is denied, do not try another route to the same action. Report it.
- Do not message other agents. Append status to `.claude/parallel/board.md`:
  `<UTC ts> @<name> <started|blocked|ready-for-review|abandoned> <one line>`

## Hand back
Write full detail to `.claude/parallel/results/<name>.md` (what changed, files, commands run
with exit codes, anything unverified). Return at most 40 lines: verdict, branch, last commit,
the acceptance result, blockers, and that path.
```

Checklist before dispatch: the item is confirmed still open (or the brief says how to prove
it done); the expected base sha is filled in; owned paths are disjoint from every other lane's;
the test command runs without a human, in under 10 minutes, and as a single command; the
runner's allowlist covers every command the brief names, written the same way; every lease
named exists in the project's rules; the model is resolved and printed.
