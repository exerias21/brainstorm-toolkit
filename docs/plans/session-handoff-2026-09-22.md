# Session handoff — 2026-09-22

A progress report for the session that picks this up. Written at the end of a long session on
PR #15; everything below was verified against the tree, not recalled.

## Where things stand

| | |
|---|---|
| Branch | `claude/sdlc-cost-review-model-bug-axs853` (PR #15, open) |
| HEAD | `570e214`, pushed, working tree clean |
| Version | 0.14.0 |
| CI | `claude-review` and `setup-roundtrip` both green on HEAD |
| Backlog | 14 open rows, 0 in progress, `close-tasks.sh reconcile` reports 0 drift |

PR #15 now carries a code review (posted as a comment), every fix that review produced, and two
new skills' worth of work. The PR description's top section is current.

## What landed this session

Newest first. Each commit message carries its own detail; this is the shape.

- `570e214` **`/docstring-sync`, phase 1.** A new shipped skill: `skills/docstring-sync/` with
  `scripts/docstring_check.py` (stdlib, AST + tokenize, never imports the target), `SKILL.md`, and
  `references/rewrite-rules.md`. Finds plan/task pointers, placeholder docstrings, param and
  return drift (Google/NumPy/Sphinx), and missing docstrings. `--snapshot`/`--verify-docs-only`
  prove a run changed only docstrings; `--self-test` runs in CI.
- `bfeb438` **The 11 posted review findings**, each re-confirmed and fixed, most with a
  `test-hooks.sh` case that failed first. Includes the row-lookup slug bug that made every
  `/brainstorm` plan match zero rows.
- `84a7696` The `/docstring-sync` design plan.
- `ef82a05` Removed `design/` — an accidental Claude Design export (recoverable:
  `git checkout 5232045 -- design/`).
- `5228c5e` **The COMMENTS rule**: one identical line in every prompt that writes code, forbidding
  plan pointers in comments and docstrings.
- `16216ae` Six lower-scored review findings, plus a Git Bash argv rewrite that mangled
  auto-continue on Windows.
- `d7e097e` Docs pass: README, `docs/FLOW.md`, CLAUDE/AGENTS, shipped templates, `/sdlc-status`.
- `36b06a9` and earlier: the scope-gate template, `_manual_` rows, phase-aware reconcile, the
  `portable-invocation` check.

## Decisions the owner made (do not re-litigate)

- **Jev's canonical question shape is three Nouls** — `supported` / `overgeneralized` /
  `contradicted` per claim, band computed in code. The four-way Choice sketched in
  `jev-integration.md` is not adopted; if that plan ships a verb, it takes this shape.
- **A pointer whose plan is gone keeps the instruction, drops the pointer, and goes on an
  unresolved list** for a human. Tickets count only when the comment is nothing but the pointer.
  The framing: a plan reference never belonged in a docstring to begin with.
- **Other repos are off limits.** The contractor app has ~79 files with plan-pointer comments; the
  tool to fix them now exists, but do not touch that repo without being asked.
- **No attribution lines** in commit messages or PR descriptions.

## What a new session should know exists

- **`close-tasks.sh rows --plan <slug>`** is how `/sdlc` Stage 0 finds a plan's rows. Never use
  `reconcile | grep` for that — reconcile only sees existing envelopes, so a first run reads zero
  rows. That exact miss cost a run this session.
- **`/jev-verify`** (user-level, `~/.claude/skills/jev-verify/`) is the only working Jev path on
  this machine: claim + quoted evidence in, three Noul probabilities and a band out. The key lives
  in claude-wiki's `.env` at `E:\programming\jev` and must never be printed. The toolkit's own Jev
  integration remains inert by design.
- **New CI checks, both proven to fail when violated:** the COMMENTS line is pinned per file in
  `scripts/ci/forbidden-phrases.txt`, and `setup-roundtrip.sh` now fails when a skill directory is
  missing from `marketplace.json` (previously only the forward direction was checked).
- **`/docstring-sync` can be run on this repo**: it reports zero `certain` findings today, which is
  the baseline to keep.

## Open work

14 rows, by plan. Resume any plan-file run with `/sdlc docs/plans/<plan>.md` — the scope gate takes
the lowest phase with open rows and parks the rest.

| Plan | Open | Notes |
|---|---|---|
| `jev-integration` | 3 (phase 1) | Docs warnings only; phases 2+ blocked on claude-wiki being published |
| `flow-gap-fixes` | 2 (phase 5), 1 (phase 4) | Phase 5 needs a design for plugin-root-aware script citations; phase 4 is the deferred macOS pair |
| `windows-portability-and-hygiene` | 2 `_manual_` (phase 1), 1 (phase 2) | The `_manual_` rows need you: update the plugin and restart, then confirm hooks fire and `data.cost` populates |
| `dogfood-followups` | 2 `_followup_` | The README lint gap, and onboarding's `.gitignore` in a skill repo |
| `ai-native-sdlc-additions` | 1 (phase 2) | Smoke evals workflow |
| `docstring-sync` | 0 open | Phases 2–5 have no rows yet; phase 5 is blocked on the Jev judge |
| `subagent-git-guard`, `board-json-export` | 0 | Delivered |

**Parked, ready to run now:** `/sdlc docs/plans/docstring-sync.md` takes phase 2 (LLM triage and
the rewrite fan-out). `/sdlc docs/plans/jev-integration.md` takes phase 1.

## Gotchas this session earned (all cost real time)

- **Git Bash rewrites a leading `/` argument** for native Windows programs: `/sdlc x` arrives as
  `C:/Program Files/Git/sdlc x`. Pass such strings on stdin. Fixed in `next-action.sh`; watch for it
  anywhere else a command string reaches Python as argv.
- **`git commit -F <(...)` silently does nothing here** — process substitution against a native git.
  Write the message to a file first.
- **A detector must pass its own rule.** `docstring_check.py` shipped citing the plan in its own
  comments. The fix was to reword and to let backticked examples demote generally — never a
  by-name self-exemption. If a rule needs an exemption to survive contact with itself, it is wrong.
- **A checker that flags working documentation gets switched off.** The first run flagged this
  repo's own usage examples as rot; example-context pointers are now `suspect`, not `certain`.

## Verify the tree in one block

```bash
bash scripts/py.sh scripts/validate_skills.py
bash scripts/py.sh scripts/ci/check_contracts.py
bash scripts/py.sh scripts/ci/check_contracts.py --self-test
bash scripts/ci/test-hooks.sh
bash scripts/ci/setup-roundtrip.sh
bash scripts/py.sh skills/docstring-sync/scripts/docstring_check.py --self-test
bash scripts/close-tasks.sh reconcile --file TASKS.md
```

All green as of `570e214`.

## Suggested next moves

1. **Merge PR #15, or ask for another review pass.** It is large (30 commits) and has been reviewed
   once, with every finding fixed and answered on the PR.
2. **The two `_manual_` rows** are the only work nobody but the owner can do: update the plugin to
   0.14.0, restart, confirm the hooks fire and `data.cost` populates.
3. **`/docstring-sync` phase 2** if the skill is wanted end to end; phase 1 is useful alone.
4. **Run `/docstring-sync` on a real consumer repo** — it has never been used outside this one.
