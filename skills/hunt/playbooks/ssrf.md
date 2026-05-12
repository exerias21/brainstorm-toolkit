# Playbook: ssrf — server-side request forgery

## What this hunts

Code that issues an outbound HTTP/TCP/file request to a URL or host
derived from untrusted input, without validating the destination against
an allowlist. SSRF is high-impact in cloud environments because the
metadata service (169.254.169.254, GCE metadata, Azure IMDS) often
yields credentials.

## Sweep targets

| Language | Sinks |
|---|---|
| Python | `requests.get(`, `httpx.get(`, `urllib.request.urlopen(`, `aiohttp.ClientSession`, `socket.create_connection(`, `pycurl` |
| Node | `fetch(`, `axios(`, `http.request(`, `https.request(`, `got(`, `node-fetch` |
| Go | `http.Get(`, `http.NewRequest(`, `(*http.Client).Get(`, `net.Dial(` |
| Java | `URL(...).openConnection()`, `HttpClient.newHttpClient().send(`, `RestTemplate.getForEntity` |
| Ruby | `Net::HTTP.get(`, `open(`, `URI.parse(...).read`, `Faraday` |
| PHP | `file_get_contents(http://...)`, `curl_exec`, `fopen(http://...)` |

## Vulnerable shape

```python
def fetch_avatar(req):
    url = req.GET["url"]          # attacker-controlled
    return requests.get(url).content
```

Webhook-style endpoints, image proxies, "import from URL" features,
PDF generators, and any "preview link" feature are the usual culprits.

## Safe shape

- **Allowlist hosts**: `urlparse(url).netloc in ALLOWED_HOSTS`.
- **Resolve once, then connect to the resolved IP** to defeat DNS
  rebinding. Block any IP in private ranges (10.0.0.0/8, 172.16.0.0/12,
  192.168.0.0/16, 127.0.0.0/8, 169.254.0.0/16, ::1, fc00::/7, fe80::/10).
- **Disable redirects** or re-validate the destination on each redirect.
- **Drop schemes** other than `http`/`https` (no `file://`, `gopher://`,
  `dict://`, `ftp://`).

## Suppression rules

- The URL is constructed entirely from a constant or from a column the
  user cannot influence.
- The host is constrained by a regex anchored on a constant domain
  (`^https://api\.stripe\.com/`), and redirects are disabled.
- The request goes through a network egress proxy that already enforces
  allowlisting (verify — don't trust the comment).

## Trace direction

Source (request param, message field, DB column populated by user) →
URL-construction site → HTTP client call. The taint window can be wide
— track string concatenations, f-strings, template renders, and
`URL`/`URI` builder fluent chains.

## Fix vocabulary

Introduce a `safe_outbound_get(url)` helper that resolves, checks IP
ranges, disables redirects, and limits response size. Make the raw
client unavailable (lint rule via `/codify`). For genuine flexibility
(e.g. webhook delivery), document the threat model decision and add a
network-level egress allowlist.
