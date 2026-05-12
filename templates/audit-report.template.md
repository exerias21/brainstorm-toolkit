# AppSec Audit — {{repo_name}}

- **Date**: {{YYYY-MM-DD}}
- **Branch / commit**: {{branch}} @ {{short_sha}}
- **Scope**: {{paths or modules audited}}
- **Hunters run**: {{authz, ssrf, deser, xss-dom, auth-state, mass-assign, file-upload, secrets, crypto}}
- **Threat model**: `plans/threat-model-{{slug}}.md` (if /threat-model was run)

## Summary

<!--
3-5 sentence executive summary. Lead with the worst single finding
(or "no High-severity findings"). Mention how many findings survived
the confidence>=8 filter and how many were dropped as likely false
positives. State whether the codebase needs a fix-and-re-audit cycle
before merge, or whether the issues can be queued.
-->

## Findings — ranked

<!--
Findings are ordered by `exploitability × blast_radius`, descending.
Each finding is the full body from templates/finding.template.md.
Drop anything below confidence 8 entirely.
-->

### High

<!-- Render each finding using templates/finding.template.md. -->

### Medium

<!-- Same shape. -->

## False positives suppressed

<!--
Findings that hunters surfaced but were dropped during the dedupe/rank
pass. One line each, with the reason: framework-handled, test-only
fixture, dead code path, behind authn+authz already, confidence<8 after
verification, etc. This is the audit trail — without it, the next run
will resurface the same noise.
-->

## Suggested next actions

<!--
The orchestrator's recommendation. Examples:
- `/repro <finding-id>` for the top-ranked finding to confirm exploitability.
- `/codify <finding-id>` to convert each High into a Semgrep + CodeQL rule.
- Open a `/sdlc` plan to land the fix bundle.
- File a /gotcha entry if the bug class is structural (e.g. all queries
  use raw string concat).
-->
