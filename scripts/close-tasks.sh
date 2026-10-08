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
# Subcommands:
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
#   close --file TASKS.md --scope plan --key SLUG --plan-file PLAN.md [--dry-run] [--in-place]
#     Closes every `[~]` row (never `[ ]`/`[x]`) tagged `_plan: SLUG_`, moving
#     each to ## Done with a `_completed_at:` stamp. A row tagged with a
#     DIFFERENT `_plan:` value that still looks like it belongs to this plan
#     (its text contains the plan file's basename) is reported in `unmatched`
#     instead of guessed-closed -- this is the writer/reader key-mismatch case.
#     Legacy rows with no `_plan:`
#     tag at all fall back to a path-substring match against --plan-file.
#     NEVER touches `[ ]` rows -- re-entry rows Stage 6 itself appends land as
#     `[ ]`, so a later `--resume` reaching Stage 6 again can never close its
#     own re-entry rows by construction.
#
#   close --file TASKS.md --scope resolved --ids-file FILE [--dry-run] [--in-place]
#     (--in-place on either scope flips the row to [x] where it stands and does
#     not move it; `moved[]` stays empty.)
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
#     row to the section matching its own checkbox state, and closes ONLY the
#     `[~]` rows belonging to a terminal envelope that still show them open --
#     a `[ ]` row referencing that same envelope (never taken by this run's
#     scope gate -- a phase-less plan cut by step count parks later rows `[ ]`
#     with no `_phase:` tag, so the `taken_phases` exemption above can't apply
#     to them) is still REPORTED in `drift` so a human sees it, but is never
#     auto-closed -- the same restriction `close --scope plan` already applies
#     ("only rows THIS run's Stage 0 marked in-progress"). It never touches an
#     `in_progress` envelope with no matching row -- there is no safe automatic
#     fix for "orchestrator forgot to write the row."
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
#   waves --file TASKS.md [--write ACTION_ITEMS.md] [--gate]
#     Groups open rows into a now/next wave by lane; see `usage` below.
#
#   tag --file TASKS.md --row NEEDLE (--add|--remove) TAG
#     Edits one open row's `_after:` / `_conflicts:` / `_lane:` trailer tag;
#     see `usage` below.
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
  close-tasks.sh close --file TASKS.md --scope plan --key SLUG --plan-file PLAN.md [--dry-run] [--in-place]
  close-tasks.sh close --file TASKS.md --scope resolved --ids-file FILE [--dry-run] [--in-place]
    --in-place flips each closed row to `[x]` (with its completion stamp) where it
    stands instead of moving it to ## Done, so `TASKS.md:N` line citations hold;
    `moved[]` stays empty.
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
  close-tasks.sh waves --file TASKS.md [--write ACTION_ITEMS.md]
  close-tasks.sh waves --file TASKS.md --gate
    Prints `{enabled, file, reason}` -- whether action items are on, from
    `.claude/project.json` beside TASKS.md (`pipeline.action_items.enabled` is a
    veto when false, a switch when true; absent, on only when `file` exists and
    line 1 is the generated banner). `file` is the resolved path.
    Read-only unless --write. Groups open `Active / Pending` rows into a `now`
    wave (no open order edge, one row per lane, no two that conflict) and a
    `next` wave (ready once every now row closes). Untagged rows are parallel by
    default; ordering and conflicts come from `_phase:` order within a plan,
    plan-phase `Files:` overlap, and the `_after:` / `_conflicts:` / `_lane:`
    trailer tags, which win. `_manual_` rows land in `needs_you`; rows whose
    plan phase names no files land in `unknown_files`. A now row whose files are
    dirty in ANOTHER git worktree gets `overlaps` (silently skipped outside git).
    Prints one JSON object (incl. a counts `summary`); --write also renders the
    lane-grouped file, but never over an existing file whose line 1 is not the
    generated banner (JSON gets `write_skipped`). Exit 0 whenever --file parses.
  close-tasks.sh tag --file TASKS.md --row NEEDLE (--add|--remove) TAG
    The only writer of `_after:` / `_conflicts:` / `_lane:`. TAG is
    `after:<plan>[:<phase>]`, `conflicts:<plan>[:<phase>]` or `lane:<name>`
    (values `[a-z0-9:/.-]`). NEEDLE must whole-token match exactly one open row;
    a referenced plan (and phase) must exist. Edits only that row's trailer,
    never its checkbox; idempotent. Prints `{line, tag, action, changed, text}`;
    on refusal prints `{error, code}` and exits 1.
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
IN_PLACE=0
GATE=0
APPLY=0
REPO_NAME=""
WRITE=""
ROW=""
ADD=""
REMOVE=""

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
    --in-place) IN_PLACE=1; shift ;;
    --gate) GATE=1; shift ;;
    --apply) APPLY=1; shift ;;
    --json) shift ;;  # documented no-op -- reconcile's output is always JSON, flag or not
    --repo-name) REPO_NAME="$2"; shift 2 ;;
    --write) WRITE="$2"; shift 2 ;;
    --row) ROW="$2"; shift 2 ;;
    --add) ADD="$2"; shift 2 ;;
    --remove) REMOVE="$2"; shift 2 ;;
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
import sys, os, re, json, shutil, subprocess, hashlib
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
# Ordering / conflict / lane tags for `waves`. Values are `[a-z0-9:/.-]` -- no
# `_`, which is what ends a tag -- and a tag counts ONLY in the trailer (see
# `trailer()`), so prose that mentions one is never parsed as one.
AFTER_RE = re.compile(r'_after:\s*([a-z0-9:/.-]+)_')
CONFLICTS_RE = re.compile(r'_conflicts:\s*([a-z0-9:/.-]+)_')
LANE_RE = re.compile(r'_lane:\s*([a-z0-9.-]+)_')
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
# The well-known plan-name prefixes a caller's plan-file basename may still
# carry (docs/CONVENTIONS.md Slug derivation step 2) even though `/brainstorm`
# et al. tag rows with the ALREADY-STRIPPED slug -- a caller that passes the
# raw basename (`brainstorm-add-orders`) instead of the Stage 0-derived slug
# (`add-orders`) must still match the `_plan: add-orders_` tag that was
# actually written. Stripped from BOTH sides of the comparison in
# `plan_row_key_match` so either spelling of the key matches the same rows.
PLAN_PREFIX_RE = re.compile(r'^(?:brainstorm-|team-brainstorm-|pbi-\d+-|task-\d+-)')


def normalize_plan_key(key):
    """Strip one leading well-known prefix (PLAN_PREFIX_RE) from a plan
    key/slug, so `brainstorm-add-orders` and `add-orders` normalize to the
    same value for comparison."""
    return PLAN_PREFIX_RE.sub('', key, count=1) if key else key


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
    Both the tag's value and `key` are run through `normalize_plan_key` before
    comparing, so a caller passing the raw plan-file basename
    (`brainstorm-add-orders`) matches the same rows as one passing the
    Stage 0-derived, already-stripped slug (`add-orders`) -- one shared
    matcher, so `rows` and `close --scope plan` can never disagree on this.
    Returns (is_match, has_different_tag) so callers that care about
    surfacing a near-miss (`close --scope plan`'s `unmatched`) can, and
    callers that don't (`rows`) can ignore the second value."""
    tagm = PLAN_TAG_RE.search(line)
    if tagm:
        tag_key = normalize_plan_key(tagm.group(1))
        norm_key = normalize_plan_key(key)
        return (tag_key == norm_key), (tag_key != norm_key)
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
        result["moved"] = [] if args.in_place else list(matched)
        result["dry_run"] = True
        print(json.dumps(result, indent=2))
        return 0

    if args.in_place:
        new_lines = list(lines)
        for i in close_idx:
            new_lines[i] = close_row_text(lines[i])
            result["closed"].append(lines[i])
        write_lines(path, new_lines)
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


# Chars that make up one hyphenated slug token -- used by `token_hit` below to
# require a candidate occupy a COMPLETE such run, not merely appear inside a
# longer one.
_TOKEN_BOUNDARY_CHARS = 'A-Za-z0-9-'
_TOKEN_BOUNDARY_NEG = '[^' + _TOKEN_BOUNDARY_CHARS + ']'


def token_hit(candidate, line):
    """Whole-token match: `candidate` must occupy a complete run of
    `[A-Za-z0-9-]` in `line`, bounded on both sides by something outside
    that class (or start/end of line) -- not merely appear as a bare
    substring. A plain `candidate in line` test (or even a `\\b`-anchored
    regex -- `\\b` sits at a hyphen boundary too, so it would not help)
    still matches a short slug like `model-cap` INSIDE an unrelated longer
    token like `enforce-model-cap.sh`, because `-` and `.` already read as
    word boundaries to `\\b` even though the slug is embedded, not whole."""
    pattern = (
        r'(?:(?<=' + _TOKEN_BOUNDARY_NEG + r')|\A)'
        + re.escape(candidate)
        + r'(?:(?=' + _TOKEN_BOUNDARY_NEG + r')|\Z)'
    )
    return re.search(pattern, line) is not None


def envelope_slug_candidates(candidates):
    """The slug-shaped subset of `envelope_candidates()` -- no path
    separator -- which is the identity space a row's own `_plan: KEY_` tag
    is compared against. A raw path candidate (e.g. `plans/foo.md`) can
    never equal a bare tag value, so it is excluded here; it still
    participates in the legacy (no-tag) fallback in
    `row_belongs_to_envelope` via a path substring check."""
    return {c for c in candidates if c and '/' not in c and '\\' not in c}


def _specific_slug(c):
    """True if slug candidate `c` is specific enough to match an UNTAGGED
    row by whole-token substring at all. A single-word slug (`cleanup`,
    `fix`, `task`) is indistinguishable from ordinary English prose in a
    row's free-text title -- `token_hit('cleanup', ...)` matches "Run the
    cleanup script" just as readily as a row that actually belongs to a
    `cleanup` envelope, so `reconcile --apply` could close an unrelated row.
    A slug earns a legacy-fallback match only by being a path (checked
    separately by the caller) or by being hyphen-compound (>=2 segments,
    e.g. `hook-timeouts`) -- compound slugs are this repo's actual naming
    convention (`feature_slug` from Stage 0) and specific enough that a
    coincidental prose match is implausible. Tagged rows are unaffected:
    the `_plan:` tag match above never calls this."""
    return '-' in c


def row_belongs_to_envelope(line, name, run, candidates):
    """Does this TASKS.md row belong to this envelope (`name`/`run`, with
    its `candidates` from `envelope_candidates`)? Mirrors
    `plan_row_key_match`'s tag-wins rule (~line 345), generalized to an
    envelope's full candidate slug set instead of one caller-supplied key.

    An explicit `_plan: KEY_` tag wins outright and NEVER falls through to
    a substring guess: it matches only when KEY normalizes
    (`normalize_plan_key`) to one of the envelope's own slug candidates.
    This is what stops a row tagged for a DIFFERENT plan (`_plan:
    hook-timeouts_`) from joining an unrelated envelope (`model-cap`)
    merely because its row text happens to contain that envelope's name as
    a bare substring (`enforce-model-cap.sh` contains `model-cap`) -- the
    live over-closure bug this function replaces (`any(c in line for c in
    candidates)`, with no `_plan:` awareness at all).

    Only a row with NO `_plan:` tag at all (legacy) falls back to the plan
    file's full path (long and close to unique -- a plain substring test is
    fine) or a whole-token hit (`token_hit`) on one of the envelope's slug
    candidates -- never a bare substring on those short, collision-prone
    slugs. Even then, a slug candidate only counts if `_specific_slug` calls
    it specific enough: a single-word slug (`cleanup`, `fix`, `task`) never
    matches an untagged row by itself, however it appears in the text --
    only a path or a hyphen-compound slug can.
    """
    tagm = PLAN_TAG_RE.search(line)
    if tagm:
        tag_key = normalize_plan_key(tagm.group(1))
        slugs = {normalize_plan_key(c) for c in envelope_slug_candidates(candidates)}
        return tag_key in slugs

    for c in candidates:
        if not c:
            continue
        if '/' in c or '\\' in c:
            if c in line:
                return True
        # Known trade-off: a single-word envelope slug with no plan_file never
        # matches an untagged row here (envelopes written by /sdlc always
        # carry plan_file; tag rows with `_plan:` otherwise).
        elif _specific_slug(c) and token_hit(c, line):
            return True
    return False


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
        # Additive fields, same rule and same trailer-only reading: row-level
        # ordering (`after`), conflict (`conflicts`) and lane (`lane`) overrides
        # that `waves` honours over its own inference.
        'after': AFTER_RE.findall(trailer(line)),
        'conflicts': CONFLICTS_RE.findall(trailer(line)),
        'lane': (LANE_RE.search(trailer(line)) or [None, None])[1],
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
            '_name': name,
            '_run': run,
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
            if row_belongs_to_envelope(line, r['_name'], r['_run'], r['_candidates']):
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
            'after': fields['after'],
            'conflicts': fields['conflicts'],
            'lane': fields['lane'],
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


# ---------------------------------------------------------------------------
# `waves` subcommand -- read-only by default; --write renders a lane-grouped
# file. Everything between here and `do_reconcile` belongs to it.
# ---------------------------------------------------------------------------

# Surface globs, in priority order -- a file matching several surfaces takes
# the first. Mirrors the canonical table in
# skills/sdlc/templates/changed-files-gate.md; `discipline.<key>` in
# .claude/project.json overrides each entry.
SURFACE_GLOBS = [
    ('frontend', 'frontend_globs',
     ['**/*.{tsx,jsx,vue,svelte,css,scss}', 'frontend/**/*.ts']),
    ('backend', 'backend_globs', ['**/*.{py,go,rb,java,ts}']),
    ('data', 'data_globs',
     ['**/migrations/**', '**/schema/**', '**/models/**', '*.sql']),
    ('docs', 'docs_globs', ['**/*.md', 'docs/**']),
    ('deploy-delta', 'deploy_delta_globs',
     ['requirements.txt', 'pyproject.toml', 'poetry.lock', 'package.json',
      'package-lock.json', 'pnpm-lock.yaml', 'yarn.lock', 'go.mod',
      'Cargo.toml', 'Gemfile.lock', 'Dockerfile', '**/Dockerfile']),
]

FILES_LINE_RE = re.compile(r'^\s*(?:[-*]\s+)?\**Files\**\s*:\**\s*(.*)$')
PHASE_END_RE = re.compile(r'^#{1,4}\s')
BACKTICK_RE = re.compile(r'`([^`\n]+)`')
PATHISH_RE = re.compile(r'[\w@./-]*[./][\w@./-]*')


def glob_to_regex(glob):
    """Compile a glob supporting `**`, `*`, `?` and `{a,b}` (fnmatch has none
    of `**` or braces). `**/` matches zero or more directories; a pattern with
    no `/` matches at any depth, like a gitignore entry."""
    out = ''
    i, n = 0, len(glob)
    while i < n:
        c = glob[i]
        if glob.startswith('**', i):
            i += 2
            if i < n and glob[i] == '/':
                out += '(?:.*/)?'
                i += 1
            else:
                out += '.*'
            continue
        if c == '*':
            out += '[^/]*'
        elif c == '?':
            out += '[^/]'
        elif c == '{' and glob.find('}', i) != -1:
            j = glob.find('}', i)
            out += '(?:' + '|'.join(re.escape(x) for x in glob[i + 1:j].split(',')) + ')'
            i = j
        else:
            out += re.escape(c)
        i += 1
    prefix = '' if '/' in glob else '(?:.*/)?'
    return re.compile('^' + prefix + out + '$')


def load_surfaces(repo_dir):
    """SURFACE_GLOBS with any `discipline.<key>` override from
    .claude/project.json. A missing or malformed file means defaults."""
    over = {}
    try:
        with open(os.path.join(repo_dir, '.claude', 'project.json'), encoding='utf-8') as f:
            disc = json.load(f).get('discipline')
        if isinstance(disc, dict):
            over = disc
    except Exception:
        pass
    surfaces = []
    for name, key, defaults in SURFACE_GLOBS:
        globs = over.get(key)
        if not (isinstance(globs, list) and all(isinstance(g, str) for g in globs)):
            globs = defaults
        surfaces.append((name, [glob_to_regex(g) for g in globs]))
    return surfaces


def lane_of(files, surfaces):
    """The earliest surface (table order) any of `files` matches, else
    'general'."""
    for name, regexes in surfaces:
        if any(rx.match(f) for f in files for rx in regexes):
            return name
    return 'general'


def clean_path(tok):
    tok = tok.strip().strip('`').replace('\\', '/').rstrip('.,;:)')
    while tok.startswith('./'):
        tok = tok[2:]
    return tok if tok and PATHISH_RE.fullmatch(tok) else ''


def phase_section(plan_lines, phase):
    """Lines of the `#### Phase N` section; with no phase and no phase
    headings anywhere, the `### Implementation Steps` section; else []."""
    heads = [i for i, l in enumerate(plan_lines) if PLAN_HEADING_RE.match(l)]
    if phase is not None:
        for i in heads:
            if int(PLAN_HEADING_RE.match(plan_lines[i]).group(1)) == phase:
                end = len(plan_lines)
                for j in range(i + 1, len(plan_lines)):
                    if PHASE_END_RE.match(plan_lines[j]):
                        end = j
                        break
                return plan_lines[i + 1:end]
        return []
    if heads:
        return []
    for i, l in enumerate(plan_lines):
        if re.match(r'^###\s+Implementation Steps', l):
            end = len(plan_lines)
            for j in range(i + 1, len(plan_lines)):
                if re.match(r'^#{1,3}\s', plan_lines[j]):
                    end = j
                    break
            return plan_lines[i + 1:end]
    return []


def section_files(section, base_dir):
    """Files named by step-level `Files:` lines, plus backticked paths in the
    section that exist on disk."""
    found = []
    for l in section:
        m = FILES_LINE_RE.match(l)
        if m:
            text = m.group(1)
            toks = BACKTICK_RE.findall(text) or PATHISH_RE.findall(text)
            found.extend(clean_path(t) for t in toks)
        else:
            for t in BACKTICK_RE.findall(l):
                p = clean_path(t)
                if p and os.path.isfile(os.path.join(base_dir, p)):
                    found.append(p)
    seen, out = set(), []
    for p in found:
        if p and p not in seen:
            seen.add(p)
            out.append(p)
    return out


def files_intersect(a, b):
    """Paths in both lists; a trailing-slash entry is a directory prefix."""
    hit = set()
    for x in a:
        for y in b:
            if x == y or (x.endswith('/') and y.startswith(x)):
                hit.add(y)
            elif y.endswith('/') and x.startswith(y):
                hit.add(x)
    return sorted(hit)


def plan_file_for(row, base_dir):
    cands = []
    if row['plan']:
        cands.append(row['plan'])
    if row['plan_slug']:
        for d in ('plans', os.path.join('docs', 'plans')):
            for stem in (row['plan_slug'], 'brainstorm-' + row['plan_slug']):
                cands.append(os.path.join(d, stem + '.md'))
    for c in cands:
        p = os.path.join(base_dir, c)
        if os.path.isfile(p):
            return p
    return None


def ref_rows(ref, rows):
    """Rows a `<plan>[:<phase>]` reference (or a linked task-file path) names."""
    if ref.endswith('.md') or '/' in ref:
        return [r for r in rows if r['plan'] and (r['plan'] == ref or r['plan'].endswith(ref))]
    plan, _, ph = ref.partition(':')
    key = normalize_plan_key(plan)
    out = []
    for r in rows:
        if r['pkey'] != key:
            continue
        if ph and not (ph.isdigit() and r['phase'] == int(ph)):
            continue
        out.append(r)
    return out


def _git_exe():
    p = shutil.which('git')
    if not p:
        return None
    low = p.lower().replace('\\', '/')
    if 'system32' in low or 'windowsapps' in low:
        return None
    return p


def _git(exe, cwd, *argv):
    try:
        r = subprocess.run([exe] + list(argv), cwd=cwd, capture_output=True,
                           encoding='utf-8', errors='replace', timeout=30)
    except Exception:
        return None
    return r.stdout if r.returncode == 0 else None


def _norm(path):
    return os.path.normcase(os.path.realpath(path))


def other_worktree_dirt(repo_dir):
    """[{worktree, branch, files}] for every OTHER worktree with uncommitted
    or untracked files. Read-only git; any failure yields []."""
    exe = _git_exe()
    if not exe:
        return []
    top = _git(exe, repo_dir, 'rev-parse', '--show-toplevel')
    listing = _git(exe, repo_dir, 'worktree', 'list', '--porcelain')
    if not top or not listing:
        return []
    here = _norm(top.strip())
    blocks, cur = [], {}
    for l in listing.splitlines() + ['']:
        if not l.strip():
            if cur:
                blocks.append(cur)
            cur = {}
        elif l.startswith('worktree '):
            cur['path'] = l[len('worktree '):].strip()
        elif l.startswith('branch '):
            b = l[len('branch '):].strip()
            cur['branch'] = b[len('refs/heads/'):] if b.startswith('refs/heads/') else b
        elif l.startswith('prunable'):
            cur['prunable'] = True
    out = []
    for b in blocks:
        path = b.get('path')
        if not path or b.get('prunable') or not os.path.isdir(path) or _norm(path) == here:
            continue
        tracked = _git(exe, path, 'diff', '--name-only', 'HEAD')
        untracked = _git(exe, path, 'ls-files', '--others', '--exclude-standard')
        files = sorted({f.strip().replace('\\', '/') for f in
                        ((tracked or '') + '\n' + (untracked or '')).splitlines() if f.strip()})
        if files:
            out.append({'worktree': path, 'branch': b.get('branch'), 'files': files})
    return out


def render_waves(result, command):
    def row_line(r):
        pri = f"({r['priority']}) " if r['priority'] else ''
        tag = ' `[~]`' if r['state'] == '~' else ''
        where = f"TASKS.md:{r['line']}"
        if r['plan_slug']:
            where += f", plan {r['plan_slug']}" + (f" phase {r['phase']}" if r['phase'] is not None else '')
        return f"- {pri}{r['title']}{tag} ({where})"

    out = [f"<!-- generated — edit TASKS.md, not this file. Regenerate: {command} -->",
           '# Action items', '']
    out.append('## Now')
    if not result['now']:
        out.append('')
        out.append('Nothing is ready. See "Needs you" and TASKS.md `## Blocked`.')
    for lane, r in result['now'].items():
        out += ['', f'### {lane}', row_line(r)]
        for o in r.get('overlaps', []):
            out.append(f"  ⚠ dirty in worktree {o['worktree']} ({o['branch']}): " + ', '.join(o['files']))
    out += ['', '## Next']
    if not result['next']:
        out += ['', 'Nothing queued behind the now wave.']
    for lane, rs in result['next'].items():
        out += ['', f'### {lane}'] + [row_line(r) for r in rs]
    if result['needs_you']:
        out += ['', '## Needs you', ''] + [row_line(r) for r in result['needs_you']]
    if result['unknown_files']:
        out += ['', '## Files unknown', '',
                'No files resolvable from the plan phase, so conflicts cannot be inferred:', '']
        out += [row_line(r) for r in result['unknown_files']]
    return '\n'.join(out) + '\n'


BANNER = '<!-- generated — edit TASKS.md'


def do_waves_gate(args):
    base_dir = os.path.dirname(os.path.abspath(args.file)) or os.getcwd()
    cfg = load_json(os.path.join(base_dir, '.claude', 'project.json'))
    ai = {}
    if isinstance(cfg, dict) and isinstance(cfg.get('pipeline'), dict):
        ai = cfg['pipeline'].get('action_items')
        ai = ai if isinstance(ai, dict) else {}
    name = ai.get('file') if isinstance(ai.get('file'), str) and ai.get('file') else 'ACTION_ITEMS.md'
    path = name if os.path.isabs(name) else os.path.join(base_dir, name)
    enabled = ai.get('enabled')
    if enabled is False:
        on, reason = False, 'pipeline.action_items.enabled is false (veto)'
    elif enabled is True:
        on, reason = True, 'pipeline.action_items.enabled is true'
    else:
        first = None
        try:
            with open(path, 'r', encoding='utf-8-sig', newline='') as f:
                first = f.readline()
        except (OSError, UnicodeDecodeError):
            pass
        if first is None:
            on, reason = False, f'enabled unset and {name} does not exist'
        elif first.startswith(BANNER):
            on, reason = True, f'enabled unset and {name} carries the generated banner'
        else:
            on, reason = False, f'enabled unset and {name} is hand-written (no banner)'
    print(json.dumps({'enabled': on, 'file': path, 'reason': reason}))
    return 0


def do_waves(args):
    if args.gate:
        return do_waves_gate(args)
    lines = read_lines(args.file)
    sections = parse_sections(lines)
    base_dir = os.path.dirname(os.path.abspath(args.file)) or os.getcwd()
    surfaces = load_surfaces(base_dir)

    undone = []  # Active / Pending and Blocked rows that are not [x]
    for i, line in enumerate(lines):
        r = parse_row(line)
        sec = section_for(sections, i)
        if r is None or sec is None or r['state'] == 'x':
            continue
        low = sec.lower()
        if 'blocked' in low:
            r['bucket'] = 'blocked'
        elif 'active' in low or 'pending' in low:
            r['bucket'] = 'open'
        else:
            continue
        r['line'] = i + 1
        base = os.path.basename(r['plan'])[:-3] if r['plan'] else None
        slug = r['plan_slug'] or base
        r['pkey'] = normalize_plan_key(slug) if slug else None
        undone.append(r)

    cands = [r for r in undone if r['bucket'] == 'open' and not r['manual']]
    needs_you = [r for r in undone if r['bucket'] == 'open' and r['manual']]

    # Resolve each candidate's plan-phase files and lane.
    plan_cache = {}
    unknown = []
    for r in cands:
        pf = plan_file_for(r, base_dir)
        files = []
        if pf:
            if pf not in plan_cache:
                try:
                    plan_cache[pf] = read_lines(pf)
                except Exception:
                    plan_cache[pf] = []
            files = section_files(phase_section(plan_cache[pf], r['phase']), base_dir)
        r['files'] = files
        r['wlane'] = r['lane'] or (lane_of(files, surfaces) if files else 'general')
        if not files:
            unknown.append(r)

    def blockers_of(r):
        if r['after']:
            hit = [t for ref in r['after'] for t in ref_rows(ref, undone)]
        elif r['pkey'] and r['phase'] is not None:
            hit = [t for t in undone if t['pkey'] == r['pkey']
                   and t['phase'] is not None and t['phase'] < r['phase']]
        else:
            hit = []
        return {t['line'] for t in hit if t is not r}

    for r in cands:
        r['blockers'] = blockers_of(r)

    conflict_pairs = {}  # frozenset({line, line}) -> {source, files}
    for idx, a in enumerate(cands):
        for ref in a['conflicts']:
            for t in ref_rows(ref, cands):
                if t is not a:
                    conflict_pairs.setdefault(frozenset((a['line'], t['line'])),
                                              {'source': 'explicit', 'files': []})
        for b in cands[idx + 1:]:
            if (a['pkey'], a['phase']) == (b['pkey'], b['phase']):
                continue  # siblings of one plan phase share its file list wholesale
            if a['line'] in b['blockers'] or b['line'] in a['blockers']:
                continue  # an order edge already keeps these two apart
            hit = files_intersect(a['files'], b['files'])
            if hit:
                key = frozenset((a['line'], b['line']))
                if key not in conflict_pairs:
                    conflict_pairs[key] = {'source': 'inferred', 'files': hit}

    def conflicts(a, b):
        return frozenset((a['line'], b['line'])) in conflict_pairs

    def order_key(r):
        pri = int(r['priority'][1]) if r['priority'] else 4
        return (0 if r['state'] == '~' else 1, pri, r['line'])

    ready = sorted((r for r in cands if not r['blockers']), key=order_key)
    now_rows = []
    now_lane = {}
    for r in ready:
        if r['wlane'] in now_lane or any(conflicts(r, c) for c in now_rows):
            continue
        now_lane[r['wlane']] = r
        now_rows.append(r)
    now_lines = {r['line'] for r in now_rows}
    next_lane = {}
    for r in sorted(cands, key=order_key):
        if r['line'] in now_lines or not r['blockers'] <= now_lines:
            continue
        next_lane.setdefault(r['wlane'], []).append(r)

    # Worktree overlap: only for rows in the now wave.
    dirt = other_worktree_dirt(base_dir) if now_rows else []

    def public(r):
        return {'line': r['line'], 'state': r['state'], 'priority': r['priority'],
                'title': r['title'], 'plan_slug': r['plan_slug'], 'phase': r['phase'],
                'lane': r.get('wlane') or r['lane'] or 'general'}

    overlaps = []
    now_out = {}
    for lane, r in now_lane.items():
        row = public(r)
        mine = []
        for w in dirt:
            hit = files_intersect(r['files'], w['files'])
            if hit:
                mine.append({'worktree': w['worktree'], 'branch': w['branch'], 'files': hit})
        if mine:
            row['overlaps'] = mine
            overlaps.append({'line': r['line'], 'lane': lane, 'overlaps': mine})
        now_out[lane] = row

    conflicts_out = []
    for key, info in sorted(conflict_pairs.items(), key=lambda kv: sorted(kv[0])):
        x, y = sorted(key)
        conflicts_out.append({'lines': [x, y], 'source': info['source'], 'files': info['files']})

    open_lines = sorted(lines[r['line'] - 1].strip() for r in undone)
    result = {
        'schema': 1,
        'generated_at': iso_utc(datetime.now(timezone.utc)),
        'summary': {
            'now': len(now_out),
            'lanes': len(set(now_out) | set(next_lane)),
            'next': sum(len(rs) for rs in next_lane.values()),
            'needs_you': len(needs_you),
            'unknown_files': len(unknown),
            'conflicts': len(conflicts_out),
        },
        # Fingerprint of the undone-row set, so a caller can tell whether the
        # backlog changed since it last looked.
        'open_hash': hashlib.sha256('\n'.join(open_lines).encode('utf-8')).hexdigest()[:16],
        'now': now_out,
        'next': {lane: [public(r) for r in rs] for lane, rs in next_lane.items()},
        'needs_you': [public(r) for r in needs_you],
        'unknown_files': [public(r) for r in unknown],
        'overlaps': overlaps,
        'conflicts': conflicts_out,
    }
    if args.write:
        command = f'bash scripts/close-tasks.sh waves --file {args.file} --write {args.write}'
        # Only a file this command generated (banner on line 1, BOM/CRLF
        # tolerated) or a missing one is written; a hand-written file of the
        # same name is never overwritten.
        hand_written = False
        if os.path.exists(args.write):
            try:
                with open(args.write, 'r', encoding='utf-8-sig', newline='') as f:
                    first = f.readline()
            except (OSError, UnicodeDecodeError):
                first = ''
            hand_written = not first.startswith('<!-- generated — edit TASKS.md')
        if hand_written:
            result['written'] = None
            result['write_skipped'] = (f'{args.write} exists and is not generated '
                                       '(no banner on line 1) — left untouched')
            print(f"close-tasks: {result['write_skipped']}", file=sys.stderr)
        else:
            with open(args.write, 'w', encoding='utf-8', newline='\n') as f:
                f.write(render_waves(result, command))
            result['written'] = args.write
    print(json.dumps(result, indent=2))
    return 0


# ---------------------------------------------------------------------------
# `tag` subcommand -- the only writer of the `_after:` / `_conflicts:` /
# `_lane:` row tags. It edits one open row's trailer and nothing else.
# ---------------------------------------------------------------------------

TAG_SPEC_RE = re.compile(r'^_?(after|conflicts|lane):\s*([a-z0-9:/.-]+?)_?$')


def tag_fail(msg, code, **extra):
    out = {'error': msg, 'code': code}
    out.update(extra)
    print(json.dumps(out))
    return 1


def split_eol(raw_line):
    body = raw_line.rstrip('\r\n')
    return body, raw_line[len(body):]


def do_tag(args):
    if not args.row:
        return tag_fail('--row <needle> is required', 'no_row')
    if bool(args.add) == bool(args.remove):
        return tag_fail('give exactly one of --add or --remove', 'bad_mode')
    spec = args.add or args.remove
    m = TAG_SPEC_RE.match(spec.strip())
    if not m:
        return tag_fail(f'bad tag {spec!r}: want after:<plan>[:<phase>], conflicts:<plan>[:<phase>] '
                        f'or lane:<name> with values in [a-z0-9:/.-]', 'bad_grammar')
    key, value = m.group(1), m.group(2)
    base_dir = os.path.dirname(os.path.abspath(args.file)) or os.getcwd()
    if key == 'lane':
        if not LANE_RE.fullmatch(f'_lane: {value}_'):
            return tag_fail(f'bad lane {value!r}: values are [a-z0-9.-]', 'bad_grammar')
    elif args.add:
        ref, _, ph = value.partition(':')
        is_path = ref.endswith('.md') or '/' in ref
        if not ref or (is_path and ph) or (ph and not ph.isdigit()):
            return tag_fail(f'bad reference {value!r}: want <plan>[:<phase>]', 'bad_grammar')
        pf = plan_file_for({'plan': ref if is_path else None, 'plan_slug': None if is_path else ref}, base_dir)
        if not pf:
            return tag_fail(f'no plan found for {ref!r}', 'unknown_plan')
        if ph:
            try:
                heads = [int(PLAN_HEADING_RE.match(l).group(1)) for l in read_lines(pf)
                         if PLAN_HEADING_RE.match(l)]
            except Exception:
                heads = []
            if int(ph) not in heads:
                return tag_fail(f'plan {ref!r} has no Phase {ph}', 'unknown_phase')

    with open(args.file, encoding='utf-8', newline='') as f:
        raw = f.read()
    raw_lines = raw.splitlines(keepends=True)
    bodies = [split_eol(l)[0] for l in raw_lines]
    sections = parse_sections(bodies)
    hits = []
    for i, line in enumerate(bodies):
        rm = ROW_RE.match(line)
        if not rm or rm.group(2) == 'x':
            continue
        sec = section_for(sections, i)
        if sec is None or sec.lower() == 'done':
            continue
        if token_hit(args.row, line):
            hits.append(i)
    if not hits:
        return tag_fail(f'no open row matches {args.row!r}', 'no_match')
    if len(hits) > 1:
        return tag_fail(f'{len(hits)} open rows match {args.row!r}; use a more specific needle',
                        'ambiguous', lines=[h + 1 for h in hits])
    i = hits[0]
    line = bodies[i]
    tr = trailer(line)
    token = f'_{key}: {value}_'
    existing = {'after': AFTER_RE, 'conflicts': CONFLICTS_RE, 'lane': LANE_RE}[key].findall(tr)
    changed = False
    if args.add:
        if key == 'lane' and existing and existing != [value]:
            return tag_fail(f'row already has _lane: {existing[0]}_; remove it first', 'lane_set', line=i + 1)
        if value not in existing:
            line = line.rstrip() + (f' \xb7 {token}' if tr else f' — {token}')
            changed = True
    elif value in existing:
        idx = line.rfind(' — ')
        head, tail = line[:idx + 3], line[idx + 3:]
        tail = re.sub(r'\s*(?:\xb7\s*)?' + re.escape(token), '', tail, count=1)
        line = (head + tail).rstrip()
        if line.endswith(' —'):
            line = line[:-2].rstrip()
        changed = True
    if changed:
        raw_lines[i] = line + split_eol(raw_lines[i])[1]
        tmp = f'{args.file}.tmp{os.getpid()}'
        with open(tmp, 'w', encoding='utf-8', newline='') as f:
            f.write(''.join(raw_lines))
        os.replace(tmp, args.file)
    print(json.dumps({'line': i + 1, 'tag': token, 'action': 'add' if args.add else 'remove',
                      'changed': changed, 'text': line.strip()}, indent=2))
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
            if row_belongs_to_envelope(line, name, run, candidates):
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
            # parked-on-purpose rows (deliberately left for a later phase the
            # run never took) from being reported every time.
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

        # Close rows for terminal envelopes that still show them open -- `[~]`
        # ONLY. A `[ ]` row referencing the same terminal envelope was never
        # taken by this run's scope gate (a phase-less plan cut by step count
        # parks later rows `[ ]` with no `_phase:` tag, so the `taken_phases`
        # exemption above can't apply), so --apply must not be the back door
        # that closes a row nobody started -- `close --scope plan` already
        # enforces the identical rule for a live run ("only rows THIS run's
        # Stage 0 marked in-progress"). The `[ ]` row stays in `drift` above so
        # a human still sees it; it is simply never auto-closed here.
        terminal_open = [d for d in drift if d["type"] == "terminal_envelope_open_rows"]
        if terminal_open:
            close_idx = []
            sections3 = parse_sections(new_lines)
            for d in terminal_open:
                for row_text in d["rows"]:
                    for i, line in enumerate(new_lines):
                        if line.strip() == row_text and ROW_RE.match(line):
                            row_m = ROW_RE.match(line)
                            if row_m.group(2) == '~':
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
    a.in_place = False
    a.gate = False
    a.apply = False
    a.repo_name = ''
    a.write = ''
    a.row = ''
    a.add = ''
    a.remove = ''
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
        elif tok == '--in-place':
            a.in_place = True
        elif tok == '--gate':
            a.gate = True
        elif tok == '--apply':
            a.apply = True
        elif tok == '--repo-name':
            a.repo_name = next(it)
        elif tok == '--write':
            a.write = next(it)
        elif tok == '--row':
            a.row = next(it)
        elif tok == '--add':
            a.add = next(it)
        elif tok == '--remove':
            a.remove = next(it)

    if sub == 'rows':
        return do_rows(a)
    elif sub == 'close':
        return do_close(a)
    elif sub == 'reconcile':
        return do_reconcile(a)
    elif sub == 'board':
        return do_board(a)
    elif sub == 'waves':
        return do_waves(a)
    elif sub == 'tag':
        return do_tag(a)
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
    [ "$IN_PLACE" -eq 1 ] && ARGS+=("--in-place")
    ;;
  reconcile)
    ARGS+=("--pipeline-dir" "$PIPELINE_DIR")
    [ "$APPLY" -eq 1 ] && ARGS+=("--apply")
    ;;
  board)
    ARGS+=("--pipeline-dir" "$PIPELINE_DIR")
    [ -n "$REPO_NAME" ] && ARGS+=("--repo-name" "$REPO_NAME")
    ;;
  waves)
    [ -n "$WRITE" ] && ARGS+=("--write" "$WRITE")
    [ "$GATE" -eq 1 ] && ARGS+=("--gate")
    ;;
  tag)
    ARGS+=("--row" "$ROW")
    [ -n "$ADD" ] && ARGS+=("--add" "$ADD")
    [ -n "$REMOVE" ] && ARGS+=("--remove" "$REMOVE")
    ;;
  *)
    usage
    exit 2
    ;;
esac

"$PY" "$PYCORE" "${ARGS[@]+"${ARGS[@]}"}"
exit $?
