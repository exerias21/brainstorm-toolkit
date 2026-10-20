#!/usr/bin/env bash
# brainstorm-toolkit — approval ledger for operator questions.
#
# The question advisor returns the questions worth asking; the orchestrator records them here
# with `approve`, and the ask-gate hook (scripts/hooks/ask-gate.sh) calls `check` to deny any
# question that was not recorded. One script owns the normalisation and hash so both sides
# agree byte for byte.
#
#   question-advice.sh approve   stdin: the advisor's JSON object ({dropped, ask}), a JSON list of
#                                question strings, a list of objects with a "question" key, or
#                                {"questions": [...]} (an AskUserQuestion input).
#                                MERGES into .claude/pipeline/_advice/approved.json =
#                                {"approvals": {"<hash>": <epoch written_at>}}: sessions sharing a
#                                worktree must not erase each other's approvals. Entries older than
#                                45 minutes are pruned; the legacy {written_at, hashes[]} file is read.
#                                An unreadable or unknown-shaped file is refused (exit 1), never
#                                overwritten; writers serialise on an OS lock (flock / msvcrt).
#   question-advice.sh check     stdin: a PreToolUse payload. Prints `allow`, or `deny: <reason>`
#                                unless every question hash has an entry under 45 minutes old.
#
# Normalisation: strip BOM, NFKC, collapse all whitespace, trim, casefold, then sha256 of UTF-8.
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
import hashlib, json, os, re, sys, time, unicodedata

sub, proj = sys.argv[1], sys.argv[2]
MAX_AGE = 45 * 60
adv_dir = os.path.join(proj, ".claude", "pipeline", "_advice")
path = os.path.join(adv_dir, "approved.json")


def norm_hash(text):
    t = unicodedata.normalize("NFKC", str(text).lstrip("﻿"))
    t = re.sub(r"\s+", " ", t, flags=re.UNICODE).strip().casefold()
    return hashlib.sha256(t.encode("utf-8")).hexdigest()


def texts(items):
    out = []
    for it in items:
        if isinstance(it, str):
            out.append(it)
        elif isinstance(it, dict) and isinstance(it.get("question"), str):
            out.append(it["question"])
    return out


class LedgerError(Exception):
    pass


def _ts(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def read_ledger():
    """{hash: epoch}; accepts the legacy {written_at, hashes[]} shape.

    Only a missing file reads as empty. An unreadable file or an unknown shape raises
    LedgerError, so approve refuses rather than overwriting another writer's ledger. A
    single bad entry is skipped, not allowed to discard the rest."""
    try:
        with open(path, encoding="utf-8-sig") as fh:
            ap = json.load(fh)
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as e:
        raise LedgerError("unreadable %s: %s" % (path, e))
    if isinstance(ap, dict) and isinstance(ap.get("approvals"), dict):
        out = {}
        for h, t in ap["approvals"].items():
            t = _ts(t)
            if t is not None:
                out[str(h)] = t
        return out
    if isinstance(ap, dict) and "written_at" in ap and isinstance(ap.get("hashes", []), list):
        w = _ts(ap["written_at"])
        if w is None:
            raise LedgerError("legacy ledger has a non-numeric written_at")
        return {str(h): w for h in ap.get("hashes") or [] if isinstance(h, str)}
    raise LedgerError("unknown ledger shape in %s" % path)


def acquire(timeout=10.0):
    """OS-level exclusive lock on a sidecar file. The OS drops it when the holder exits, so
    there is no stale-lock break, and the lock file is never deleted: deleting it is what let
    one writer remove a lock another writer still held."""
    fh = open(path + ".lock", "a+")
    end = time.time() + timeout
    while True:
        try:
            if os.name == "nt":
                import msvcrt
                fh.seek(0)
                msvcrt.locking(fh.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fh
        except OSError:
            if time.time() > end:
                fh.close()
                return None
            time.sleep(0.05)


def release(fh):
    try:
        if os.name == "nt":
            import msvcrt
            fh.seek(0)
            msvcrt.locking(fh.fileno(), msvcrt.LK_UNLCK, 1)
        else:
            import fcntl
            fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
    except OSError:
        pass
    fh.close()


def replace_retry(src, dst):
    # Windows refuses os.replace while a reader holds dst open; that window is milliseconds.
    for i in range(20):
        try:
            os.replace(src, dst)
            return
        except PermissionError:
            if i == 19:
                raise
            time.sleep(0.05)


try:
    data = json.loads(os.environ.get("HOOK_INPUT", ""))
except Exception:
    data = None

if sub == "approve":
    if isinstance(data, dict):
        for k in ("ask", "questions"):
            if isinstance(data.get(k), list):
                data = data[k]
                break
    if not isinstance(data, list):
        print('{"error":"expected the advisor object, or a JSON list of questions"}', file=sys.stderr)
        sys.exit(1)
    new = {norm_hash(t) for t in texts(data)}
    os.makedirs(adv_dir, exist_ok=True)
    lk = acquire()
    if lk is None:
        print('{"error":"approval ledger is locked by another writer; retry"}', file=sys.stderr)
        sys.exit(1)
    try:
        try:
            led = read_ledger()
        except LedgerError as e:
            print(json.dumps({"error": str(e) + "; left untouched"}), file=sys.stderr)
            sys.exit(1)
        now = time.time()
        led = {h: t for h, t in led.items() if now - t <= MAX_AGE}
        for h in new:
            led[h] = int(now)
        tmp = "%s.%d.%s.tmp" % (path, os.getpid(), os.urandom(4).hex())
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump({"approvals": led}, fh)
        replace_retry(tmp, path)
    finally:
        release(lk)
    print(json.dumps({"approved": len(new), "path": path}))
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
    led = read_ledger()
except LedgerError as e:
    print("deny: " + str(e))
    sys.exit(0)
if not led:
    print("deny: no approved question list found")
    sys.exit(0)
now = time.time()
for q in qs:
    t = led.get(norm_hash(q))
    if t is None:
        print("deny: question not approved by the advisor: " + q[:80])
        sys.exit(0)
    if now - t > MAX_AGE or now - t < -300:
        print("deny: the approved question list is stale")
        sys.exit(0)
print("allow")
PY
