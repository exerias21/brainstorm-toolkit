---
name: full-audit
description: >
  End-to-end AppSec audit orchestrator. Runs /threat-model first, then fans
  out the full hunter set (authz, ssrf, deser, xss-dom, auth-state,
  mass-assign, file-upload, secrets, crypto) in parallel sub-agents,
  dedupes and ranks the surviving findings, and emits a single
  exploitability×blast-radius–ranked report. Use when the user says
  /full-audit, "run a full security review", "audit this codebase
  end-to-end", or before a release that needs a security sign-off.
argument-hint: "[path]   # default: whole repo"
metadata:
  brainstorm-toolkit-applies-to: claude
---

# /full-audit — orchestrator for the AppSec Hunter suite

Composes `/threat-model` + all nine `/hunt <class>` invocations into one
audit run. Outputs `plans/audit-<short-sha>.md`, a single ranked report
that downstream consumers (security tracker, PR comment, `/sdlc`
remediation plan) can read.

For a single-class deep dive use `/hunt <class>`. For just the
threat model, use `/threat-model`. This skill is the "do everything"
entry point.

## Scope and rules

- **Authorized review of owned source only.** Confirm scope before
  running. If the repo isn't owned by the user or there's no rules-of-
  engagement context, stop and ask.
- **Read-only**. The only files written are under `plans/`. No code
  edits. No live probing — that's `/repro`.
- **Confidence floor**: every hunter drops findings <8. The orchestrator
  re-applies the floor after dedupe in case two hunters disagree on
  confidence for the same site.
- **Secrets in history**: if a hunter surfaces a committed secret,
  prompt the user to **rotate first**, then file the finding. Do not
  proceed silently — a committed secret is already compromised the
  moment it hits a public remote.

## Args

- **`[path]`** (optional) — restrict the entire run to a subtree.
  Propagated to `/threat-model` and each hunter.

## Procedure

### Stage 1 — Threat model

Invoke `/threat-model [path]`. This produces
`plans/threat-model-<slug>.md`. Read the resulting file's "Top-N risky
flows" and "Downstream sinks" sections — these become the
prioritization hints handed to each hunter.

If `/threat-model` fails (e.g., empty repo, no recognized entry
points), continue to Stage 2 but warn the user and run hunters at
default scope.

### Stage 2 — Hunter fan-out (parallel)

Dispatch nine sub-agents in **one message, nine parallel tool calls**.
Each sub-agent runs `/hunt <class> [path]` for one class. Pass the
threat model path so each hunter can read the risky-flow list.

Each sub-agent returns:
- Path to its per-class report (`plans/findings/<class>-<sha>.md`).
- A small structured summary: `{ class, high_count, medium_count,
  top_finding_ids }`.

If a sub-agent fails (timeout, error), record it in the report as
`<class>: error — <reason>` and continue. A partial audit is more
useful than no audit.

### Stage 3 — Dedupe

The same `file:line` may surface from multiple hunters (e.g., an
upload endpoint can show up in `file-upload` and `authz`). Dedupe by
`(file, line_range, category)` — keep the higher-confidence entry,
note the cross-class corroboration in the merged finding's
"Discovered by" field.

### Stage 4 — Rank

Score each finding by `exploitability × blast_radius`:

- Exploitability (0–10):
  - Anonymous-reachable + no precondition = 10
  - Authed-reachable + no precondition = 8
  - Authed + role-guarded but bypassable = 6
  - Internal-only + requires VPN/cluster = 3

- Blast radius (0–10):
  - RCE / data exfil at scale = 10
  - Account takeover (single account) = 8
  - Cross-tenant data read = 7
  - Self-only data write = 4
  - Defense-in-depth gap, no direct impact = 2

Final score = exploitability × blast_radius. Order findings by score
descending. Re-apply confidence floor (<8 → suppression list).

### Stage 5 — Write the audit report

Write `plans/audit-<short-sha>.md` using
`templates/audit-report.template.md`. Include:
- Executive summary
- Findings — High, then Medium (each rendered from
  `templates/finding.template.md`)
- False positives suppressed (with reason)
- Suggested next actions: top-1 `/repro` candidate, top-3 `/codify`
  candidates, whether to open a `/sdlc` remediation plan.

Print a one-line summary to chat:
`Audit complete: plans/audit-<sha>.md — <H> high · <M> medium · <FP> suppressed. Suggested next: /repro <top-id>.`

### Stage 6 — Tracker handoff (optional)

If the user invoked with `--tracker <name>` (or `.claude/project.json`
declares a tracker integration), prompt the user before posting the
top High findings to the tracker. Findings touching shared
infrastructure (e.g., load balancer config, network policy, IAM,
secret manager) loop in platform owners immediately — print a note
listing those findings and recommend the user notify the owners
manually. No auto-pings to chat systems.

## Why fan out in parallel

Each hunter's per-class playbook is independent — none read another
hunter's report. Running them in parallel cuts wall time roughly 9×
on Claude Code. The orchestrator owns synchronization: it doesn't
read partial hunter output, only the final per-class report files
once all sub-agents return.

## Compose with other skills

- `/repro <finding-id>` — confirm the top finding's exploitability
  in a localhost sandbox.
- `/codify <finding-id>` — turn each surviving High into a Semgrep +
  CodeQL rule for fleet-wide sweep.
- `/sdlc` — open a remediation plan once findings are triaged.
- `/repo-health` — runs `gitleaks` + dep CVE counts; complementary to
  this audit, not a replacement. Run both before a release.

## When this skill triggers

- User types `/full-audit`
- User says "run a full security review", "audit this end-to-end",
  "pre-release security pass", "is this safe to ship"
- After a major refactor that touched auth, payments, file I/O, or
  outbound network calls

## When NOT to use

- Mid-development on an unstable branch — wait for the diff to settle.
  Use `/review-pr --security` if it exists, otherwise `/hunt <class>`
  on the changed paths.
- For dep-CVE counts only — `/repo-health` is faster.
- For a single specific class — `/hunt <class>` is the focused entry.
