---
name: logging-conventions
description: >
  Enforces structured logging conventions when writing or modifying backend Python or frontend
  TypeScript code. ALWAYS consult this skill when: (1) writing or modifying any backend service,
  API route, or background job, (2) adding try/except or catch blocks, (3) creating new API
  endpoints, (4) working on LLM integration code, (5) modifying error handling or fallback logic,
  (6) touching any file that imports logging or structlog, (7) writing frontend code that calls
  the backend API. This ensures every code change follows the project's structured logging contract
  so the container-log-audit skill can reliably detect and classify errors.
---

# Logging Conventions

These conventions exist so Docker container logs are machine-readable. The container-log-audit
skill parses these logs after every test run — if your code doesn't follow these patterns,
errors become invisible to automation.

## Backend: How to Log

All 83+ backend files already use `logging.getLogger(__name__)`. structlog wraps these
automatically via `foreign_pre_chain` — no special import needed for existing files.

```python
# Option A: stdlib (works everywhere, already in most files)
import logging
logger = logging.getLogger(__name__)

# Option B: structlog (use when you want bound context)
import structlog
logger = structlog.stdlib.get_logger()
```

Both produce structured JSON output. Choose whichever the file already uses.

### NEVER use print() for logging

`print()` bypasses the logging framework entirely — structlog cannot capture it, the audit
script cannot parse it, and it produces unstructured noise in Docker logs.

```python
# WRONG — invisible to logging framework
print(f"[DayPlan] UPSERT FAILED: {exc}")

# RIGHT — structured, parseable, includes context
logger.error("day_plan_upsert_failed", error=str(exc), category="DB")
```

### Log Levels — Use the Right One

| Level | When to use | NOT for |
|-------|-------------|---------|
| `debug` | Internal diagnostics, verbose steps | Fallback activation, dropped writes, anything the audit skill needs |
| `info` | Request lifecycle, startup, normal transitions | Hiding errors at low severity |
| `warning` | Degraded behavior, fallback used, partial response | Expected operational noise |
| `error` | Unhandled exceptions, 5xx, rollback failures | Handled errors with clean fallback |

The audit skill ignores `debug` and `info` (except for HTTP status codes in access logs).
If you log a real failure at `debug`, it becomes invisible.

### Error and Warning Events MUST Include

```python
# For warnings (degraded but operational):
logger.warning("llm_call_failed",
    category="LLM",                    # Required: DB, LLM, AUTH, API, etc.
    error_code="LLM_PROVIDER_ERROR",   # Required: from error_codes.py
    error=str(e),                      # What went wrong
    fallback_used=True,                # Did we degrade gracefully?
)

# For errors (broken functionality):
logger.error("unhandled_exception",
    category="API",
    error_code="UNHANDLED_EXCEPTION",
    route=request.url.path,
    exception_type=type(exc).__name__,
    error=str(exc),
)
```

### Exception Handling Rules

**Every `except` block must either re-raise or log.**

```python
# WRONG — silent failure, zero visibility
try:
    result = await session.execute(query)
except Exception:
    pass

# WRONG — logged at debug, invisible to audit skill
try:
    result = await session.execute(query)
except Exception as e:
    logger.debug("query failed: %s", e)

# RIGHT — logged at appropriate level with context
try:
    result = await session.execute(query)
except Exception as e:
    logger.warning("query_failed",
        category="DB",
        error_code="DB_TRANSACTION_ABORTED",
        error=str(e),
        operation="fetch_user_checkins",
    )
    await session.rollback()  # Prevent transaction cascade (see gotcha)
    result = default_value    # Explicit fallback
```

**Fallback behavior MUST be logged at `warning`:**

```python
# When an LLM call fails and you use a fallback:
try:
    response = await llm_client.generate(prompt)
except LLMUnavailableError as e:
    logger.warning("llm_fallback_activated",
        category="LLM",
        error_code="LLM_PROVIDER_ERROR",
        error=str(e),
        fallback_used=True,
    )
    response = deterministic_fallback()
```

### Available Error Codes

Reference `your project's error_codes module` for the current set. Common ones:

| Code | When |
|------|------|
| `DB_TRANSACTION_ABORTED` | Query failed, transaction rolled back |
| `DB_ROLLBACK_FAILED` | Rollback itself failed (critical) |
| `DB_CONNECTION_FAILED` | Cannot reach PostgreSQL |
| `DB_MISSING_GREENLET` | Async/sync session mismatch |
| `LLM_CONTEXT_OVERFLOW` | Prompt too large for model |
| `LLM_TIMEOUT` | LLM didn't respond in time |
| `LLM_PROVIDER_ERROR` | LLM returned error status |
| `LLM_PARSE_FAILED` | LLM response wasn't valid JSON |
| `API_VALIDATION_ERROR` | Request failed validation |
| `BACKGROUND_JOB_FAILED` | Job worker unhandled exception |

If none fit, use a descriptive `error_code` string following the pattern `DOMAIN_FAILURE_MODE`.

### Available Categories

`DB`, `LLM`, `AUTH`, `API`, `EXTERNAL_API`, `BACKGROUND_JOB`, `VALIDATION`, `DOCKER`

## Frontend: How to Log (Current State)

The frontend currently has no structured logging library. Until Pino is added:

1. Use `console.error()` for genuine errors (these appear in browser DevTools)
2. Include the operation name and error in the message
3. Do NOT use `console.log()` for error conditions

```typescript
// WRONG
console.log('failed')

// RIGHT
console.error('[MorningPulse] Day plan generation failed:', error)
```

When Pino is added, these will be migrated to structured calls.

## When Creating New API Endpoints

1. Use `logging.getLogger(__name__)` at the top of the file
2. Add a global exception handler if the endpoint has complex error paths
3. Log at `warning` for handled errors, `error` for unhandled
4. Include `category` and `error_code` in error/warning logs
5. Never catch `Exception` without logging — see exception handling rules above

## Cross-Reference

- **Gotchas**: Check `.claude/skills/gotcha/GOTCHAS.md` for logging pitfalls (Logging/Observability category)
- **Error codes**: See `your project's error_codes module` for the full current set
- **Audit patterns**: See LOGGING.md Error Pattern Catalog for what the audit skill detects
- **Full plan**: See LOGGING.md for the phased implementation guide
