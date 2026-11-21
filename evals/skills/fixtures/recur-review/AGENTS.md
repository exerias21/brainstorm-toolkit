# AGENTS.md — recur-review (eval fixture)

Tiny repo used only by `scripts/ci/skill-eval.py` for the `sdlc-recurring-catch*` cases.
It starts with `/sdlc` paused after the review stage (`.claude/pipeline/current/`), plus
earlier finished runs whose envelopes record the same review-finding category.

- `app.py` — one helper, `parse_limit`.
- `tests/test_app.py` — its tests. Run with `pytest -q`.
