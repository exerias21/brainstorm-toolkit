# The merge queue (`scripts/merge-queue.sh`)

The one door every lane lands through. Opt-in: nothing runs it but you.

```bash
bash scripts/merge-queue.sh land lane/<name> [lane/<name2> ...] [--target main] \
  [--verify-tests <slug> [--pipeline-dir .claude/pipeline]] [--dry-run]   # no --test-cmd, see below
bash scripts/merge-queue.sh log 10     # recent verdicts (.claude/parallel/merge-queue.jsonl)
cat .claude/parallel/merge-queue.verdict.json   # last run: {"exit": N, "result": ..., "branch": ..., "pid": ...}
# Two callers at once share that file; give each its own with --verdict-file PATH.
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
| 0 | landed, dry-run passed, or nothing to land | `lanes.sh remove <name>`; tell sibling lanes not yet accepted to `lanes.sh sync` |
| 2 | conflict | the conflict path below |
| 3 | queue busy | land it after the current landing's notification |
| 4 | tests failed, protected tests changed, lane setup failed, or no test command | send the failure (the log the message names, also copied to `.claude/parallel/merge-queue.last-test.log`; setup at `merge-queue.last-setup.log`) back to the lane's writer; a test that fails only because a gitignored input is missing is a project fix (skill section 5), not the lane's |
| 5 | target moved during the run | re-run; it rebases on the new tip |
| 6 | uncommitted or untracked files in the target's folder on the lane's paths, or it could not be moved forward | commit, move or discard just the named paths (they are usually yours), re-run; never stash or reset the whole folder, other work lives there |
| 7 | the review or migration-number check refused, or one of the opt-in keys could not be read | follow the message (below); never work around it by editing `reviews.tsv`, `reservations.tsv` or the config |

## Opt-in checks

Each is off while its `.claude/project.json` key under `pipeline.parallel` is unset. If the
file names a key but it cannot be read (bad JSON, wrong type), the queue refuses (exit 7).

### Re-review gate (`review_required_paths`)

A list of globs for the paths where an unreviewed fix is not acceptable (money, personal data,
guards, gates). `*` crosses `/`; a trailing `/` means the subtree; a leading `**/` also matches
at the root. Braces are not expanded: write one entry per alternative. An entry that could
never match is refused (exit 7, `refused-config`): one with `{`, one starting `./` or `/`, or a
folder written without its trailing `/`. So is a glob (`*`, `?`, `[`) that does not end in `/`
and has no `*` in its last segment (`engine/*/ledger`; also `**/guard.js`, which would match).

```bash
bash scripts/lanes.sh reviewed <lane> <sha> [--verdict accept|fix|reject]   # .claude/parallel/reviews.tsv
```

Record the sha the reviewer read, not whatever the lane is at when you type it; only a sha on
the lane is taken. A lane whose diff touches a listed path lands only if its latest row is
`accept` and the head has the same content as that sha. So no row at all is a refusal, and so
is any later commit, even one outside the listed paths. The message lists the paths changed
after the review. A rebase or amend that changes content also needs a new row, so sync before
the review, never after an accept (the queue rebases an accepted lane itself). Only a conflict
justifies a sync after an accept, and it needs a new `reviewed` row. Send the
reviewer just the change since the accepted sha, then record the new one. The record belongs
to a `lane/<name>` branch, so another branch touching a listed path cannot land while the
check is on.

### Migration numbers (`migrations_dir`)

The folder of revision files, relative to the repo root (for example `db/versions`). A
revision is a file directly in it whose name starts with digits then `.`, `_` or `-`.

```bash
bash scripts/lanes.sh reserve-migration <lane> [--dir <versions dir>]   # reserved: 0103 lane=<lane> dir=...
bash scripts/lanes.sh release-migration <lane> [--number N]
```

The number is one above the highest among the target's files and the open reservations
(`.claude/parallel/reservations.tsv`). Reserve before the writer creates the file and put the
number in the brief. `lanes.sh remove` drops the lane's reservations. The queue refuses a
landing that adds a revision whose number another file in the folder already has (on the
target or in the same landing), or that another lane reserved. Files sharing a stem
(`0005_x.up.sql`, `0005_x.down.sql`) count as one revision. The queue compares file names
only: the project's own tests must check revision ids and the parent chain inside the files.
A `migrations_dir` that neither the target nor the landing has is refused too (exit 7,
`refused-config`).

### Flake triage (`rerun_check_command`)

A command containing `{check}`, for example `"bash ci/run-check.sh {check}"`. The gate says
which check failed by printing one line per failed check:

```
merge-queue-failed-check: <name>
```

and, as the **last line** of its output once every check has run, the number of failures:

```
merge-queue-gate-complete: failed=<n>
```

Count every failure in `<n>`, including steps outside the named checks (a coverage threshold, a
later script step). **Print these lines only from a gate that runs every check to the end.** A
gate that stops at the first failure (`a && b && c`) has not run what came after, and a passing
rerun of `b` would land the lane with `c` never run. Print the sentinel
(`merge-queue-gate-complete`) as the gate's last statement, never from an `EXIT` trap, which
also fires when the gate dies partway.

The queue reruns once, only when the output names exactly one distinct check, with a name of
letters, digits and `._/:=@+-` that does not start with `-`, the last line is
`merge-queue-gate-complete: failed=1`, and the exit code is below 126 (a killed
gate is never rerun; a timed-out gate prints no sentinel). Anything else is a plain `tests-failed`. If the rerun passes, the landing goes on and its verdict line in
`merge-queue.jsonl` carries `"flake":"flake:<name>"`. A check with two such records in the
last 7 days is not rerun: the verdict is `flake-limit` (exit 4). Open a task to fix that
check; the queue does not write `TASKS.md`.

With or without this key, each test run keeps its own log,
`.claude/parallel/merge-queue.logs/<branch>-<n>.log` (`/` becomes `-`, several branches are
joined by `+`). `merge-queue.last-test.log` is a link to the latest, made before the run starts,
so it can be followed live (a copy made at the end where links are not supported).
Nothing prunes the folder.

## Queue events

Each verdict also writes one `queue.attempt` per branch to
`.claude/parallel/events.v1.jsonl` (envelope in `runners.md`), with that lane's `lane_id`.
Fields: `result` (the verdict above), `failed_check` (set when the gate named exactly one check,
with or without `rerun_check_command`; only the part after the last `/`, null if it has other
unusual characters), `flake_suspected` (a rerun passed, or `flake-limit`), `duration_s`,
`old_sha`, `new_sha` (null when nothing was rebased), `batch_size` and `batch_index`. A busy or
usage exit writes none. The verdict's `detail` and test command stay in `merge-queue.jsonl`.
`lanes.sh reviewed <lane> <sha> --reviewer-model M` writes `review.verdict`.

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
orchestrator, short lanes, and `lanes.sh sync` after every landing in the wave (for lanes not
yet accepted, see the re-review gate).
