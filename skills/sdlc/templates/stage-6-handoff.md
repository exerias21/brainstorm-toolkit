# Stage 6 — Hand off (shared)

Canonical for `/sdlc`. No commit, no branch, no push, no PR — `/sdlc` stops at the edge of git
and hands you a validated working tree; the DO-NOT list of git commands this stage never runs
lives in `skills/sdlc/SKILL.md` Stage 6 itself, not here.

**Ordering is load-bearing.** Close-out (step 3) and the terminal `run.json` write happen
**before** gotcha capture (step 4), which ends in a confirm prompt. A run that dies at that
prompt used to complete the secret scan, print the diff, and never touch `TASKS.md` — this
order is the difference between "usually closes" and "closes."

1. **Secret scan** the changed files — **read `skills/sdlc/templates/secret-scan.md` now**
   and run it. **Warn-only**: surface findings (file:line) but never block. HIGH findings
   get a `⚠ HIGH:` prefix and a note that GitHub Push Protection on public
   remotes may reject a later push — worth scrubbing before you commit.

2. **Report the diff, don't commit it.** Show `git diff --stat`, the list of
   files changed, and a **suggested** commit message. Leave the working tree
   exactly as the pipeline produced it.
   ```
   Suggested commit (run yourself when ready):
     git add <files>
     git commit -m "feat: <title>"
   ```
   **Co-author trailer**: only when `.claude/project.json` `coauthor_trailer` is `true`,
   end the suggested message with a blank line and
   `Co-Authored-By: Claude <noreply@anthropic.com>`. Absent or `false` ⇒ no trailer.
   **Range semantics**: process tasks in order; the changes from all tasks
   accumulate in the working tree. You decide how to slice commits (per task,
   or one bundle). Sanity-check (1.5) ran once up front; Stage 5's plan check and
   flowsim trace ran once at the end over the shared parent plan.

3. **Close out — via the script, not by hand.** A procedural script does the flip so the
   close-out can't be forgotten or drift between runtimes: run
   `bash scripts/close-tasks.sh close --file TASKS.md --scope <plan|resolved> ...` and read
   its JSON result back — never edit `TASKS.md` checkbox state directly here. (`setup.sh`
   ships this script under the repo-local `scripts/` tree unless the consumer chose
   `--no-copy-scripts`; if the path is missing, say so in the report and skip close-out
   rather than failing the whole hand-off — the pipeline still delivers a validated tree.)

   - **Plan-file run** (Stage 0 resolved a `.md` plan path):
     `bash scripts/close-tasks.sh close --file TASKS.md --scope plan --key <feature_slug> --plan-file <plan_file>`.
     This closes only the `[~]` rows Stage 0 marked for **this** plan (matched by the
     `_plan:` tag, with a legacy path-substring fallback for untagged rows) — never "any row
     referencing this plan." A row tagged for a *different* plan is left alone; a row whose
     `_plan:` tag looks like a writer/reader mismatch (right path, wrong key) lands in
     `unmatched` instead of being guessed-closed. On `--resume` (which skipped Stage 0) this
     re-derives matched rows straight from `TASKS.md` on disk via the `_plan:` key — never
     from session memory, because there is no session memory to read.
   - **Task id / range / ad-hoc-description / queue item** (no `_plan:` key applies, or —
     for a queue item — applying the plan key would sweep in its siblings):
     write the resolved row id(s) from Stage 0's `run.json.data.tasks.resolved[]` (or the
     queue item's own per-item envelope, `skills/sdlc/templates/queue-mode.md`) one per line
     to a temp file and run
     `bash scripts/close-tasks.sh close --file TASKS.md --scope resolved --ids-file <file>`.
     This closes **exactly** those rows — a queued item's siblings sharing its `_plan:` key
     are never touched, because this scope never looks at the `_plan:` tag at all.
   - **Re-entry rows this same Stage 6 is about to append (below) are never in scope** —
     they don't exist yet when the script runs, so a later `--resume` that reaches Stage 6
     again can't close its own re-entry rows by construction (they land `[ ]`, and neither
     scope above ever touches a `[ ]` row it didn't explicitly ask for).

   **Auditability — write the script's result into `handoff.json`, don't discard it.**
   The script's JSON output (`{match_key, matched[], closed[], moved[], unmatched[]}`) becomes
   `stage-outputs/handoff.json`'s `data.tasks` verbatim. `moved[]` is kept separate from
   `closed[]` even though today they're always identical (the flip and the section move are
   two edits; a future partial-failure run can do one without the other). If a plan-file run
   genuinely matched zero rows, that's an empty `matched`/`closed`/`unmatched` — expected, not
   a miss; say so in the report rather than treating it as an error.

   **Seam on unmatched.** A non-empty `unmatched[]` means at least one row looked like it
   belonged to this run but didn't get closed (a key mismatch, an ambiguous match, or a
   resolved id that no longer exists on disk) — drop the reconciliation seam so it doesn't
   silently rot:
   `line='{"cmd":"/sdlc-status --reconcile","source":"sdlc","confirm":true}'; grep -qF "$line" .claude/.next-action 2>/dev/null || echo "$line" >> .claude/.next-action`
   and print `Next: /sdlc-status --reconcile` inline as the same graceful-degrade fallback
   every other seam write uses.

   **Also leave re-entry rows** so the queue keeps the follow-up (`/sdlc`
   opens no PR, so these are conditioned on delivery, not a PR number): when the
   changed-files gate flagged the **deploy-delta** surface, append
   `- [ ] (P1) rebuild <env> for <slug> (dependency change — rebuild, not restart) — plans/<slug>.md`;
   and a `- [ ] (P2) verify <slug> deployed — /repo-health`
   row closes the loop. These are appended `[ ]` (pending), never `[~]` — see the exclusion
   note above.

   **Then print the manual-verification line** from `.claude/project.json` `stack.*`
   (all keys optional): the deploy-delta case prints `stack.rebuild` (a dependency
   changed, so a plain restart would run stale code), otherwise `stack.up`; append
   `stack.url` when set. This is a **printed suggestion, never auto-run** — the user
   asked for a validated tree, not a running one. When a needed key is absent, say
   which key would supply it rather than guessing a command:

   ```
   Verify: docker compose up -d --build --force-recreate   # stack.rebuild (dependency change)
   Open:   http://localhost:3000                            # stack.url
   ```

   **State write — right here, before step 4.** `stage-outputs/handoff.json` =
   `{branch, files_changed[], committed: false, suggested_commit_msg, data: {tasks: {match_key,
   matched[], closed[], moved[], unmatched[]}}}`. **Always set `run.json.status` to a terminal
   value** (`complete`, or `paused` if you stopped mid-pipeline) **now** — never leave it
   `in_progress`, and never defer this past step 4's confirm prompt, or `/repo-health` and
   `/sdlc-status` will (correctly) flag it as a stale run and `TASKS.md` will show rows still
   open on a run that actually finished. **Also set `run.json.next_action = {cmd, confirm}`**
   when the run proposes a follow-up — on pause the `/sdlc-status` / `--resume` command, on
   complete the primary re-entry (e.g. `/repo-health`, or `/sdlc-status --reconcile` when
   `unmatched` was non-empty) — so `/sdlc-status` recovers the handoff after the fire-once
   sentinel; omit when there's none. This holds for **retro / validation-only runs** too
   (Stage 2 skipped because the code already landed): advance `run.json.stage`/`stages_completed`
   as each validation sidecar is written, add `implement` to `stages_skipped`, and close on a
   terminal `status` — never leave a `parse`-stage envelope `in_progress` with sidecars already
   on disk.

4. **Capture at loop-exit + seam** — run the shared protocol in
   `skills/gotcha/SKILL.md`. Auto-draft a gotcha **only** on an objective
   trigger — a test/eval/flowsim fix-loop that **failed-then-recovered**, or the
   user voicing surprise — route it through gotcha's dedup, and one-tap confirm.
   A clean run stays silent (no vibe-gating). If capture is **declined/deferred**,
   drop the seam sentinel instead — append ONE structured line, deduped by `cmd`
   (multi-slot: it now coexists with the pipeline handoff instead of racing it;
   see `docs/SEAM.md`):
   `line='{"cmd":"/gotcha <drafted text>","source":"sdlc","confirm":false}'; grep -qF "$line" .claude/.next-action 2>/dev/null || echo "$line" >> .claude/.next-action`
   (never a bare `/gotcha`). On Codex (as a fallback until its `.codex/hooks.json` Stop hook is wired+trusted) also print `Next: /gotcha …`
   inline so the seam degrades gracefully. **By this point `TASKS.md` is already closed and
   `run.json` is already terminal** — a run that dies at this step's confirm prompt still
   hands back a correctly closed backlog.
