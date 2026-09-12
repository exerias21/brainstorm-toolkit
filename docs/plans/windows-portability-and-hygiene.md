## Brainstorm Result: Windows portability — stop the bleeding, then stop the recurrence

### Direction

Two shipping bugs make this toolkit partly non-functional on Windows, and both were found by
being bitten rather than by any check. They are the same shape, and that shape is the point:
**the shell scripts know the platform; the wiring and the prose never got told.**

- `hooks/hooks.json` — the plugin-shipped wiring — spawns five `.sh` files with **no
  interpreter**. Windows cannot exec a `.sh` (`WinError 193`, surfaced through libuv as
  `EFTYPE`), so every plugin-installed hook fails. `setup.sh:426` gets this right
  (`cmd="bash $hook_path_escaped"`), which is why the copy-install path works and the plugin
  path never has. Consequence: for any Windows marketplace install, the `.next-action` seam,
  auto-continue, `stop-gate` and the cost report have **never run**, silently.
- **14 bare `python3` invocations across 7 shipped files.** On Windows `python3` resolves to
  the Microsoft Store stub (`WindowsApps\python3.exe`), which prints "Python was not found"
  and opens the Store. `skills/sdlc/templates/stage-5-skill-repo.md:18` fires on **every**
  `/sdlc` run in a skill repo, and `templates/project.json.example:33` ships
  `"runner": "python3 scripts/eval-runner.py"` as the default into **every repo you onboard**.
  Meanwhile five scripts (`close-tasks.sh`, `record-decision.sh`, and three hooks) already
  probe `python3 → python → py` and verify the interpreter *runs* — the knowledge exists, it
  just never reached the prose. `GOTCHAS.md` has zero entries about it.

Fixing the instances is the easy half. The valuable half is a **deterministic check**, because
this is precisely the case the doctrine shipped last run describes: the rule must hold when the
author forgets, the check needs no judgment, and `scripts/ci/` can exercise it. A seventh
`check_contracts.py` check costs a few dozen lines and ends the class.

The run also closes two backlog items that this session's evidence settled. **RUN-DURABILITY
(P2) does not reproduce**: across all nine envelopes on disk, once lane sidecars (`decompose`,
`converge`, `implement-<lane>`) are attributed to their parent stage, **zero** show any
completed-but-unrecorded stage. Its cited 70-minute observation was on `/sdlc-lite`, a pipeline
that no longer exists. It should be closed with that evidence rather than left to be
re-confirmed by the same misreading — which is exactly what happened during the watch that
produced this plan.

### Conventions & reuse

- **Reuse the probe idiom verbatim** — `for c in python3 python py; do command -v "$c" && "$c" -c 'pass'`.
  It appears identically in `close-tasks.sh:78-80`, `record-decision.sh`, `reseed-context.sh`,
  `run-cost-report.sh:28-32` and `stop-gate.sh`. Probing that the interpreter **runs** (not
  merely resolves) is the whole point — the Store stub resolves fine and then exits non-zero.
- **Follow `setup.sh:426`** for hook command construction: `bash` + a **quoted** path. Quoting
  is not cosmetic — `C:\Users\First Last\` is ordinary and an unquoted path splits the argument.
- **Follow `check_contracts.py`'s existing check shape** for the new check: a `Finding` NamedTuple
  with `check=` set, registered in `run_all()`, scoped via `scope_files()`, and exercised by
  `--self-test`. Do not invent a parallel reporting path.
- **Follow `GOTCHAS.md`'s existing entry format** for the new entry.
- **New (justified):** nothing. Every piece of this reuses an idiom already in the repo — which
  is itself the finding: the fix was available the whole time and never propagated.

### Implementation Steps

#### Phase 1 — the two bugs, and the check that ends their class

1. **Fix `hooks/hooks.json` — all five commands.** Change each from
   `${CLAUDE_PLUGIN_ROOT}/scripts/hooks/<x>.sh` to `bash "${CLAUDE_PLUGIN_ROOT}/scripts/hooks/<x>.sh"`.
   Five entries: `next-action`, `run-cost-report`, `stop-gate` (Stop), `reseed-context`
   (SessionStart), `enforce-model-cap` (PreToolUse). `hooks/` is **not** in `SHIPPED_GLOBS`, so
   this alone needs no version bump. Files: `hooks/hooks.json`.

2. **Verify the hooks actually fire — this is the acceptance test, not a formality.** The bug
   was invisible for the entire life of the plugin because nothing exercised it. After step 1,
   confirm on Windows that a Stop event runs `next-action.sh` (a queued `.claude/.next-action`
   line surfaces as `Next:`) rather than erroring. Note the constraint: a *plugin* hook can only
   be verified through a real plugin install, so this needs a `claude plugin update` + restart,
   not a local file edit. Files: none (verification).

3. **`data.cost` is unverified because of step 1.** The previous run built cost persistence into
   `run-cost-report.sh`, but that hook has never executed here, so `data.cost` is absent from
   every envelope and the feature has never actually run. Once hooks fire, confirm a completed
   run writes `data.cost` with the five fields, and that the write is additive and atomic — it
   mutates the same `run.json` that `stop-gate.sh`, `--resume`'s `plan_hash` check and
   `close-tasks.sh reconcile` all read. Files: none (verification), possibly
   `scripts/hooks/run-cost-report.sh` if the write proves non-atomic.

4. **Fix the 14 bare `python3` sites.** In order of blast radius:
   `templates/project.json.example:32-33` (ships to every onboarded repo),
   `skills/sdlc/templates/stage-5-skill-repo.md:18` (fires on every skill-repo `/sdlc` run),
   `skills/test-check/SKILL.md:57,70`, `agents/e2e-test-runner.md:61`,
   `skills/code-tour/SKILL.md:59-61`, `skills/code-tour/references/tooling.md:227`, and
   `skills/code-tour/scripts/docstring_audit.py:32-39` (its own `--help` text).
   **See Open Questions for what to replace them with — that is a real decision, not a
   find-and-replace.** Note `code-tour` has no line ceiling and `test-check`/`stage-5-skill-repo`
   have room, so a slightly longer portable form is affordable.

5. **Add `check_contracts.py` check 7 — `portable-invocation`.** Two rules, both deterministic:
   (a) no bare `python3 ` in `scope_files()` (the probe idiom and prose *about* the probe are
   exempt — match the existing allowlist convention rather than inventing one); (b) every command
   in `hooks/hooks.json` must start with an interpreter token (`bash `), not a bare path. Register
   it in `run_all()`, give it a `--self-test` case seeded with one violation of each rule, and
   keep the existing five checks' output shape. This is the step that matters most: it converts
   "someone will notice on Windows" into "CI says no." Files: `scripts/ci/check_contracts.py`.

6. **Add the `GOTCHAS.md` entry.** One entry covering both faces of the same trap: `python3` is a
   Store stub on Windows that resolves and fails, and a `.sh` path is not executable on Windows so
   hook commands need an explicit `bash` prefix. Cite the probe idiom and `setup.sh:426` as the
   two correct patterns. Without this the knowledge stays in hook comments, where it has already
   failed to propagate twice. Files: `GOTCHAS.md`.

7. **Version bump if — and only if — step 4 touched a shipped tree.** Step 4 edits `skills/`,
   `templates/` and `agents/`, all under `SHIPPED_GLOBS`, so a bump in **both**
   `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` is required (currently
   `0.6.0`). Steps 1, 5 and 6 alone would not require one. Files: both manifests.

#### Phase 2 — backlog hygiene (no code, settles two stale items)

8. **Close RUN-DURABILITY with its evidence.** Move the P2 row to Done with the finding: nine
   envelopes checked, zero completed-but-unrecorded stages once `decompose`/`converge`/
   `implement-<lane>` sidecars are attributed to `implement`; the original observation was on
   `/sdlc-lite`, since merged away. Record it in `DECISIONS.md` too — the rejected alternative is
   "keep re-confirming it", and the reason is that a lane-vs-stage misreading already produced a
   false confirmation once during this session's watch. Files: `TASKS.md`, `DECISIONS.md`.

9. **`/sdlc` Stage 6 must tag deliberately-deferred rows `_followup_`.** Found while writing this
   plan: the previous run closed 11 of 12 rows and correctly left the Phase 2 row open — but did
   not tag it, so `reconcile` immediately reported `terminal_envelope_open_rows` drift. Every
   completed multi-phase plan will do this. The marker already exists (added `5232045`); Stage 6
   just needs to apply it when it closes a plan's rows and knowingly leaves a later phase open.
   Two-leg edit: `skills/sdlc/templates/stage-6-handoff.md` plus the Copilot and Codex `sdlc`
   overlays if they carry the close-out line. Files: `skills/sdlc/templates/stage-6-handoff.md`,
   overlays as needed.

10. **Fix `/brainstorm`'s plan destination for skill repos.** Step 6 hardcodes
   `plans/<slug>.md`, which is right for a consumer and wrong here: `plans/` is gitignored in this
   repo, so a plan written there is invisible to git and one `rm` from gone. `/sdlc` already
   auto-detects skill-repo mode from `.claude-plugin/marketplace.json` — `/brainstorm` should use
   the same detection and write to `docs/plans/` when it fires. This is a two-leg edit: canonical
   plus the Copilot overlay (`copilot/skills/brainstorm/` exists; `codex/` does not). Files:
   `skills/brainstorm/SKILL.md`, `copilot/skills/brainstorm/SKILL.md`.

### Cross-Module Touchpoints

- **Every consumer repo** inherits the `project.json.example` fix, but only on a **fresh**
  onboarding — `setup.sh:307-310` never overwrites an existing `project.json`. Existing repos keep
  the broken `runner` value until edited by hand. That is the same silent-non-adoption gap the
  last plan dissolved by adding no keys; here it is unavoidable, so it should be **stated in the
  handoff** rather than assumed away.
- **`scripts/ci/test-hooks.sh`** is unaffected — it tests hook *behaviour*, not hook *wiring*.
  The wiring is what broke, which is precisely why the new `check_contracts.py` rule belongs
  there and not in the hook harness.
- **No `project.json` keys** are added, so no `/repo-onboarding` re-run is needed anywhere.

### Open Questions

- **What replaces bare `python3` in prose?** There is no portable single token: `python3` is the
  Store stub on Windows, `python` is absent on stock macOS and Debian. Three candidates:
  (a) prose names both — "`python3`, or `python` on Windows"; (b) a tiny `scripts/py.sh` wrapper
  that probes and execs, so prose says `bash scripts/py.sh <script>`; (c) leave the *command* and
  document the trap at each site. **Leaning (a)** for prose — it is honest, costs one clause, and
  adds no file. But `templates/project.json.example:33` is different: its value is *executed*, not
  read, so it needs a single working string. Decide that one separately; it may be the one case
  that justifies (b).
- **Should the new check also cover `scripts/`?** Those files already probe correctly, so the rule
  would be noise there today — but nothing stops a future script from regressing. Cheap either way.

### Appendix: Alternatives Considered

- **Fix only the instances, skip the check** — rejected. Both bugs existed for the life of the
  plugin and were found by a popup and a crashed hook. The instances will recur; the check is the
  only thing that makes recurrence visible. This is also the exact test the doctrine shipped in
  `c226f36` prescribes.
- **Make `hooks/hooks.json` a `PreToolUse`-style deterministic guard instead of a JSON fix** —
  rejected as absurd overkill; the file is five lines of wiring with a missing token.
- **Investigate RUN-DURABILITY properly rather than closing it** — rejected on evidence: nothing
  on disk exhibits it and the pipeline it was observed on was deleted. Re-opening needs a real
  reproduction, not a re-reading.
- **`/repo-onboarding --merge-new-keys` to repair existing consumers' `runner` value** — deferred.
  Worth doing if more shipped defaults ever change, but a single wrong value in one key does not
  justify a migration mode.
- **Fix `python3` by requiring `py` (the Windows launcher)** — rejected: `py` does not exist on
  macOS or Linux, so it trades one platform's breakage for another's.
