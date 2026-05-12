---
name: threat-model
description: >
  Build a STRIDE-style threat model of the codebase from source. Lists entry
  points, trust boundaries, downstream sinks, and the top-N highest-risk data
  flows — each with file:line anchors. Run this first before /hunt or
  /full-audit so the hunters know where to look. Use when the user says
  /threat-model, "threat-model this", "what's the attack surface", "where
  could this break", "security review starting point", or before shipping a
  feature that touches auth, payments, file I/O, or external network calls.
argument-hint: "[path|module]   # default: whole repo"
metadata:
  brainstorm-toolkit-applies-to: claude copilot
---

# /threat-model — STRIDE walkthrough from source

Produces `plans/threat-model-<slug>.md` — the durable artifact that downstream
skills (`/hunt`, `/full-audit`) consume to focus their work. Read-only:
this skill never edits code.

## Scope and rules

- **Authorized review of owned source only.** If the user invokes
  `/threat-model` against a repo they don't own, stop and ask them to
  confirm scope and rules of engagement first.
- **Source-only**. No live probing, no requests to running services. The
  output identifies *where* risks live in code; running the actual attack
  is `/repro`'s job.
- **Read-only tools**: `Read`, `Glob`, `Grep`, scoped `git`. Do not
  edit, write, or run general shell commands. The only file this skill
  writes is the threat-model markdown under `plans/`.

## Args

- **`<path|module>`** (optional) — limit the model to a subtree or a
  module declared in `.claude/project.json::modules`. No arg = whole repo.

## Procedure

### 1. Load project context

Read, in this order, whichever exist:
- `README.md`
- `AGENTS.md` (or `CLAUDE.md`)
- `.claude/project.json` — especially `modules`, `auth_model`, `data_classification`
- `GOTCHAS.md` — pre-existing pitfalls inform STRIDE; cite them in the model

If `.claude/project.json` is missing or empty, that's fine — proceed
without the optional inputs and note "no project.json — entry points
discovered by Grep" in section 1 of the report.

### 2. Discover entry points

Grep for the framework's route declarations and message handlers. Don't
assume one stack — detect what's present:

| Stack signal | Grep targets |
|---|---|
| Express / Fastify / Hapi | `app.get(`, `app.post(`, `router.<verb>(`, `@Get(`, `@Post(` |
| Flask / FastAPI | `@app.route`, `@router.<verb>`, `APIRouter()` |
| Django | `urlpatterns`, `path(`, `re_path(` |
| Spring | `@RequestMapping`, `@GetMapping`, `@PostMapping`, `@Controller` |
| Rails | `routes.rb`, `resources :`, `match '`, `get '` |
| Go (net/http, chi, gin) | `http.HandleFunc`, `r.Get(`, `r.Post(`, `e.GET(` |
| AWS Lambda / handlers | `def lambda_handler`, `exports.handler` |
| Message queues | `@SqsListener`, `kafka.consume`, `redis.subscribe`, `bull.process` |
| CLI / cron | `if __name__ == "__main__"`, `cobra.Command`, `commander`, cronfiles |

For each match, capture: HTTP verb (if applicable), path, handler symbol,
file:line, and the middleware chain it sits behind. Auth requirement is a
*conclusion* drawn from the middleware chain — don't trust comments.

### 3. Identify trust boundaries

For each boundary type below, find the chokepoint file:line and the
control that lives there *today* (not what the docs claim):

- Internet → app (auth middleware, CSRF, rate limit)
- App → DB (query layer: parameterized? ORM? raw SQL?)
- App → outbound HTTP (URL construction — SSRF candidates)
- App → filesystem (path joining, normalization, allowlist)
- App → shell / `exec` / `eval` / dynamic require / dynamic `import` /
  language-specific reflection (`getattr` chains in Python,
  `Method.invoke` in Java)
- App → JavaScript code-execution sinks: bare `eval`, the `Function`
  constructor when invoked with a string body, string-form timer APIs,
  Node's `vm.runIn*` family, and the HTML-write DOM sinks (the latter
  cross-listed with the xss-dom playbook — refer to that playbook for
  the concrete sink names)
- App → unsafe deserialization (binary deserializers, YAML.load, Marshal,
  unserialize, `JSON.parse` on attacker-controlled JSON before schema
  validation)

### 4. Enumerate downstream sinks

For each dangerous-primitive class, list every call site (capped at 30
per class — note the cap if hit). This is what the hunters will grep
for later; the threat model gives them the index. For JavaScript/Node
codebases, the JS code-execution sinks above are a distinct class from
the shell/exec sinks — enumerate them separately so the xss-dom and
deser hunters can find them.

### 5. Walk STRIDE for top flows

Pick 3-7 highest-value flows (auth, payments, admin, file upload, data
export, etc.) and walk all six STRIDE categories. Empty categories are
fine — don't pad.

### 6. Rank and recommend hunters

Order flows by `exploitability × blast_radius`. For each top flow, name
the `/hunt <class>` invocation(s) that should follow.

## Output

Write the model to `plans/threat-model-<slug>.md` using
`templates/threat-model.template.md`. The slug is derived from the path
argument (`whole-repo` if none) plus the short SHA at HEAD, so
re-running on a moved tree produces a new file rather than silently
overwriting prior work.

Print a one-line summary to chat:
`Threat model saved: plans/threat-model-<slug>.md — <N> entry points · <M> sinks · <K> ranked flows. Suggested next: /full-audit or /hunt <top-class>.`

## Why STRIDE, why source-only

STRIDE is the smallest frame that still forces coverage across the six
property classes that matter (auth, integrity, accountability,
confidentiality, availability, authorization). Source-only keeps the
skill safe to run anywhere — including third-party reviews and CI — and
keeps the artifact deterministic: two runs on the same SHA produce
substantively the same model.

## When this skill triggers

- User types `/threat-model` (with or without a path arg)
- User says "threat-model this", "what's the attack surface here", "where
  could this break", "do a security model"
- Pre-feature kickoff for anything touching auth, payments, file uploads,
  or outbound network calls
- First step before `/full-audit` (the orchestrator reads this file)

## When NOT to use

- For a specific finding's exploitability proof → use `/repro`
- For sweeping one bug class across the codebase → use `/hunt <class>`
- For dep-vuln summaries → use `/repo-health` (it covers CVE counts)
