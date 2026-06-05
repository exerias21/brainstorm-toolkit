# Stage 2c — Converge agent prompt

The orchestrator (not a subagent) runs this after every lane in 2b has
completed. Decomposition deliberately set global consistency aside; converge
rebuilds it. **Converge is the tax for decomposing — it must stay cheaper than
the single-agent context it replaced**, which is exactly why the gate only fans
out when lanes are genuinely disjoint.

Substitute `{feature_name}`, `{lanes}` (the lane names + their contracts from
`decompose.json`), and `{merged_files}` (the union of all lanes'
`files_changed[].path`) before running.

---

## Orchestrator step: converge

**prompt** (run by the orchestrator over the converged tree):

```
All lanes for {feature_name} have implemented their files in a single shared
working tree (sequential dispatch — no conflicts). Rebuild global consistency:

LANES + CONTRACTS:
{lanes}

CHANGED FILES (union across lanes):
{merged_files}

DO, in order:
1. Resolve cross-lane integration gaps: wire up imports, call sites, and shared
   types so the lanes actually connect. A frontend lane that coded against the
   backend contract needs its real import/path; a backend lane that uses the
   data lane's model needs the import. Fix these here.
2. Run a fast import / symbol-collision sweep over the union of changed files:
   - every imported symbol resolves to a real definition,
   - no symbol is defined by two lanes in a colliding way.
   Use the project's own check where one exists (typecheck, linter, a quick
   import smoke); otherwise grep the imports against the definitions.
3. If a lane's output CONTRADICTS the contract it was given, fix the integration
   directly when it's a small seam mismatch; if it's a real logic gap, leave it
   for the Stage 4 fix loop rather than rewriting the lane here.

OUTPUT a JSON object EXACTLY in this shape (this becomes converge.json data):
{
  "merged_files": ["..."],
  "integration_fixes": [{ "file": "...", "fix": "..." }],
  "import_check": { "status": "pass", "unresolved": [] },
  "symbol_collisions": []
}

Set import_check.status to "fail" with the offending entries in `unresolved`
if anything does not resolve and you could not fix it here — that feeds the
Stage 4 fix loop. Do NOT expand scope beyond reconciling the lanes' edits.
```
