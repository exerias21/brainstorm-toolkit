## Brainstorm Result: `close-tasks.sh board` — a read-only JSON view of this repo's work state

### Direction

Add a third subcommand to `scripts/close-tasks.sh` that emits, as JSON, everything this repo knows
about its own work: `TASKS.md` rows joined to `.claude/pipeline/*/run.json` envelopes. Read-only,
no flags beyond `--file`, no network, no writes ever.

**Why this belongs in the toolkit and the board that consumes it does not.** The test is what
`setup.sh` does with a file. `scripts/` is copied wholesale into every consumer repo
(`setup.sh:288-294`, minus `scripts/ci/` and `sync-global.sh`), so anything landing there ships to
every install. A per-repo JSON export of that repo's own contract passes that test — any consumer
benefits from being able to ask "what is the state of my work here?" in a machine-readable form. A
cross-machine dashboard fails it: no consumer wants a copy of someone else's console.

**This is independently useful.** Even if no board is ever built, this subcommand gives
`/sdlc-status`, `/repo-health`, a shell prompt, a CI step or a `jq` one-liner a single stable way
to read work state, instead of each re-deriving it from two file formats. It is the *contract*;
consumers of that contract are somebody else's problem.

### Conventions & reuse

- **Reuse:** `parse_sections` (`close-tasks.sh:132`), `ROW_RE` (`:123`), `PLAN_TAG_RE` (`:124`),
  `envelope_candidates` (`:305`). `do_reconcile` (`:328`) is already read-only unless `--apply` is
  passed, so the read path exists and is proven.
- **Be honest about what is NOT free.** `reconcile` only extracts row *text* for **drifted** rows;
  it never builds a per-row record. So this needs a genuinely new row→JSON mapper built *on* those
  helpers. Two specific gaps found during validation:
  - there is **no `PHASE_RE`**, though rows already carry `_phase: N_`;
  - there is **no `started_at` on `Active / Pending` rows at all** — only `_completed_at:` on Done
    rows (`:165-167`). It must come from the joined envelope or be omitted.
- **Envelope reality, measured on 8 real files:** 3 of 4 sampled lack `updated_at` entirely, and
  `plan_hash` is present in 2 and correctly formatted (`sha256:<hex>`) in only 1 — `toolkit-steals`
  carries a bare 16-hex string. `envelope_candidates` already handles the three non-canonical key
  spellings (`plan_file` / `input` / `data.plan_target`). **Treat every documented field as
  optional**; fall back to file mtime for ordering, and never fail on a malformed envelope.
- **Follow:** the existing jq-or-python fallback and project-location idiom in the same file, and
  `scripts/hooks/run-cost-report.sh`'s *runs*-probe for interpreter resolution.
- **New:** nothing outside `close-tasks.sh` and its docs. No config keys, no hook, no skill.

### Implementation Steps

1. **`close-tasks.sh board --file TASKS.md [--repo-name NAME]`** emitting one JSON object:
   ```
   {
     "schema": 1,
     "repo": "<basename or --repo-name>",
     "repo_path": "<abs path>",
     "generated_at": "<iso8601>",
     "tasks": [ { "state": " |~|x", "section": "Active / Pending|Blocked|Done",
                  "priority": "P1|P2|P3|null", "title": "...", "plan": "plans/x.md|null",
                  "plan_slug": "...|null", "phase": 2, "blocked_reason": "...|null",
                  "started_at": "...|null", "completed_at": "...|null", "line": 42 } ],
     "runs":  [ { "slug": "...", "stage": "...", "status": "...", "pipeline": "sdlc",
                  "plan_file": "...|null", "updated_at": "...|null", "mtime": "<iso8601>",
                  "plan_hash": "...|null", "terminal": true } ],
     "warnings": [ "..." ]
   }
   ```
   `terminal` is derived (`complete|failed` ⇒ true), so a consumer never re-implements that rule.
   `warnings[]` carries non-fatal parse problems — a malformed envelope is a warning, never an exit.
2. **Add `PHASE_RE`** and parse `_phase: N_` into `tasks[].phase`. Keep it optional; an untagged
   row is `null`, not an error.
3. **Join rows to runs** on `plan_slug`, using the same slug derivation `reconcile` uses. Where a
   row's slug has no envelope, `runs` simply has no entry — the *consumer* decides that means
   "planned, never run". This subcommand reports state; it does not classify it.
4. **Ordering guarantees, stated in the output contract:** `tasks[]` in file order (so `line` is
   meaningful and a consumer can round-trip to the source); `runs[]` newest-first by
   `updated_at or mtime`. Document that `updated_at` is frequently absent in the wild and that
   mtime is the fallback — a consumer sorting on `updated_at` alone would drop most real runs.
5. **Exit codes:** `0` always when the file parses, even with warnings. `1` only when `--file` is
   missing or unreadable. A board polling this must never see a non-zero exit for ordinary drift.
6. **Tests.** Extend `scripts/ci/test-hooks.sh` (or add `scripts/ci/test-close-tasks.sh` if that
   file is getting long) with fixture cases: a row with `_phase:`, a row without, a `[~]` row, a
   `Blocked` row with `_blocked_reason:`, an envelope missing `updated_at`, an envelope with the
   bare-hex `plan_hash`, and a deliberately malformed envelope that must produce a warning and
   exit 0. Assert on parsed JSON, not on string matching.
7. **Docs.** One README bullet under the scripts list, and the output contract in
   `docs/CONVENTIONS.md` (or a short `docs/BOARD-JSON.md` if it does not fit) so an external
   consumer has something stable to code against. State the schema version rule: additive fields
   never bump `schema`; a removed or retyped field does.

### Cross-Module Touchpoints

- `close-tasks.sh`'s existing `close` and `reconcile` behaviour must be untouched — re-run the
  close/reconcile probes and `scripts/ci/test-hooks.sh` after.
- `/sdlc-status` and `/repo-health` Check 11 are the natural first consumers, but **do not migrate
  them in this plan.** Ship the contract, prove it, migrate later if it earns it.
- No `project.json` keys. Say so explicitly so nobody adds one — and note that
  `check_config_keys` (`check_contracts.py:219`) would not catch it if they did, since it never
  scans `scripts/`.

### Acceptance criteria

- `bash scripts/close-tasks.sh board --file TASKS.md | python -c "import json,sys;json.load(sys.stdin)"`
  parses, on this repo's real `TASKS.md` and its 8 real envelopes.
- Every `Active / Pending` row appears in `tasks[]` with its correct `state`, `priority`, `section`
  and `line`; a `_phase:`-tagged row reports its phase; an untagged row reports `null`.
- The envelope missing `updated_at` still appears in `runs[]`, ordered by mtime.
- A deliberately malformed envelope yields a `warnings[]` entry and **exit 0** (verify, then revert).
- `git diff` is empty after any run — this subcommand writes nothing, ever.
- `validate_skills.py`, `check_contracts.py`, `test-hooks.sh` and a fresh `--tools all` install all
  pass, and the subcommand is present in a consumer install.

### Open Questions

- Should `board` accept multiple `--file` arguments for a monorepo with several `TASKS.md`?
  Recommend no — one repo, one call; aggregation is the consumer's job by design.
- Should it emit `plans/*.md` that have **no** `TASKS.md` row at all? Recommend yes, as a
  `plans_without_rows[]` array — that set is precisely "planned but never queued", which is the
  most actionable thing a reviewer wants, and only this script is positioned to compute it.

### Appendix: Alternatives Considered

- **Put the whole board here** — rejected. `setup.sh` copies `scripts/` to every consumer, so a
  cross-machine dashboard would ship to every repo it aggregates. The toolkit is per-repo; a board
  is per-machine across repos. Also: this repo makes **zero** outbound network calls today and
  advertises that; a long-running HTTP server is a category change, not a scope increase.
- **A new `/board` skill** — rejected. Its body would be "run this script", which CLAUDE.md warns
  against and which would cost its whole file in three trees forever.
- **Have consumers parse `TASKS.md` themselves** — rejected: that is the status quo, and it is why
  `reconcile` had to exist. Two parsers already drift; a documented JSON contract is the fix.
