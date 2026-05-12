# Network Security Audit Agent

Orchestrates a network-security audit by fanning out the four stages of the
`network-engineer` skill across parallel sub-agents and joining the results
into a single ranked findings report.

Use this agent when:
- A user asks "what's exposed on our network right now?"
- After a new Batfish snapshot is uploaded
- During a bug-bounty triage pass on corp infra
- After a vendor PSIRT publishes a high-CVSS advisory affecting deployed gear

## Inputs

- `snapshot` (required): Batfish snapshot name (must already be uploaded).
- `mode` (optional): `audit` (default) | `bounty`. Controls Stage 4 output shape.
- `vendors` (optional): comma-separated list of vendors to pull PSIRT feeds for.
  Default: inferred from the Stage 1 inventory.

## Config

Reads `.claude/project.json` for `network.*` keys (see
`skills/network-engineer/SKILL.md` for the schema). All keys are optional;
missing ones are prompted for or inferred.

## Pre-flight

1. Verify required scripts exist in the consumer repo:
   - `scripts/batfish_query.py`
   - `scripts/psirt_fetch.py`
   - `scripts/qualys_xref.py` (optional, only needed if `network.qualys_xref` is true)

   If any required script is missing: stop, report which one, and tell the user
   to either install it or run with the relevant feature disabled.

2. Create the run directory: `plans/network-audit-<timestamp>/`.

## Pipeline

### Stage 1 — Inventory (single agent, blocking)

Run synchronously (Stages 2 and 3 depend on its output):

```
python3 scripts/batfish_query.py --snapshot <snapshot> \
    --question initIssues --json > plans/network-audit-<ts>/01-init.json
python3 scripts/batfish_query.py --snapshot <snapshot> \
    --question nodeProperties \
    --properties "Configuration_Format,Vendor_Family,Vrfs,Hostname" \
    --json > plans/network-audit-<ts>/01-inventory.json
```

Gate: if `initIssues` parse-failure rate > 5%, stop and surface to user. A
half-parsed snapshot produces lying findings.

### Stages 2 + 3 — Parallel fan-out

Launch in a single message, both at once:

**Stage 2 sub-agent** (Sonnet) — CVE pull:
- Read `01-inventory.json`
- Group hosts by `(Vendor_Family, OS_version)`
- For each group, run `scripts/psirt_fetch.py` with the matching vendor flags
- Normalize output (one record per CVE, see skill for shape)
- Write `plans/network-audit-<ts>/02-cves.json`
- If `network.qualys_xref` is true, also pull Qualys results and tag each
  CVE record with `qualys_seen: bool`

**Stage 3 sub-agent** (Sonnet) — Overpermissive sweep:
- Read `01-inventory.json` and the rubric from `skills/network-engineer/SKILL.md`
  (Stage 3 section)
- For each rubric row, run the corresponding Batfish question
  (`searchFilters`, `reachability`, `testFilters`)
- Compute blast-radius (reachable_hosts_from_untrusted_zones) per finding
- Write `plans/network-audit-<ts>/03-overpermissive.json` using the schema
  defined in the skill's "Stage 3 output" section (one record per finding:
  `device`, `acl_or_policy`, `rule_identity`, `rubric_row`, `base_severity`,
  `blast_radius_hosts`, `blast_radius_multiplier`, `affected_flow`, `evidence`).
  Stage 4's exploit-path-confirmed bonus depends on this schema; do not
  invent a different shape.

Both sub-agents must finish before Stage 4 starts.

### Stage 4 — Rank + report (single agent, blocking)

- Read `02-cves.json` and `03-overpermissive.json`
- For each (device, CVE) pair, compute the risk score per the formula in the
  skill's Stage 4 section
- Cross-correlate: if a CVE's `vulnerable_feature` matches a Stage 3
  overpermissive finding's affected ACL/service, multiply risk × 1.5
  (exploit-path-confirmed bonus)
- Sort descending
- Emit `plans/network-audit-<ts>/report.md` per the skill's report template
- If `mode=bounty`, also emit `report-bounty.md` with only the
  internet-exposed-unauth-RCE and lateral-movement-chain sections

### Stage 5 — Surface to user

Print:
- Path to `report.md`
- Top 3 critical findings (one-liners) inline
- Coverage caveats (parse failures, stale PSIRT feeds)

If `mode=bounty`: also print the count of internet-exposed exploit paths.

## Exit conditions

- **Success:** `report.md` written, top findings surfaced.
- **Blocked:** missing scripts, snapshot parse failure > 5%, or zero matching
  CVEs found across all vendors (likely a stale PSIRT cache — surface, don't
  silently report "all clear").
- **Partial:** if Stage 2 OR Stage 3 fails but the other succeeds, emit a
  partial report and clearly mark which half is missing. Do not block on a
  single sub-agent failure — half a finding list is more useful than none.

## Rules

- Never write to the consumer's network gear (read-only operations only).
- Never publish the report to an external system from this agent — surface the
  path, let the user decide.
- Never silently truncate the findings list; if the report is large, paginate
  with `report-page-N.md` files and surface the index.
- Treat a "no CVEs found" result as suspicious until verified — vendor feeds
  go stale, scripts hit auth issues. Confirm by checking the timestamp on the
  most recent PSIRT pull.
