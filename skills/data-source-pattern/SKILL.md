---
name: data-source-pattern
description: >
  Pattern guide for ingesting external data (web scrapes, third-party APIs,
  file imports, user-generated content) into a project's database. Use when
  adding a new scraper, import script, or automated data-collection job.
  Defines the standard shape: discovery pipeline, seed scripts, and direct
  API ingestion — three patterns, one per situation.
applies-to: [claude, copilot]
---

# Data Source Pattern

When content/data needs to enter the database from an external source, pick one
of three patterns below. Each has a specific fit — don't mix them.

## Rule: data lives in the database

Content that changes, that users filter/search, or that multiple features depend
on belongs in the database — not hardcoded into the frontend. The frontend queries
via an API; the database is the source of truth.

---

## Pattern 1 — Discovery Pipeline (automated, scheduled)

Use when: data changes over time and needs periodic refresh. Examples: daily
deal scanning, event calendars, news feeds, product-catalog syncs.

**Shape:**

```
Scheduler (cron / watcher) → queue a job → worker script → fetch/parse →
upsert into DB → emit metric/notification
```

**Required pieces:**

1. A **job type** registered in a central registry (e.g., a `VALID_JOB_TYPES`
   list in your worker service).
2. A **worker script** (`scripts/<source>-discovery.py` or similar) that:
   - Accepts a job record as input
   - Fetches the external data (WebSearch, WebFetch, scraping, API call)
   - Deduplicates against existing DB rows
   - Upserts or inserts new rows
   - Logs structured events for observability
3. A **trigger** — at minimum, a cron schedule. Optionally: a UI button, a chat/NL
   intent, an API endpoint.
4. A **DB table** with at minimum: `id`, `source`, `external_id`, `payload`,
   `discovered_at`, `deduped_hash` (or similar), and any domain-specific columns.

**Gotchas:**
- Always dedupe before insert — scrapers re-run and re-discover the same items.
- Store the raw payload (`JSONB`) in addition to extracted columns, so you can
  re-parse later without re-scraping.
- Handle the external source being unavailable — never crash the worker.

---

## Pattern 2 — Seed Script (one-time bulk load)

Use when: you have a static dataset that needs to enter the DB once, not on a
schedule. Examples: curated reference data, one-time partner imports, demo content.

**Shape:**

```
python3 scripts/seed_<name>.py [--force] [--dry-run]
```

**Required pieces:**

1. A Python script in `scripts/` that:
   - Reads a local file (JSON, CSV) or embeds data inline
   - Connects to the DB
   - Uses `INSERT ... ON CONFLICT DO NOTHING` or equivalent idempotency
   - Reports counts (inserted/skipped/errored) at the end
2. A `--dry-run` flag that prints what would change without touching the DB.
3. A `--force` flag (optional) to re-insert even if rows exist.

**Gotchas:**
- Seeds should be idempotent — safe to re-run anytime.
- Don't bake credentials into the script — read from env vars or config.

---

## Pattern 3 — Direct API Ingestion (user or model generated)

Use when: data comes from user actions or an LLM response, synchronously.
Examples: user adds a calendar event, LLM generates a plan, chat message, form
submission.

**Shape:**

```
Frontend/model → POST /api/<module>/<endpoint> → router → service → DB row
```

**Required pieces:**

1. A request schema (Pydantic, Zod, etc.) validating the payload.
2. A service function that validates domain rules and inserts.
3. An endpoint that returns the created resource (or an ID).

**Gotchas:**
- Validate at the API boundary — don't trust client-side sanitization.
- If an LLM is producing the payload, parse defensively (tolerate extra keys,
  fall back to a sensible default if parsing fails).

---

## Which pattern fits?

| Scenario | Pattern |
|---|---|
| Scraping a website every day for deals | 1 (discovery) |
| Loading a curated starter dataset | 2 (seed) |
| User creating a row via the UI | 3 (direct) |
| LLM-generated content from a chat flow | 3 (direct) |
| Periodic refresh from a public API | 1 (discovery) |
| One-time migration of legacy data | 2 (seed) |

## Before writing a new data source

Read the project's existing examples:
- Any file matching `scripts/*-discovery.py`, `scripts/seed_*.py`, or
  `scripts/scrape-*.py` is a good template.
- Check `CLAUDE.md` for project-specific conventions (worker framework,
  DB connection helper, logging conventions).
