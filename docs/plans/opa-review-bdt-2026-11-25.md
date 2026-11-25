# Brainstorm: orchestration review (orchestrate-parallel-agents) and the Vercel dashboard

Date: 2026-11-25. Asked by the operator: "Review session data. How has the skill been working? … recommend fixes in brainstorm — also brainstorm how this could tie in Vercel dashboards as that's the end goal."
Method: a 5-agent review (3 Sonnet readers: numbers, friction, skill-vs-practice; 1 Opus adversarial reviewer who spot-checked 9 claims against the files; 1 Fable dashboard brainstorm with web research). Raw reports: session scratchpad `review-0..4.md` (not tracked).

### Direction

Keep the model (orchestrator plus headless Sonnet runners, one lane per writer, one merge queue). It works: 107 landings in 11 days, 0 runner errors, cost per landing fell from $1.66 (11-15..23) to $1.18 (11-24..25). Fix the four things that hurt: refusals invite workarounds, fixes made after a review can land unreviewed, gate flakes cannot be told from real failures, and the records cannot be joined or graphed. Then emit one versioned event stream, which is also what the dashboard needs.

### What the data says (measured 2026-11-25; sources `.claude/parallel/runners/*/{events,denials}.jsonl`, `.claude/parallel/merge-queue.jsonl`, `runner.sh report`)

| Measure | 11-15..23 | 11-24..25 |
|---|---|---|
| Runner calls / cost | 220 / $129.70 | 74 / $35.43 |
| Cost per landing | $1.66 (baseline memo $1.78) | $1.18 |
| Share of cost in resumes | 39% | 27% |
| Calls hitting a denial | 25% | 31% (37% on 11-25) |
| Merge attempts failed on tests | 25% | 21% |
| Median lane wall time | 21 min | 7 min |

- The denial residue after the 11-23 allowlist is mostly chained commands (`cd lane && git …`), `bash scripts/…`, read commands not on the list (`ls`, `git check-ignore`), and writes into `lane/.claude/**`. Bare `git add/commit` denials are nearly gone (Opus spot-check 2).
- Of 34 failed merge attempts, at least 3 are recorded load flakes (portal vitest `practice-settings.test.tsx`, the migration-head self-test); the rest cannot be attributed because only the last test log is kept.
- Review rounds: the production Settings crawl took about eight Opus FIX rounds across four lanes. Each round found a real hole, so the reviews paid off, but the brief under-specified the safety envelope at the start.

### Conventions & reuse

- The toolkit is canonical for the skill and its scripts (`/mnt/h/programming/brainstorm-toolkit/skills/orchestrate-parallel-agents/`, `scripts/runner.sh`, `merge-queue.sh`, `lanes.sh`, `lease.sh`). Toolkit items below are filed upstream, not edited in this repo's vendored copies.
- Project items live in this repo: `.claude/parallel/briefs/_common.md`, `.claude/project.json` (`pipeline.parallel.runner.allowed_tools`, gitignored), project hooks, and the dashboard exporter.
- Reuse for the dashboard: `ops.job_type` / `ops.job_run` (revision 0068), the bdt-daily skill's "Never on the page" list, the PII ratchet, `plans/brainstorm-ops-job-status-db.md`, `plans/brainstorm-orchestrator-reporting.md`.

### Premises

- P1: the operator still wants headless runners, not agent teams. Basis: standing rule.
- P2: nothing personal, no member money, no database rows leave the machine (AGENTS.md, bdt-daily). Unconfirmed: whether orchestration tool cost and run-grain EXACT counts count as "money".
- P3: the engine host keeps no public ingress (Caddy loopback, `scripts/check_compose_exposure.py`).

### Implementation Steps

#### Phase 1 — Safety and quick wins (this week)
1. **Done 2026-11-25: refusals stop, never get re-routed.** `_common.md` line 6 used to say "rephrase and carry on". On 11-25 a runner, refused an edit to `.claude/hooks/lib/commit-gate-core.js`, tried the same write through a python heredoc. The line now says re-run a shape-refused command once as a plain command, and report `blocked: denied <tool> <path>` for a refused action. The stale 11-22 nightly date is replaced with the daily window. [project]
2. **Laundering rule written down.** Protected paths are `.claude/hooks/**`, `research/tools/guard.js`, the runner allowlist, `scripts/safe-commit.sh` and `commit-gate*`, and `*.env`. The orchestrator applies a runner-refused change there only after the operator approves that exact diff, and the approval is recorded in DECISIONS.md. Toolkit: SKILL.md §13. Project: optionally a PreToolUse check that enforces it. [toolkit + project] S
3. **Gate-narrowing changes need a ruling before they land.** Lane `tools-ratchet-scope` makes the commit gate skip gitignored captures, which narrows the PII ratchet. It is HELD, not re-landed, until the operator rules (Open Question 3). ⟳ 2026-11-25: corrected premise — no check read gitignored captures before or after this lane; it stops scanning other sessions' untracked drafts at commit time. Operator approved landing it and the one hook line (DECISIONS 2026-11-25). [project] S
4. **Allowlist residue.** Add `Bash(ls:*)`, `Bash(git branch:*)` and `Bash(git check-ignore:*)`. Keep `bash`, `sed -i`, `rm` and `cp` off the list (write or escape vectors). Re-measure denials from 11-23 only. [project, operator-owned file] S
5. **Runner results path.** Writes into `lane/.claude/**` are refused, so the brief template's `results/<name>.md` is dead. Rely on `last-result.md`, and drop the line from the template. [toolkit] S
6. **Push wording.** SKILL.md:289 says "no git push". Make it "lanes and workers never push; the orchestrator pushes only under the project's push rule". Add a default `--max-budget-usd` per call, and enforce `rotate_at` on resume (max context 262.6k despite rotate at 180k). [toolkit] S

#### Phase 2 — Review and landing integrity
7. **Re-review gate.** The lane verdict records the reviewed sha. The merge queue refuses a lane whose head moved past that sha when the diff touches money, PII or safety path classes (`engine/src/engine/{ledger,payout*,plugins,quals}/`, `guard.js`, the ratchets, the gate). Fixes made after ACCEPT get a short re-review. Evidence: several "ACCEPT after fixes" lands. [toolkit merge-queue.sh + skill §10] M
8. **Flake triage.** On tests-failed, rerun only the failing check once. Keep a per-attempt log (`merge-queue.logs/<branch>-<n>.log`) and tag the result `flake:<check>`. A check that flakes twice in 7 days fails hard and opens a TASKS row. [toolkit] M
9. **Migration numbers.** Add `lanes.sh reserve-migration <lane>`, which takes the next number from main's head plus open reservations, held in `leases.tsv`. The merge queue refuses a duplicate revision. Evidence: two lanes hold 0102 today (setting_change, notify_template_import). [toolkit] M
10. **Held lanes.** Add a `lanes.sh held --until <date|lane>` state shown in `lanes.sh list`. Five lanes wait for Friday 11-27 today, known only from prose. [toolkit] S
11. **Verifier variant.** Record the practice: a one-off Opus or Sonnet review agent per lane, fixes resumed on the owning writer, never a new `*-fix` runner, so cost stays under one name. [toolkit skill §9] S
12. **Safety envelope in the brief template.** Add a "cannot undo / protected resource" slot that lists the required negative tests up front, for production crawlers, guard and gate changes and money paths. That would have cut the crawl lanes' eight FIX rounds. [toolkit brief-template] S

#### Phase 3 — Events and reporting (the dashboard's input)
13. **One event stream.** `runner.sh`, `merge-queue.sh`, `lanes.sh` and `lease.sh` append to `.claude/parallel/events.v1.jsonl` with envelope `schema: "opa.event/1"`, `event_id`, `ts`, `type`, `lane_id`, `runner`, `attempt`. The types are `lane.opened/closed`, `runner.call` (with `resume_reason` and `cost_delta_usd`), `runner.denial` (tool and shape enum, never the command text), `review.verdict`, `queue.attempt` (with `failed_check` and `flake_suspected`), `lease.*` and `loop.tick`. Enums and numbers only. [toolkit] M
14. **`runner.sh report --json --since`**: a per-day table, fresh vs resume cost, the share of calls with a denial, top denied shapes, and cost per landing joined on `lane_id`. The 11-27 and 11-30 re-measures become one command. [toolkit] M

#### Phase 4 — Vercel dashboard (end goal)
15. **Exporter.** `scripts/dashboard-export.py` builds `snapshot.json` (`schema: "bdt.dashboard/1"`) from `events.v1.jsonl`, `ops.job_run` and the forward-recon verdicts. A fail-closed allowlist checks keys, refuses free text and anything shaped like money, an email or a member id, and fails on an empty snapshot (rule 4). [project] S
16. **Push, never pull.** The exporter uploads to a private Vercel Blob store with a write token in a gitignored env file. The operator installs the token and the cron line. Nothing on Vercel reaches into the machine. [project] S
17. **The app.** A small separate Next.js app on Vercel, behind Vercel Authentication, with three pages: Today (needs you, landed, pay-run go/no-go, coming up), Orchestration (cost per landing, denial rate, gate outcomes with flake tags, held lanes, reserved migrations, review rounds), and Ops jobs. A "last export" age turns red past 2 hours. It replaces or sits beside the claude.ai daily page (Open Question 6). [project] S
18. **History** (staff viewing dropped by the 2026-11-25 ruling). Dated snapshots in Blob first; Neon through the Marketplace only if trend queries need it. Later, Entra sign-in for Zilis staff with per-role sections. Operator-only detail stays on the tailnet (wildcard W3). [project] M

### Cross-Module Touchpoints

- Engine: `ops.job_run` readers only (no new revision for phases 1-3).
- Portals: none. The dashboard is a separate app, so the staff portal's Entra and CSP work is untouched.
- Toolkit: steps 2, 5-14 go upstream to brainstorm-toolkit.

### Open Questions

1. **Vercel account and plan.** Hobby gives daily cron only; Pro gives hourly cron, Password Protection ($20 per project per month) and Drains. **Your answer:** Pro team the operator owns (2026-11-25). Vercel cron is not used (the machine pushes).
2. **What may appear.** Recommend: counts, run numbers, EXACT or not, and orchestration tool cost (it is not member money); no member money amounts. **Your answer:** agent cost in dollars only; no member money or pay-run totals (2026-11-25).
3. **Gate scope (held lane `tools-ratchet-scope`).** Should the commit gate scan only tracked files plus the commit's paths (other sessions' drafts stop blocking commits), with gitignored captures checked only in CI and full local runs? Recommend: yes, with the full walk kept in CI and the nightly. **Your answer:** yes, land and apply the hook line (2026-11-25).
4. **Who may view the dashboard, and when.** Recommend: operator only until January; Zilis staff later, pay-run and job status only. **Your answer:** operator only, no end date; staff use the back office's job pages (2026-11-25).
5. **Lane names on Vercel, or hashed ids.** Recommend: an area plus a short hash. **Your answer:** deferred — measured all 125 runner names are area slugs or run numbers; plain names through the exporter allowlist.
6. **Replace the claude.ai daily page, or run beside it.** Recommend: beside it until the dashboard has run cleanly for a week. **Your answer:** deferred; beside it until a clean week.

### Appendix: Alternatives Considered

- A2, push events to Marketplace Postgres (Neon): M effort; one more database and an ingest secret, and an event is hard to take back once it lands. Kept as the phase-4 history option.
- A3, pull through a tunnel (Tailscale Funnel or Cloudflare Tunnel): rejected. It opens public ingress to the machine that holds PII and money, and the private-network option is Enterprise-priced (Secure Compute, from about $6.5K a year).
- W2, upload prebuilt static HTML (`vercel deploy --prebuilt`): the simplest, but no history, and a PII slip is baked into a deployment.
- A standing verifier runner per wave (the skill's text): the one-off review agent worked and costs less. Record it as the accepted variant (step 11).
