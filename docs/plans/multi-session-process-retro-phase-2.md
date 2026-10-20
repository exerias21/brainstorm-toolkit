## Brainstorm Result: Multi-session process retro, Phase 2 (plan template sections)

### Direction
Ship Phase 2 of `docs/plans/multi-session-process-retro.md`: three new plan sections that make a
plan's assumptions checkable before code is written. `### Premises` lists the facts the plan rests
on, each with evidence (`path:line` or a command). `### Baseline & exit measurement` names what is
measured before work starts and the number or command that says it is done. `### Pins and forward
behaviour` lists behaviour that must not change (pinned) and behaviour that changes from now on
(forward). A consumer review found exactly the forward-run pin class these sections catch.
All three are optional: a plan without them parses and runs exactly as today. Prose only; no hook,
no agent, no git write. Version stays 0.18.25 (Phase 1 is still uncommitted in the same tree).

### Conventions & reuse
- Follow: the template's existing `###` heading level and its one-paragraph "what belongs here"
  notes — `skills/brainstorm/templates/plan.md.template`.
- Follow: Stage 0 already extracts named sections into `parse.json` (`skills/sdlc/SKILL.md`
  "Then parse the plan"); add the new fields there, additive, documented in
  `skills/sdlc/templates/state-schema.md` `parse` shape.
- Follow: the completeness focus prompt in `skills/sdlc/templates/stage-1.5-sanity-check.md` is the
  one judgment-heavy plan check; add the three checks to its prompt, not a new focus.
- Reuse: overlays parse the plan with the same sentence (`copilot/skills/sdlc/SKILL.md`,
  `codex/skills/sdlc/SKILL.md` "Then parse the plan"); mirror the extraction there.

### Implementation Steps

#### Phase 2 — Plan template sections
1. **Template.** Add `### Premises`, `### Baseline & exit measurement` and `### Pins and forward
   behaviour` to `skills/brainstorm/templates/plan.md.template`, between `### Conventions & reuse`
   and `### Implementation Steps`. Each gets a two-line note on what belongs there and "omit when
   empty". Premises: one bullet per fact, each with `path:line` or a command and its result. Baseline:
   the measurement command and today's number, then the exit number. Pins: `Pin:` lines (behaviour
   that must stay, with the test or value that guards it) and `Forward:` lines (behaviour that changes
   for every later run). Update the header comment's list of parsed headings.
   Files: `skills/brainstorm/templates/plan.md.template`
2. **Brainstorm step 6 list.** The section list in `/brainstorm` Step 6 names every section; add the
   three (as optional) in the canonical skill and the Copilot overlay.
   Files: `skills/brainstorm/SKILL.md`, `copilot/skills/brainstorm/SKILL.md`
3. **Stage 0 parse.** "Then parse the plan" also extracts premises, baseline and pins when present,
   and `parse.json` gains `data.premises[]`, `data.baseline` (string or null) and `data.pins[]`
   (each `{kind: "pin"|"forward", text}`); empty/null when the plan has no such section. Document
   the fields in the `parse` shape.
   Files: `skills/sdlc/SKILL.md`, `copilot/skills/sdlc/SKILL.md`, `codex/skills/sdlc/SKILL.md`,
   `skills/sdlc/templates/state-schema.md`
4. **Completeness focus.** The completeness prompt gains three checks, each skipped when the section
   is absent. Each has an objective test, not a judgment call: (a) a premise about existing code
   whose cited `path:line` or symbol is absent, or whose command result the code contradicts, is a
   `fail` (and critical when the Direction rests on it); a premise about code this plan creates is
   never failed as absent; (b) the baseline contains a backticked command; (c) every `Pin:` line
   contains a test name, a path or a literal value, and every `Forward:` line shares a file path or
   key with some implementation step. The exit number and `Forward:` behaviour describe the future
   and are never failed as not yet true.
   Files: `skills/sdlc/templates/stage-1.5-sanity-check.md`
5. **Implementer honours pins.** `stage-2-implement.md`'s "honor the `Conventions & reuse` block"
   bullet also tells the agent to keep every `Pin:` true and deliver every `Forward:` line. Fix that
   bullet's `## Conventions & reuse` to `###` (the template's level) while there.
   Files: `skills/sdlc/templates/stage-2-implement.md`
6. **Verify.** Template notes and examples name no plan path and no bare `python`/`python3` (use
   `bash scripts/py.sh` or a non-Python command). Run `bash scripts/py.sh scripts/validate_skills.py`,
   `bash scripts/py.sh scripts/ci/check_contracts.py`. Old envelopes stay readable: the new
   `parse.json` fields are additive and absent on old runs (say so in the `parse` shape).

### Cross-Module Touchpoints
- `/brainstorm-team` and `/task` write different plan shapes; they are not changed.
- Overlays: both `/sdlc` overlays and the `/brainstorm` Copilot overlay. `validate_skills.py`
  soft-warns on drift.
- `scripts/close-tasks.sh` reads only `Files:` lines and `#### Phase` headings; the new sections add
  neither, so it is unaffected.

### Open Questions
- None. The parent plan names the three sections; their order and optionality are decided here.

### Appendix: Alternatives Considered
- **Required sections.** Rejected: every existing plan in consumers would fail parsing or the
  completeness check.
- **A fourth sanity focus.** Rejected: one more agent on every run; the completeness focus already
  reads the plan against the code.
- **`##` headings (as the parent plan wrote them).** Rejected: the template's sections are `###`
  under one `##` title.
