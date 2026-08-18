---
name: data-source-pattern
description: >
  Pattern guide for ingesting external data (web scrapes, third-party APIs,
  file imports, user-generated content) into a project's database. Covers the
  three ingestion patterns (discovery pipeline, seed script, direct API), plus
  how to author a per-source web-discovery skill: WebSearch vs headless
  browser, the session-cookie pattern for authenticated sites, source trust
  tiers, and dedup-upsert. Use when adding a new scraper, import script, feed
  poller, or automated data-collection job; when wiring a third-party API or a
  vendor export into local storage; or when the user asks "how do I scrape X into
  the DB?", "how should I import this data?", "how do I pull from <vendor/API>
  on a schedule?", or "where should this ingest code live?".
metadata:
   brainstorm-toolkit-applies-to: claude copilot codex
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

### Fetch method — WebSearch/WebFetch or a headless browser?

Default to **WebSearch + WebFetch**: public pages, search engines, RSS, JSON
APIs. No browser, runs fully unattended, cheapest. This covers most sources.

Reach for a **headless browser** (Playwright MCP, or a Playwright/Puppeteer
script) only when the source *requires* it:
- content behind a login,
- data rendered client-side by JS that `WebFetch` can't see,
- pages needing interaction (click, scroll-to-load) before the data appears.

Prefer extracting via `page.evaluate(() => …)` returning structured data over
brittle deep CSS selectors — selectors rot on every site redesign.

### Authenticated sources — the session-cookie pattern

For sites behind a login, **don't script the login flow** — it's fragile, trips
bot detection, and leaks credentials into logs. Instead:

1. **One-time, interactive:** a human logs in once in a visible browser; save
   the storage state (cookies + localStorage) to a gitignored file such as
   `scripts/.<source>-session.json`.
2. **Unattended runs:** load that saved state into the browser context and go
   straight to the data URL.
3. **Expiry:** when the saved session is missing or rejected, **stop and ask the
   user to re-run the one-time login** — never auto-login with stored secrets.

Session files are live credentials — gitignore them. (The toolkit's secret scan
is warn-only and won't block a commit that includes one.)

### Source trust tiers

Scraping pulls in junk unless you rank sources. Bake a tier list into the skill
so every run applies it the same way:

- **Prefer** authoritative sources: official `.gov`/`.edu`, the data owner's own
  site, first-party APIs, well-known org domains.
- **Include with verification:** established orgs and businesses with a
  verifiable real-world identity.
- **Block** low-signal sources: review aggregators, social feeds, content farms,
  SEO-spam blogs, anything requiring login to view. They inflate noise and
  dedup cost.

### Authoring a per-source discovery skill

A discovery skill is a thin, repeatable shape — **one skill per source type**:

1. **Load context** — read what parameterizes the search (location, user prefs,
   categories) from the DB/config. Stop early with a clear message if a required
   input is missing.
2. **Search phases** — grouped WebSearch queries (or browser navigations) per
   source category, templated with the loaded context.
3. **Apply trust tiers** — drop blocked sources, keep the ranked ones.
4. **Compile + dedup** — normalize each hit into a record; dedup by a stable key
   (`title`+`location`, or `source`+`external_id`). Keep the richer duplicate.
5. **Upsert** — `INSERT … ON CONFLICT DO UPDATE/NOTHING` into the target table;
   store the raw payload alongside the extracted columns.
6. **Report** — counts (found / inserted / updated / skipped), a grouped
   summary, and gaps where nothing was found.

Keep DB specifics (driver, connection, table names) out of the skill prose and
in the project's existing helpers/conventions. The skill describes the *shape*;
the project supplies the *wiring*.

### Going autonomous (optional)

To run discovery on a schedule with no human present, a watcher daemon can drive
the headless `claude` CLI against a job queue — "Claude as a cron worker." This
is opt-in infrastructure (needs an always-on host); for occasional refresh, just
run the skill by hand. See `docs/AUTONOMOUS-DISCOVERY.md` in the brainstorm-toolkit
repo for the full watcher pattern, headless-CLI invocation, and security notes.

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
