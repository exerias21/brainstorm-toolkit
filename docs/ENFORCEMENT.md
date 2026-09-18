# Prose vs. hook vs. detector — worked examples

> **✓ Live contract — current and maintained.**

`CLAUDE.md`'s "When a rule earns a hook, not just prose" states the four questions and the
tension (a hook is also a second expression, and this repo deleted a 1,398-line Workflow because
a second expression drifted). This page is the worked-examples appendix that section points to —
four real cases that came out differently. No cost table (that's `docs/SEAM.md`'s cross-tool Stop
hook section) and no new-hook checklist (the shipped hooks below are the checklist).

## `models.cap` — prose that earned a hook

Axis 1 (fan-out tier) was prose-only first: every dispatch site resolves `--model` >
`project.json` `models.cap` > default and prints `model: <tier> (cap: <cap|none>)` before
dispatching. The miss is named in `scripts/hooks/enforce-model-cap.sh`'s own header: "a dispatch
with no `model` inherits the session model with zero error and zero log line." That's Q1 (holds
even when the model forgets) and Q2 (the check is a stdin-JSON read, a `project.json` lookup, and
a rank comparison — no interpretation) both firing yes. The hook is a `PreToolUse(Agent)`
rewrite, opt-in via `pipeline.enforce_cap`, exempting `review:`-prefixed dispatches (Axis 2 is
never governed by the cap). `scripts/ci/test-hooks.sh` exercises it end to end with sample stdin
— Q3. 110 lines.

## Test immutability — deterministic, but not a hook

The designed version was a `PreToolUse` preventer blocking `Write`/`Edit` on an armed test file.
It was rejected: its own risk list conceded a `Bash`-driven `sed -i` routes around a `Write|Edit`
matcher, so the expensive parts (installer surgery, a tri-state config key, a self-exemption to
avoid deadlocking on its own marker) all bought a half that was already porous. Q4 — is a
preventer actually enforceable? — answered no. What shipped instead, `scripts/protect-tests.sh`,
is a plain CLI (`arm` / `verify` / `disarm`), not a hook: it records a test file's sha256 into the
run envelope's `data.protected_tests` at red-stage and re-checks it at close-out. Still fully
deterministic and still covered by `scripts/ci/test-hooks.sh` (whose scope line now reads
"deterministic controls" rather than "hooks" because of this case) — it just isn't wired to any
tool-call matcher, because there was no matcher worth wiring. It is a detector: it proves a
protected test's bytes changed since arming; it does not stop the rewrite.

## The Workflow — a second expression that didn't earn its keep

`sdlc-pipeline.workflow.js` (1,398 lines, plus a smaller one in `/brainstorm-deep`) mirrored the
`/sdlc` prose stage-for-stage. It failed Q2 and Q3 at once: it was not small, and nothing checked
it against the prose it mirrored — the prose↔Workflow sync leg had no automated guard, so the two
drifted apart silently. Contrast the shipped hooks and `protect-tests.sh` above, each 110–240
lines with `scripts/ci/test-hooks.sh` asserting on their actual stdout: a regression harness can
exercise "does this ~150-line script emit the right JSON for this stdin," but it cannot exercise
"does this 1,398-line script still say what the prose says" without becoming a second prose
document itself. See `docs/PROSE-FIDELITY.md` for the full case history of why it was deleted.

## The nine unopened pointers — prose-only today, and what determinism would cost

`/sdlc`'s `**Read skills/sdlc/templates/<x>.md now**` pointers fire at nine points; an audited run
read zero of them (795 lines of stage contract unread), and nothing caught it. This case passes
Q1 (the rule fails silently exactly when the model skips it) but stalls on Q2: a `PreToolUse` or
`PostToolUse` hook can confirm a `Read` tool call happened, but confirming the model *read* the
file is not the same claim as confirming it *loaded the stage contract before acting on it* —
that requires correlating a `Read` call's timing and path against the specific stage's later tool
calls, which means parsing `transcript_path` rather than a single stdin JSON payload. That is a
materially bigger, stateful check than the two shipped hooks, and nobody has built or tested it.
Until someone does, this rule stays exactly where `docs/PROSE-FIDELITY.md`'s prescriptive-prose
lever leaves it: the fix is tighter prose, not a hook, unless a future measurement shows the
tighter prose still isn't followed.
