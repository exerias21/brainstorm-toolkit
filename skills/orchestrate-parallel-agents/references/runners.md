# Managed headless runners (`scripts/runner.sh`)

A runner is a named worker that runs as one `claude -p --output-format json` call per task and
exits. Nothing stays running between tasks, so an idle runner costs nothing. Its state is in
flat files under `.claude/parallel/runners/<name>/` (gitignore `.claude/parallel/`):

| File | Holds |
|---|---|
| `status.json` | current `session_id`, `cwd`, model, allowlist, `rotate_at`, last `context_tokens`, calls, cost, every session id it has had |
| `events.jsonl` | one line per call: time, mode (fresh/resume), session, context, cost, denials, and the `allowed_tools` and `tools` in force |
| `denials.jsonl` | every permission denial, verbatim |
| `handoff-<n>.md` | the hand-off note written at each rotation |
| `last-prompt.md` | the prompt of the last call (sent on stdin) |
| `last-result.md` | the full final message of the last call (stdout carries only a summary) |
| `verdict.json` | `exit`, `result` (ok, denied, error), `denials`, `session_id` of the last call; removed when a call starts, so a missing file means the call did not finish |

## Commands

```bash
bash scripts/runner.sh start api --cwd <lane path> --prompt-file .claude/parallel/briefs/api.md \
  --allowed-tools "+Bash(npm --prefix api test:*)" \
  --task T-12 --model M [--max-turns 200] [--max-budget-usd 5] [--rotate-at 180000]
bash scripts/runner.sh resume api --prompt "Review feedback: ..."   # same session, same task
bash scripts/runner.sh resume api --prompt-file next.md --task T-13 # new work item
bash scripts/runner.sh resume api --prompt-file fixup.md --fresh    # hand off, start clean
bash scripts/runner.sh rotate api      # write a hand-off now; next call starts fresh
bash scripts/runner.sh status          # one line per runner
bash scripts/runner.sh report [--json] # calls, cost, last context, denials by runner and task
```

`--task <id>` is stored in `status.json` and written on every `events.jsonl` line until another
`--task` replaces it. `report` reads only the JSONL files, which stay the source of truth; a
database, if ever wanted, would be built from them.

`--model M` is optional. Without it a fresh session uses `models.runner` from
`.claude/project.json` (default `sonnet`, lowered by `models.cap` when set). The model is
recorded in `status.json` next to the `session_id` (`model`, `model_source`: flag, config,
default or recorded); a resumed session keeps its recorded model unless `--model M` is passed
again, and the fresh session after a rotation re-reads `models.runner`. Each call prints
`model: <m> (cap: <cap|none>, source: <source>)`.

Run `start`/`resume` with `run_in_background` and wait for the notification. Then read the
summary line and, only if needed, `last-result.md`. **Do not pipe it** (`runner.sh ... | tail`):
the exit code you see is then `tail`'s, and a run that hit denials (exit 3) reads as 0. The
first trial's exit 3 was masked exactly this way.

## Flags it passes (checked against `claude --help` and live calls, 2026-11-15 and 2026-11-23)

`-p --output-format json`, `--resume <session_id>`, `--model M`, `--permission-mode` (default
`dontAsk`), `--allowed-tools`, `--max-turns` (accepted by `claude -p` though not listed in
`--help`), `--max-budget-usd`, and, when the installed `claude` lists them,
`--permission-prompts none`, `--tools <set> --strict-mcp-config` and
`--exclude-dynamic-system-prompt-sections`. The prompt goes on **stdin** from
`last-prompt.md`, never as an argument. A session is stored per working folder, so the runner
always runs in its recorded `cwd`.

**Lean start (default).** Measured on one Haiku turn, 2026-11-23: a runner started with no
extra flags carried **36.9k** tokens of context before reading its brief (every connected MCP
tool, the full built-in tool set); with `--tools Bash,Read,Edit,Write,Glob,Grep
--strict-mcp-config --exclude-dynamic-system-prompt-sections` it carried **9.3k**, and every
later turn pays that difference again. `--tools` alone was worse (58.4k: MCP tools then load up
front), so the two always go together. `--exclude-dynamic-system-prompt-sections` moves the
cwd and git status out of the system prompt, so runners in different lanes share its cache.
The set comes from `--tools`, else `pipeline.parallel.runner.tools`, else that list; name any
extra tool the brief needs (`WebFetch`, an MCP tool), or pass `--tools default` for a runner
that needs MCP servers (neither flag is then passed). It is recorded at `start` and kept for the
runner's life, so a running session's tools never change.

**Why the prompt is on stdin.** `--tools` and `--allowed-tools` take several values, so a
prompt after them is read as one more tool name; and with nothing on stdin `claude -p` waits 3 s
("no stdin data received", seen on 10 runners).

**Not used, on purpose.** *Code Mode* (`CLAUDE_CODE_EXPERIMENTAL_CODE_MODE=1`, v2.1.323+,
https://code.claude.com/docs/en/code-mode) is the token-saving mode for interactive sessions;
its docs require an interactive terminal and say it does not work in background jobs, and a
`claude -p` call with it set had no `REPL` tool (2026-11-23), so it does not reach runners.
`--bare` (https://code.claude.com/docs/en/headless) skips hooks, plugins and CLAUDE.md
discovery but never reads OAuth or the keychain, so it fails on a subscription login: opt in
per runner with `--bare` (or `pipeline.parallel.runner.bare: true`) only with an
`ANTHROPIC_API_KEY`.

**`--max-turns` defaults to 200.** Under the one-command-per-Bash-call rule every step is its
own turn: portal runners used 111-113 of a 120 cap. A lower number cuts a lane off mid-task;
bound cost with `--max-budget-usd` instead. The runner does not probe whether the lane managed
to commit; check `git log` in the lane when the call returns.

## Project commit hooks see the lane as the project root

A project hook keyed on `CLAUDE_PROJECT_DIR` (a `PreToolUse` commit gate, a script that
`cd`s there) runs with the **lane's folder as the project root**, because the runner's `cwd` is
the lane. A hook that assumed the main checkout (a path relative to it, a lookup of files only
the main folder has) then breaks or gates the wrong tree; one such bug was fixed in the bdt
repo (commit e121ccc). Before dispatching a wave, **make one test commit in one lane** and see
the hook pass, then reset that commit in the lane (`git reset` is yours, never a writer's). Do
it once per project per hook change, not per lane.

## Context measurement and rotation

The JSON result carries `session_id`, `total_cost_usd`, `permission_denials[]`, `result`, and
`usage`. `usage` sums every model call in the task, which overstates the live context, so the
runner reads the **last** entry of `usage.iterations[]` (input + cache-read + cache-creation +
output tokens): that is what the next turn starts from. When it reaches `rotate_at` (default
180000 from `--rotate-at`, else `pipeline.parallel.runner.rotate_at`; 150000-250000
recommended, a warning outside it), the next `resume`:

1. resumes the old session once with a hand-off prompt (format: `handoff-note.md`) and saves
   the reply as `handoff-<n>.md`;
2. starts a fresh session whose first prompt is that note followed by the new task;
3. records the new `session_id`; the old one stays in `sessions[]`.

**The threshold is set for cost, not headroom.** Every turn of a resumed session re-reads the
whole conversation. On the audited bdt run (211 calls, $296.80) a resumed turn cost $0.092 vs
$0.024 fresh, resumes were 74% of spend, and the 34 resumes that ended above 200k cost 40% of
it, while the old 350k default fired once. A runner recorded before this default keeps its
`rotate_at`; pass `--rotate-at 180000` on its next `resume` to move it.

`resume --fresh` rotates now, whatever the context. Use it for a fix-up after review on a runner
that has grown large: put the commit shas and the review text in the prompt, and the fresh
session gets the hand-off note plus exactly that. Small fix-ups below the threshold resume as
usual; the warm session already holds the lane.

## Re-use one warm runner across a series

A runner is not one task. When the next item is in the same area as the last (a numbered series:
nav steps, parity B1-B9), `resume` the runner that did the previous step with `--task <next>`
and a short prompt instead of starting a new runner with a cold brief: the files it read and the
rules it learned are already in its context. Start a new runner when the area changes, when the
lane changes (a runner's session belongs to its `cwd`), or when the runner is past `rotate_at`
anyway. Open the next lane, then move the runner there with a new `start` only if the work truly
needs a new worktree; otherwise keep the series on one lane and land per step.

## One long-lived reviewer

Run the verifier as a named runner too, not as a new agent per landing: one reviewer per wave,
`--model M` with M an Opus-tier model (the independent check, skill section 3), a read-only allowlist, resumed per lane with `--task <lane>` so it keeps the plan
and its earlier verdicts in context, and rotated like any runner:

```bash
bash scripts/runner.sh start reviewer --cwd <main folder> --model M --task <first lane> \
  --tools Read,Glob,Grep,Bash \
  --allowed-tools "Read,Glob,Grep,Bash(git diff:*),Bash(git log:*),Bash(git show:*)" \
  --prompt-file .claude/parallel/briefs/reviewer.md
bash scripts/runner.sh resume reviewer --task <next lane> --prompt "Review lane/<next>: <base>..<tip>"
```

Its verdict goes back to the writer that owns the lane (skill section 9); the reviewer never
fixes. An interactive peer session the human watches, fed by cross-session messages, is the
alternative when live visibility matters more than the flat-file record.

## Permissions: give an allowlist, escalate every denial

A headless runner cannot answer a permission prompt. So `start` refuses without an allowlist,
and the default mode denies everything not on the list. Scope Bash entries narrowly
(`Bash(npm test:*)`, not `Bash`), and leave out anything the project reserves for a human:
database writes, deploys, pushes.

**One project default.** Put the list every lane needs in
`pipeline.parallel.runner.allowed_tools` (a string or a list) in `.claude/project.json`.
`start` without `--allowed-tools` uses it; `--allowed-tools +X,Y` appends to it (or to the
runner's current list on `resume`); a plain `--allowed-tools` replaces it. The list in force is
written on every `events.jsonl` line, so a denial can always be tied to the list it hit.

**Dead patterns are refused.** `:*` matches a prefix followed by a word boundary, so a prefix
ending in `/` matches no command: `Bash(node research/tools/:*)` denied
`node research/tools/guard.test.js`. `start` and `resume` exit 2 on such an entry and
name it. List each command exactly (`Bash(node research/tools/guard.test.js)`), or drop the
colon (`Bash(node research/tools/*)`).

**Write the allowlist and the brief together.** A `Bash(<prefix>:*)` rule matches one command
that starts with that prefix. A chained call (`cd engine && uv sync | tail -3; uv run pytest`)
matches none, so in the first trial every Bash call was denied. The brief forbids `cd`, `&&`,
`;`, pipes and redirection, and has each tool take its directory as a flag; the allowlist then
names exactly those commands. A set that fits a Python + Node repo with `engine/` and
`portal/` subfolders:

```text
Read,Edit,Write,Glob,Grep,
Bash(uv run --directory engine pytest:*),
Bash(uv sync --directory engine --locked:*),
Bash(npm --prefix portal test:*),
Bash(npm --prefix portal run lint:*),
Bash(npm --prefix portal run typecheck:*),
Bash(git status:*),Bash(git diff:*),Bash(git log:*),
Bash(git add:*),Bash(git commit:*),
Bash(bash scripts/lease.sh:*)
```

(One line, comma-separated, when passed to `--allowed-tools`.) Leave out `git push`, `git
reset`, `git checkout`, `git rebase` and anything that writes outside the worktree. If a step
needs a command that is not on the list, the runner reports it as a denial and you decide;
widening to `Bash(uv run:*)` or `Bash` to make denials stop hides the question from the human.

When the result has `permission_denials`, the runner prints one `DENIED: <tool> <input>` line
each, appends them to `denials.jsonl`, and exits 3. Then:

- take the denial to the human (escalation chain in the skill, section 13) with what the runner
  was trying to do;
- if the human approves, either widen this runner's allowlist (`resume ... --allowed-tools`) or
  do the action yourself where the human can see it;
- **never** give the denied action to another runner or subagent to do instead. That turns a
  refusal into a workaround, and the human never sees the question.

## Exit codes

0 ok · 1 the call failed or returned an error (see `last-stderr.txt`) · 2 usage · 3 denials
(takes precedence over 1: a call that was denied and also failed exits 3). The same code is in
`verdict.json`, so a caller that piped the output can still read it.

## Background subagent or runner?

A background subagent (`isolation: "worktree"`) is simpler and its permission prompts reach
you, but it lives inside your session. Use a runner when the work is longer than a sitting,
must survive your session ending, or needs its own model, allowlist or budget.
