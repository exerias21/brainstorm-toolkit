## Brainstorm Result: Optional Jev integration (loop judge + claim verifier + memory wiki)

> **Revision 3 — for review.** Revision 1 was a working doc from a 2026-09-19 session in
> `E:\programming\jev`. Revision 2 folded in a review against the live TypeSafe docs (confidence,
> Noul, API, the Jev 1.13 jaggedness page, the Noul self-consistency cookbook) and against this
> repo's tree. Revision 3 folds in **prior art**: six public Jev projects, three of which change this
> plan. See *Appendix: Prior art reviewed* and *Appendix: What revision 1 got wrong*. Nothing here is
> implemented in this repo yet.

### Direction

**brainstorm-toolkit gains an optional, detect-if-present integration with an external repo,
`claude-wiki` (at `E:\programming\jev`), which owns everything Jev-related.** The toolkit never
depends on Jev, never imports the TypeSafe SDK, and never needs an API key. When the external
command is configured and runs, the toolkit shells out to it at a few decision points and gets
back a small JSON verdict. When it is absent, fails, or times out, every call site behaves
exactly as it does today.

```
claude-wiki repo (E:\programming\jev)             brainstorm-toolkit (this repo)
─────────────────────────────────────             ───────────────────────────────
Jev questions + thresholds (one file)             detects `pipeline.judge.command`
typesafe-sdk, JEV_API_KEY, uv env         ◄─────  shells out: <command> judge <verb>
`claude-wiki judge <verb>` (stdin JSON → stdout)  (stdin JSON, stdout JSON, hard timeout)
labelled eval sets + thresholds                   appends verdicts to judge.jsonl
the wiki: harvest → classify → verify             reads the wiki's verified claims if configured
```

Why this split:
- **Toolkit rules stay intact:** stdlib-only Python via `scripts/py.sh`, hooks always exit 0, no
  secrets, works unchanged on Codex and Copilot. The integration is one subprocess behind a key.
- **Everything Jev-specific iterates in one place:** question wording, thresholds, the pinned model
  version, the labelled eval sets, and API cost.
- **The same repo already builds the memory wiki**, so memory injection is one more verb.

**The organising rule: Jev picks, code decides.** It comes from OpenWork, which wires Jev into its
eval testkit to *select* checked-in checks while deterministic code runs them — *"no model-decided
pass verdicts."* Every verb in this plan follows it: Jev returns a typed judgment, code owns the
threshold, the action, and anything countable. Where a verdict would otherwise be the final word
(refusing a write, failing a build), this plan tags instead and lets code or a human act.

**The headline use is claim verification, not the stop loop.** Revision 1 led with a `stuck` judge
in the Stop hooks. That is the use the Jev docs rate *riskiest*, and limpet — a public Stop-hook
judge measured on 2,645 real stops — now puts a number on it: tuned to wrongly block only 5% of
good stops, it catches **5–12% of bad ones**, with an estimated ceiling near **0.65** *"with the
information a stop has,"* and **33% of bad stops invisible at stop time altogether.** A Stop-hook
judge is a cheap nudge, not a guard. Meanwhile the best-evidenced use was missing from revision 1:
**verifying claims against their own evidence**, which is what the wiki's `verify` stage already
does and the one result in the proof of concept with a negative control (5 of 5 planted false
claims rejected). It is also this repo's most repeated failure — in one recent session a validator
refuted 5 plan claims, 3 of 4 sanity-check "blockers" were refuted on re-verification, and a
predicted 1 lint finding was actually 74 — and the pipeline already names the risk:
`stage-6-handoff.md`, *"`--evidence` takes provenance, never a claim… A self-report written here is
read by the next session with more authority than it earned."* So the first verbs are
**`classify-failure`** (rated reliable) and **`verify-claim`** (strongest evidence).

**Call-site order: prose first, hooks last.** Prose call sites (`fix-loop.md`,
`record-decision.sh`) run one at a time. The Stop hooks run **in parallel** — the single-blocker
contract in `stop-gate.sh`'s header and `docs/SEAM.md` say so — which is where concurrency bugs live.

**Rollout is shadow-first, and promotion needs labelled data — which already exists.** Revision 1
had no labelled history: of 64 pipeline runs across 6 repos, one recorded a fix-loop iteration, so a
shadow-only promotion rule would pass vacuously. limpet solved the same problem by labelling each
stop by **whether the human's next reply pushed back or corrected it.** claude-wiki already harvests
those human replies and already asks a `corrects_claude` Noul of every exchange. So the labelled
sets are built from transcripts already on disk, not by hand from scratch.

---

### Background: what Jev is (short)

Full condensed docs: `E:\programming\jev\docs\typesafe\README.md`, plus `07-jaggedness.md`. Live:
https://docs.typesafe.ai/llms.txt.

- `POST https://api.typesafe.ai/v1/systemone` with a `state` and named typed questions. Returns
  calibrated answers in ~100 ms. Costs **$0.042 per million input tokens**; output is free.
- **Three question types, and they differ in what they return:**
  - **Noul:** P(yes) only. **No confidence field.** A value near 0.5 means yes and no are about
    equally likely — not "medium".
  - **Choice:** one option, plus `probabilities` and a derived `confidence`.
  - **Score:** a position on described levels, plus `probabilities` and `confidence`.
- All questions in one request run in parallel and independently.
- **It cannot generate text.** It is weak at counting, math and dates, reads instructions
  literally, and **loses accuracy as state fills with detail unrelated to the decision.** Keep
  arithmetic and filtering in code; write the exact condition in the question.
- Errors worth handling: `401`, `429` (rate limit), `529` (overloaded). The SDK's retry policy
  backs off exponentially; hooks cannot wait on that, so they use zero retries.
- Pin `jev-1.13.0` once thresholds are tuned. `jev-latest` moves.

**Jaggedness verdicts for the uses in this plan** (Jev 1.13 page, asked directly):

| Use | Verdict | Consequence here |
|---|---|---|
| Classify a failure into a closed taxonomy | ✅ likely reliable | `classify-failure` ships first |
| Does a short rule apply to a described change | ⚠️ moderately risky | make conditions explicit; test boundary cases |
| Compare two error-log tails for the same root cause | ⚠️ **risky** — large unstructured state | `stuck` normalizes and hashes in code; Jev only on the residual |

### Background: claude-wiki as built (the proof of concept)

Repo `E:\programming\jev`, uv project `claude-wiki`, Python 3.11, `typesafe-sdk`. The API key
lives in `.env` as `JEV_API_KEY`, mapped to `TYPESAFE_API_KEY`. Global skill at
`~/.claude/skills/claude-wiki/SKILL.md` (`/claude-wiki`).

| Stage | What it does | Where |
|---|---|---|
| `harvest` | Reads the Claude homes in `wiki-sources.txt` (Windows + 3 WSL distros). Keeps genuine human turns with the Claude reply either side. Redacts credentials. Dedupes resumed sessions. | `src/claude_wiki/harvest.py` |
| `classify` | One Jev request per new exchange: 8 Nouls (incl. `corrects_claude`), a topic Choice, a generality Score. Cached. | `questions.py`, `jev.py` |
| `select` | `memory_value()` combines signals; exchanges ≥ 0.5 go to Claude, grouped by topic. | `select.py` |
| (Claude) | Writes `claims.json`: atomic claims, each citing exchange ids. | skill step 4 |
| `verify` | Jev checks each claim against its evidence: `supported`, `overgeneralized`, `contradicted`. | `render.py` |

Results on real data (2026-09-19):
- **Scale and cost:** 715 exchanges from 4 Claude homes; harvest ~10 s; classifying 494 new
  exchanges took seconds and about two cents in total.
- **Selection:** 58 candidates → 32 claims → **30 kept** (7 flagged "may be situational"), 2 rejected.
- **Negative control:** 5 deliberately false or unsupported claims cited to real evidence were
  **all rejected** (support ≤ 0.41). The over-generalized one scored highest on `overgeneralized`.
- **Real catches:** verification caught four of Claude's own over-reaches — turning a question
  into a rule, dropping a project's scope, and "never" where the evidence said "default, with
  opt-in". **This is the core evidence, and it is evidence for `verify-claim` specifically.**

Measured on this machine (2026-09-19): `uv run -q claude-wiki --help` warm, Windows native, three
runs: **261, 271, 345 ms.** With the ~100 ms Jev call that is well inside a 2.5 s budget. The
WSL → `/mnt/e` path is **not** measured.

Lessons that carry over:
- A single Jev signal is rarely a decision. Combine signals in code and gate on scope.
- Broad Nouls fire broadly (`describes_user` ≥ 0.7 on 298 of 724 exchanges). Supporting only.
  `corrects_claude` is broad too — as a *label source* it needs the scope gate below, not raw use.
- Compound, negated questions come back mushy (`task_only`: 470 of 724 landed in 0.3–0.7).
- Verification is strict about scope words and reads literally — what you want from a verifier.
- Open rough edges: duplicate memory files from the `/mnt/d` → `/mnt/e` migration are harvested
  twice (dedupe by content hash); the current session's own messages show up as candidates.

---

### Conventions & reuse

- **Follow the opt-in knob pattern:** `pipeline.loop.auto_continue`, `pipeline.stop_gate` and
  `pipeline.scope.*` carry a `_comment` and live in `templates/project.json.example`
  (`"pipeline": {` at :99). **Every new key must land in both `templates/project.json.example` and
  `docs/CONFIG.md`** — `check_contracts.py`'s config-keys check fails otherwise.
- **Follow the per-machine command key:** like `"python"` (`templates/project.json.example:45`)
  and `scripts/py.sh`, the judge command differs per machine (a Windows path vs a WSL path to the
  same repo), so it is a config value, never hardcoded.
- **Reuse the envelope addressing from `docs/plans/flow-gap-fixes.md` step 11**, not a guess. See
  *Prerequisite* below.
- **Reuse the Noul three-band convention** from the TypeSafe self-consistency cookbook:
  **< 0.30 no / 0.30–0.70 uncertain / > 0.70 yes**, where *uncertain never acts*. Choice verdicts
  use the returned `confidence`; Noul verdicts never claim a confidence they do not have.
- **Reuse the park path:** `queue-mode.md` `## Park protocol` (shared by queue mode and the Stage 0
  scope gate) is the one way a judge verdict parks a run — never a new sentinel shape.
- **Reuse the zero-token reporting channel:** `scripts/hooks/run-cost-report.sh` emits
  `systemMessage` (4 sites today), shown to the human at no model cost.
- **Reuse the test harness:** `scripts/ci/test-hooks.sh` with a **stub judge command** (a tiny
  script echoing fixed JSON), so CI never calls the network.
- **Reuse prior art (all MIT):** limpet's labelling method (label = the human's next reply);
  jev-agent-skill-router's eval harness and its five case categories; OpenWork's "Jev selects,
  code executes" split. Details in *Appendix: Prior art reviewed*.
- **Follow the Python gotcha** (`GOTCHAS.md`: never name a Python or `.sh` directly in shipped
  prose). Call sites use `bash scripts/py.sh scripts/judge.py …`.
- **New (justified): `scripts/judge.py`**, a stdlib shim. `scripts/check_docker_logs.py`,
  `eval-runner.py`, `check_contracts.py` and `skill-eval.py` each already call `subprocess` with a
  `timeout=`, but inline; there is no shared helper to extend.
- **New (justified): `stage-outputs/judge.jsonl`**, append-only, one verdict per line, instead of
  revision 1's `run.json` `data.judge[]` — which would have had three concurrent writers.

---

### Implementation Steps

> **Scope-gate note.** This plan spans two repos. Phases marked **EXTERNAL** execute in
> `E:\programming\jev`, not by this repo's `/sdlc`, and are marked **DEFERRED** here so the Stage 0
> scope gate never pulls them in. When adding `TASKS.md` rows for this plan, **do not add rows for
> EXTERNAL phases** — the gate selects the lowest phase with open rows. The prerequisite is an
> unnumbered heading on purpose: it is not implemented by this plan, and a `#### Phase N` heading
> would make the gate select it.

#### Prerequisite — envelope addressing (not implemented by this plan)

**`docs/plans/flow-gap-fixes.md` step 11 must land first.** Nothing names an envelope today:
`protect-tests.sh` `find_envelope()` takes the **last** sorted `in_progress` match and
`stop-gate.sh` breaks on the **first**. With two runs open, verdicts would be recorded against the
wrong run and `stuck` would read a *foreign* run's failures. **Phases 3–8 depend on this.** Phase 1
does not, and can ship now.

#### Phase 1 — Docs warnings (toolkit; no prerequisite; ships now)

1. **`skills/sdlc/templates/models.md` "Runtime regimes": warn about per-turn router proxies.**
   Projects such as jev-router / jcm-router sit as a local proxy and rewrite the model and
   reasoning effort on every turn. Under such a proxy, each dispatch's printed
   `model: <tier> (cap: …)` line — the only enforcement Axis 1 has on the prose path — no longer
   describes what actually ran, and the proxy can collapse the Axis 2 reviewer onto the
   implementer's tier, defeating independence. This is the same class of hazard the file already
   warns about for `CLAUDE_CODE_SUBAGENT_MODEL_FORCE`; add a sibling bullet, one or two lines, and
   name no product (products churn; the mechanism is the point). `models.md` is shipped, so this
   step carries a **version bump**.
2. **`docs/SEAM.md`: warn about a second blocking Stop hook.** limpet and similar "don't stop yet"
   hooks block with exit 2. `SEAM.md` (`:91`) records that Stop hooks run **in parallel** and that
   `stop-gate.sh` guarantees it is never the second blocker; a third-party blocking hook installed
   beside `stop-gate.sh` with `pipeline.stop_gate` enabled breaks that guarantee from outside. Add
   one paragraph: enable at most one blocking Stop hook per repo. `docs/` is not shipped.
3. **Version bump** for step 1 (`.claude-plugin/plugin.json` + `.claude-plugin/marketplace.json`).

#### Phase 2 — EXTERNAL · DEFERRED here · claude-wiki: judge CLI, first two verbs, labelled sets

4. **`claude-wiki judge <verb>`** — one JSON object on stdin, one on stdout.
   - Files: `src/claude_wiki/judge.py` (new), `src/claude_wiki/__init__.py` (argparse),
     `src/claude_wiki/questions.py` (new `JUDGE_*` question sets and thresholds, beside the
     existing ones).
   - **Contract (exit 0 always):**
     `{"verb", "verdict": <obj|null>, "band": "act"|"uncertain"|"no", "signals": {<question id>: <value>}, "confidence": <float|null>, "model", "request_id", "latency_ms"}`.
     `confidence` is set **only** when the deciding question is a Choice or Score; `null` for
     Noul-decided verbs. `signals` carries every raw answer so thresholds can be re-tuned without
     re-running inference. Any error → `"verdict": null` plus `"error"`.
   - Sync `TypeSafeClient`, `timeout=2.0`, `RetryPolicy(max_retries=0)`. Treat `429`/`529` as
     `verdict: null`, never as a retry.
5. **Verb `classify-failure`** — rated reliable, so it ships first.
   - Input: `{"plan_step", "gate", "failure_tail", "previous_tails": [...]}`. **Trim in code
     first:** the last ~40 lines of each tail, ANSI codes stripped.
   - Choice `failure_class` over the fix-loop taxonomy — `flaky` / `code-defect` / `plan-wrong` /
     `config-missing` — plus **`none-of-these`**, because a closed set with no escape forces a
     confident wrong answer. Criteria copied from `skills/sdlc/templates/fix-loop.md` as structured
     `what` / `not_for` / `examples` objects.
   - Verdict: `park_now` only when the class is `plan-wrong` or `config-missing` **and** confidence
     ≥ T (tuned on the labelled set). Otherwise `fix`. `none-of-these` never acts.
6. **Verb `verify-claim`** — the wiki's `verify` stage, exposed as a verb.
   - Input: `{"claim", "evidence"}`, where `evidence` is the literal text the claim cites.
   - Choice `verdict` over `supported` / `overgeneralized` / `contradicted` / **`not-addressed`**
     (the evidence does not speak to the claim — the no-match outcome).
   - Plus Noul `scope_widened`: "Does `claim` state something broader than `evidence` shows — a
     general rule from a single case, 'never' where the evidence shows a default, or a count the
     evidence does not contain?" This is the over-reach class the wiki caught four times.
   - **Counts stay in code.** A claim like "74 findings" is checked by code parsing the evidence;
     Jev is asked only about the prose around it.
7. **Labelled sets, one per verb, built from transcripts already on disk (limpet's method).**
   - Label = **what the human did next.** A stop, verdict or report the human replied to with
     pushback or a correction is a positive; one they accepted and moved on from is a negative.
     claude-wiki's harvest already pairs each human turn with the Claude reply before it, and its
     `corrects_claude` Noul already scores the reply.
   - **Scope the label, don't use it raw.** `corrects_claude` fires on task-specific fact
     corrections too (the wiki's own top hit was one), and the wiki's lessons say broad Nouls fire
     broadly. Filter to exchanges where the preceding Claude turn contained the thing being judged
     (a failure report for `classify-failure`, a claim-with-evidence for `verify-claim`), then have
     a human confirm a sample. limpet found carefully-labelled data scored 0.62–0.70 against its
     automatic labels — expect a similar gap and report both.
   - Include **planted negatives** the way the wiki's negative control did: false claims cited to
     real evidence, so the set cannot pass by accepting everything.
   - `claude-wiki judge --eval <verb>` reports precision in the `act` band, per label source.
8. **Offline stub mode.** `CLAUDE_WIKI_JUDGE_STUB=<file>` makes each verb return canned JSON, for
   the toolkit's CI.

#### Phase 3 — Toolkit seam and doctrine (depends on the prerequisite)

9. **Config keys** under `pipeline.judge`, each with a `_comment`, in **both**
   `templates/project.json.example` and `docs/CONFIG.md`:
   - `command` — default `""` (off). Example `"uv --directory E:/programming/jev run -q claude-wiki"`,
     or the `/mnt/e/...` form under WSL.
   - `mode` — `"off" | "shadow" | "enforce"`. Default `"off"`; `"shadow"` when a command is set.
   - `enforce` — list of verbs allowed to act. Default `[]`.
   - `timeout_ms` — default `2500`.
   - `memory_source` — path to a claims file. Default `""`.
10. **`scripts/judge.py`** (stdlib). Reads config; returns `{"verdict": null}` when off,
    unconfigured, timed out, erroring or malformed; otherwise runs `<command> judge <verb>` with the
    timeout and validates the contract from step 4. It **appends one line** —
    `{verb, verdict, band, signals, confidence, acted, at}` — to the addressed envelope's
    `stage-outputs/judge.jsonl`, never to `run.json`. Exits 0 always. Takes `--slug` and resolves
    through the prerequisite's addressing.
    Invocation: `bash scripts/py.sh scripts/judge.py <verb> [--slug <s>] < input.json`.
11. **`scripts/ci/test-hooks.sh` cases** with the stub command: off (no call), shadow (records,
    changes nothing), enforce+act, enforce+uncertain (must not act), timed-out command, missing
    command, malformed output, and **two concurrent appends to one `judge.jsonl`** (both survive).
12. **Doctrine: add the "Jev picks, code decides" worked case to `docs/ENFORCEMENT.md`.**
    `CLAUDE.md`'s hook-promotion question 2 says *"If the check needs judgment, it stays prose
    regardless of how important the rule is."* As written, that sends every use in this plan back to
    prose. OpenWork is the worked example of the resolution: the model **selects** from a fixed,
    checked-in set, and deterministic code **executes and decides** — no model-decided pass
    verdict. State the conditions under which a probabilistic judgment behind a deterministic
    interface earns a call site: it selects or tags rather than passing/failing; it ships a labelled
    set; its uncertain band never acts; it is off by default. Amend question 2 by one clause
    pointing there. Written **before** any call site lands, so it is not written to ratify one.
    `CLAUDE.md` and `AGENTS.md` stay byte-identical.

#### Phase 4 — Prose call sites, shadow only (depends on Phases 2 and 3)

13. **`skills/sdlc/templates/fix-loop.md`:** after each failed gate and before dispatching the fix
    agent, run `classify-failure`. Shadow: record only. Enforce + `park_now`: skip the remaining
    iterations and emit the existing PAUSED block with the judged class filled in.
14. **`scripts/record-decision.sh`: tag, never refuse.** Run `verify-claim` on each `--title`
    against its `--evidence`, and record the verdict beside the decision. `--evidence` is
    **optional** today (`[--evidence E]` in the script's usage), so a decision with none records
    `verdict: null, reason: "no-evidence"` and is written as now. In enforce mode, `contradicted`,
    `not-addressed` or an in-band `scope_widened` **mark** the entry `⚠ unverified: <verdict>` —
    they never block the write. This is the "Jev picks, code decides" rule applied: the tag is a
    typed signal for the next reader, and refusing a human's recorded decision would make the model
    the final word. The reseed hook points post-compaction sessions at `DECISIONS.md`, so a visible
    tag there reaches every future reset.
15. **`skills/sdlc/SKILL.md` Stage 7 report** (it lives in the skill, not a template — a
    **three-leg edit**: canonical plus the Copilot and Codex `/sdlc` overlays): run `verify-claim`
    over the report's verdict claims against the sidecars they cite. The `tasks: N closed` line is
    a count, so code checks it against `handoff.json` directly. Shadow only in this plan.
16. **`skills/sdlc-status/SKILL.md`:** when `judge.jsonl` holds a class for the failing stage, show
    it next to the inferred class. The disagreements are calibration data.

#### Phase 5 — `stuck` inside the hooks, hash-first (depends on Phases 3 and 4)

> **Set expectations from limpet's numbers before building this.** A stop-time judge sees only
> what a stop has. limpet's measurement — 5–12% of bad stops caught at a 5% false-block rate,
> ceiling near 0.65, a third of bad stops invisible — is the realistic envelope. This phase is
> worth doing because the hash-first half is nearly free and catches the commonest case
> deterministically; the Jev half is a nudge on the residual, not a guard.

17. **EXTERNAL · DEFERRED here: verb `stuck`, residual-only.**
    - Input: `{"plan_step", "attempts": [{"summary", "failure_tail"}, ...]}` (last 2–3).
    - Noul `same_failure`: "Do `attempts[-1].failure_tail` and `attempts[-2].failure_tail` report
      the same failing check for the same reason?" Noul `drifted`: "Is `attempts[-1].summary` about
      something other than `plan_step`?"
    - **Revision 1's `repeat_likely` is dropped:** it asks for a prediction the state cannot support,
      and in practice restates `same_failure`.
    - Verdict: `park` when `same_failure` is in the act band. `uncertain` never parks.
    - Labelled set per step 7: stops the human followed with "you're going in circles" / a
      correction are positives.
18. **Toolkit: normalize and hash before calling.** In `scripts/hooks/stop-gate.sh` (on a red
    `test.unit`) and the `next-action.sh` auto-continue branch, strip line numbers, paths,
    timestamps, hex addresses and durations from each tail, and hash the result. **Identical hashes
    park deterministically, with no Jev call.** Only tails whose hashes differ go to `stuck`. Keep
    the last 2–3 normalized tails in `.claude/.stop-gate-tails`; add that file to both gitignore
    lists in `setup.sh` and `skills/repo-onboarding/SKILL.md` (they must stay in sync —
    `.claude/.stop-gate-hops` is currently missing from both, flow-gap-fixes G16).
19. **Enforce + `park`** takes the shared Park protocol with
    `⛔ judge: repeating the same failure — parking`. `stop-gate.sh` stands down with a
    `systemMessage` instead of blocking again. `max_hops` remains the hard cap regardless.
20. **`test-hooks.sh` cases:** identical-hash park with no judge configured; differing tails + stub
    `same_failure` high → park; stub uncertain → continue; judge timeout → identical to today.

#### Phase 6 — Once per item (depends on Phase 3)

21. **EXTERNAL · DEFERRED here: verbs `triage-rows`, `relevant-memory`, `dedupe-gotcha`.**
    - `triage-rows`: per row, Noul `needs_human` ("Does this task require a decision, credential,
      login, or approval from the user before work can start?") and Noul `blocked_by`. Encodes a
      verified wiki claim: "keep executing every task that doesn't need the user's input" (support
      0.94 across 6 exchanges).
    - `relevant-memory`: one Noul per claim from the wiki's `verified.json`, restricted to
      `status in (verified, narrow)`. Code sorts and caps.
    - `dedupe-gotcha`: one Noul per existing entry — "Is `new_entry` the same trap as
      `entries[i]`, even if worded differently?"
22. **`skills/sdlc/templates/queue-mode.md` Select:** prefer rows `triage-rows` marks runnable
    unattended. Shadow records which row would have been picked. The Stage 0 scope gate still owns
    phase boundaries; triage only orders rows within the taken phase.
23. **`skills/sdlc/templates/stage-2-implement.md`:** if `pipeline.judge.memory_source` is set, run
    `relevant-memory` once and add at most ~8 claims to the brief under "How this user works".
    Enforce only after the wiki's two open rough edges are fixed.
24. **`skills/gotcha/SKILL.md`:** replace the dedup judgment call with `dedupe-gotcha`.
25. **`relevant-gotchas` — deferred on evidence, not dropped.** This repo's `GOTCHAS.md` holds 6
    entries, so filtering buys almost nothing yet. Revisit when a consumer's file is large enough
    that injecting it whole costs more than a Jev call.

#### Phase 7 — Description routing eval (nightly tier; depends on Phase 2 only)

26. **Adopt jev-agent-skill-router rather than building a `route-skill` verb.** It is MIT, ships a
    CLI (`route`, `evaluate`, `validate-results`, `report`) and a Python `Router`, and returns the
    same three abstain-shaped outcomes this plan uses (`route` / `no_skill` / `review`). On its
    72-case benchmark it routed **94.4%** correctly against **70.8%** for a lexical baseline, with
    **0 wrong routes and 0 needless loads**. Its multi-round batching is built for large catalogues;
    at 13 skills a single Choice fits, so evaluate whether to use the library whole or just its
    harness. Median latency 1.3 s — fine for a nightly run. **Pin a commit**; do not track a branch.
27. **Build this repo's case set in its five categories** — clear routes, **near neighbours**,
    **no-skill**, ambiguity, adversarial. Near neighbours are exactly where this repo's descriptions
    break: `/sdlc` vs `/task`, `/brainstorm` vs `/brainstorm-team`, `/repo-health` vs
    `/dead-code-review` — every one of those descriptions carries explicit "use X instead" text.
    Run each case against the descriptions **as installed per runtime**, after the truncation each
    runtime applies (`CLAUDE.md` rule 4: Codex shortens from the end).
28. **Wire it beside `scripts/ci/skill-eval.py`** as a nightly/on-demand eval, never per push. Fail
    when a case that used to route correctly stops doing so — the regression is the signal, not the
    absolute score.

#### Phase 8 — Calibrate, then promote

29. **`scripts/hooks/run-cost-report.sh`:** at terminal state, add one line summarizing
    `judge.jsonl` — verdicts by verb and band, and how often the judge disagreed with what the loop
    did. `systemMessage`, zero model tokens.
30. **Promotion rule (in the plan, not in code).** A verb moves to `enforce` only when **all** hold:
    - its labelled set (step 7) shows precision in the `act` band at or above the target for that
      verb's consequence — parking a run is costlier than tagging a decision `⚠ unverified`;
    - shadow data contains **at least 5 cases** where it would have acted, and none of them parked
      a run that later went green — fewer than 5 means "not enough evidence", never "passed";
    - its `uncertain` band is still wired to never act.
    Thresholds change in `claude-wiki/questions.py`, not in the toolkit. Pin `jev-1.13.0` (or the
    then-current version) before the first promotion.

---

### Cross-Module Touchpoints

- **`/sdlc`** — the fix loop gains `classify-failure` (step 13, a template edit, one leg); the
  Stage 7 report gains shadow verification (step 15, in `skills/sdlc/SKILL.md`, three legs).
- **`models.md`** — gains a runtime warning about per-turn router proxies (step 1). Cited by ~20
  skills, so the warning reaches every fan-out site without further edits.
- **`/sdlc-status`** shows the judged class beside its own inference (step 16).
- **`record-decision.sh`** and therefore **`DECISIONS.md`** — entries gain a verification tag
  (step 14); nothing is ever refused.
- **`/gotcha`** — dedup becomes a verb (step 24). Keep entries atomic, one trap each.
- **`/repo-health`** — optional: report "judge configured but command failing".
- **`/claude-wiki`** (external) — the loop's own transcripts flow back into the wiki on the next
  harvest, which also grows the labelled sets from step 7 automatically.
- **Consumers** — every key defaults off. A consumer without Jev sees no behaviour change and no
  new required config. The two Phase 1 warnings are the only changes a consumer reads.

### Open Questions

- **The WSL path.** Latency is measured for Windows-native `uv` only (261–345 ms warm). Most
  toolkit sessions run in WSL against `/mnt/h/...`. Measure the WSL → `/mnt/e` form before Phase 5
  puts a call on the Stop path.
- **Initial thresholds.** Noul verbs start on the cookbook's 0.30/0.70 bands; Choice verbs have no
  starting number until the labelled sets exist. Do not guess one into the code.
- **How much human confirmation the step-7 labels need.** limpet's automatic labels and its
  careful labels disagreed enough to move scores to 0.62–0.70. Decide a confirmation sample size
  per verb once the first set exists.
- **A global verdict log** (`~/.claude/judge-log.jsonl`) for cross-repo calibration — cheap and
  useful because per-repo volume is low. Decide in claude-wiki.
- **Compaction pruning coexistence.** Jev-scored compaction tools (save-token-jev,
  fast-jev-compaction) hook the same `SessionStart(source=compact)` event `reseed-context.sh` uses.
  Out of scope here; check coexistence before recommending one in `docs/LOOP-HYGIENE.md`.
- **Wiki rough edges** (content-hash dedupe of migrated memory files; excluding the current
  session) must be fixed before `relevant-memory` is enforced.

### Appendix: Alternatives Considered

- **A. `jev_judge.py` in the toolkit, five subcommands.** Chosen in reshaped form: the code lives in
  the external repo; the toolkit keeps only a shim.
- **B. Hooks first, templates later.** Revision 1 ran hooks early; revisions 2–3 **reverse** it —
  prose first, hooks last — and limpet's numbers confirm a Stop-hook judge is a nudge, not a guard.
- **C. One fan-out request per hop, cached for templates.** Not chosen. The failure class is needed
  mid-run after a gate fails, so a cache from the last Stop is stale for the answer that matters.
- **Personal-only (no toolkit changes).** Rejected: it gives up the deterministic call sites where
  the judge is easiest to test.
- **Install limpet as-is.** Rejected for this repo: it is a blocking Stop hook, and a second blocker
  beside `stop-gate.sh` breaks the single-blocker contract. Its *method* is adopted (step 7).
- **Build a `route-skill` verb.** Replaced by adopting jev-agent-skill-router (step 26).
- **Wildcard: First Principles, "Jev Gate".** One `ask()` function; shadow means "don't consume the
  return". **Adopted** as the internal shape and per-verb promotion.
- **Wildcard: Inversion, "Silence Auditor".** A permanent veto-only judge. Not adopted as the
  design; its abstain-shaped question framing is adopted in `stuck`.
- **Wildcard: Cross-Domain, "Triage Nurse".** Verdicts as chart notes beside decisions, low
  confidence always escalating. **Adopted** as `judge.jsonl` with `acted` and the uncertain band.
- **Wildcard: Constraint Removal, "Pilot Light".** Only per-hop state needs live calls. **Adopted**
  for memory and triage (once per item).

### Appendix: Prior art reviewed (2026-09-19)

| Project | What it does | Verdict here |
|---|---|---|
| [limpet](https://github.com/noplan-inc/limpet) (MIT) | Stop hook; plain-language rules judged by Jev; blocks with exit 2 | **Method and numbers adopted** (steps 7, Phase 5 note). Hook not installed — second blocker. Warning added (step 2) |
| [jev-agent-skill-router](https://github.com/GodsBoy/jev-agent-skill-router) (MIT) | Confidence-aware skill routing; `route`/`no_skill`/`review`; 72-case harness | **Adopted** for the routing eval (Phase 7) |
| [OpenWork](https://github.com/different-ai/openwork/pull/5101) / [eve](https://github.com/vercel/eve/pull/3531) | Jev as default verification judge; Jev selects checks, code executes | **Principle adopted** — "Jev picks, code decides" (Direction, step 12, step 14) |
| [jev-router](https://github.com/flaviusapop/jev-router) / jcm-router | Proxy that rewrites model and effort per turn | **Warning, not integration** (step 1) — falsifies the printed tier line and can collapse Axis 2. Note: several unrelated projects share the name |
| [save-token-jev](https://github.com/IAmUnbounded/save-token-jev-clean) / [fast-jev-compaction](https://github.com/evgenishko/fast-jev-compaction) | Jev-scored pruning of tool output at compaction | **Out of scope** — user-level install; coexistence with `reseed-context.sh` open |
| Jev Ultrafast (Browser Use) | DOM-state browser actions via Jev | **Not relevant** — this repo does no browser automation of its own |

Index of further projects: [awesome-jev](https://github.com/yibie/awesome-jev).

### Appendix: What revision 1 got wrong

1. **Three concurrent writers to `run.json`.** `judge.py` did a read-modify-write of `run.json` from
   `next-action.sh` and `stop-gate.sh`, and `run-cost-report.sh` already rewrites the same file —
   all Stop hooks, all in parallel. `os.replace` prevents a torn file, not a lost update. **Fix:**
   append-only `stage-outputs/judge.jsonl`.
2. **"The active envelope" is an open bug.** Nothing names an envelope today. **Fix:** the
   prerequisite — flow-gap-fixes step 11.
3. **`stuck` asked Jev to do the one thing its docs rate risky** — compare two unstructured log
   tails. **Fix:** normalize and hash in code; Jev judges only the residual. `repeat_likely`
   dropped.
4. **Thresholds did not match the primitives.** A `confidence` field for every verb, though Nouls
   return none; single guessed cut-offs. **Fix:** three bands with a never-acting middle;
   `confidence` only where a Choice or Score decides; raw `signals` recorded.
5. **The promotion rule was vacuous** with about one fix-loop iteration in 64 runs. **Fix:** labelled
   sets from existing transcripts (limpet's method) plus a minimum of 5 would-have-acted cases.
6. **Closed taxonomies had no escape option.** **Fix:** `none-of-these` / `not-addressed`, which
   never act.
7. **It missed the best-evidenced use** — claim verification. **Fix:** `verify-claim`.
8. **It led with the hooks**, where parallelism, addressing and latency all bite — and where
   limpet's data shows a judge's reach is modest. **Fix:** prose first; hooks in Phase 5.
9. **It did not reconcile with the repo's own doctrine.** **Fix:** step 12, built on OpenWork's
   "Jev picks, code decides".
10. **Config keys named one registry.** **Fix:** step 9 names both.
11. **`relevant-gotchas` was scheduled regardless of size.** **Fix:** deferred on evidence.
