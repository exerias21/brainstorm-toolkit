#!/usr/bin/env python
"""The parallel-orchestration event stream and its per-day report.

runner.sh, merge-queue.sh, lanes.sh and lease.sh append to
<state>/events.v1.jsonl, one JSON object per line. Every field of every type is
declared in FIELDS with a validator: a value that does not pass becomes null (or
"other"), and an undeclared field is dropped. That table is what keeps free
text, command text and file paths out of the stream.

CLI (always exits 0: a lost event must never fail the script that emits it):
  events.py emit <state> <type> [key=value ...]
  events.py queue <state> <main> key=value ... branches...   (after `--`)
"""
import glob
import json
import os
import re
import subprocess
import sys
import time
import uuid

SCHEMA = "opa.event/1"
REPORT_SCHEMA = "opa.report/1"
FILE = "events.v1.jsonl"

RESUME_REASONS = ("review_fix", "tests_failed", "denial", "rotate", "operator", "other")
SHAPES = ("git_commit", "git_add", "chained", "redirect_or_heredoc", "sed_inplace",
          "protected_path", "lanes_path_write", "read_cmd", "other")
QUEUE_RESULTS = ("landed", "dry-run", "nothing", "tests-failed", "flake-limit", "conflict",
                 "rebase-failed", "setup-failed", "protected-tests", "refused-no-tests",
                 "refused-config", "refused-target-dirty", "refused-review",
                 "refused-migration", "refused-target-worktree", "target-moved", "other")


def _token(pattern, fallback=None):
    rx = re.compile(pattern)

    def check(v):
        if v is None or v == "":
            return None
        return v if isinstance(v, str) and rx.fullmatch(v) else fallback
    return check


def _enum(values, fallback=None):
    def check(v):
        if v is None or v == "":
            return None
        return v if v in values else fallback
    return check


def _int(v):
    try:
        return None if isinstance(v, bool) or v is None else int(v)
    except (TypeError, ValueError, OverflowError):
        return None


def _num(v):
    try:
        if isinstance(v, bool) or v is None:
            return None
        n = float(v)
    except (TypeError, ValueError):
        return None
    return round(n, 6) if n == n and abs(n) != float("inf") else None


def _bool(v):
    if isinstance(v, bool):
        return v
    return {"true": True, "false": False}.get(v)


NAME = _token(r"[A-Za-z0-9_][A-Za-z0-9._-]{0,127}")
SHA = _token(r"[0-9a-f]{7,64}")
_TS = _token(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ")

ENVELOPE = {"lane_id": NAME, "runner": NAME, "attempt": _int}
FIELDS = {
    "lane.opened": {"area": NAME, "base_sha": SHA},
    "lane.closed": {"area": NAME, "base_sha": SHA, "forced": _bool},
    "runner.call": {"mode": _enum(("fresh", "resume")),
                    "resume_reason": _enum(RESUME_REASONS, "other"),
                    "model": _token(r"[A-Za-z0-9][A-Za-z0-9._:\[\]-]{0,63}", "other"),
                    "num_turns": _int, "context_tokens": _int, "cost_delta_usd": _num,
                    "is_error": _bool, "rc": _int, "denials": _int},
    "runner.denial": {"tool": _token(r"[A-Za-z][A-Za-z0-9_-]{0,63}", "other"),
                      "shape": _enum(SHAPES, "other")},
    "review.verdict": {"round": _int, "verdict": _enum(("accept", "fix", "reject")),
                       "reviewer_model": _token(r"[A-Za-z0-9][A-Za-z0-9._:\[\]-]{0,63}", "other")},
    "queue.attempt": {"result": _enum(QUEUE_RESULTS, "other"), "failed_check": NAME,
                      "flake_suspected": _bool, "duration_s": _int, "old_sha": SHA,
                      "new_sha": SHA, "batch_size": _int, "batch_index": _int},
    "lease.taken": {"resource": _token(r"[A-Za-z0-9_][A-Za-z0-9._:-]{0,63}", "other"),
                    "held_s": _int},
    "lease.released": {"resource": _token(r"[A-Za-z0-9_][A-Za-z0-9._:-]{0,63}", "other"),
                       "held_s": _int, "expired": _bool},
    "loop.tick": {"lanes_open": _int, "needs_operator": _int},
}


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def build(kind, values, ts=None):
    ev = {"schema": SCHEMA, "event_id": uuid.uuid4().hex, "ts": _TS(ts) or now(), "type": kind}
    for key, check in list(ENVELOPE.items()) + list(FIELDS[kind].items()):
        ev[key] = check(values.get(key))
    return ev


def append(state, line):
    """One write() on an O_APPEND descriptor, under a mkdir lock because
    O_APPEND alone is not reliable on network and /mnt drives."""
    os.makedirs(state, exist_ok=True)
    lock = os.path.join(state, "events.lock")
    held = False
    for _ in range(200):
        try:
            os.mkdir(lock)
            held = True
            break
        except FileExistsError:
            try:
                if time.time() - os.stat(lock).st_mtime > 30:
                    os.rmdir(lock)
                    continue
            except OSError:
                pass
            time.sleep(0.01)
        except OSError:
            break
    try:
        fd = os.open(os.path.join(state, FILE), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            os.write(fd, line.encode("utf-8"))
        finally:
            os.close(fd)
    finally:
        if held:
            try:
                os.rmdir(lock)
            except OSError:
                pass


def emit(state, kind, values, ts=None):
    try:
        append(state, json.dumps(build(kind, values, ts), separators=(",", ":")) + "\n")
    except Exception as exc:  # never fail the caller
        sys.stderr.write("events.py: warning: event not recorded (%s)\n" % type(exc).__name__)


def read_jsonl(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                if isinstance(d, dict):
                    yield d
    except OSError:
        return


# ── lanes ───────────────────────────────────────────────────────────────────

def _git(cwd, *args):
    try:
        p = subprocess.run(["git", "-C", cwd] + list(args), capture_output=True, text=True)
    except OSError:
        return ""
    return p.stdout.strip() if p.returncode == 0 else ""


def lane_id_at(path, name):
    """The id `lanes.sh create` stored in the lane's git dir; a lane made before
    ids existed is known by its name."""
    gitdir = _git(path, "rev-parse", "--absolute-git-dir")
    try:
        with open(os.path.join(gitdir, "lane-id"), encoding="utf-8") as f:
            return f.read().split()[0]
    except (OSError, IndexError):
        return name


def lane_of_dir(path):
    """lane_id of the lane worktree holding `path`, else None."""
    branch = _git(path, "symbolic-ref", "--quiet", "--short", "HEAD") if path else ""
    return lane_id_at(path, branch[5:]) if branch.startswith("lane/") else None


def lane_of_branch(main, branch):
    """lane_id for branch lane/<name>, else None."""
    if not branch.startswith("lane/"):
        return None
    path = None
    for line in _git(main, "worktree", "list", "--porcelain").splitlines():
        if line.startswith("worktree "):
            path = line[9:]
        elif line == "branch refs/heads/" + branch:
            return lane_id_at(path, branch[5:])
    return branch[5:]


def queue_attempt(state, main, values, branches, ts=None):
    """One queue.attempt per branch, so each lane's landing can be joined."""
    prior = {}
    for ev in read_jsonl(os.path.join(state, FILE)):
        if ev.get("type") == "queue.attempt":
            prior[ev.get("lane_id")] = prior.get(ev.get("lane_id"), 0) + 1
    check = values.get("failed_check") or ""
    for i, branch in enumerate(branches):
        lane = lane_of_branch(main, branch)
        emit(state, "queue.attempt", dict(
            values, lane_id=lane, attempt=prior.get(lane, 0) + 1 if lane else None,
            failed_check=check.rsplit("/", 1)[-1], batch_size=len(branches), batch_index=i), ts)


# ── denial shapes ───────────────────────────────────────────────────────────

PROTECTED = re.compile(r"(^|[\s/=>'\"])(\.claude/(hooks/|settings[\w.]*\.json|project\.json)"
                       r"|[\w.-]*\.env(?![\w-])|\.git/)")
LANE_CLAUDE = re.compile(r"\.lanes/[^/\s]+/\.claude/")
GIT = r"\bgit(?:\s+-[Cc]\s+\S+|\s+--[\w-]+(?:=\S+)?)*\s+"
READ = re.compile(r"\s*(?:(?:ls|cat|head|tail|grep|rg|find|wc|stat|file|tree|pwd|which|du)\b|"
                  + GIT + r"(?:status|log|diff|show|branch|check-ignore|ls-files|rev-parse)\b)")


def denial_shape(tool, tool_input, cwd=None):
    """An enum describing a denied call. The input itself is never returned."""
    inp = tool_input if isinstance(tool_input, dict) else {}
    lane_dir = (cwd or "").rstrip("/") + "/.claude/"
    if tool in ("Write", "Edit", "MultiEdit", "NotebookEdit"):
        path = str(inp.get("file_path") or inp.get("notebook_path") or "").replace("\\", "/")
        if PROTECTED.search(path):
            return "protected_path"
        in_lane = cwd and ".lanes/" in lane_dir and path.startswith((lane_dir, ".claude/"))
        return "lanes_path_write" if LANE_CLAUDE.search(path) or in_lane else "other"
    if tool != "Bash":
        return "other"
    cmd = str(inp.get("command") or "").strip()
    # Operators inside a quoted argument (a commit message) are not operators.
    bare = re.sub(r"'[^']*'|\"(?:\\.|[^\"\\])*\"", " Q ", cmd)
    bare = re.sub(r"\d?>&\d|(?:\d|&)?>\s*/dev/null", " ", bare)
    redirect = "<<" in bare or ">" in bare
    writes = redirect or re.search(r"\b(tee|cp|mv|rm|touch|mkdir|chmod|ln)\b|\bsed\s+(-\w+\s+)*-i", bare)
    if writes and PROTECTED.search(cmd):
        return "protected_path"
    if writes and LANE_CLAUDE.search(cmd):
        return "lanes_path_write"
    if redirect:
        return "redirect_or_heredoc"
    if re.search(r"&&|\|\||[;|\n]|(?<!&)&(?!&)", bare):
        return "chained"
    if re.match(r"sed\b.*\s(-\w*i|--in-place)", bare):
        return "sed_inplace"
    if re.match(GIT + r"commit\b", bare):
        return "git_commit"
    if re.match(GIT + r"add\b", bare):
        return "git_add"
    return "read_cmd" if READ.match(bare) else "other"


# ── report ──────────────────────────────────────────────────────────────────

def _legacy_calls(state):
    for path in sorted(glob.glob(os.path.join(state, "runners", "*", "events.jsonl"))):
        runner = os.path.basename(os.path.dirname(path))
        totals = {}
        for ev in read_jsonl(path):
            cum = _num(ev.get("session_cost_usd", ev.get("cost_usd"))) or 0.0
            sid = ev.get("session_id")
            prev = totals.get(sid, 0.0) if sid else 0.0
            if sid:
                totals[sid] = cum
            yield {"type": "runner.call", "ts": str(ev.get("ts") or ""), "runner": runner,
                   "lane_id": ev.get("lane_id") or runner, "mode": ev.get("mode"),
                   "cost_delta_usd": cum - prev if cum >= prev else cum,
                   "denials": _int(ev.get("denials")) or 0}


def _legacy_denials(state):
    for path in sorted(glob.glob(os.path.join(state, "runners", "*", "denials.jsonl"))):
        for ev in read_jsonl(path):
            x = ev.get("denial") if isinstance(ev.get("denial"), dict) else {}
            yield {"type": "runner.denial", "ts": str(ev.get("ts") or ""),
                   "shape": denial_shape(x.get("tool_name"), x.get("tool_input"))}


def _legacy_queue(state):
    for ev in read_jsonl(os.path.join(state, "merge-queue.jsonl")):
        flake = bool(ev.get("flake")) or ev.get("result") == "flake-limit"
        for i, branch in enumerate(str(ev.get("branch") or "").split()):
            yield {"type": "queue.attempt", "ts": str(ev.get("ts") or ""),
                   "lane_id": branch[5:] if branch.startswith("lane/") else None,
                   "result": ev.get("result"), "flake_suspected": flake, "batch_index": i}


def _records(state):
    """Stream records, plus the older files' records from before the stream
    first recorded that type. Returns (records, source)."""
    stream = [e for e in read_jsonl(os.path.join(state, FILE))
              if e.get("schema") == SCHEMA and isinstance(e.get("ts"), str)
              and isinstance(e.get("type"), str)]
    first = {}
    for e in stream:
        kind, ts = e.get("type"), e.get("ts")
        first[kind] = min(first.get(kind, ts), ts)
    records = [e for e in stream
               if e.get("type") in ("runner.call", "runner.denial", "queue.attempt")]
    used_stream, used_legacy = bool(records), False
    for kind, gate, rows in (("runner.call", "runner.call", _legacy_calls(state)),
                             ("runner.denial", "runner.call", _legacy_denials(state)),
                             ("queue.attempt", "queue.attempt", _legacy_queue(state))):
        for r in rows:
            if gate not in first or r["ts"] < first[gate]:
                records.append(r)
                used_legacy = True
    source = "mixed" if used_stream and used_legacy else "events" if used_stream else "legacy"
    return records, source


def _bucket():
    return {"calls": 0, "cost_usd": 0.0, "cost_fresh_usd": 0.0, "cost_resume_usd": 0.0,
            "calls_with_denial": 0, "shapes": {}, "landings": 0, "landings_joined": 0,
            "joined_cost_usd": 0.0, "queue_attempts": 0, "tests_failed": 0,
            "tests_failed_resumes": 0, "flakes": 0}


def _finish(b):
    shapes = b.pop("shapes")
    for k in ("cost_usd", "cost_fresh_usd", "cost_resume_usd", "joined_cost_usd"):
        b[k] = round(b[k], 6)
    b["denial_share"] = round(b["calls_with_denial"] / b["calls"], 4) if b["calls"] else None
    b["top_denial_shapes"] = [{"shape": s, "count": n} for s, n in
                              sorted(shapes.items(), key=lambda kv: (-kv[1], kv[0]))[:5]]
    b["cost_per_landing_usd"] = (round(b["joined_cost_usd"] / b["landings_joined"], 6)
                                 if b["landings_joined"] else None)
    b["tests_failed_rate"] = (round(b["tests_failed"] / b["queue_attempts"], 4)
                              if b["queue_attempts"] else None)
    return b


def day_report(state, since=None):
    """Per-UTC-day figures. A landing is charged the cost of its lane_id's calls
    since that lane's previous landing, including calls made before `since`."""
    records, source = _records(state)
    order = {"runner.call": 0, "runner.denial": 1, "queue.attempt": 2}
    records.sort(key=lambda r: (r["ts"], order[r["type"]]))
    days, total, pending = {}, _bucket(), {}
    for r in records:
        day, lane = r["ts"][:10], r.get("lane_id")
        cost = _num(r.get("cost_delta_usd")) or 0.0
        charge = None
        if r["type"] == "runner.call" and lane:
            pending[lane] = pending.get(lane, 0.0) + cost
        elif r["type"] == "queue.attempt" and r.get("result") == "landed" and lane in pending:
            charge = pending.pop(lane)
        if since and day < since:
            continue
        for b in (days.setdefault(day, _bucket()), total):
            if r["type"] == "runner.call":
                b["calls"] += 1
                b["cost_usd"] += cost
                if r.get("mode") in ("fresh", "resume"):
                    b["cost_%s_usd" % r["mode"]] += cost
                b["calls_with_denial"] += 1 if r.get("denials") else 0
                b["tests_failed_resumes"] += 1 if r.get("resume_reason") == "tests_failed" else 0
            elif r["type"] == "runner.denial":
                shape = r.get("shape") or "other"
                b["shapes"][shape] = b["shapes"].get(shape, 0) + 1
            else:
                if r.get("result") == "landed":
                    b["landings"] += 1
                    if charge is not None:
                        b["landings_joined"] += 1
                        b["joined_cost_usd"] += charge
                # A several-branch landing is one attempt and at most one flake.
                if not r.get("batch_index"):
                    b["queue_attempts"] += 1
                    b["tests_failed"] += 1 if r.get("result") in ("tests-failed", "flake-limit") else 0
                    b["flakes"] += 1 if r.get("flake_suspected") else 0
    return {"schema": REPORT_SCHEMA, "since": since, "source": source,
            "days": [dict(date=d, **_finish(days[d])) for d in sorted(days)],
            "totals": _finish(total)}


def main(argv):
    if len(argv) >= 3 and argv[0] == "emit" and argv[2] in FIELDS:
        emit(argv[1], argv[2], dict(a.split("=", 1) for a in argv[3:] if "=" in a))
    elif len(argv) >= 3 and argv[0] == "queue" and "--" in argv:
        cut = argv.index("--")
        values = dict(a.split("=", 1) for a in argv[3:cut] if "=" in a)
        queue_attempt(argv[1], argv[2], values, argv[cut + 1:], values.get("ts"))
    else:
        sys.stderr.write("events.py: bad arguments\n")


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    try:
        main(sys.argv[1:])
    except Exception as exc:
        sys.stderr.write("events.py: warning: event not recorded (%s)\n" % type(exc).__name__)
