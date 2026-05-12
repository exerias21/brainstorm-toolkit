---
name: hunt
description: >
  Vulnerability-class deep dive on the codebase. Pick one class — authz, ssrf,
  deser, xss-dom, auth-state, mass-assign, file-upload, secrets, crypto — and
  this skill sweeps every relevant code path, surfaces ranked findings, and
  filters false positives. Use when the user says /hunt <class>, "look for
  <class> vulns", "check for SSRF / IDOR / mass assignment", "any
  hardcoded secrets", "review the auth flow for bugs", or after
  /threat-model identifies a risky flow that needs a focused sweep.
argument-hint: "<class> [path]   # class in {authz, ssrf, deser, xss-dom, auth-state, mass-assign, file-upload, secrets, crypto}"
metadata:
  brainstorm-toolkit-applies-to: claude copilot
---

# /hunt — single-class vulnerability deep dive

Each invocation focuses one bug class. The per-class playbook tells you
*where* to grep, *what* patterns count as the vulnerable shape, *what*
counts as the safe shape, and *which* framework guarantees can suppress
a finding to false-positive. Read the playbook for the requested class
before grepping.

## Scope and rules

- **Authorized review of owned source only.** Before any sweep, confirm
  the repo is owned by the user or covered by a rules-of-engagement
  document the user has produced. If neither is true — for example, the
  user dropped an unfamiliar GitHub URL or a customer's source tree
  with no ROE in the working directory — **stop and ask** before
  proceeding. Do not run the sweep speculatively.
- **Read-only tools**: `Read`, `Glob`, `Grep`, scoped `git`. No `Write`
  except for the findings markdown under `plans/findings/`.
- **Source-only sweep**. Confirming exploitability against a running
  service is `/repro`'s job, not this one.
- **Confidence floor**: drop any finding with confidence < 8 before
  writing the report. Findings below the floor go into the "False
  positives suppressed" section with the suppression reason.

## Args

- **`<class>`** (required) — one of:
  - `authz` — broken access control, IDOR, missing role checks
  - `ssrf` — server-side request forgery, URL construction from input
  - `deser` — unsafe deserialization of attacker-controlled data
  - `xss-dom` — DOM-based XSS, unsafe sinks in client JS
  - `auth-state` — session, token, MFA, password-reset, account-takeover
  - `mass-assign` — over-posting / mass assignment in ORMs and binders
  - `file-upload` — upload validation, MIME bypass, path traversal,
    polyglot, content disposition
  - `secrets` — hardcoded credentials, API keys, private keys, JWT secrets
  - `crypto` — weak primitives, hardcoded IVs, custom crypto, weak RNG

- **`[path]`** (optional) — restrict the sweep to a subtree.

## Procedure

### 1. Load the playbook

Read `playbooks/<class>.md` from this skill's directory. The "skill's
directory" resolves to `.claude/skills/hunt/playbooks/<class>.md` on
Claude Code and `.github/skills/hunt/playbooks/<class>.md` on Copilot.
If your tool surfaces a different install path, try both before giving
up. The playbook contains the sweep patterns, the safe-shape allowlist,
the framework suppression rules, and the recommended fix vocabulary
for that class.

If no playbook exists for the requested class, print the list of
supported classes and exit. Don't fabricate a class on the fly.

### 2. Load threat model (if present)

If `plans/threat-model-*.md` exists, read the most recent one and use
its "Top-N risky flows" section to prioritize which entry points to
trace into the sinks the playbook identifies. The threat model is
optional — without it, sweep the whole subtree using the playbook's
default scope.

### 3. Execute the playbook

Follow the per-class playbook step by step. Most playbooks have this
shape:

1. Grep for the dangerous primitive (the sink).
2. For each hit, trace backwards to find the input source. Stop tracing
   when you reach a trust boundary (validated input, allowlist, constant).
3. Classify each unsafe source→sink pair as a candidate finding with a
   confidence score.
4. Walk the suppression list — if the playbook says "framework auto-escapes
   here," drop the finding to false-positive.

### 4. Rank surviving findings

Sort by `exploitability × blast_radius`. Anonymous-user-reachable, write-
or-exec sinks rank highest. Authenticated-only, read-only sinks rank
lower. Internal-mesh-only sinks rank lowest.

### 5. Write the report

Append each finding (rendered from `templates/finding.template.md` at
the repo root) into `plans/findings/<class>-<short-sha>.md`. Create the
`plans/findings/` directory if it doesn't exist. The report header lists
the class, sweep date, path scope, and counts:

```
# /hunt <class> — <repo> @ <short-sha>

Scope: <path or "whole repo">
Date: <YYYY-MM-DD>
Surviving findings: <H high · M medium>
Suppressed (FP): <count>
```

Print a one-line summary to chat:
`Hunt(<class>): <H> high · <M> medium findings in plans/findings/<class>-<sha>.md. Suggested next: /repro <top-finding-id> or /codify <top-finding-id>.`

### 6. Compose with /full-audit

When invoked by `/full-audit`, this skill returns the same report path
plus a small structured summary (counts, top-3 finding IDs) so the
orchestrator can dedupe across hunters. The orchestrator owns the final
ranked audit report; individual hunter reports stay under
`plans/findings/` as the per-class audit trail.

## Why one skill, nine playbooks

Each bug class is structurally distinct — SSRF and crypto need different
sink lists, different suppressions, different fix vocabularies. But
they share the *workflow*: load playbook → trace source→sink → suppress
→ rank → report. One skill captures the workflow; the playbooks capture
the per-class knowledge that would otherwise duplicate across nine
nearly-identical SKILL.md files.

## When this skill triggers

- User types `/hunt <class>`
- User says "look for <class> vulns", "any IDORs in this", "is the file
  upload safe", "any hardcoded secrets", "check for mass assignment"
- Post-threat-model, when a risky flow needs focused coverage
- Inside `/full-audit`'s fan-out — one hunter per class in parallel

## When NOT to use

- To produce a working exploit → `/repro`
- To convert a finding into a fleet-wide rule → `/codify`
- For a sweep that spans all classes at once → `/full-audit` (it
  orchestrates this skill across all 9 classes)
