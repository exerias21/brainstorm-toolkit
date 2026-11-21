# Stage 7 — Report (summary body)

Loaded by `skills/sdlc/SKILL.md` Stage 7 after the degrade check and stage table are printed.

Summarize: branch the changes are sitting on (uncommitted), files changed,
suggested commit message, eval pass/fail (or "skipped — no test surface"),
test-check summary, the Stage 5 plan check — requirements verdict plus the flowsim
flow trace and whether it was witnessed or advisory (or "skipped — no plan target")
— and anything left open. **Always print `tasks: N closed, M moved (K matched)`** from
Stage 6's `handoff.json` `data.tasks` — including `tasks: 0 closed (0 matched)` when
nothing matched — this is the line that turns a silent close-out miss into a visible one;
when `unmatched` is non-empty, add `(U unmatched — see /sdlc-status --reconcile)`.
Under `writer: "orchestrator"` print `tasks: reported to orchestrator (N close, M add) — /sdlc-status --reconcile shows these rows open until applied` instead.
List `data.shared` paths apart from the files changed, as `shared (stage by hunk)`.
When `review.json.data.independence == "degraded"`, add the line `independence: degraded —
findings surfaced only, never auto-fixed` (wording: `skills/sdlc/templates/stage-5.7-review-fix.md`
"Independence enforcement").
When Stage 6 wrote `data.waves`, add `waves: now N across L lane(s), next M` from its `summary`
(`now`, `lanes`, `next`) and one warning line per `overlaps[]` entry; omit both when it did not.
If the delivered diff departs from the plan (a step skipped,
reordered, or solved differently), say where and why in one line each — the
`plan-conformance-validator`'s
partial/missing rows are the source. Check `coauthor_trailer` in `.claude/project.json`: unless it is literally `true`, the suggested
commit message contains no `Co-Authored-By` (or other attribution) line — strip one if present. Make it explicit that **nothing was committed** — the next
move is yours.
