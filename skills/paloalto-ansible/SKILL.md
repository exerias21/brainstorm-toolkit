---
name: paloalto-ansible
description: >
  Designs and generates Strata Cloud Manager (SCM) firewall automation: a
  custom Ansible module that calls the official SCM API directly (NOT the
  paloaltonetworks.panos collection and NOT the legacy SASE / Prisma API), a
  playbook that uses it, an eval-corpus entry that applies-then-verifies in a
  fix-loop, and optionally a Postgres change-log shaped for future ServiceNow
  migration. Defaults to a single agent that walks the steps sequentially —
  cheap. Opt-in --team flag escalates to a parallel multi-expert orchestration
  when the change is large. Use this when the user asks to "automate Strata
  Cloud Manager", "write a custom SCM Ansible module", "build an SCM change
  with eval verify", "loop until SCM matches", or invokes /paloalto-ansible —
  even if they don't name every component.
argument-hint: "{intent} [--team] [--with-audit] [--no-eval] [--module-only]"
metadata:
  brainstorm-toolkit-applies-to: claude copilot
---

# Palo Alto SCM Ansible Automation

Produces three coordinated outputs:

1. A **custom Ansible module** (Python, docstrings) wrapping the official SCM
   API for one object type. NOT `paloaltonetworks.panos`, NOT SASE.
2. A **playbook** using the new module.
3. An **eval-corpus entry** — expected SCM state + verifier that applies the
   playbook, GETs from SCM, diffs, and reports pass/fail so an existing
   fix-loop driver iterates until SCM matches.

Plus, with `--with-audit`, a **Postgres change-log** schema using column
names chosen to migrate to ServiceNow CMDB CI tables later by `ALTER TABLE
RENAME` rather than a redesign.

## Trigger phrases

`/paloalto-ansible`, "automate SCM", "write custom SCM Ansible module",
"build firewall change with eval verify", "loop until SCM matches", "audit
log of SCM changes".

## Arguments

- `intent` (required): Free-form. Examples:
  `"create an address object in folder NetEng with FQDN x.example.com"`,
  `"sync address-groups from inventory CSV into SCM folder X"`.
- `--team` (default off): Escalate to parallel multi-expert orchestration
  (4 teammates) via the agent-team feature. **Cost ~5–10× the default**;
  only use for cross-object changes (e.g., a new rule that also needs new
  address objects, services, and audit hooks). Falls back to the sequential
  flow when agent-teams are not enabled.
- `--with-audit` (default off): emit Postgres change-log schema + helper.
- `--no-eval` (default off): skip eval-corpus emission.
- `--module-only` (default off): only module + smoke playbook.

## Before invoking — load project context

Read these in order, skipping any that don't exist:

1. The repo-local SCM docs (see "Doc-lookup discipline" in
   `references/scm-ansible.md`).
2. `README.md`, `CLAUDE.md` / `AGENTS.md`.
3. `.claude/project.json` (read `firewall.*` keys — all optional; see below).
4. `library/` or `plugins/modules/` — if custom modules already live there,
   MATCH layout. Don't introduce a new collection structure.
5. The existing eval-corpus dir (`evals/`, `tests/evals/`, `eval-corpus/`)
   if present — new entries must follow the existing layout exactly.

### Project config keys (all optional)

```jsonc
{
  "firewall": {
    "scm_tenant_url": "https://...",
    "scm_client_id_env": "SCM_CLIENT_ID",
    "scm_auth_secret_env": "SCM_CLIENT_SECRET",
    "scm_tsg_id_env": "SCM_TSG_ID",
    "scm_api_docs_dir": "docs/scm-api/",
    "module_dir": "library/",
    "playbook_dir": "playbooks/",
    "eval_dir": "evals/",
    "audit_db": "postgres://...",
    "audit_servicenow_table_hint": "cmdb_ci_ip_firewall"
  }
}
```

Missing keys → use defaults shown and flag the assumption in the plan file.

---

## Default mode — single agent, sequential

Read `references/scm-ansible.md` once. It contains the full domain
discipline: doc-lookup order, endpoint spec format, custom-module shape,
verifier shape, Postgres column choices, and refuse-list. Then walk the
five passes below in order, producing the artifacts as you go.

### Pass 1 — SCM endpoint spec

Cover the endpoints the INTENT requires (create / read / update / delete /
list-filter). Follow the doc-lookup order in the reference: repo-local first,
restricted WebFetch hosts second, FORBIDDEN list third. Emit specs inline in
the plan file; modules and verifier will reference them.

### Pass 2 — Custom Ansible module

Write `{firewall.module_dir or "library/"}/scm_<object_type>.py` per the
shape in the reference. Non-negotiables: OAuth2 client-credentials auth,
GET-then-diff check mode, idempotent, Google-style docstrings, reuse or
create a shared `module_utils/scm_client.py`. First line is a `# Source:`
header citing where the contract came from.

### Pass 3 — Smoke playbook + verifier

`{playbook_dir or "playbooks/"}/scm-<slug>.yml` exercises the module.
`verify.py` GETs the object back from SCM and diffs against expected.
Stdlib + httpx + pydantic only.

### Pass 4 — Eval-corpus entry (skip if `--no-eval` or `--module-only`)

`evals/scm-<slug>/` matches the existing entries' file layout. Includes
`expected.json`, `playbook.yml`, `verify.py`, and a `README.md` describing
how it plugs into the user's existing fix-loop driver. Do NOT invent a new
loop runner — reference what exists.

### Pass 5 — Postgres audit (only if `--with-audit` and not `--module-only`)

`db/migrations/<timestamp>_scm_change_log.sql` + `db/scm_audit_helper.py`
with Google-style docstrings. Column names follow the ServiceNow-mapping
table in the reference. Flag any column requiring a real migration decision.

### Pass 6 — Plan summary

`plans/paloalto-<slug>.md` with: intent, doc citations table, change
summary table, eval-loop wiring command, ServiceNow migration note (if
`--with-audit`).

---

## Opt-in `--team` mode — parallel multi-expert

When the change spans multiple object types or warrants independent expert
critique, escalate by passing `--team`. Requires agent-teams enabled:

```json
// settings.json
{ "env": { "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1" } }
```

If agent-teams is not enabled, silently fall back to the sequential default
and note this in the plan file.

When enabled, create an agent team with 4 teammates (Sonnet each). Require
plan approval before any teammate writes files. Each teammate first reads
`references/scm-ansible.md` for the shared discipline (doc-lookup order,
module shape, ServiceNow column mapping, refuse list), then does their part:

- Teammate 1 — SCM API expert: runs first, emits the endpoint spec everyone
  else depends on. Focus is on the doc-lookup discipline in the reference.
- Teammate 2 — Custom Ansible module developer: writes the module + smoke
  playbook per the "Custom Ansible module shape" section of the reference.
- Teammate 3 — Python expert: writes the verifier + reviews Teammate 2's
  module for docstrings/types/error handling.
- Teammate 4 — Postgres expert (only when `--with-audit`): emits the
  ServiceNow-shaped change-log schema + insert helper per the reference's
  column table.

You (orchestrator) write `plans/paloalto-<slug>.md` and the eval-corpus
entry from their outputs. Coordination: Teammate 1 first; 2/3/4 in parallel
after.

The token cost difference vs. default mode is roughly 5–10×. Use only when
the change really benefits from independent expert critique.

---

## Allowed change types (project-specific)

<!--
USER-FILL: constrain what this skill will author for your environment.
  ALLOWED: addresses, address-groups, services, security-rules, tags
  DENY: zones, virtual-routers, HA-config, decryption-profiles
Both the default-mode flow and the --team-mode Teammate 2 read this list
and refuse out-of-scope intents.

If you leave these empty, the skill falls back to the global refuse-list
in references/scm-ansible.md (zones, virtual-router, HA, bulk-destructive
ops are denied; all other SCM object types are allowed). An empty ALLOWED
list is treated as "all object types allowed except the global deny
list" — NOT as "allow everything." If you want a stricter project-level
allowlist, list the object types here.
-->

ALLOWED: <!-- empty → fallback to references/scm-ansible.md global allowlist -->

DENY: <!-- empty → fallback to references/scm-ansible.md global deny list (zones, virtual-routers, HA, bulk-destructive) -->

---

## Output Format (both modes)

Use `Write` under the repo root:

```
{module_dir}/scm_<object_type>.py
{playbook_dir}/scm-<slug>.yml
{eval_dir}/scm-<slug>/{expected.json, playbook.yml, verify.py, README.md}
db/migrations/<timestamp>_scm_change_log.sql        # --with-audit only
db/scm_audit_helper.py                              # --with-audit only
plans/paloalto-<slug>.md
```

Plan file must contain: intent, doc-citation table, change summary table,
eval-loop wiring command, ServiceNow migration note (if `--with-audit`).

---

## Reusing the expertise from other skills

`references/scm-ansible.md` is self-contained. Any other skill or a `/task`
invocation that needs SCM-Ansible discipline can `Read` it directly without
invoking `/paloalto-ansible`:

```
Read skills/paloalto-ansible/references/scm-ansible.md
```

Use this when the change is small enough to fit in one `/task` and you don't
want the multi-pass overhead.

## When to skip this skill

- One-off ad-hoc change with no need for a reusable module → just write the
  playbook inline.
- The project ALREADY has a module covering the object type → use it.
- The project is on `paloaltonetworks.panos` — this skill deliberately does
  not use that collection.

## See also

- `references/scm-ansible.md` — single-file domain reference (READ FIRST)
- `/eval-harness` — the eval-fix loop pattern this skill's outputs plug into
- `/brainstorm-team` — agent-team primitive used by `--team` mode
