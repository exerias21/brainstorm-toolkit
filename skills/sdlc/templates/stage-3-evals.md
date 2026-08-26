# Stage 3 — Generate evals (shared)

Canonical for `/sdlc-lite`. Skip silently when no `eval.runner` is
configured; record `data.skipped_reason`.

Create test cases that verify the plan's INTENT, not just "does it compile."

### For features with new Python functions:

1. Identify all new pure functions (no I/O, no database, no browser)
2. Create `tests/eval/test_{feature_slug}_eval.py` with parameterized test cases
3. Import functions via `tests/eval/conftest.py::load_script_module()`
4. Write binary assertions: expected input → expected output

### For features with new scripts that output JSON:

1. If the script accepts `--input` fixtures, create:
   - `<eval.features_dir>/{feature_slug}/fixtures/{scenario}.json` — input data
   - `<eval.features_dir>/{feature_slug}/expected/{scenario}.json` — expected output
2. The runner auto-discovers new features by scanning `<eval.features_dir>/*/` —
   no registration needed.

### For pure functions that live in the application package (not loadable by the eval harness):

The eval harness is **script-scoped**: `tests/eval/conftest.py::load_script_module()`
only imports files under `scripts/`, and `eval-runner.py` only discovers features
under `<eval.features_dir>/`. Pure functions inside an application package
(`backend/app/...`, `src/...`, a FastAPI/Django/Rails service module) are
**unreachable** by that harness. **Do not mark these "skipped — no testable
surface"** — that's the trap where the most common feature type silently gets
zero coverage.

Instead, when the testable functions live in the app package:
1. Generate tests into the **project's native unit-test suite** at the
   project's convention (where `test.unit` points — e.g. `backend/tests/`,
   `tests/`, `__tests__/`), not into `tests/eval/`.
2. They run in **Stage 5** via the configured `test.unit` command, not via
   `eval.runner`.
3. Record `data.coverage_route: "test.unit"` in the generate-evals sidecar so
   Stage 5's flow axis knows unit results are the corroborating evidence.

### For features without testable pure functions:

1. Create schema validation tests — does the output match the expected JSON structure?
2. Create smoke tests — does the script/endpoint return a valid response?
3. If no tests are possible, note "eval generation skipped — no testable surface" and proceed

### Key principle:

Evals must be created BEFORE running them. This is test-driven: define what
"correct" looks like first, then verify the implementation matches.

**State write**: write `stage-outputs/generate-evals.json` with
`data.evals_created[]` and `data.skipped_reason` (or `null`). Status is
`pass` even when evals are skipped (no testable surface) — record the
reason in `summary` and `data.skipped_reason`.

