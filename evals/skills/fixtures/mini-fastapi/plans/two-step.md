## Brainstorm Result: Add Health Endpoint

### Direction
Add a minimal `GET /health` endpoint to the mini-fastapi fixture app, returning
`{"ok": true}`, plus a test for it. This is the deliberately tiny, deterministic
two-step plan `/sdlc` runs headlessly in the `sdlc-two-step` eval case.

### Conventions & reuse
- Follow: existing route style in `app.py` (plain `@app.get(...)` handlers
  returning a dict) — see `app.py`.
- Reuse: the existing `tests/test_app.py` `TestClient` pattern for the new test.
- New (justified): none — this fits the existing two-route shape exactly.

### Implementation Steps
1. Add a `GET /health` route to `app.py` that returns `{"ok": true}`.
2. Add a test in `tests/test_app.py` asserting `GET /health` returns status
   200 and `{"ok": true}`.

### Cross-Module Touchpoints
- None — single-file change plus its test.

### Open Questions
- None.

### Appendix: Alternatives Considered
- None — this plan exists only to give `/sdlc` a minimal, deterministic
  two-step target for the eval harness.
