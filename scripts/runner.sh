#!/usr/bin/env bash
# brainstorm-toolkit — managed headless runners: start, resume and rotate a
# `claude -p` session per named worker, with its state in flat files.
#
# WHY THIS EXISTS: a runner kept alive in a hand-kept terminal costs a human to
# watch it, relays its messages through the orchestrator's context, and dies
# with the terminal. A managed runner is a headless `claude -p --output-format
# json` call per task: it reads its brief, works, returns one JSON result and
# exits. Its session id is stored, so the next task resumes the same
# conversation (`--resume <id>`) with nothing kept running in between -- an
# idle worker costs nothing.
#
# WHY ROTATION: a session that keeps resuming keeps growing. Past a few
# hundred thousand tokens every turn re-pays that context and the model's
# attention to early detail degrades. When the last turn's context passes the
# threshold (default 180000; 150000-250000 recommended -- on one audited run a
# resumed turn cost ~3.8x a fresh one, and resumes above 200k were 40% of all
# spend), the next resume first
# asks the old session for a hand-off note, then starts a fresh session seeded
# with that note plus the new task, and records the new id. The old id stays in
# the history.
#
# PERMISSIONS: a headless runner cannot answer a permission prompt. Give it an
# explicit allowlist (--allowed-tools, else the project's
# pipeline.parallel.runner.allowed_tools; `--allowed-tools +X,Y` appends to
# that default) and a mode that
# denies everything else (default --permission-mode dontAsk, plus
# --permission-prompts none when this claude supports it). Anything it is
# denied is printed as DENIED lines, appended to denials.jsonl, and the run
# exits 3: the orchestrator takes it to the human. Never relay one runner's
# denied action to another runner to perform -- that launders the denial.
# A `Bash(<prefix>/:*)` entry is refused up front: `:*` needs a word boundary,
# so a prefix ending in `/` matches no command and every use is denied.
#
# LEAN START: each call passes `--tools <set> --strict-mcp-config` (set from
# --tools, else pipeline.parallel.runner.tools, else Bash,Read,Edit,Write,Glob,
# Grep; `default` passes neither) and `--exclude-dynamic-system-prompt-sections`
# when claude lists it. Measured 2026-11-23: starting context 36.9k -> 9.3k
# tokens, paid again on every turn. `--tools` without `--strict-mcp-config`
# was WORSE (58.4k: every MCP tool loads up front). The prompt goes on stdin
# from last-prompt.md, never as an argument: --tools and --allowed-tools are
# variadic and swallow a trailing prompt, and an empty stdin costs a 3 s wait.
# `--bare` (opt-in) skips OAuth, so it only works with an API key.
#
# State: <state>/runners/<name>/ with status.json (small, overwritten),
# events.jsonl (one line per call, with the allowlist and tool set in force),
# denials.jsonl, handoff-<n>.md, last-prompt.md, last-result.md (the full final
# message; stdout carries only a summary) and verdict.json (exit code and
# result of the last call, so a piped caller can still read a 3).
# <state> is $PARALLEL_STATE_DIR, else <main worktree>/.claude/parallel.
#
# MODEL: `--model` on this call wins. Otherwise a fresh session (start, or the
# fresh session after a rotation) uses `models.runner` from the project's
# .claude/project.json, default "sonnet", lowered by `models.cap` when set
# (Axis 1 of skills/sdlc/templates/models.md; an unrecognised value falls
# through to the default). A resumed session keeps the model recorded next to
# its session_id in status.json. The project is $CLAUDE_PROJECT_DIR, else the
# main worktree of the current git repo, else $PWD.
#
# TASK: `--task <id>` names the work item (a TASKS.md row, a plan step) the
# call serves. It is recorded in status.json and on every events.jsonl line
# from then on (until another --task), so cost and time trace to the work.
# `report` aggregates every runner's events.jsonl -- calls, cost, last
# context, denials, first and last call -- by runner and by task. The JSONL
# files stay the source of truth; any database would be derived from them.
#
# Usage:
#   runner.sh start  <name> (--prompt TEXT | --prompt-file F) [--allowed-tools T|+T]
#                    [--cwd DIR] [--model M] [--permission-mode M] [--max-turns N]
#                    [--max-budget-usd X] [--rotate-at TOKENS] [--task ID]
#                    [--tools SET|default] [--bare]
#                    (--max-turns defaults to 200: portal runners under the
#                    one-command rule used 111-113 of a 120 cap)
#   runner.sh resume <name> (--prompt TEXT | --prompt-file F) [same overrides]
#                    [--fresh]   hand off and start a fresh session now
#   runner.sh rotate <name>      write the hand-off now; next resume starts fresh
#   runner.sh status [<name>]    print status.json (or one line per runner)
#   runner.sh report [--json]    totals by runner and by task, from events.jsonl
#
# Exit codes: 0 ok, 1 the claude call failed or returned an error, 2 usage,
# 3 the run hit permission denials (see DENIED lines). Do not pipe runner.sh
# (`runner.sh ... | tail`) when the exit code matters: the pipeline's status
# is the last command's, so a 3 reads as 0 unless the caller sets pipefail.
# $RUNNER_CLAUDE_BIN overrides the claude binary (tests use a fake).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_BIN="${RUNNER_CLAUDE_BIN:-claude}"
usage() { sed -n '67,84p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

[ $# -ge 1 ] || usage
SUB="$1"; shift

PY="$(bash "$HERE/py.sh" --print 2>/dev/null)" || true
[ -n "$PY" ] || { echo "runner.sh: no working python interpreter (see scripts/py.sh)" >&2; exit 1; }

if [ -n "${PARALLEL_STATE_DIR:-}" ]; then STATE="$PARALLEL_STATE_DIR"
elif common="$(git rev-parse --git-common-dir 2>/dev/null)"; then STATE="$(cd "$(dirname "$common")" && pwd)/.claude/parallel"
else STATE="$PWD/.claude/parallel"; fi

NAME=""; PROMPT=""; PROMPT_SET=0; MODEL_OVERRIDE=""; REPORT_JSON=0; FRESH=0
DEFAULT_TOOLS="Bash,Read,Edit,Write,Glob,Grep"
OPTS=()  # "key=value" pairs (no associative arrays: stock macOS bash is 3.2)
while [ $# -gt 0 ]; do
  case "$1" in
    --prompt)      PROMPT="${2:-}"; PROMPT_SET=1; shift 2 ;;
    --prompt-file) [ -f "${2:-}" ] || { echo "runner.sh: no prompt file ${2:-}" >&2; exit 2; }
                   PROMPT="$(cat "$2")"; PROMPT_SET=1; shift 2 ;;
    --cwd)              OPTS+=("cwd=$(cd "${2:?}" && pwd)"); shift 2 ;;
    --model)            MODEL_OVERRIDE="${2:-}"; shift 2 ;;
    --permission-mode)  OPTS+=("permission_mode=${2:-}"); shift 2 ;;
    --allowed-tools)    OPTS+=("allowed_tools=${2:-}"); shift 2 ;;
    --max-turns)        OPTS+=("max_turns=${2:-}"); shift 2 ;;
    --max-budget-usd)   OPTS+=("max_budget_usd=${2:-}"); shift 2 ;;
    --rotate-at)        OPTS+=("rotate_at=${2:-}"); shift 2 ;;
    --tools)            [ -n "${2:-}" ] || { echo "runner.sh: --tools needs a set (or default)" >&2; exit 2; }
                        OPTS+=("tools=$2"); shift 2 ;;
    --bare)             OPTS+=("bare=1"); shift ;;
    --fresh)            FRESH=1; shift ;;
    --task)             [ -n "${2:-}" ] || { echo "runner.sh: --task needs an id" >&2; exit 2; }
                        OPTS+=("task=$2"); shift 2 ;;
    --json)             REPORT_JSON=1; shift ;;
    -h|--help) usage ;;
    --*) echo "runner.sh: unknown flag $1" >&2; usage ;;
    *) [ -z "$NAME" ] || usage; NAME="$1"; shift ;;
  esac
done

if [ "$SUB" = "status" ]; then
  [ -d "$STATE/runners" ] || exit 0
  if [ -n "$NAME" ]; then cat "$STATE/runners/$NAME/status.json"; echo; exit 0; fi
  for f in "$STATE"/runners/*/status.json; do
    [ -f "$f" ] || continue
    "$PY" -c 'import json,sys; s=json.load(open(sys.argv[1])); print("%s\tsession=%s\ttask=%s\tmodel=%s\tcontext=%s\trotate_at=%s\tcalls=%s\tcost_usd=%.4f" % (s["name"], s.get("session_id") or "-", s.get("task") or "-", s.get("model") or "-", s.get("context_tokens",0), s.get("rotate_at"), s.get("calls",0), s.get("cost_usd",0.0)))' "$f"
  done
  exit 0
fi

if [ "$SUB" = "report" ]; then
  "$PY" - "$STATE/runners" "$REPORT_JSON" <<'PYEOF'
import glob, json, os, sys
root, as_json = sys.argv[1], sys.argv[2] == "1"
def blank():
    return {"calls": 0, "cost_usd": 0.0, "denials": 0, "errors": 0, "last_context": 0,
            "first": None, "last": None}
by_runner, by_task, total = {}, {}, blank()
for path in sorted(glob.glob(os.path.join(root, "*", "events.jsonl"))):
    runner = os.path.basename(os.path.dirname(path))
    for line in open(path, encoding="utf-8", errors="replace"):
        try:
            ev = json.loads(line)
        except Exception:
            continue
        task = ev.get("task") or "-"
        for agg in (by_runner.setdefault(runner, blank()), by_task.setdefault(task, blank()), total):
            agg["calls"] += 1
            agg["cost_usd"] += float(ev.get("cost_usd") or 0.0)
            agg["denials"] += int(ev.get("denials") or 0)
            agg["errors"] += 1 if (ev.get("error") or ev.get("is_error") or ev.get("rc")) else 0
            if ev.get("context_tokens") is not None:
                agg["last_context"] = int(ev["context_tokens"])
            ts = ev.get("ts")
            if ts:
                agg["first"] = agg["first"] or ts
                agg["last"] = ts
if as_json:
    print(json.dumps({"by_runner": by_runner, "by_task": by_task, "total": total}, indent=1))
    sys.exit(0)
def table(title, rows):
    print(title)
    print("  %-24s %6s %10s %12s %7s %6s  %s" % ("name", "calls", "cost_usd", "last_ctx", "denied", "errors", "first .. last"))
    for k in sorted(rows):
        a = rows[k]
        print("  %-24s %6d %10.4f %12d %7d %6d  %s .. %s" % (k, a["calls"], a["cost_usd"], a["last_context"],
              a["denials"], a["errors"], a["first"] or "-", a["last"] or "-"))
if not by_runner:
    print("no runner events under %s" % root)
    sys.exit(0)
table("by runner", by_runner)
table("by task", by_task)
print("total: calls=%d cost_usd=%.4f denials=%d errors=%d" % (total["calls"], total["cost_usd"], total["denials"], total["errors"]))
PYEOF
  exit 0
fi

case "$NAME" in ''|*[!A-Za-z0-9._-]*|.*) echo "runner.sh: runner name must match [A-Za-z0-9._-]+" >&2; exit 2 ;; esac
DIR="$STATE/runners/$NAME"
STATUS="$DIR/status.json"
mkdir -p "$DIR"
# verdict.json always describes THIS invocation: removed now, written by the
# claude call, and rewritten on exit when the script's code differs from that
# call's (a refusal before any call, a rotation step that failed).
rm -f "$DIR/verdict.json"
LAST_CALL_RC=""
on_exit() {
  local rc=$?
  [ "$rc" = "$LAST_CALL_RC" ] && return 0
  [ -z "$LAST_CALL_RC" ] && [ "$rc" -eq 0 ] && return 0
  printf '{"ts": "%s", "exit": %s, "result": "%s", "denials": 0, "session_id": null, "mode": "none"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" "$(case "$rc" in 0) echo ok ;; 2) echo refused ;; *) echo error ;; esac)" > "$DIR/verdict.json" 2>/dev/null || true
}
trap on_exit EXIT

if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then PROJ="$CLAUDE_PROJECT_DIR"
elif common="$(git rev-parse --git-common-dir 2>/dev/null)"; then PROJ="$(cd "$(dirname "$common")" && pwd)"
else PROJ="$PWD"; fi

# Prints "<model> <source> <cap|none>": the configured model for a FRESH
# session. Source is config or default; cap only ever lowers the tier.
resolve_model() {
  "$PY" - "$PROJ/.claude/project.json" <<'PYEOF'
import json, sys
RANK = {"haiku": 1, "sonnet": 2, "opus": 3, "fable": 4}
try:
    cfg = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    cfg = {}
models = cfg.get("models") if isinstance(cfg, dict) and isinstance(cfg.get("models"), dict) else {}
model, source = "sonnet", "default"
if models.get("runner") in RANK:
    model, source = models["runner"], "config"
cap = models.get("cap") if models.get("cap") in RANK and models.get("cap") != "fable" else None
if cap and RANK[model] > RANK[cap]:
    model, source = cap, source + "+cap"
print(model, source, cap or "none")
PYEOF
}

# pipeline.parallel.runner.<key> from the project's .claude/project.json,
# else $2. Every key is optional.
cfg_get() {
  "$PY" - "$PROJ/.claude/project.json" "$1" "${2:-}" <<'PYEOF'
import json, sys
try:
    cfg = json.load(open(sys.argv[1], encoding="utf-8"))
    v = cfg["pipeline"]["parallel"]["runner"][sys.argv[2]]
except Exception:
    v = None
if isinstance(v, list):
    v = ",".join(str(x) for x in v)
elif v is True:
    v = "1"
print(sys.argv[3] if v is None or v == "" or v is False or isinstance(v, dict) else v)
PYEOF
}

has_opt() { local o; for o in "${OPTS[@]+"${OPTS[@]}"}"; do case "$o" in "$1="*) return 0 ;; esac; done; return 1; }
opt_val() { local o v=""; for o in "${OPTS[@]+"${OPTS[@]}"}"; do case "$o" in "$1="*) v="${o#*=}" ;; esac; done; printf '%s' "$v"; }

# The allowlist that will be in force: a flag replaces, a flag starting with +
# appends to the current (else the project default) list, no flag keeps the
# current list (else the project default). Prints it; "" means none.
resolve_allowlist() {
  local flag base=""
  [ -f "$STATUS" ] && base="$(get allowed_tools)"
  [ -n "$base" ] || base="$(cfg_get allowed_tools)"
  if has_opt allowed_tools; then
    flag="$(opt_val allowed_tools)"
    case "$flag" in
      +*) [ -n "$base" ] || { echo "runner.sh: --allowed-tools $flag appends, but there is no list to append to (set pipeline.parallel.runner.allowed_tools)" >&2; return 2; }
          # Append without repeating an entry already on the list.
          printf '%s,%s' "$base" "${flag#+}" | awk -v RS=',' -v ORS=',' 'NF && !seen[$0]++' | sed 's/,$//' ;;
      *)  printf '%s' "$flag" ;;
    esac
  else
    printf '%s' "$base"
  fi
}

# A Bash(<prefix>:*) rule needs a word boundary after the prefix, so one whose
# prefix ends in "/" matches no command: every use is denied (seen as
# Bash(python3 research/tools/:*) refusing research/tools/build-user-guide.py).
check_allowlist() {
  local bad
  bad="$(printf '%s' "$1" | grep -o 'Bash([^)]*/:\*)' || true)"
  [ -z "$bad" ] && return 0
  echo "runner.sh: allowlist entries that can never match (a ':*' prefix ending in '/'):" >&2
  printf '%s\n' "$bad" | sed 's/^/  /' >&2
  echo "  list each command exactly, e.g. Bash(node research/tools/guard.test.js), or drop the colon: Bash(node research/tools/*)" >&2
  return 2
}

# Fill OPTS for this call: the resolved allowlist (validated), and on a NEW
# runner the configured tool set and rotate_at unless a flag gave them. An
# existing runner keeps what it recorded unless a flag on resume changes it.
prepare_opts() {
  local al o kept=()
  al="$(resolve_allowlist)" || exit 2
  if has_opt allowed_tools && [ -z "$al" ]; then
    echo "runner.sh: --allowed-tools is empty (an unset variable?); a headless runner needs an allowlist" >&2; exit 2
  fi
  # The raw flag is replaced by the resolved list, never written as given.
  for o in "${OPTS[@]+"${OPTS[@]}"}"; do case "$o" in allowed_tools=*) ;; *) kept+=("$o") ;; esac; done
  OPTS=("${kept[@]+"${kept[@]}"}")
  if [ -n "$al" ]; then
    check_allowlist "$al" || exit 2
    OPTS+=("allowed_tools=$al")
  fi
  if [ ! -f "$STATUS" ]; then
    has_opt tools || OPTS=("tools=$(cfg_get tools "$DEFAULT_TOOLS")" "${OPTS[@]+"${OPTS[@]}"}")
    has_opt rotate_at || OPTS=("rotate_at=$(cfg_get rotate_at 180000)" "${OPTS[@]+"${OPTS[@]}"}")
    [ "$(cfg_get bare)" = "1" ] && ! has_opt bare && OPTS=("bare=1" "${OPTS[@]+"${OPTS[@]}"}")
  fi
  return 0
}

# Set status.json["model"] for the next call: the override, else the
# configured model (fresh) or the recorded one (resume). $1 = fresh|resume.
choose_model() {
  local m src cap
  read -r m src cap < <(resolve_model)
  if [ -n "$MODEL_OVERRIDE" ]; then
    m="$MODEL_OVERRIDE"; src="flag"
  elif [ "$1" = "resume" ] && [ -n "$(get model)" ]; then
    m="$(get model)"; src="recorded"
  fi
  set_kv model "$m"; set_kv model_source "$src"
  echo "model: $m (cap: $cap, source: $src)"
}

# Small JSON helpers, all through one interpreter call each.
get() { "$PY" -c 'import json,sys; s=json.load(open(sys.argv[1])); v=s.get(sys.argv[2]); print("" if v is None else v)' "$STATUS" "$1"; }

set_kv() {
  "$PY" - "$STATUS" "$1" "$2" <<'PYEOF'
import json, os, sys
p = sys.argv[1]; s = json.load(open(p)); s[sys.argv[2]] = sys.argv[3]
json.dump(s, open(p + ".tmp", "w"), indent=1); os.replace(p + ".tmp", p)
PYEOF
}

write_status_from_opts() {  # merge OPTS over status.json (created if absent)
  "$PY" - "$STATUS" "$NAME" "${OPTS[@]+"${OPTS[@]}"}" <<'PYEOF'
import json, os, sys
path, name, pairs = sys.argv[1], sys.argv[2], sys.argv[3:]
s = json.load(open(path)) if os.path.exists(path) else {
    "name": name, "session_id": None, "cwd": os.getcwd(), "permission_mode": "dontAsk",
    "rotate_at": 180000, "max_turns": 200, "context_tokens": 0, "calls": 0, "cost_usd": 0.0,
    "sessions": [], "pending_handoff": None}
for p in pairs:
    k, v = p.split("=", 1)
    s[k] = int(v) if k in ("rotate_at", "max_turns") and v.isdigit() else v
tmp = path + ".tmp"
json.dump(s, open(tmp, "w"), indent=1)
os.replace(tmp, path)
PYEOF
}

# Runs one claude call. $1 = prompt, $2 = "resume" or "fresh". Records the
# result and prints a short summary. Returns 0, 1 or 3.
call_claude() {
  local prompt="$1" mode="$2" sid cwd out rc tools
  sid="$(get session_id)"; cwd="$(get cwd)"; tools="$(get tools)"
  [ -n "${CLAUDE_HELP+x}" ] || CLAUDE_HELP="$("$CLAUDE_BIN" --help 2>/dev/null || true)"
  local cmd=("$CLAUDE_BIN" -p --output-format json)
  [ "$mode" = "resume" ] && [ -n "$sid" ] && cmd+=(--resume "$sid")
  [ -n "$(get model)" ] && cmd+=(--model "$(get model)")
  [ -n "$(get permission_mode)" ] && cmd+=(--permission-mode "$(get permission_mode)")
  [ -n "$(get allowed_tools)" ] && cmd+=(--allowed-tools "$(get allowed_tools)")
  [ -n "$(get max_turns)" ] && cmd+=(--max-turns "$(get max_turns)")
  [ -n "$(get max_budget_usd)" ] && cmd+=(--max-budget-usd "$(get max_budget_usd)")
  case "$CLAUDE_HELP" in *--permission-prompts*) cmd+=(--permission-prompts none) ;; esac
  if [ -n "$tools" ] && [ "$tools" != "default" ]; then
    cmd+=(--tools "$tools")
    case "$CLAUDE_HELP" in *--strict-mcp-config*) cmd+=(--strict-mcp-config) ;; esac
  fi
  case "$CLAUDE_HELP" in *--exclude-dynamic-system-prompt-sections*) cmd+=(--exclude-dynamic-system-prompt-sections) ;; esac
  [ "$(get bare)" = "1" ] && cmd+=(--bare)
  # The prompt goes on stdin, never as an argument (see LEAN START above).
  printf '%s' "$prompt" > "$DIR/last-prompt.md"
  rm -f "$DIR/verdict.json"
  # No set +e/-e toggling: callers run this under set +e and must see its code.
  if out="$(cd "$cwd" && "${cmd[@]}" <"$DIR/last-prompt.md" 2>"$DIR/last-stderr.txt")"; then rc=0; else rc=$?; fi
  printf '%s' "$out" > "$DIR/last.json"
  if "$PY" - "$STATUS" "$DIR" "$rc" "$mode" <<'PYEOF'
import json, os, sys, time
status_path, d, rc, mode = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
s = json.load(open(status_path))
raw = open(os.path.join(d, "last.json"), encoding="utf-8", errors="replace").read()
try:
    r = json.loads(raw)
except Exception:
    r = None
ev = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "mode": mode, "rc": rc,
      "task": s.get("task"), "allowed_tools": s.get("allowed_tools"), "tools": s.get("tools") or "default"}
code = 0
if not isinstance(r, dict):
    ev["error"] = "no JSON result (see last-stderr.txt)"
    code = 1
else:
    u = r.get("usage") or {}
    its = u.get("iterations") or []
    last = its[-1] if its else u
    # Context of the LAST model call = what the next turn starts from. The
    # top-level usage sums every call in a multi-step turn, so it overstates.
    ctx = sum(int(last.get(k) or 0) for k in
              ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens"))
    sid = r.get("session_id")
    if sid and sid != s.get("session_id"):
        s["sessions"].append({"session_id": sid, "started": ev["ts"], "model": s.get("model")})
    s["session_id"] = sid or s.get("session_id")
    s["context_tokens"] = ctx
    s["calls"] = int(s.get("calls", 0)) + 1
    s["cost_usd"] = float(s.get("cost_usd", 0.0)) + float(r.get("total_cost_usd") or 0.0)
    ev.update(model=s.get("model"), session_id=sid, context_tokens=ctx, cost_usd=r.get("total_cost_usd"),
              num_turns=r.get("num_turns"), subtype=r.get("subtype"), is_error=r.get("is_error"))
    open(os.path.join(d, "last-result.md"), "w", encoding="utf-8").write(str(r.get("result") or ""))
    denials = r.get("permission_denials") or []
    if denials:
        with open(os.path.join(d, "denials.jsonl"), "a", encoding="utf-8") as f:
            for x in denials:
                f.write(json.dumps({"ts": ev["ts"], "session_id": sid, "denial": x}) + "\n")
        for x in denials:
            name = x.get("tool_name") if isinstance(x, dict) else None
            inp = json.dumps(x.get("tool_input") if isinstance(x, dict) else x)[:200]
            print("DENIED: %s %s" % (name or "?", inp))
        ev["denials"] = len(denials)
        code = 3
    if r.get("is_error") or rc != 0:
        code = 1 if code == 0 else code
with open(os.path.join(d, "events.jsonl"), "a", encoding="utf-8") as f:
    f.write(json.dumps(ev) + "\n")
# The exit code on disk, so `runner.sh ... | tail` cannot hide a 3.
verdict = {"ts": ev["ts"], "exit": code, "result": {0: "ok", 3: "denied"}.get(code, "error"),
           "denials": int(ev.get("denials") or 0), "session_id": s.get("session_id"), "mode": mode}
json.dump(verdict, open(os.path.join(d, "verdict.json"), "w"), indent=1)
tmp = status_path + ".tmp"
json.dump(s, open(tmp, "w"), indent=1)
os.replace(tmp, status_path)
print("runner=%s task=%s session=%s model=%s context=%s rotate_at=%s cost_usd=%.4f result=%s" % (
    s["name"], s.get("task") or "-", s.get("session_id"), s.get("model"), s.get("context_tokens"), s.get("rotate_at"),
    s.get("cost_usd", 0.0), os.path.join(d, "last-result.md")))
sys.exit(code)
PYEOF
  then LAST_CALL_RC=0; else LAST_CALL_RC=$?; fi
  return "$LAST_CALL_RC"
}

HANDOFF_PROMPT='Write a hand-off note for a fresh session that will continue your work. Reply with the note only, in this shape:
## Goal
## Done (with file paths and commit or branch names)
## In progress (exact state, what is half-done)
## Next steps (numbered)
## Decisions and constraints (what was ruled, by whom)
## Open questions and denials (anything you were refused, verbatim)
Keep it under 60 lines. Do not do any other work in this turn.'

rotate() {
  local n note
  [ -n "$(get session_id)" ] || { echo "runner.sh: $NAME has no session to rotate"; return 0; }
  n=1; while [ -e "$DIR/handoff-$n.md" ]; do n=$((n + 1)); done
  note="$DIR/handoff-$n.md"
  echo "rotating $NAME at context $(get context_tokens) (rotate_at $(get rotate_at)): asking for a hand-off note"
  set +e; call_claude "$HANDOFF_PROMPT" resume; local rc=$?; set -e
  [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] || { echo "runner.sh: hand-off turn failed; not rotating" >&2; return 1; }
  cp "$DIR/last-result.md" "$note" || { echo "runner.sh: could not save the hand-off note; not rotating" >&2; return 1; }
  "$PY" - "$STATUS" "$note" <<'PYEOF'
import json, os, sys
p = sys.argv[1]; s = json.load(open(p))
s["session_id"] = None; s["context_tokens"] = 0; s["pending_handoff"] = sys.argv[2]
json.dump(s, open(p + ".tmp", "w"), indent=1); os.replace(p + ".tmp", p)
PYEOF
  echo "hand-off note: $note (next call starts a fresh session)"
}

with_handoff() {  # prepend a pending hand-off note to the prompt, once
  local h; h="$(get pending_handoff)"
  if [ -n "$h" ] && [ -f "$h" ]; then
    printf 'You are continuing work from an earlier session. Its hand-off note:\n\n%s\n\n---\nYour task now:\n%s' "$(cat "$h")" "$1"
  else printf '%s' "$1"; fi
}
clear_handoff() {
  "$PY" - "$STATUS" <<'PYEOF'
import json, os, sys
p = sys.argv[1]; s = json.load(open(p)); s["pending_handoff"] = None
json.dump(s, open(p + ".tmp", "w"), indent=1); os.replace(p + ".tmp", p)
PYEOF
}

check_rotate_at() {
  local r; r="$(get rotate_at)"
  case "$r" in ''|*[!0-9]*) echo "runner.sh: --rotate-at must be a token count" >&2; exit 2 ;; esac
  if [ "$r" -lt 150000 ] || [ "$r" -gt 250000 ]; then
    echo "runner.sh: warning: rotate_at $r is outside the recommended 150000-250000 (pass --rotate-at 180000 to move this runner)" >&2
  fi
}

case "$SUB" in
  start)
    [ "$PROMPT_SET" -eq 1 ] || { echo "runner.sh start: --prompt or --prompt-file is required" >&2; exit 2; }
    if [ -f "$STATUS" ] && [ -n "$(get session_id)" ]; then
      echo "runner.sh: runner $NAME already has session $(get session_id); use resume (or rotate)" >&2; exit 2
    fi
    prepare_opts
    has_opt allowed_tools || {
      echo "runner.sh start: no allowlist -- pass --allowed-tools or set pipeline.parallel.runner.allowed_tools; a headless runner cannot answer permission prompts" >&2; exit 2; }
    write_status_from_opts; check_rotate_at
    choose_model fresh
    full="$(with_handoff "$PROMPT")"
    set +e; call_claude "$full" fresh; rc=$?; set -e
    [ "$rc" -eq 1 ] || clear_handoff
    exit "$rc"
    ;;
  resume)
    [ "$PROMPT_SET" -eq 1 ] || { echo "runner.sh resume: --prompt or --prompt-file is required" >&2; exit 2; }
    [ -f "$STATUS" ] || { echo "runner.sh: no runner $NAME; use start" >&2; exit 2; }
    prepare_opts
    write_status_from_opts; check_rotate_at
    if [ -n "$(get session_id)" ] && { [ "$FRESH" -eq 1 ] || [ "$(get context_tokens)" -ge "$(get rotate_at)" ]; }; then rotate || exit 1; fi
    mode=resume; [ -n "$(get session_id)" ] || mode=fresh
    choose_model "$mode"
    full="$(with_handoff "$PROMPT")"
    set +e; call_claude "$full" "$mode"; rc=$?; set -e
    [ "$rc" -eq 1 ] || clear_handoff
    exit "$rc"
    ;;
  rotate)
    [ -f "$STATUS" ] || { echo "runner.sh: no runner $NAME" >&2; exit 2; }
    rotate
    ;;
  *) usage ;;
esac
