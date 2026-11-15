# Managed headless runners (`scripts/runner.sh`)

A runner is a named worker that runs as one `claude -p --output-format json` call per task and
exits. Nothing stays running between tasks, so an idle runner costs nothing. Its state is in
flat files under `.claude/parallel/runners/<name>/` (gitignore `.claude/parallel/`):

| File | Holds |
|---|---|
| `status.json` | current `session_id`, `cwd`, model, allowlist, `rotate_at`, last `context_tokens`, calls, cost, every session id it has had |
| `events.jsonl` | one line per call: time, mode (fresh/resume), session, context, cost, denials |
| `denials.jsonl` | every permission denial, verbatim |
| `handoff-<n>.md` | the hand-off note written at each rotation |
| `last-result.md` | the full final message of the last call (stdout carries only a summary) |

## Commands

```bash
bash scripts/runner.sh start api --cwd <lane path> --prompt-file .claude/parallel/briefs/api.md \
  --allowed-tools "Read,Edit,Write,Glob,Grep,Bash(npm --prefix api test:*),Bash(git add:*),Bash(git commit:*)" \
  --task T-12 --model M --max-turns 60 [--max-budget-usd 5] [--rotate-at 350000]
bash scripts/runner.sh resume api --prompt "Review feedback: ..."   # same session, same task
bash scripts/runner.sh resume api --prompt-file next.md --task T-13 # new work item
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

## Flags it passes (checked against `claude --help` and a live call, 2026-11-15)

`-p --output-format json`, `--resume <session_id>`, `--model M`, `--permission-mode` (default
`dontAsk`), `--allowed-tools`, `--max-turns` (accepted by `claude -p` though not listed in
`--help`), `--max-budget-usd`, and `--permission-prompts none` when the installed `claude`
lists it. A session is stored per working folder, so the runner always runs in its recorded
`cwd`.

## Context measurement and rotation

The JSON result carries `session_id`, `total_cost_usd`, `permission_denials[]`, `result`, and
`usage`. `usage` sums every model call in the task, which overstates the live context, so the
runner reads the **last** entry of `usage.iterations[]` (input + cache-read + cache-creation +
output tokens): that is what the next turn starts from. When it reaches `rotate_at` (default
350000; 300000-400000 recommended, a warning outside it), the next `resume`:

1. resumes the old session once with a hand-off prompt (format: `handoff-note.md`) and saves
   the reply as `handoff-<n>.md`;
2. starts a fresh session whose first prompt is that note followed by the new task;
3. records the new `session_id`; the old one stays in `sessions[]`.

## Permissions: give an allowlist, escalate every denial

A headless runner cannot answer a permission prompt. So `start` refuses without
`--allowed-tools`, and the default mode denies everything not on the list. Scope Bash entries
narrowly (`Bash(npm test:*)`, not `Bash`), and leave out anything the project reserves for a
human: database writes, deploys, pushes.

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
(takes precedence over 1: a call that was denied and also failed exits 3).

## Background subagent or runner?

A background subagent (`isolation: "worktree"`) is simpler and its permission prompts reach
you, but it lives inside your session. Use a runner when the work is longer than a sitting,
must survive your session ending, or needs its own model, allowlist or budget.
