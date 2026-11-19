---
name: session-handoff
description: >
  Write a hand-off for a whole working session (usually an orchestrator) that is about to be
  cleared, so a fresh session can pick up without the transcript: what landed, what is in
  flight, what waits on the human, how work is being driven, and what to do first. Every claim
  is re-measured from durable state (git, TASKS.md, lanes, runners, leases, pipeline envelopes,
  background jobs), not recalled. Use when the user says "write a handoff", "I'm clearing this
  session", "hand this off", "/session-handoff", "wrap up for the next session", or before a
  long session ends. For rotating one runner, runner.sh already writes a lane note
  (orchestrate-parallel-agents references/handoff-note.md).
argument-hint: "[--review] [--out <path>]"
metadata:
  brainstorm-toolkit-applies-to: claude copilot codex
---

# Session hand-off

> **Toolkit paths.** Every toolkit script or template path cited here resolves, first hit wins, against: a repo-local copy installed by `setup.sh`; else the plugin root (this skill's base directory two levels up, `<base>/../..`) when it holds that path; else `~/.claude/brainstorm-toolkit/` (the global shell install).

A hand-off is read by a session that knows nothing. It over-trusts whatever it reads, so the
note's job is to be **true, short and actionable**. A transcript summary is none of those: it
is written from memory, it keeps the story and drops the state.

## 1. Measure, do not recall

Collect the state with commands, in one or two batches, before writing a line. Skip any
source the repo does not have.

| Source | Command | Gives |
|---|---|---|
| Commits | `git log --oneline <session-start>..HEAD` (start = the first sha of the session, or `--since`) | what landed, with shas |
| Unpushed | `git log --oneline @{u}..HEAD` | what still needs a push (and whose it is) |
| Dirty tree | `git status --short` | uncommitted work; name each file and whose it is |
| Backlog | rows touched this session in `TASKS.md` (ticked, added) and the open rows of the active plans | done / next |
| Lanes | `bash scripts/lanes.sh list` or `git worktree list` | worktrees still open, and whether their commits landed |
| Runners | `bash scripts/runner.sh report` | calls, cost, denials per runner and per task |
| Leases | `bash scripts/lease.sh list` | anything still held |
| Pipelines | `.claude/pipeline/*/run.json` with `status` not `complete` | stalled or paused runs |
| Background jobs | the session's running background tasks; cron jobs the session armed | what will still fire after the clear |
| Human decisions | the project's decision log and questions file (e.g. `DECISIONS.md`, `HUMAN.md`) | answered this session / still open |

Anything you cannot measure, mark **unverified** rather than dropping or asserting it.

## 2. Write the note

Default path: `.claude/handoffs/<YYYY-MM-DD>-<slug>.md` (create the folder; `--out` overrides).
If the project keeps a memory index (for example Claude Code's `MEMORY.md`), add a one-line
pointer to the note there, so the next session loads it without being told.

Sections, in this order. Target under 150 lines; link, do not paste.

```markdown
# Hand-off: <session purpose> (<date>)

## Read first
<3-5 lines: the one thing in flight, the one thing waiting on the human, the first command to run>

## Where things stand
<per workstream: done (sha), in flight (where, who), next; the plan file each belongs to>

## Waiting on the human
<each open decision: the question, the recommendation, where it is recorded>

## In flight right now
<background jobs, armed cron, held leases, open lanes, unpushed commits; how to check each>

## How work is driven
<the driver recipe as it actually ran: commands, flags, allowlists, review step, landing step,
with the gotchas that bit; enough to start the next worker without rediscovery>

## Rules that bit this session
<constraints the next session will hit again: a refused command shape, a race, a slow step>

## First steps for the next session
1. <concrete command or action>
2. ...
```

Rules:

- **Provenance on every fact:** a sha, a command and its result, a `path:line`, a run id.
  "Tests pass" without the command is a claim, not a fact.
- **Uncommitted work is named file by file**, with whose it is. Commit your own first if you
  can; never commit another session's work to make the note tidier.
- **Denials are copied verbatim** and marked escalated or not. The next session must not retry
  a denied action by another route.
- **Recommendations are labelled as such**, apart from facts.
- No secrets, credentials, connection strings or personal data, even when the repo is private.

## 3. `--review`: how the session's way of working went

When asked (or when the session changed how work is driven), add a short section comparing
this session's driver with the previous one, from measurements, not impressions:

- **Throughput:** items landed, landings refused and why (tests, conflicts, target moved).
- **Cost:** `runner.sh report` totals; the most expensive runners and what made them so
  (re-tries, oversized prompts, fix-up rounds).
- **Friction:** denials by cause (command shape, allowlist pattern, hook), silent failures,
  races, load-related test failures; which were fixed and which still bite.
- **Keep / change:** two or three concrete changes for the next session, each tied to a
  measured cause.

## 4. Before you finish

- Re-read the note as the next session would: can it start from "First steps" with nothing
  else? Every path exists? Every sha is on the branch it names?
- Tell the user where the note is, and the one decision still waiting on them.
