# Secret scan (shared)

Canonical for `/sdlc-lite` Stage 6 (gating posture: warn, never refuse) and `/sdlc-lite`
Stage 6 (warn-only, never blocks). Run it over the changed files before the terminal
stage.

**Secret scan** the files about to be staged. Skip only if `pipeline.skip_secret_scan: true`
in `.claude/project.json` (e.g., a security research repo where false positives dominate).

Prefer `gitleaks` if available:
```bash
if command -v gitleaks >/dev/null 2>&1; then
  gitleaks detect --no-git --source . --report-format json --report-path /tmp/gitleaks-{feature-slug}.json --exit-code 0 -- {specific files}
fi
```

If `gitleaks` is not installed, run a fallback regex sweep on the same file list for these
high-signal patterns: `AKIA[0-9A-Z]{16}` (AWS access key), `aws_secret_access_key\s*=`,
`-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----`, `xox[baprs]-[0-9a-zA-Z]{10,}` (Slack),
`sk-[a-zA-Z0-9]{20,}` (OpenAI/Anthropic-style), `ghp_[a-zA-Z0-9]{36}` (GitHub PAT),
`gh[osu]_[a-zA-Z0-9]{36}` (GitHub OAuth/server/user tokens),
`(?i)(api[_-]?key|secret|token|password)\s*[:=]\s*['\"][^'\"]{12,}['\"]`.

**Policy — warn-only, never blocks commit or push**:
- Any finding (HIGH, MEDIUM, LOW, or regex-fallback match) → record file
  and line, surface in the PR body, and **proceed** with stage + commit.
  This pipeline does not refuse to commit on a secret-scan finding alone.
- HIGH findings get a `⚠ HIGH:` prefix and a one-line note that GitHub
  Push Protection (on public remotes) may still reject the push even
  though this skill did not. The user can scrub-and-recommit or push to a
  private remote (e.g., Tailscale-backed internal git) at their discretion.
- If the regex fallback fires, treat all matches as HIGH for reporting purposes
  (no severity distinction in the fallback) — same warn-only behavior.

Record the scan tool used and finding count in the PR body so reviewers know a scan ran.

**No sidecar.** The scan never gates (status was always `pass`) and nothing ever read
`secret-scan.json`. Report findings inline and append `secret-scan` to
`run.json.stages_completed`; that is what every consumer actually reads.

