# Playbook: crypto — weak primitives, custom crypto, weak RNG

## What this hunts

Crypto choices that look right at a glance but fail under real
adversaries: deprecated hash functions for password storage, weak block
modes, hardcoded IVs, custom "encryption" schemes, `Math.random()` for
security tokens, and TLS configurations that allow downgrade.

## Sweep targets

### Hash functions
- `MD5`, `SHA1` for *security* purposes (password storage, integrity
  checks of attacker-controlled data, signatures). Both are fine for
  non-security (e.g. content-addressable cache keys) — name the
  context.
- Password hashing: anything that isn't bcrypt / scrypt / argon2 /
  PBKDF2 with high iterations. `hashlib.sha256(password)` is broken.

### Symmetric crypto
- ECB mode: `Cipher.getInstance("AES/ECB/...`, `AES.new(key, AES.MODE_ECB)`.
- Hardcoded IV: `iv = b"\x00" * 16`, `iv = "1234567890123456"`.
- IV reuse: same `iv` variable across encrypt calls — find by Grep for
  `iv` written once, used in a loop or per-call.
- CBC without authentication: `AES-CBC` without an HMAC over the
  ciphertext (padding-oracle exposure).
- Static keys derived from low-entropy inputs.

### Asymmetric crypto
- RSA without padding (`RSA/NONE/NoPadding`).
- RSA-PKCS1v1.5 for *encryption* (Bleichenbacher); fine for legacy
  signatures with careful verification.
- ECDSA with deterministic-k missing.

### Randomness
- `Math.random()` (JavaScript), `random.random()` (Python `random`
  module), `rand()` (PHP/C), `java.util.Random` — none are CSPRNG.
  Used for tokens, salts, session IDs, password reset codes, or keys
  → finding.
- Time-derived seeds: `random.seed(time.time())`.

### TLS / transport
- `verify=False`, `rejectUnauthorized: false`, `InsecureSkipVerify: true`
  on HTTP clients — disables cert validation.
- Hard-coded `TLSv1`, `SSLv3` minimum.

### Custom crypto
- Any function named `encrypt`/`decrypt` that uses XOR loops, char-by-
  char transforms, base64-and-call-it-encryption, or rolls its own
  Feistel.

## Vulnerable shape

```python
def hash_password(p):
    return hashlib.sha256(p.encode()).hexdigest()   # not a KDF
```

```javascript
const token = Math.random().toString(36).slice(2);   // predictable
```

```java
Cipher c = Cipher.getInstance("AES");                // defaults to ECB
```

```go
http.Client{Transport: &http.Transport{
    TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
}}
```

## Safe shape

- Password storage: `bcrypt(cost>=12)`, `argon2id(...)`, `scrypt`.
- Symmetric: AES-GCM with per-message random nonce; `libsodium`
  / `cryptography.fernet` / `aws-encryption-sdk` for higher-level use.
- Random: `crypto.randomBytes` (Node), `secrets.token_bytes` (Python),
  `SecureRandom` (Java), `crypto/rand` (Go).
- TLS: leave defaults alone; let the platform's TLS config drive
  versions and cipher suites.

## Suppression rules

- MD5/SHA1 used for non-security: content-addressable storage, cache
  keys, ETag generation. Confirm the input isn't attacker-controlled
  in a way that matters (e.g., cache-key collision DoS) before
  suppressing.
- "Random" used for non-security: jitter, dithering, picking which
  test to run. Confirm none of the values flow to a token, ID, or key.
- `InsecureSkipVerify` in a test file pointed at a self-signed local
  server.

## Trace direction

Sink-first for primitive choice. For each hit, classify the *purpose*:
security-sensitive (token, secret, signature, password) or not. The
purpose determines whether the finding stands.

## Fix vocabulary

Name the primitive and its replacement directly. Avoid "use stronger
crypto" hand-waving — recommend the exact API in the codebase's
language. For password storage, name the cost parameter explicitly
(bcrypt cost 12+, argon2id memory 64 MiB+, scrypt N=2^15+). Codify
the lint rule via `/codify` so the deprecated API is rejected at PR
time.
