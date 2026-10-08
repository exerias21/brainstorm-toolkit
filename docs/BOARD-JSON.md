# `close-tasks.sh board` — JSON work-state export

> **✓ Live contract — current and maintained.**

`bash scripts/close-tasks.sh board --file TASKS.md [--repo-name NAME] [--pipeline-dir .claude/pipeline]`
emits **one JSON object** on stdout describing everything this repo knows about its own work:
`TASKS.md` rows joined against `.claude/pipeline/*/run.json` envelopes.

**Read-only, always.** There is no flag that makes it write. It never touches `close` or
`reconcile` behaviour, never edits `TASKS.md`, and never writes a pipeline envelope.

Origin: the `board-json-export` plan, removed once delivered — its "Why this belongs in the
toolkit" rationale (an export, not a dashboard) is in git history.

**See also:** `close-tasks.sh rows --plan <slug>` — the sibling read-only subcommand `/sdlc`
Stage 0 uses to look up one plan's rows. It shares this subcommand's row parser and returns
the same `{match_key, matched[]}` shape rather than the full board.

## Output shape

```jsonc
{
  "schema": 1,
  "repo": "<basename of the TASKS.md directory, or --repo-name>",
  "repo_path": "<absolute path to that directory>",
  "generated_at": "<iso8601 UTC, e.g. 2026-09-08T23:18:13Z>",
  "tasks": [
    {
      "state": " ",              // " " | "~" | "x"
      "section": "Active / Pending", // the ## heading the row is filed under
      "priority": "P1",           // "P1" | "P2" | "P3" | null
      "title": "...",             // row prose, metadata tags stripped
      "plan": "plans/x.md",       // a plans/*.md or docs/plans/*.md path found in the row text, or null
      "plan_slug": "x",           // the `_plan: x_` tag value, or null (NOT derived from `plan`)
      "phase": 2,                 // the `_phase: N_` tag value as an int, or null
      "blocked_reason": null,     // the `_blocked_reason: ..._` tag value, or null
      "started_at": null,         // from the JOINED envelope's `started_at` only -- rows carry no such tag
      "completed_at": null,       // the `_completed_at: ..._` tag value, or null
      "followup": false,          // true iff `_followup_` appears in the row's TRAILER (after the last " -- ")
      "manual": false,            // true iff `_manual_` appears in the row's TRAILER -- a human-only row
      "after": [],                // `_after: <plan>[:<phase>]_` values from the TRAILER (list; [] when none)
      "conflicts": [],            // `_conflicts: <plan>[:<phase>]_` values from the TRAILER
      "lane": null,               // the `_lane: <name>_` value from the TRAILER, or null
      "line": 15                  // 1-based line number in --file
    }
  ],
  "runs": [
    {
      "slug": "board-json-export",
      "stage": "handoff",
      "status": "complete",
      "pipeline": "sdlc",
      "plan_file": "docs/plans/board-json-export.md", // plan_file, else input, else data.plan_target
      "updated_at": null,         // raw envelope field, frequently absent -- do not assume it's set
      "mtime": "2026-09-05T12:17:43Z", // run.json's file mtime -- the ordering fallback
      "plan_hash": "sha256:...", // passed through raw; format is NOT validated (some envelopes carry a bare hex string)
      "terminal": true            // DERIVED: true iff status is complete/completed/failed
    }
  ],
  "plans_without_rows": ["plans/foo.md"],
  "warnings": ["envelope 'x': unreadable/malformed run.json (JSONDecodeError) -- skipped"]
}
```

## Ordering contract

- `tasks[]` is in **file order** — `line` is meaningful and a consumer can round-trip to the
  source row.
- `runs[]` is **newest-first**, sorted by `updated_at` when it parses, else by the envelope
  file's own mtime. Measured across this repo's real envelopes: most lack `updated_at`
  entirely, so a consumer that sorts on `updated_at` alone silently drops most real runs — sort
  on `updated_at or mtime`, which is exactly what this subcommand already did for you.

## Field notes (read before building a consumer)

- **`started_at` is never invented.** `TASKS.md` rows carry no `_started_at:` tag at all today
  (only `_completed_at:` exists on `## Done` rows). The field is populated **only** by joining
  the row to a pipeline envelope (same candidate-matching `reconcile` uses: envelope directory
  name, `plan_file`/`input`/`data.plan_target`, and `brainstorm-`/`team-brainstorm-`-stripped
  variants) and reading that envelope's own `started_at`. No match -> `null`.
- **`plan_slug` comes only from the `_plan: slug_` tag.** It is not derived from the `plan`
  path when the tag is absent — a row can have a `plan` (path found in its text) with no
  `plan_slug` (no tag), and the two fields are deliberately not filled in from each other.
- **`followup` and `manual` match only in the row's trailer** — the text after the last
  ` — ` (space, em dash, space) on the line. A title that merely *mentions* `_followup_` or
  `_manual_` in its prose (rather than carrying it as a trailing tag) is not flagged.
- **A malformed envelope is a `warnings[]` entry, never a crash.** Every documented envelope
  field is optional; an unreadable or non-object `run.json` is skipped and reported in
  `warnings[]`, and an unparsable `updated_at` falls back to mtime with its own warning.
  `plan_hash` format is not validated at all — pass it through as-is.
- **`plans_without_rows[]`** lists every `plans/*.md` file (top-level `plans/` dir only) with no
  `TASKS.md` row referencing it — "planned but never queued". This subcommand does not scan
  `docs/plans/`, which holds a different class of document in this repo.
- The join between `tasks[]` and `runs[]` is **not performed for you beyond `started_at`** — a
  row's `plan_slug` (or `plan`) and a run's `slug`/`plan_file` are the keys a consumer joins on.
  This subcommand reports state; it does not classify "planned vs. never run" beyond
  `plans_without_rows[]`.

## Exit codes

- `0` whenever `--file` parses, warnings or not. A board polling this must never see a
  non-zero exit for ordinary drift (a malformed envelope, an unparsable timestamp, etc.).
- `1` only when `--file` is missing or unreadable.

## Schema-version rule

`schema` is `1` today. **Additive fields never bump it** — a new key appearing in `tasks[]`,
`runs[]`, or the top-level object is always safe to ignore. **A removed or retyped field
bumps it** — if `schema` changes, assume every field's shape needs re-checking before trusting
old parsing code against the new output.

# `close-tasks.sh waves` — what runs when

`waves --file TASKS.md --gate` prints `{enabled, file, reason}` for the action-items enable rule
(`pipeline.action_items.enabled: false` vetoes; `true` enables; absent → on only if the configured
`file` exists with the generated banner on line 1) and nothing else.

`waves --file TASKS.md [--write PATH]` groups the open `## Active / Pending` rows into waves.
Read-only unless `--write` is passed; it never edits `TASKS.md`. Exit codes match `board`.

```jsonc
{
  "schema": 1,
  "generated_at": "<iso8601 UTC>",
  "summary": { "now": 1, "lanes": 2, "next": 3, "needs_you": 0, "unknown_files": 1, "conflicts": 0 },
  "open_hash": "<16 hex chars>",
  "now":  { "<lane>": { "line": 15, "state": " ", "priority": "P2", "title": "...",
                        "plan_slug": "x", "phase": 1, "lane": "<lane>",
                        "overlaps": [ { "worktree": "/path", "branch": "b", "files": ["a.py"] } ] } },
  "next": { "<lane>": [ { /* same row shape, no overlaps */ } ] },
  "needs_you":     [ { /* `_manual_` rows */ } ],
  "unknown_files": [ { /* candidate rows whose plan phase names no files */ } ],
  "overlaps":      [ { "line": 15, "lane": "<lane>", "overlaps": [ /* as on the row */ ] } ],
  "conflicts":     [ { "lines": [15, 22], "source": "inferred|explicit", "files": ["a.py"] } ]
}
```

- **now** is the rows with no open order edge, at most one per lane (`[~]` first, then
  priority, then file order), and no two that conflict. **next** is the rows that become
  ready if every now row closes. An empty now-wave is `"now": {}` — callers park and report;
  they never fall back to plain priority order.
- **Order edges:** within one `_plan:`, a row waits while a lower `_phase:` of that plan has
  a not-done row (`Active / Pending` or `Blocked`). An `_after:` tag replaces that inference
  for its row. **Conflicts:** `_conflicts:` plus two rows (of different plan phases) whose
  plan-phase file lists intersect. A row with no resolvable files has no inferred conflicts and
  is listed in `unknown_files`.
- **Files** for a row come from the `Files:` lines and existing backticked repo paths in its
  plan's `#### Phase N` section; the plan file comes from the row's plan path, else its
  `_plan:` slug under `plans/` then `docs/plans/`, all resolved against the `TASKS.md`
  directory. **Lane:** `_lane:` > the first surface (changed-files-gate order, with
  the gate's per-surface glob overrides) any of its files matches > `general`.
- **`overlaps`** is read-only git (`worktree list`, `diff --name-only HEAD`, untracked files)
  over every OTHER worktree; it is `[]` outside git, without git, or on any git failure.
- **`--write PATH`** also renders the lane-grouped markdown (with a "generated — edit
  TASKS.md, not this file" banner and the generating command) and adds `"written": PATH` to
  the JSON. The file carries no timestamp, so identical input yields identical bytes. An existing
  file whose line 1 is not that banner (BOM/CRLF tolerated) is a hand-written file and is never
  overwritten: the JSON gets `"written": null` and `"write_skipped": "<path> exists and is not
  generated (no banner on line 1) — left untouched"`, stderr gets one warning, and the exit is
  still 0. A missing file is created; a bannered one is regenerated.
- **`summary`** is counts only: `now` rows, `lanes` (distinct lanes across now and next),
  `next` rows, `needs_you`, `unknown_files`, `conflicts`. **`open_hash`** fingerprints the
  sorted not-done rows (Active / Pending and Blocked), so a caller can tell whether the backlog
  changed since the hash it stored.
- **Schema:** `schema` is `1`; additive fields never bump it, same rule as `board`.

# `close-tasks.sh tag` — the one writer of row tags

`tag --file TASKS.md --row NEEDLE (--add|--remove) TAG` adds or removes one `_after:`,
`_conflicts:` or `_lane:` tag on a single open row. `TAG` is `after:<plan>[:<phase>]`,
`conflicts:<plan>[:<phase>]` or `lane:<name>` (values `[a-z0-9:/.-]`; a lane is `[a-z0-9.-]`).

```jsonc
{ "line": 12, "tag": "_after: p:1_", "action": "add|remove", "changed": true,
  "text": "<the row after the edit>" }
// refusal, exit 1:
{ "error": "...", "code": "bad_grammar|unknown_plan|unknown_phase|no_match|ambiguous|lane_set|bad_mode|no_row" }
```

- `NEEDLE` must whole-token match exactly one open row (not `[x]`, not under `## Done`);
  zero matches is `no_match`, several is `ambiguous` (with `lines[]`).
- On `--add`, a referenced plan must resolve (slug under `plans/` then `docs/plans/`, or a
  linked task-file path) and a referenced phase must have a `#### Phase N` heading. `--remove`
  skips those checks so a stale tag can always be cleared.
- Only the row's trailer changes: the tag is appended as `· _tag: v_` (or ` — _tag: v_` on a
  row with no trailer), never the checkbox. `changed: false` means the tag was already present
  (add) or absent (remove); the file is not rewritten. A row holds one `_lane:` — adding a
  different one is `lane_set`.
- The write goes through a same-directory temp file and `os.replace`; line endings (CRLF
  included) and non-ASCII bytes are preserved.
