# Threat Model — {{repo_or_module_name}}

- **Date**: {{YYYY-MM-DD}}
- **Scope**: {{paths or feature}}
- **Method**: STRIDE walkthrough of code-resident entry points

## 1. System summary

<!--
3-5 sentences. What this service does, who its users are (anon, authed
low-priv, authed high-priv, internal-only), where it lives (public
internet, VPN, internal mesh), and what kinds of data it handles
(PII, credentials, secrets, financial, none).
-->

## 2. Entry points

<!--
Every place untrusted input enters the system. Group by surface:

### HTTP routes
- `METHOD /path` — handler at `file:line` — auth required: yes/no/role —
  notable inputs: <list params, headers, body fields>

### Message queues / webhooks / scheduled jobs
- <queue or hook name> — handler at `file:line` — auth model

### CLI / file watchers / IPC
- ...

### Client-side surfaces (if SPA / mobile / desktop)
- ...
-->

## 3. Trust boundaries

<!--
Where data crosses from less-trusted to more-trusted contexts. Each
boundary needs a name, the code-level chokepoint (middleware,
deserializer, validator), and what control lives there today.

- **Internet → app** — middleware at `file:line` — controls: TLS, rate
  limit, CSRF (if web), session validation.
- **App → DB** — query layer at `file:line` — controls: parameterized
  queries / ORM only / raw SQL with escaping.
- **App → outbound HTTP** — `file:line` — controls: URL allowlist / DNS
  pinning / none (SSRF risk).
- **App → filesystem** — `file:line` — controls: path normalization,
  chroot, allowlist.
- **App → shell / exec** — `file:line` — controls: argv arrays only /
  shell=True (CRITICAL: command-injection candidate).
- **App → unsafe deserialization** — `file:line` — controls: schema-
  bound JSON only / safe-loader variants / HMAC-verified-then-decode.
-->

## 4. Downstream sinks

<!--
For each dangerous primitive used in the codebase, list every call site.
This drives the hunter prompts later.

- SQL execution: `file:line`, `file:line`, ...
- HTML rendering: `file:line`, `file:line`, ...
- Unsafe deserializers (binary loaders, YAML.load, Marshal, unserialize): ...
- Subprocess / dynamic require / runtime code-evaluators: ...
- Outbound HTTP (where URL comes from input): ...
- Crypto (use of MD5/SHA1, hardcoded keys, Math.random for security): ...
-->

## 5. STRIDE per high-value flow

<!--
Pick the 3-7 highest-value data flows (auth, payments, file upload, admin,
data export, etc.). For each, walk STRIDE and list concrete code-level
risks. Empty categories are fine — don't pad.

### Flow: <name>
- **S — Spoofing**: ...
- **T — Tampering**: ...
- **R — Repudiation**: ...
- **I — Information disclosure**: ...
- **D — Denial of service**: ...
- **E — Elevation of privilege**: ...
-->

## 6. Top-N risky flows — ranked

<!--
Order by exploitability × blast_radius. Each entry: flow name, one-line
risk statement, candidate hunter class(es) to dispatch
(`/hunt authz`, `/hunt ssrf`, ...), and the file(s) to focus on.
-->

## 7. Out of scope

<!--
Explicitly list flows or surfaces NOT analyzed and why. Useful for the
next audit to pick up where this one stopped (e.g. "admin console at
/internal/* not reviewed — only reachable from VPN, lower priority").
-->
