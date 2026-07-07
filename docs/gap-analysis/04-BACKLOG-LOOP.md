# Gap 4 — Nothing drives the backlog

**Gap:** TASKS.md is the toolkit's shared work queue — `/brainstorm` appends to it, `/task`
appends to it, a future `/triage` would append to it — but **nothing consumes it except a
human picking a row**. The user's stated goal ("give a task… and have the system loop over and
over") is precisely a backlog driver, and the toolkit explicitly declines the role today:
`/task`'s gotchas section says *"One task at a time… If the ask implies a batch, run
`/sdlc-lite <range>`"* — and a range is still a single human invocation over a hand-chosen
span.

**Levers**, from least to most autonomous: (a) queue mode on `/sdlc-lite`, (b) conductor-driven
chaining via auto-continue, (c) a scheduled/headless worker — the delivery-flavored version of
the pattern `docs/AUTONOMOUS-DISCOVERY.md` already documents.

---

## What exists vs what's needed

| Capability | Exists? | Where |
|---|---|---|
| A durable queue with states (`[ ]`/`[~]`/`[x]`, priorities, blocked) | ✅ | TASKS.md contract + template |
| Reading the queue | ✅ read-only | `/status` |
| Executing one item | ✅ | `/task`, `/sdlc-lite <task-id>` |
| Executing a hand-picked batch | ✅ | `/sdlc-lite N-M` (range semantics: accumulate in tree, close rows at the end) |
| **Picking the next item automatically** | ❌ | `/next` ladder rungs 5–6 would (gap 1) |
| **Continuing to the next item after one finishes** | ❌ | the seam is fire-once + human-typed (gap 3) |
| **Running the queue unattended** | ❌ | AUTONOMOUS-DISCOVERY covers discovery jobs only, and deliberately excludes delivery |
| **Stop conditions / budgets for a loop** | ❌ | only per-run budgets exist (3-iteration fix loop) — nothing bounds a multi-run loop |

## Lever A — `--queue` mode on `/sdlc-lite` (attended loop, smallest step)

`/sdlc-lite --queue [max-N]`: resolve *all* `Active / Pending` rows (or the top N by priority),
then run the existing range semantics over them. This is ~zero new machinery — the range path
already handles multi-task accumulation, single up-front sanity check, per-plan validation, and
row close-out. What it adds over `1-5`:

- selection by state+priority instead of hand-typed row numbers;
- a **re-scan between items**: rows appended *during* the run (a `/triage`-drafted fix task, a
  brainstorm follow-up) join the queue — this is what makes it a loop rather than a batch;
- explicit stop conditions (below).

Keeping it inside `/sdlc-lite` (no git writes, user commits at the end) means the most
autonomous *attended* mode still can't surprise anyone — the same reasoning `/brainstorm`
Step 8 uses to make `sdlc-lite` the default handoff.

## Lever B — conductor chaining (the session as the loop)

With gap 1 (`/next`) and gap 3 Lever C (auto-continue) in place, the loop needs no new mode at
all: each run's terminal step writes the sentinel, the Stop hook auto-continues into `/next
--go`, `/next` picks the top backlog row, and the session iterates until a stop condition or a
`confirm: true` action (a PR) parks it. This composes better than Lever A — it also picks up
paused-run triage and plan handoffs, not just TASKS rows — but it depends on two other levers
landing first and is Claude-only.

## Lever C — unattended worker (the ceiling; adopt the existing pattern, add teeth)

`docs/AUTONOMOUS-DISCOVERY.md` already defines the architecture: job queue → watcher daemon →
headless `claude --print --allowed-tools …` → skill runs → mark done/failed. Delivery reuses it
with TASKS.md (or the envelope dir) as the queue and `/sdlc-lite <task-id>` as the job body.
The doc's own reservations apply doubly for delivery:

- **Terminal action stays human.** The worker runs `/sdlc-lite` (validated tree / branch
  artifacts), never `/sdlc`-to-PR without a human gate — or, if PRs are wanted, the PR *is*
  the human gate and the worker must be branch-scoped and rate-limited.
- **The soft-stop rule already anticipates this**: `/sdlc`'s "Non-interactive runs" section
  mandates proceed-and-document instead of blocking on questions. A headless queue worker is
  exactly that context; the debt-row convention (write the skipped check into TASKS.md) is the
  audit trail.
- **Scoped tools, timeout, loud failure** — verbatim from the discovery doc.
- Like the discovery pattern, this should stay a **documented deployment pattern in `docs/`**,
  not a shipped skill — a daemon polling a queue is infrastructure a consumer opts into.

## Stop conditions and budgets (needed by all three levers)

A multi-run loop needs bounds the way the fix loop needed its 3-iteration budget. Candidate
knobs (project.json `pipeline.loop.*`, all optional):

| Knob | Meaning | Default instinct |
|---|---|---|
| `max_items` | rows consumed per loop invocation | 5 |
| `stop_on: pause` | any run ending `paused`/`failed` parks the loop (after writing its triage hint) | always on — never plow past a red run into the next item |
| `stop_on: confirm` | any `confirm: true` next action parks the loop | always on |
| `max_consecutive_failures` | distinct-item failures before parking even with triage | 2 |
| time/token budget | wall-clock or spend ceiling for unattended mode | deployment-specific |

"Park" = write the would-be next action to the sentinel/envelope (gap 3 Lever B) and stop —
so the loop resumes exactly where it parked when a human (or the next scheduled run) returns.
That symmetry — *every stop is a parked next-action, never a dead end* — is the design
principle that makes the whole system loop-shaped, and it's the same fix gap 2 applies to the
red path.

## Ordering note

Lever A is shippable alone and immediately useful. Lever B is the strategic one but is really
"gaps 1+3 finished." Lever C should wait for real usage of A/B — the discovery doc's own advice
("only pay the always-on cost when the cadence genuinely has to be unattended") transfers
unchanged.
