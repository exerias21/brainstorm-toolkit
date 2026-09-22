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
# Four subcommands:
#
#   rows --plan SLUG [--file TASKS.md] [--plan-file PLAN.md]
#     Read-only row lookup, added after a live miss on 2026-09-20: a
#     `subagent-git-guard` run used `reconcile | grep <slug>` as its row scan,
#     but `reconcile` only reports drift against EXISTING pipeline envelopes,
#     so a first run (no envelope on disk yet) always reads zero rows -- the
#     scope gate took its zero-row fallback and close-out matched nothing
#     while four correctly-tagged rows sat open. `rows` reads TASKS.md alone,
#     no envelope involved, so a first run reports the same tagged rows a
#     tenth run would. Reuses the SAME `_plan:` key matching (and its legacy
#     path-substring fallback against --plan-file) that `close --scope plan`
#     uses, and the same `parse_row`/trailer helpers `board` uses -- one
#     parser, three callers. Prints `{match_key, matched[]}`; each `matched[]`
#     entry is `{line, text, state, phase, followup, manual}` with `state` one
#     of `open`/`in_progress`/`done` (unlike `close`, which never reports a
#     `[x]` row at all -- `rows` reports every state so a caller can tell
#     "already done" from "never tagged").
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
#         still open -- `_followup_` and `_manual_` rows are exempted (both
#         mean "deliberately left open"); when the envelope recorded
#         `data.scope_gate.taken_phases`, a row's own `_phase: N_` tag outside
#         that list is read as a legitimately-parked later phase, not drift
#         (envelopes with no `taken_phases` keep the un-refined behavior)
#       - an `in_progress` envelope with no TASKS.md row referencing it at all
#       - a row's `_phase: N_` tag naming a phase its OWN plan file has no
#         `#### Phase N` heading for (independent of any envelope)
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
#   board --file TASKS.md [--repo-name NAME] [--pipeline-dir .claude/pipeline]
#     Read-only, always -- no flags exist to make it write. Joins TASKS.md rows
#     to pipeline envelopes and emits ONE JSON object: `tasks[]` (file order,
#     so `line` round-trips to source), `runs[]` (newest-first by `updated_at`
#     when parseable, else the envelope file's mtime -- most real envelopes
#     lack `updated_at`), and `plans_without_rows[]` (`plans/*.md` with no
#     TASKS.md row referencing them -- "planned but never queued"). A `[~]`
#     row's `started_at` comes only from its joined envelope (rows carry no
#     such tag themselves); a malformed envelope is a `warnings[]` entry, never
#     a crash. Exit 0 whenever `--file` parses; exit 1 only when it's
#     missing/unreadable. Full contract: docs/BOARD-JSON.md.
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
  close-tasks.sh rows --plan SLUG [--file TASKS.md] [--plan-file PLAN.md]
    Read-only. Reports every TASKS.md row tagged `_plan: SLUG_` (any state,
    any section, no pipeline envelope involved) -- a first run reports the
    same rows a tenth run would. Untagged legacy rows fall back to a
    path-substring match against --plan-file, same as `close --scope plan`.
    Prints `{match_key, matched[]}`; each entry is `{line, text, state, phase,
    followup, manual}` with `state` one of `open`/`in_progress`/`done`.
  close-tasks.sh close --file TASKS.md --scope plan --key SLUG --plan-file PLAN.md [--dry-run]
  close-tasks.sh close --file TASKS.md --scope resolved --ids-file FILE [--dry-run]
  close-tasks.sh reconcile --file TASKS.md [--pipeline-dir .claude/pipeline] [--apply] [--json]
    (--json is a documented no-op: reconcile's output is always one JSON object
    on stdout, with or without the flag -- it exists so a caller following the
    header contract above is never rejected with "unknown arg".)
    Mark a row `_followup_` (or `_followup: why_`) to say it was left open ON
    PURPOSE after its plan completed, or `_manual_` to say only a human can do
    it. reconcile then stops reporting either as drift, while a row that is
    merely forgotten still is. Both tags count ONLY in the row's trailer (the
    text after the last ` -- `) -- a title that merely mentions `_manual_` or
    `_followup_` in prose is not tagged. When an envelope recorded which
    phases it took (`data.scope_gate.taken_phases`), a still-open row whose
    `_phase: N_` tag names a phase outside that list is read as a
    legitimately-parked later phase, not drift. Also flags a row's `_phase:
    N_` tag naming a phase its own plan file has no `#### Phase N` heading for.
  close-tasks.sh board --file TASKS.md [--repo-name NAME] [--pipeline-dir .claude/pipeline]
    Read-only. Emits one JSON object: TASKS.md rows (tasks[], in FILE ORDER so
    `line` round-trips to source) + pipeline envelopes (runs[], newest-first
    by `updated_at` when parseable, else the envelope file's mtime -- most
    envelopes in the wild lack `updated_at` entirely) + plans/*.md with no
    TASKS.md row referencing them (plans_without_rows[]). `terminal` on a run
    is derived (complete/failed => true). Never writes anything. Exit 0
    whenever --file parses (malformed envelopes surface as warnings[], not a
    failure); exit 1 only when --file is missing/unreadable. Schema-version
    rule: additive fields never bump `schema`; a removed or retyped field does.
EOF
}

[ $# -ge 1 ] || { usage; exit 2; }
SUBCMD="$1"; shift

FILE="TASKS.md"
SCOPE=""
KEY=""
PLAN=""
PLAN_FILE=""
IDS_FILE=""
PIPELINE_DIR=".claude/pipeline"
DRY_RUN=0
APPLY=0
REPO_NAME=""

while [ $# -gt 0 ]; do
  case "$1" in
    --file) FILE="$2"; shift 2 ;;
    --scope) SCOPE="$2"; shift 2 ;;
    --key) KEY="$2"; shift 2 ;;
    --plan) PLAN="$2"; shift 2 ;;
    --plan-file) PLAN_FILE="$2"; shift 2 ;;
    --ids-file) IDS_FILE="$2"; shift 2 ;;
    --pipeline-dir) PIPELINE_DIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --apply) APPLY=1; shift ;;
    --json) shift ;;  # documented no-op -- reconcile's output is always JSON, flag or not
    --repo-name) REPO_NAME="$2"; shift 2 ;;
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
# `board` subcommand only -- net-new, nothing above this line reads these.
PHASE_RE = re.compile(r'_phase:\s*(\d+)_')
BLOCKED_REASON_RE = re.compile(r'_blocked_reason:\s*([^_]+?)_')
COMPLETED_AT_RE = re.compile(r'_completed_at:\s*([^_]+?)_')
PRIORITY_RE = re.compile(r'^\(P([1-3])\)')
PLAN_PATH_RE = re.compile(r'[\w./-]*plans/[\w./-]+\.md')
# A row DELIBERATELY left open after its plan completed -- a follow-up the run
# surfaced and chose not to do. Without this marker `reconcile` cannot tell a
# deferred follow-up from a forgotten close-out, so it reports every such row as
# drift; the first real dogfood of `board` produced eight of them at once and
# buried the one signal the check exists for. Bare `_followup_` or
# `_followup: why_` both count.
FOLLOWUP_RE = re.compile(r'_followup(?::\s*[^_]+?)?_')
# A row only a HUMAN can do -- the scope gate never takes it or marks it `[~]`,
# the queue Select and task-range paths skip it, and reconcile exempts it
# exactly like FOLLOWUP_RE. Bare flag, no value.
MANUAL_RE = re.compile(r'_manual_')
# Strips one or more chained `_key: value_` markers (joined by ` \xb7 `) off a
# row's tail so `title` reads as prose, not "prose _plan: x_ \xb7 _phase: 1_".
TAG_STRIP_RE = re.compile(r'\s*(?:\xb7\s*)?_[a-z_]+:\s*[^_]+?_')
# Valueless flags need their own pattern: TAG_STRIP_RE requires `key: value`,
# and widening it to make the colon optional would swallow ordinary `_italics_`
# out of every title. Enumerate the bare flags instead.
BARE_TAG_STRIP_RE = re.compile(r'\s*(?:\xb7\s*)?_(?:followup|manual)_')
# `#### Phase N` heading finder -- used by reconcile's phase_tag_without_heading
# check to confirm a row's `_phase: N_` tag actually names a phase its plan file
# declares.
PLAN_HEADING_RE = re.compile(r'^####\s+Phase\s+(\d+)\b')


def trailer(line):
    """The text after the LAST ' -- ' (space, U+2014 em dash, space) on a row --
    the only place `_manual_` / `_followup_` count as a tag. Matching the whole
    line (as FOLLOWUP_RE/BARE_TAG_STRIP_RE used to) means a row whose PROSE
    merely mentions one of these words -- e.g. one documenting `pr_followup_of`,
    or one of this very plan's own rows discussing `_manual_` -- is misread as
    tagged. No ' -- ' on the row at all means no trailer, hence no tag.
    """
    idx = line.rfind(' — ')
    return line[idx + 3:] if idx != -1 else ''


def strip_bare_tags(text):
    """BARE_TAG_STRIP_RE, confined to the trailer (see `trailer()` above) so a
    title merely mentioning `_followup_`/`_manual_` in prose is not mangled by
    display-stripping the same way whole-line matching would be."""
    idx = text.rfind(' — ')
    if idx == -1:
        return text
    return text[:idx + 3] + BARE_TAG_STRIP_RE.sub('', text[idx + 3:])


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


def plan_base_of(plan_file):
    """The basename-minus-extension of a plan file path, or '' when no path
    was given -- shared by every legacy path-substring fallback so `close
    --scope plan` and `rows` derive it identically."""
    return os.path.splitext(os.path.basename(plan_file))[0] if plan_file else ''


def plan_row_key_match(line, key, plan_base, plan_file):
    """Does this row belong to plan `key`? An explicit `_plan: KEY_` tag wins
    outright (matching key -> True, any OTHER key -> False, never falls
    through to the path guess). Only a legacy row with no `_plan:` tag at all
    falls back to a path-substring match against --plan-file/its basename.
    Returns (is_match, has_different_tag) so callers that care about
    surfacing a near-miss (`close --scope plan`'s `unmatched`) can, and
    callers that don't (`rows`) can ignore the second value."""
    tagm = PLAN_TAG_RE.search(line)
    if tagm:
        return (tagm.group(1) == key), (tagm.group(1) != key)
    legacy_hit = bool((plan_file and plan_file in line) or (plan_base and plan_base in line))
    return legacy_hit, False


def cmd_close_plan(lines, key, plan_file):
    sections = parse_sections(lines)
    plan_base = plan_base_of(plan_file)
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
        is_match, has_different_tag = plan_row_key_match(line, key, plan_base, plan_file)
        if is_match:
            matched.append(line)
            close_idx.append(i)
        elif has_different_tag and plan_base and (plan_base in line or (plan_file and plan_file in line)):
            unmatched.append(line)
        # else: tagged for a different plan entirely (and no path hint), or a
        # legacy row that doesn't even path-match -- not our concern
    return matched, unmatched, close_idx


STATE_LABEL = {'x': 'done', '~': 'in_progress', ' ': 'open'}


def cmd_rows_plan(lines, key, plan_file):
    """Every row tagged for plan `key`, in ANY section and ANY checkbox state
    -- unlike cmd_close_plan (which only ever touches `[~]` rows outside
    ## Done), this is a pure read used to answer "what rows exist for this
    plan RIGHT NOW", with no pipeline envelope involved at all. That's what
    makes a first run (no envelope on disk yet) report the same rows a tenth
    run would -- the bug `reconcile | grep` had."""
    plan_base = plan_base_of(plan_file)
    matched = []
    for i, line in enumerate(lines):
        if not ROW_RE.match(line):
            continue
        is_match, _has_different_tag = plan_row_key_match(line, key, plan_base, plan_file)
        if not is_match:
            continue
        fields = parse_row(line)
        matched.append({
            'line': i + 1,
            'text': line.strip(),
            'state': STATE_LABEL.get(fields['state'], 'open'),
            'phase': fields['phase'],
            'followup': fields['followup'],
            'manual': fields['manual'],
        })
    return matched


def do_rows(args):
    lines = read_lines(args.file)
    matched = cmd_rows_plan(lines, args.plan, args.plan_file)
    result = {"match_key": args.plan, "matched": matched}
    print(json.dumps(result, indent=2))
    return 0


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


# ---------------------------------------------------------------------------
# `board` subcommand -- read-only JSON export. Everything below this line and
# above `do_board` is net-new; nothing here is called by close/reconcile.
# ---------------------------------------------------------------------------


def parse_iso(s):
    """Best-effort ISO8601 -> aware datetime. None on anything unparseable --
    a malformed timestamp must fall back to file mtime, never crash."""
    if not s or not isinstance(s, str):
        return None
    try:
        dt = datetime.fromisoformat(s.replace('Z', '+00:00'))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt
    except Exception:
        return None


def iso_utc(dt):
    return dt.astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def parse_row(line):
    """Map one TASKS.md row line to its JSON fields (everything except
    `started_at`, which requires the joined envelope and is filled in by the
    caller). Returns None for a non-row line."""
    m = ROW_RE.match(line)
    if not m:
        return None
    state = m.group(2)
    rest = m.group(3)  # "] ...rest of the row..."
    body = rest[1:].lstrip()
    pm = PRIORITY_RE.match(body)
    priority = f'P{pm.group(1)}' if pm else None
    title_full = body[pm.end():].lstrip() if pm else body
    title = strip_bare_tags(TAG_STRIP_RE.sub('', title_full)).rstrip()
    plan_m = PLAN_PATH_RE.search(title_full)
    plan = plan_m.group(0) if plan_m else None
    # The plan path rides in its own field, so leaving it in `title` too makes
    # every consumer render it twice. Strip it plus the trailing em-dash
    # separator the row convention puts before it.
    if plan:
        title = PLAN_PATH_RE.sub('', title).rstrip()
        title = re.sub(r'[\s—–-]+$', '', title).rstrip()
    tag_m = PLAN_TAG_RE.search(line)
    plan_slug = tag_m.group(1) if tag_m else None
    phase_m = PHASE_RE.search(line)
    phase = int(phase_m.group(1)) if phase_m else None
    blocked_m = BLOCKED_REASON_RE.search(line)
    blocked_reason = blocked_m.group(1).strip() if blocked_m else None
    completed_m = COMPLETED_AT_RE.search(line)
    completed_at = completed_m.group(1).strip() if completed_m else None
    return {
        'state': state, 'priority': priority, 'title': title, 'plan': plan,
        'plan_slug': plan_slug, 'phase': phase, 'blocked_reason': blocked_reason,
        'completed_at': completed_at,
        # Additive field -- does NOT bump `schema` (see the schema-version rule
        # in the usage block). Lets a board mark a row as deferred-on-purpose
        # rather than merely open. Trailer-only (see `trailer()`): a title
        # merely mentioning `_followup_` is not tagged.
        'followup': bool(FOLLOWUP_RE.search(trailer(line))),
        # Additive field, same rule: a row only a human can do. Trailer-only
        # for the same reason `followup` is.
        'manual': bool(MANUAL_RE.search(trailer(line))),
    }


def load_envelope(pdir, name):
    """Load one envelope's run.json. Returns (dict, None) on success or
    (None, warning) on anything unreadable/malformed -- callers must never
    let a bad envelope raise or abort the run."""
    run_json = os.path.join(pdir, name, 'run.json')
    try:
        with open(run_json, encoding='utf-8') as f:
            data = json.load(f)
    except Exception as e:
        return None, f"envelope '{name}': unreadable/malformed run.json ({e.__class__.__name__}) -- skipped"
    if not isinstance(data, dict):
        return None, f"envelope '{name}': run.json is not a JSON object -- skipped"
    return data, None


def do_board(args):
    warnings = []
    lines = read_lines(args.file)
    sections = parse_sections(lines)

    repo_path = os.path.dirname(os.path.abspath(args.file)) or os.getcwd()
    repo = args.repo_name or os.path.basename(repo_path.rstrip(os.sep).rstrip('/')) or repo_path

    # --- load envelopes (a malformed one is a warning, never a crash) ---
    pdir = args.pipeline_dir
    loaded = []  # (name, run, run_json_mtime_dt)
    if pdir and os.path.isdir(pdir):
        for name in sorted(os.listdir(pdir)):
            entry_dir = os.path.join(pdir, name)
            run_json = os.path.join(entry_dir, 'run.json')
            if not os.path.isdir(entry_dir) or not os.path.isfile(run_json):
                continue
            run, warn = load_envelope(pdir, name)
            if warn:
                warnings.append(warn)
                continue
            try:
                mtime_dt = datetime.fromtimestamp(os.path.getmtime(run_json), tz=timezone.utc)
            except Exception:
                mtime_dt = datetime.now(timezone.utc)
            loaded.append((name, run, mtime_dt))

    # --- build runs[], newest-first by updated_at (parsed) or mtime ---
    runs = []
    for name, run, mtime_dt in loaded:
        status = run.get('status') if isinstance(run.get('status'), str) else None
        data = run.get('data') or {}
        if not isinstance(data, dict):
            data = {}
        plan_file = run.get('plan_file') or run.get('input') or data.get('plan_target')
        updated_raw = run.get('updated_at')
        updated_dt = parse_iso(updated_raw)
        if updated_raw and updated_dt is None:
            warnings.append(f"envelope '{name}': unparsable updated_at {updated_raw!r} -- sorted by mtime instead")
        terminal = status in ('complete', 'completed', 'failed')
        runs.append({
            'slug': run.get('slug') or name,
            'stage': run.get('stage'),
            'status': run.get('status'),
            'pipeline': run.get('pipeline'),
            'plan_file': plan_file,
            'updated_at': updated_raw if isinstance(updated_raw, str) else None,
            'mtime': iso_utc(mtime_dt),
            'plan_hash': run.get('plan_hash'),
            'stages_skipped': run.get('stages_skipped'),
            'terminal': terminal,
            '_candidates': envelope_candidates(name, run),
            '_started_at': run.get('started_at'),
            '_sort_dt': updated_dt or mtime_dt,
        })
    runs.sort(key=lambda r: r['_sort_dt'], reverse=True)

    # --- tasks[], in file order; started_at comes only from a joined envelope ---
    tasks = []
    for i, line in enumerate(lines):
        fields = parse_row(line)
        if fields is None:
            continue
        sec = section_for(sections, i)
        if sec is None:
            continue
        started_at = None
        for r in runs:
            if any(c in line for c in r['_candidates']):
                started_at = r['_started_at']
                break
        tasks.append({
            'state': fields['state'],
            'section': sec,
            'priority': fields['priority'],
            'title': fields['title'],
            'plan': fields['plan'],
            'plan_slug': fields['plan_slug'],
            'phase': fields['phase'],
            'blocked_reason': fields['blocked_reason'],
            'started_at': started_at,
            'completed_at': fields['completed_at'],
            'followup': fields['followup'],
            'manual': fields['manual'],
            'line': i + 1,
        })

    public_runs = [
        {k: v for k, v in r.items() if not k.startswith('_')}
        for r in runs
    ]

    # --- plans/*.md with no TASKS.md row referencing them ---
    plans_without_rows = []
    plans_dir = os.path.join(repo_path, 'plans')
    if os.path.isdir(plans_dir):
        row_lines = [l for l in lines if ROW_RE.match(l)]
        for fname in sorted(os.listdir(plans_dir)):
            if not fname.endswith('.md'):
                continue
            rel = f'plans/{fname}'
            if not any(rel in rl for rl in row_lines):
                plans_without_rows.append(rel)

    result = {
        "schema": 1,
        "repo": repo,
        "repo_path": repo_path,
        "generated_at": iso_utc(datetime.now(timezone.utc)),
        "tasks": tasks,
        "runs": public_runs,
        "plans_without_rows": plans_without_rows,
        "warnings": warnings,
    }
    print(json.dumps(result, indent=2))
    return 0


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

    # Zero-noise structural check: a row's `_phase: N_` tag naming a phase its
    # OWN plan file does not declare as `#### Phase N` -- independent of any
    # envelope, so it fires even when no pipeline run ever touched the plan.
    # OPEN rows only ([ ]/[~], same "not x" test as terminal_envelope_open_rows
    # above): a closed `[x]` row is already done and can't be acted on, so
    # flagging it is noise, not a finding.
    plan_headings_cache = {}
    for i, line in enumerate(lines):
        row_m = ROW_RE.match(line)
        if not row_m or row_m.group(2) == 'x':
            continue
        phase_m = PHASE_RE.search(line)
        if not phase_m:
            continue
        plan_m = PLAN_PATH_RE.search(line)
        if not plan_m:
            continue
        plan_path = plan_m.group(0)
        if plan_path not in plan_headings_cache:
            try:
                with open(plan_path, encoding='utf-8') as f:
                    plan_lines = f.read().splitlines()
                plan_headings_cache[plan_path] = {
                    int(hm.group(1)) for pl in plan_lines
                    for hm in [PLAN_HEADING_RE.match(pl)] if hm
                }
            except Exception:
                plan_headings_cache[plan_path] = None  # unreadable -- not this check's job
        headings = plan_headings_cache[plan_path]
        if headings is None:
            continue
        phase_n = int(phase_m.group(1))
        if phase_n not in headings:
            drift.append({
                "type": "phase_tag_without_heading",
                "line": i + 1, "row": line.strip(), "plan": plan_path, "phase": phase_n,
                "detail": f"row tagged _phase: {phase_n}_ but {plan_path} has no '#### Phase {phase_n}' heading",
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
            # A row tagged `_followup_` was left open on purpose -- the run
            # surfaced it and deferred it. Counting those as drift is how this
            # check cries wolf: a completed plan that spawned N follow-ups
            # reports N phantom drifts, and the real case (a close-out that
            # genuinely did not fire) is lost in them. `_manual_` is exempted
            # the same way -- a human-only row, never taken by the scope gate.
            open_rows = [r for r in matching_rows
                         if r[2] != 'x'
                         and not FOLLOWUP_RE.search(trailer(r[1]))
                         and not MANUAL_RE.search(trailer(r[1]))]
            # Phase-aware refinement: when the envelope recorded WHICH phases it
            # actually took (`data.scope_gate.taken_phases`, additive -- absent
            # on every envelope written before this field existed, which keep
            # today's un-refined behavior above), a row's own `_phase: N_` tag
            # that names a phase NOT in that list is a legitimately-parked later
            # phase, not drift -- this is what stops a finished plan's own
            # parked-on-purpose rows from being reported every time (the
            # `flow-gap-fixes` Phase 5 rows this plan's Direction cites).
            # A row with no `_phase:` tag at all can't be judged this way, so it
            # keeps being reported, same as before this refinement existed.
            data = run.get('data') or {}
            scope_gate = data.get('scope_gate') if isinstance(data, dict) else None
            taken_phases = scope_gate.get('taken_phases') if isinstance(scope_gate, dict) else None
            if isinstance(taken_phases, list) and taken_phases:
                refined = []
                for r in open_rows:
                    phase_m = PHASE_RE.search(r[1])
                    if phase_m and int(phase_m.group(1)) not in taken_phases:
                        continue  # parked later phase -- not this envelope's drift
                    refined.append(r)
                open_rows = refined
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
    a.plan = ''
    a.plan_file = ''
    a.ids_file = ''
    a.pipeline_dir = '.claude/pipeline'
    a.dry_run = False
    a.apply = False
    a.repo_name = ''
    it = iter(argv[1:])
    for tok in it:
        if tok == '--file':
            a.file = next(it)
        elif tok == '--scope':
            a.scope = next(it)
        elif tok == '--key':
            a.key = next(it)
        elif tok == '--plan':
            a.plan = next(it)
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
        elif tok == '--repo-name':
            a.repo_name = next(it)

    if sub == 'rows':
        return do_rows(a)
    elif sub == 'close':
        return do_close(a)
    elif sub == 'reconcile':
        return do_reconcile(a)
    elif sub == 'board':
        return do_board(a)
    else:
        print(json.dumps({"error": f"unknown subcommand {sub!r}"}))
        return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
PYEOF

ARGS=("$SUBCMD" "--file" "$FILE")
case "$SUBCMD" in
  rows)
    ARGS+=("--plan" "$PLAN")
    [ -n "$PLAN_FILE" ] && ARGS+=("--plan-file" "$PLAN_FILE")
    ;;
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
  board)
    ARGS+=("--pipeline-dir" "$PIPELINE_DIR")
    [ -n "$REPO_NAME" ] && ARGS+=("--repo-name" "$REPO_NAME")
    ;;
  *)
    usage
    exit 2
    ;;
esac

"$PY" "$PYCORE" "${ARGS[@]}"
exit $?
