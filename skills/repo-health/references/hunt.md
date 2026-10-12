# /repo-health --hunt

Bug hunt over `<area>` (a path or glob; default the whole repo, excluding vendored, generated,
build-output and `docs/` paths). Read-only on code: it files `_bug_` rows and a report, and never
fixes anything.

## 1. Resolve and print

Resolve per `skills/sdlc/templates/models.md`:

- Lens tier (Axis 1): `models.hunt` > `sonnet`, then ceiling `models.cap`.
- Lenses: `agents.hunt_lenses`, default `["correctness", "error-handling", "data-contracts"]`
  (correctness; error handling and edge cases; data shapes and cross-module contracts). An
  unrecognized name is ignored with one warning.
- Consolidator tier (Axis 2): `models.code_review` > `opus`. `models.cap` never lowers it.

Print `model: hunt=<tier> (cap: <cap|none>)` before the first lens dispatch, and
`model: code_review=<tier> (axis 2)` before the consolidator. A dispatch with no `model` bypasses
the cap with zero log line, so pass `model` explicitly on every one.

## 2. Lens fan-out

Dispatch one `general-purpose` agent per lens in a single message, each with `model` set to the
lens tier. On Copilot and Codex (no sub-agent seam) run the lenses inline, sequentially, and keep
only the structured findings in context. Each lens prompt carries, verbatim in substance:

```
You are the <lens> lens of a bug hunt over <area>. Read-only: never edit, create or delete code.
GIT: never run a git command that writes — no stash, commit, checkout, switch, reset, restore, rebase, merge, clean, add, or branch creation.

EVIDENCE RULE. A finding needs ONE of: a `file:line` plus a quoted line of code; a failing command
with its output; or a measured value. Anything you suspect without that goes under "unverified"
and files nothing.

Severity: P0 = data loss, security hole or crash on a common path; P1 = wrong result or failure on
a normal path; P2 = failure only on an edge case or rare path; P3 = latent or cosmetic.

Report JSON: {"findings": [{title, severity, file, line, evidence, why}], "unverified": [{claim, why_unproven}]}.
Cap findings at 10.
```

## 3. Consolidate

One pass over all lens output, dispatched with `description: "review:hunt-consolidate"` (the
`review:` prefix exempts it from the cap hook) on the Axis 2 model; on Copilot and Codex it is an
inline second pass. Its prompt carries the same no-git-writes sentence. For each finding it
re-opens the cited `file:line`, confirms the quoted line is really there and really behaves as
claimed, and returns `confirmed` (with a possibly corrected severity), `overruled` (with the
reason) or `unverified`. It may overrule a lens, and merges findings that share a `file:line`.

Overrule, never file, a finding about input outside the code's documented contract (wrong type,
`None`, a value the docstring excludes) when the code fails loudly on it — a raised exception
there is correct behavior, not a bug. Only *silent* wrong output on such input is a finding.

## 4. Dedupe

Run `bash scripts/close-tasks.sh rows --tag bug --file TASKS.md`. A confirmed finding whose
`file:line` already appears in an open or in-progress `_bug_` row is dropped from filing and noted
as `already tracked (line N)` in the report. Skip silently when `TASKS.md` or the script is absent
(the report is still written; no rows are filed).

## 5. Report and rows

Write the report to `plans/bug-hunts/<YYYY-MM-DD>-<slug>.md` (`docs/plans/bug-hunts/` when
`.claude-plugin/marketplace.json` exists, i.e. a skill repo); `<slug>` from `<area>` or `repo`.
Sections: Confirmed (each with severity, `file:line`, quoted evidence), Already tracked, Overruled
(with reasons), Unverified.

Then append one row per confirmed, untracked finding to `TASKS.md` under `Active / Pending`,
highest severity first:

`- [ ] (Pn) <title> — <report path> _bug_`

File at most 10 rows; any beyond stay in the report only, and the report says so. Do not fix code.

## 6. Verify and hand off

Run `git status --short`; only the report and `TASKS.md` may have changed. If anything else did,
say so plainly and stop. Print the confirmed count by severity, the rows filed, and the report
path. When at least one row was filed, append the structured `.next-action` line using the same
guard and dedupe as the normal sweep, with `cmd` `/sdlc <TASKS.md line number of the top bug row>` (a bare row number — a title would be
read as a new ad-hoc task and file a duplicate row) and
`source` `repo-health`; otherwise write nothing.
