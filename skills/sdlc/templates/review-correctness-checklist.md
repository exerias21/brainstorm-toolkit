# Correctness review checklist — Stage 5.7 `correctness` lens

Distilled bug-classes for the Review→Fix stage's `correctness` lens (see `skills/sdlc/SKILL.md`
Stage 5.7). Also a `GOTCHAS.md` candidate for any DB-backed Python + query-cache-frontend repo.

```
Discovery/backend review checklist:
1. WHERE touching a nullable col inside NOT/AND — is NULL handled explicitly?
   (`NOT (x IS NULL AND col ~* rx)` drops rows when col is also NULL → add `col IS NOT NULL AND`)
2. `x or DEFAULT` / `if x:` on config — should [] / 0 / "" mean "user cleared it", not "unset"?
3. URL/text decoding — decoded exactly once? (parse_qs already unquotes; a second unquote corrupts)
4. Restart / self-exit / lifecycle change — what in-memory state resets, and who pays (external APIs)?
5. New env var or default — identical value in code, .env.example, compose, AND GET-defaults?
   Imported from ONE source, not re-typed?
6. json.loads on stored/user data — wrapped in try/except with a sane fallback?
7. Keyword heuristics — does an incidental match misclassify? Require explicit signals.
8. Frontend mutation onSuccess — invalidates EVERY query key the changed setting feeds?
9. Early-return / short-circuit branches — do they skip a warning/log/metric that other
   paths emit? (A silent-failure path that returns early before its sibling paths' logging
   call is a defect class of its own.)
```

**Cheap grep/lint (no model needed):** #3 (`unquote` near `parse_qs`), #5 (diff env-var names
across code/`.env.example`/compose), #6 (`json.loads` outside a `try`), #2 (`or _DEFAULT` on a
settings read). **Needs the LLM reviewer:** #1 (nullability needs schema knowledge), #4
(cross-subsystem side-effects), #7 (semantics), #8 (the query-key dependency graph), #9
(control-flow comparison across sibling branches). A good split: run the grep-able items as a
pre-review lint gate before spending reviewer-model tokens on the ones needing judgment.
