# The merge queue (`scripts/merge-queue.sh`)

The one door every lane lands through. Opt-in: nothing runs it but you.

```bash
bash scripts/merge-queue.sh land lane/<name> [lane/<name2> ...] [--target main] \
  [--verify-tests <slug> [--pipeline-dir .claude/pipeline]] [--dry-run]   # no --test-cmd, see below
bash scripts/merge-queue.sh log 10     # recent verdicts (.claude/parallel/merge-queue.jsonl)
cat .claude/parallel/merge-queue.verdict.json   # this run: {"exit": N, "result": ..., "branch": ...}
```

**Several branches, one landing.** `land lane/a lane/b` rebases them in the order given onto the
target in one clean checkout, runs the gate once on the combined result, and moves the target
once (one compare-and-swap): all land or none. Use it for lanes that only pass together, for
example two lanes that each change a string a shared test pins. A conflict between them is
exit 2 with the files named, as for one lane. Single-branch behaviour and exit codes are
unchanged.

**Never pass `--test-cmd` narrower than the configured gate.** It exists for projects with no
configured gate. When `pipeline.parallel.gate_command` or `test.unit` is set, `--test-cmd`
prints `WARNING: --test-cmd overrides the configured gate` and the verdict records
`test_cmd_override: true`; every verdict records the command it ran as `test_cmd`. Check
`bash scripts/merge-queue.sh log` for `"test_cmd_override":true` before you trust a run of
landings: in the first trial ad hoc narrow commands were passed on every landing and the
project's full gate never ran.

What it does, in order:

1. Takes the `merge-queue` lease (a second caller is refused, exit 3, not queued).
2. If the target is checked out somewhere, refuses (exit 6, paths named as `dirty: <path>`)
   when a modified, staged or untracked file there is on a path the lane changes
   (`git diff --name-only <target>...<lane>`), or when the lane adds a file that already exists
   there untracked or ignored. Unrelated uncommitted work does not block: a busy main folder
   always has some.
3. Records the target's tip, then rebases the lane's commits onto it in a throwaway detached
   worktree. The lane's own branch and folder are not touched.
4. Seeds that checkout like a lane (`.worktreeinclude` copies, then
   `pipeline.parallel.lane_setup`; a failed setup is exit 4), optionally runs
   `scripts/protect-tests.sh verify --slug <slug>`, then runs the full test command:
   `--test-cmd`, else `pipeline.parallel.gate_command`, else `test.unit`. None at all is a
   refusal (exit 4): no tests is not a pass. The suite can take as long as it takes, so run the
   queue with `run_in_background`; the lane's fast command (`fast_test_command`) is not used here.
5. Repeats the step-2 check (the folder may have been edited during the test run), then
   `git update-ref refs/heads/<target> <new> <old>`: moves the target only if it still points
   where step 3 found it. If the target is checked out, only the lane's paths are moved forward
   in its folder (`git read-tree -m -u <old> <new>`); every other file, staged or not, stays as
   it was.
6. Appends a verdict line and prints `LANDED ... Not pushed.` It never pushes.

| Exit | Meaning | Your next step |
|---|---|---|
| 0 | landed, dry-run passed, or nothing to land | `lanes.sh remove <name>`; tell sibling lanes to `lanes.sh sync` |
| 2 | conflict | the conflict path below |
| 3 | queue busy | land it after the current landing's notification |
| 4 | tests failed, protected tests changed, lane setup failed, or no test command | send the failure (log at `.claude/parallel/merge-queue.last-test.log`, setup at `merge-queue.last-setup.log`) back to the lane's writer; a test that fails only because a gitignored input is missing is a project fix (skill section 5), not the lane's |
| 5 | target moved during the run | re-run; it rebases on the new tip |
| 6 | uncommitted or untracked files in the target's folder on the lane's paths, or it could not be moved forward | commit, move or discard just the named paths (they are usually yours), re-run; never stash or reset the whole folder, other work lives there |

## The conflict path

On a conflict the queue aborts the rebase, changes nothing, prints `conflict: <file>` lines
and exits 2. Then:

1. **Stop.** Do not resolve it yourself and do not ask a different agent to.
2. **Report** the files on the board (`@<name> blocked conflict: a.py, b.py`).
3. **Hand back** to whoever owns the files:
   - if they are inside the lane's owned paths, resume the lane's writer with the file list and
     "run `bash scripts/lanes.sh sync <name>`, resolve within your owned paths, re-run your
     acceptance command, commit"; it then reports `ready-for-review` again and goes back
     through the verifier and the queue;
   - if another lane or the target changed the same files, the lanes were not disjoint. That is
     a planning error for the orchestrator: decide which change wins, re-brief, and record it.
     Bring the human in if the two changes encode different intentions.
4. Never auto-resolve, never pick "ours" or "theirs" wholesale, never drop a commit to make a
   rebase pass.

Fewer conflicts start upstream: disjoint owned paths, shared files edited only by the
orchestrator, short lanes, and `lanes.sh sync` after every landing in the wave.
