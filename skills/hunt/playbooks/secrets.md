# Playbook: secrets — hardcoded credentials, keys, tokens

## What this hunts

Secrets committed to source: API keys, private keys, JWT signing
secrets, database passwords, OAuth client secrets, cloud credentials.
Distinct from `/repo-health`'s secret scan in that this hunt also
covers *runtime* exposure (logged secrets, secrets in error messages,
secrets returned by API responses) and history scans.

## Sweep targets

### High-signal regexes
- AWS: `AKIA[0-9A-Z]{16}` (access key), `aws_secret_access_key\s*=`
- GCP: `"type":\s*"service_account"`, `private_key.*BEGIN PRIVATE KEY`
- Azure: `DefaultEndpointsProtocol=`, `AccountKey=`
- GitHub: `ghp_[0-9A-Za-z]{36}`, `gho_`, `ghs_`, `ghu_`
- Slack: `xox[baprs]-[0-9A-Za-z-]+`
- Stripe: `sk_live_[0-9A-Za-z]{24,}`, `pk_live_`, `rk_live_`
- OpenAI / Anthropic: `sk-[A-Za-z0-9]{20,}`, `sk-ant-[A-Za-z0-9-]+`
- Private keys: `-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----`
- Generic: `password\s*=\s*["'][^"']{8,}["']`, `api[_-]?key\s*=\s*["'][^"']+["']`,
  `secret\s*=\s*["'][^"']+["']`, `Authorization:\s*Bearer\s+[A-Za-z0-9._-]+`

### Locations
- Source files (especially `config/`, `settings/`, `.env.example`).
- Test fixtures (`.json`, `.yaml`, `.sql`) — often real-looking data.
- CI configs (`.github/workflows/`, `.gitlab-ci.yml`, `Jenkinsfile`).
- Dockerfiles (`ENV API_KEY=...`).
- Comments (`// TODO: replace key abc123 before merge`).

### Runtime exposure (subtler)
- Log statements that include credential variables: `log.info(f"auth
  {api_key=}")`, `console.log({password})`.
- API response bodies that include secret fields: `return user;` where
  `user` has a `passwordHash` or `apiToken` field.
- Error pages / stack traces that leak env vars or config dicts.

## Vulnerable shape

```python
STRIPE_KEY = "sk_live_<EXAMPLE_REDACTED>"   # hardcoded live key
```

```javascript
logger.info("authenticating user", { user, token });   // logs the token
```

```python
return jsonify(current_user.__dict__)   # leaks password_hash
```

## Safe shape

- Secrets from env vars or secret manager only. `.env.example` shows
  the *names*, never the values.
- Logging filters: structured loggers redact configured field names
  (`password`, `token`, `secret`, `authorization`, `cookie`).
- API serializers explicitly allowlist returned fields.

## Suppression rules

- The matched string is in a test fixture *and* the value is documented
  as a public example (e.g., Stripe's well-known test keys
  `sk_test_<EXAMPLE_REDACTED>`). Allowlist these explicitly in
  the report.
- The "secret" is a placeholder (`<your-key-here>`, `xxx`, `change-me`).
- A redaction wrapper is applied to the value before logging or
  returning (verify the wrapper exists and is called).

## Trace direction

Two passes:
1. **Source pass**: grep the regex set above; for each hit, judge if
   it's a real secret or a fixture/placeholder.
2. **Sink pass**: grep `log.`, `logger.`, `console.log`, response
   serializers; trace fields back to see if any secret-shaped field
   reaches the sink.

History scan (optional): `git log -p -S "<pattern>"` to find secrets
that *were* committed and removed. Even if removed in HEAD, anything
that ever hit a public repo must be rotated.

## Fix vocabulary

For each finding: (a) **rotate the secret immediately** (don't just
remove it from source — assume it's compromised the moment it hits
git), (b) move to env / secret manager, (c) add the regex pattern to
`gitleaks.toml` so the next commit catches a regression. Codify the
redaction wrapper via `/codify` if logs are leaking.
