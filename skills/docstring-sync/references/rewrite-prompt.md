# Docstring Sync — rewrite prompt

Dispatched by `SKILL.md`'s rewrite fan-out: one sub-agent per batch of files (up to ~8), given the
confirmed edit queue for that batch. You never see the skill itself, so this file is your whole
brief — everything you need to do the job is below, plus two reference files whose absolute paths
your dispatcher resolved and listed immediately before this prompt (one is this skill's own
`rewrite-rules.md`; the other is the `code-tour` skill's `standards.md`).

**Read both of those two files now**, at the exact paths you were given — do not guess a path
yourself, you have no base directory of your own to resolve one against — before making any edit,
and follow them. They already carry the minimal-edit rule, the pointer policy (look for the plan
on disk, drop the pointer if it's gone, never invent a reason), the runtime-visible exception, and
the type-hint / no-restated-signature rules — this file does not restate any of that.

## Your input

The confirmed edit queue for this batch: one entry per flagged symbol or comment line, each
carrying its path, line, kind (`PLACEHOLDER` / `THIN` / `POINTER` / `STALE`), and the finding's
message — for a `STALE` entry, the claim sentence and the verifying quote a human has already
seen and approved.

## Scope

**Only the listed symbols.** No roaming edits outside this batch — if you notice something else
wrong while you're in a file, leave it and mention it in your report rather than touching it.
Every edit you make must be traceable to one entry in the queue you were given.

GIT: never run a git command that writes — no stash, commit, checkout, switch, reset, restore, rebase, merge, clean, or branch creation. The working tree holds the user's uncommitted work; git that only reads (status, diff, log, show) is fine. If you need a clean baseline, report it as a blocker instead.

## What counts as done

An entry is `edited` only when you made the change and it is verifiable against the code you were
given — an edit you cannot verify against the function's actual body is not a fix (see
`rewrite-rules.md`'s "never guess" section). Otherwise mark it `skipped` with a reason:

- `runtime_visible` — the docstring is behavior (a route/CLI/doctest surface) and this run did not
  ask for `--include-runtime-docstrings`.
- `no-recoverable-plan` — the entry is a stale pointer whose target plan is gone from disk, and no
  surrounding code explains the reason well enough to inline it (rare — usually you can still keep
  the bare instruction; use this only when even that can't be recovered).
- `ambiguous-cannot-verify` — the flagged claim's truth is genuinely unclear from the code alone,
  so any rewrite would be a guess.

COMMENTS: never reference the plan in code — no plan file paths, plan/phase/step numbers, or TASKS.md rows in comments or docstrings. Write the reason itself; the plan does not ship with the code and its numbering means nothing once it is gone.

## Output

Return one JSON array, one entry per symbol you were given:

```json
[
  {"symbol": "<qualified name>", "action": "edited", "unresolved": null},
  {"symbol": "<qualified name>", "action": "skipped", "unresolved": {"reason": "runtime_visible"}}
]
```

`"edited"` always carries `"unresolved": null`. `"skipped"` always carries a reason object —
never a bare string — so the orchestrator can group skips by reason without string-matching.
Cover every symbol in your batch; do not invent symbols and do not drop one silently.
