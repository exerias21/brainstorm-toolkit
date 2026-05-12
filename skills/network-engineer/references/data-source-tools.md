# Data-Source Tools — API Contracts

The `network-engineer` skill is methodology only. It assumes the consumer repo
provides three data-layer scripts: `scripts/batfish_query.py`,
`scripts/psirt_fetch.py`, and (optional) `scripts/qualys_xref.py`. This file
documents the API endpoints, auth shapes, and JSON output contracts each
script must implement.

The skill calls these scripts; the scripts hide the API specifics. Treat this
file as the contract — if you change a script's flags or output shape, update
this file and the skill in lockstep.

---

## 1. Batfish — `scripts/batfish_query.py`

**Library:** `pybatfish` (pip install pybatfish).

**Required CLI shape:**

```
python3 scripts/batfish_query.py \
    --snapshot <snapshot-name> \
    --question <question-name> \
    [--properties <comma-sep-list>] \
    [--filters <key=value,...>] \
    --json
```

**Required questions the skill invokes:**

| Question | Purpose |
|---|---|
| `initIssues` | Parse-failure inventory; gates the run |
| `nodeProperties` | Hostname, vendor family, OS version, VRFs |
| `searchFilters` | "What flow does this filter permit/deny?" |
| `reachability` | End-to-end forwarding analysis |
| `testFilters` | Explicit per-flow test against named ACLs |

**Output shape:** stream pybatfish DataFrame as JSON-records (`df.to_json(orient='records')`).
The skill reads it directly; no further normalization required.

**Auth:** none (Batfish runs as a local Docker container or remote service the
script connects to via the pybatfish session).

---

## 2. PSIRT vendor feeds — `scripts/psirt_fetch.py`

**Required CLI shape:**

```
python3 scripts/psirt_fetch.py \
    --vendor <cisco|arista|paloalto|fortinet|juniper> \
    --os <os-family> \
    --version <version-string> \
    [--since <ISO-8601-date>] \
    --json
```

**Output shape (one CVE per record):**

```json
{
  "cve": "CVE-2026-XXXX",
  "cvss": 9.8,
  "vendor": "cisco",
  "os_family": "ios-xe",
  "affected_versions": ["17.3.1", "17.3.2"],
  "fixed_in": ["17.3.3"],
  "vulnerable_feature": "ip http server",
  "batfish_question_hint": "nodeProperties properties=HTTP_Server_Enabled",
  "advisory_url": "https://...",
  "published": "2026-04-12"
}
```

The `vulnerable_feature` and `batfish_question_hint` fields are the bridge to
Stage 3 — they tell the audit which Batfish question proves a device is
*actually* exposed, not just *running an affected version*. Not every advisory
gives you these directly; the script's job is to derive them from the
advisory text (regex/heuristic OK; perfect not required).

### 2a. Cisco — openVuln API

- **Base:** `https://apix.cisco.com/security/advisories/v2/`
- **Auth:** OAuth2 client credentials. Get key/secret at
  `https://apiconsole.cisco.com`. Token endpoint:
  `https://id.cisco.com/oauth2/default/v1/token`.
- **Useful endpoints:**
  - `GET /OSType/iosxe?version=17.3.1` — advisories affecting IOS-XE 17.3.1
  - `GET /cve/{CVE-ID}` — single advisory by CVE
  - `GET /all/firstpublished?startDate=YYYY-MM-DD&endDate=YYYY-MM-DD`
- **Rate limit:** 30 req/sec, 5000/day (as of the openVuln docs).
- **Quirk:** the OS version filter accepts a single version, not a range. To
  cover an inventory, the script must iterate.

### 2b. Arista — Security Advisories RSS

- **Feed:** `https://www.arista.com/en/support/advisories-notices/security-advisories/feed`
- **Auth:** none (public RSS).
- **Quirk:** RSS gives titles + links. The script must HTTP-GET each advisory
  page and scrape the "Affected Software" + "Affected Platforms" sections.
  Slow but reliable. Cache aggressively (per-CVE, indefinitely; advisories
  don't change after publication).

### 2c. Palo Alto — Security Advisories

- **Base:** `https://security.paloaltonetworks.com/api/`
- **Auth:** none (public; wrapper around the public advisories portal).
- **Useful endpoint:** `GET /products/PAN-OS?version=11.1.0`
- **Format:** JSON. Each advisory includes `affected_versions`, `fixed_versions`,
  and a `cwe_id` — useful for grouping.

### 2d. Fortinet — PSIRT Advisories

- **Base:** `https://www.fortiguard.com/psirt/`
- **Auth:** none for the public listing; FortiCare auth needed for the API.
- **Format:** HTML listing + per-advisory pages. The script scrapes
  the `Affected Products` table.
- **Alternative:** the public **CVE.org** mirror often has Fortinet advisories
  cross-linked; using the NVD CVE-by-vendor query (below) avoids the scrape.

### 2e. Juniper — SIRT Advisories

- **Base:** `https://supportportal.juniper.net/s/global-search/%40uri`
- **Auth:** Juniper support account required for full content; titles are public.
- **Workaround:** the script can fall back to the NVD CVE feed filtered by
  `cpe:2.3:o:juniper:junos:` if Juniper auth isn't configured.

### 2f. Fallback — NVD

When a vendor PSIRT is unavailable, fall back to the **NVD 2.0 API**:

- **Endpoint:** `https://services.nvd.nist.gov/rest/json/cves/2.0`
- **Auth:** none required, but recommended; sign up for an API key (free,
  raises rate limit from 5 req/30s to 50 req/30s).
- **CPE filter:** `?cpeName=cpe:2.3:o:cisco:ios_xe:17.3.1:*:*:*:*:*:*:*`
- **Quirk:** NVD lags vendor PSIRTs by 2–14 days. Use it as a cross-check, not
  a primary source.

---

## 3. Qualys — `scripts/qualys_xref.py` (optional)

Used to cross-check that the (device, CVE) pairs the skill ranks as critical
match what Qualys saw in its last scan — and to flag any CVEs Qualys saw that
the PSIRT path missed (and vice versa).

**Required CLI shape:**

```
python3 scripts/qualys_xref.py \
    --since <ISO-8601-date> \
    [--ips <comma-sep-list>] \
    [--severity-min 3] \
    --json
```

**Output shape (one detection record per host+QID):**

```json
{
  "ip": "10.42.1.7",
  "hostname": "edge-rtr-07",
  "qid": 38765,
  "cve_ids": ["CVE-2026-XXXX"],
  "severity": 5,
  "qds": 92,
  "first_found": "2026-04-15T03:12:00Z",
  "last_found": "2026-05-10T03:12:00Z",
  "status": "ACTIVE",
  "port": 443,
  "ssl": true
}
```

### 3a. Auth

Qualys uses **HTTP Basic** with a platform-specific subdomain. There is **no
OAuth flow** — credentials in the request, served over TLS.

```
curl -u "$QUALYS_USER:$QUALYS_PASS" \
    -H "X-Requested-With: brainstorm-toolkit" \
    "https://qualysapi.qg3.apps.qualys.com/api/2.0/fo/asset/host/vm/detection/?action=list&..."
```

The subdomain (`qg3` above) is the Qualys platform you were assigned at signup
— check the Qualys UI URL. Common values: `qg1`, `qg2`, `qg3`, `qg4` (US),
`qg1.eu`, `qg2.eu` (EU).

The `X-Requested-With` header is **required** for all Qualys API v2 calls.
Omitting it returns HTTP 400.

### 3b. The endpoint the skill needs — Host List Detection

```
GET /api/2.0/fo/asset/host/vm/detection/?action=list
    &show_results=1
    &show_qds=1                         # include Qualys Detection Score
    &show_qds_factors=1                 # exploit/threat intel signals
    &severities=3-5                     # medium / high / critical
    &output_format=JSON                 # default is XML; force JSON
    &vm_processed_after=YYYY-MM-DDTHH:MM:SSZ
    [&ips=10.0.0.0/8]                   # optional CIDR filter
    [&truncation_limit=1000]            # default 1000; pagination via id_min
```

**Pagination:** the response includes a `<warning>` block with a `URL` element
when truncated. The script must follow it (it embeds an `id_min` cursor) until
no `<warning>` is returned. **This is the single most common bug in
Qualys API integrations** — a non-paginating script silently caps at 1000
detections.

### 3c. Mapping QID → CVE

The Host List Detection response gives **QIDs** (Qualys-internal IDs), not
CVEs directly. To join with PSIRT data, the script must also pull the
**KnowledgeBase**:

```
GET /api/2.0/fo/knowledge_base/vuln/?action=list
    &ids=38765,38766,38767                  # the QIDs from the detection pull
    &details=Basic
    &output_format=JSON
```

Each KB entry includes a `<CVE_LIST>` array (zero or more CVE IDs per QID — a
single QID can map to multiple CVEs). Cache the KB pull aggressively; QIDs
don't change once published.

### 3d. Rate limits

Qualys enforces concurrency caps per subscription (typical: 2–5 concurrent
API calls; per-call rate limited via the `X-RateLimit-Remaining` header in
the response). The script should:

- Run KB pulls and Host List pulls **sequentially** (not parallel).
- Honor `X-RateLimit-ToWait-Sec` if returned.
- Cache the KB locally (it's mostly-static reference data); only re-pull QIDs
  not seen before.

### 3e. What Qualys is — and isn't — good for here

**Good for:** confirming a device that PSIRT says is vulnerable was actually
*reachable and scanned*. If PSIRT says "CVE-2026-X on 14 IOS-XE 17.3.1
devices" but Qualys shows the detection on only 9 of them, the other 5 are
either (a) not network-reachable from the Qualys scanner, or (b) suppressed
by an authentication/scan-window issue. Either way, that's a finding by
itself.

**Not good for:** the "is the vulnerable feature enabled?" question. Qualys
checks signatures and version banners, not config knobs. Batfish answers that.
Don't try to reproduce Batfish via Qualys; it doesn't have the model.

---

## 4. Reference — feed staleness defaults

The skill's "no findings = suspicious" gate (Stage 2 → Stage 4) needs to know
what "stale" means per source. Defaults:

| Source | Refresh cadence | "Stale" threshold |
|---|---|---|
| Cisco openVuln | Daily | 7 days |
| Arista RSS | On-publication | 14 days |
| Palo Alto API | Daily | 7 days |
| Fortinet | Weekly | 14 days |
| Juniper | Weekly | 14 days |
| NVD fallback | Hourly | 2 days |
| Qualys Host List | Per scan window (often 7d) | 14 days |

Override these in `.claude/project.json` under `network.feed_staleness_days`
if your environment differs.
