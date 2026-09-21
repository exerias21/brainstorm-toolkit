# `close-tasks.sh board` — JSON work-state export

> **✓ Live contract — current and maintained.**

`bash scripts/close-tasks.sh board --file TASKS.md [--repo-name NAME] [--pipeline-dir .claude/pipeline]`
emits **one JSON object** on stdout describing everything this repo knows about its own work:
`TASKS.md` rows joined against `.claude/pipeline/*/run.json` envelopes.

**Read-only, always.** There is no flag that makes it write. It never touches `close` or
`reconcile` behaviour, never edits `TASKS.md`, and never writes a pipeline envelope.

Origin: `docs/plans/board-json-export.md`. Rationale for why this lives here and not a
cross-machine dashboard: see that plan's "Why this belongs in the toolkit" section.

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
