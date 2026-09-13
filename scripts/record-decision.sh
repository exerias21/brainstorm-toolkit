#!/usr/bin/env bash
# brainstorm-toolkit — the ONE place that writes a decision to DECISIONS.md.
#
# WHY THIS EXISTS: the envelope records WHAT happened (stages, verdicts, files),
# TASKS.md records WHAT IS LEFT, GOTCHAS.md records WHAT BIT US, CLAUDE.md
# records HOW TO WORK HERE. Nothing records WHY WE CHOSE X OVER Y -- that lives
# only in the chat transcript and dies with the context window. A fresh session
# then re-litigates a settled call, or worse, quietly reverses it.
#
# WHY NOT A SESSION TRANSCRIPT: a transcript is the model grading its own
# homework. In the run this was built from, the model's own summaries were
# materially wrong four separate times ("61 tests green" when the suite was
# Windows-only and four tests structurally could not fail; "chmod 0600 applied"
# when it is a no-op on Windows; "it ran through the toolkit" when zero of nine
# stage templates were opened). Every one was caught by RUNNING something, never
# by re-reading a claim. A transcript would have preserved all four as facts and
# handed them to the next session with more authority than they earned. So this
# file records decisions with PROVENANCE -- a command, an exit code, a file:line,
# a measured number -- and refuses to be a narrative.
#
# Markdown, not JSON, for the same reason TASKS.md and GOTCHAS.md are markdown:
# the file is the contract, greppable and diffable, and a script emits the JSON
# view. `record-decision.sh json` is that view.
#
# Two subcommands:
#
#   record-decision.sh add --title T --why W [--rejected R] [--evidence E]
#                          [--slug S] [--file DECISIONS.md] [--dry-run]
#     Appends one block. Idempotent on --title: re-adding an existing title is a
#     no-op (exit 0), so a re-run of a stage cannot double-write.
#
#   record-decision.sh json [--file DECISIONS.md]
#     Read-only. Emits {schema, decisions:[{date,title,slug,rejected,why,evidence}]}.
#     Never writes. Exit 0 even when the file is absent (decisions: []).
set -eu

PY=""
for c in python3 python py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'pass' >/dev/null 2>&1; then PY="$c"; break; fi
done
if [ -z "$PY" ]; then
  echo '{"error":"no working python interpreter found (tried python3, python, py)"}' >&2
  exit 1
fi

usage() {
  sed -n '25,34p' "$0" | sed 's/^# \{0,1\}//'
}

[ $# -ge 1 ] || { usage; exit 2; }
SUBCMD="$1"; shift

FILE="DECISIONS.md"
TITLE=""; WHY=""; REJECTED=""; EVIDENCE=""; SLUG=""; DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --file)     FILE="$2"; shift 2 ;;
    --title)    TITLE="$2"; shift 2 ;;
    --why)      WHY="$2"; shift 2 ;;
    --rejected) REJECTED="$2"; shift 2 ;;
    --evidence) EVIDENCE="$2"; shift 2 ;;
    --slug)     SLUG="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

PYCORE="$(mktemp)"
trap 'rm -f "$PYCORE"' EXIT
cat > "$PYCORE" <<'PYEOF'
import io, json, os, re, sys
from datetime import datetime, timezone

sub, path, title, why, rejected, evidence, slug, dry = sys.argv[1:9]
dry = dry == "1"

HEADER = """# DECISIONS.md

Why things are the way they are. One block per decision, append-only, newest last.

Written by `scripts/record-decision.sh` -- do not hand-edit the structure; a
consumer parses it. Each block answers one question a future session would
otherwise re-litigate: what was chosen, what was rejected, and why.

**Record provenance, never a claim.** "122 tests pass (`python -m pytest tests/
-q`, exit 0)" is durable. "Phase 2 works" is a liability -- a self-report that a
later session will trust more than it deserves.
"""

BLOCK_RE = re.compile(
    r'^##\s+(?P<date>\d{4}-\d{2}-\d{2})\s+[-—]\s+(?P<title>.+?)\s*$', re.M)


def read(p):
    try:
        with io.open(p, encoding='utf-8') as f:
            return f.read()
    except OSError:
        return ""


def parse(text):
    out = []
    marks = list(BLOCK_RE.finditer(text))
    for i, m in enumerate(marks):
        body = text[m.end(): marks[i + 1].start() if i + 1 < len(marks) else len(text)]

        def field(name):
            fm = re.search(r'^-\s+\*\*' + name + r':\*\*\s*(.+?)\s*$', body, re.M)
            return fm.group(1).strip() if fm else None
        out.append({
            "date": m.group("date"),
            "title": m.group("title").strip(),
            "slug": field("slug"),
            "rejected": field("rejected"),
            "why": field("why"),
            "evidence": field("evidence"),
        })
    return out


text = read(path)

if sub == "json":
    print(json.dumps({"schema": 1, "file": path, "decisions": parse(text)}, indent=2))
    raise SystemExit(0)

# --- add ---
if not title or not why:
    print("add requires --title and --why", file=sys.stderr)
    raise SystemExit(2)

existing = parse(text)
if any(d["title"].lower() == title.lower() for d in existing):
    print(f"skip: a decision titled {title!r} is already recorded")
    raise SystemExit(0)

date = datetime.now(timezone.utc).strftime("%Y-%m-%d")
lines = [f"\n## {date} — {title}\n"]
if slug:
    lines.append(f"- **slug:** {slug}\n")
if rejected:
    lines.append(f"- **rejected:** {rejected}\n")
lines.append(f"- **why:** {why}\n")
if evidence:
    lines.append(f"- **evidence:** {evidence}\n")
block = "".join(lines)

if dry:
    print(block, end="")
    raise SystemExit(0)

new = (text if text.strip() else HEADER) + block
tmp = path + ".tmp"
try:
    with io.open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(new)
    os.replace(tmp, path)
except OSError as e:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    print(f"error: could not write {path}: {e}", file=sys.stderr)
    raise SystemExit(1)
print(f"recorded: {title}  -> {path}")
PYEOF

case "$SUBCMD" in
  add|json) ;;
  *) usage; exit 2 ;;
esac

"$PY" "$PYCORE" "$SUBCMD" "$FILE" "$TITLE" "$WHY" "$REJECTED" "$EVIDENCE" "$SLUG" "$DRY_RUN"
