#!/usr/bin/env python3
"""Container / process log auditor.

Dual-mode: parses JSON (structured logs) and raw text. Extracts multi-line
tracebacks, classifies by severity/category, deduplicates, and outputs
structured JSON or human-readable text.

The log-fetch command is configurable via --log-command. The default assumes
`docker compose`, but it works with any shell command that prints logs to
stdout. Use {service} as a placeholder in the command — it will be substituted
with each service name from --services.

Usage:
    python scripts/check_docker_logs.py --services api web --output json
    python scripts/check_docker_logs.py --log-command "kubectl logs deploy/{service} --tail=200" --services api
    python scripts/check_docker_logs.py --input ./logs.txt --output json
    python scripts/check_docker_logs.py --services api --baseline ./known_issues.json
"""

import argparse
import json
import re
import subprocess
import sys
from datetime import datetime


# ── Error patterns ──────────────────────────────────────────────────────────

BACKEND_PATTERNS = [
    # Critical — app broken
    {"pattern": r"ModuleNotFoundError", "severity": "critical", "category": "API"},
    {"pattern": r"ImportError", "severity": "critical", "category": "API"},
    {"pattern": r"SyntaxError", "severity": "critical", "category": "API"},
    {"pattern": r"IndentationError", "severity": "critical", "category": "API"},
    {"pattern": r"Application startup.*failed|cannot start", "severity": "critical", "category": "DOCKER"},
    {"pattern": r"OperationalError.*could not connect", "severity": "critical", "category": "DB"},
    # High — functionality broken
    {"pattern": r"sqlalchemy\.exc\.\w+Error", "severity": "high", "category": "DB"},
    {"pattern": r"MissingGreenlet", "severity": "high", "category": "DB"},
    {"pattern": r"asyncpg\.\w+Error", "severity": "high", "category": "DB"},
    {"pattern": r"IntegrityError", "severity": "high", "category": "DB"},
    {"pattern": r"TypeError:", "severity": "high", "category": "API"},
    {"pattern": r"AttributeError:", "severity": "high", "category": "API"},
    {"pattern": r"KeyError:", "severity": "high", "category": "API"},
    {"pattern": r"ValueError:", "severity": "high", "category": "API"},
    {"pattern": r"Unhandled exception", "severity": "high", "category": "API"},
    # Medium — degraded
    {"pattern": r"llm_call_failed|llm_bad_status|llm_response_truncated|LLM.*failed|LM Studio returned [45]\d\d", "severity": "medium", "category": "LLM"},
    {"pattern": r"TimeoutError|timed out", "severity": "medium", "category": "API"},
    {"pattern": r"CORS.*error|CORS.*blocked", "severity": "medium", "category": "API"},
    {"pattern": r"PermissionError", "severity": "medium", "category": "API"},
    # Low
    {"pattern": r"DeprecationWarning", "severity": "low", "category": "API"},
]

FRONTEND_PATTERNS = [
    {"pattern": r"Failed to compile|Build error|build failed", "severity": "critical", "category": "DOCKER"},
    {"pattern": r"Module not found", "severity": "critical", "category": "DOCKER"},
    {"pattern": r"TypeError:|SyntaxError:", "severity": "critical", "category": "DOCKER"},
    {"pattern": r"[Hh]ydration failed|hydration mismatch", "severity": "high", "category": "FRONTEND_NETWORK"},
    {"pattern": r"Unhandled Runtime Error", "severity": "high", "category": "FRONTEND_NETWORK"},
    {"pattern": r"ECONNREFUSED|ENOTFOUND", "severity": "medium", "category": "FRONTEND_NETWORK"},
]

# Lines to ignore (normal operational noise)
NOISE_PATTERNS = [
    r"WatchFiles detected changes",
    r"Reloading\.\.\.",
    r"Shutting down",
    r"Waiting for application",
    r"Application (startup|shutdown) complete",
    r"(Started|Finished) server process",
    r"app_starting|app_stopping",
    r"Starting Wellness App API",
    r"Uvicorn running on",
    r"Started reloader process",
    r"Will watch for changes",
    r"next dev",
    r"Starting\.\.\.",
    r"Ready in",
    r"anonymous telemetry",
    r"tsconfig\.json",
    r"target was set to",
    r"wellness-app-frontend@",
    r"> next dev",
    r"Attention: Next\.js now collects",
    r"We detected TypeScript",
    r"Compiled .* in \d+(\.\d+)?m?s",  # Normal compilation (not errors)
    r"\"(GET|POST|PUT|DELETE|PATCH|OPTIONS) .+\" (200|201|204|301|302|304)",  # Success responses
]

_noise_re = re.compile("|".join(NOISE_PATTERNS), re.IGNORECASE)


# ── Helpers ─────────────────────────────────────────────────────────────────

def _strip_prefix(line: str) -> str:
    """Strip Docker compose prefix like 'backend-1  | '."""
    return re.sub(r"^[\w-]+-\d+\s*\|\s*", "", line).strip()


def _is_noise(text: str) -> bool:
    return bool(_noise_re.search(text))


def _detect_service(line: str) -> str:
    if line.startswith("frontend"):
        return "frontend"
    if line.startswith("backend") or line.startswith("job-worker"):
        return "backend"
    return "unknown"


# ── JSON log parsing (structlog backend) ────────────────────────────────────

def _parse_json_line(clean: str, service: str) -> dict | None:
    """Try to parse a structlog JSON line. Return finding or None."""
    try:
        data = json.loads(clean)
    except (json.JSONDecodeError, ValueError):
        return None

    level = data.get("level", "").lower()
    event = data.get("event", "")
    logger_name = data.get("logger", "")
    exception = data.get("exception", "")

    # Map levels to severity
    if level in ("critical", "fatal"):
        severity = "critical"
    elif level == "error":
        severity = "high"
    elif level == "warning":
        severity = "medium"
    elif level == "info":
        # Access logs at INFO may contain HTTP errors
        http_match = re.search(r'"(?:GET|POST|PUT|DELETE|PATCH) .+" (\d{3})', event)
        if http_match:
            status = int(http_match.group(1))
            if status >= 500:
                severity = "high"
            elif status == 422:
                severity = "medium"
            elif status == 404:
                # Only flag 404 on API routes, not static
                if "/api/" in event:
                    severity = "medium"
                else:
                    return None
            else:
                return None
        else:
            return None
    else:
        return None

    # Extract category and error_code from structured fields
    category = data.get("category", "")
    error_code = data.get("error_code", "")

    # Infer category from logger name if not set
    if not category:
        if "llm" in logger_name or "llm" in event.lower():
            category = "LLM"
        elif "sqlalchemy" in event or "db" in logger_name:
            category = "DB"
        elif "uvicorn.access" in logger_name:
            category = "API"
        else:
            category = "API"

    return {
        "service": service,
        "severity": severity,
        "category": category,
        "error_code": error_code,
        "message": event[:200],
        "detail": exception[:500] if exception else None,
        "source": "json",
    }


# ── Regex log parsing (frontend, fallback) ──────────────────────────────────

def _extract_tracebacks(lines: list[str]) -> list[dict]:
    """Extract multi-line Python tracebacks."""
    tracebacks = []
    i = 0
    while i < len(lines):
        clean = _strip_prefix(lines[i])
        if "Traceback (most recent call last)" in clean:
            tb_lines = [clean]
            i += 1
            while i < len(lines):
                next_clean = _strip_prefix(lines[i])
                tb_lines.append(next_clean)
                if next_clean and not next_clean.startswith(" ") and ":" in next_clean and "File" not in next_clean:
                    break
                i += 1
            error_line = tb_lines[-1] if tb_lines else ""
            tracebacks.append({
                "service": "backend",
                "severity": "critical",
                "category": "DB" if "sqlalchemy" in error_line.lower() or "asyncpg" in error_line.lower() else "API",
                "error_code": "",
                "message": error_line[:200],
                "detail": "\n".join(tb_lines)[:500],
                "source": "plaintext",
            })
        i += 1
    return tracebacks


def _scan_regex(lines: list[str], patterns: list[dict], service: str) -> list[dict]:
    """Scan lines against regex patterns."""
    findings = []
    for line in lines:
        clean = _strip_prefix(line)
        if not clean or _is_noise(clean):
            continue
        for pat in patterns:
            if re.search(pat["pattern"], clean, re.IGNORECASE):
                findings.append({
                    "service": service,
                    "severity": pat["severity"],
                    "category": pat["category"],
                    "error_code": "",
                    "message": clean[:200],
                    "detail": None,
                    "source": "plaintext",
                })
                break  # One match per line
    return findings


def _check_http_errors(lines: list[str], service: str) -> list[dict]:
    """Extract HTTP 4xx/5xx from access log lines (regex mode).

    Handles two formats:
    - Uvicorn/nginx: "GET /path" 500
    - Next.js dev:    GET /path 500 in 234ms
    """
    findings = []
    for line in lines:
        clean = _strip_prefix(line)
        # Try uvicorn format first (quoted), then Next.js format (unquoted)
        match = re.search(r'"(GET|POST|PUT|DELETE|PATCH) ([^"]+)" (\d{3})', clean)
        if not match:
            match = re.search(r'(GET|POST|PUT|DELETE|PATCH) (\S+) (\d{3})(?: in \d+m?s)?', clean)
        if match:
            method, path, status = match.group(1), match.group(2), int(match.group(3))
            if status >= 500:
                findings.append({"service": service, "severity": "high", "category": "API", "error_code": "", "message": f"{method} {path} -> {status}", "detail": None, "source": "plaintext"})
            elif status == 422:
                findings.append({"service": service, "severity": "medium", "category": "VALIDATION", "error_code": "API_VALIDATION_ERROR", "message": f"{method} {path} -> {status}", "detail": None, "source": "plaintext"})
            elif status == 404 and "/api/" in path:
                findings.append({"service": service, "severity": "medium", "category": "API", "error_code": "API_ENDPOINT_NOT_FOUND", "message": f"{method} {path} -> {status}", "detail": None, "source": "plaintext"})
    return findings


# ── Core scanning ───────────────────────────────────────────────────────────

def scan_log_text(log_text: str, service: str) -> list[dict]:
    """Scan log text using dual-mode parsing (JSON first, regex fallback)."""
    findings = []
    regex_lines = []
    lines = log_text.split("\n")

    for line in lines:
        clean = _strip_prefix(line)
        if not clean or _is_noise(clean):
            continue

        # Try JSON first
        result = _parse_json_line(clean, service)
        if result:
            findings.append(result)
        else:
            regex_lines.append(line)

    # Regex fallback for non-JSON lines — apply all patterns (backend + frontend)
    # so a single scanner works for any service. Ordering still surfaces critical
    # issues first because patterns are sorted by severity in their list.
    patterns = BACKEND_PATTERNS + FRONTEND_PATTERNS
    findings.extend(_extract_tracebacks(regex_lines))
    findings.extend(_scan_regex(regex_lines, patterns, service))
    findings.extend(_check_http_errors(regex_lines, service))

    return findings


def get_service_logs(service: str, log_command: str, tail: int = 200) -> str:
    """Fetch logs for a service using the configured command.

    The log_command may contain {service} and {tail} placeholders.
    """
    cmd = log_command.format(service=service, tail=tail)
    try:
        result = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=30,
        )
        return result.stdout + result.stderr
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        return f"ERROR: Could not fetch {service} logs: {e}"


def deduplicate(findings: list[dict]) -> list[dict]:
    """Deduplicate findings by message prefix."""
    seen = set()
    unique = []
    for f in findings:
        key = f"{f['service']}:{f['category']}:{f['message'][:60]}"
        if key not in seen:
            seen.add(key)
            unique.append(f)
    return unique


def apply_baseline(findings: list[dict], baseline_path: str) -> list[dict]:
    """Mark findings that match known issues as baseline."""
    try:
        with open(baseline_path) as fp:
            baseline = json.load(fp)
    except (FileNotFoundError, json.JSONDecodeError):
        return findings

    accepted = baseline.get("accepted", [])
    for f in findings:
        for rule in accepted:
            pattern = rule.get("message_pattern", "")
            if pattern and re.search(pattern, f["message"], re.IGNORECASE):
                f["baseline"] = True
                break
        else:
            f["baseline"] = False
    return findings


# ── Main ────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Container / process log auditor")
    parser.add_argument("--services", nargs="+", default=[],
                        help="Service names to fetch logs for (e.g. api web worker). "
                             "If empty and no --input, no services are scanned.")
    parser.add_argument("--log-command", default="docker compose logs {service} --tail={tail}",
                        help="Command template for fetching logs per service. "
                             "Placeholders: {service}, {tail}.")
    parser.add_argument("--tail", type=int, default=200)
    parser.add_argument("--output", default="text", choices=["json", "text"])
    parser.add_argument("--input", dest="input_file", help="Read from file instead of running a command")
    parser.add_argument("--baseline", help="Path to known_issues.json")
    # Back-compat: accept --service (singular) as a shim
    parser.add_argument("--service", help=argparse.SUPPRESS)
    args = parser.parse_args()

    if args.service and not args.services:
        if args.service == "all":
            print("WARNING: --service all is deprecated; pass explicit --services names.", file=sys.stderr)
            args.services = []
        else:
            args.services = [args.service]

    all_findings = []

    if args.input_file:
        # Fixture/regression test mode — scan as a single blob using combined patterns
        with open(args.input_file) as fp:
            text = fp.read()
        all_findings.extend(scan_log_text(text, "fixture"))
    else:
        for svc in args.services:
            logs = get_service_logs(svc, args.log_command, args.tail)
            all_findings.extend(scan_log_text(logs, svc))

    # Deduplicate
    all_findings = deduplicate(all_findings)

    # Sort by severity
    severity_order = {"critical": 0, "high": 1, "medium": 2, "low": 3}
    all_findings.sort(key=lambda f: severity_order.get(f["severity"], 4))

    # Apply baseline if provided
    if args.baseline:
        all_findings = apply_baseline(all_findings, args.baseline)

    # Determine overall status
    has_critical = any(f["severity"] == "critical" and not f.get("baseline") for f in all_findings)
    has_high = any(f["severity"] == "high" and not f.get("baseline") for f in all_findings)
    status = "error" if has_critical else "warning" if has_high else "ok"

    summary = {
        "total": len(all_findings),
        "critical": sum(1 for f in all_findings if f["severity"] == "critical"),
        "high": sum(1 for f in all_findings if f["severity"] == "high"),
        "medium": sum(1 for f in all_findings if f["severity"] == "medium"),
        "low": sum(1 for f in all_findings if f["severity"] == "low"),
    }

    if args.output == "json":
        print(json.dumps({
            "status": status,
            "timestamp": datetime.now().isoformat(),
            "findings": all_findings,
            "summary": summary,
        }, indent=2))
    else:
        if not all_findings:
            print("No issues found in container logs")
            return

        print(f"{'=' * 50}")
        print(f"CONTAINER LOG AUDIT — {summary['total']} issue(s)")
        print(f"{'=' * 50}")
        for sev in ["critical", "high", "medium", "low"]:
            items = [f for f in all_findings if f["severity"] == sev]
            if items:
                print(f"\n  {sev.upper()} ({len(items)})")
                print(f"  {'─' * 40}")
                for f in items:
                    baseline = " [baseline]" if f.get("baseline") else ""
                    print(f"  [{f['service']}] {f['category']}: {f['message'][:100]}{baseline}")
                    if f.get("detail"):
                        for dl in f["detail"].split("\n")[:4]:
                            print(f"    {dl}")

        print(f"\n{'=' * 50}")
        if has_critical:
            print(f"  CRITICAL issues found — must fix before proceeding")
        elif has_high:
            print(f"  HIGH issues found — investigate")
        else:
            print(f"  Minor issues only")


if __name__ == "__main__":
    main()
