# Playbook: auth-state — session, token, MFA, reset, takeover

## What this hunts

Bugs in the authentication state machine: session lifecycle, token
issuance and revocation, MFA bypasses, password reset flows, account
recovery, and trust-after-auth-event regressions. These are the bugs
that produce account takeovers — high impact, frequently overlooked.

## Sweep targets

### Sessions
- Session creation: where `set-cookie` or token issuance happens
  (`req.session.user`, `jwt.sign`, `auth.login`).
- Session fixation: does the session ID *change* on login? Grep for
  `regenerate`, `session.regenerate_id`, `req.session.regenerate`.
- Logout: does `/logout` invalidate the session *server-side*, not just
  clear the cookie?
- Concurrent sessions: are old sessions invalidated on password change?

### Tokens
- JWT verification: `jwt.verify(`, `jwt.decode(` (decode without verify
  is always a bug).
- Algorithm allowlist: is `algorithms: ["HS256"]` (or RS256) *explicitly*
  set, or does the verifier accept `alg: none` / `alg: HS256` against an
  RS256 public key?
- Secret strength: hardcoded or short JWT secrets fail this hunt;
  cross-reference with `/hunt secrets`.

### MFA
- Bypass during recovery: if password reset doesn't require MFA, MFA is
  effectively optional.
- Step-up enforcement: is the second factor required for sensitive
  operations (password change, email change, payment method add), or
  only at login?

### Password reset
- Token entropy: `crypto.randomBytes(32)` good; `Math.random()`, `uuid.v1`,
  timestamp-derived → broken (cross-reference `/hunt crypto`).
- Token storage: stored hashed? Single-use? Expiry < 1 hour?
- Email enumeration: does the response differ for "email exists" vs
  "doesn't"? (200 + "check your email" for both is the safe shape.)

### Account takeover combo paths
- Email change without re-auth.
- Email change without confirmation to *old* address.
- Recovery via SMS without rate limit (SIM-swap exposure).
- OAuth/SSO linking that trusts an unverified third-party email.

## Vulnerable shape

```javascript
// JWT with no alg pinning:
jwt.verify(token, secret);   // attacker submits alg:none
```

```python
# Login does not regenerate session:
def login(req):
    user = check_password(...)
    req.session["user_id"] = user.id   # session fixation
```

## Safe shape

- JWT verify: `algorithms=["HS256"]` explicit.
- Sessions regenerate on login *and* on privilege change.
- Password reset: hash the token before storing, expire ≤ 1 hour,
  single-use, MFA still required.
- All security-relevant operations require recent re-auth (≤ 5 min).

## Suppression rules

- The framework auto-regenerates session on login (Django >=1.7
  `login()`, Spring Security `SessionFixationProtection`) AND there is
  no custom session-write between auth check and response.
- JWT library is used as a wrapper with the alg pinned in config.

## Trace direction

State-machine-first, not source/sink. Draw the auth state machine from
code: anon → login → authed → privileged-op → logout. At each transition,
check whether the state changes are atomic, the credential is rotated,
and the prior state is invalidated.

## Fix vocabulary

For each finding, name the transition, name the missing guarantee
(rotate / invalidate / re-auth / rate-limit), and propose the framework
primitive that enforces it. Cite OWASP ASVS section 2 (Authentication)
for shared vocabulary in the recommendation.
