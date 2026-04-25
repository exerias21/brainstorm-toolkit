---
name: post-deploy-verify
description: >
  Post-deployment BRD-and-PBI-vs-delivered verification gate. Reads
  requirements/BRD-<id>.md and the linked pbis/*.md files, then queries the
  *deployed* environment for evidence each requirement is actually delivered.
  Produces a per-requirement red/yellow/green matrix readable by stakeholders.
  Use as the closing bracket of the pipeline after deploy — `/flowsim` answers
  "code matches plan", this answers "deployed system matches BRD".
argument-hint: "<brd-or-pbi-ref> [--env staging|prod|<name>] [--config <path>]"
metadata:
  brainstorm-toolkit-applies-to: claude copilot
---

# Post-Deploy BRD/PBI Verification

## Status: stub

This skill defines a contract that depends on Phase 2 of the broader pipeline
plan (BRD intake + PBI decomposition — see `BRAINSTORM-PIPELINE.md`). The
artifacts the skill consumes (`requirements/BRD-<id>.md`, `pbis/PBI-*.md` with
stable IDs and acceptance criteria) do not exist in most repos yet.

When those artifacts ship, this skill executes. Until then, invoking it
returns a clear "missing prerequisites" report listing what to author first.

## Framing

`/flowsim` and `/sdlc` Stage 5.5 answer **code-vs-plan**: do the file:line
anchors match what the plan claimed? They run pre-merge.

This skill answers **deployed-vs-BRD**: does the running system actually
deliver what the business asked for? It runs post-deploy. Different question,
different evidence: requests against a live URL, queries against a deployed
DB, checks of a deployed UI — not file reads.

The two are complementary. A passing `/flowsim` plus a passing
`/post-deploy-verify` is the strongest signal that "we shipped the right
thing." A passing `/flowsim` with a failing `/post-deploy-verify` typically
means: code matches plan, but the *plan* drifted from the BRD.

## When to use

- After a deploy completes (manual or automated).
- Before a stakeholder sign-off meeting where you need a coverage matrix.
- On a recurring schedule (weekly?) to catch drift between BRD and prod state.
- As a gate in a CI/CD pipeline: block promotion to prod if the staging
  verification matrix has any RED requirements.

## Inputs

- `brd-or-pbi-ref` (required): one of
  - `BRD-<id>` — verify every requirement in that BRD.
  - `PBI-<id>` — verify only the requirements linked from that PBI.
  - `REQ-<id>` — verify a single requirement.
- `--env` (optional): which deployed environment to probe. Default: read
  `pipeline.default_env` from `.claude/project.json`, else `staging`.
- `--config <path>` (optional): override the env config path. Default:
  `.claude/envs/<env>.json` with shape:
  ```json
  {
    "name": "staging",
    "base_url": "https://staging.example.com",
    "db": { "connection": "...", "secret_env": "STAGING_DB_PASSWORD" },
    "auth": { "test_user_email": "...", "secret_env": "STAGING_TEST_PASSWORD" }
  }
  ```

## Prerequisites

- `requirements/BRD-<id>.md` exists with stable `REQ-<NNN>` IDs and at least
  one acceptance criterion per requirement.
- `pbis/PBI-<id>.md` exists with `brd_refs: [REQ-NNN, ...]` frontmatter,
  linking each PBI to the requirement(s) it claims to satisfy.
- The `--env` config file exists with `base_url` at minimum.

If any prerequisite is missing, exit cleanly with a checklist of what to
author. Do NOT guess at requirements — that defeats the purpose of the gate.

## Procedure

### Step 1 — Resolve target requirements

From `brd-or-pbi-ref`, build the list of `REQ-NNN` IDs to verify:
- `BRD-<id>` → every `REQ-NNN` in that BRD.
- `PBI-<id>` → the `brd_refs` list from that PBI's frontmatter.
- `REQ-<id>` → the single ID.

For each requirement, load:
- The acceptance criteria (from BRD).
- The PBI(s) claiming to satisfy it (from `pbis/`).
- The `delivery/PBI-<id>.json` manifest (from prior `/sdlc` runs, if Phase 2
  is wired) — lists files touched, evals added, PR URL.

### Step 2 — Per-requirement evidence collection

Each acceptance criterion gets one or more **probes**. The probe shape
depends on what the criterion claims:

| Criterion claim | Probe | Evidence |
|---|---|---|
| "User can do X via the UI" | Playwright MCP: navigate, snapshot, capture | screenshot + accessibility tree |
| "API endpoint returns Y" | `curl <base_url>/api/...` with auth | response body + status code |
| "DB has table/column Z" | `psql ... -c "\d <table>"` | DDL output |
| "Background job runs every N minutes" | check job runner status / log | last-run timestamp |
| "Email sent on event E" | check provider's send log via API | message ID + delivery status |
| "Metric M visible in dashboard D" | hit dashboard query API | data point exists |

Probes that need credentials: read from the env config's `secret_env` keys.
Never hardcode secrets in this file or in evidence output.

### Step 3 — Score per requirement

For each `REQ-NNN`:
- All probes pass → **GREEN**.
- All probes pass but evidence is weak (e.g., endpoint returns 200 but
  response body wasn't validated) → **YELLOW**, with a note.
- Any probe fails → **RED**, with the specific failure attached.
- Probe couldn't run (config missing, auth broke) → **GRAY**, "unverifiable".

### Step 4 — Output the matrix

Stakeholder-readable markdown:

```markdown
## Post-Deploy Verification — BRD-<id>

**Environment**: staging (https://staging.example.com)
**Verified at**: 2026-04-25T15:00:00Z
**PBIs covered**: PBI-12, PBI-14, PBI-21

| REQ | Title | Status | Probe | Evidence |
|---|---|---|---|---|
| REQ-001 | User can submit order | 🟢 GREEN | UI + API | screenshot, 200 OK |
| REQ-002 | Email confirmation sent | 🟡 YELLOW | provider API | sent, but bounce rate not checked |
| REQ-003 | Admin dashboard shows totals | 🔴 RED | dashboard query | endpoint returns 500 |
| REQ-004 | Orders persisted to DB | ⚫ GRAY | DB | could not connect (auth) |

### Failures (RED)
- **REQ-003**: GET /api/admin/orders/totals → 500 Internal Server Error.
  See logs for trace ID `abc123`. Likely needs the migration from PBI-21
  to be applied — verify migration ran in this env.

### Unverifiable (GRAY)
- **REQ-004**: DB credentials in `.claude/envs/staging.json` not loaded;
  set `STAGING_DB_PASSWORD` in your environment and re-run.
```

Also write a structured JSON sidecar at `delivery/post-deploy-<env>-<timestamp>.json`
for downstream tooling (CI gates, dashboards).

### Step 5 — Block-or-proceed signal

If invoked from a CI pipeline:
- Any RED → exit 1 (block promotion).
- Any GRAY → exit 2 (cannot determine; fix config and re-run).
- All GREEN/YELLOW → exit 0.

If invoked manually, just print the matrix and return.

## Companion: BRD → PBI vetting (forward-looking contract)

The BRD → PBI skill itself does not exist yet (Phase 2 of the broader plan
in `BRAINSTORM-PIPELINE.md`). When it ships, it MUST run a multi-agent vet
**by default** before the PBIs it produces are written to disk. Bad PBIs
poison the entire downstream pipeline (`/sdlc`, this skill, deploy
verification), so vetting is **not opt-in** here — unlike `/brainstorm`
where `--vet none` is a valid mode.

### Required vet agents (default-on)

Three agents per PBI batch, dispatched in parallel after the BRD is parsed
and PBIs are drafted but BEFORE they are persisted:

1. **Testability agent** (Haiku): each PBI must have at least one
   acceptance criterion that names a probe shape (UI / API / DB / job /
   email / metric — the same probes this skill runs at Step 2). A PBI
   whose ACs are all unmeasurable text (e.g., "feels intuitive") fails
   testability. **CRITICAL flag → PAUSE**: the BRD → PBI flow stops and
   asks the user to clarify the AC before continuing.

2. **Traceability agent** (Haiku): each PBI must declare `brd_refs:
   [REQ-NNN, ...]` in its frontmatter, and every cited `REQ-NNN` must
   resolve to a real requirement in the source BRD. Orphan PBI (no
   brd_refs) or dangling REQ → CRITICAL flag → PAUSE.

3. **Coverage agent** (Sonnet): for each `REQ-NNN` in the BRD, at least
   one PBI must list it in `brd_refs`. Uncovered REQ → CRITICAL flag →
   PAUSE.

### Why default-on (and `/brainstorm` is not)

`/brainstorm` produces a single plan that one developer will implement,
review, and merge. The blast radius of a bad plan is bounded.

A BRD → PBI run produces N PBIs that flow into `/sdlc` autonomously. A
single untestable or orphan PBI silently produces code with no link back
to the BRD requirement, which `/post-deploy-verify` then can't verify.
The cost of a bad PBI is multiplied across every downstream stage. Vetting
is the cheapest place to catch it.

### CRITICAL vs SOFT flags

A vet agent emits CRITICAL only when the issue blocks downstream
correctness:
- Untestable AC (testability)
- Orphan PBI or dangling REQ (traceability)
- Uncovered BRD requirement (coverage)

Lower-severity findings (vague language, missing edge-case ACs,
underspecified probe types) are SOFT flags — surfaced in the report but
do not pause the flow. The BRD → PBI orchestrator decides whether to
auto-revise or ask the user; it does NOT proceed silently.

## Rules

- **Never modify the deployed system from this skill.** Read-only probes only.
  Mutations belong to the deploy step, not verification.
- **Never embed secrets.** Every credential is read from env vars referenced
  by `secret_env` keys in the env config.
- **Don't guess at acceptance criteria.** If the BRD doesn't define a
  testable criterion, surface that as a SOFT warning ("REQ-NNN has no
  testable AC; cannot verify"). Don't invent a criterion.
- **Don't loop or retry on YELLOW/GRAY.** Report and exit. The user decides
  whether to author missing config or accept weak evidence.
- **Match the env to the audience.** Stakeholder reports come from
  `staging` or `prod`; never run a verification matrix against a developer's
  laptop.
