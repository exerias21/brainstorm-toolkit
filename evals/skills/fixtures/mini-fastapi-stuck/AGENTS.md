# AGENTS.md — mini-fastapi-stuck (eval fixture)

Tiny FastAPI app used only by `scripts/ci/skill-eval.py` for the `sdlc-stuck-test`
case: a fix loop that cannot converge.

## Layout

- `app.py` — the FastAPI app (two routes).
- `tests/test_app.py` — passing tests.
- `tests/test_stuck.py` — a contract test that no implementation can satisfy. Do not edit it.
- `plans/stuck-test.md` — the plan `/sdlc` runs.

Run tests with `pytest -q`.
