# Docstring Sync — triage prompt

Dispatched by `SKILL.md`'s triage step: one sub-agent per file, given that file's claim batch
from `--claims-out`. You never see the skill itself, so this file is your whole brief —
everything you need to do the job is below or in your dispatch input.

## Your input

A JSON array of claims scoped to one file, each `{"id", "claim", "evidence": [...]}`. `evidence`
is the claiming symbol's own source (decorators through its closing line), capped at 200 lines.
If this file has any oversized symbol (over that cap), you are given its full, uncapped source
directly instead of a capped evidence string — same id scheme, judge it the same way.

## Your job — find only, never edit

Read each claim sentence against **only its own evidence** — not the rest of the file, not the
rest of the repo, not what you assume the code "probably" does elsewhere. For every claim id,
answer exactly one of:

- **`supported`** — the evidence bears the claim out.
- **`overgeneralized`** — the claim states something broader than the evidence actually shows
  (e.g. "always returns X" when the body returns X on only one branch).
- **`contradicted`** — the evidence shows the claim is flatly wrong.
- **`not-addressed`** — the evidence is silent on the claim, neither confirming nor denying it.

**Incorrectness only.** "Could be clearer," "could say more," or any stylistic complaint is not
a finding — an open-ended "is this docstring good?" question flags nearly everything, which is
exactly the failure mode this prompt exists to avoid. You are checking whether the claim is
*true of the evidence*, not whether the prose is good.

**Callee behavior is `not-addressed`, never `contradicted`.** If the claim describes what a
called function does internally and the evidence you were given is only the calling symbol's own
body, you cannot see that callee's behavior — silence about something outside your evidence is
`not-addressed`, not a contradiction. Only mark `contradicted` or `overgeneralized` when the
evidence you were actually given disagrees with the claim.

**Quote verbatim, or the verdict cannot become an edit.** For every `contradicted` or
`overgeneralized` verdict, quote the exact contradicting line(s) from the evidence, character for
character. A verdict without a verifiable quote is downstream noise — the confirmation step and
the rewrite pass both depend on being able to find your quote in the source again.

You make no edits, and no rewrite decision is yours to make — that is a separate pass, after a
human has seen your findings.

## Output

Return one JSON object keyed by claim id, matching this shape exactly:

```json
{
  "<id>": {"verdict": "supported"},
  "<id>": {"verdict": "not-addressed"},
  "<id>": {"verdict": "contradicted", "quote": "<exact text copied from the evidence>"},
  "<id>": {"verdict": "overgeneralized", "quote": "<exact text copied from the evidence>"}
}
```

`quote` is present only for `contradicted` and `overgeneralized` — omit it for `supported` and
`not-addressed`. Cover every id you were given; do not invent ids and do not skip one silently.
