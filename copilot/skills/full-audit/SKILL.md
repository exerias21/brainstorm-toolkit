---
name: full-audit
description: >
  End-to-end AppSec audit orchestrator. Runs /threat-model first, then runs
  each hunter (authz, ssrf, deser, xss-dom, auth-state, mass-assign,
  file-upload, secrets, crypto) sequentially, dedupes and ranks the
  surviving findings, and emits a single exploitability×blast-radius–
  ranked report. Use when the user says /full-audit, "run a full security
  review", or before a release that needs a security sign-off.
argument-hint: "[path]   # default: whole repo"
metadata:
  brainstorm-toolkit-applies-to: copilot
---

# /full-audit — orchestrator for the AppSec Hunter suite (Copilot variant)

Same contract as the Claude version: produces `plans/audit-<short-sha>.md`
with ranked findings and a suggested-next-step block. The difference is
the hunter phase runs **sequentially** rather than parallel — Copilot's
agent mode doesn't yet support spawning parallel sub-agents.

When Copilot adds parallel-subagent support, this overlay can be
removed and the canonical skill will work on both tools.

## Scope and rules

- **Authorized review of owned source only.** Confirm scope before
  running.
- **Read-only**. The only files written are under `plans/`. No code
  edits. No live probing — that's `/repro`.
- **Confidence floor**: every hunter drops findings <8. The orchestrator
  re-applies the floor after dedupe.
- **Secrets in history**: if a hunter surfaces a committed secret,
  prompt the user to **rotate first**, then file the finding.

## Args

- **`[path]`** (optional) — restrict the run to a subtree. Propagated
  to `/threat-model` and each hunter.

## Procedure

### Stage 1 — Threat model

Invoke `/threat-model [path]`. Read the resulting
`plans/threat-model-<slug>.md` "Top-N risky flows" and "Downstream
sinks" sections — these prioritize each hunter's sweep.

### Stage 2 — Hunters (sequential)

Run each `/hunt <class> [path]` invocation in order:

1. `/hunt secrets` — fastest, runs first so secret-in-history rotation
   warnings appear early.
2. `/hunt authz`
3. `/hunt ssrf`
4. `/hunt deser`
5. `/hunt xss-dom`
6. `/hunt auth-state`
7. `/hunt mass-assign`
8. `/hunt file-upload`
9. `/hunt crypto`

Each hunter writes `plans/findings/<class>-<sha>.md`. The orchestrator
records the per-class counts as it goes.

If a hunter fails, record `<class>: error — <reason>` and continue.

### Stage 3 — Dedupe

Same `(file, line_range, category)` dedupe as the Claude variant. Keep
the higher-confidence entry; record cross-class corroboration.

### Stage 4 — Rank

Score by `exploitability × blast_radius`:

- Exploitability (0–10): anon = 10, authed = 8, role-guarded
  bypassable = 6, internal-only = 3.
- Blast radius (0–10): RCE/exfil = 10, ATO = 8, cross-tenant read = 7,
  self-only write = 4, defense-in-depth = 2.

Re-apply confidence floor (<8 → suppression list).

### Stage 5 — Write the audit report

Write `plans/audit-<short-sha>.md` using
`templates/audit-report.template.md`. Include executive summary,
ranked findings (rendered from `templates/finding.template.md`),
suppressed-FP list, and suggested next actions.

Print one-line summary to chat:
`Audit complete: plans/audit-<sha>.md — <H> high · <M> medium · <FP> suppressed.`

## Compose with other skills

- `/repro <finding-id>` — sandboxed PoC for the top finding.
- `/codify <finding-id>` — Semgrep + CodeQL rule for fleet-wide sweep.
- `/repo-health` — dep CVEs + secret scan; complementary.

## When this skill triggers

- User types `/full-audit`
- User says "run a full security review", "audit this end-to-end",
  "pre-release security pass"

## When NOT to use

- Mid-development on an unstable branch — wait for the diff to settle.
- For dep CVEs only — `/repo-health` is faster.
- For one class — `/hunt <class>` is focused.
