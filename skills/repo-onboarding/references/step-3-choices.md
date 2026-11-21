# Step 3 — the choices detection can't make (body)

Loaded by `skills/repo-onboarding/SKILL.md` Step 3, interactive sessions only, after the
proposed `project.json` and the owner interview.

**Ask these questions explicitly — do not bury them in "does this look right?".**
Detection can't decide any of them, they are the main cost/quality/policy levers, and a user
who is never asked never discovers the key exists. Ask them in one batch — prefer the host's
**built-in interactive question UI** (the multiple-choice picker it already uses to ask you to
choose an approach): one question per key, options as choices, recommended default first. Where
the host has no such UI, print a numbered list and take the answers in a single reply. Default
first so "just accept" is one keystroke, and state the cost (or policy) direction in each option:

| Ask | Key | Options (default first) |
|---|---|---|
| **Which model implements the work?** (Stage 2 implementers, fix agents.) The bulk of the tokens. | `models.implement` | `sonnet` (recommended) · `haiku` (cheapest) · `opus` (priciest) |
| **Enable the adversarial Review→Fix stage, and which model reviews?** Recommend **on + `opus`**: Sonnet does the bulk of the tokens and a different, stronger model reviews — cheaper than Opus end to end, and the review stays independent. | `pipeline.review_fix.enabled` / `models.code_review` | `true` + `opus` (recommended) · `true` + `fable` (usage-billed, explicit opt-in) · `false` (never runs by accident) |
| **Ceiling for every sub-agent fan-out?** It only lowers a tier, never raises one — omitting it leaves each role at its own key. | `models.cap` | omit (recommended; no ceiling) · `sonnet` · `haiku` (cheapest; fine for sweeps/monitoring) |
| **Which model pre-flights your plan before any code is written** (Stage 1.5, never gated — it runs on *every* `/sdlc` run). Say plainly that the built-in per-focus defaults are `paths=haiku`, `completeness=sonnet`, `gotchas=sonnet`, and that **`models.cap` cannot raise any of them** — `models.sanity` (a string for all focuses, or a per-focus map) is the only lever. | `models.sanity` / `agents.sanity_focuses` | omit → built-in defaults (`paths=haiku`, `completeness=sonnet`, `gotchas=sonnet`) · `opus` (raises every focus at once) · a map like `{"completeness": "opus"}` to raise just one · fewer focuses to cut cost (`paths` is mechanical; drop `gotchas` when there's no `GOTCHAS.md`) |
| **How many review lenses?** Ask only if the review stage is on. One reviewer call per lens at the reviewer model, so this scales the stage's cost roughly linearly. | `agents.code_review_lenses` | omit → all four (`correctness`, `plan-alignment`, `config-env-docs`, `security`) · `["correctness", "security"]` (half cost; good default for app code) · `["correctness"]` (quarter cost; highest-yield single lens) |
| **How do you bring this app up for manual verification?** Confirm or correct what was detected. | `stack.up` / `stack.rebuild` / `stack.url` | the detected compose/dev commands · corrected by the user · omit (skills then say which key is missing instead of guessing) |
| **What should git ignore?** Not a config key — it decides what Step 5 appends to `.gitignore`. Multi-select over the toolkit files that are a genuine team choice (the machine-state entries in Step 5 are always ignored and never asked). State the trade per option: ignored = personal, no merge conflicts; tracked = shared with the team, survives a `git reset --hard`. For `.claude/project.json` also say that tracking it makes the opt-in stop gate stand down — it never runs a test command from a committed config unless `BRAINSTORM_TRUST_STOP_GATE=1`. Then ask for **any other paths** this repo wants ignored (local env files, scratch or output dirs the scan saw untracked) — and never propose a path that is already tracked without saying ignoring it won't untrack it. | `.gitignore` | all three checked (default): `.claude/project.json`, `TASKS.md`, `plans/` · uncheck any the team shares · plus free-text extra paths |
| **Should commit messages this toolkit writes or suggests credit Claude as a co-author?** Not a cost lever — a disclosure choice, so it is off unless the user says yes. Mention that it also lands in any PR body a future step authors, and that some DCO / commit-lint setups reject unrecognized trailers. | `coauthor_trailer` | `false` (default — no trailer) · `true` (append `Co-Authored-By: Claude <noreply@anthropic.com>`) |
| **When should Claude Code auto-compact the conversation?** Claude only — not a `project.json` key; it goes in `.claude/settings.json`, shared by everyone on the repo. A larger window keeps more working context before a compaction but every turn past the default costs more; on a 1M-context model `600000` suits long `/sdlc` runs. Mention that each person can still override it for themselves with `/autocompact <tokens>` (user settings). | `autoCompactWindow` (`.claude/settings.json`) | omit (default — Claude Code decides) · `600000` (1M-context models; fewer compactions mid-run) · a custom token count |

Explain the interaction once, because it surprises people: **`models.cap` is a ceiling, not a
target** — it can only *lower* a role's tier, never raise it, so a cap of `sonnet` silently
turns an explicit `models.sanity: "opus"` into Sonnet. Every other `models.*` key exists with its
default and is edited in `project.json` — see `.claude/project.json.example` and
`skills/sdlc/templates/models.md`; do not walk them here. Close with the open catch-all: *"Anything
else to add, remove, or correct?"*
