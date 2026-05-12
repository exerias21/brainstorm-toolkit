# Vuln {{N}}: {{category}}: {{file}}:{{line}}

- **Severity**: {{High|Medium}}
- **Confidence**: {{1-10}}   <!-- drop the finding if < 8 -->
- **CWE**: {{CWE-id, optional}}
- **Discovered by**: {{/hunt <class> | /threat-model | /full-audit}}

## Description

<!--
What is the vulnerability, in 2-4 sentences. Name the sink, the source of
untrusted input, and the missing control. Quote the exact lines of code
where the flaw lives, with a path:line anchor.
-->

## Exploit scenario

<!--
Walk an attacker's path concretely. Who are they (anonymous user,
authenticated low-priv user, internal service)? What request do they
send? What do they get back / what side effect do they cause? Be
specific: HTTP verbs, parameter names, payload shapes. Tie the scenario
to a real entry point in this codebase, not a generic OWASP example.
-->

## Recommendation

<!--
The fix, framed as a concrete code change. Prefer parameterized APIs,
allowlist validation at the trust boundary, principle-of-least-privilege
defaults, and removing the dangerous primitive entirely over patching
its inputs. Cite the safe-by-default helper that should be used if the
codebase already has one (e.g. `db.queryParam(...)` over `db.queryRaw(
... + userInput)`).
-->

## References

<!-- Optional. CVE IDs, advisory links, framework docs. -->
