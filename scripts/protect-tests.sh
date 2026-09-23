#!/usr/bin/env bash
# brainstorm-toolkit — test-immutability DETECTOR: arm / verify / disarm.
#
# Records the sha256 of a test file at red-stage (arm) and re-checks it at
# close-out (verify). This is a DETECTOR, not a preventer: it proves a
# protected test's bytes changed since arming; it does not stop the rewrite.
# Reuses the envelope's `plan_hash` idiom (`sha256:<hex>`, captured at one
# stage and compared at a later one) instead of inventing a new
# `.claude/.protected-tests` file with a third run-identity namespace --
# armed hashes live at run.json's `data.protected_tests`, alongside
# `plan_hash` (schema: skills/sdlc/templates/state-schema.md).
#
# Three subcommands, all accepting an optional --slug:
#
#   protect-tests.sh arm <test-file> [more...] [--pipeline-dir DIR] [--slug NAME]
#     Hashes each file and records data.protected_tests["<repo-relative-path>"]
#     = "sha256:<hex>" in the current in_progress envelope's run.json.
#     Re-arming a path overwrites its hash.
#
#   protect-tests.sh verify [--pipeline-dir DIR] [--slug NAME]
#     Recomputes each armed file's hash and compares against the recorded
#     one. Prints one "VIOLATION: ..." line per mismatched or missing file
#     and exits non-zero if any are found. Silent, exit 0, when nothing was
#     armed.
#
#   protect-tests.sh disarm [--pipeline-dir DIR] [--slug NAME]
#     Clears data.protected_tests from the envelope.
#
# --slug NAME addresses exactly `<--pipeline-dir>/<NAME>/run.json`, no
# selection heuristic involved -- a no-op (exit 0) if that envelope doesn't
# exist, the same posture as "no envelope at all" below. Callers that own a
# known slug (`/task` passes its own `task-<N>-<slug>`) should always pass
# it: with two runs open, an unaddressed call previously risked arming or
# verifying a FOREIGN envelope and reporting clean.
#
# Without --slug, the fallback prefers an in_progress envelope whose
# `pipeline` field is `"task"`, tie-broken on the newest `started_at`
# (ISO-8601 sorts lexically); falling back further to the newest `started_at`
# among ALL in_progress envelopes when none has `pipeline: "task"`. This
# replaces the old "last name in sorted order wins" scan.
#
# All three are no-ops exiting 0 when no in_progress envelope exists (or no
# working python interpreter is found -- same fail-open posture as the other
# best-effort scripts in this repo; a detector that blocked a run over its
# own missing dependency would be worse than no detector).
#
# Additive-only, atomic writes to run.json (tmp + os.replace, the idiom at
# scripts/merge-hook.py:89-97): stop-gate.sh, --resume's plan_hash check and
# close-tasks.sh reconcile all read this file, so a half-written run.json
# corrupts every one of them. Only `data.protected_tests` is ever touched --
# every other field, including anything --resume validates, is read back
# unchanged.
set -u

usage() {
  cat >&2 <<'EOF'
Usage:
  protect-tests.sh arm <test-file> [more...] [--pipeline-dir DIR] [--slug NAME]
    Detector, not preventer: records each file's sha256 as
    data.protected_tests["<repo-relative-path>"] = "sha256:<hex>" in the
    current in_progress run envelope.
  protect-tests.sh verify [--pipeline-dir DIR] [--slug NAME]
    Re-hashes every armed file and reports mismatches. Exit 0 if all match
    (or nothing armed); non-zero with one "VIOLATION: ..." line per
    mismatched/missing file otherwise.
  protect-tests.sh disarm [--pipeline-dir DIR] [--slug NAME]
    Clears data.protected_tests from the envelope.

--slug NAME addresses exactly <--pipeline-dir>/NAME/run.json (no-op, exit 0,
if it doesn't exist). Without it: prefer an in_progress envelope with
pipeline == "task", tie-break on newest started_at; else the newest
started_at among all in_progress envelopes.

Root resolution: CLAUDE_PROJECT_DIR -> git rev-parse --show-toplevel -> PWD.
No-op (exit 0) when there is no in_progress envelope under --pipeline-dir
(default .claude/pipeline).
EOF
}

[ $# -ge 1 ] || { usage; exit 2; }
SUBCMD="$1"; shift

PIPELINE_DIR=".claude/pipeline"
SLUG=""
FILES=()

case "$SUBCMD" in
  arm)
    while [ $# -gt 0 ]; do
      case "$1" in
        --pipeline-dir) PIPELINE_DIR="$2"; shift 2 ;;
        --slug) SLUG="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) FILES+=("$1"); shift ;;
      esac
    done
    [ "${#FILES[@]}" -ge 1 ] || { echo "protect-tests.sh arm: at least one test file required" >&2; usage; exit 2; }
    ;;
  verify|disarm)
    while [ $# -gt 0 ]; do
      case "$1" in
        --pipeline-dir) PIPELINE_DIR="$2"; shift 2 ;;
        --slug) SLUG="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
      esac
    done
    ;;
  -h|--help) usage; exit 0 ;;
  *) echo "unknown subcommand: $SUBCMD" >&2; usage; exit 2 ;;
esac

# Root resolution: CLAUDE_PROJECT_DIR -> git top-level -> PWD (same fallback
# as scripts/hooks/enforce-model-cap.sh:24-27).
PROJ="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$PROJ" ]; then
  if _gr="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$_gr" ]; then PROJ="$_gr"; else PROJ="$PWD"; fi
fi

# Probe that the interpreter RUNS, not merely that it resolves on PATH: on
# Windows `python3` is commonly a Microsoft Store stub that resolves and then
# exits non-zero (scripts/hooks/enforce-model-cap.sh:28-32).
PY=""
for c in python3 python py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'pass' >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -n "$PY" ] || exit 0

PYCORE="$(mktemp)"
trap 'rm -f "$PYCORE"' EXIT
cat > "$PYCORE" <<'PYEOF'
import hashlib, json, os, sys


def find_envelope(proj, pdir, slug=None):
    """Repo-relative pipeline dir -> the envelope's run.json path, or None.

    With a slug, address exactly <pdir>/<slug>/run.json -- no selection
    heuristic, no in_progress requirement -- None (no-op) if it doesn't
    exist. Without one, scan for the in_progress envelope: prefer
    `pipeline == "task"`, tie-broken on the newest `started_at` (ISO-8601
    sorts lexically); fall back to the newest `started_at` among ALL
    in_progress envelopes when none has `pipeline: "task"`. This replaces
    the old "last name in sorted order wins" scan, which let a foreign
    envelope get armed/verified whenever more than one run was open.
    """
    base = os.path.join(proj, pdir)
    if not os.path.isdir(base):
        return None

    if slug:
        run_json = os.path.join(base, slug, 'run.json')
        return run_json if os.path.isfile(run_json) else None

    best_task = None   # (started_at, run_json)
    best_any = None     # (started_at, run_json)
    for name in sorted(os.listdir(base)):
        run_json = os.path.join(base, name, 'run.json')
        if not os.path.isfile(run_json):
            continue
        try:
            with open(run_json, encoding='utf-8') as f:
                data = json.load(f)
        except Exception:
            continue
        if not isinstance(data, dict) or data.get('status') != 'in_progress':
            continue
        started = data.get('started_at') or ''
        if data.get('pipeline') == 'task':
            if best_task is None or started > best_task[0]:
                best_task = (started, run_json)
        else:
            if best_any is None or started > best_any[0]:
                best_any = (started, run_json)
    if best_task is not None:
        return best_task[1]
    return best_any[1] if best_any is not None else None


def sha256_of(path):
    try:
        h = hashlib.sha256()
        with open(path, 'rb') as f:
            for chunk in iter(lambda: f.read(65536), b''):
                h.update(chunk)
        return 'sha256:' + h.hexdigest()
    except OSError:
        return None


def repo_relative(proj, path):
    ap = path if os.path.isabs(path) else os.path.join(os.getcwd(), path)
    try:
        rel = os.path.relpath(ap, proj)
    except ValueError:
        rel = path
    return rel.replace(os.sep, '/')


def atomic_write(path, data):
    tmp = path + '.tmp'
    try:
        with open(tmp, 'w', encoding='utf-8', newline='\n') as f:
            json.dump(data, f, indent=2)
            f.write('\n')
        os.replace(tmp, path)
        return True
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return False


def main(argv):
    sub, proj, pdir, slug = argv[0], argv[1], argv[2], argv[3]
    rest = argv[4:]
    slug = slug or None

    run_json = find_envelope(proj, pdir, slug)
    if run_json is None:
        return 0  # no-op: no in_progress envelope to arm/verify/disarm against

    try:
        with open(run_json, encoding='utf-8') as f:
            env = json.load(f)
    except Exception:
        return 0
    if not isinstance(env, dict):
        return 0

    if sub == 'arm':
        data = env.get('data') if isinstance(env.get('data'), dict) else {}
        pt = data.get('protected_tests') if isinstance(data.get('protected_tests'), dict) else {}
        armed_any = False
        for f in rest:
            digest = sha256_of(f if os.path.isabs(f) else os.path.join(os.getcwd(), f))
            if digest is None:
                print(f"protect-tests.sh: cannot hash {f} (not found) -- not armed", file=sys.stderr)
                continue
            rel = repo_relative(proj, f)
            pt[rel] = digest
            armed_any = True
            print(f"armed: {rel} ({digest})")
        if armed_any:
            data['protected_tests'] = pt
            env['data'] = data
            atomic_write(run_json, env)
        return 0

    if sub == 'verify':
        data = env.get('data') if isinstance(env.get('data'), dict) else {}
        pt = data.get('protected_tests') if isinstance(data.get('protected_tests'), dict) else {}
        if not pt:
            return 0  # nothing armed -- not a violation
        violations = 0
        for rel, armed_hash in sorted(pt.items()):
            full = os.path.join(proj, rel)
            current = sha256_of(full)
            if current is None:
                print(f"VIOLATION: {rel} is missing (armed at {armed_hash})")
                violations += 1
            elif current != armed_hash:
                print(f"VIOLATION: {rel} changed since arming (was {armed_hash}, now {current})")
                violations += 1
        return 1 if violations else 0

    if sub == 'disarm':
        data = env.get('data') if isinstance(env.get('data'), dict) else {}
        if 'protected_tests' in data:
            del data['protected_tests']
            env['data'] = data
            atomic_write(run_json, env)
            print("disarmed: data.protected_tests cleared")
        return 0

    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
PYEOF

"$PY" "$PYCORE" "$SUBCMD" "$PROJ" "$PIPELINE_DIR" "$SLUG" "${FILES[@]}"
rc=$?
exit $rc
