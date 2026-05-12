---
name: network-engineer
description: >
  Domain-knowledge prompt for auditing a corporate network using Batfish-parsed
  device configs cross-referenced against vendor PSIRT CVE feeds. Encodes the
  severity rubric, overpermissive-rule checklist, and CVE-to-config correlation
  patterns that turn raw config + CVE data into a ranked findings report.
  Use when running a network-security audit, a bug-bounty sweep over corp
  infra, or answering "which devices have feature X enabled that's part of
  CVE Y." Pairs with the `network-sec` agent for Claude-orchestrated runs;
  on Copilot/Codex the same stages run sequentially.
metadata:
  brainstorm-toolkit-applies-to: claude copilot codex
---

# Network Engineer

Domain knowledge for network-security audits driven by Batfish (parsed configs)
+ vendor PSIRT feeds (CVE source of truth) + optional Qualys cross-reference.

## What this skill is — and isn't

**Is:** the methodology for ranking findings, the rubric for "overpermissive",
the patterns for joining a CVE advisory to a Batfish-derivable config fact.

**Isn't:** the data layer. This skill assumes the consumer repo has:

- `scripts/batfish_query.py` — pybatfish wrapper (snapshot mgmt + question runner)
- `scripts/psirt_fetch.py` — pulls Cisco openVuln, Arista advisories RSS, PaloAlto
  Security Advisories, etc., into a normalized JSON shape
- (optional) `scripts/qualys_xref.py` — pulls vuln scan results to cross-check

If those don't exist, this skill won't work — surface that to the user and
stop. Don't fabricate data.

## Why PSIRT + Batfish beats Qualys alone

Qualys (or any vuln scanner) tells you: *CVE-2026-X applies to Cisco IOS-XE
17.3.1 and you have 14 of those.*

Batfish + PSIRT tells you: *of those 14 devices, only 6 have the vulnerable
feature enabled in config (`ip http server`, BGP graceful-restart, the WebUI
module mentioned in the advisory).* The other 8 are not exploitable as
deployed.

That intersection — **CVSS × exploitability-by-config × blast-radius** — is the
ranking signal Qualys cannot produce on its own. Always compute it; never just
re-emit the Qualys list.

## Stage contract (skill-as-methodology, agent-as-orchestrator)

The `network-sec` agent (Claude only) fans these out in parallel sub-agents.
On Copilot/Codex run them sequentially.

```
Stage 1: inventory      → Batfish parse-status + node properties
Stage 2: CVE pull       → PSIRT feeds for every (vendor, OS) in inventory
Stage 3: overpermissive → Batfish reachability/ACL queries against the rubric
Stage 4: rank + report  → join 1+2+3, sort by computed risk, emit markdown
```

Each stage writes to `plans/network-audit-<timestamp>/<stage>.json`. Stage 4
reads all three and emits `report.md`.

## Stage 1 — Inventory (Batfish)

```
python3 scripts/batfish_query.py --snapshot <name> --question initIssues --json
python3 scripts/batfish_query.py --snapshot <name> --question nodeProperties \
    --properties "Configuration_Format,Vendor_Family,Vrfs,Hostname" --json
```

If `initIssues` reports parse failures > 5% of nodes, **stop and surface** —
findings on a half-parsed snapshot will lie about coverage.

## Stage 2 — CVE pull (PSIRT)

Per (vendor, OS-family, OS-version) tuple from Stage 1:

```
python3 scripts/psirt_fetch.py --vendor cisco   --os ios-xe   --version 17.3.1
python3 scripts/psirt_fetch.py --vendor arista  --os eos      --version 4.30.1F
python3 scripts/psirt_fetch.py --vendor paloalto --os panos   --version 11.1.0
```

Normalized output shape (one record per CVE):

```json
{
  "cve": "CVE-2026-XXXX",
  "cvss": 9.8,
  "vendor": "cisco",
  "os_family": "ios-xe",
  "affected_versions": ["17.3.1", "17.3.2"],
  "vulnerable_feature": "ip http server",
  "batfish_question_hint": "nodeProperties properties=HTTP_Server_Enabled"
}
```

The `vulnerable_feature` + `batfish_question_hint` fields are the bridge to
Stage 3 — they tell Stage 3 which Batfish question proves a device is *actually*
exposed, not just *running an affected version*.

## Stage 3 — Overpermissive sweep (Batfish)

Run the rubric below against parsed ACLs, security policies, and reachability.
Use Batfish's `searchFilters`, `reachability`, and `testFilters` questions.

### TODO (USER): Severity rubric — fill in the rows

Replace the placeholder rows. Each row defines (a) what evidence Batfish must
return for the row to fire, (b) the base severity, (c) the multiplier for
blast-radius / sensitive-zone reach.

| Pattern | Batfish evidence | Base severity | Blast-radius multiplier |
|---|---|---|---|
| `any → any:any` permit on edge ACL | `searchFilters` returns flow with src=`0.0.0.0/0`, dst=`0.0.0.0/0`, action=PERMIT | high | × hosts reachable from internet |
| _TODO row 2 — e.g. mgmt-VRF reachable from corp_ | _TODO_ | _TODO_ | _TODO_ |
| _TODO row 3 — e.g. SCADA segment ingress from non-OT zone_ | _TODO_ | _TODO_ | _TODO_ |
| _TODO row 4 — e.g. shadow rule (rule above makes this rule unreachable)_ | _TODO_ | _TODO_ | _TODO_ |
| _TODO row 5 — e.g. unused rule (no hits in N days)_ | _TODO_ | _TODO_ | _TODO_ |

Why this is the user-contribution slot: the *zones that matter* (SCADA, PCI,
mgmt-VRF, DMZ, jump hosts) and the *risk weights* you assign are network-
specific. A generic rubric ranks every "any-any" the same; yours should rank
"any-any reaching the SCADA jump host" 10× higher than "any-any reaching a
read-only DNS resolver."

### TODO (USER): Overpermissive checklist — fill in the criteria

Each item below is a check Stage 3 runs; the user fills in the threshold that
counts as "overpermissive" *for this network*.

- [ ] ACL line with `any` source AND `any` service → severity ≥ ???
- [ ] ACL line whose destination CIDR contains > ???? hosts
- [ ] Service permit list with > ?? distinct ports
- [ ] _TODO — your network's specific anti-patterns_
- [ ] _TODO_

## Stage 4 — Rank + report

Join Stages 1+2+3. For each (device, CVE) pair compute:

```
risk = cvss
     × (1 if Stage-3 confirms vulnerable_feature is enabled, else 0.2)
     × log10(reachable_hosts_from_untrusted_zones + 10)
```

Then sort descending. Emit `report.md` with this shape:

```markdown
# Network Security Findings — <snapshot>

## Critical (risk ≥ 8.0)
- **CVE-2026-XXXX** on 14 Cisco IOS-XE 17.3.1 devices
  - Vulnerable feature confirmed enabled on **6 of 14**
  - Exposed: mgmt-VRF reachable from corp on 4 of 6
  - Devices: edge-rtr-{01,02,03,07,11,14}
  - PSIRT: <url>

## Overpermissive — top 10 by blast radius
- **acl-edge-101 line 47**: `permit ip any 10.0.0.0/8 any`
  - Reaches: 4,200 hosts, 38 services
  - Also matches Stage-3 rubric row "any-any to internal subnet"
  - Last hit (Qualys flow telemetry): N days ago

## Coverage caveats
- 3 of 247 devices failed to parse — see Stage 1 initIssues
- PSIRT feeds last refreshed: <timestamp>
```

## Bug-bounty / red-team mode

Same pipeline, different output. Add `--bounty` to Stage 4. The report
foregrounds:

1. Devices reachable from the public internet whose OS has a known unauth-RCE
   CVE (CVSS ≥ 9.0) AND whose Stage-3 sweep confirms the vulnerable feature.
2. Lateral-movement chains: A → B → C where each hop is permitted by an
   overpermissive rule and any node has an unpatched LPE/auth-bypass CVE.

Anything else (info-disclosure, low-CVSS) is suppressed — bounty triage wants
the smallest possible high-signal list.

## Project config

Read `.claude/project.json` for these optional keys:

```json
{
  "network": {
    "batfish_snapshot": "prod-snapshot-name",
    "psirt_vendors": ["cisco", "arista", "paloalto", "fortinet", "juniper"],
    "qualys_xref": true,
    "trusted_zones": ["mgmt-vrf", "ot-scada"],
    "untrusted_zones": ["internet", "guest-wifi", "vendor-vpn"]
  }
}
```

If `network.*` is missing, prompt the user once for the snapshot name and run
with vendor list = inferred from Stage 1 inventory.

## Cross-tool notes

- **Claude:** invoke via the `network-sec` agent for parallel-stage execution.
- **Copilot / Codex:** invoke this skill directly; it walks the four stages
  sequentially. No parallelism, but otherwise identical output.
