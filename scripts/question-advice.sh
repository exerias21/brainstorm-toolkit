#!/usr/bin/env bash
# brainstorm-toolkit — approval ledger for operator questions.
#
# The question advisor returns the questions worth asking; the orchestrator records them here
# with `approve`, and the ask-gate hook (scripts/hooks/ask-gate.sh) calls `check` to deny any
# question that was not recorded. One script owns the normalisation and hash so both sides
# agree byte for byte.
#
#   question-advice.sh approve   stdin: JSON list of question strings, or objects with a
#                                "question" key, or {"questions": [...]} (an AskUserQuestion input).
#                                Writes .claude/pipeline/_advice/approved.json = {written_at, hashes[]}.
#   question-advice.sh check     stdin: a PreToolUse payload. Prints `allow`, or `deny: <reason>`
#                                when a question hash is missing or the approval is over 45 minutes old.
#
# Normalisation: strip BOM, collapse all whitespace, trim, lowercase, then sha256 of UTF-8.
# Fails open on unreadable input: `check` prints `allow` for a payload it cannot parse.
set -u
SUB="${1:-}"
case "$SUB" in approve|check) ;; *) echo "usage: question-advice.sh approve|check  (JSON on stdin)" >&2; exit 2 ;; esac
input="$(cat 2>/dev/null || true)"

PROJ="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$PROJ" ]; then
  if _gr="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$_gr" ]; then PROJ="$_gr"; else PROJ="$PWD"; fi
fi
# shellcheck source=./hooks/_pyresolve.sh
. "$(dirname "${BASH_SOURCE[0]:-$0}")/hooks/_pyresolve.sh"
PY="$(hooks_resolve_python "$PROJ")" || PY=""
if [ -z "$PY" ]; then
  if [ "$SUB" = "check" ]; then echo "allow"; exit 0; fi
  echo '{"error":"no working python interpreter found"}' >&2
  exit 1
fi

HOOK_INPUT="$input" "$PY" - "$SUB" "$PROJ" <<'PY'
import hashlib, json, os, re, sys, time

sub, proj = sys.argv[1], sys.argv[2]
MAX_AGE = 45 * 60
adv_dir = os.path.join(proj, ".claude", "pipeline", "_advice")
path = os.path.join(adv_dir, "approved.json")


def norm_hash(text):
    t = str(text).lstrip("﻿")
    t = re.sub(r"\s+", " ", t, flags=re.UNICODE).strip().lower()
    return hashlib.sha256(t.encode("utf-8")).hexdigest()


def texts(items):
    out = []
    for it in items:
        if isinstance(it, str):
            out.append(it)
        elif isinstance(it, dict) and isinstance(it.get("question"), str):
            out.append(it["question"])
    return out


try:
    data = json.loads(os.environ.get("HOOK_INPUT", ""))
except Exception:
    data = None

if sub == "approve":
    if isinstance(data, dict) and isinstance(data.get("questions"), list):
        data = data["questions"]
    if not isinstance(data, list):
        print('{"error":"expected a JSON list of questions"}', file=sys.stderr)
        sys.exit(1)
    hashes = sorted({norm_hash(t) for t in texts(data)})
    os.makedirs(adv_dir, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump({"written_at": int(time.time()), "hashes": hashes}, fh)
    os.replace(tmp, path)
    print(json.dumps({"approved": len(hashes), "path": path}))
    sys.exit(0)

# check
try:
    qs = texts((data.get("tool_input") or {}).get("questions") or [])
except Exception:
    qs = []
if not qs:
    print("allow")
    sys.exit(0)
try:
    with open(path, encoding="utf-8") as fh:
        ap = json.load(fh)
    written = float(ap["written_at"])
    have = set(ap.get("hashes") or [])
except Exception:
    print("deny: no approved question list found")
    sys.exit(0)
age = time.time() - written
if age > MAX_AGE or age < -300:
    print("deny: the approved question list is stale")
    sys.exit(0)
missing = [q for q in qs if norm_hash(q) not in have]
if missing:
    print("deny: question not approved by the advisor: " + missing[0][:80])
    sys.exit(0)
print("allow")
PY
