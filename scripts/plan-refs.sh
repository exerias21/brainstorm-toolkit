#!/usr/bin/env bash
# brainstorm-toolkit -- deterministic detector for plan/task references written into code.
#
# WHY THIS IS A SCRIPT: the prose guard ("never write plan or task references into code") sits
# in every code-writing dispatch prompt, and a model that forgets it -- or reads "comments" and
# writes the reference into a string literal instead -- is exactly the case prose cannot catch.
# This scan reads only the added lines, so references already in the repo never block a run.
#
#   plan-refs.sh scan --base <commit> [--slug <plan-slug>] [--file TASKS.md]
#     Scans ADDED lines (`git diff -U0 <base>` plus untracked files in full) in code files only
#     (not *.md/*.mdx/*.txt/*.rst, plans/, docs/plans/, TASKS.md, GOTCHAS.md, DECISIONS.md,
#     ACTION_ITEMS.md, CHANGELOG*, .claude/). Prints {hits:[{file,line,text,pattern}],
#     scanned_files:N} on stdout. Read-only. Exits 0 always -- the caller decides what a hit means.
set -u
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SUBCMD="${1:-}"
[ "$#" -gt 0 ] && shift
BASE=""; SLUG=""; TFILE="TASKS.md"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --base) BASE="${2:-}"; shift 2 ;;
    --slug) SLUG="${2:-}"; shift 2 ;;
    --file) TFILE="${2:-}"; shift 2 ;;
    *) echo "plan-refs.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [ "$SUBCMD" != "scan" ] || [ -z "$BASE" ]; then
  echo "usage: plan-refs.sh scan --base <commit> [--slug <plan-slug>] [--file TASKS.md]" >&2
  exit 2
fi
PYCORE="$(mktemp)"
trap 'rm -f "$PYCORE"' EXIT
cat > "$PYCORE" <<'PYEOF'
import json, os, re, shutil, subprocess, sys

base, slug, tfile = sys.argv[1], sys.argv[2], sys.argv[3]
GIT = shutil.which("git") or "git"

def git(*args):
    p = subprocess.run([GIT, "-c", "core.quotepath=off"] + list(args), capture_output=True)
    return p.returncode, p.stdout.decode("utf-8", errors="replace")

SKIP_EXT = {".md", ".mdx", ".txt", ".rst"}
SKIP_NAMES = {"tasks.md", "gotchas.md", "decisions.md", "action_items.md"}
SKIP_PREFIX = ("plans/", "docs/plans/", ".claude/")
tbase = os.path.basename(tfile).lower()

def skipped(path):
    p = path.replace("\\", "/")
    name = os.path.basename(p).lower()
    if os.path.splitext(name)[1] in SKIP_EXT:
        return True
    if name in SKIP_NAMES or name == tbase or name.startswith("changelog"):
        return True
    return p.startswith(SKIP_PREFIX)

PATTERNS = [
    ("plan-path", re.compile(r"plans/[\w./-]+\.md")),
    ("tasks-row", re.compile(r"TASKS\.md:\d+")),
    ("task-id", re.compile(r"\btask-\d+\b")),
    ("phase-of-plan", re.compile(r"\b(?:phase|step) \d+ of (?:the )?plan\b", re.I)),
]
# A plan is named by its file stem (brainstorm-/team-brainstorm- prefixes included). Only a stem
# that EXISTS in plans/ or docs/plans/ counts, so "brainstorm-toolkit" in code is not a hit;
# hyphenless stems ("ui", "index") are skipped as ordinary words, and so is a stem that is also
# a file or directory name in the repo (a plan named after the module or skill it changes).
stems = set()
for d in ("plans", os.path.join("docs", "plans")):
    try:
        for n in os.listdir(d):
            if n.endswith(".md") and "-" in n[:-3]:
                stems.add(n[:-3])
    except OSError:
        pass
if stems:
    rc, out = git("ls-files")
    if rc == 0:
        names = set()
        for f in out.splitlines():
            if f.startswith(("plans/", "docs/plans/")):
                continue
            for part in f.split("/"):
                names.add(part)
                names.add(os.path.splitext(part)[0])
        stems -= names
if stems:
    alt = "|".join(re.escape(x) for x in sorted(stems, key=len, reverse=True))
    PATTERNS.append(("brainstorm-name", re.compile(r"(?<![\w-])(?:" + alt + r")(?![\w-])")))
if slug:
    PATTERNS.append(("slug", re.compile(r"(?<![\w-])" + re.escape(slug) + r"(?![\w-])")))

added = {}  # path -> [(lineno, text)]
rc, out = git("diff", "-U0", "--no-color", "--no-ext-diff", base)
cur, ln = None, 0
for raw in out.split("\n"):
    raw = raw.rstrip("\r")
    if raw.startswith("+++ "):
        cur = None if raw == "+++ /dev/null" else raw[6:] if raw.startswith("+++ b/") else raw[4:]
    elif raw.startswith("@@"):
        m = re.search(r"\+(\d+)", raw)
        ln = int(m.group(1)) if m else 0
    elif cur and raw.startswith("+") and not raw.startswith("+++"):
        added.setdefault(cur, []).append((ln, raw[1:]))
        ln += 1
rc, out = git("ls-files", "--others", "--exclude-standard")
for path in [p for p in out.split("\n") if p.strip()]:
    path = path.rstrip("\r")
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError:
        continue
    if b"\0" in data[:8192]:
        continue
    lines = data.decode("utf-8", errors="replace").split("\n")
    added[path] = [(i + 1, l.rstrip("\r")) for i, l in enumerate(lines)]

hits, scanned = [], 0
for path in sorted(added):
    if skipped(path):
        continue
    scanned += 1
    for lineno, text in added[path]:
        for name, rx in PATTERNS:
            if rx.search(text):
                hits.append({"file": path, "line": lineno, "text": text.strip()[:200], "pattern": name})
print(json.dumps({"hits": hits, "scanned_files": scanned}, ensure_ascii=False))
PYEOF
bash "$SELF_DIR/py.sh" "$PYCORE" "$BASE" "$SLUG" "$TFILE"
exit 0
