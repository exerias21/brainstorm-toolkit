# Security review checklist — Stage 5.7 `security` lens

Application-security bug-classes for the Review→Fix stage's `security` lens (see `skills/sdlc/SKILL.md`
Stage 5.7). Scope is **this diff**, not a whole-repo audit. Same finding shape as every other lens
(`REVIEW_FINDING_SCHEMA`); rides the reviewer-model axis (default `opus`), never `models.cap`.

```
Security review checklist (review THIS diff, not the whole repo):
1. Injection — queries built by string-concat / f-string instead of parameters (SQL/NoSQL);
   subprocess with shell=True or a command string carrying external input; template injection.
2. AuthN/AuthZ — every NEW endpoint/route/handler: is authn enforced? Object-level authz
   (can user A pass user B's id — IDOR)? Is a privileged action reachable unauthenticated?
3. Secrets — hardcoded token/password/key; secret echoed to logs/errors/URLs; a real value
   committed where a placeholder belongs (.env.example / fixtures).
4. Input validation & deserialization — external input (params, uploads, webhooks) bounded &
   validated before use; no pickle.loads / yaml.load(unsafe) / eval on untrusted data.
5. SSRF & path traversal — user-controlled URL fetched server-side without an allowlist;
   user-controlled path joined into fs access without normalize + prefix check.
6. Dependencies / supply-chain — new dep pinned? name plausible (not typo-squat)? lockfile
   updated? known-vuln check if an audit tool is configured.
7. Crypto — random.* where secrets.* is required; home-rolled hashing/crypto; passwords without
   a modern KDF (bcrypt/argon2); TLS verification disabled (verify=False).
8. Sensitive-data exposure — PII/credentials in logs or traces; over-broad API response;
   debug endpoint/flag reachable on a prod path.
9. XSS / output encoding — user content rendered unescaped (dangerouslySetInnerHTML, innerHTML,
   |safe, raw template output).
10. (Skill-repo mode) shell snippets in skill prose / hook scripts: variables quoted, no eval/exec
    of fetched or user-supplied text; sentinel/JSON writes not building shell from untrusted input.
```

**Cheap grep/lint (no model needed):** `shell=True`, `eval(`, `pickle.loads`, `yaml.load(`,
`verify=False`, `dangerouslySetInnerHTML`, `innerHTML`, `random.` near `token`/`secret`/`key`,
literal `AKIA`/`sk-`/`ghp_` prefixes. **Needs the LLM reviewer:** #2 (authz reasoning), #5
(data-flow to the sink), #6 (name-plausibility), #8 (exposure judgment). A good split: run the
grep-able items as a pre-review lint gate before spending reviewer-model tokens on the ones that
need judgment.
