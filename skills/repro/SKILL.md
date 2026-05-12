---
name: repro
description: >
  Scaffold a sandboxed proof-of-concept for a finding produced by /hunt or
  /full-audit. Writes a Python script and an HTTP request file under
  ./repro/ that targets localhost only — payload is read-only (whoami,
  SELECT @@version, /etc/hostname, time-based blind probe). Use when the
  user says /repro <finding-id>, "show me the exploit", "can we actually
  trigger this", "demo this finding", or needs evidence to escalate or
  prioritize a finding.
argument-hint: "<finding-id>   # e.g. 'ssrf-01', or path to a finding md file"
metadata:
  brainstorm-toolkit-applies-to: claude copilot
---

# /repro — sandboxed proof-of-concept generator

Turns a markdown finding into a runnable PoC under `./repro/`. The
goal is *evidence* — convince a reviewer the vuln is real — not
exploitation. The script asserts the target is loopback before
sending anything; the payload is intentionally non-destructive.

## Scope and rules

- **Authorized testing only.** This skill produces code that connects
  back to the user's localhost sandbox. It refuses non-loopback hosts
  at runtime. Do not edit the loopback assertion out.
- **Localhost-only.** Never target staging-with-real-data, never
  production, never third-party hosts. If the user asks to point the
  PoC at a non-loopback target, refuse and explain.
- **Read-only proof payloads.** `whoami`, `SELECT @@version`, reading
  `/etc/hostname`, a time-based blind probe — anything that
  demonstrates code execution or data access *without* writing data
  or destroying state. If the finding inherently requires a destructive
  payload to prove, document that in the README under `./repro/` and
  stop. The user can craft and authorize the destructive variant
  manually.
- **Read-only tools** for the skill itself: `Read`, `Glob`, `Grep`,
  scoped `git`, plus `Write` *only* under `./repro/`. No `Edit`, no
  general `Bash`. The PoC is generated, not executed by this skill.

## Args

- **`<finding-id>`** — either a short ID (e.g. `ssrf-01`) that the
  skill resolves against `plans/findings/*-<sha>.md` or
  `plans/audit-<sha>.md`, or a direct path to a finding markdown
  file (e.g. `plans/findings/ssrf-abc123.md#Vuln-3`).
- If no arg given, list available finding IDs from the most recent
  `plans/audit-*.md` and ask which one.

## Procedure

### 1. Locate the finding

If arg is a path → read it directly. Otherwise grep
`plans/findings/*.md` and `plans/audit-*.md` for the ID. Extract:
- Category (authz, ssrf, deser, …)
- File:line of the sink
- HTTP method, path, auth requirement (parse from the exploit
  scenario)
- Confidence score (skip if <8 — refuse to repro low-confidence
  findings; they're FP-prone)

### 2. Choose a non-destructive proof payload

Per category, the default payload:

| Category | Payload |
|---|---|
| SQL injection | `' UNION SELECT @@version,NULL --` (read-only) |
| Command injection | `; whoami #` or `$(whoami)` |
| SSRF | `http://127.0.0.1/` then `http://169.254.169.254/latest/meta-data/` if cloud — but use a local mock listener |
| Path traversal | `../../etc/hostname` |
| XSS | `<img src=x onerror=alert(1)>` (browser-only confirmation, document, do not auto-run) |
| Authz / IDOR | Two cookies for two users; fetch user-B's resource with user-A's cookie |
| Deser | A class instance that prints `whoami` in its constructor; do not include a real gadget chain |
| Mass-assign | Add the over-posted field with a benign value like `role: "test-marker"`; verify in DB readback |
| File upload | A `.txt` with magic bytes that look like an image, plus a polyglot proof; do not upload an actual webshell |
| Secrets | No PoC — the proof is the grep hit. Rotate, don't replay. |
| Crypto | Deterministic decryption of a sample ciphertext using the recovered weakness; not an active attack |

### 3. Confirm sandbox setup with the user

Print the planned PoC contents and ask:
```
About to write ./repro/<finding-id>/repro.py + request.http
Target host: 127.0.0.1:<port>
Payload: <one-line description>

Confirm:
- Is your sandbox running on 127.0.0.1:<port>? [y/n]
- Is this sandbox isolated from any real data? [y/n]
```
Only proceed on `y` to both.

### 4. Generate the files

Create `./repro/<finding-id>/`:
- `repro.py` — from `templates/repro-script.template.py`, with the
  loopback assertion intact.
- `request.http` — from `templates/request.template.http`, suitable
  for VS Code REST Client or JetBrains HTTP client.
- `README.md` — one-paragraph context: finding ID, target setup,
  expected output signal, cleanup steps.

### 5. Print run instructions

```
Repro scaffold: ./repro/<finding-id>/
Run: python ./repro/<finding-id>/repro.py
Expected output: <detection signal>

Loopback assertion is in place — script refuses non-127.0.0.1 hosts.
Cleanup: rm -rf ./repro/<finding-id>/ when done.
```

Do not execute the PoC from inside this skill. The user runs it in
their controlled sandbox.

## Why localhost-only, why read-only payloads

The point of `/repro` is to lower the cost of *confirmation*, not to
arm an attacker. A localhost loopback assertion makes accidental
escalation hard (the script literally refuses to run elsewhere).
Read-only payloads keep the demo within the bounds of authorized
review — `whoami` proves code execution as plainly as `rm -rf /` and
leaves the sandbox usable.

If a finding really needs a destructive payload to demonstrate (rare),
that's a separate, documented decision — not the default.

## When this skill triggers

- User types `/repro <finding-id>`
- User says "show me the exploit", "can we actually trigger this",
  "I need evidence for the ticket", "demo the finding"
- After `/full-audit` or `/hunt`, on the top High finding

## When NOT to use

- Confidence <8 — the finding is already FP-prone; running a PoC
  against a likely false positive wastes time. Re-verify in code first.
- Secrets findings — rotate, don't replay.
- Any time the target isn't your own sandbox. If the user wants to
  test against a third-party system, refuse and point them at a
  formal pentest engagement.
