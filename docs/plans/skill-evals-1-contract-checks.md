## Brainstorm Result: Skill evals tier 1 — static contract checks

### Direction
Add one stdlib-only CI script, `scripts/ci/check_contracts.py`, that proves the prose and
the config agree: every `project.json` key path a skill names exists in the example file,
every repo-path citation resolves, no wrong-fact phrase survives, and no sentence names the
same command twice. This is the cheapest tier of skill evals and it targets the exact
failure class the 2026-09 review found 46 instances of (dead keys such as
`sanity_check.model`, dangling `model-cap.md`, "PR body" in a no-git-writes pipeline,
collapsed rename pairs). It runs in under five seconds with no model calls, so it goes in
the existing `setup-roundtrip` workflow on every push.

### Conventions & reuse
- Follow: the shape of `scripts/ci/check_install_refs.py` — stdlib only, exit 0/1, one
  finding per line with `file:line`, `--json` optional.
- Reuse: `templates/project.json.example` as the single source of valid key paths
  (strip every `_*comment` / `_recommended*` key when building the set).
- Reuse: the collapsed-pair regex and the wrong-fact greps written out under
  "Migration policy" in `docs/CONVENTIONS.md`.
- Reuse: `scripts/validate_skills.py` conventions for walking `skills/`, `copilot/skills/`,
  `codex/skills/`, `agents/`, `skills/sdlc/templates/`.
- New (justified): `scripts/ci/forbidden-phrases.txt`, because a denylist of facts a rename
  invalidated must be editable without touching code.

### Implementation Steps
1. Create `scripts/ci/check_contracts.py` with four checks, each a function returning a
   list of `(path, line, message)`:
   - **Config keys.** Regex backticked dotted key paths rooted at a known top-level key
     (`models`, `agents`, `pipeline`, `test`, `logs`, `stack`, `eval`, `discipline`,
     `migrations`, plus bare `gotchas_file`, `main_branch`, `coauthor_trailer`, `modules`)
     across `skills/**/*.md`, `copilot/**/*.md`, `codex/**/*.md`, `agents/*.md`,
     `templates/*.template`. Flag any path not present in `templates/project.json.example`.
     Treat a trailing `.*` or `<x>` segment as a wildcard. Provide a small inline allowlist
     for keys that are documented as open lists (`pipeline.loop.*`, `stack.*`).
   - **Citations resolve.** Regex backticked paths matching
     `(skills|scripts|templates|docs|agents|hooks|examples)/[A-Za-z0-9_./-]+\.(md|py|sh|json|template|txt)`
     in the same file set and flag any that do not exist in the repo. Additionally flag a
     `docs/` path that appears in a `read … now` / `load` instruction inside `skills/` or
     `skills/sdlc/templates/` — `docs/` is never installed, so that is a load, not a cite.
   - **Forbidden phrases.** Read `scripts/ci/forbidden-phrases.txt` (format:
     `regex<TAB>reason<TAB>allow-glob(optional)`), grep the same file set, flag hits not
     covered by the allow-glob.
   - **Collapsed pairs.** Flag any sentence in which the same `/command` token appears
     twice (the shape a global rename leaves behind).
   Exit 1 if any finding; print a one-line summary count per check. Add `--self-test`,
   which writes a temp tree containing one violation of each kind and asserts each check
   catches exactly it, then exits 0.
2. Create `scripts/ci/forbidden-phrases.txt` seeded with: `PR body` (reason: `/sdlc`
   opens no PR; allow `docs/**`), `opens a PR`, `gh pr create` (allow `docs/**` and the
   Stage 6 DO-NOT list in `skills/sdlc/SKILL.md` and both overlays), `commit_sha` (allow
   `skills/task/SKILL.md`), `sanity_check.model`, `pipeline.review_fix.model`,
   `pipeline.sanity_check.focuses`, `model-cap.md`, `sdlc-lite`.
3. Run the script against HEAD and fix every genuine finding it reports by hand (never a
   global substitution — read each hit). Adjust allowlists only for hits that are correct
   attribution sentences or documented open lists.
4. Add a step to `.github/workflows/setup-roundtrip.yml` after `install-refs resolve`:
   `python scripts/ci/check_contracts.py` and `python scripts/ci/check_contracts.py --self-test`.
5. Update `CLAUDE.md` "Testing changes" (and its `AGENTS.md` copy, which must stay
   byte-identical) to list the new script as step 2, and add one bullet to the README's
   scripts list describing it.

### Cross-Module Touchpoints
- `templates/project.json.example` becomes load-bearing as the key registry; a new key
  must be added there before a skill may name it.
- `docs/CONVENTIONS.md` "Migration policy" gains a pointer: the two manual greps are now
  automated by `check_contracts.py`.

### Acceptance criteria
- `python3 scripts/ci/check_contracts.py` must exit 0 on the branch after step 3.
- `--self-test` must exit 0 and must report one caught violation per check (verify by
  reading its output).
- Injecting `` `models.sanity_check` `` into any skill must make the script exit 1 with a
  `file:line` pointing at the injected line (verify, then revert).
- Runtime must stay under 5 seconds on this repo.
- `python3 scripts/validate_skills.py` and `bash scripts/ci/setup-roundtrip.sh` still pass.
- No skill's line count increases (this plan adds scripts and docs only).

### Open Questions
- Should the citation check also cover `README.md`? Recommend yes for paths, no for phrases.

### Appendix: Alternatives Considered
- Extend `validate_skills.py` instead of a new file — rejected: that script is the
  frontmatter/marketplace linter and is already ~450 lines; contracts are a different axis.
- An LLM-graded "does this prose contradict itself" pass — rejected for tier 1: costs
  tokens per run and every finding this tier targets is mechanically detectable.
