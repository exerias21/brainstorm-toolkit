## Brainstorm Result: /docstring-sync — repair docstrings and comments that drifted from their code

> **For review — nothing here is implemented.** Written 2026-09-22 from the owner's idea ("scan
> over the docstrings and update them based on the function … clean up legacy docstrings — make
> them match") and the consumer-repo finding behind commit `5228c5e`: a large set of files carrying
> comments like `# plans/LAUNCH_REQUIREMENT_PHASES.md ... Do not reintroduce.` that rot because
> `plans/` is gitignored there. The toolkit now forbids *new* pointers; this skill repairs the
> existing ones, and the wider class of stale, placeholder and drifted docstrings.

### Direction

**Ship `/docstring-sync` as a toolkit skill (`claude copilot codex`) that repairs existing
documentation to match the code, fully functional LLM-only, with Jev as an optional triage
accelerator reached only through the planned `jev` seam.** A stdlib script does everything
deterministic first — discovery that respects `.gitignore`, AST extraction, plan-pointer and
placeholder detection, param/return drift, a git-blame "body changed after its docstring" signal —
and nothing a script can decide is ever sent to a model. Judgment (is this sentence still true of
the body?) runs only on the survivors, in the claim-versus-evidence shape `jev-verify` already
proves on this machine: claim = one docstring sentence, evidence = the function's source. Without
Jev, find-only Sonnet agents answer the same question in the same vocabulary, and must quote the
contradicting lines, which code string-matches before acting (the citation-check cookbook's
"is the quote in the source?" step). With Jev configured, one cheap request per docstring covers the
whole repo, and the LLM only sees what Jev leaves uncertain — the SDE-cascade pattern (cheap
judgment, escalate only the flagged). Rewrites touch only flagged docstrings, keep accurate author
prose, carry the COMMENTS rule verbatim, and are proven docs-only by comparing each file's AST with
docstrings stripped. The skill never commits; it hands back a diff. It is **a new, separate skill,
not a `/code-tour` mode**: `/code-tour` *adds* teaching-depth docstrings for an audience; this one
*repairs* existing ones with minimal edits. The two share `/code-tour`'s standards reference rather
than restating it.

---

### Design answers (one recommendation per question)

**1. Where it lives and what it is called.** A shipped toolkit skill, `skills/docstring-sync/`,
named `/docstring-sync` ("sync" = make the docs match the function; `/docstring-audit` would
wrongly promise read-only). Not user-level only: the consumer repos with the rot run Copilot and
Codex too, and Copilot/Codex load no Claude skills (`docs/JEV.md:39-44`). Not a second, Jev-specific
skill either: Jev enters through the one seam `docs/plans/jev-integration.md` designs, never a
direct call to `jev_verify.py` from shipped prose. The owner can still dogfood Jev by hand before
that seam lands, because the script's claims file is byte-compatible with `jev_verify.py`'s input
(see Phase 2) — that path is documented here, in `docs/`, and never in the shipped skill.

**2. Pipeline.**

```
discover ─► extract ─► mechanical checks ─► triage ───────────► confirm ─► rewrite ─► verify ─► report
git ls-files  ast +     script, no model:    Jev if configured,   one       flagged    AST docs-only
-co --exclude tokenize  pointer, placeholder,else find-only LLM;  prompt    symbols    guard, re-scan,
-standard;              param/return drift,  code maps verdict+             only,      tests; no git
path/--changed          body-newer, runtime  band to an action              Sonnet     writes
```

- **Scope flags:** positional paths; `--changed` (read-only `git diff --name-only HEAD` plus
  untracked-not-ignored); `--pointers-only` (the fast legacy path); `--limit N` files edited per run
  (default 25 — the scan is the state, so a re-run continues where the last stopped); `--report`
  (never edits, never loads the rewrite rules).
- **Languages:** Python gets full treatment (`ast` + `tokenize`, never imports the target). The
  pointer and placeholder scans run over comment lines in any text source file via a comment-prefix
  heuristic, marked `heuristic: true`. Non-Python param drift is delegated to the repo's own linter
  when it already configures one (Phase 4); otherwise it is not checked, and the report says so.
- **Legacy cleanup is a selection of the same checks, not a second pipeline:** pointer and
  placeholder cleanup across comments *and* docstrings (on by default, and all of `--pointers-only`);
  `--unify-style <convention>` converts minority-convention docstrings (Phase 4); `--fill-missing`
  writes contract-level docstrings for public symbols that have none (Phase 4; never by default —
  a missing docstring is otherwise report-only, and teaching-depth fills are `/code-tour`'s job).

**Finding vocabulary**, aligned with Stage 5.9's `docstring-currency` lens
(`skills/sdlc/templates/stage-5.9-cleanup.md:66`) so the two never drift apart:

| Kind | Meaning | Decided by |
|---|---|---|
| `STALE` | a sentence the body contradicts, or states more broadly than the body shows | triage (Jev or LLM) |
| `THIN` | documented params/returns disagree with the signature/body; omits a raise or side effect | script (params/returns); shadow Noul (omissions) |
| `MISSING` | public symbol, no docstring | script — report-only unless `--fill-missing` |
| `POINTER` | plan path, `TASKS.md` row, plan/phase/step numbering, a cited path that is missing or gitignored, or a pointer-only ticket ref | script |
| `PLACEHOLDER` | empty, `_summary_`/`_description_` (autoDocstring stubs), `TODO`-only, "Docstring for X" | script |
| `STYLE` | minority convention in the repo; types repeated beside annotations; signature restated | script (Phase 4) |

Every finding also carries `severity: certain|suspect` and `runtime_visible` (below). `suspect`
findings — plan numbering with no plan path (`# step 3 of the handshake` is legitimate protocol
prose), ticket refs — go to the confirmation list, never straight to the rewrite queue.

**Pointer policy.** A pointer to a **tracked, durable** file (an ADR, `docs/ARCHITECTURE.md`) is
left alone — ADRs are the recommended home for system-level "why"
(`skills/code-tour/references/standards.md:270-289`). A pointer to a plan path, a `TASKS.md` row,
or a missing/gitignored path is `certain`. The rewrite keeps the *reason* and drops the pointer; if
the comment is pointer-only, the rewriter first looks for the plan **on disk** (a consumer's
`plans/` is gitignored but usually still present locally) and inlines the load-bearing reason. If
the plan is gone, it keeps the bare instruction ("Do not reintroduce the retry wrapper here."),
drops the pointer, and lists it for the human — it never invents a reason
(`skills/code-tour/SKILL.md:106-109`).

**3. The Jev question design.** Reuse the `jev-verify` shape exactly; do not invent a status Choice.

- **Primitive:** per claim, the `jev-verify` triple of Nouls — `supported`, `overgeneralized`,
  `contradicted` (`~/.claude/skills/jev-verify/SKILL.md:11-15`) — all claims of one docstring in one
  request, since batching every question into one call is 12.2x cheaper with no change in answers
  (TypeSafe parallel-questions cookbook).
- **State:** `{claim, evidence: [function source]}`. Code builds each claim: one sentence of the
  summary, description or a param description, prefixed with the symbol (`` `load_config`: Returns
  None when the file is missing.``) so a pronoun-led sentence still names its subject. Evidence is
  the function's own source including decorators, capped in code (default 200 lines, far under
  Jev's 32k-token state bound); an oversized body skips Jev and goes to the LLM path. Nothing else
  goes in state — accuracy falls as unrelated state grows (Jev 1.13 jaggedness, failure mode 5).
- **Why not a Choice over `{accurate, stale, incomplete, pointer-only, missing}`:** pointer-only and
  missing are mechanical, so asking a model is paying for a worse answer; and "stale vs incomplete"
  hides several judgments in one question, which the jaggedness page names as a failure mode — a
  docstring can be both. The SDE-cascade appendix points the same way: narrow per-field questions,
  bad = TRUE, aggregate with `max`. So `THIN`-by-omission is a **separate** Noul, `omits_behavior`
  ("Does `evidence` raise an exception, mutate an argument or global state, perform I/O, or return a
  different kind of value that the docstring does not mention?"), **shadow-only** until labelled.
- **Thresholds (starting points, owned by the judge, not the toolkit):** `act` at 0.8 with
  `contradicted ≤ 0.2` for a corroboration — `jev_verify.py:28-29`, itself from the citation-check
  cookbook's "start at 0.8 and lower as you see results". The toolkit consumes only
  `{verdict, band}` (`docs/plans/jev-integration.md:63-71`).
- **Jev picks, code decides** — the script owns this table:

| Source | Verdict | Band | Action |
|---|---|---|---|
| Jev or LLM | `contradicted` / `overgeneralized` | `act` | queue a `STALE` rewrite |
| Jev | `supported` | `act` | skip LLM triage for this docstring |
| Jev | any | `uncertain` | LLM triage **only if** the docstring is already a mechanical or body-newer candidate; otherwise listed, no action |
| any | any | `no` / null / error | no action, listed |

  LLM triage verdicts have no calibrated band, so code assigns one: `act` only when the agent's
  quoted contradicting lines are found verbatim (whitespace-normalized) in the evidence, else
  `uncertain`. An unverifiable accusation never becomes an edit.

**4. Cost and scale (a 500-function repo, ~400 with docstrings, ~3 claims each).**

| Stage | Calls | Rough size | Notes |
|---|---|---|---|
| Mechanical | none | seconds; one read-only `git blame` per file | free |
| Jev triage (when enabled) | one request per docstring, ~400 | ~1.2k input tokens each ≈ 0.5M tokens ≈ **$0.02** at $0.042/M input, output free | 1,200 req/min rate limit → under a minute. Even one request per claim (how `jev_verify.py` calls today) stays around $0.05 |
| LLM triage, no Jev | candidates only (mechanical ∪ body-newer, typically 20–30%) in per-file batches at Sonnet | ~200k–400k tokens | `--all` widens to every docstring — ~3x the cost, and naive LLM detection flags most functions (DocPrism) |
| LLM triage, Jev enforce | only Jev-`uncertain` ∩ candidates | a fraction of the row above | the cascade saving |
| Rewrite | flagged only (expect 10–20%: DocPrism puts real inconsistencies at ≥11%, plus pointers and placeholders), batched ~8 files per agent at Sonnet | ~150k–600k tokens | `--model opus` opt-up per `skills/sdlc/templates/models.md` |

A full LLM-only run lands at several times `/dead-code-review`'s row in `docs/COST.md:44`; a
`--pointers-only` run has no triage at all. Sonnet by default everywhere; the fan-out rides Axis 1
and prints `model: <tier> (cap: <cap|none>)` before each dispatch
(`skills/sdlc/templates/models.md:175-180`).

**5. Safety.**

- **Docs-only, proven in code.** Before editing, the script snapshots each target file's AST dump
  *with docstrings removed* (comments are not in the AST at all) to a path under
  `tempfile.gettempdir()` — nothing lands in the repo, so no new gitignore entry. After editing, any
  file whose stripped AST differs is a violation: the run stops and reports it. For non-Python files,
  every changed line must be a comment or blank line by the same heuristic.
- **Runtime-visible docstrings are report-only by default.** A docstring can be behaviour: FastAPI
  and Flask routes publish it as OpenAPI text, click/typer commands and `argparse(description=__doc__)`
  print it as `--help`, and `>>>` blocks run under `--doctest-modules`. The script marks these
  `runtime_visible`; the rewrite skips them unless `--include-runtime-docstrings`.
- **No restating, no invented intent.** The rewrite rules cite `/code-tour`'s standards
  (`skills/code-tour/references/standards.md:144-167` on types, `:328-361` on LLM-authored docs)
  and its bad-output list (`skills/code-tour/SKILL.md:228-244`) instead of restating them; a rewrite
  edits only the flagged sentences and keeps accurate author prose
  (`skills/code-tour/SKILL.md:49-51`). C4RLLaMA got 55.9–65.0% of comment updates right — so a
  human diff review is mandatory, not polish.
- **The COMMENTS rule, enforced twice.** Prose: the rule line verbatim in the rewrite rules and
  every rewrite prompt, pinned in CI. Code: the pointer scan re-runs on every touched file and a
  single remaining `certain` `POINTER` fails the run.
- **Tests before and after**, the `/dead-code-review` pattern (`skills/dead-code-review/SKILL.md:23-27`);
  with no suite configured the run proceeds (the AST guard is the primary control) and says so.
- **No git writes, ever**, and the verbatim GIT line in every file-editing prompt
  (`scripts/ci/forbidden-phrases.txt:29`).

**6. Testability.** Three layers, matching `docs/EVALS.md`'s tiers:

- **Tier 0 (free, every push):** `docstring_check.py --self-test` builds a synthetic tree in a temp
  dir with planted positives *and* negative controls, and asserts both — the
  `check_contracts.py --self-test` precedent (the `contract checks` step, `.github/workflows/setup-roundtrip.yml:34-37`). Plus
  a `forbidden-phrases.txt` pin on the COMMENTS line.
- **Tier 2 (nightly/on-demand, costs money):** a legacy-docstring fixture and a `skill-eval.py`
  case graded by deterministic assertions — never an LLM grader.
- **Jev calibration** stays EXTERNAL, in the judge's own labelled-set harness
  (`docs/plans/jev-integration.md:283-296`), seeded from the same fixture.

No hook: see *Appendix: Alternatives Considered*, G.

---

### Conventions & reuse

- Follow: the bundled-script shape of `/code-tour` — a stdlib script inside the skill directory,
  invoked as `bash scripts/py.sh <skill-dir>/scripts/…` (`skills/code-tour/SKILL.md:57-61`),
  parsing with `ast` and never importing the target (`skills/code-tour/scripts/docstring_audit.py:11-17`),
  exit codes 0/1/2 with a parse error never counted as clean (`:25-29`, `:121-137`), and a
  `main(argv=None)` entry that tests can call directly (`:203-209`).
- Reuse (copy, with a one-line provenance comment — skills stay self-contained): the qualified-name
  AST walk (`skills/code-tour/scripts/docstring_audit.py:95-118`) and the default excludes
  (`:53-57`) as the non-git fallback for discovery.
- Reuse: `/code-tour`'s standards reference as the rewrite agents' style authority, **loaded, not
  restated** — `skills/code-tour/references/standards.md` — and its "reason in the docstring, never a
  pointer to a plan, ticket, or design file" rule (`skills/code-tour/SKILL.md:125-127`).
- Follow: Stage 5.9's apply contract — findings printed once, a **single** confirmation, a
  non-interactive run with no channel to ask treated as report-only
  (`skills/sdlc/templates/stage-5.9-cleanup.md:72-81`); the find-only-then-apply split and the
  default-deny rubric where a docstring edit is applicable and anything else is report-only
  (`:83-87`); GIT and COMMENTS lines quoted verbatim into any file-editing sub-agent (`:94-98`).
- Follow: the COMMENTS line text exactly as it appears at `skills/sdlc/templates/fix-loop.md:14`.
- Follow: the no-overlay dual-runtime shape of `/repo-health` — parallel on Claude, one sentence
  saying Copilot/Codex run each batch inline and sequentially (`skills/repo-health/SKILL.md:32-36`),
  consistent with `skills/sdlc/templates/models.md:186-199`.
- Follow: the test-baseline and never-commit rules of `skills/dead-code-review/SKILL.md:23-27` and
  `:92`; its lens role prompts in `references/` (`skills/dead-code-review/SKILL.md:40`).
- Reuse: the claims/verdicts shape of `~/.claude/skills/jev-verify/scripts/jev_verify.py:8-11`
  (`[{id, claim, evidence: [...]}]` in, `{id: {…, band}}` out) and its code-owned band
  (`:26-42`), so the Jev path needs no new question design.
- Reuse: the `jev` opt-in block and the `scripts/judge.py` shim from
  `docs/plans/jev-integration.md:302-341`; its three-band convention with a never-acting middle
  (`:195-197`); its promotion rule for leaving shadow mode (`:495-501`); its scope-gate note for
  phases that must not get `TASKS.md` rows yet (`:219-224`).
- Reuse: `scripts/ci/forbidden-phrases.txt`'s count-pinned allow-globs as a presence pin, exactly as
  the GIT guard does (`scripts/ci/forbidden-phrases.txt:29`).
- Reuse: `scripts/ci/skill-eval.py`'s deterministic assertions — `file_matches`, `file_not_matches`,
  `pytest_green`, `git_head_unchanged`, `agent_models_within_cap` (`scripts/ci/skill-eval.py:604-620`).
- Follow: the fan-out registry — add the skill to `MODEL_CAP_FAN_OUT_SKILLS`
  (`scripts/validate_skills.py:44-54`) once it dispatches sub-agents.
- New (justified): `skills/docstring-sync/scripts/docstring_check.py`, because `docstring_audit.py`
  measures presence only and belongs to a different skill; extending it would couple two skills'
  install trees and turn a coverage auditor into a linter.
- New (justified): an optional `fixture` key in skill-eval cases, because the fixture path is
  hardcoded (`scripts/ci/skill-eval.py:57`, copied at `:861`) and seeding legacy docstrings into
  `mini-fastapi` would disturb every existing case's baseline.
- Doc drift: commit `5228c5e` says one identical COMMENTS line now sits beside the GIT guard in
  every code-writing prompt, but only the GIT guard is CI-pinned (`scripts/ci/forbidden-phrases.txt:29`);
  deleting a COMMENTS line from any of its sites fails nothing today. Phase 1 closes this.
- Budget: the shipped description set measures ~6,630 characters today against CLAUDE.md rule 4's
  7,500 ceiling. The draft description below is 394 characters (~7,024 total) — keep it under ~450.

---

### Implementation Steps

> **Scope-gate note.** Phase 5 depends on `docs/plans/jev-integration.md` Phase 3 (the `jev` block
> and `scripts/judge.py`) and on EXTERNAL work in claude-wiki. **Do not add `TASKS.md` rows for
> Phase 5 until that has landed** — the Stage 0 scope gate takes the lowest phase with open rows,
> and a blocked phase would stall the queue. Phases 1–4 have no Jev dependency.

#### Phase 1 — Mechanical core and legacy-pointer cleanup (Python + comment lines; inline, no fan-out, no Jev)

The smallest useful slice: it fixes the consumer repo's plan-pointer rot end to end, with no model
judgment beyond the edit itself.

1. **`skills/docstring-sync/scripts/docstring_check.py`** (new, stdlib, never imports the target).
   - Discovery: `git ls-files -co --exclude-standard` inside a repo (read-only), else the copied
     default excludes; positional paths; `--changed`; tests included for the pointer scan, excluded
     from docstring checks unless `--include-tests`.
   - Python extraction: every module/class/def with its qualified name, docstring text and line
     span, parameters (excluding `self`/`cls`; `*args`/`**kwargs` by bare name), whether the body
     returns a value or yields, and decorators. `tokenize` supplies comment tokens.
   - Checks: `POINTER` (plan paths, `TASKS.md` rows, plan/phase/step numbering as `suspect`, cited
     paths that are missing or gitignored via read-only `git check-ignore`, ticket refs `suspect`
     and flagged only when pointer-only); `PLACEHOLDER`; `THIN` param drift for Google, NumPy and
     Sphinx sections (unrecognised style ⇒ skip, never guess) and returns drift (a documented
     Returns on a body with no value-return, excluding abstract/`NotImplementedError`/stub bodies);
     `MISSING` for public symbols, report-only. Every finding gets `runtime_visible` (route/CLI
     decorators, `description=__doc__`, `>>>`).
   - Pointer-only test: strip pointer tokens and filler ("see", "per", "as described in") and flag
     `pointer_only` when almost nothing remains.
   - `--pointers-only`, `--json`, grouped text summary; exit 0 clean / 1 findings / 2 parse error or
     nothing discovered (loud, like `docstring_audit.py`).
   - `--snapshot` (prints the temp path) and `--verify-docs-only <snapshot>`: stripped-AST equality
     for Python; changed-lines-are-comments for other files (`heuristic` in the output).
   - `--self-test`: planted positives (a `# plans/X.md ... Do not reintroduce.` comment with the
     plan present, one with it absent, a pointer-only `TASKS.md` row, param drift in each supported
     convention, an `_summary_` stub, a FastAPI route docstring, a doctest) and negative controls (a
     pointer to a tracked ADR, `# step 3 of the TLS handshake`, an accurate docstring, a
     `NotImplementedError` stub with Returns), plus a planted code edit `--verify-docs-only` must
     catch and a docstring-only edit it must pass. Handles CRLF and undecodable files.
2. **`skills/docstring-sync/references/rewrite-rules.md`** (new; loaded before the first edit, never
   on a `--report` run): minimal edit — only flagged sentences/sections; keep accurate author prose;
   the pointer policy (harvest the reason from an on-disk plan; never invent; keep the bare
   instruction and list it when unrecoverable; leave durable tracked pointers alone); skip
   `runtime_visible` unless opted in; match the file's existing convention; the COMMENTS line
   verbatim; read `skills/code-tour/references/standards.md` for the type-hint and
   no-restated-signature rules rather than restating them here.
3. **`skills/docstring-sync/SKILL.md`** (new, target under ~200 lines). Frontmatter: `name`,
   `argument-hint` (Claude-only; `setup.sh` strips it for Copilot/Codex), `metadata.brainstorm-toolkit-applies-to: claude copilot codex`,
   and this description (394 chars, trigger words first):
   > Repair docstrings and comments that drifted from their code: stale or wrong claims,
   > param/return mismatches, placeholder text, and pointers to plan files or tickets that rot.
   > Deterministic checks run first; an LLM rewrites only the flagged ones, and you review the diff.
   > Never commits. Use on /docstring-sync, "fix stale docstrings", "docstrings are out of date", or
   > "clean up legacy comments".

   Procedure: scope and flags → optional test baseline from `project.json` `test.*` (skip with a
   message when absent) → run the script and **report counts per kind before touching anything** →
   one confirmation (report-only on no, or with no channel to ask) → snapshot → **read the rewrite
   rules now** → edit inline, at most `--limit` files → `--verify-docs-only` + re-scan of touched
   files (zero `certain` `POINTER` allowed) + tests → report: per-kind before/after, files touched,
   the unresolved list (reasons that could not be recovered), `git diff --stat`, a suggested commit
   message. A short "not this skill" section in the body: teaching docs → `/code-tour`; the
   diff-scoped pass inside `/sdlc` → Stage 5.9's `docstring-currency` lens.
4. **Registration and docs.** `.claude-plugin/marketplace.json` `plugins[0].skills`
   (`.claude-plugin/marketplace.json:21`); a `README.md` skills-table row beside `/code-tour`
   (`README.md:24`); a `docs/COST.md` row near `:43-44`; one body line in
   `skills/code-tour/SKILL.md` Step 1 (near `:49-51`) — "docstrings that exist but no longer match
   the code: `/docstring-sync`" — body only, its description unchanged.
5. **CI pins.** `.github/workflows/setup-roundtrip.yml` runs the script's `--self-test` beside the
   `contract checks` step (a file with uncommitted edits today — cite by step name, not line). `scripts/ci/forbidden-phrases.txt` gains a row pinning the COMMENTS
   line (`never reference the plan in code`) at `:1` in each of its current sites — the fix loop,
   stage-2 implement, 2b dispatch, 2c converge, 5.7 review-fix, 5.9 cleanup,
   `agents/e2e-test-runner.md`, `skills/task/SKILL.md` — plus `rewrite-rules.md`.
6. **Version bump** — `.claude-plugin/plugin.json:3` and `.claude-plugin/marketplace.json:8`
   (`version-freshness` fails otherwise).

#### Phase 2 — Judgment triage and fan-out rewrite (LLM-only; the Jev-shaped contract)

7. **`body-newer` signal** in the script: per file, one read-only `git blame --line-porcelain`; a
   symbol whose body lines carry a newer commit than its docstring lines is a candidate. This is the
   deterministic prior Deep-JIT motivates (inconsistency is introduced when code changes and its
   comment does not), at zero model cost.
8. **`dangling-ref`** in the script: a backticked identifier or Sphinx role in a docstring that
   resolves to no symbol in the repo index, no import and no builtin is flagged `suspect` — the
   citation-check cookbook's string-match step, which needs no model.
9. **Claims and verdicts files.** `--claims-out <file>` writes one entry per claim for the chosen
   docstrings (candidates by default, every docstring with `--all`), in `jev_verify.py`'s exact
   input shape; oversized evidence is marked and excluded. `--verdicts-in <file>` accepts
   `{id: {verdict, band, quote?}}`, adapts `jev_verify.py`'s band names (`corroborated` →
   `supported`/`act`, `contradicted`/`overgeneralized` → same/`act`, `uncertain` → `uncertain`,
   `error` → null), verifies LLM quotes against the evidence, and applies the action table from
   *Design answers*. Owner-only dogfood path until Phase 5, never named in shipped prose:
   `--claims-out` → `jev_verify.py` → `--verdicts-in`.
10. **`skills/docstring-sync/references/triage-prompt.md`** (new): the find-only role prompt.
    Per claim, answer `supported` / `overgeneralized` / `contradicted` / `not-addressed`, quoting
    the contradicting lines verbatim for a `contradicted`/`overgeneralized` answer. Incorrectness
    only — "could be clearer" is not a finding (DocPrism's lesson: an open-ended "is this
    consistent?" flags nearly everything). Callee behaviour the body does not show is
    `not-addressed`, never `contradicted`.
11. **`skills/docstring-sync/references/rewrite-prompt.md`** (new): the rewrite role prompt — only
    the listed symbols, reads `rewrite-rules.md` and the standards reference, GIT and COMMENTS lines
    verbatim (a sub-agent never sees the skill), returns `{symbol, action, unresolved}` per symbol.
    Extend the Phase 1 COMMENTS pin to this file.
12. **`SKILL.md`:** triage step between the scan and the confirmation (the confirmation now shows
    each quoted contradiction); rewrite fan-out in per-file batches on Claude, inline and sequential
    on Copilot/Codex (one sentence, `/repo-health`'s shape). Before each dispatch, resolve and print
    the tier per the `models.md` pointer. Triage and rewrite stay separate passes with the human
    confirmation between them — a pass that accuses and fixes grades its own accusation
    (`skills/sdlc/templates/stage-5.9-cleanup.md:7-9`).
13. **`scripts/validate_skills.py`:** add `docstring-sync` to `MODEL_CAP_FAN_OUT_SKILLS`. **Version
    bump.**

#### Phase 3 — Outcome eval on a legacy fixture (nightly tier)

14. **`scripts/ci/skill-eval.py`:** optional `fixture` key per case, default `mini-fastapi`; every
    existing case unchanged.
15. **`evals/skills/fixtures/legacy-docstrings/`** (new, tiny, runnable with pytest): the Phase 1
    self-test's positives and controls as real files, a gitignored `plans/` holding one plan whose
    reason must be harvested, one body-newer drift planted across two fixture commits, and a test
    suite that exercises the doctest and the FastAPI route.
16. **`evals/skills/cases/docstring-sync-legacy.json`** (new): `file_not_matches` for plan-path
    pointers in source; `file_matches` for the harvested reason text; `file_matches` that each
    control docstring is byte-identical; `pytest_green`; `git_head_unchanged`;
    `agent_models_within_cap`. Record its baseline in `evals/skills/baseline.json`; add a line to
    `docs/EVALS.md`. (`scripts/ci/` is not shipped, so no version bump.)

#### Phase 4 — Legacy extras: style unification, fill-missing, existing linters

17. **Style detection** in the script: per-docstring convention (Google / NumPy / Sphinx / plain),
    the repo's dominant one counted in code, `STYLE` findings for the minority, types repeated
    beside annotations, and a restated signature in the summary line.
18. **`--unify-style <convention>`**: the rewrite agent converts sections; the script re-checks
    convention *and* param drift afterwards. No deterministic converter (see Appendix, I).
19. **`--fill-missing`**: public symbols only by default (PEP 8 and linter design exempt private
    ones, `skills/code-tour/references/standards.md:169-189`), contract-level — summary line plus
    only what the signature cannot carry; the report points to `/code-tour` for teaching depth.
20. **Existing linters:** when the repo already configures pydoclint (`[tool.pydoclint]`) or
    eslint-plugin-jsdoc, run it and merge its findings as `THIN` — this is how non-Python param
    drift gets covered without the toolkit taking a dependency.
21. **Optional config** (only if dogfooding shows repeat use): a `docstrings` block with
    `convention` and `ticket_patterns`, each with a `_comment`, landing in **both**
    `templates/project.json.example` and `docs/CONFIG.md` (the `config-keys` check). **Version bump.**

#### Phase 5 — Jev triage through the planned judge seam (shadow first; blocked on jev-integration Phase 3)

22. **EXTERNAL · DEFERRED here: the `verify-claim` verb accepts a batch** (an array in, a map by
    id out) and asks the `jev-verify` triple per claim, one request per docstring. Plus
    `omits_behavior` as a shadow-only Noul. Labelled set: the Phase 3 fixture's planted drift as
    positives and its controls as negatives, plus planted false claims cited to real bodies (the
    wiki's negative-control method).
23. **Gate in the skill:** the Jev step runs only when `jev.enabled` is `true` and `jev.command` is
    non-empty (`docs/JEV.md:20-28`); otherwise one report line, "judge: not configured", and the
    Phase 2 path runs unchanged. Invocation is `bash scripts/py.sh scripts/judge.py verify-claim`
    fed by `--claims-out`, its output fed to `--verdicts-in`.
24. **Shadow (the default when enabled):** Jev covers every docstring; the rewrite queue stays
    exactly as Phase 2 decides it; the report adds "judge would have queued N more; agreed with LLM
    triage on M of K". **Enforce** (the verb named in `jev.enforce`, after the promotion rule):
    the action table in *Design answers* — `act` contradictions queue directly, `act` support skips
    LLM triage, `uncertain` escalates to LLM triage only for candidates.
25. **Post-rewrite re-verify:** rewritten claims go back through the judge; an `act`-band
    `contradicted` marks the edit "rejected by verifier" in the report for the human — flagged,
    never silently reverted. **Version bump.**

---

### Cross-Module Touchpoints

- **`/code-tour`** — its standards reference becomes a runtime load for this skill's rewrite
  agents, so edits there reach both skills; its body gains a one-line neighbour pointer (Phase 1);
  its description and `/docstrings` trigger stay as they are.
- **`/sdlc` Stage 5.9 `docstring-currency` lens** — shares the finding vocabulary. Follow-up, not
  scheduled: the lens runs `docstring_check.py` on `implement.json`'s changed files for its
  mechanical half and keeps its own judgment half.
- **Every COMMENTS-rule site** — pinned in CI from Phase 1, so deleting the line anywhere fails.
- **`/repo-health`** — follow-up, not scheduled: a read-only pointer-rot count via
  `--pointers-only --json`.
- **`docs/plans/jev-integration.md`** — gains a consumer of `verify-claim` that needs a batch form;
  add this skill to that plan's Cross-Module list when Phase 5 is picked up.
- **`scripts/validate_skills.py`**, **`.claude-plugin/marketplace.json`**, **`README.md`**,
  **`docs/COST.md`**, **`docs/EVALS.md`**, **`scripts/ci/skill-eval.py`**,
  **`.github/workflows/setup-roundtrip.yml`**, **`scripts/ci/forbidden-phrases.txt`** — registration
  and CI as listed per phase.
- **Consumers** — installed with every other skill by `setup.sh`; no required config, no new
  gitignore entry (snapshots go to the OS temp dir), no network unless the `jev` block is on.

### Open Questions

**Decided by the owner (2026-09-22), so neither is open any more:**

- **The three Nouls are canonical.** `verify-claim` asks `supported` / `overgeneralized` /
  `contradicted` per claim, with the band computed in code — the shape `~/.claude/skills/jev-verify/`
  already runs and the one this session used on real review findings. The Choice form sketched at
  `docs/plans/jev-integration.md:274-282` is not adopted; if that plan ships its verb, it takes this
  shape. Still to settle when Phase 5 starts: the verb must accept an array, since a run sends
  hundreds of claims.
- **An unrecoverable reason keeps the rule and loses the pointer**, and the line goes on the
  unresolved list for a human. Tickets count only when the comment is nothing but the pointer.
  **The owner's framing, which belongs in the skill's voice too: a plan reference never belonged in
  a docstring to begin with.** The COMMENTS rule in every code-writing prompt is the prevention;
  this skill is remediation for code written before it existed.
- **Where shadow verdicts live.** `judge.py` appends to an envelope's `judge.jsonl`, and this skill
  has no envelope (creating one under `.claude/pipeline/` would read as a stalled run to
  `/sdlc-status`). Recommended: the run report is the record; revisit if calibration needs more.
- **Description budget.** ~7,024 of 7,500 characters after this skill; the next new skill will
  likely force a trim elsewhere.

### Appendix: Alternatives Considered

- **A. A `--sync` mode inside `/code-tour`.** Not chosen: `/code-tour` is additive and
  audience-driven (Step 1's audience questions, full dependency-order reads); sync is minimal-edit
  repair. Merging would put two gates in one skill and need sync trigger words in a description
  already at 544 characters. Its only win — no new description cost — is real, and recorded.
- **B. User-level skill only, next to `jev-verify`.** Not chosen: the rot is in consumer repos on
  all three runtimes, and a Jev-only design breaks "works fully without Jev".
- **C. Both — shipped skill plus a user-level Jev wrapper.** Adopted in reduced form: the
  claims/verdicts files match `jev_verify.py`, so the owner can dogfood by hand today with no second
  shipped seam.
- **D. LLM judgment over every docstring by default.** Not chosen: DocPrism measured naive LLM
  detection flagging 98% of functions; cost scales with the whole repo. Kept as opt-in `--all`.
- **E. A status Choice over `{accurate, stale, incomplete, pointer-only, missing}`.** Not chosen:
  half its options are mechanical, and the rest hide several judgments in one question.
- **F. Triage and rewrite in one agent pass.** Not chosen: the fixer grades its own accusation, and
  there is no human gate between flag and edit.
- **G. A PreToolUse hook blocking plan pointers in `Write`/`Edit`.** Not chosen: a `Bash` edit routes
  around it (CLAUDE.md hook question 4), phase/step numbering has real false positives, and it is a
  second expression of the COMMENTS rule. The script's `--pointers-only --changed` exit code is the
  detector if a consumer wants a gate.
- **H. pydoclint/docsig as the mechanical core.** Not chosen as a dependency (the toolkit is
  stdlib-only and consumers may not have them); adopted as "run it too when the repo configures it"
  (Phase 4).
- **I. A deterministic Google↔NumPy↔Sphinx converter.** Not chosen: large, and napoleon only
  converts one way; LLM conversion plus a script post-check is cheaper to build and verify.
- **J. Widen Stage 5.9's `docstring-currency` lens repo-wide.** Not chosen: that stage is scoped to
  the run's diff by design (`skills/sdlc/templates/stage-5.9-cleanup.md:41-44`).
- **K. Regenerate every docstring on change (RepoAgent's model).** Not chosen: it discards accurate
  author prose and turns every change into docstring churn.

### Prior art

- **Mechanical checkers — structure only; none judges whether the prose is true.**
  [pydoclint](https://github.com/jsh9/pydoclint) (args/returns/yields/raises vs signature —
  [codes](https://jsh9.github.io/pydoclint/violation_codes.html));
  [docsig](https://github.com/jshwi/docsig) (params vs signature);
  [darglint](https://github.com/terrencepreilly/darglint) and
  [pydocstyle](https://github.com/PyCQA/pydocstyle), both archived, succeeded by ruff `D`/`DOC`;
  [interrogate](https://interrogate.readthedocs.io/) (presence only);
  [eslint-plugin-jsdoc](https://github.com/gajus/eslint-plugin-jsdoc) (`check-param-names`,
  `require-param`, `require-returns-check`);
  [eslint-plugin-tsdoc](https://tsdoc.org/pages/packages/eslint-plugin-tsdoc/) (TSDoc syntax only).
- **Research on drift.** Deep-JIT, [Panthaplackel et al. 2021](https://arxiv.org/abs/2010.01625) —
  inconsistency arises when code changes without its comment (the `body-newer` basis).
  [Radmanesh et al. 2024](https://arxiv.org/abs/2409.10781) — inconsistent changes ~1.5x more likely
  to introduce a bug, highest right after. C4RLLaMA,
  [ICSE 2025](https://github.com/aiopsplus/C4RLLaMA) — 65.0% / 55.9% correct comment updates.
  [CCISolver 2025](https://arxiv.org/abs/2506.20558) — cheap detector, then LLM fixer; existing
  datasets substantially mislabelled. [DocPrism, ISSTA 2026](https://arxiv.org/abs/2511.00215) —
  naive LLM detection flags 98% of functions; narrow incorrectness-only categorization cuts that to
  14% (F1 0.22 → 0.77), with ≥11% as the real-inconsistency floor.
  [RepoAgent](https://arxiv.org/abs/2402.16667) — regenerate-on-change docs.
  DocAgent and CASCADE are already cited in `skills/code-tour/references/standards.md:328-361`.
- **TypeSafe (read live, 2026-09-22).** [Citation check](https://docs.typesafe.ai/cookbooks/citation_check.md)
  (string match before any model; auto-accept at confidence ≥ 0.8, else a human);
  [SDE cascade](https://docs.typesafe.ai/cookbooks/sde_cascade.md) (cheap pass → per-field Noul
  verify, bad = TRUE, `max` → escalate only the flagged);
  [Confidence](https://docs.typesafe.ai/confidence.md) (three paths; thresholds scale with risk);
  [Noul](https://docs.typesafe.ai/primitives/noul.md) (no confidence field; threshold by cost of
  error); [Choice](https://docs.typesafe.ai/primitives/choice.md) (add a none-of-these option);
  [Jev 1.13 jaggedness](https://docs.typesafe.ai/model-jaggedness/jev-1.13.md) (literal reading,
  large state, indirection, no generation); [Models](https://docs.typesafe.ai/models.md)
  ($0.042/M input, output free, 1,200 req/min, 32k-token state);
  [Parallel questions](https://docs.typesafe.ai/cookbooks/parallel_questions.md) (one call, many
  questions: 12.2x cheaper).
