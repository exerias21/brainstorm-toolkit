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
# Three subcommands:
#
#   protect-tests.sh arm <test-file> [more...] [--pipeline-dir DIR]
#     Hashes each file and records data.protected_tests["<repo-relative-path>"]
#     = "sha256:<hex>" in the current in_progress envelope's run.json.
#     Re-arming a path overwrites its hash.
#
#   protect-tests.sh verify [--pipeline-dir DIR]
#     Recomputes each armed file's hash and compares against the recorded
#     one. Prints one "VIOLATION: ..." line per mismatched or missing file
#     and exits non-zero if any are found. Silent, exit 0, when nothing was
#     armed.
#
#   protect-tests.sh disarm [--pipeline-dir DIR]
#     Clears data.protected_tests from the envelope.
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
  protect-tests.sh arm <test-file> [more...] [--pipeline-dir DIR]
    Detector, not preventer: records each file's sha256 as
    data.protected_tests["<repo-relative-path>"] = "sha256:<hex>" in the
    current in_progress run envelope.
  protect-tests.sh verify [--pipeline-dir DIR]
    Re-hashes every armed file and reports mismatches. Exit 0 if all match
    (or nothing armed); non-zero with one "VIOLATION: ..." line per
    mismatched/missing file otherwise.
  protect-tests.sh disarm [--pipeline-dir DIR]
    Clears data.protected_tests from the envelope.

Root resolution: CLAUDE_PROJECT_DIR -> git rev-parse --show-toplevel -> PWD.
No-op (exit 0) when there is no in_progress envelope under --pipeline-dir
(default .claude/pipeline).
EOF
}

[ $# -ge 1 ] || { usage; exit 2; }
SUBCMD="$1"; shift

PIPELINE_DIR=".claude/pipeline"
FILES=()

case "$SUBCMD" in
  arm)
    while [ $# -gt 0 ]; do
      case "$1" in
        --pipeline-dir) PIPELINE_DIR="$2"; shift 2 ;;
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


def find_envelope(proj, pdir):
    """Repo-relative pipeline dir -> the current in_progress envelope's
    run.json path, or None. Mirrors run-cost-report.sh's scan: sorted names,
    last in_progress match wins (there is normally exactly one)."""
    base = os.path.join(proj, pdir)
    if not os.path.isdir(base):
        return None
    found = None
    for name in sorted(os.listdir(base)):
        run_json = os.path.join(base, name, 'run.json')
        if not os.path.isfile(run_json):
            continue
        try:
            with open(run_json, encoding='utf-8') as f:
                data = json.load(f)
        except Exception:
            continue
        if isinstance(data, dict) and data.get('status') == 'in_progress':
            found = run_json
    return found


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
    sub, proj, pdir = argv[0], argv[1], argv[2]
    rest = argv[3:]

    run_json = find_envelope(proj, pdir)
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

"$PY" "$PYCORE" "$SUBCMD" "$PROJ" "$PIPELINE_DIR" "${FILES[@]}"
rc=$?
exit $rc
