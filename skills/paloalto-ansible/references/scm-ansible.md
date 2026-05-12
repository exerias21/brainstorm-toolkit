# SCM Ansible Automation — Single-File Reference

Everything one agent needs to design a Strata Cloud Manager (SCM) firewall
change as a custom Ansible module + playbook + eval entry. Self-contained so
`/task`, `/sdlc`, or any other skill can `Read` this file and acquire the
domain knowledge without invoking `/paloalto-ansible`.

This is the OFFICIAL Strata Cloud Manager API path. It is NOT the
`paloaltonetworks.panos` collection and it is NOT the legacy SASE / Prisma
SASE API. Those are wrong directions for this project.

## Doc-lookup discipline

Strict order. Stop at the first that has what you need:

1. **Repo-local docs.** Search for `docs/scm-api/`, `docs/scm/`,
   `references/scm-api/`, `references/`, or any `*scm*.md` / `*strata*.md`
   under `docs/`. The user has stated the repo contains the SCM context
   needed. Cite `<path> @ <git-sha>` in the `# Source:` header of every
   emitted file.
2. **WebFetch fallback — restricted hosts only:**
   - `https://pan.dev/scm/api/` (primary developer docs)
   - `https://docs.paloaltonetworks.com/strata-cloud-manager` (concept docs)
   Cite `<URL> @ <YYYY-MM-DD>`.
3. **FORBIDDEN:** `prismaaccess.com`, `prisma-sase`, `*legacy*`, `*v1beta*`
   pages. Skip even if a search engine ranks them highly — they describe a
   different API generation that this project explicitly does not use.
4. **context7** is OK for ancillary libs only: `psycopg` v3, `httpx`,
   `pydantic`. Never use it for SCM endpoints — there is no context7 entry
   for SCM and any answer would be hallucinated.

If a lookup fails (network, rate-limit, missing doc), write
`# TODO: doc lookup failed — verify before use` and stop. Do not guess
endpoint paths from training memory — SCM path-shape misremembering is the
failure mode that wires up the wrong API surface.

## Endpoint spec format

For each operation the change requires (create / read / update / delete /
list-with-filter), capture:

```markdown
### <Operation> <object-type>
- Source: <repo-path-or-URL> @ <sha-or-date>
- Method: POST | GET | PUT | DELETE
- URL: {tenant}/sse/config/v1/<resource>
- Query: folder={folder_name} (required), other filters
- Headers:
  - Authorization: Bearer {token}
  - Content-Type: application/json
- Body: { ...field shape... }
- Returns:
  - 2xx: <shape>
  - 4xx/5xx codes the module must handle: 400, 401, 403, 404, 409, 429, 5xx
- Folder/scope rules: <leaf-only? Global allowed?>
- Idempotency check: GET <path>?name=... &folder=... before POST
```

### Auth flow (always include)

```markdown
### Auth (OAuth2 client credentials)
- Token endpoint: https://auth.apps.paloaltonetworks.com/oauth2/access_token
- Grant: client_credentials
- Client ID: env var named by firewall.scm_client_id_env
             (default SCM_CLIENT_ID)
- Client secret: env var named by firewall.scm_auth_secret_env
                 (default SCM_CLIENT_SECRET)
- TSG ID: env var named by firewall.scm_tsg_id_env
         (default SCM_TSG_ID) — passed into the scope as `tsg_id:{tsg}`
- Scope: `tsg_id:{tsg_id}` (substituted at request time from the TSG env var)
- Required POST body fields: `grant_type=client_credentials`,
  `client_id={client_id}`, `client_secret={client_secret}`,
  `scope=tsg_id:{tsg_id}`
- Token TTL per docs; module must refresh on 401. If any of the three
  env vars is missing at runtime, fail with a clear message naming
  which env var is unset — do not silently attempt the call.
```

### Folder/scope discipline

The most common SCM mistake is targeting the wrong scope. Always include a
"Folder/scope rules" line per endpoint. Reject any intent that targets
`Global` without an explicit user override flag.

## Custom Ansible module shape

One Python file per object-type, placed at `{firewall.module_dir or "library/"}/scm_<object_type>.py`.

```python
#!/usr/bin/python
# Source: docs/scm-api/<file>.md @ <git-sha> (repo)
from __future__ import annotations

DOCUMENTATION = r"""
---
module: scm_<object_type>
short_description: Manage <object_type> in Strata Cloud Manager
description:
  - Calls the official SCM config API (NOT the SASE/Prisma legacy API).
  - Supports check mode via GET-then-diff.
options:
  ...
"""

EXAMPLES = r"""..."""
RETURN = r"""..."""

from ansible.module_utils.basic import AnsibleModule
from ansible.module_utils.scm_client import ScmClient   # shared helper


def run(module: AnsibleModule) -> None:
    """Top-level module entry — dispatches present/absent.

    Args:
        module: Ansible module instance with validated params.
    """
    ...
```

### Non-negotiables

- **Check mode by GET-then-diff.** In `_ansible_check_mode`, GET the current
  state, compute diff against desired, return `changed=true/false`. Never
  POST/PUT/DELETE in check mode. This is what makes `ansible-playbook --check`
  meaningful and what lets the eval loop dry-run safely.
- **Idempotent.** Re-running against converged state returns `changed=false`.
  The eval loop depends on this to distinguish "needed a fix" from "already
  good".
- **Google-style docstrings** on every function/class. Populate
  `DOCUMENTATION` / `EXAMPLES` / `RETURN` with realistic content — the
  verifier and eval-corpus reader pull `EXAMPLES` to construct test payloads.
- **Shared `module_utils/scm_client.py`** holds auth, retry, pagination.
  Never inline HTTP calls inside the module body. If the helper doesn't
  exist yet, design it alongside the first module and reuse from then on.

## Playbook + verifier pair

```yaml
# playbooks/scm-<slug>.yml
- name: <intent>
  hosts: localhost
  gather_facts: false
  vars:
    folder: "NetEng"
    name: "{{ object_name }}"
  tasks:
    - name: ensure <object>
      scm_<object_type>:
        state: present
        folder: "{{ folder }}"
        name: "{{ name }}"
        # ... payload fields ...
```

```python
# verify.py — used by the eval loop
"""Post-apply verifier. Exit 0 on match, non-zero with diff on mismatch."""
# Source: docs/scm-api/<file>.md @ <git-sha> (repo)

def verify(expected: dict, observed: dict) -> tuple[bool, dict]:
    """Diff observed SCM state against expected payload.

    Args:
        expected: The payload the playbook intended to produce.
        observed: The object GET'd from SCM after the playbook ran.

    Returns:
        (ok, diff) — ok is True when observed matches expected for the
        fields that matter; diff lists mismatches.
    """
    ...
```

Stdlib + `httpx` + `pydantic` only unless the project pins more.

## Eval-corpus entry

Match the layout of existing entries under `firewall.eval_dir` (default
`evals/`). Do NOT introduce a new shape. Typical:

```
evals/scm-<slug>/
  expected.json      # payload that should exist after playbook runs
  playbook.yml       # copy or symlink of the playbook
  verify.py          # copy or symlink of the verifier
  README.md          # how this plugs into the user's eval-fix loop
```

The user's loop is: **apply → verify → on-fail → fix playbook → re-apply**.
Reference the project's existing loop driver (`/eval-harness` or a custom
runner) — do not invent a new one.

## Postgres audit schema (only when `--with-audit`)

Local Postgres today, ServiceNow CMDB tables tomorrow. Pick column names so
the migration is a series of `ALTER TABLE ... RENAME` rather than a
redesign. Suggested columns:

| Column            | Type         | Why this name                    |
|-------------------|--------------|----------------------------------|
| `change_id`       | uuid PK      | Maps to ServiceNow sys_id        |
| `actor`           | text         | Not "user_id" — SN uses `sys_created_by` style |
| `ts`              | timestamptz  | Default `now()`                  |
| `intent`          | text         | The natural-language intent      |
| `scm_scope`       | text         | folder/snippet path              |
| `object_type`     | text         |                                  |
| `object_id`       | text         |                                  |
| `action`          | text         | create/update/delete             |
| `payload_sent`    | jsonb        |                                  |
| `payload_observed`| jsonb        | (Post-eval verify result)        |
| `eval_result`     | text         | pass/fail/n_a                    |
| `apply_mode`      | text         | check/apply                      |

Flag any column where the ServiceNow target shape isn't obvious — those need
a deliberate decision at migration time, not an auto-rename.

## Refuse to generate

- Endpoints on the SASE / Prisma SASE / legacy surfaces
- Object types outside the project's ALLOWED list (see canonical SKILL.md)
- Zone changes, virtual-router config, HA setup — architecture, not policy
- Bulk-destructive operations (delete-by-tag, wipe-folder) without an
  explicit `confirmation_token` parameter in the intent

## How `/task` consumes this file

A `/task` invocation that needs SCM-Ansible expertise can:

```
Read skills/paloalto-ansible/references/scm-ansible.md
```

…then follow the discipline above to produce a one-off module + playbook
without invoking `/paloalto-ansible`. This skips the orchestration overhead
when the change is small enough to fit in a single `/task`.
