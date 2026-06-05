# Autonomous discovery — Claude as a scheduled worker

Reference pattern. **Not shipped by `setup.sh`** — this is infrastructure you
opt into deliberately, not a skill that drops into a repo. It describes how to
run `/data-source-pattern`-style discovery skills unattended on a schedule by
driving the headless `claude` CLI from a watcher daemon. Generalized from a
production deployment (the "teacup" wellness app).

## When to use this

Use it when data must refresh **on a schedule with no human present** — nightly
deal scans, hourly event feeds, daily catalog syncs.

**Don't** reach for it for occasional or on-demand refresh. If a human kicks off
the discovery a few times a week, just invoke the skill in a normal Claude
session. The watcher is always-on infrastructure with real operational cost (a
host that never sleeps, auth upkeep, log rotation, failure alerting). Only pay
that cost when the cadence genuinely has to be unattended.

## Architecture

```
producer            (UI button, cron, NL intent)
   │  enqueue
   ▼
job queue table     (e.g. agent_jobs: id, job_type, status, params, …)
   │  poll every N seconds
   ▼
watcher daemon      (long-running; systemd / launchd / container)
   │  for each claimed job:
   ▼
claude --print --allowed-tools "…" "<prompt from template>"
   │  the prompt invokes the discovery skill
   ▼
skill runs: load context → WebSearch/Playwright → dedup → upsert to DB
   │
   ▼
watcher marks job done/failed, writes a per-job log
```

## The pieces

1. **Job queue table** — minimum columns: `id`, `job_type`, `status`
   (`queued` / `running` / `done` / `failed`), `params` (JSON), `created_at`,
   `claimed_at`, `finished_at`, `result`/`error`. Any database works.

2. **Watcher daemon** — a small script (Python, Node, whatever) that:
   - polls the queue for `status = 'queued'` rows it owns,
   - claims a row atomically (update to `running`),
   - builds a prompt from a per-job-type template,
   - shells out to the headless `claude` CLI with a **scoped** `--allowed-tools`
     list and a timeout,
   - captures stdout/stderr to a per-job log,
   - marks the row `done` or `failed`.

3. **Per-job-type config** — a small registry mapping
   `job_type → { skill, allowed_tools, prompt_template }`. Keeps the watcher
   generic; adding a discovery type is a config entry, not new daemon code.

4. **Run host** — something always-on: a systemd *user* service, a launchd
   agent, a small VM, or a container with `restart: always`. Add a watchdog
   that restarts the watcher if it dies.

## Headless CLI invocation

```bash
claude --print \
  --allowed-tools "Bash,Read,Write,Edit,Glob,Grep,WebSearch,WebFetch" \
  "Run /<discovery-skill> for <params>. Load context from the DB, run the
   full discovery workflow, then report a summary."
```

- `--print` runs non-interactively and exits — suitable for a daemon.
- Scope `--allowed-tools` to the minimum the skill needs. A scheduled worker
  with no human in the loop should not carry broad tool access.
- Always set a timeout in the watcher so a wedged run can't block the queue.
- One-time: the CLI must be authenticated on the host (`claude` login once; the
  session persists across restarts).

## WebSearch vs Playwright under automation

- WebSearch/WebFetch jobs run cleanly headless — nothing extra needed.
- Playwright jobs need a **saved browser session** on the host (see the
  session-cookie pattern in `/data-source-pattern`). The unattended run loads
  the saved state; when it's expired the job should **fail loudly and tell a
  human to refresh the session** — never auto-login.

## Job ownership (multiple workers)

If both a backend worker and a host watcher can see the same queue, give each a
clear ownership rule (by `job_type`) so they don't double-process. A single env
flag the watcher checks (e.g. `SKIP_BACKEND_JOBS=1`) is enough to draw the line.

## Security notes

- Treat saved sessions and any credentials as secrets — gitignore them. The
  toolkit's secret scan is warn-only and won't block a commit that includes one,
  so the gitignore is your real guard.
- Scope `--allowed-tools` tightly: a headless agent with `Bash` can do anything
  the host user can.
- Log per-job output to a rotating location and scrub tokens from logs.

## Relationship to the toolkit

- `/data-source-pattern` (shipped skill) — how to author the discovery skill the
  watcher invokes. This doc is the deployment layer around it.
- This pattern is intentionally **not** a skill. A systemd daemon polling a
  database is a domain-specific deployment, not a portable workflow primitive —
  the same reason the AppSec Hunter suite was kept out of the lean toolkit.
