## Brainstorm Result: Stage 5.9 — an opt-in cleanup pass that never judges its own work

### Direction

Add one stage to `/sdlc`, after the code is proven correct and before the hand-off:
**strip over-engineering and refresh stale docstrings, scoped to the files this run
touched.** It is quality-only — it does not hunt for bugs, because Stage 5.7's
`correctness` lens already does, and a stage that does both ends up fixing what it just
accused. Opt-in, permanently off by default, bounded by lens count exactly like 5.7.

Three constraints shape the whole design, and each one killed a simpler version:

1. **It writes, so it cannot be the thing that verifies.** `plan-conformance-validator`
   is read-only *by enforced allowlist* — that is the only reason "it cannot edit the
   thing it judges" is a fact rather than a promise. Folding cleanup into it would let a
   `MISMATCH` be resolved by editing until the complaint stops. The cleanup agent is a
   separate dispatch that runs **after** Stage 5 is green, and whatever it changes is
   re-validated by re-running the Stage 5 gate — never by the cleanup agent itself.
2. **It cannot call `/simplify`.** That skill is built into Claude Code, not shipped by
   this toolkit and not present on Copilot or Codex. Depending on it would break the
   cross-tool contract that is the repo's whole premise, and would silently version the
   stage against the CLI instead of against this plugin. The stage carries its own prose.
3. **Unwitnessed opinions must not become edits.** Stage 5's flow axis is advisory when
   unwitnessed precisely because a trace with no runtime evidence can invent a finding
   that costs nothing to be wrong about. This stage only runs once Stage 5 is green with
   real test evidence, so it never acts on an unfalsified guess.

### Conventions & reuse

- Follow: `skills/sdlc/templates/stage-5.7-review-fix.md` — the whole shape is already
  there. Opt-in gate resolved in the SKILL before the template is opened, configurable
  lens fan-out, a cap applied in list order, a separate fix budget, a cumulative sidecar.
  Copy the *structure*, not the text.
- Follow: `skills/sdlc/templates/changed-files-gate.md` for scope. The stage reads
  `implement.json` `data.files_changed[]` — it must never sweep the whole repo, which is
  what `/dead-code-review` and `/repo-health` are for.
- Reuse: `skills/sdlc/templates/fix-loop.md` for the re-validate loop and the PAUSE block.
- Reuse: `skills/sdlc/templates/models.md` — Sonnet by default, `--model` > `models.cap` >
  default, and print `model: <tier> (cap: <cap|none>)` before dispatching. This is Axis 1,
  not the reviewer axis; `models.cap` governs it normally.
- Reuse: the `agents.code_review_lenses` / `agents.code_review_max_lenses` pattern for the
  new keys, so a reader who knows one knows the other.
- New (justified): nothing. No new agent definition — per `CLAUDE.md`, a definition file
  is earned only by an enforced `tools:` restriction, and this agent needs `Edit`. It is
  `general-purpose` plus a role prompt in `skills/sdlc/templates/`, with an explicit
  `model:` at the dispatch site.

### Implementation Steps

1. **Gate in the skill, body in the template.** Add `## Stage 5.9 — Cleanup pass` to
   `skills/sdlc/SKILL.md`, ≤8 lines: enabled only by `pipeline.cleanup.enabled: true` or
   `--cleanup`; `--no-cleanup` always wins off; omitted means off. Auto-off when Stage 5
   is not green, when `implement` was skipped (a validation-only run has nothing to clean),
   or when the diff touched no code surface. On skip, append `cleanup` to
   `run.json.stages_skipped` and **do not open the template**. Otherwise
   `**Read skills/sdlc/templates/stage-5.9-cleanup.md now**`.
2. **Write `skills/sdlc/templates/stage-5.9-cleanup.md`** with two lenses, selected by
   `agents.cleanup_lenses` (default both) and capped by `agents.cleanup_max_lenses`
   (default `2`):
   - **`over-engineering`** — speculative generality with one caller, an abstraction
     introduced for a second case that never arrived, a config key nothing reads, a
     wrapper that only forwards, error handling for a condition the type system already
     excludes, a parallel pattern where the repo already had one. For each: the minimal
     removal, and the call sites it touches. **Never** propose a rewrite; if the fix is
     bigger than a deletion plus its call-site updates, report it and leave it.
   - **`docstring-currency`** — only for functions/classes the diff actually changed:
     does the existing docstring still describe what the code now does? Flag `STALE`
     (says something no longer true — highest value, a wrong docstring is worse than
     none), `THIN` (exists but omits a new parameter, raise, or return shape), `MISSING`
     (public surface, no docstring). Follow the repo's existing docstring style rather
     than importing one; `/code-tour` owns the why-focused house style — cite it, do not
     restate it. Do not touch a docstring on a function this run did not change.
3. **Dispatch and apply.** One agent per selected lens, in one message, `general-purpose`,
   Sonnet by default, each given the changed-file list and the plan. Each returns findings
   with `file:line` plus a `minimal_fix`. Apply under `pipeline.cleanup.mode`:
   `interactive` (default — show the list, apply on confirmation), `auto` (apply all
   `safe_to_apply` findings), `off` (report only, change nothing). A finding is
   `safe_to_apply` only if it is a deletion, a docstring edit, or a rename with every call
   site named. Anything else is report-only regardless of mode.
4. **Re-validate unconditionally.** If any edit was applied, re-run the Stage 5 gate
   exactly once. A regression there **pauses the run** — this is an objective break, not
   an opinion, and it is the entire safety story for a stage that writes after the tests
   went green. Use the shared PAUSE block. Never let the cleanup agent decide whether its
   own edit was fine.
5. **State.** Write `stage-outputs/cleanup.json`:
   `{status, data:{lenses_run[], findings[], applied[], skipped_reason, revalidate:{ran,green}}}`.
   Add `cleanup` to the Stage 7 report — one line per applied change, and the count left
   report-only. Register the keys in `templates/project.json.example` with `_comment`s
   (`pipeline.cleanup.enabled`, `pipeline.cleanup.mode`, `agents.cleanup_lenses`,
   `agents.cleanup_max_lenses`) — the contract check fails the build otherwise.
6. **Overlays.** Add the same gate + pointer to `copilot/skills/sdlc/SKILL.md` and
   `codex/skills/sdlc/SKILL.md`. Both cite the shared template; neither inlines it. On a
   runtime with no sub-agent seam, run the lenses sequentially inline and report the same
   structured result, per the standing note at the top of the shared templates.

### Cross-Module Touchpoints

- `skills/sdlc/SKILL.md` grows by ≤8 lines; the two overlays by ≤6 each.
- `/repo-health` and `/sdlc-status` read `run.json`; a new terminal stage name must not
  break their non-terminal scan. Check both after adding it.
- `docs/FLOW.md` gains the stage in its diagram.
- Bug-catching is **out of scope by design** — it belongs to Stage 5.7's `correctness`
  lens. Say so in the stage prose so a future reader does not "helpfully" add it back.

### Acceptance criteria

- With no config and no flag, a `/sdlc` run must not open `stage-5.9-cleanup.md` at all,
  and must record `cleanup` in `stages_skipped` (verify by reading the envelope).
- With the stage enabled and a diff that deletes nothing, it must report zero findings and
  apply nothing rather than inventing work.
- An applied edit must be followed by exactly one Stage 5 re-run; a deliberately
  introduced regression must PAUSE the run, not proceed to hand-off (verify, then revert).
- `pipeline.cleanup.mode: "off"` must produce findings and zero file modifications
  (`git diff` identical before and after the stage).
- The stage must never modify a file absent from `implement.json` `data.files_changed[]`.
- `python scripts/validate_skills.py`, `python scripts/ci/check_contracts.py` and
  `bash scripts/ci/setup-roundtrip.sh` all pass; a fresh `--tools all` install resolves the
  new template citation from all three tool roots.

### Open Questions

- Should `docstring-currency` be allowed to ADD a docstring to a public function the diff
  created, or only refresh existing ones? Recommend allowing it for newly-added public
  surface only — that is where the gap is real and the author's intent is freshest.
- Does the eval suite want a `cleanup-stage` case? Recommend yes, once tier 2 has a
  fixture with deliberate over-engineering in it; not worth a bespoke fixture before then.

### Appendix: Alternatives Considered

- **Fold cleanup into `plan-conformance-validator`** — rejected, and this is the load-bearing
  rejection. It would need `Edit`, which means dropping the enforced read-only allowlist
  that makes its verdicts trustworthy, and it would let the agent that found a problem be
  the one that decides the problem is gone.
- **Call `/simplify`** — rejected: Claude Code built-in, absent on Copilot and Codex, and
  versioned with the CLI rather than with this plugin.
- **A dedicated `cleanup` agent definition in `agents/`** — rejected: it needs `Edit`, so
  there is no enforced `tools:` restriction to earn the file, and `agents/` is Claude-only,
  which would make the stage invisible on two of three runtimes.
- **Run it before Stage 5 instead of after** — rejected: cleaning code that has not yet been
  proven correct means the re-validation has no green baseline to regress *from*.
- **A standalone `/cleanup` skill** — deferred. If the stage proves useful, extracting it is
  cheap; adding a fourteenth skill before it has run once is not.
