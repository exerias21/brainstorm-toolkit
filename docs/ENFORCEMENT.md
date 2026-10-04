# Prose vs. hook vs. detector — worked examples

> **✓ Live contract — current and maintained.**

`AGENTS.md`'s "When a rule earns a hook, not just prose" states the four questions and the
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

### Its own interpreter probe needed the same determinism it provides

The hook's interpreter probe originally tried only `python3`/`python`, so a machine whose sole
working interpreter is the Windows `py` launcher had `pipeline.enforce_cap: true` enforce
nothing, silently — no error, no systemMessage, just a cap that never clamped anything. It now
resolves through `scripts/hooks/_pyresolve.sh`, the same three-tier order (`$BRAINSTORM_PYTHON`
-> `.claude/project.json` `python` -> probe `python3`/`python`/`py`) every other hook under
`scripts/hooks/` shares, and if no interpreter resolves at all while `enforce_cap` looks
configured true, it emits a visible `systemMessage` instead of going quiet. `_pyresolve.sh` also
validates a project.json-supplied `python` value (`hooks_is_plausible_python`) before ever running
it as the interpreter — every always-on hook (`next-action.sh`, `reseed-context.sh`,
`run-cost-report.sh`) reads that same key, and none of them previously checked the value was
plausibly Python before executing it: a narrower instance of the same "config from a repo you
merely opened" trust problem the `stop-gate.sh` case below is about. The rule is bare-name-only: a
project.json-supplied `python` value is accepted only as a command name with no path separator and
no drive prefix, resolved through PATH — never treated as a filesystem path at all, so there is no
path-vs-project-root comparison left to bypass (an earlier path-comparison version was itself
case-sensitive, so it missed a differently-cased spelling of the same file on a case-insensitive
filesystem). The lookup PATH itself keeps only absolute entries (a relative or empty entry is
dropped, not just `.`), and every resolver returns the resolved absolute path rather than the bare
name — a safely-resolved bare name handed back to a later unsanitised PATH lookup reopens the exact
same gap it closed. A specific interpreter path still works, just not from a repo-controlled file —
`$BRAINSTORM_PYTHON` is the user's own environment and may still name one.

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

## `stop-gate.sh`'s `test.unit` — a hook that needed a trust check, not just a determinism check

`stop-gate.sh` runs a repo-configured shell command (`test.unit`) from a Stop hook, which
executes outside Claude Code's Bash permission system — no approval prompt, because the harness
never routes hook commands through the tool-permission path. That is fine when the config is the
person's own file, which git does not report as tracked. `setup.sh` does **not** gitignore
`.claude/project.json` unconditionally — it only always-ignores pure machine-state paths
(`.claude/pipeline/`, `.claude/.next-action`, `.claude/.auto-continue-hops`,
`.claude/.stop-gate-hops`); whether `.claude/project.json` itself is gitignored is a genuine team
decision `/repo-onboarding`'s Step 3 ("What should git ignore?") asks about, not something
setup.sh decides either way. So the trust check below does not read `.gitignore` at all — an
UNTRACKED `project.json` is trusted by design regardless of whether it also happens to be
gitignored, because untracked means it is the person's own config, not content that arrived with
the clone; that is intentional, not an oversight the check merely happens to cover. It stops being
fine the moment the file is tracked by git — a forced add, or a team that deliberately shares it —
because then the command that runs on Stop is content that arrived WITH THE CLONE, and opening the
repo is enough to run it, with no gate the model's own judgment could intervene on (there is no
"model decides whether to trust this" step; the hook runs before any model turn).

The fix is a deterministic, by-construction check rather than a prose warning: before ever
executing `test.unit`, the hook runs `git ls-files --error-unmatch -- .claude/project.json` and
stands down (systemMessage, never `decision:block`) if that file is tracked, unless the person
sets `BRAINSTORM_TRUST_STOP_GATE=1` themselves (the escape hatch for a team that really does commit
a shared config). This is a case the four questions answer cleanly: Q1 fires (the hole exists
exactly when nobody is watching — the first Stop after a clone), Q2 is a single git plumbing call
with a boolean answer, Q3 is three `scripts/ci/test-hooks.sh` cases (tracked stands down and never
runs the command, the override re-enables it, untracked-inside-a-repo is unaffected), and Q4 is yes
— `git ls-files` cannot be routed around by anything short of untracking the file, which is the
intended escape. On top of the trust check, the first Stop of any run that does proceed also names
the exact command in its systemMessage/reason once (a
`.claude/pipeline/<slug>/.stop-gate-announced` marker makes it once-per-run, not once-per-Stop) —
cheap transparency for the case the trust check correctly lets through.

## The sub-agent git-write guard — a CI pin instead of a hook

On 2026-09-19 in poc-contractor, an `/sdlc` implement sub-agent ran `git stash` on its own
initiative, next to uncommitted Phase 1 work. `/sdlc` promises "no git writes at all"
(`skills/sdlc/SKILL.md`), but that promise lives in the *orchestrator's* skill text — a
dispatched sub-agent never reads it, so the rule simply didn't reach the agent that needed it.
The fix is a canonical guard sentence quoted verbatim into every prompt that dispatches a
file-editing sub-agent (`stage-2-implement.md`, `stage-2b-dispatch.md`, `fix-loop.md`,
`stage-5.7-review-fix.md`, `stage-5.9-cleanup.md`, `agents/e2e-test-runner.md`). A deterministic `PreToolUse` hook
blocking `git stash|commit|checkout|reset…` during an `in_progress` envelope was considered and
deferred: real protection, but a new hook for a failure seen
once. Instead, the guard sentence is pinned in `scripts/ci/forbidden-phrases.txt` (the row matching a
unique fragment of the sentence) — deleting it from any of the six prompts drops that file's
occurrence count below the pin, which `check_contracts.py` reports as a stale-pin finding.
That is CI enforcement of the *prose's presence*, not of the sub-agent's actual behavior — a
narrower guarantee than a hook, chosen because the failure has only happened once. Revisit trigger:
a second incident after this pin landed.
