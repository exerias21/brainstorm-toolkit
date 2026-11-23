---
name: orchestrate-parallel-agents
description: >
  Run several coding agents on one repo at once without merge chaos: one git
  worktree per writer, briefs with owned and forbidden paths, a verifier per 2-4
  workers, expiring leases for shared resources, managed headless runners that
  resume and rotate, and one serial merge queue. Use when the user wants to
  "parallelise", "run agents in parallel", "split this across workers", "swarm",
  set up runners or lanes, land several branches safely, report what runners
  cost, or debug a lane that was denied, built on the wrong base, or cannot land.
argument-hint: "plan-file | task range | description"
metadata:
  brainstorm-toolkit-applies-to: claude
---

# Orchestrate parallel agents

You are the **orchestrator**. You plan, brief, route and land. You do not do the technical
work yourself: the moment you start editing code, nobody is watching the lanes, and your
context fills with one lane's detail while the others wait.

> **Toolkit paths.** Every toolkit script or template path cited here resolves, first hit wins, against: a repo-local copy installed by `setup.sh`; else the plugin root (this skill's base directory two levels up, `<base>/../..`) when it holds that path; else `~/.claude/brainstorm-toolkit/` (the global shell install).

Project rules (which database, which ports, which paths are protected, what may never be
written) live in the project's `CLAUDE.md` / `AGENTS.md`. Read them first and quote the
relevant ones into every brief. This skill carries none of them.

## 1. When not to parallelise

Check this first. Parallel work costs more tokens (each agent pays for its own context;
multi-agent work runs several times the cost of one agent) and moves the bottleneck to the
one human who reviews everything. Do **not** parallelise when:

- **One writer is enough.** The change is small, or one linear agent finishes it in a sitting.
- **The parts are not independent.** Steps that share files, a schema, or a design decision
  still being made. Parallel agents make clashing implicit decisions; split only after the
  decision is written down.
- **The pieces would touch the same files.** If `waves` (below) cannot put them in separate
  lanes, run them in sequence.
- **Nobody can review the output.** Writers beyond what the human can review only grow a queue.
- **It is read-only work.** Research, review and measurement need no lanes, no worktrees and
  no queue: fan them out as ordinary background subagents in the shared folder.

If any of these hold, say so in one line and run the work serially (or with `/sdlc`).

## 2. Roles

| Role | Who | Does |
|---|---|---|
| Orchestrator | you | splits work, writes briefs, opens lanes, reads results, runs the merge queue, escalates |
| Worker (writer) | one named agent per lane (`@api`, `@ui-1`) | edits only its owned paths, in its own worktree, commits on its lane branch |
| Verifier | one per 2-4 workers, read-only | reads each lane's diff, runs its tests, sends problems back to **the writer that owns them** |
| Read-only helper | any number | research, review, measurement in the shared folder |

Give every agent a name and use it everywhere: brief, board, branch (`lane/<name>`), runner.

**Cost guidance.** Start with **2-3 writers**, not more. Workers run on Sonnet; the verifier
on a stronger model (Opus) because it is the independent check. Headless runners take their
model from `models.runner` in `.claude/project.json` (default `sonnet`, lowered by
`models.cap`); `runner.sh start --model M` overrides it for one runner. Idle workers cost nothing:
a background subagent that finished, or a headless runner between calls, holds no tokens.
Resolve each dispatch's model through `skills/sdlc/templates/models.md` when the project
sets `models.*`; the defaults above apply when it does not.

## 3. Plan the lanes

1. Run `bash scripts/close-tasks.sh waves --file TASKS.md` when the work is in `TASKS.md`. It
   already groups open rows into parallel waves by their `_lane:`, `_conflicts:` and `_after:`
   tags, and warns when a row's files are dirty in another worktree. Use its `now` wave as the
   lane list; do not invent a second planner. For ad-hoc work, list the files each piece
   touches and group by disjoint file sets yourself.
2. For each lane write down **owned paths** (the only files it may change) and **forbidden
   paths** (everything another lane owns, plus shared files only you edit: `TASKS.md`,
   lock files, migrations, changelogs, version numbers). Overlap between two lanes' owned
   paths means they are one lane. **Before splitting by directory, grep the tests for the
   strings the lanes change** (labels, messages, fixture names). A pinned string or shared
   fixture makes two lanes one lane, or two lanes that must land together
   (`merge-queue.sh land lane/a lane/b`). List the tests that pin a lane's files as that
   lane's owned paths in its brief, or the writer cannot update them.
3. **Confirm each item is still open before you brief it.** A task list goes stale: in the
   first trial a lane was briefed on a row whose work had already landed, and the runner spent
   its whole budget rediscovering that. Spend one or two reads checking the code (does the
   function, route or test the row asks for already exist?). If it looks done, close or re-scope
   it yourself; if you cannot tell, say in the brief "if this is already done, prove it with the
   tests and change nothing".
4. Keep lanes **short-lived**: one task, landed within a sitting or a day. A long-lived
   branch is where large conflicts grow.
5. Cap writers at `pipeline.parallel.max_writers` from `.claude/project.json` (default 2).

## 4. Pick the driver

| Work | Driver | Isolation |
|---|---|---|
| Writes code, fits one sitting | background subagent (Agent tool, `run_in_background`) | a lane from `scripts/lanes.sh create`, or `isolation: "worktree"` with the tip check below |
| Writes code, longer than a sitting or must outlive this session | managed headless runner, `scripts/runner.sh` | a lane from `scripts/lanes.sh create` |
| Read-only | background subagent, no isolation | shared folder |

Agent teams are out: they add live chatter and token cost, not isolation. Hand-kept runner
terminals that chat with you are out: replace them with `runner.sh`.

A background subagent's permission prompts surface in your session; a headless runner has
nobody to ask. Read `references/runners.md` before starting the first runner of a session.

**Prefer `lanes.sh create` for every writer.** It bases the lane on the main worktree's HEAD
and prints that sha (`base=`). The harness's `isolation: "worktree"` picks its own base, and
in one measured case it handed a subagent a worktree 517 commits behind the current branch
tip, so everything the agent did was wasted. If you do use `isolation: "worktree"`, put the
expected tip sha in the brief (the template has a slot) and make the agent's first step
`git log --oneline -1`, stopping with `blocked` unless it matches.

## 5. Open a lane

```bash
bash scripts/lanes.sh create <name>          # branch lane/<name>, sibling worktree
# -> lane=<name> branch=lane/<name> base=<sha> path=<dir>
```

A new worktree holds tracked files only, so `create` seeds it in two steps:

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

**Project git hooks are off for checkouts.** `lanes.sh create`, `lanes.sh sync` and the merge
queue's clean checkout run git with `core.hooksPath=/dev/null`: a post-checkout hook that
regenerates tracked files (measured 2026-11-15) left new lanes dirty and made the queue's
"clean" copy refuse to rebase. Work inside the lane still runs the hooks as usual.

**Tests that need gitignored inputs.** A test that reads a file only the main folder has (a
capture folder, a CSV export) fails in every lane and in the queue's clean checkout. Either list
the input in `.worktreeinclude` (when it is small and not private) or, better, have the project
make that test skip when its input is absent. That is a project fix: name the tests in your
report and leave the change to the project's own work queue; do not count those failures
against a lane.

Then take any lease the lane needs (section 8) and write its brief. All four scripts keep their
state in `.claude/parallel/` of the main worktree; make sure the project gitignores it before
the first lane.

## 6. Brief every writer

**Read `references/brief-template.md` now** and fill it for each lane. The non-negotiables:
the expected base sha, owned paths, forbidden paths, the lane's test command, the leases it
may take, the shell rules below, where it writes its result, and the 40-line return limit (detail goes in the result file, as in
`skills/sdlc/templates/output-verbosity.md`). If the lane runs `/sdlc`, say that Stage 2's
separate implement agent is required: a delegated run that skips stages while reporting a
full run is a measured failure.

**One command per Bash call.** Permission rules such as `Bash(uv run:*)` match a single
command. A chained call (`cd engine && uv sync | tail; uv run pytest`) matches none of them,
so a headless runner is denied every time; in the first trial every Bash call was refused
this way and the run ended with nothing done. The brief therefore tells writers: no `cd`, no
`&&`, `;`, pipes or redirection; run each tool from the worktree root with its own directory
flag (`uv run --directory engine pytest ...`, `npm --prefix portal test`); plain `git status`
works as is, since the worktree root is the cwd. Allowlists that fit this rule are in
`references/runners.md`.

**Gate tiers.** A lane runs `pipeline.parallel.fast_test_command`: targeted or sampled tests
that finish well under 10 minutes, because an agent's Bash call is killed at 10 minutes (a
full suite that ran longer was killed mid-baseline in the second trial). The full suite,
`pipeline.parallel.gate_command`, runs only in the merge queue. Without a fast command, name
the targeted tests for the lane's owned paths in the brief yourself.

## 7. Run, wait, and the board

- Dispatch all lanes of a wave in one message. Then **wait for the background-task
  notification**. Never poll: no `sleep` loops, no `watch`, no re-reading an output file to see
  if it is done.
- If you must test whether a process is alive, never `pgrep -f <name>`: it matches its own
  command line and reports "still running" forever. Use the bracket trick:
  `pgrep -f "[m]y-script.sh"`.
- **One shared board, no private relays.** Each lane appends status lines to
  `.claude/parallel/board.md` (`<ts> @<name> <state> <one line>`); `state` is `started`,
  `blocked`, `ready-for-review`, `landed` or `abandoned`. Workers never message each other,
  and you never forward one agent's message to another: if lane A needs something from lane
  B, that is a planning error you fix by re-briefing, in writing, on the board.

## 8. Leases for what worktrees cannot isolate

A shared database, a fixed port, a cron window, the CPU-heavy full test suite:

```bash
bash scripts/lease.sh acquire db port-8080 --holder @api --ttl 900   # all or nothing
bash scripts/lease.sh renew db --holder @api
bash scripts/lease.sh release db port-8080 --holder @api
bash scripts/lease.sh list            # who holds what, and until when
```

Every lease expires, so a crashed agent cannot hold one forever. A refused `acquire` prints
the holder; the lane reports `blocked` on the board and you re-dispatch it later, rather than
it waiting in a loop. Put the resource names in the brief; the project's `CLAUDE.md` says which
resources exist.

## 9. Verify

When a lane reports `ready-for-review`, the verifier for its group reads `git diff
<target>...lane/<name>`, runs the lane's fast test command in the lane folder, and checks the
diff touches owned paths only: `bash scripts/lanes.sh verify <name> --owned 'src/*' 'tests/x.py'`
exits 1 and names every changed file outside the globs (`*` crosses `/`). Problems go back **to the writer that owns those files**, as a
new turn on its session (`runner.sh resume`, or a re-dispatched subagent), never fixed by the
verifier or by you. Keep one verifier per wave as a named runner resumed per lane
(`references/runners.md`). A lane that fails review twice escalates (section 13).

## 10. Land through the merge queue

```bash
bash scripts/merge-queue.sh land lane/<name> [lane/<name2> ...] [--target main] [--verify-tests <slug>]
```

**Do not pass `--test-cmd` narrower than the configured gate.** Leave it off; the queue uses
the project's gate. An override prints a WARNING and is logged (`test_cmd_override`). Several
branches in one call are rebased in order, gated once and landed all-or-none.

One landing at a time. It rebases the lane in a clean throwaway checkout, seeds it like a lane
(`.worktreeinclude`, then `lane_setup`), runs the full test command
(`pipeline.parallel.gate_command`, else `test.unit`, else refuses), and fast-forwards the
target only if it has not moved since (compare-and-swap). Cheap tests run in the lane; the
full suite runs once, here. Run it with `run_in_background`: a full suite can outlast a
10-minute foreground call.

Uncommitted work in the target's folder does not block a landing unless it sits on a path the
lane changes (exit 6 names those paths). After landing, only the lane's paths are moved forward
there; your other edits stay as they were. **Read `references/merge-queue.md` now** the first time you land
in a session: it has the exit codes and the conflict path. The short version: on a conflict
it stops and names the files; you hand them back to the owning lane (`lanes.sh sync <name>`,
then re-land) or decide yourself; nothing is ever auto-resolved.

Tell lanes to **rebase early** (`bash scripts/lanes.sh sync <name>`) after each landing in
their wave, so conflicts surface small. After a landing: `bash scripts/lanes.sh remove <name>`
(it also accepts a lane that landed combined with other changes, when every path the lane
changed already matches the target; a lane whose content is missing is still refused).

## 11. Interaction with project commit hooks

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
  this skill, and never brief a lane to use `--no-verify`.
- A hook keyed on `CLAUDE_PROJECT_DIR` sees the lane as the project root. Test one lane
  commit before dispatching a wave (`references/runners.md`).
- Until the project decides, keep lane commits few (one per finished step) and say in the
  brief that a commit may take as long as the hook does.

## 12. Long runners: resume and rotate

`runner.sh` stores each runner's `session_id` and resumes it for the next task. When the last
turn's context passes the threshold (default 180k tokens, set 150k-250k with `--rotate-at`),
the next `resume` asks the old session for a hand-off note, starts a fresh session seeded with
it, and records the new id; `resume --fresh` does it now. Re-use a warm runner for the next
step of a series (`resume --task <next>`). To rotate by hand, or to write a hand-off for a subagent lane,
**read `references/handoff-note.md`**. Details and flags: `references/runners.md`.

Pass `--task <id>` (the TASKS row or plan step) on `start`, and again whenever a runner moves
to new work, so `bash scripts/runner.sh report` can total calls, cost, context and denials by
task as well as by runner. Do not pipe `runner.sh` (`| tail`) when its exit code matters: a
pipe reports the last command's status, so read `verdict.json` instead.

## 13. Escalation chain

**Worker → orchestrator → advisor → human.**

1. The worker reports `blocked` with the reason (a refused lease, a denied tool, an ambiguous
   brief, a conflict, a worktree on the wrong base) and stops. It does not work around it.
2. You resolve what a re-brief, a re-plan or a lease can resolve.
3. A question for the human first goes to an advisor pass (the `question-advisor` agent, or
   `skills/sdlc/templates/operator-gate.md` when the project enables it), which drops what the
   code or the decision log already answers.
4. What is left goes to the human, with the options and your recommendation. **Every
   permission denial goes here unchanged**: a runner's denied action is never handed to another
   agent to perform.

## 14. What this skill must not do

- No `git push`, no force-push, no pull request, no remote of any kind.
- No landing on the target except through `merge-queue.sh` (no `git merge`, no
  `git reset`, no hand-made `update-ref`); `/sdlc` keeps its no-git-writes rule inside lanes.
- No automatic conflict resolution, anywhere.
- No database writes and no other project-side effect the project's rules reserve for a
  human; quote those rules into the brief and leave them to the human.
- No polling loops; use background-task notifications. Never `pgrep -f` without the
  `[b]racket` trick.
- No relaying of one agent's messages or denied actions to another agent.
- No agent teams; no daemon; nothing wired into `setup.sh` or hooks; no edits to the
  project's own hooks.
- No writes by lanes to shared bookkeeping (`TASKS.md`, decision logs): lanes report, you write.
