---
name: review-pr
description: >
  Run a structured code review on an open PR or arbitrary branch — wraps the
  built-in /review slash command and writes findings to plans/review-<id>.md
  so they survive the chat session. Invoke via /review-pr [pr#|branch], or
  when the user asks "review this PR", "vet the diff", "review branch X
  before merge". Use this instead of waiting on Copilot's auto-comment bot
  when you want one canonical review on demand.
argument-hint: "[pr-number | branch-name] [--post-comment]"
metadata:
   brainstorm-toolkit-applies-to: claude copilot
---

# /review-pr — on-demand code review for any PR or branch

`/sdlc` already triggers `/review` after it creates a PR (Stage 7, step 6).
This skill is the **standalone entry point** for reviewing PRs that didn't
come from `/sdlc` — hand-rolled branches, `/task` outputs, or PRs from
other contributors. One canonical reviewer, your model, your prompt — no
waiting on the Copilot bot.

## Args

- **`<pr-number>`** (e.g. `42`) — review the diff of an open GitHub PR.
- **`<branch-name>`** (e.g. `feat/orders`) — review the diff between this
  branch and `main` (or `project.json.main_branch`).
- **No arg** — review the current branch's diff against main.
- **`--post-comment`** (optional) — after the review, post the summary as
  a single PR-level comment via `gh pr comment`. Requires a PR number or
  a branch with an open PR. Without this flag, output stays in chat +
  `plans/review-<id>.md`.

## Flow

1. **Resolve target.**
   - If arg is all-digits → treat as PR number; run
     `gh pr view <n> --json number,headRefName,baseRefName,url` to capture
     branch + base + URL.
   - If arg is a branch name → use as-is; base is
     `project.json.main_branch` (default `main`).
   - If no arg → `git rev-parse --abbrev-ref HEAD`.
   - If on the resolved base branch (e.g. user passed nothing while on
     `main`), error: "no diff to review — pass a PR number or branch."

2. **Capture the diff.**
   - PR mode: `gh pr diff <n>` (full unified diff, including added files).
   - Branch mode: `git diff <base>...<branch>` from the repo root.
   - If the diff exceeds ~3000 lines, warn and ask whether to proceed,
     split by directory, or focus on a subpath. Don't auto-truncate
     silently.

3. **Run the review.** Invoke the built-in `/review` slash command,
   passing the captured diff. `/review` is a Claude-side primitive on
   Claude Code; on Copilot, fall back to a structured prompt that asks
   for the same shape (severity-tagged findings + summary). The required
   output shape either way:

   ```
   ## Summary
   <2–4 sentences: what changed, overall risk, recommend merge or revise>

   ## Findings
   ### High (block merge)
   - <file:line> — <issue> — <suggested fix>

   ### Medium (worth addressing)
   - <file:line> — <issue> — <suggested fix>

   ### Low / nits
   - <file:line> — <issue>

   ## Strengths
   - <what's done well — keep this short, 2–3 bullets>
   ```

4. **Persist.** Write the full review to
   `plans/review-<id>.md` where `<id>` is:
   - PR mode: `pr-<n>` (e.g. `plans/review-pr-42.md`)
   - Branch mode: the branch slug, kebab-cased (e.g.
     `plans/review-feat-orders.md`)

   This makes the review survive the chat session and gives `/sdlc
   --resume` flows or follow-up `/task` calls something durable to point
   at.

5. **Optional comment post (`--post-comment`).**
   - Resolve PR number (from arg, or `gh pr list --head <branch> --json number --limit 1`).
   - If no open PR exists, skip with a one-line note ("no open PR for
     `<branch>` — review saved to `plans/review-<slug>.md` only").
   - Post via `gh pr comment <n> --body-file plans/review-<id>.md`.
   - Single comment, not a multi-thread review — keeps the PR signal:noise
     ratio high.

6. **Print a one-line summary** to chat:
   `Review saved: plans/review-<id>.md — <H> high · <M> medium · <L> low findings.`
   When `--post-comment` was used, append `· posted to PR #<n>`.

## Rules

- **Read-only on the diff.** This skill does not edit code. If the review
  surfaces fixes worth doing, the user (or a follow-up `/task`) applies
  them.
- **No state-envelope writes.** This skill is independent of `/sdlc`'s
  pipeline journal — it's a one-shot tool. Don't mirror into
  `.claude/pipeline/`.
- **Don't re-review on rerun.** If `plans/review-<id>.md` already exists
  and the diff hash hasn't changed (compare HEAD SHA of the branch),
  print the existing review and exit. Re-run with the same args after a
  push to refresh.
- **Don't post comments without `--post-comment`.** The default audience
  is the user driving the chat, same convention `/sdlc` uses.
- **`pipeline.skip_review: true` does not apply here.** That flag
  silences the *automatic* post-PR review inside `/sdlc`. This skill is
  manually invoked — if the user typed `/review-pr`, they want a review.

## When `/review` isn't available

On Copilot or older Claude Code installs, `/review` may not be a
built-in. Fall back to running the review inline with the structured
prompt above. The output shape and persistence behavior are identical.
