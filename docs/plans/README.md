# Plans — run each with `/sdlc docs/plans/<file>.md`

`plans/` is gitignored on this plugin repo (it is a consumer-side directory), so the plans
that ship with the repo live here. `/sdlc` takes any `.md` path; skill-repo mode is
auto-detected from `.claude-plugin/marketplace.json`, so Stage 3 skips and Stage 5 runs
the skill-repo validation (validator, marketplace, template refs, dry install).

Only plans still in flight — with open `TASKS.md` rows — live here. A plan is deleted once
its last row closes; the delivered plans are in git history.

| Plan | What is left | Run cost |
|---|---|---|
| `ai-native-sdlc-additions.md` | Phase 2: the smoke-eval gate (~$2/PR). | Low |
| `docstring-sync.md` | Phase 2 onward: LLM triage and the rewrite fan-out; phase 5 waits on the Jev judge. | Medium |
| `dogfood-followups.md` | Two `_followup_` rows: the README lint gap, and onboarding's `.gitignore` in a skill repo. | Low |
| `flow-gap-fixes.md` | Phase 5 (plugin-root-aware script citations, needs a design) and the deferred macOS pair. | Low |
| `jev-integration.md` | Phase 1 docs warnings; phases 2+ wait on claude-wiki being published. | Low |
| `model-tier-gaps-and-extras.md` | Phase 1 shipped. The opt-in extras plugin (phases 2–5) continues on its own branch. | Medium |
| `windows-portability-and-hygiene.md` | Two `_manual_` rows (update the plugin, restart, confirm hooks fire and `data.cost` populates) and one phase-2 row. | Low |
