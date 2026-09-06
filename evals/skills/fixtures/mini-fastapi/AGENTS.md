# AGENTS.md — mini-fastapi (eval fixture)

Tiny FastAPI app used only by `evals/skills/skill-eval.py` to headlessly
exercise brainstorm-toolkit skills against a real, disposable repo.

## Layout

- `app.py` — the FastAPI app (two routes).
- `tests/test_app.py` — pytest tests for it.
- `plans/two-step.md` — the plan `/sdlc` runs in the `sdlc-two-step` case.

Run tests with `pytest -q`.
