# AGENTS.md — legacy-docstrings (eval fixture)

Tiny, runnable fixture used only by `scripts/ci/skill-eval.py`'s `docstring-sync-legacy`
case to exercise `/docstring-sync` against planted drift and a set of controls that must
stay untouched.

## Layout

- `legacy.py` — planted findings: a pointer-only plan-path comment (`plans/legacy-retry.md`,
  reason harvested from `plans/legacy-retry.md` on disk), a pointer-only `TASKS.md` row
  comment, Google- and NumPy-style param drift, an `_summary_` placeholder stub, and a
  body-newer drift (`parse_config`'s body changes in a later fixture commit than its
  docstring, via `_history/01/`). Also carries negative controls: a pointer to a tracked
  ADR, lowercase protocol prose ("step 3 of the TLS handshake"), an accurate docstring, a
  `NotImplementedError` stub with a Returns section, and an accurate doctest.
- `app.py` — one FastAPI route with a runtime-visible docstring; must stay byte-identical.
- `plans/legacy-retry.md` — the plan `legacy.py`'s pointer-only comment cites; gitignored
  in the eval copy, the same as a real consumer repo. The rule ships as `_gitignore`, which
  the harness renames to `.gitignore` in the copy; a real nested `.gitignore` here would also
  hide the plan from the toolkit's own git, so it could never be committed as fixture content.
- `docs/adr/0001-example.md` — a tracked, durable pointer target (left alone by policy).
- `tests/test_legacy.py` — exercises the doctest (`double`) and the FastAPI route.

Run tests with `pytest -q`.
