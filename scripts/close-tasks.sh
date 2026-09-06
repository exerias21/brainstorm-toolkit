#!/usr/bin/env bash
# brainstorm-toolkit — the ONE place that flips a TASKS.md row from open to done.
#
# WHY THIS IS A SCRIPT, NOT PROSE: /sdlc's Stage 6 close-out bullet has been
# forgotten in practice, and it exists as prose in three places (the canonical
# skill + the Copilot overlay + the Codex overlay) that will drift again the
# next time one of them is edited alone. A script can't be reordered behind a
# confirm prompt (the gotcha-capture prompt used to sit BEFORE close-out, so a
# run that died there never touched TASKS.md) and can't drift between copies --
# all three runtimes invoke this file with the same one-line call.
#
# Two subcommands:
#
#   close --file TASKS.md --scope plan --key SLUG --plan-file PLAN.md [--dry-run]
#     Closes every `[~]` row (never `[ ]`/`[x]`) tagged `_plan: SLUG_`, moving
#     each to ## Done with a `_completed_at:` stamp. A row tagged with a
#     DIFFERENT `_plan:` value that still looks like it belongs to this plan
#     (its text contains the plan file's basename) is reported in `unmatched`
#     instead of guessed-closed -- this is the writer/reader key-mismatch case
#     (docs/plans/tasks-md-closeout.md step 2). Legacy rows with no `_plan:`
#     tag at all fall back to a path-substring match against --plan-file.
#     NEVER touches `[ ]` rows -- re-entry rows Stage 6 itself appends land as
#     `[ ]`, so a later `--resume` reaching Stage 6 again can never close its
#     own re-entry rows by construction.
#
#   close --file TASKS.md --scope resolved --ids-file FILE [--dry-run]
#     Closes exactly the rows matching each line of FILE (a substring unique
#     to one row -- typically the row's linked task file path). Used by
#     task-id / task-range / ad-hoc-description / queue-item runs, which
#     persist their resolved row ids at Stage 0 into
#     `run.json.data.tasks.resolved[]` precisely so this never has to guess.
#     A queue item's row NEVER shares this scope with its siblings even when
#     they share one `_plan:` key -- this is the over-closure guard.
#
#   reconcile --file TASKS.md [--pipeline-dir .claude/pipeline] [--apply] [--json]
#     Read-only by default. Reports bidirectional drift between TASKS.md and
#     the pipeline envelopes:
#       - a `[x]` row filed outside ## Done
#       - a `[ ]`/`[~]` row filed under ## Done  (TASKS.md:62 in this repo, live)
#       - a `complete`/`completed` envelope whose matched TASKS.md row(s) are
#         still open
#       - an `in_progress` envelope with no TASKS.md row referencing it at all
#     The envelope<->row join key is the envelope DIRECTORY NAME plus any of
#     `plan_file` / `input` / `data.plan_target` -- several envelopes on disk
#     in this repo wrote the latter two instead of the canonical field, so a
#     join keyed only on the canonical key would skip exactly the runs it
#     should catch.
#     `--apply` requires one external confirmation (the caller's job, mirroring
#     `/sdlc-status --prune-stale`) and then: moves a bidirectionally-drifted
#     row to the section matching its own checkbox state, and closes rows
#     belonging to a terminal envelope that still show them open. It never
#     touches an `in_progress` envelope with no matching row -- there is no
#     safe automatic fix for "orchestrator forgot to write the row."
#
# Output is always one JSON object on stdout (jq-or-python fallback, same
# probe style as scripts/hooks/run-cost-report.sh and stop-gate.sh: prove the
# interpreter RUNS, not merely that it resolves on PATH). This script does the
# real markdown-row surgery in Python (robust text handling); when Python is
# unavailable it errors out rather than silently no-op, because unlike a
# best-effort background hook, this script's JSON output is load-bearing --
# Stage 6 writes it verbatim into handoff.json's data.tasks and Stage 7's
# "tasks: N closed, M moved (K matched)" line reads it back.
set -u

PY=""
for c in python3 python py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'pass' >/dev/null 2>&1; then PY="$c"; break; fi
done
if [ -z "$PY" ]; then
  echo '{"error":"no working python interpreter found (tried python3, python, py) -- close-tasks.sh requires one"}' >&2
  exit 1
fi

usage() {
  cat >&2 <<'EOF'
Usage:
  close-tasks.sh close --file TASKS.md --scope plan --key SLUG --plan-file PLAN.md [--dry-run]
  close-tasks.sh close --file TASKS.md --scope resolved --ids-file FILE [--dry-run]
  close-tasks.sh reconcile --file TASKS.md [--pipeline-dir .claude/pipeline] [--apply]
EOF
}

[ $# -ge 1 ] || { usage; exit 2; }
SUBCMD="$1"; shift

FILE="TASKS.md"
SCOPE=""
KEY=""
PLAN_FILE=""
IDS_FILE=""
PIPELINE_DIR=".claude/pipeline"
DRY_RUN=0
APPLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --file) FILE="$2"; shift 2 ;;
    --scope) SCOPE="$2"; shift 2 ;;
    --key) KEY="$2"; shift 2 ;;
    --plan-file) PLAN_FILE="$2"; shift 2 ;;
    --ids-file) IDS_FILE="$2"; shift 2 ;;
    --pipeline-dir) PIPELINE_DIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --apply) APPLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "{\"error\":\"unknown arg: $1\"}" >&2; usage; exit 2 ;;
  esac
done

if [ ! -f "$FILE" ]; then
  echo "{\"error\":\"no such file: $FILE\"}" >&2
  exit 1
fi

PYCORE="$(mktemp)"
trap 'rm -f "$PYCORE"' EXIT

cat > "$PYCORE" <<'PYEOF'
import sys, os, re, json
from datetime import datetime, timezone

SECTION_RE = re.compile(r'^##\s+(.+?)\s*$')
ROW_RE = re.compile(r'^(\s*-\s*\[)([ x~])(\]\s*.*)$')
PLAN_TAG_RE = re.compile(r'_plan:\s*([a-z0-9-]+)_')


def read_lines(path):
    with open(path, encoding='utf-8') as f:
        return f.read().splitlines()


def parse_sections(lines):
    sections = []
    cur_name = None
    cur_start = 0
    for i, line in enumerate(lines):
        m = SECTION_RE.match(line)
        if m:
            if cur_name is not None:
                sections.append((cur_name, cur_start, i))
            cur_name = m.group(1).strip()
            cur_start = i
    if cur_name is not None:
        sections.append((cur_name, cur_start, len(lines)))
    return sections


def section_for(sections, i):
    for name, start, end in sections:
        if start < i < end:
            return name
    return None


def today():
    return datetime.now(timezone.utc).strftime('%Y-%m-%d')


def close_row_text(line):
    m = ROW_RE.match(line)
    if not m:
        return line
    prefix, _state, rest = m.groups()
    new_line = prefix + 'x' + rest
    if '_completed_at:' not in new_line:
        new_line = new_line.rstrip() + f' _completed_at: {today()}_'
    return new_line


def write_lines(path, lines):
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(lines) + '\n')


def insert_into_done(lines, closed_lines):
    """Insert closed_lines (already flipped to [x]) at the top of ## Done,
    creating the section if absent. Returns the new full line list."""
    sections = parse_sections(lines)
    done = next((s for s in sections if s[0].lower() == 'done'), None)
    new_lines = list(lines)
    if done is None:
        if new_lines and new_lines[-1].strip() != '':
            new_lines.append('')
        new_lines.append('## Done')
        new_lines.append('')
        insert_at = len(new_lines)
    else:
        _name, start, _end = done
        insert_at = start + 1
        if insert_at < len(new_lines) and new_lines[insert_at].strip() == '':
            insert_at += 1
    for offset, cl in enumerate(closed_lines):
        new_lines.insert(insert_at + offset, cl)
    return new_lines


def cmd_close_plan(lines, key, plan_file):
    sections = parse_sections(lines)
    plan_base = os.path.splitext(os.path.basename(plan_file))[0] if plan_file else ''
    matched, unmatched, close_idx = [], [], []
    for i, line in enumerate(lines):
        m = ROW_RE.match(line)
        if not m:
            continue
        sec = section_for(sections, i)
        if sec is None or sec.lower() == 'done':
            continue
        state = m.group(2)
        if state != '~':
            continue  # only rows THIS run's Stage 0 marked in-progress
        tagm = PLAN_TAG_RE.search(line)
        if tagm:
            tag = tagm.group(1)
            if tag == key:
                matched.append(line)
                close_idx.append(i)
            elif plan_base and (plan_base in line or (plan_file and plan_file in line)):
                unmatched.append(line)
            # else: tagged for a different plan entirely -- not our concern
        else:
            # legacy row, no _plan: tag -- fall back to path-substring match
            if (plan_file and plan_file in line) or (plan_base and plan_base in line):
                matched.append(line)
                close_idx.append(i)
    return matched, unmatched, close_idx


def cmd_close_resolved(lines, needles):
    sections = parse_sections(lines)
    matched, unmatched, close_idx = [], [], []
    for needle in needles:
        hits = []
        for i, line in enumerate(lines):
            if not ROW_RE.match(line):
                continue
            sec = section_for(sections, i)
            if sec is None or sec.lower() == 'done':
                continue
            if needle in line:
                hits.append(i)
        if len(hits) == 1:
            matched.append(lines[hits[0]])
            close_idx.append(hits[0])
        elif len(hits) == 0:
            unmatched.append(needle)
        else:
            unmatched.append(f'{needle} (ambiguous: {len(hits)} rows matched)')
    return matched, unmatched, close_idx


def do_close(args):
    path = args.file
    lines = read_lines(path)

    if args.scope == 'plan':
        matched, unmatched, close_idx = cmd_close_plan(lines, args.key, args.plan_file)
        match_key = args.key
    elif args.scope == 'resolved':
        with open(args.ids_file, encoding='utf-8') as f:
            needles = [l.strip() for l in f if l.strip()]
        matched, unmatched, close_idx = cmd_close_resolved(lines, needles)
        match_key = '(resolved)'
    else:
        print(json.dumps({"error": f"unknown scope {args.scope!r}"}))
        return 2

    result = {"match_key": match_key, "matched": matched, "closed": [], "moved": [], "unmatched": unmatched}

    if not close_idx:
        print(json.dumps(result, indent=2))
        return 0

    if args.dry_run:
        result["closed"] = list(matched)
        result["moved"] = list(matched)
        result["dry_run"] = True
        print(json.dumps(result, indent=2))
        return 0

    close_idx_set = set(close_idx)
    closed_flipped = []
    kept_lines = []
    for i, line in enumerate(lines):
        if i in close_idx_set:
            closed_flipped.append(close_row_text(line))
            result["closed"].append(line)
            result["moved"].append(line)
            continue
        kept_lines.append(line)

    new_lines = insert_into_done(kept_lines, closed_flipped)
    write_lines(path, new_lines)
    print(json.dumps(result, indent=2))
    return 0


def load_json(path):
    try:
        with open(path, encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return None


def envelope_candidates(name, run):
    candidates = {name}
    for key in ('plan_file', 'input'):
        v = run.get(key)
        if v:
            candidates.add(v)
            candidates.add(os.path.splitext(os.path.basename(v))[0])
    data = run.get('data') or {}
    v = data.get('plan_target')
    if v:
        candidates.add(v)
        candidates.add(os.path.splitext(os.path.basename(v))[0])
    stripped = set()
    for c in list(candidates):
        base = os.path.splitext(os.path.basename(c))[0]
        for pfx in ('brainstorm-', 'team-brainstorm-'):
            if base.startswith(pfx):
                stripped.add(base[len(pfx):])
        stripped.add(base)
    candidates |= stripped
    return {c for c in candidates if c}


def do_reconcile(args):
    lines = read_lines(args.file)
    sections = parse_sections(lines)
    drift = []

    for i, line in enumerate(lines):
        m = ROW_RE.match(line)
        if not m:
            continue
        state = m.group(2)
        sec = section_for(sections, i)
        if sec is None:
            continue
        secl = sec.lower()
        if secl == 'done' and state in (' ', '~'):
            drift.append({
                "type": "done_section_open_row", "line": i + 1, "row": line.strip(),
                "detail": f"row filed under ## Done has checkbox state '[{state}]' (not actually done)",
            })
        elif secl != 'done' and state == 'x':
            drift.append({
                "type": "active_section_closed_row", "line": i + 1, "row": line.strip(),
                "detail": f"row is checked '[x]' but filed under ## {sec}, not ## Done",
            })

    pdir = args.pipeline_dir
    envelopes = []
    if pdir and os.path.isdir(pdir):
        for name in sorted(os.listdir(pdir)):
            run_json = os.path.join(pdir, name, 'run.json')
            if not os.path.isfile(run_json):
                continue
            run = load_json(run_json)
            if run is None:
                continue
            envelopes.append((name, run))

    for name, run in envelopes:
        status = run.get('status')
        candidates = envelope_candidates(name, run)
        matching_rows = []
        for i, line in enumerate(lines):
            m = ROW_RE.match(line)
            if not m:
                continue
            sec = section_for(sections, i)
            if sec is None or sec.lower() == 'done':
                continue
            if any(c in line for c in candidates):
                matching_rows.append((i, line, m.group(2)))

        if status in ('complete', 'completed') and matching_rows:
            open_rows = [r for r in matching_rows if r[2] != 'x']
            if open_rows:
                drift.append({
                    "type": "terminal_envelope_open_rows",
                    "envelope": name,
                    "rows": [r[1].strip() for r in open_rows],
                    "row_lines": [r[0] + 1 for r in open_rows],
                    "detail": f"envelope '{name}' is {status} but {len(open_rows)} TASKS.md row(s) referencing it remain open",
                })
        if status == 'in_progress' and not matching_rows:
            drift.append({
                "type": "inprogress_envelope_no_row",
                "envelope": name,
                "detail": f"envelope '{name}' is in_progress but no TASKS.md row references it",
            })

    applied = []
    if args.apply and drift:
        new_lines = list(lines)
        # Fix bidirectional section/checkbox mismatches by moving the row to
        # the section matching its OWN checkbox state -- checkbox wins.
        to_move_out_of_done = []  # (line text) currently under Done, not [x]
        to_move_into_done = []    # (line text) currently outside Done, is [x]
        for d in drift:
            if d["type"] == "done_section_open_row":
                to_move_out_of_done.append(d["row"])
            elif d["type"] == "active_section_closed_row":
                to_move_into_done.append(d["row"])

        if to_move_out_of_done or to_move_into_done:
            remaining = []
            moved_out, moved_in = [], []
            for line in new_lines:
                stripped = line.strip()
                if stripped in to_move_out_of_done:
                    moved_out.append(line)
                    continue
                if stripped in to_move_into_done:
                    moved_in.append(line)
                    continue
                remaining.append(line)
            # moved_in rows are already [x] -- file them into Done.
            if moved_in:
                remaining = insert_into_done(remaining, moved_in)
            # moved_out rows keep their own checkbox state -- file them at the
            # top of "Active / Pending" (creating it if somehow absent).
            if moved_out:
                secs2 = parse_sections(remaining)
                active = next((s for s in secs2 if s[0].lower().startswith('active')), None)
                if active is None:
                    remaining = ['## Active / Pending', ''] + moved_out + [''] + remaining
                else:
                    _n, start, _e = active
                    insert_at = start + 1
                    if insert_at < len(remaining) and remaining[insert_at].strip() == '':
                        insert_at += 1
                    for offset, ml in enumerate(moved_out):
                        remaining.insert(insert_at + offset, ml)
            new_lines = remaining
            applied.append(f"moved {len(moved_out)} row(s) out of Done, {len(moved_in)} row(s) into Done (checkbox-matched section)")

        # Close rows for terminal envelopes that still show them open.
        terminal_open = [d for d in drift if d["type"] == "terminal_envelope_open_rows"]
        if terminal_open:
            close_idx = []
            sections3 = parse_sections(new_lines)
            for d in terminal_open:
                for row_text in d["rows"]:
                    for i, line in enumerate(new_lines):
                        if line.strip() == row_text and ROW_RE.match(line):
                            sec = section_for(sections3, i)
                            if sec and sec.lower() != 'done':
                                close_idx.append(i)
                            break
            if close_idx:
                close_idx_set = set(close_idx)
                closed_flipped = [close_row_text(new_lines[i]) for i in sorted(close_idx_set)]
                kept = [l for i, l in enumerate(new_lines) if i not in close_idx_set]
                new_lines = insert_into_done(kept, closed_flipped)
                applied.append(f"closed {len(close_idx_set)} row(s) belonging to terminal envelope(s)")

        write_lines(args.file, new_lines)

    result = {"drift_count": len(drift), "drift": drift, "applied": applied}
    print(json.dumps(result, indent=2))
    return 0


class Args:
    pass


def main(argv):
    if not argv:
        print(json.dumps({"error": "no subcommand"}))
        return 2
    sub = argv[0]
    a = Args()
    a.file = 'TASKS.md'
    a.scope = ''
    a.key = ''
    a.plan_file = ''
    a.ids_file = ''
    a.pipeline_dir = '.claude/pipeline'
    a.dry_run = False
    a.apply = False
    it = iter(argv[1:])
    for tok in it:
        if tok == '--file':
            a.file = next(it)
        elif tok == '--scope':
            a.scope = next(it)
        elif tok == '--key':
            a.key = next(it)
        elif tok == '--plan-file':
            a.plan_file = next(it)
        elif tok == '--ids-file':
            a.ids_file = next(it)
        elif tok == '--pipeline-dir':
            a.pipeline_dir = next(it)
        elif tok == '--dry-run':
            a.dry_run = True
        elif tok == '--apply':
            a.apply = True

    if sub == 'close':
        return do_close(a)
    elif sub == 'reconcile':
        return do_reconcile(a)
    else:
        print(json.dumps({"error": f"unknown subcommand {sub!r}"}))
        return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
PYEOF

ARGS=("$SUBCMD" "--file" "$FILE")
case "$SUBCMD" in
  close)
    ARGS+=("--scope" "$SCOPE")
    [ -n "$KEY" ] && ARGS+=("--key" "$KEY")
    [ -n "$PLAN_FILE" ] && ARGS+=("--plan-file" "$PLAN_FILE")
    [ -n "$IDS_FILE" ] && ARGS+=("--ids-file" "$IDS_FILE")
    [ "$DRY_RUN" -eq 1 ] && ARGS+=("--dry-run")
    ;;
  reconcile)
    ARGS+=("--pipeline-dir" "$PIPELINE_DIR")
    [ "$APPLY" -eq 1 ] && ARGS+=("--apply")
    ;;
  *)
    usage
    exit 2
    ;;
esac

"$PY" "$PYCORE" "${ARGS[@]}"
exit $?
