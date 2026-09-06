#!/usr/bin/env python3
"""Headless outcome evals for file-producing skills (skill evals tier 2).

Sibling to `scripts/eval-runner.py`, not a fork of it: this shares its
fixture/expected-style layout and structured-JSON output shape, but instead
of diffing JSON fixtures it installs the toolkit into a disposable copy of a
tiny fixture repo (`evals/skills/fixtures/mini-fastapi/`), runs one skill
headlessly via `claude -p`, and grades the resulting tree with deterministic
assertions -- no LLM graders. Every case records `total_cost_usd` from the
CLI's JSON result, so the same run doubles as a cost-regression test.

Design doc: docs/plans/skill-evals-2-fixture-harness.md.

Usage:
  python scripts/ci/skill-eval.py --case sdlc-status-readout
  python scripts/ci/skill-eval.py --all
  python scripts/ci/skill-eval.py --all --update-baseline
  python scripts/ci/skill-eval.py --case gotcha-dedup --keep-tmp

Runs nightly / on demand only (see .github/workflows/skill-evals.yml) -- never
per push. Stdlib only. NEVER writes outside the per-case temp dir and
evals/skills/results/, except evals/skills/baseline.json, and then only when
--update-baseline is explicitly passed.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, NamedTuple

REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURE_DIR = REPO_ROOT / "evals" / "skills" / "fixtures" / "mini-fastapi"
CASES_DIR = REPO_ROOT / "evals" / "skills" / "cases"
RESULTS_DIR = REPO_ROOT / "evals" / "skills" / "results"
BASELINE_FILE = REPO_ROOT / "evals" / "skills" / "baseline.json"
SETUP_SH = REPO_ROOT / "setup.sh"
AGENTS_DIR = REPO_ROOT / "agents"

_MISSING = object()


# ── Reuse: scripts/token-audit.py's tier ranking (haiku < sonnet < opus) ────
# Loaded from the source file (not duplicated) so the two never drift. Safe:
# token-audit.py's module-level code only imports stdlib and defines
# functions/constants; its own CLI only runs under `if __name__ == "__main__"`.
def _load_token_audit():
    path = REPO_ROOT / "scripts" / "token-audit.py"
    spec = importlib.util.spec_from_file_location("_skill_eval_token_audit", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


_ta = _load_token_audit()
TIER_RANK: dict[str, int] = _ta.TIER_RANK
tier_of = _ta.tier_of


# ── Interpreter resolution (defensive: python3 first, then python) ─────────
# Mirrors scripts/hooks/run-cost-report.sh's PY probe loop: on Windows,
# `python3` is commonly a Microsoft Store stub that resolves on PATH and then
# exits non-zero, so probe that the interpreter actually RUNS, not merely
# that `shutil.which` finds it. Hardcoding either name breaks somewhere:
# `python3` breaks on the Windows dev machine used to build this harness;
# `python` breaks on some CI images that ship only `python3`.
def resolve_python() -> str:
    for candidate in ("python3", "python", "py"):
        exe = shutil.which(candidate)
        if not exe:
            continue
        try:
            r = subprocess.run(
                [exe, "-c", "pass"], capture_output=True, timeout=5
            )
            if r.returncode == 0:
                return exe
        except (OSError, subprocess.TimeoutExpired):
            continue
    return sys.executable  # last resort: the interpreter already running us


# ── Safety: every write this harness makes must land under an allowed root ──
class SandboxViolation(RuntimeError):
    pass


def _ensure_under(path: Path, roots: list[Path]) -> Path:
    rp = path.resolve()
    for root in roots:
        try:
            rp.relative_to(root.resolve())
            return rp
        except ValueError:
            continue
    raise SandboxViolation(
        f"refusing to write outside sandboxed roots {roots}: {rp}"
    )


def safe_write_text(path: Path, text: str, *, roots: list[Path]) -> None:
    resolved = _ensure_under(path, roots)
    resolved.parent.mkdir(parents=True, exist_ok=True)
    resolved.write_text(text, encoding="utf-8")


# ── Case loading ─────────────────────────────────────────────────────────


def load_case(name: str) -> dict[str, Any]:
    path = CASES_DIR / f"{name}.json"
    if not path.is_file():
        available = sorted(p.stem for p in CASES_DIR.glob("*.json"))
        raise SystemExit(
            f"unknown case {name!r}. Available: {', '.join(available)}"
        )
    return json.loads(path.read_text(encoding="utf-8"))


def discover_case_names() -> list[str]:
    return sorted(p.stem for p in CASES_DIR.glob("*.json"))


# ── Agent pinning (for agent_models_within_cap) ─────────────────────────────

_FRONTMATTER_RE = re.compile(r"\A---\n(.*?)\n---\n", re.DOTALL)
_NAME_RE = re.compile(r"^name:\s*([a-z0-9-]+)\s*$", re.MULTILINE)
_MODEL_RE = re.compile(r"^model:\s*(\S+)\s*$", re.MULTILINE)


def load_pinned_agents() -> dict[str, str]:
    """agents/*.md whose frontmatter pins a `model:` -- these are exempt from
    the 'missing model' branch of the cap check (they inherit their pinned
    tier, not the orchestrator's)."""
    pinned: dict[str, str] = {}
    if not AGENTS_DIR.is_dir():
        return pinned
    for f in AGENTS_DIR.glob("*.md"):
        text = f.read_text(encoding="utf-8", errors="replace")
        m = _FRONTMATTER_RE.match(text)
        if not m:
            continue
        fm = m.group(1)
        name_m = _NAME_RE.search(fm)
        model_m = _MODEL_RE.search(fm)
        if name_m and model_m:
            pinned[name_m.group(1)] = model_m.group(1)
    return pinned


def extract_agent_tool_uses(events: list[dict]) -> list[dict[str, Any]]:
    """Scan stream-json events for `tool_use` blocks named `Agent`. Returns
    a list of {"subagent_type": ..., "model": ...} (either may be None)."""
    out: list[dict[str, Any]] = []
    for ev in events:
        msg = ev.get("message") or {}
        content = msg.get("content")
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict):
                continue
            if block.get("type") != "tool_use" or block.get("name") != "Agent":
                continue
            inp = block.get("input") or {}
            out.append(
                {
                    "subagent_type": inp.get("subagent_type"),
                    "model": inp.get("model"),
                }
            )
    return out


# ── Assertions ───────────────────────────────────────────────────────────


class AssertionResult(NamedTuple):
    passed: bool
    message: str


def _dotted_get(obj: Any, path: str) -> Any:
    cur = obj
    for part in path.split("."):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            return _MISSING
    return cur


def _all_dotted_keys(obj: Any, prefix: str = "") -> set[str]:
    keys: set[str] = set()
    if isinstance(obj, dict):
        for k, v in obj.items():
            full = f"{prefix}.{k}" if prefix else k
            keys.add(full)
            keys |= _all_dotted_keys(v, full)
    return keys


def _count_task_rows(text: str) -> int:
    return len(re.findall(r"^\s*-\s*\[.\]", text, re.MULTILINE))


def assert_tasks_row_added(target: Path, params: dict, ctx: dict) -> AssertionResult:
    rel = params.get("file", "TASKS.md")
    f = target / rel
    if not f.is_file():
        return AssertionResult(False, f"{rel} does not exist")
    before = ctx.get("initial_tasks_row_count")
    if before is None:
        return AssertionResult(False, "no baseline TASKS.md row count was captured")
    after = _count_task_rows(f.read_text(encoding="utf-8", errors="replace"))
    expected_delta = params.get("count", 1)
    actual_delta = after - before
    if actual_delta != expected_delta:
        return AssertionResult(
            False,
            f"{rel} row count changed by {actual_delta}, expected {expected_delta} "
            f"({before} -> {after})",
        )
    return AssertionResult(
        True, f"{rel} rows increased by {expected_delta} ({before} -> {after})"
    )


def assert_tasks_row_state(target: Path, params: dict, ctx: dict) -> AssertionResult:
    """Assert one TASKS.md row's checkbox state AND which section it sits under.

    Both halves matter, and checking only the checkbox is how the close-out bug
    survived: "mark [x] and move to Done" is two edits, and a run can do one. A
    row can be [x] while still filed under Active / Pending, or [ ] under Done --
    this repo had a live instance of the latter. `section` may be omitted to
    assert state alone.
    """
    rel = params.get("file", "TASKS.md")
    f = target / rel
    if not f.is_file():
        return AssertionResult(False, f"{rel} does not exist")
    needle = params["row"]
    want_state = params["state"]          # one of " ", "x", "~"
    want_section = params.get("section")  # e.g. "Done" / "Active / Pending"

    section = None
    for line in f.read_text(encoding="utf-8", errors="replace").splitlines():
        m = re.match(r"^##\s+(.*?)\s*$", line)
        if m:
            section = m.group(1)
            continue
        if needle not in line:
            continue
        sm = re.match(r"^\s*-\s*\[(.)\]", line)
        if not sm:
            return AssertionResult(False, f"row matching {needle!r} is not a checkbox row")
        state = sm.group(1)
        if state != want_state:
            return AssertionResult(
                False, f"row {needle!r} has state '[{state}]', expected '[{want_state}]'"
            )
        if want_section is not None and section != want_section:
            return AssertionResult(
                False,
                f"row {needle!r} is '[{state}]' but filed under '## {section}', "
                f"expected '## {want_section}' -- the flip happened, the move did not",
            )
        where = f" under '## {section}'" if want_section is not None else ""
        return AssertionResult(True, f"row {needle!r} is '[{state}]'{where}")
    return AssertionResult(False, f"no row in {rel} matches {needle!r}")


def assert_glob_exists(target: Path, params: dict, ctx: dict) -> AssertionResult:
    pattern = params["pattern"]
    matches = list(target.glob(pattern))
    if not matches:
        return AssertionResult(False, f"no files match `{pattern}` under {target}")
    return AssertionResult(True, f"{len(matches)} file(s) match `{pattern}`")


def load_project_config(target: Path) -> dict:
    cfg = target / ".claude" / "project.json"
    if not cfg.is_file():
        return {}
    try:
        return json.loads(cfg.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def assert_pytest_green(target: Path, params: dict, ctx: dict) -> AssertionResult:
    cfg = load_project_config(target)
    cmd = params.get("cmd") or cfg.get("test", {}).get("unit") or "pytest -q"
    try:
        tokens = shlex.split(cmd)
    except ValueError as exc:
        return AssertionResult(False, f"could not parse test command {cmd!r}: {exc}")
    py = ctx.get("python_interpreter") or resolve_python()
    if tokens and tokens[0] == "pytest":
        argv = [py, "-m", "pytest"] + tokens[1:]
    elif tokens and tokens[0] in ("python", "python3", "py"):
        argv = [py] + tokens[1:]
    else:
        argv = tokens
    try:
        r = subprocess.run(
            argv, cwd=str(target), capture_output=True, text=True, timeout=180
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return AssertionResult(False, f"failed to run test command {cmd!r}: {exc}")
    if r.returncode != 0:
        tail = ((r.stdout or "") + (r.stderr or ""))[-800:]
        return AssertionResult(
            False, f"test command {cmd!r} exited {r.returncode}:\n{tail}"
        )
    return AssertionResult(True, f"test command {cmd!r} passed")


def git_rev_parse_head(target: Path) -> str | None:
    try:
        r = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=str(target),
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    return r.stdout.strip() if r.returncode == 0 else None


def assert_git_head_unchanged(target: Path, params: dict, ctx: dict) -> AssertionResult:
    before = ctx.get("initial_head")
    after = git_rev_parse_head(target)
    if before is None or after is None:
        return AssertionResult(False, "could not determine git HEAD before/after")
    if before != after:
        return AssertionResult(False, f"HEAD changed: {before} -> {after}")
    return AssertionResult(True, f"HEAD unchanged at {before[:12]}")


def assert_json_path(target: Path, params: dict, ctx: dict) -> AssertionResult:
    rel = params["file"]
    f = target / rel
    if not f.is_file():
        return AssertionResult(False, f"{rel} does not exist")
    try:
        data = json.loads(f.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        return AssertionResult(False, f"{rel} is not valid JSON: {exc}")
    val = _dotted_get(data, params["path"])
    if val is _MISSING:
        return AssertionResult(False, f"{rel}: path `{params['path']}` not found")
    # `min_length` for the "this list is non-empty" shape -- an audit trail
    # assertion cares that something was recorded, not exactly how many.
    if "min_length" in params:
        want = params["min_length"]
        try:
            n = len(val)
        except TypeError:
            return AssertionResult(
                False, f"{rel}: `{params['path']}` = {val!r} has no length"
            )
        if n < want:
            return AssertionResult(
                False, f"{rel}: `{params['path']}` has {n} entr(ies), expected >= {want}"
            )
        return AssertionResult(True, f"{rel}: `{params['path']}` has {n} entr(ies) (>= {want})")
    expected = params["equals"]
    if val != expected:
        return AssertionResult(
            False, f"{rel}: `{params['path']}` = {val!r}, expected {expected!r}"
        )
    return AssertionResult(True, f"{rel}: `{params['path']}` == {expected!r}")


def _first_fenced_block(text: str) -> str | None:
    """The first ```-fenced block, or None."""
    m = re.search(r"^```[^\n]*\n(.*?)^```", text, re.S | re.M)
    return m.group(1) if m else None


def assert_output_max_lines(target: Path, params: dict, ctx: dict) -> AssertionResult:
    """Bound the length of a skill's readout.

    `scope: "fenced"` measures the first ```-fenced block instead of the whole
    message. Use it for any skill whose contract is a structured readout: the
    child session still inherits the operator's OUTPUT STYLE (an
    "explanatory"/"learning" style appends commentary blocks), and there is no
    way to force that off from the CLI -- `--settings {"outputStyle":"default"}`
    does not override the user-level setting, and isolating CLAUDE_CONFIG_DIR
    breaks auth because credentials live there. Measuring the fenced artifact
    makes the assertion depend on the skill instead of on who ran it, which is
    what keeps a baseline reproducible across machines and in CI.
    """
    text = ctx.get("final_text") or ""
    scope = params.get("scope", "message")
    measured, where = text, "final output"
    if scope == "fenced":
        block = _first_fenced_block(text)
        if block is not None:
            measured, where = block, "fenced readout block"
        else:
            where = "final output (no fenced block found)"
    lines = [ln for ln in measured.splitlines() if ln.strip()]
    n = params["n"]
    if len(lines) > n:
        return AssertionResult(
            False, f"{where} has {len(lines)} non-blank line(s), max {n}"
        )
    return AssertionResult(True, f"{where} has {len(lines)} non-blank line(s) (<= {n})")


def assert_output_contains(target: Path, params: dict, ctx: dict) -> AssertionResult:
    text = ctx.get("final_text") or ""
    needle = params["text"]
    if needle not in text:
        return AssertionResult(False, f"final output does not contain {needle!r}")
    return AssertionResult(True, f"final output contains {needle!r}")


def assert_tree_unchanged(target: Path, params: dict, ctx: dict) -> AssertionResult:
    try:
        r = subprocess.run(
            ["git", "status", "--porcelain"],
            cwd=str(target),
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return AssertionResult(False, f"could not run git status: {exc}")
    dirty = r.stdout.strip()
    if dirty:
        return AssertionResult(False, f"working tree has changes:\n{dirty}")
    return AssertionResult(True, "working tree clean (git status --porcelain empty)")


def _iter_glob_files(target: Path, pattern: str) -> list[Path]:
    return [p for p in target.glob(pattern) if p.is_file()]


def assert_file_matches(target: Path, params: dict, ctx: dict) -> AssertionResult:
    files = _iter_glob_files(target, params["glob"])
    if not files:
        return AssertionResult(False, f"no files match `{params['glob']}`")
    pattern = re.compile(params["pattern"])
    for f in files:
        text = f.read_text(encoding="utf-8", errors="replace")
        if pattern.search(text):
            return AssertionResult(
                True, f"{f.relative_to(target)} matches `{params['pattern']}`"
            )
    return AssertionResult(
        False,
        f"no file matching `{params['glob']}` contains `{params['pattern']}`",
    )


def assert_file_not_matches(target: Path, params: dict, ctx: dict) -> AssertionResult:
    files = _iter_glob_files(target, params["glob"])
    if not files:
        return AssertionResult(False, f"no files match `{params['glob']}`")
    pattern = re.compile(params["pattern"])
    offenders = []
    for f in files:
        text = f.read_text(encoding="utf-8", errors="replace")
        if pattern.search(text):
            offenders.append(str(f.relative_to(target)))
    if offenders:
        return AssertionResult(
            False, f"`{params['pattern']}` found in: {', '.join(offenders)}"
        )
    return AssertionResult(
        True,
        f"`{params['pattern']}` not found in any of {len(files)} file(s) "
        f"matching `{params['glob']}`",
    )


def assert_json_keys_subset(target: Path, params: dict, ctx: dict) -> AssertionResult:
    sub_rel, sup_rel = params["file"], params["superset_file"]
    sub_f, sup_f = target / sub_rel, target / sup_rel
    if not sub_f.is_file():
        return AssertionResult(False, f"{sub_rel} does not exist")
    if not sup_f.is_file():
        return AssertionResult(False, f"{sup_rel} does not exist")
    try:
        sub = json.loads(sub_f.read_text(encoding="utf-8"))
        sup = json.loads(sup_f.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        return AssertionResult(False, f"invalid JSON: {exc}")
    # Underscore-prefixed keys are inline documentation, not config. The example
    # file is full of them (_globs_comment, _deploy_delta_comment), the repo's own
    # registry check strips them when building its key set (check_contracts.py), and
    # a generated config that adds its own `_..._comment` is following the house
    # style, not inventing config. Treat them the same way here so the two agree.
    def _config_keys(obj: Any) -> set[str]:
        return {
            k
            for k in _all_dotted_keys(obj)
            if not any(part.startswith("_") for part in k.split("."))
        }

    sub_keys = _config_keys(sub)
    sup_keys = _config_keys(sup)
    extra = sub_keys - sup_keys
    if extra:
        return AssertionResult(
            False, f"{sub_rel} has key(s) not in {sup_rel}: {sorted(extra)}"
        )
    return AssertionResult(
        True, f"all {len(sub_keys)} key(s) in {sub_rel} present in {sup_rel}"
    )


def assert_file_exists(target: Path, params: dict, ctx: dict) -> AssertionResult:
    p = target / params["path"]
    if not p.is_file():
        return AssertionResult(False, f"{params['path']} does not exist")
    return AssertionResult(True, f"{params['path']} exists")


def assert_count_occurrences(target: Path, params: dict, ctx: dict) -> AssertionResult:
    rel = params["file"]
    f = target / rel
    if not f.is_file():
        return AssertionResult(False, f"{rel} does not exist")
    text = f.read_text(encoding="utf-8", errors="replace")
    needle = params["text"]
    # `mode: "regex"` counts pattern matches. Prefer it whenever the thing being
    # counted is a RECORD rather than a word: a dedup check wants one ENTRY, and
    # a single entry may legitimately mention its own subject several times, so a
    # substring count reports a duplicate that is not there.
    if params.get("mode") == "regex":
        actual = len(re.findall(needle, text))
    else:
        actual = text.count(needle)
    expected = params["equals"]
    if actual != expected:
        return AssertionResult(
            False, f"{rel} contains {needle!r} {actual} time(s), expected {expected}"
        )
    return AssertionResult(True, f"{rel} contains {needle!r} exactly {expected} time(s)")


def assert_agent_models_within_cap(target: Path, params: dict, ctx: dict) -> AssertionResult:
    cap = params.get("cap", "sonnet")
    cap_rank = TIER_RANK.get(cap, 0)
    pinned = ctx.get("pinned_agents") or {}
    agent_uses: list[dict] = ctx.get("agent_tool_uses") or []
    violations: list[str] = []
    for use in agent_uses:
        subtype = use.get("subagent_type")
        model = use.get("model")
        if not model:
            if subtype in pinned:
                model = pinned[subtype]
            else:
                violations.append(
                    f"Agent dispatch (subagent_type={subtype!r}) has no model "
                    f"and is not a pinned agent -- it would inherit the "
                    f"orchestrator's model"
                )
                continue
        tier = tier_of(model)
        if TIER_RANK.get(tier, 0) > cap_rank:
            violations.append(
                f"Agent dispatch (subagent_type={subtype!r}) ran {model} "
                f"(tier {tier}), above cap {cap}"
            )
    if violations:
        return AssertionResult(False, "; ".join(violations))
    return AssertionResult(
        True, f"all {len(agent_uses)} agent dispatch(es) within cap {cap}"
    )


ASSERTION_FUNCS = {
    "tasks_row_added": assert_tasks_row_added,
    "tasks_row_state": assert_tasks_row_state,
    "glob_exists": assert_glob_exists,
    "pytest_green": assert_pytest_green,
    "git_head_unchanged": assert_git_head_unchanged,
    "json_path": assert_json_path,
    "output_max_lines": assert_output_max_lines,
    "output_contains": assert_output_contains,
    "tree_unchanged": assert_tree_unchanged,
    "file_matches": assert_file_matches,
    "file_not_matches": assert_file_not_matches,
    "json_keys_subset": assert_json_keys_subset,
    "file_exists": assert_file_exists,
    "count_occurrences": assert_count_occurrences,
    "agent_models_within_cap": assert_agent_models_within_cap,
}


# ── Child-session plumbing ───────────────────────────────────────────────


def run_cmd(argv: list[str], *, cwd: Path, env: dict | None = None, timeout: int = 120):
    # encoding/errors are load-bearing on Windows: text=True alone decodes with
    # the ANSI codepage (cp1252 here), and the toolkit's own output is full of
    # em-dashes and box-drawing characters. A single undecodable byte kills the
    # reader thread, and subprocess then hands back stdout=None -- which
    # surfaces far away as "NoneType has no attribute splitlines".
    return subprocess.run(
        argv,
        cwd=str(cwd),
        env=env,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=timeout,
    )


def resolve_bash() -> str:
    """Absolute path to a bash that can see Windows drive paths.

    A bare "bash" is wrong on Windows: subprocess uses CreateProcess, which
    searches System32 *before* PATH, so it finds WSL's bash.exe -- which has
    no H:/ drive and fails with "No such file or directory" on a path that
    plainly exists. (shutil.which searches PATH only, so it disagrees with
    what subprocess actually launches; that discrepancy is the tell.)
    Resolve explicitly, and reject the WSL/WindowsApps stubs by path.
    """
    override = os.environ.get("SKILL_EVAL_BASH")
    if override:
        return override
    if os.name != "nt":
        return "bash"
    bad = ("system32", "windowsapps")
    found = shutil.which("bash")
    if found and not any(b in found.lower() for b in bad):
        return found
    for candidate in (
        r"C:\Program Files\Git\bin\bash.exe",
        r"C:\Program Files\Git\usr\bin\bash.exe",
        r"C:\Program Files (x86)\Git\bin\bash.exe",
    ):
        if Path(candidate).is_file():
            return candidate
    raise SystemExit(
        "no usable bash found. Install Git for Windows, or set SKILL_EVAL_BASH "
        "to a bash that can see Windows drive paths (WSL's bash cannot)."
    )


def resolve_claude() -> str:
    """Absolute path to the Claude Code CLI.

    Same CreateProcess caveat as resolve_bash, one layer down: on Windows the
    npm shim is claude.CMD, and CreateProcess does not apply PATHEXT, so a
    bare "claude" raises WinError 2 even though the shim is plainly on PATH.
    """
    override = os.environ.get("SKILL_EVAL_CLAUDE")
    if override:
        return override
    found = shutil.which("claude")
    if not found:
        raise SystemExit(
            "claude CLI not found on PATH. Install Claude Code, or set "
            "SKILL_EVAL_CLAUDE to its absolute path."
        )
    return found


def git_init_and_commit(target: Path) -> str | None:
    env = dict(os.environ)
    env.setdefault("GIT_AUTHOR_NAME", "skill-eval")
    env.setdefault("GIT_AUTHOR_EMAIL", "skill-eval@localhost")
    env.setdefault("GIT_COMMITTER_NAME", "skill-eval")
    env.setdefault("GIT_COMMITTER_EMAIL", "skill-eval@localhost")
    for argv in (
        ["git", "init", "-q"],
        ["git", "add", "-A"],
        ["git", "commit", "-q", "-m", "baseline fixture commit", "--no-verify"],
    ):
        r = run_cmd(argv, cwd=target, env=env, timeout=30)
        if r.returncode != 0:
            return None
    return git_rev_parse_head(target)


def install_toolkit(target: Path) -> tuple[bool, str]:
    # Pass POSIX-form paths: these are bash *arguments*, and on Windows a
    # native path (H:\a\b) reaches bash with its backslashes eaten as escapes
    # ("H:ab"). `cwd=` below is handled by Python itself and stays native.
    r = run_cmd(
        [
            resolve_bash(),
            SETUP_SH.as_posix(),
            "--target",
            target.as_posix(),
            "--tools",
            "claude",
            "--no-hooks",
        ],
        cwd=REPO_ROOT,
        timeout=60,
    )
    ok = r.returncode == 0
    return ok, ((r.stdout or "") + (r.stderr or ""))


def build_child_env(target: Path) -> dict:
    """Child-session isolation (non-negotiable): the child inherits the
    parent's environment by default, and the parent here is THIS repo -- a
    hook resolving CLAUDE_PROJECT_DIR from inheritance would point at the
    plugin repo's own .claude/, not the fixture's. Set it EXPLICITLY to the
    temp dir rather than merely unsetting it. Never touch the user's global
    ~/.claude/settings.json -- HOME is left alone so `claude` can still read
    its own auth config; only the PROJECT-scoped resolution is redirected."""
    env = dict(os.environ)

    # Scrub the PARENT session's own bookkeeping. When this harness is driven
    # from inside a Claude Code session (the normal case while developing it),
    # the child otherwise inherits CLAUDE_CODE_SESSION_ID, a live messaging
    # socket, CLAUDE_CODE_CHILD_SESSION, CLAUDE_EFFORT and friends -- state
    # describing a different session entirely. Keep only the auth vars, which
    # are what CI actually supplies.
    keep = {"CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"}
    for k in [k for k in env if k.startswith("CLAUDE") and k not in keep]:
        env.pop(k, None)
    env.pop("CLAUDECODE", None)
    env.pop("AI_AGENT", None)

    env["CLAUDE_PROJECT_DIR"] = str(target)
    return env


def run_claude_once(
    prompt: str, target: Path, max_budget_usd: float, timeout: int
) -> tuple[list[dict], str]:
    """Runs one headless `claude -p` turn. Returns (parsed events, raw stdout).

    Verified flag shape (Claude Code 2.1.261): -p, --output-format
    stream-json, --verbose, --permission-mode bypassPermissions,
    --max-budget-usd. `--max-turns` does not exist and must never be passed;
    --max-budget-usd is the only spend bound.
    """
    argv = [
        resolve_claude(),
        # Pin a neutral output style. Without this the operator's personal
        # style leaks in and shapes the measured text -- a "learning"/
        # "explanatory" style appends commentary blocks that have nothing to do
        # with the skill under test, so output_max_lines measures the operator's
        # settings, not the skill, and a baseline recorded on one machine will
        # not reproduce on another (or in CI).
        "--settings",
        '{"outputStyle":"default"}',
        "-p",
        prompt,
        "--output-format",
        "stream-json",
        "--verbose",
        "--permission-mode",
        "bypassPermissions",
        "--max-budget-usd",
        str(max_budget_usd),
    ]
    env = build_child_env(target)
    r = run_cmd(argv, cwd=target, env=env, timeout=timeout)
    # Belt-and-braces: a crashed reader thread yields None rather than "".
    stdout = r.stdout or ""
    events: list[dict] = []
    for line in stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return events, stdout


def extract_result_fields(events: list[dict]) -> dict:
    """Reads total_cost_usd / num_turns / duration_ms defensively -- these
    are UNDOCUMENTED result-event fields, so `.get()` everywhere and record
    null on absence rather than KeyError on a schema change."""
    result_event = None
    for ev in events:
        if ev.get("type") == "result":
            result_event = ev
    if result_event is None:
        return {"total_cost_usd": None, "num_turns": None, "duration_ms": None}
    return {
        "total_cost_usd": result_event.get("total_cost_usd"),
        "num_turns": result_event.get("num_turns"),
        "duration_ms": result_event.get("duration_ms"),
    }


def extract_final_text(events: list[dict]) -> str:
    for ev in reversed(events):
        if ev.get("type") == "result" and isinstance(ev.get("result"), str):
            return ev["result"]
    for ev in reversed(events):
        if ev.get("type") == "assistant":
            content = (ev.get("message") or {}).get("content")
            if isinstance(content, list):
                texts = [b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text"]
                if texts:
                    return "\n".join(texts)
    return ""


# ── Per-case run ─────────────────────────────────────────────────────────


def run_case(name: str, args: argparse.Namespace, results_root: Path) -> dict:
    case = load_case(name)
    started_at = datetime.now(timezone.utc).isoformat()
    case_result_dir = results_root / name

    tmp = Path(tempfile.mkdtemp(prefix=f"skill-eval-{name}-"))
    print(f"[{name}] fixture copy: {tmp}")

    findings: list[str] = []
    assertion_results: list[dict] = []
    setup_ok = True
    claude_ok = True
    all_events: list[dict] = []
    final_text = ""
    cost_total = 0.0
    cost_seen = False
    turns_total = 0
    turns_seen = False
    duration_total = 0
    duration_seen = False

    try:
        shutil.copytree(FIXTURE_DIR, tmp, dirs_exist_ok=True)

        for rel in case.get("pre_setup_remove", []):
            p = tmp / rel
            if p.is_dir():
                shutil.rmtree(p, ignore_errors=True)
            elif p.exists():
                p.unlink()

        # Install BEFORE the baseline commit. The toolkit's own installed files
        # are part of the fixture's starting state, not something the skill under
        # test produced -- committing first would leave every installed path
        # untracked and make `tree_unchanged` fail on setup.sh's output rather
        # than on anything the skill did.
        setup_ok, setup_log = install_toolkit(tmp)
        if not setup_ok:
            findings.append(f"setup.sh failed:\n{setup_log[-800:]}")

        initial_head = git_init_and_commit(tmp)

        initial_tasks_row_count = None
        tasks_file = tmp / case.get("assertions_context", {}).get("tasks_file", "TASKS.md")
        if tasks_file.is_file():
            initial_tasks_row_count = _count_task_rows(
                tasks_file.read_text(encoding="utf-8", errors="replace")
            )

        if setup_ok:
            repeat = int(case.get("repeat", 1))
            for i in range(1, repeat + 1):
                events, raw = run_claude_once(
                    case["prompt"], tmp, case.get("max_budget_usd", 1.0), args.timeout
                )
                events_path = case_result_dir / (
                    "events.jsonl" if repeat == 1 else f"events-{i}.jsonl"
                )
                safe_write_text(events_path, raw, roots=[RESULTS_DIR])
                all_events.extend(events)
                fields = extract_result_fields(events)
                if fields["total_cost_usd"] is not None:
                    cost_total += fields["total_cost_usd"]
                    cost_seen = True
                if fields["num_turns"] is not None:
                    turns_total += fields["num_turns"]
                    turns_seen = True
                if fields["duration_ms"] is not None:
                    duration_total += fields["duration_ms"]
                    duration_seen = True
                final_text = extract_final_text(events)
                if not events:
                    claude_ok = False
                    findings.append(f"run {i}: no stream-json events parsed from claude -p")
                # A session the CLI itself aborted did not finish the work, so the
                # tree it left behind is a partial one. Grading it would report
                # the truncation as skill failures -- name the real cause instead.
                for ev in events:
                    if ev.get("type") != "result" or not ev.get("is_error"):
                        continue
                    sub = ev.get("subtype") or "unknown"
                    claude_ok = False
                    if sub == "error_max_budget_usd":
                        findings.append(
                            f"run {i}: session ABORTED on the --max-budget-usd ceiling "
                            f"(${case.get('max_budget_usd', 1.0)}). Cost "
                            f"{fields['total_cost_usd']}. The tree is "
                            f"partial, so the assertion results below are NOT skill "
                            f"findings -- raise max_budget_usd for this case and re-run."
                        )
                    else:
                        findings.append(f"run {i}: session ended with error subtype {sub!r}")
                    break

        ctx = {
            "initial_head": initial_head,
            "initial_tasks_row_count": initial_tasks_row_count,
            "final_text": final_text,
            "pinned_agents": load_pinned_agents(),
            "agent_tool_uses": extract_agent_tool_uses(all_events),
            "python_interpreter": resolve_python(),
        }

        if setup_ok:
            for a in case.get("assertions", []):
                fn = ASSERTION_FUNCS.get(a["type"])
                if fn is None:
                    assertion_results.append(
                        {"type": a["type"], "passed": False, "message": "no such assertion type implemented"}
                    )
                    continue
                try:
                    res = fn(tmp, a, ctx)
                except Exception as exc:  # noqa: BLE001 - report, don't crash the run
                    res = AssertionResult(False, f"assertion raised {exc!r}")
                assertion_results.append(
                    {"type": a["type"], "passed": res.passed, "message": res.message}
                )
        else:
            for a in case.get("assertions", []):
                assertion_results.append(
                    {"type": a["type"], "passed": False, "message": "skipped: setup.sh failed"}
                )
    finally:
        if not args.keep_tmp:
            shutil.rmtree(tmp, ignore_errors=True)
        else:
            print(f"[{name}] kept temp dir: {tmp}")

    overall_pass = setup_ok and claude_ok and all(a["passed"] for a in assertion_results)

    baseline = load_baseline()
    cost_regression = None
    baseline_cost = baseline.get(name, {}).get("total_cost_usd") if isinstance(baseline.get(name), dict) else None
    actual_cost = cost_total if cost_seen else None
    if baseline_cost is not None and actual_cost is not None and baseline_cost > 0:
        if actual_cost > 2 * baseline_cost:
            cost_regression = (
                f"{name}: cost {actual_cost:.4f} exceeds 2x baseline {baseline_cost:.4f}"
            )
            overall_pass = False

    result = {
        "case": name,
        "started_at": started_at,
        "ended_at": datetime.now(timezone.utc).isoformat(),
        "setup_ok": setup_ok,
        "claude_ok": claude_ok,
        "assertions": assertion_results,
        "overall_pass": overall_pass,
        "total_cost_usd": actual_cost,
        "num_turns": turns_total if turns_seen else None,
        "duration_ms": duration_total if duration_seen else None,
        "cost_regression": cost_regression,
        "findings": findings,
    }
    safe_write_text(
        case_result_dir / "result.json", json.dumps(result, indent=2), roots=[RESULTS_DIR]
    )
    return result


# ── Baseline ─────────────────────────────────────────────────────────────


def load_baseline() -> dict:
    if not BASELINE_FILE.is_file():
        return {}
    try:
        return json.loads(BASELINE_FILE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def update_baseline(results: list[dict]) -> None:
    """The ONE deliberate exception to the temp-dir/results-dir sandbox: only
    reachable when the user explicitly passes --update-baseline, and always
    writes the literal BASELINE_FILE constant -- never a derived/parametrized
    path -- so there is no path here an untrusted case file could redirect."""
    baseline = load_baseline()
    for r in results:
        if r["total_cost_usd"] is None:
            continue
        baseline[r["case"]] = {
            "total_cost_usd": r["total_cost_usd"],
            "recorded_at": r["ended_at"],
        }
    BASELINE_FILE.write_text(json.dumps(baseline, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"wrote {BASELINE_FILE}")


# ── Summary / reporting ──────────────────────────────────────────────────


def write_summary(results: list[dict], results_root: Path) -> None:
    total = len(results)
    passed = sum(1 for r in results if r["overall_pass"])
    summary = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "total": total,
        "passed": passed,
        "failed": total - passed,
        "overall": "PASS" if passed == total and total > 0 else "FAIL" if total else "SKIP",
        "cases": results,
    }
    safe_write_text(
        results_root / "summary.json", json.dumps(summary, indent=2), roots=[RESULTS_DIR]
    )

    lines = ["# Skill evals summary", ""]
    lines.append(f"timestamp: {summary['timestamp']}")
    lines.append(f"overall: {summary['overall']} ({passed}/{total} cases)")
    lines.append("")
    lines.append("| case | pass | cost | turns | seconds |")
    lines.append("|---|---|---|---|---|")
    for r in results:
        secs = f"{r['duration_ms']/1000:.1f}" if r["duration_ms"] is not None else "n/a"
        cost = f"${r['total_cost_usd']:.4f}" if r["total_cost_usd"] is not None else "n/a"
        turns = r["num_turns"] if r["num_turns"] is not None else "n/a"
        lines.append(
            f"| {r['case']} | {'PASS' if r['overall_pass'] else 'FAIL'} | {cost} | {turns} | {secs} |"
        )
        for a in r["assertions"]:
            mark = "ok" if a["passed"] else "FAIL"
            lines.append(f"|   - {a['type']} ({mark}) | | | | {a['message'][:200]} |")
        if r["cost_regression"]:
            lines.append(f"|   - cost regression | | | | {r['cost_regression']} |")
    safe_write_text(results_root / "summary.md", "\n".join(lines) + "\n", roots=[RESULTS_DIR])


# ── CLI ──────────────────────────────────────────────────────────────────


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--case", action="append", metavar="NAME", help="run one case by name (repeatable)")
    parser.add_argument("--all", action="store_true", help="run every case in evals/skills/cases/")
    parser.add_argument("--keep-tmp", action="store_true", help="do not delete the per-case temp fixture copy")
    parser.add_argument(
        "--update-baseline",
        action="store_true",
        help="rewrite evals/skills/baseline.json from this run's recorded costs",
    )
    parser.add_argument(
        "--timeout", type=int, default=900, help="per `claude -p` invocation timeout in seconds (default 900)"
    )
    args = parser.parse_args(argv)

    if not args.case and not args.all:
        parser.error("pass --case NAME (repeatable) or --all")

    case_names = args.case if args.case else discover_case_names()
    if not case_names:
        print("no cases found under", CASES_DIR, file=sys.stderr)
        return 1

    date_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    results_root = RESULTS_DIR / f"{date_str}-{uuid.uuid4().hex[:8]}"

    results = []
    for name in case_names:
        print(f"=== {name} ===")
        results.append(run_case(name, args, results_root))

    write_summary(results, results_root)

    if args.update_baseline:
        update_baseline(results)

    failed = [r for r in results if not r["overall_pass"]]
    print()
    print(f"{len(results) - len(failed)}/{len(results)} case(s) passed. Results: {results_root}")
    for r in failed:
        bad = [a for a in r["assertions"] if not a["passed"]]
        for a in bad:
            print(f"  FAIL {r['case']} :: {a['type']}: {a['message'][:300]}")
        if r["cost_regression"]:
            print(f"  FAIL {r['case']} :: cost_regression: {r['cost_regression']}")
        for f in r["findings"]:
            print(f"  FAIL {r['case']} :: {f[:300]}")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
