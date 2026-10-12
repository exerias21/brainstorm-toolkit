#!/usr/bin/env bash
# brainstorm-toolkit -- renames dead .claude/project.json keys to the keys that replaced them.
#
# WHY THIS IS A SCRIPT: a hand-edit of a consumer's project.json drops comment keys, reorders
# keys or flips CRLF to LF; a rewrite has to be value-preserving, which prose cannot guarantee.
# It keeps key order, line endings, BOM, indent and trailing newline, but it is not byte-exact:
# the file is re-serialized, so an inline array or object is expanded one item per line.
# The rename table is data (project-json-renames.json, next to this script).
#
#   migrate-project-json.sh check [--file .claude/project.json]
#     Prints {file, exists, example, moves:[{old,new,value}], conflicts:[{old,new,old_value,
#     new_value}], unknown:[dotted keys absent from project.json.example]}. Read-only, exit 0.
#   migrate-project-json.sh apply [--file .claude/project.json]
#     With nothing to move: the check JSON plus "applied":[] and no write. Otherwise writes
#     <file>.bak-<YYYYmmddHHMMSS> first, then moves each value, keeping key order, line endings,
#     indent width and trailing newline. A key whose target already holds a DIFFERENT value, or
#     whose target path runs through a non-object value, is a conflict: both are left untouched.
#     Each move and each conflict is echoed to stderr. The .bak file is left for the user to delete.
#   Exit 0 ok / 1 malformed JSON / 2 usage.
set -u
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SUBCMD="${1:-}"
[ "$#" -gt 0 ] && shift
FILE=".claude/project.json"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --file) FILE="${2:-}"; shift 2 ;;
    *) echo "migrate-project-json.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
if { [ "$SUBCMD" != "check" ] && [ "$SUBCMD" != "apply" ]; } || [ -z "$FILE" ]; then
  echo "usage: migrate-project-json.sh check|apply [--file .claude/project.json]" >&2
  exit 2
fi
PYCORE="$(mktemp)"
trap 'rm -f "$PYCORE"' EXIT
cat > "$PYCORE" <<'PYEOF'
import copy, datetime, json, os, shutil, sys

mode, path, renames_path, tool_example = sys.argv[1:5]
MISSING = object()

def out(obj):
    sys.stdout.buffer.write((json.dumps(obj, ensure_ascii=False) + "\n").encode("utf-8"))

def load_json(p):
    with open(p, "rb") as fh:
        raw = fh.read()
    return raw, json.loads(raw.decode("utf-8-sig"))

def get(doc, dotted):
    cur = doc
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return MISSING
        cur = cur[part]
    return cur

def blocker(doc, dotted):
    # The first ancestor of `dotted` that is set to a non-object, or None. Writing through it
    # would replace a value the user set, so it makes the rename a conflict instead.
    cur, walked = doc, []
    for part in dotted.split(".")[:-1]:
        walked.append(part)
        if part not in cur:
            return None
        if not isinstance(cur[part], dict):
            return ".".join(walked)
        cur = cur[part]
    return None

def put(doc, dotted, value):
    parts = dotted.split(".")
    cur = doc
    for part in parts[:-1]:
        cur = cur.setdefault(part, {})
    cur[parts[-1]] = value

def drop(doc, dotted):
    parts = dotted.split(".")
    chain = [doc]
    for part in parts[:-1]:
        chain.append(chain[-1][part])
    del chain[-1][parts[-1]]
    for i in range(len(chain) - 1, 0, -1):
        if chain[i]:
            break
        del chain[i - 1][parts[i - 1]]

def plan(doc, renames):
    work = copy.deepcopy(doc)
    moves, conflicts, filled_by = [], [], {}
    for r in renames:
        old_v = get(work, r["old"])
        if old_v is MISSING:
            continue
        new_v = get(work, r["new"])
        block = blocker(work, r["new"]) if new_v is MISSING else None
        if block is not None:
            conflicts.append({"old": r["old"], "new": r["new"], "old_value": old_v,
                              "new_value": None, "blocked_by": block})
            continue
        if new_v is MISSING:
            put(work, r["new"], old_v)
            filled_by[r["new"]] = r["old"]
        elif new_v != old_v:
            c = {"old": r["old"], "new": r["new"], "old_value": old_v, "new_value": new_v}
            if r["new"] in filled_by:
                c["new_set_by"] = filled_by[r["new"]]
            conflicts.append(c)
            continue
        drop(work, r["old"])
        moves.append({"old": r["old"], "new": r["new"], "value": old_v})
    return work, moves, conflicts

def unknown_keys(user, ex, prefix=""):
    found = []
    for k, v in user.items():
        if k.startswith(("_", "//")):
            continue
        if k in ex:
            if isinstance(v, dict) and isinstance(ex[k], dict):
                found += unknown_keys(v, ex[k], prefix + k + ".")
        else:
            found.append(prefix + k)
    return found

def find_example():
    # The target repo's copy is written once and never refreshed, so it goes stale;
    # the toolkit's own template is the current key registry and wins when present.
    local = os.path.join(os.path.dirname(os.path.abspath(path)), "project.json.example")
    for cand in (tool_example, local):
        if os.path.isfile(cand):
            return cand
    return None

with open(renames_path, "rb") as fh:
    renames = json.loads(fh.read().decode("utf-8-sig"))["renames"]

report = {"file": path, "exists": os.path.isfile(path), "example": None,
          "moves": [], "conflicts": [], "unknown": []}
if not report["exists"]:
    if mode == "apply":
        report["applied"] = []
    out(report)
    sys.exit(0)

try:
    raw, doc = load_json(path)
    if not isinstance(doc, dict):
        raise ValueError("top level is not an object")
except (ValueError, OSError) as e:
    sys.stderr.write("migrate-project-json.sh: cannot parse %s: %s\n" % (path, e))
    sys.exit(1)

work, moves, conflicts = plan(doc, renames)
report["moves"], report["conflicts"] = moves, conflicts
ex_path = find_example()
if ex_path:
    report["example"] = ex_path
    try:
        report["unknown"] = unknown_keys(doc, load_json(ex_path)[1])
    except (ValueError, OSError):
        report["example"] = None

if mode == "apply":
    report["applied"] = []
    if moves:
        stamp = datetime.datetime.now().strftime("%Y%m%d%H%M%S")
        backup = path + ".bak-" + stamp
        n = 0
        while os.path.exists(backup):
            n += 1
            backup = "%s.bak-%s-%d" % (path, stamp, n)
        shutil.copyfile(path, backup)
        eol = "\r\n" if b"\r\n" in raw else "\n"
        text = raw.decode("utf-8")
        bom = text.startswith("﻿")
        if bom:
            text = text[1:]
        indent = 2
        for line in text.splitlines():
            stripped = line.lstrip(" \t")
            if stripped and stripped != line:
                lead = line[: len(line) - len(stripped)]
                indent = "\t" if lead[0] == "\t" else len(lead)
                break
        body = json.dumps(work, indent=indent, ensure_ascii=False).replace("\n", eol)
        if text.endswith("\n"):
            body += eol
        with open(path, "wb") as fh:
            fh.write((("﻿" if bom else "") + body).encode("utf-8"))
        report["applied"] = moves
        report["backup"] = backup
        for m in moves:
            sys.stderr.write("moved %s -> %s\n" % (m["old"], m["new"]))
if mode == "apply":
    for c in conflicts:
        if c.get("blocked_by"):
            sys.stderr.write("conflict: %s cannot move to %s, because %s is set to a non-object; left untouched\n"
                             % (c["old"], c["new"], c["blocked_by"]))
        else:
            by = (" (filled from %s in this run)" % c["new_set_by"]) if c.get("new_set_by") else ""
            sys.stderr.write("conflict: %s and %s%s are both set; left untouched, the new key wins\n"
                             % (c["old"], c["new"], by))
out(report)
PYEOF
bash "$SELF_DIR/py.sh" "$PYCORE" "$SUBCMD" "$FILE" "$SELF_DIR/project-json-renames.json" "$SELF_DIR/../templates/project.json.example"
exit $?
