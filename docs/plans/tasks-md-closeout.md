## Brainstorm Result: Make TASKS.md close-out solid — phases, an audit trail, and reconciliation

### Direction

`TASKS.md` is the toolkit's only durable backlog, and the one operation it cannot do
reliably is **finish**. Rows open correctly; they do not close correctly. Three additions fix
it, in increasing order of how much they buy: give a plan's rows a **phase** to close as a
unit, make Stage 6's close-out **write down what it flipped**, and add a **reconciliation
check** so drift between the envelopes and the backlog is visible instead of silent.

The diagnosis, verified against the current prose:

1. **No grouping exists.** `skills/brainstorm/SKILL.md:214` appends one row *per
   implementation step*, all sharing a plan path. The plan template has a flat steps list with
   no phase concept, so "this plan is done" is only ever inferred by matching a path substring
   across N unrelated rows.
2. **Close-out is unverified prose.** `skills/sdlc/SKILL.md` Stage 6 bullet 4 says to mark rows
   `[x]`; nothing records which rows were flipped, and `handoff.json` has no field for it. The
   claim is unfalsifiable, so a miss is indistinguishable from a success.
3. **A silent matcher failure looks like success.** "If a plan-file run genuinely matched no
   rows, say so" — but a *broken match* and *no rows to match* produce identical output.
4. **A paused run strands rows.** Stage 0 marks rows `[~]`; a run that pauses at Stage 5 leaves
   them in-progress with no owner and nothing revisits them.
5. **Nothing reconciles.** `/sdlc-status` reads TASKS.md *and* `.claude/pipeline/`, but never
   cross-checks — a `complete` envelope beside open rows for that slug is the reported bug, and
   is invisible today.
6. **Neither overlay closes anything.** Copilot and Codex have neither the Stage 0 scan nor the
   full Stage 6 close-out. By the text, a finished plan closes nothing on two of three runtimes
   — the most likely root cause of all.


**A procedural script does the flip, not prose.** Bullet 4 has been forgotten before; three
copies of prose across canonical + two overlays will drift again. Ship
`scripts/close-tasks.sh` (POSIX sh, jq-or-python fallback like the hooks) that takes a slug and
a scope and does the flip-and-move atomically, and have all three skills invoke it in one line.
A script cannot be reordered behind a confirm prompt and cannot drift between copies.

1. **Phases in the plan shape.** `skills/brainstorm/templates/plan.md.template`: allow
   `#### Phase N — <title>` under `### Implementation Steps`. Optional — a flat list is one
   implicit phase, so no existing plan breaks. 3 lines of guidance in `skills/brainstorm/SKILL.md`
   Step 6 (use phases past ~6 steps or a real ordering dependency).
2. **Tag the rows, and define who owns the slug.** Rows become
   `- [ ] (P2) <title> — plans/<file>.md _plan: <slug>_ · _phase: <N>_`. **The slug is the one
   Stage 0 derives** (strip `brainstorm-` / `team-brainstorm-` / `pbi-NNN-` / `task-NNN-`) — say
   so explicitly in both writers, because `brainstorm` currently writes
   `plans/brainstorm-<topic>.md` and a reader looking for `<topic>` would never match. Update
   **both** writers: `skills/brainstorm/SKILL.md` and `copilot/skills/brainstorm/SKILL.md`
   (the Copilot overlay appends rows too and is missing from every previous draft of this plan).
3. **Scope-of-this-run — the rule that stops over-closure.** Stage 6 must close only rows in
   scope, never "any row referencing this plan":
   - **plan-file run** — only rows this run marked `[~]` at Stage 0.
   - **queue item / task-id** — exactly that row. A queued item must never close its siblings;
     they share a `_plan:` key, so the exact key makes this *worse* without this rule.
   - **re-entry rows Stage 6 itself appended** (`rebuild <env>…`, `verify <slug> deployed`) —
     never closed by the pipeline that wrote them. Exclude rows created during this Stage 6.
   - **`--resume` skips Stage 0**, so Stage 6 re-derives matched rows from `TASKS.md` on disk via
     the `_plan:` key — never from session memory. Additionally persist resolved row ids at
     Stage 0 into `run.json.data.tasks.resolved[]` for task-id runs, which have no key.
4. **Reorder Stage 6.** Close-out and the terminal `run.json` write move **before** the gotcha
   capture protocol, which ends in a confirm prompt. A run that dies at that prompt currently
   completes the secret scan, prints the diff, and never touches `TASKS.md` — this ordering is
   the difference between "usually closes" and "closes".
5. **Make it auditable.** `handoff.json` gains
   `data.tasks:{match_key, matched[], closed[], moved[], unmatched[]}` — `moved[]` separate from
   `closed[]` because the flip and the section move are two edits and a run can do one. Stage 7
   prints `tasks: N closed, M moved (K matched)` **always**, including `0 closed (0 matched)`;
   that line is what turns a silent miss into a visible one.
6. **Seam on unmatched.** Non-empty `unmatched[]` drops
   `{"cmd":"/sdlc-status --reconcile","source":"sdlc","confirm":true}` plus the inline `Next:`
   fallback.
7. **Overlay parity — the likely root cause of the reported bug.** `copilot/skills/sdlc/SKILL.md`
   and `codex/skills/sdlc/SKILL.md` have **neither** the Stage 0 plan-row scan (`[~]`) **nor** the
   full Stage 6 close-out; both say only "Mark each resolved row `[x]`". By the text, a finished
   plan closes nothing on those two runtimes. Add both halves to both overlays, invoking the same
   `scripts/close-tasks.sh`.
8. **Reconciliation in `/sdlc-status --reconcile`.** Read-only without the flag. Drift is
   **bidirectional**: a terminal envelope with open rows, a `[~]` row with no/non-terminal
   envelope, **a `[x]` under `Active / Pending`, and a `[ ]`/`[~]` under `Done`** — the last is
   live in this repo today (`TASKS.md:62`). Key the envelope→row join on the **directory name**
   plus any of `plan_file` / `input` / `data.plan_target`: three envelopes on disk wrote the
   latter two, so a reconciler keyed only on the canonical field skips exactly the runs it should
   catch. `--reconcile` applies after one confirmation, mirroring `--prune-stale`.
9. **`/repo-health` Check 11 — backlog drift.** Procedural, capped at 10, weighted like Check 5.
   Note it is a **new reader**: `/repo-health` does not read `TASKS.md` today, and CLAUDE.md's
   claim that it does is wrong — fix that sentence in the same change.
10. **A durable guard, or this decays like the rest.** Add a `tasks_row_state` assertion to
   `scripts/ci/skill-eval.py` (file, row substring, expected state, expected section) and an eval
   case whose fixture `TASKS.md` carries one `_plan:`-tagged row and one deliberately mismatched
   row — asserting exactly one closed and one reported unmatched. Acceptance criteria that are
   only manual prose are how the current bug survived.
11. **Document.** `templates/TASKS.md.template` conventions block gains `_plan:_` and `_phase:_`;
   `docs/FLOW.md` gains the backlog lifecycle; no new `project.json` keys — say so explicitly.

### Cross-Module Touchpoints

- Writers: `skills/brainstorm/SKILL.md`, `copilot/skills/brainstorm/SKILL.md`.
- Closers: `skills/sdlc/SKILL.md` + **both** overlays, all via `scripts/close-tasks.sh`.
- Readers: `skills/sdlc-status/SKILL.md`, `skills/repo-health/SKILL.md`.
- Shared: `plan.md.template`, `templates/TASKS.md.template`, `state-schema.md`, `docs/FLOW.md`,
  `scripts/ci/skill-eval.py`, `evals/skills/cases/`.
- `queue-mode.md` selects `Active / Pending` rows — confirm a tagged row still selects and that
  closing one phase does not strand its siblings.

### Acceptance criteria

- A plan run closes **only** its in-scope rows: verify a queue run over 3 sibling rows closes
  exactly the one item it processed, leaving two open.
- Stage 6's own re-entry rows survive a `--resume` that reaches Stage 6 again.
- A deliberately mismatched `_plan:` marker lands in `unmatched[]` and fires the sentinel.
- Killing the run at the gotcha confirm still leaves `TASKS.md` closed and `run.json` terminal.
- `/sdlc-status --reconcile` flags `TASKS.md:62` (a `[ ]` under `## Done`) as drift, and without
  the flag makes zero writes.
- The `tasks_row_state` eval case passes, and fails when the fixture's row is left open.
- Legacy rows with no `_plan:_` marker still parse, still select under `--queue`, and fall back to
  the path-substring match.
- `validate_skills.py`, `check_contracts.py`, `check_install_refs.py` and a fresh `--tools all`
  install all pass.

### Open Questions

- Auto-close a phase when its last row is `[x]`? Recommend yes — derived state, one fewer thing
  that can fail to trigger.
- Should `/repo-health` Check 11 fix drift? No — it is read-only by contract;
  `/sdlc-status --reconcile` owns the write.

### Appendix: Alternatives Considered

- **A `tasks.json` sidecar as the real backlog, with `TASKS.md` rendered from it** — rejected:
  `TASKS.md` being a plain, hand-editable Markdown checkbox list is the entire reason it works
  across three runtimes and survives the session. A sidecar makes it a derived artifact and
  puts it out of reach of a human with an editor.
- **Closing rows at Stage 0 optimistically** — rejected: rows would close for runs that later
  pause or fail, which is a worse failure than the current one.
- **A Stop hook that reconciles automatically on every session end** — rejected for now: it
  writes to the backlog without being asked, and the repo already has two blocking Stop hooks
  that must stay mutually exclusive. `--reconcile` plus the `/repo-health` check gets the
  visibility without a third writer.
