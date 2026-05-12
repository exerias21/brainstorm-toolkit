#!/usr/bin/env python3
"""
Reproduction for {{finding_id}}: {{category}} at {{file}}:{{line}}

Authorized testing only. Target MUST be localhost in a disposable
sandbox environment. This script asserts the host is loopback before
sending any payload; do not edit the assertion out.

Read-only proof. The payload demonstrates the vulnerability without
causing destructive side effects (`whoami`, `SELECT @@version`,
`/etc/hostname`, time-based blind probe, etc.). If you need to escalate
the proof, do it manually and document it; this script stays read-only.
"""
import sys
import urllib.parse
import urllib.request

TARGET = "http://127.0.0.1:{{port}}"
ENDPOINT = "{{path}}"
METHOD = "{{GET|POST}}"
PAYLOAD = {{payload_repr}}  # safe, non-destructive proof payload


def assert_loopback(url: str) -> None:
    host = urllib.parse.urlparse(url).hostname or ""
    if host not in ("127.0.0.1", "localhost", "::1"):
        sys.exit(
            f"refusing to run: target {host!r} is not loopback. "
            "this PoC is sandboxed-only."
        )


def main() -> int:
    assert_loopback(TARGET)
    req = urllib.request.Request(
        TARGET + ENDPOINT,
        method=METHOD,
        data=PAYLOAD if METHOD != "GET" else None,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    with urllib.request.urlopen(req, timeout=5) as resp:
        body = resp.read().decode("utf-8", errors="replace")

    # Detection: the {{detection_hint}} below should appear in `body`
    # if the vulnerability is reachable. Adjust per finding.
    print(body[:2000])
    if {{detection_predicate}}:
        print("\n[+] vuln confirmed: {{finding_id}}")
        return 0
    print("\n[-] no detection signal — payload may need adjustment or fix is in place")
    return 1


if __name__ == "__main__":
    sys.exit(main())
