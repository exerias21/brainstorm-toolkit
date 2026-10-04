#!/usr/bin/env python3
"""Find docstrings and comments that drifted from their code -- the
docstring-sync skill's mechanical core (Phase 1: no model calls at all).

Uses `ast` + `tokenize`, never `import`, for the same reason
`skills/code-tour/scripts/docstring_audit.py` does: importing the target
would execute it (side effects, missing dependencies, environment-only
failures), and regex cannot tell a docstring from any other string literal
or reliably separate a real comment from a string that merely looks like
one. `ast.parse` and `tokenize.generate_tokens` only read text, so this
audits code that cannot even run here.

What it checks (each decided by the script, no model judgment):

  POINTER      -- a comment or docstring cites a plan file, a TASKS.md row,
                  or bare plan/phase/step numbering. A cited path that is
                  missing or gitignored is `certain`; bare numbering with no
                  path, and a ticket reference that is the ONLY content of
                  its comment, are `suspect`. A pointer to a tracked,
                  non-plan file (an ADR, a doc) is left alone entirely: a
                  plan is ephemeral and often not even version-controlled in
                  a consumer repo, so citing one is what rots, while an ADR
                  or another durable doc is meant to persist and is not the
                  kind of rot this check targets. A docstring that cites a
                  backticked identifier or Sphinx cross-reference role
                  (:func:, :class:, :meth:, :attr:) resolving to no name
                  written anywhere in the scanned code is a dangling
                  reference, always `suspect` -- the name may simply have
                  been renamed elsewhere, so this is a prompt to confirm,
                  never an accusation.
  PLACEHOLDER  -- an empty docstring, an autoDocstring stub ('_summary_',
                  '_description_'), a bare TODO, or a generated
                  "Docstring for X" line.
  THIN         -- documented params disagree with the signature (Google,
                  NumPy or Sphinx sections only -- an unrecognized style is
                  skipped, never guessed at), or a Returns section on a body
                  that never returns a value (excluding stub/NotImplementedError
                  bodies, where "no return yet" is the honest state).
  MISSING      -- a public symbol with no docstring at all. Report-only: this
                  script never writes a docstring, so there is nothing here
                  for a human to approve or reject.
  BODY_NEWER   -- a symbol's code changed, via git blame author-time, more
                  recently than its own docstring. Always `suspect`: a body
                  edit after its docstring is a prior worth a human or model
                  looking closer, not proof the docstring is now wrong.
  STALE        -- only present after a --verdicts-in pass: a specific
                  docstring sentence a judgment step (a probability-scoring
                  judge or an LLM triage agent) marked contradicted or
                  overgeneralized against the symbol's own source. `certain`
                  when the verdict carries a verified quote or a calibrated
                  "act" band, `suspect` otherwise -- the script owns this
                  mapping, never the judge.

Every finding also carries `runtime_visible` (a route/CLI decorator,
`description=__doc__`, or a `>>>` doctest block makes a docstring a public
contract, not just documentation) so a downstream rewrite can skip it by
default.

Discovery respects `.gitignore` via `git ls-files` (read-only) when the
target is a git repository, and falls back to a fixed exclude list
otherwise. Any git call resolves the binary via `shutil.which`, never a
bare git executable name, and uses only read-only subcommands (`ls-files`,
`diff --name-only`, `check-ignore`, `blame --line-porcelain`); an absent
git or a non-repo path is a silent, graceful fallback, never a crash. Any
path with a `fixtures` directory segment is excluded from discovery unless
that path (or a path under it) is named explicitly as a positional
argument -- a fixture is a deliberately shaped test input, not
documentation, and a repair pass over one destroys the test it backs.

Exit codes:
  0  no findings
  1  findings reported
  2  a file could not be parsed, nothing was discovered, or a --verdicts-in
     id did not resolve against the current scan (loud, never a silent
     "0 files, all clean" or a silently dropped verdict)

Usage:
    bash scripts/py.sh docstring_check.py [PATH ...] [--changed]
                        [--include-tests] [--pointers-only] [--json]
                        [--limit N] [--snapshot] [--verify-docs-only FILE]
                        [--claims-out FILE] [--verdicts-in FILE] [--all]
                        [--self-test]

Examples:
    bash scripts/py.sh docstring_check.py skills/
    bash scripts/py.sh docstring_check.py --changed --json
    bash scripts/py.sh docstring_check.py --pointers-only .
    bash scripts/py.sh docstring_check.py skills/foo --claims-out claims.json
    bash scripts/py.sh docstring_check.py skills/foo --verdicts-in verdicts.json
"""
from __future__ import annotations

import argparse
import ast
import builtins
import contextlib
import fnmatch
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import tokenize
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from pathlib import Path

# ── Reused from skills/code-tour/scripts/docstring_audit.py: copied, not
# imported, with a one-line provenance comment on each borrowed piece below.
# A shared import would couple two skills' install trees together, so each
# stays self-contained and installable on its own ──────────────────────────

# Directories that are never the project's own source -- copied verbatim from
# docstring_audit.py:53-57 as the non-git discovery fallback.
_DEFAULT_EXCLUDES = (
    "*/.git/*", "*/node_modules/*", "*/.venv/*", "*/venv/*", "*/env/*",
    "*/__pycache__/*", "*/site-packages/*", "*/.tox/*", "*/.mypy_cache/*",
    "*/build/*", "*/dist/*", "*/.eggs/*", "*/migrations/*",
)

# Copied verbatim from docstring_audit.py:59.
_TEST_PATTERNS = ("test_*.py", "*_test.py", "conftest.py", "selftest.py")

# Extensions the generic (non-Python) comment-prefix heuristic scans. Kept
# small and explicit: this heuristic cannot parse any of these languages, so
# widening it just widens the false-positive surface for no real gain.
_HEURISTIC_TEXT_EXTS = (
    ".js", ".ts", ".jsx", ".tsx", ".go", ".rs", ".java", ".c", ".cc", ".cpp",
    ".h", ".hpp", ".sh", ".yml", ".yaml", ".toml", ".rb",
)


def _is_private(name: str) -> bool:
    """A leading underscore marks a private symbol -- but dunders are not
    private. Copied from docstring_audit.py:83-92 (provenance above)."""
    return name.startswith("_") and not (name.startswith("__") and name.endswith("__"))


def _walk_symbols(tree: ast.AST) -> list[tuple[ast.AST, str]]:
    """Collect every def/class with its qualified name, descending into
    nesting. Adapted from docstring_audit.py:95-118 (provenance above) --
    unchanged in behavior, this file just keeps the node instead of
    discarding it, since later checks need params/body/decorators too."""
    found: list[tuple[ast.AST, str]] = []

    def visit(node: ast.AST, prefix: str) -> None:
        for child in ast.iter_child_nodes(node):
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                qualified = f"{prefix}{child.name}"
                found.append((child, qualified))
                visit(child, f"{qualified}.")
            else:
                visit(child, prefix)

    visit(tree, "")
    return found


# ── git helpers -- read-only subcommands only, absolute binary, graceful
# degradation when git is absent or the path is not a repo ─────────────────


def _git_binary() -> str | None:
    return shutil.which("git")


def _run_git(args: list[str], cwd: Path) -> str | None:
    """Run a read-only git subcommand; None on any failure (no git, not a
    repo, bad path) -- callers treat None exactly like "git can't help
    here", never like an error worth surfacing."""
    git = _git_binary()
    if git is None:
        return None
    try:
        result = subprocess.run(
            [git, *args], cwd=str(cwd), capture_output=True,
            encoding="utf-8", errors="replace", timeout=20,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    return result.stdout


def _split_git_z(out: str) -> set[str]:
    """Split `-z` (NUL-separated, unquoted) git listing output. `-z` is
    used on every git listing call here instead of the default newline
    format specifically to avoid `core.quotepath` (on by default): a
    non-ASCII filename like `café.py` otherwise arrives octal-quoted
    (`"caf\\303\\251.py"`, literal surrounding quotes and backslash
    escapes), which does not end in a real extension and is silently
    dropped by `_scannable` -- `-z` disables that quoting entirely, so
    this just NUL-splits and drops the trailing empty field."""
    return {p for p in out.split("\0") if p}


def _git_tracked_files(root: Path) -> set[str] | None:
    out = _run_git(["ls-files", "-co", "--exclude-standard", "-z"], root)
    if out is None:
        return None
    return _split_git_z(out)


def _git_changed_files(root: Path) -> set[str] | None:
    """Tracked changes against HEAD plus untracked-not-ignored files --
    read-only (`diff --name-only`, `ls-files --others`).

    `--relative` on the diff call is load-bearing, not cosmetic: unlike
    `ls-files` (already relative to `cwd` by default), `git diff
    --name-only` prints paths relative to the repo's TOP LEVEL by default.
    When `root` is a subdirectory of the repo, the two would disagree --
    `root / <top-level-relative path>` doubles the subdirectory segment
    (`pkg/pkg/a.py` resolved against a root already inside `pkg/` becomes
    the nonexistent `pkg/pkg/pkg/a.py`), which is exactly the "unreadable"
    failure `--changed` must not produce just because it was invoked from
    somewhere other than the repo root.

    `--diff-filter=d` excludes deletions from the diff side: a path git
    still reports as "changed" because it was deleted from the working
    tree is nothing to scan, and left in would otherwise surface as an
    "unreadable" parse error and consume `--limit` for free."""
    diffed = _run_git(
        ["diff", "--relative", "--diff-filter=d", "--name-only", "-z", "HEAD"], root
    )
    others = _run_git(["ls-files", "--others", "--exclude-standard", "-z"], root)
    if diffed is None and others is None:
        return None
    changed: set[str] = set()
    for out in (diffed, others):
        if out:
            changed.update(_split_git_z(out))
    return changed


def _git_is_ignored(root: Path, rel_path: str) -> bool:
    out = _run_git(["check-ignore", "-q", rel_path], root)
    # check-ignore's exit code is what matters, not stdout; _run_git already
    # collapses non-zero to None, so a non-None (even empty) result means the
    # path IS ignored -- but check-ignore also returns non-zero (-> None)
    # when a repo simply has no ignore rule matching, which is
    # indistinguishable from "git unavailable" here. Query returncode
    # directly instead of trusting the None-means-not-ignored shortcut.
    git = _git_binary()
    if git is None:
        return False
    try:
        result = subprocess.run(
            [git, "check-ignore", "-q", rel_path], cwd=str(root),
            capture_output=True, encoding="utf-8", errors="replace", timeout=20,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return result.returncode == 0


_BLAME_HEADER_RE = re.compile(r"^([0-9a-f]{40}) \d+ (\d+)(?: \d+)?$")


def _parse_blame_porcelain(output: str) -> dict[int, tuple[str, int]]:
    """Map each final line number to (sha, author-unix-time) from
    `git blame --line-porcelain` output. `--line-porcelain` repeats full
    metadata for every line (not just the first of a run), so each header
    line is followed by its own `author-time` before the tab-prefixed
    source line ends that block -- an uncommitted line carries the
    all-zero SHA and the current time, which sorts as "newest" like any
    other commit; nothing here special-cases it."""
    lines = output.splitlines()
    result: dict[int, tuple[str, int]] = {}
    i = 0
    while i < len(lines):
        m = _BLAME_HEADER_RE.match(lines[i])
        if not m:
            i += 1
            continue
        sha, final_line = m.group(1), int(m.group(2))
        i += 1
        author_time: int | None = None
        while i < len(lines) and not lines[i].startswith("\t"):
            if lines[i].startswith("author-time "):
                try:
                    author_time = int(lines[i].split(" ", 1)[1])
                except (IndexError, ValueError):
                    author_time = None
            i += 1
        if i < len(lines):
            i += 1  # skip the tab-prefixed source line itself
        if author_time is not None:
            result[final_line] = (sha, author_time)
    return result


def _blame_map(root: Path, rel_path: str) -> dict[int, tuple[str, int]] | None:
    out = _run_git(["blame", "--line-porcelain", rel_path], root)
    if out is None:
        return None
    return _parse_blame_porcelain(out)


def _short_sha_date(sha: str, author_time: int) -> str:
    short = sha[:7]
    date = datetime.fromtimestamp(author_time, tz=timezone.utc).strftime("%Y-%m-%d")
    return f"{short} ({date})"


# ── Discovery ────────────────────────────────────────────────────────────────


def _has_fixtures_segment(path_like: str) -> bool:
    """True when `fixtures` is a whole directory SEGMENT of the (POSIX-form)
    path, not merely a substring (`prefixtures/x` must not match). Fixture
    trees (`evals/skills/fixtures/**`) are deliberately shaped test inputs
    with planted drift, not real documentation -- a repair pass over them
    would edit the very findings the eval fixture exists to plant, silently
    breaking the test it backs."""
    return "fixtures" in Path(path_like).as_posix().split("/")


def _under_any(candidate: Path, roots: list[Path]) -> bool:
    resolved = candidate.resolve()
    for root_ in roots:
        try:
            resolved.relative_to(root_)
            return True
        except ValueError:
            continue
    return False


def _dir_walk_excluded(root: Path, pp: Path, f: Path, tracked: set[str] | None) -> bool:
    """Should a file discovered by walking an explicitly-named DIRECTORY
    `pp` be dropped?

    Applies the same base rule the no-argument discovery applies (`tracked`
    is `_git_tracked_files(root)` when `root` is a repo, so membership in it
    mirrors `git ls-files -co --exclude-standard`; otherwise `_DEFAULT_EXCLUDES`
    matched root-relative, the same fallback the non-git walk already uses).

    But naming a directory is explicit intent to look inside it, even one
    that itself sits in an excluded area (`docstring_check.py node_modules/foo`)
    -- so a file is excluded by the base rule ONLY if that exclusion also
    holds relative to `pp` itself (i.e. there is a further excluded directory
    NESTED below the explicitly-named one, not just somewhere in `pp`'s own
    ancestry)."""
    if tracked is not None:
        base_excluded = _relposix(root, f) not in tracked
    else:
        rel_posix = "/" + _relposix(root, f)
        base_excluded = any(fnmatch.fnmatch(rel_posix, pat) for pat in _DEFAULT_EXCLUDES)
    if not base_excluded:
        return False
    nested_rel = "/" + _relposix(pp, f)
    return any(fnmatch.fnmatch(nested_rel, pat) for pat in _DEFAULT_EXCLUDES)


def discover(paths: list[str] | None, root: Path, changed: bool) -> list[Path]:
    """Resolve the file set to scan.

    Positional paths win the WALK (a directory is walked; a file is used
    as-is), but a directory's contents are still filtered through the same
    exclusion rule the no-argument discovery applies (`_dir_walk_excluded`)
    -- `docstring_check.py .` must not surface `node_modules/`, `.venv/`, or
    whatever `git` itself ignores just because a directory walk bypasses
    `_DEFAULT_EXCLUDES`/`.gitignore` by construction. An explicitly named
    FILE is always scanned regardless (explicit intent, one level stronger
    than a directory). When `--changed` is ALSO given alongside positional
    paths, the result is intersected with the changed-file set (scan the
    changed files under those paths, not everything under them).

    Otherwise: --changed uses read-only git diff/ls-files; plain invocation
    uses `git ls-files` when the root is a repo, falling back to a
    filesystem walk with `_DEFAULT_EXCLUDES` otherwise. Either way, a
    discovered path that does not actually exist as a file anymore (a
    deleted-but-still-indexed or deleted-but-still-diffed git entry) is
    dropped -- it is not a finding, it is nothing to scan.

    In every path, a file under a `fixtures` directory segment is excluded
    -- UNLESS that fixtures-bearing path (or an ancestor of it) was itself
    one of the positional arguments. `docstring_check.py .` must never surface
    a planted eval fixture as a "real" finding, but
    `docstring_check.py evals/skills/fixtures/legacy-docstrings` -- naming the
    fixture directly -- is a deliberate, explicit ask and is honored.
    """
    if paths:
        explicit_fixture_roots = [
            Path(p).resolve() for p in paths if _has_fixtures_segment(p)
        ]
        tracked = _git_tracked_files(root)
        files: list[Path] = []
        for p in paths:
            pp = Path(p)
            if pp.is_dir():
                candidates = sorted(pp.rglob("*.py"))
                for ext in _HEURISTIC_TEXT_EXTS:
                    candidates.extend(sorted(pp.rglob(f"*{ext}")))
                candidates = [
                    f for f in candidates if not _dir_walk_excluded(root, pp, f, tracked)
                ]
            elif pp.is_file():
                candidates = [pp]
            else:
                candidates = []
            for f in candidates:
                if _has_fixtures_segment(f.as_posix()) and not _under_any(f, explicit_fixture_roots):
                    continue
                files.append(f)
        if changed:
            changed_rels = _git_changed_files(root)
            if changed_rels is None:
                print("docstring_check: --changed requires a git repository; "
                      "found none usable here", file=sys.stderr)
                return []
            files = [f for f in files if _relposix(root, f) in changed_rels]
        return files

    if changed:
        rels = _git_changed_files(root)
        if rels is None:
            print("docstring_check: --changed requires a git repository; "
                  "found none usable here", file=sys.stderr)
            return []
        return sorted(
            p for p in (root / r for r in rels if _scannable(r) and not _has_fixtures_segment(r))
            if p.is_file()
        )

    tracked = _git_tracked_files(root)
    if tracked is not None:
        return sorted(
            p for p in (root / r for r in tracked if _scannable(r) and not _has_fixtures_segment(r))
            if p.is_file()
        )

    files = []
    for ext in (".py", *_HEURISTIC_TEXT_EXTS):
        for p in sorted(root.rglob(f"*{ext}")):
            # Root-relative, not `p.as_posix()` (absolute) -- an absolute path
            # inherits every ANCESTOR of `root` too, so running this fallback
            # from inside e.g. `.../evals/skills/fixtures/legacy-docstrings`
            # or `.../venv/myproject` would match `_DEFAULT_EXCLUDES`/fixtures
            # on `root`'s own ancestry and exclude every real file underneath
            # it. A leading "/" keeps a root-level match ("node_modules/x.py")
            # matching the same `*/dir/*`-shaped patterns a nested one would.
            rel_posix = "/" + _relposix(root, p)
            if any(fnmatch.fnmatch(rel_posix, pat) for pat in _DEFAULT_EXCLUDES):
                continue
            if _has_fixtures_segment(rel_posix):
                continue
            files.append(p)
    return files


def _scannable(rel: str) -> bool:
    return rel.endswith(".py") or rel.endswith(_HEURISTIC_TEXT_EXTS)


def _is_test_file(path: Path) -> bool:
    return any(fnmatch.fnmatch(path.name, pat) for pat in _TEST_PATTERNS)


# ── Finding record ───────────────────────────────────────────────────────────


@dataclass
class Finding:
    path: str
    line: int
    kind: str  # POINTER | PLACEHOLDER | THIN | MISSING | BODY_NEWER | STALE
    severity: str  # certain | suspect
    message: str
    symbol: str | None = None
    runtime_visible: bool = False
    pointer_only: bool | None = None
    heuristic: bool = False


@dataclass
class ScanResult:
    findings: list[Finding] = field(default_factory=list)
    parse_errors: list[tuple[str, str]] = field(default_factory=list)
    files_scanned: int = 0


# ── Pointer detection (comments and docstrings, Python and generic text) ────

# A cited path: requires a slash (so a bare mention of a same-directory
# module by name, e.g. "like utils.py", is never mistaken for a rotted
# reference) plus a recognized extension. An optional leading "." so a
# dotdir path (`.claude/project.json`) is captured whole rather than losing
# its leading dot (which would then look like a different, nonexistent
# path: "claude/project.json"). `(?<![\w./-])` instead of `\b` for the same
# reason -- `\b` cannot see a boundary right before a literal ".".
_PATH_WITH_SLASH_RE = re.compile(
    r"(?<![\w./-])\.?[A-Za-z0-9_][\w./-]*/[\w.-]+\.(?:md|py|json|ya?ml|txt)(?![\w.])"
)

# The generic "missing/gitignored, non-plan path" rule is scoped to paths
# that claim to be PART OF THIS TOOLKIT (the same top-level dirs
# check_contracts.py's own CITATION_RE trusts) -- `.claude/project.json`,
# `.claude/settings.json`, `codex/hooks.json` etc. are CONSUMER-repo-relative
# paths by this toolkit's own convention (never expected to exist here),
# and flagging them as "dangling" would be flagging the toolkit's own design.
_TOOLKIT_TOPLEVEL_DIRS = ("skills/", "scripts/", "templates/", "docs/", "agents/", "hooks/", "examples/")
# `TASKS.md` is special-cased bare, since "see TASKS.md row 12" never
# carries a directory. Only counted as a citation when a row/line/item
# number sits nearby -- a bare mention of the filename in ordinary prose
# ("its own AGENTS.md, TASKS.md, a plan file") is not a stale pointer to a
# specific row, just naming the file, and must not be flagged.
_BARE_TASKS_RE = re.compile(r"\bTASKS\.md\b")
_TASKS_ROW_NEARBY_RE = re.compile(r"\d")


def _looks_like_joined_filenames(path: str) -> bool:
    """True when an EARLIER path segment already ends in a recognized
    extension -- the `CLAUDE.md/AGENTS.md` shape, two filenames joined by a
    slash meaning "or", not a real path. Only the FINAL segment is allowed
    to carry the citation's extension."""
    segments = path.split("/")
    return any(
        re.search(r"\.(?:md|py|json|ya?ml|txt)$", seg, re.IGNORECASE)
        for seg in segments[:-1]
    )

# Plan-like: a "plans" (or "plan") path SEGMENT -- the directory name is what
# marks it, never the filename (a citation like
# `docs/plans/LAUNCH_REQUIREMENT_PHASES.md` is plan-like from its directory
# alone; that basename does not contain "plan" at all).
_PLAN_SEGMENT_RE = re.compile(r"(?:^|/)plans?(?:/|$)", re.IGNORECASE)

# Bare plan/phase/step numbering. Case-SENSITIVE and capitalized-only on
# purpose: numbered plan sections are conventionally capitalized ("Phase 1",
# "#### Phase 1"), while legitimate lowercase protocol prose ("step 3 of the
# TLS handshake") is not -- staying case-sensitive is what keeps the second
# case from ever being flagged. A cheap heuristic, not a parser, and stated
# as such.
_PHASE_STEP_RE = re.compile(r"\b(?:Phase|Step)\s+\d+\b")

# Ticket references. Suspect, and only flagged when the comment is otherwise
# pointer-only -- a ticket mentioned inside a substantive sentence is not a
# rotted pointer, it's citing context.
_JIRA_TICKET_RE = re.compile(r"\b[A-Z]{2,10}-\d{1,6}\b")
_GH_ISSUE_RE = re.compile(r"(?<![\w#])#\d{1,6}\b")

# Stripped in the pointer-only test: connective words that carry no
# independent meaning once the pointer itself is removed. Deliberately does
# NOT include negations ("not") or content verbs ("reintroduce", "keep") --
# those are exactly the load-bearing REASON text the policy says to keep.
_FILLER_WORDS = {
    "a", "an", "the", "of", "in", "on", "to", "for", "see", "per", "cf",
    "ref", "refer", "reference", "described", "row", "line", "item",
    "above", "below", "this", "that", "here", "and", "or", "do",
}

# A plan-path or TASKS.md citation that sits in a USAGE EXAMPLE -- a comment
# demonstrating what a command or a row looks like -- is not the same claim
# as one that JUSTIFIES a piece of code ("plans/X.md and migration 016. Do
# not reintroduce."). The verify gate treats `certain` as zero-tolerance, so
# misreading a worked example as rot pushes an agent to "fix" documentation
# that was never broken -- exactly the false alarm that gets a checker
# switched off. Three independent signals, any one of which demotes the
# finding to `suspect` (never silently drops it -- a human still confirms):
#   1. a shell/command snippet sits in the same text (echo, a redirect, a
#      pipe, command substitution, or a leading shell prompt);
#   2. the cited path itself sits inside quote marks in the same text (the
#      shape of a literal string being shown, not a citation being made);
#   3. a `Usage:`/`Example(s):`/`e.g.` marker sits in the same text, OR the
#      comment falls inside the file's own leading usage-block header
#      (`_detect_leading_usage_block`) -- close-tasks.sh's CLI reference
#      documents `reconcile`'s behavior against a specific, real
#      `TASKS.md:62` line, but that whole header is a usage manual, not a
#      justification for a line of code below it.
# A fourth, path-shaped signal: the cited basename is an obvious
# placeholder (`X.md`, `foo.md`, `<slug>.md`, `NNN.md`) rather than a name
# that could plausibly be a real file.
_USAGE_MARKER_RE = re.compile(r"\b(?:usage|examples?)\s*:|e\.g\.", re.IGNORECASE)
# Straight/single quotes AND backticks all count as "showing a literal
# string" for this signal -- backticks are this codebase's own inline-code
# convention (see e.g. check_contracts.py's CITATION_RE), so a path shown
# between backticks reads exactly like one shown between quotes.
_QUOTED_SPAN_RE = re.compile(r'"([^"]*)"|\'([^\']*)\'|`([^`]*)`')
_PLACEHOLDER_PATH_STEM_RE = re.compile(
    r"(?i)^(?:x|foo|bar|baz|xxx+|nnn+|name|slug|topic-slug|example)(?:[-_].*)?$"
)


def _has_shell_snippet_signal(text: str) -> bool:
    if any(tok in text for tok in ("echo ", ">>", "$(")):
        return True
    if re.search(r"(?m)^\s*[#/*-]*\s*\$\s", text):
        return True  # a leading shell-prompt line ("$ some-command")
    return bool(re.search(r"(?<!\|)\|(?!\|)", text))


def _cited_inside_quotes(text: str, start: int, end: int) -> bool:
    for qm in _QUOTED_SPAN_RE.finditer(text):
        if qm.start() <= start and end <= qm.end():
            return True
    return False


def _is_placeholder_path(cited_norm: str) -> bool:
    stem = cited_norm.rsplit("/", 1)[-1].rsplit(".", 1)[0]
    return bool(_PLACEHOLDER_PATH_STEM_RE.match(stem)) or "<" in cited_norm


def _looks_like_usage_example(text: str, start: int, end: int, cited_norm: str) -> bool:
    """True when the citation at `text[start:end]` reads as part of a
    worked example rather than a real, justifying pointer."""
    if _has_shell_snippet_signal(text):
        return True
    if _cited_inside_quotes(text, start, end):
        return True
    if _USAGE_MARKER_RE.search(text):
        return True
    return _is_placeholder_path(cited_norm)


# A shell/JS/etc. file's LEADING comment block (from the top of the file,
# past an optional shebang, to the first non-comment/non-blank line) is
# frequently a CLI usage manual -- multiple `--flag`-shaped subcommand
# signatures, or an explicit `Usage:`/`Example:` marker. Any plan-path/
# TASKS.md citation inside that block documents the tool's own interface,
# never a justification for code that comes after the manual ends.
_FLAG_SIGNATURE_RE = re.compile(r"--[A-Za-z][\w-]*")


def _detect_leading_usage_block(source_text: str) -> int:
    """Return the 1-based line number the leading usage-block header ends
    on, or 0 if the file has none (or it doesn't look like a usage manual)."""
    lines = source_text.splitlines()
    i = 1 if lines and lines[0].startswith("#!") else 0
    block_lines: list[str] = []
    while i < len(lines):
        stripped = lines[i].strip()
        if stripped == "" or any(stripped.startswith(p) for p in _COMMENT_PREFIXES):
            block_lines.append(lines[i])
            i += 1
            continue
        break
    if not block_lines:
        return 0
    joined = "\n".join(block_lines)
    if _USAGE_MARKER_RE.search(joined) or len(_FLAG_SIGNATURE_RE.findall(joined)) >= 2:
        return i  # 1-based: lines 1..i were consumed as the header block
    return 0


_PLACEHOLDER_PATTERNS = (
    re.compile(r"^\s*$"),
    re.compile(r"^_summary_\s*$", re.IGNORECASE),
    re.compile(r"^_description_\s*$", re.IGNORECASE),
    re.compile(r"^TODO[:.]?\s*$", re.IGNORECASE),
    re.compile(r"^Docstring for \w+\.?\s*$", re.IGNORECASE),
    re.compile(r"^\.\.\.\s*$"),
)


def _strip_and_count_content_words(text: str, spans_to_remove: list[tuple[int, int]]) -> int:
    """Remove the matched pointer spans, tokenize what's left on word
    boundaries, drop filler words and pure punctuation/digits, and return
    how many content-bearing words remain."""
    chars = list(text)
    for start, end in spans_to_remove:
        for i in range(start, end):
            if 0 <= i < len(chars):
                chars[i] = " "
    remainder = "".join(chars)
    words = re.findall(r"[A-Za-z]+", remainder)
    content = [w for w in words if w.lower() not in _FILLER_WORDS and len(w) > 1]
    return len(content)


def _path_status(root: Path, rel_path: str) -> str:
    """`tracked` | `missing` | `gitignored` | `untracked-present`."""
    tracked = _git_tracked_files(root)
    if tracked is not None:
        if rel_path in tracked:
            return "tracked"
        if (root / rel_path).is_file():
            if _git_is_ignored(root, rel_path):
                return "gitignored"
            return "untracked-present"
        return "missing"
    # No usable git -- filesystem existence is all we can tell.
    return "untracked-present" if (root / rel_path).is_file() else "missing"


def scan_text_for_pointers(
    text: str, root: Path, rel_file: str, base_line: int, heuristic: bool,
    in_usage_block: bool = False, symbol: str | None = None,
) -> list[Finding]:
    """Scan one comment or docstring body for POINTER findings. `base_line`
    is the 1-based source line the text starts on (findings report the
    line the match itself falls on, computed from `base_line` plus the
    number of newlines before the match). `symbol` is carried onto each
    Finding unchanged -- callers scanning a symbol's own docstring (as
    opposed to a bare comment or the module docstring, neither of which has
    one) pass their qualified name so a plan/ticket pointer living inside a
    function or class docstring is attributable the same way a THIN or
    PLACEHOLDER finding on that symbol already is."""
    findings: list[Finding] = []
    spans: list[tuple[int, int]] = []
    plan_hits: list[tuple[int, int, str]] = []  # start, end, cited path
    backtick_spans = [m.span(1) for m in re.finditer(r"`([^`]+)`", text)]

    def _in_backticks(start: int, end: int) -> bool:
        return any(bs <= start and end <= be for bs, be in backtick_spans)

    for m in _PATH_WITH_SLASH_RE.finditer(text):
        cited = m.group(0)
        if _looks_like_joined_filenames(cited):
            continue  # "CLAUDE.md/AGENTS.md" -- two names, not a path
        spans.append(m.span())
        plan_hits.append((*m.span(), cited))
    for m in _BARE_TASKS_RE.finditer(text):
        # Require a nearby row/line number -- otherwise this is prose
        # naming the file, not a stale pointer to one of its rows.
        window = text[m.end(): m.end() + 20]
        if not _TASKS_ROW_NEARBY_RE.search(window):
            continue
        spans.append(m.span())
        plan_hits.append((*m.span(), m.group(0)))

    phase_step_hits = list(_PHASE_STEP_RE.finditer(text))
    for m in phase_step_hits:
        spans.append(m.span())

    ticket_hits = list(_JIRA_TICKET_RE.finditer(text)) + list(_GH_ISSUE_RE.finditer(text))
    for m in ticket_hits:
        spans.append(m.span())

    if not plan_hits and not phase_step_hits and not ticket_hits:
        return findings

    remaining_content = _strip_and_count_content_words(text, spans)
    pointer_only = remaining_content == 0

    def line_of(offset: int) -> int:
        return base_line + text.count("\n", 0, offset)

    for start, end, cited in plan_hits:
        # Strip only a genuine "./" relative-path prefix -- NOT a bare
        # leading "." on its own, which would mangle a dotdir path like
        # `.claude/project.json` into the different, nonexistent
        # `claude/project.json`.
        cited_norm = cited[2:] if cited.startswith("./") else cited
        is_plan_like = bool(_PLAN_SEGMENT_RE.search(cited_norm)) or cited_norm.lower() == "tasks.md" \
            or cited_norm.lower().endswith("/tasks.md")
        status = _path_status(root, cited_norm)
        if is_plan_like:
            example = in_usage_block or _looks_like_usage_example(text, start, end, cited_norm)
            if example:
                findings.append(Finding(
                    path=rel_file, line=line_of(start), kind="POINTER", severity="suspect",
                    message=f"cites plan path `{cited_norm}` ({status}) inside what reads as a "
                            "usage example, not a justification for code -- confirm before acting",
                    pointer_only=pointer_only, heuristic=heuristic, symbol=symbol,
                ))
            else:
                findings.append(Finding(
                    path=rel_file, line=line_of(start), kind="POINTER", severity="certain",
                    message=f"cites plan path `{cited_norm}` ({status}) -- plan references rot; "
                            "the reason belongs in the comment itself, not a pointer to it",
                    pointer_only=pointer_only, heuristic=heuristic, symbol=symbol,
                ))
        elif status in ("missing", "gitignored") and _in_backticks(start, end) \
                and cited_norm.startswith(_TOOLKIT_TOPLEVEL_DIRS):
            # Backtick-gated: a deliberate citation (this repo's own
            # convention, mirrored from check_contracts.py's CITATION_RE)
            # rather than a bare filename mentioned in passing prose --
            # otherwise nearly any sentence naming a file by name becomes a
            # false "dangling reference".
            findings.append(Finding(
                path=rel_file, line=line_of(start), kind="POINTER", severity="certain",
                message=f"cites `{cited_norm}`, which is {status} -- a dangling reference",
                pointer_only=pointer_only, heuristic=heuristic, symbol=symbol,
            ))
        # else: tracked/untracked-present and not plan-like -- a durable
        # pointer (an ADR, a doc), left alone per the pointer policy. A
        # bare (non-backtick) mention of a missing/gitignored non-plan path
        # is also left alone -- too weak a signal outside a real citation.

    if not plan_hits:
        for m in phase_step_hits:
            findings.append(Finding(
                path=rel_file, line=line_of(m.start()), kind="POINTER", severity="suspect",
                message=f"bare plan numbering `{m.group(0)}` with no cited path -- "
                        "may be legitimate prose (a protocol's own steps); confirm before acting",
                pointer_only=pointer_only, heuristic=heuristic, symbol=symbol,
            ))
        if pointer_only:
            for m in ticket_hits:
                findings.append(Finding(
                    path=rel_file, line=line_of(m.start()), kind="POINTER", severity="suspect",
                    message=f"comment is only a ticket reference (`{m.group(0)}`) -- "
                            "confirm whether the reason should be inlined",
                    pointer_only=True, heuristic=heuristic, symbol=symbol,
                ))

    return findings


def scan_text_for_placeholder(
    text: str, rel_file: str, line: int, symbol: str, runtime_visible: bool,
) -> Finding | None:
    for pat in _PLACEHOLDER_PATTERNS:
        if pat.match(text.strip("\n")):
            return Finding(
                path=rel_file, line=line, kind="PLACEHOLDER", severity="certain",
                symbol=symbol, runtime_visible=runtime_visible,
                message=f"placeholder docstring on `{symbol}` (matches "
                        f"{pat.pattern!r})",
            )
    return None


# ── Non-Python generic comment-prefix heuristic ─────────────────────────────

_COMMENT_PREFIXES = ("#", "//", "*", "/*", "--")


def scan_nonpython_file(path: Path, root: Path) -> tuple[list[Finding], str | None]:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        return [], f"unreadable: {exc}"
    rel = _relposix(root, path)
    findings: list[Finding] = []
    usage_block_end = _detect_leading_usage_block(text)
    for lineno, line in enumerate(text.splitlines(), start=1):
        stripped = line.strip()
        if not any(stripped.startswith(p) for p in _COMMENT_PREFIXES):
            continue
        findings.extend(scan_text_for_pointers(
            stripped, root, rel, lineno, heuristic=True,
            in_usage_block=lineno <= usage_block_end,
        ))
    return findings, None


def _relposix(root: Path, path: Path) -> str:
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return path.as_posix()


# ── Python extraction: params, decorators, return/stub shape ───────────────

_ROUTE_DECORATOR_ATTRS = {
    "get", "post", "put", "delete", "patch", "route", "websocket",
    "on_event", "api_route", "head", "options",
}
_CLI_DECORATOR_ATTRS = {"command"}


def _decorator_attr(dec: ast.expr) -> str | None:
    node = dec.func if isinstance(dec, ast.Call) else dec
    if isinstance(node, ast.Attribute):
        return node.attr
    if isinstance(node, ast.Name):
        return node.id
    return None


def _is_runtime_visible_decorators(decorators: list[ast.expr]) -> bool:
    for dec in decorators:
        attr = _decorator_attr(dec)
        if attr in _ROUTE_DECORATOR_ATTRS or attr in _CLI_DECORATOR_ATTRS:
            return True
    return False


def _params_of(node: ast.AST) -> list[str]:
    if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
        return []
    args = node.args
    names = [a.arg for a in args.posonlyargs] if hasattr(args, "posonlyargs") else []
    names += [a.arg for a in args.args]
    names = [n for n in names if n not in ("self", "cls")]
    names += [a.arg for a in args.kwonlyargs]
    if args.vararg:
        names.append(args.vararg.arg)
    if args.kwarg:
        names.append(args.kwarg.arg)
    return names


def _is_stub_body(node: ast.AST) -> bool:
    """A body that is only a docstring, `pass`, `...`, or a bare
    `raise NotImplementedError(...)` -- the "hasn't been written yet"
    shape, where Returns-drift would flag honesty, not staleness."""
    if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
        return False
    body = node.body
    if body and isinstance(body[0], ast.Expr) and isinstance(
        getattr(body[0], "value", None), ast.Constant
    ) and isinstance(body[0].value.value, str):
        body = body[1:]
    if not body:
        return True
    for stmt in body:
        if isinstance(stmt, ast.Pass):
            continue
        if isinstance(stmt, ast.Expr) and isinstance(stmt.value, ast.Constant) and stmt.value.value is Ellipsis:
            continue
        if isinstance(stmt, ast.Raise) and isinstance(stmt.exc, ast.Call) and \
                isinstance(stmt.exc.func, ast.Name) and stmt.exc.func.id == "NotImplementedError":
            continue
        if isinstance(stmt, ast.Raise) and isinstance(stmt.exc, ast.Name) and stmt.exc.id == "NotImplementedError":
            continue
        return False
    return True


def _returns_value(node: ast.AST) -> tuple[bool, bool]:
    """(returns_a_value, is_generator) -- walks the body but never descends
    into a NESTED def/lambda, since an inner function's `return` is not
    this symbol's contract."""
    if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
        return False, False
    returns_value = False
    is_generator = False

    def visit(n: ast.AST) -> None:
        nonlocal returns_value, is_generator
        if isinstance(n, ast.Return) and n.value is not None:
            returns_value = True
        if isinstance(n, (ast.Yield, ast.YieldFrom)):
            is_generator = True
        for child in ast.iter_child_nodes(n):
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda, ast.ClassDef)):
                continue  # a nested scope's return/yield is not THIS symbol's contract
            visit(child)

    for stmt in node.body:
        visit(stmt)
    return returns_value, is_generator


def _has_doctest(doc: str) -> bool:
    return any(line.strip().startswith(">>>") for line in doc.splitlines())


def _module_has_description_doc(tree: ast.Module) -> bool:
    """`argparse.ArgumentParser(description=__doc__)` (or an attribute
    ending in `__doc__`) makes the MODULE docstring a printed --help
    string."""
    for node in ast.walk(tree):
        if isinstance(node, ast.keyword) and node.arg == "description":
            v = node.value
            if isinstance(v, ast.Attribute) and v.attr == "__doc__":
                return True
            if isinstance(v, ast.Name) and v.id == "__doc__":
                return True
    return False


# ── Docstring section parsing: Google / NumPy / Sphinx only, else skip ─────


@dataclass
class DocSections:
    style: str
    params: set[str]
    has_returns: bool


_GOOGLE_SECTION_RE = re.compile(r"^(Args|Arguments|Returns|Yields|Raises|Attributes)\s*:\s*$")
_GOOGLE_PARAM_RE = re.compile(r"^\s+\*{0,2}([A-Za-z_][A-Za-z0-9_]*)\s*(?:\(.*?\))?\s*:")

_NUMPY_UNDERLINE_RE = re.compile(r"^-{3,}\s*$")
_NUMPY_PARAM_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*(?::.*)?$")
_NUMPY_SECTION_NAMES = ("Parameters", "Returns", "Yields", "Raises", "Attributes", "Other Parameters")

_SPHINX_PARAM_RE = re.compile(r"^\s*:param\s+(?:\S+\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*:", re.MULTILINE)
_SPHINX_RETURNS_RE = re.compile(r"^\s*:returns?:", re.MULTILINE)


def _parse_google(doc: str) -> DocSections | None:
    lines = doc.splitlines()
    section = None
    params: set[str] = set()
    has_returns = False
    found_recognized_section = False
    for line in lines:
        stripped = line.strip()
        header_m = _GOOGLE_SECTION_RE.match(stripped)
        if header_m:
            section = header_m.group(1)
            found_recognized_section = True
            if section == "Returns":
                has_returns = True
            continue
        if section in ("Args", "Arguments") and line.strip():
            pm = _GOOGLE_PARAM_RE.match(line)
            if pm:
                params.add(pm.group(1))
        elif section and line and not line.startswith((" ", "\t")):
            section = None  # dedent ends the section
    if not found_recognized_section:
        return None
    return DocSections(style="google", params=params, has_returns=has_returns)


def _leading_ws(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def _parse_numpy(doc: str) -> DocSections | None:
    lines = doc.splitlines()
    params: set[str] = set()
    has_returns = False
    found = False
    i = 0
    while i < len(lines):
        stripped = lines[i].strip()
        if stripped in _NUMPY_SECTION_NAMES and \
                i + 1 < len(lines) and _NUMPY_UNDERLINE_RE.match(lines[i + 1].strip()):
            found = True
            header = stripped
            if header == "Returns":
                has_returns = True
            i += 2
            if header == "Parameters":
                # A param declaration line ("name : type") sits at the
                # block's base indentation; a MORE indented line is its
                # description (skip); a LESS indented line, a blank line
                # followed by dedent, or the next `Name\n----` header ends
                # the block.
                base_indent: int | None = None
                while i < len(lines):
                    line = lines[i]
                    if not line.strip():
                        i += 1
                        continue
                    if i + 1 < len(lines) and _NUMPY_UNDERLINE_RE.match(lines[i + 1].strip()):
                        break  # the next section's header
                    indent = _leading_ws(line)
                    if base_indent is None:
                        base_indent = indent
                    if indent > base_indent:
                        i += 1
                        continue  # a description continuation line
                    if indent < base_indent:
                        break  # dedented out of the Parameters block
                    pm = _NUMPY_PARAM_RE.match(line.strip())
                    if pm:
                        params.add(pm.group(1))
                    i += 1
            continue
        i += 1
    if not found:
        return None
    return DocSections(style="numpy", params=params, has_returns=has_returns)


def _parse_sphinx(doc: str) -> DocSections | None:
    params = {m.group(1) for m in _SPHINX_PARAM_RE.finditer(doc)}
    has_returns = bool(_SPHINX_RETURNS_RE.search(doc))
    if not params and not has_returns:
        return None
    return DocSections(style="sphinx", params=params, has_returns=has_returns)


def parse_doc_sections(doc: str) -> DocSections | None:
    """Try each recognized convention in turn; an unrecognized style (or a
    plain prose docstring with no Args/Parameters/:param: section at all)
    returns None, and callers must skip THIN param/return checks entirely
    rather than guess."""
    for parser in (_parse_numpy, _parse_sphinx, _parse_google):
        result = parser(doc)
        if result is not None:
            return result
    return None


# ── body-newer: git-blame prior comparing a symbol's body against its own
# docstring -- always `suspect`, since a body edit after its docstring is a
# reason to look closer, not proof the docstring is wrong ──────────────────


def _docstring_line_span(node: ast.AST) -> tuple[int, int] | None:
    body = getattr(node, "body", None)
    if not body:
        return None
    first = body[0]
    if isinstance(first, ast.Expr) and isinstance(
        getattr(first, "value", None), ast.Constant
    ) and isinstance(first.value.value, str):
        return first.lineno, getattr(first, "end_lineno", first.lineno)
    return None


def check_body_newer(
    node: ast.AST, qualified: str, rel_file: str,
    blame_map: dict[int, tuple[str, int]],
) -> Finding | None:
    doc_span = _docstring_line_span(node)
    if doc_span is None:
        return None  # no docstring -- nothing to compare
    end_lineno = getattr(node, "end_lineno", None)
    if end_lineno is None:
        return None
    doc_lines = set(range(doc_span[0], doc_span[1] + 1))
    body_lines = set(range(node.lineno, end_lineno + 1)) - doc_lines
    if not body_lines:
        return None  # e.g. a one-line stub that is only its own docstring

    def _newest(lines: set[int]) -> tuple[str, int] | None:
        candidates = [blame_map[ln] for ln in lines if ln in blame_map]
        if not candidates:
            return None
        return max(candidates, key=lambda pair: pair[1])

    body_newest = _newest(body_lines)
    doc_newest = _newest(doc_lines)
    if body_newest is None or doc_newest is None:
        return None
    if body_newest[1] <= doc_newest[1]:
        return None
    return Finding(
        path=rel_file, line=doc_span[0], kind="BODY_NEWER", severity="suspect",
        symbol=qualified,
        message=f"body last touched {_short_sha_date(*body_newest)}, docstring "
                f"last touched {_short_sha_date(*doc_newest)} -- body changed "
                "after its docstring",
    )


# ── dangling-ref: a docstring's backticked identifier or Sphinx xref role
# that resolves to nothing anywhere in the scanned code -- a sibling of the
# existing path-based POINTER check, for identifiers instead of paths.
#
# Two independent gates keep this from flagging ordinary prose: (1) a
# CODE-SHAPE gate on backticks only (a Sphinx role is a deliberate citation
# by construction, so it always counts) -- a plain lowercase word someone
# merely emphasized with backticks ('checks', 'hooks', 'one') never even
# reaches resolution; (2) once shape-gated, a RESOLUTION UNIVERSE wide
# enough that a real name almost never misses: every identifier written
# ANYWHERE in the scanned Python files (not just def/class names -- also
# parameter names, attribute/method names, keyword-argument names, and
# import aliases) plus every string constant (so a JSON/dict key cited as
# a name resolves) plus stdlib module names. What survives both gates is
# a name nobody in the scanned code ever wrote down at all. ───────────────

# Anchored between the surrounding backticks (or Sphinx role backticks) with
# nothing else allowed in the span -- a multi-word phrase, a path with a
# slash, or a bare "..."/ellipsis never matches at all, regardless of the
# code-shape gate below.
_BACKTICK_IDENT_RE = re.compile(
    r"`([A-Za-z_][\w]*(?:\.[A-Za-z_]\w*)*)(\(\))?`"
)
_SPHINX_XREF_RE = re.compile(
    r":(?:func|class|meth|attr):`([A-Za-z_][\w]*(?:\.[A-Za-z_]\w*)*)(\(\))?`"
)
# A dotted name whose final segment is a recognized file extension reads as a
# filename (`TASKS.md`, `project.json`) even though it is identifier-shaped --
# the existing path-based POINTER check already owns that citation, so this
# check leaves it alone rather than reporting the same name as dangling.
_FILE_EXTENSION_TAILS = {"md", "py", "json", "yml", "yaml", "txt", "sh", "js", "ts", "cfg", "ini", "toml"}


def _looks_like_filename(name: str) -> bool:
    if "." not in name:
        return False
    return name.rsplit(".", 1)[-1].lower() in _FILE_EXTENSION_TAILS


def _looks_like_code_shape(name: str, had_call_parens: bool) -> bool:
    """A backticked token is worth checking only if it reads as code, not
    prose: a call (trailing '()'), a dotted or underscored name, or a
    CamelCase/UPPER_CASE identifier. A single plain lowercase word ('one',
    'path', 'hooks') never passes this gate, so it is never even resolved
    -- backticks used purely for emphasis are left alone by construction,
    not by guessing whether the word happens to name something real."""
    if had_call_parens:
        return True
    if "_" in name or "." in name:
        return True
    return any(c.isupper() for c in name)  # CamelCase or UPPER_CASE


def _find_doc_references(doc: str) -> list[tuple[str, bool, bool, int, int]]:
    """Return (name, had_call_parens, is_sphinx_role, start, end) for every
    backticked identifier or Sphinx cross-reference role in a docstring. A
    Sphinx role's own backticks would also match the generic backtick
    pattern; its span is recorded once, from the role match, not twice."""
    refs: list[tuple[str, bool, bool, int, int]] = []
    consumed: list[tuple[int, int]] = []
    for m in _SPHINX_XREF_RE.finditer(doc):
        refs.append((m.group(1), bool(m.group(2)), True, m.start(), m.end()))
        consumed.append(m.span())
    for m in _BACKTICK_IDENT_RE.finditer(doc):
        span = m.span()
        if any(cs <= span[0] and span[1] <= ce for cs, ce in consumed):
            continue
        refs.append((m.group(1), bool(m.group(2)), False, span[0], span[1]))
    return refs


# A dunder of this shape (`__init__`, `__enter__`, `__repr__`, ...) is a
# Python DATA-MODEL name -- part of the language itself, not something any
# particular repo defines or imports, so citing one is never a reference to
# repo code that can go stale. Resolved unconditionally, before checking
# whether anyone in the scanned files happened to write it down.
_DUNDER_DATA_MODEL_RE = re.compile(r"^__[a-z][a-z0-9_]*__$")


def _resolve_reference(
    name: str, own_params: set[str], identifiers: set[str],
    string_constants: set[str], builtins_set: set[str], stdlib_modules: set[str],
) -> bool:
    """A dotted name resolves through its LAST component only -- the
    universe below is names, not qualified paths, so a two-part dotted
    citation ('SomeClass.some_method') is checked the same way a bare one
    would be."""
    tail = name.rsplit(".", 1)[-1]
    for candidate in {name, tail}:
        if _DUNDER_DATA_MODEL_RE.match(candidate):
            return True
        if candidate in own_params or candidate in identifiers \
                or candidate in string_constants or candidate in builtins_set \
                or candidate in stdlib_modules:
            return True
    return False


def check_dangling_refs(
    doc: str, base_line: int, symbol: str, rel_file: str, own_params: set[str],
    identifiers: set[str], string_constants: set[str], builtins_set: set[str],
    stdlib_modules: set[str],
) -> list[Finding]:
    findings: list[Finding] = []
    for name, had_parens, is_role, start, _end in _find_doc_references(doc):
        if _looks_like_filename(name):
            continue
        if not is_role and not _looks_like_code_shape(name, had_parens):
            continue  # backticked prose emphasis, not a code citation
        if _resolve_reference(name, own_params, identifiers, string_constants, builtins_set, stdlib_modules):
            continue
        line = base_line + doc.count("\n", 0, start)
        findings.append(Finding(
            path=rel_file, line=line, kind="POINTER", severity="suspect",
            symbol=symbol,
            message=f"cites `{name}`, which resolves to no name written "
                    "anywhere in the scanned code -- a dangling reference; "
                    "confirm before treating it as stale",
        ))
    return findings


# ── Symbol-level checks (PLACEHOLDER, THIN, MISSING) ────────────────────────


def check_symbol(
    node: ast.AST, qualified: str, rel_file: str, decorators: list[ast.expr],
    identifiers: set[str], string_constants: set[str], builtins_set: set[str],
    stdlib_modules: set[str], blame_map: dict[int, tuple[str, int]] | None,
    root: Path,
) -> list[Finding]:
    findings: list[Finding] = []
    doc = ast.get_docstring(node, clean=False)
    runtime_visible = _is_runtime_visible_decorators(decorators) or (doc is not None and _has_doctest(doc))
    doc_line = node.lineno
    if doc is not None:
        # ast.get_docstring's node has no direct line for the string itself
        # in all Python versions worth chasing here; the def/class line is
        # close enough for a human to find it, same tradeoff docstring_audit
        # makes for `missing` entries.
        placeholder = scan_text_for_placeholder(doc, rel_file, doc_line, qualified, runtime_visible)
        if placeholder:
            findings.append(placeholder)
            return findings  # a placeholder has nothing else worth checking

        # A function/class/method docstring is scanned for the same
        # plan-path/TASKS.md/ticket POINTER rot a bare comment or the
        # module docstring already is -- previously only those two were
        # scanned, so a stale pointer living inside a SYMBOL's own
        # docstring (the most common place to write one) was invisible to
        # `--verify-docs-only`'s drift detection entirely. Distinct text
        # from both the module docstring and every comment token, so this
        # can never double-report a POINTER finding already produced by
        # either of those.
        findings.extend(scan_text_for_pointers(
            doc, root, rel_file, doc_line, heuristic=False, symbol=qualified,
        ))

        sections = parse_doc_sections(doc)
        if sections is not None:
            actual_params = {p.lstrip("*") for p in _params_of(node)}
            documented = {p.lstrip("*") for p in sections.params}
            if documented and actual_params != documented and documented - actual_params:
                extra = sorted(documented - actual_params)
                findings.append(Finding(
                    path=rel_file, line=doc_line, kind="THIN", severity="certain",
                    symbol=qualified, runtime_visible=runtime_visible,
                    message=f"documents param(s) {extra} not in the signature "
                            f"(signature has {sorted(actual_params) or ['(none)']})",
                ))
            elif documented and actual_params - documented:
                missing_docs = sorted(actual_params - documented)
                findings.append(Finding(
                    path=rel_file, line=doc_line, kind="THIN", severity="certain",
                    symbol=qualified, runtime_visible=runtime_visible,
                    message=f"signature param(s) {missing_docs} are not documented "
                            f"in the {sections.style} Args/Parameters section",
                ))
            if sections.has_returns and isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                returns_value, is_generator = _returns_value(node)
                if not returns_value and not is_generator and not _is_stub_body(node):
                    findings.append(Finding(
                        path=rel_file, line=doc_line, kind="THIN", severity="certain",
                        symbol=qualified, runtime_visible=runtime_visible,
                        message="documents a Returns section but the body never "
                                "returns a value",
                    ))
        own_params = {p.lstrip("*") for p in _params_of(node)}
        findings.extend(check_dangling_refs(
            doc, doc_line, qualified, rel_file, own_params,
            identifiers, string_constants, builtins_set, stdlib_modules,
        ))
        if blame_map is not None:
            bn = check_body_newer(node, qualified, rel_file, blame_map)
            if bn is not None:
                findings.append(bn)
    else:
        if not _is_private(getattr(node, "name", "")):
            findings.append(Finding(
                path=rel_file, line=getattr(node, "lineno", 0), kind="MISSING",
                severity="certain", symbol=qualified, runtime_visible=runtime_visible,
                message=f"public symbol `{qualified}` has no docstring (report-only)",
            ))
    return findings


# ── Python file orchestration ────────────────────────────────────────────────


def check_python_file(
    path: Path, root: Path, include_tests: bool, pointers_only: bool,
    identifiers: set[str] | None = None, string_constants: set[str] | None = None,
    builtins_set: set[str] | None = None, stdlib_modules: set[str] | None = None,
) -> tuple[list[Finding], str | None]:
    identifiers = identifiers if identifiers is not None else set()
    string_constants = string_constants if string_constants is not None else set()
    builtins_set = builtins_set if builtins_set is not None else set(dir(builtins))
    stdlib_modules = stdlib_modules if stdlib_modules is not None else _stdlib_module_names()

    try:
        source = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        return [], f"unreadable: {exc}"

    try:
        tree = ast.parse(source)
    except SyntaxError as exc:
        return [], f"syntax error line {exc.lineno}: {exc.msg}"

    rel = _relposix(root, path)
    findings: list[Finding] = []
    is_test = _is_test_file(path)

    # Pointer scan runs over EVERY comment (tokenize) regardless of
    # --include-tests: a rotted plan pointer in a test file is just as
    # rotted as one in application code, so gating it behind a flag would
    # quietly hide half the rot. Only the OTHER checks below (PLACEHOLDER,
    # THIN, MISSING) skip test files unless --include-tests is passed.
    try:
        for tok in tokenize.generate_tokens(io.StringIO(source).readline):
            if tok.type == tokenize.COMMENT:
                findings.extend(
                    scan_text_for_pointers(tok.string, root, rel, tok.start[0], heuristic=False)
                )
    except (tokenize.TokenizeError, IndentationError, SyntaxError):
        pass  # a comment-scan failure is not fatal; the AST already parsed

    module_doc = ast.get_docstring(tree, clean=False)
    if module_doc is not None:
        findings.extend(
            scan_text_for_pointers(module_doc, root, rel, 1, heuristic=False)
        )
        findings.extend(check_dangling_refs(
            module_doc, 1, "<module>", rel, set(),
            identifiers, string_constants, builtins_set, stdlib_modules,
        ))

    if pointers_only:
        return findings, None

    if is_test and not include_tests:
        return findings, None

    if module_doc is not None:
        runtime_visible = _module_has_description_doc(tree) or _has_doctest(module_doc)
        placeholder = scan_text_for_placeholder(module_doc, rel, 1, "<module>", runtime_visible)
        if placeholder:
            findings.append(placeholder)

    blame_map = _blame_map(root, rel)

    for node, qualified in _walk_symbols(tree):
        decorators = list(getattr(node, "decorator_list", []))
        findings.extend(check_symbol(
            node, qualified, rel, decorators,
            identifiers, string_constants, builtins_set, stdlib_modules, blame_map,
            root,
        ))

    return findings, None


# ── Scan driver ──────────────────────────────────────────────────────────────


def _stdlib_module_names() -> set[str]:
    # 3.10+ ships this directly; an older interpreter degrades to an empty
    # set (stdlib-module names simply stop resolving there) rather than a
    # crash -- the same graceful-degradation posture as the git helpers.
    return set(getattr(sys, "stdlib_module_names", ()))


def _build_global_identifier_index(files: list[Path]) -> tuple[set[str], set[str]]:
    """Returns (identifiers, string_constants): every identifier-shaped
    name and every string constant appearing ANYWHERE in the scanned
    Python files' ASTs -- the resolution universe for dangling-ref. This is
    deliberately much wider than "is a def/class name": a parameter name,
    an attribute/method name (`.rglob`), a keyword-argument name, an
    import alias, or a JSON/dict key are all things a docstring can
    legitimately cite, and each was written down somewhere in real code if
    it is real. Best-effort: a file that fails to parse here simply
    contributes nothing to the index; it still gets its own parse-error
    finding from the main scan below."""
    identifiers: set[str] = set()
    strings: set[str] = set()
    for path in files:
        if path.suffix != ".py":
            continue
        try:
            source = path.read_text(encoding="utf-8", errors="replace")
            tree = ast.parse(source)
        except (OSError, SyntaxError):
            continue
        for node in ast.walk(tree):
            if isinstance(node, ast.Name):
                identifiers.add(node.id)
            elif isinstance(node, ast.Attribute):
                identifiers.add(node.attr)
            elif isinstance(node, ast.arg):
                identifiers.add(node.arg)
            elif isinstance(node, ast.keyword) and node.arg:
                identifiers.add(node.arg)
            elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                identifiers.add(node.name)
            elif isinstance(node, ast.alias):
                identifiers.add(node.name)
                identifiers.add(node.name.split(".")[0])
                if node.asname:
                    identifiers.add(node.asname)
            elif isinstance(node, ast.Constant) and isinstance(node.value, str):
                strings.add(node.value)
    return identifiers, strings


def scan_paths(
    files: list[Path], root: Path, include_tests: bool, pointers_only: bool,
    index_files: list[Path] | None = None,
) -> ScanResult:
    # The dangling-ref resolution universe (`_build_global_identifier_index`)
    # is built from `index_files` when the caller supplies a wider set than
    # `files` -- otherwise a name defined only in a file that `--limit`,
    # `--changed`, or an explicit positional path left OUT of this report
    # would be flagged as dangling just because it wasn't in the scan, not
    # because it doesn't exist. Defaults to `files` so an existing caller
    # that passes one closed set keeps its old behavior unchanged.
    identifiers, string_constants = _build_global_identifier_index(
        index_files if index_files is not None else files
    )
    builtins_set = set(dir(builtins))
    stdlib_modules = _stdlib_module_names()
    result = ScanResult()
    for path in files:
        result.files_scanned += 1
        if path.suffix == ".py":
            findings, error = check_python_file(
                path, root, include_tests, pointers_only,
                identifiers, string_constants, builtins_set, stdlib_modules,
            )
        else:
            findings, error = scan_nonpython_file(path, root)
        if error:
            result.parse_errors.append((_relposix(root, path), error))
            continue
        result.findings.extend(findings)
    return result


# ── Snapshot / --verify-docs-only (the AST-docs-only safety guard) ─────────


def _ast_dump_without_docstrings(tree: ast.AST) -> str:
    """Strip the leading docstring Expr from every module/class/def, then
    dump the AST. Two files whose stripped dumps match differ ONLY in their
    docstrings (comments are never in the AST to begin with)."""
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
            body = node.body
            if body and isinstance(body[0], ast.Expr) and isinstance(
                getattr(body[0], "value", None), ast.Constant
            ) and isinstance(body[0].value.value, str):
                node.body = body[1:] or [ast.Pass()]
    return ast.dump(tree, annotate_fields=True, include_attributes=False)


# Per-extension comment syntax for `_code_line_signature`, the function that
# backs the `--verify-docs-only` SAFETY GUARD. This is deliberately a
# DIFFERENT, narrower table than `_COMMENT_PREFIXES` (used only by the
# pointer-rot heuristic, where missing a comment just skips a weak check):
# here, calling a line "comment-only" when it is actually code is the one
# mistake this function must never make, since it is what tells a caller a
# change was "docs only". A blind, language-blind prefix list flags a C
# `#define`/`#include`, a pointer-deref `*p = 0;`, a pre-decrement `--i;`, a
# Rust `#[attr]`, a JS/TS `#private` field, or a YAML `---` document marker
# as "just a comment" purely because the line happens to start with a
# character some OTHER language uses for comments.
#
# Fail-safe default: an extension not in this table gets NO entry in either
# map below, so `has_block` is False and `line_comment` is None -- every
# non-blank line counts as code, never as a comment it can discard.
_LINE_COMMENT_BY_EXT: dict[str, str] = {
    # C-family and other `//`-comment languages.
    ".js": "//", ".ts": "//", ".jsx": "//", ".tsx": "//",
    ".go": "//", ".rs": "//", ".java": "//",
    ".c": "//", ".cc": "//", ".cpp": "//", ".h": "//", ".hpp": "//",
    # `#`-comment languages -- NOT the C-family above, where `#` is
    # preprocessor/attribute/private-field syntax, not a comment.
    ".sh": "#", ".yml": "#", ".yaml": "#", ".toml": "#", ".rb": "#",
    # `--`-comment languages this heuristic does not currently discover
    # (not in `_HEURISTIC_TEXT_EXTS`), listed for completeness rather than
    # silently mis-scanned if ever added there.
    ".sql": "--", ".lua": "--", ".hs": "--",
}
# `/* ... */` block comments: only the languages above that actually support
# them. `#`-comment and `--`-comment languages are never checked for a block
# form here -- in YAML/TOML/shell/SQL/Lua, `/*`  is just ordinary text, not
# comment syntax, so treating it as one would be its own false-safe bug.
_BLOCK_COMMENT_EXTS = {
    ".js", ".ts", ".jsx", ".tsx", ".go", ".rs", ".java",
    ".c", ".cc", ".cpp", ".h", ".hpp",
}

# Extensions whose language has a backtick template-literal / raw-string
# form that can itself span multiple lines and legitimately contain a
# `//`- or `#`-prefixed line as DATA, not a comment.
_BACKTICK_STRING_EXTS = {".js", ".ts", ".jsx", ".tsx", ".go"}

_YAML_BLOCK_SCALAR_RE = re.compile(r":\s*[|>][+-]?\s*(#.*)?$")
_SHELL_HEREDOC_RE = re.compile(r"<<-?~?\s*['\"]?[A-Za-z_][A-Za-z0-9_]*")


def _has_multiline_construct(text: str, ext: str) -> bool:
    """True when `text` contains a language construct for `ext` that can
    span multiple lines and carry a line that merely LOOKS like a comment
    (a `//`/`#`-prefixed line inside a JS/TS/Go backtick template literal
    or Go raw string, a Python-style triple-quoted block even in a
    non-Python file, a YAML `|`/`>` block scalar, or a shell `<<` heredoc).

    `_code_line_signature`'s per-line comment stripping has no notion of
    "currently inside one of these" -- unlike its `/* */` block-comment
    tracking, which IS stateful -- so it cannot tell a data line inside one
    of these constructs from a real comment. `--verify-docs-only`'s
    contract is fail-safe (never call real code a comment), so detecting
    one of these here means the caller falls back to comparing the whole
    file verbatim instead of trusting the per-line strip."""
    if ext in _BACKTICK_STRING_EXTS and "`" in text:
        return True
    if "'''" in text or '"""' in text:
        return True
    if ext in (".yml", ".yaml"):
        for line in text.splitlines():
            if _YAML_BLOCK_SCALAR_RE.search(line):
                return True
    if ext == ".sh":
        for line in text.splitlines():
            if _SHELL_HEREDOC_RE.search(line):
                return True
    return False


def _code_line_signature(text: str, ext: str = "") -> str:
    """Non-Python fallback for the docs-only guard: every line that is not
    blank and not a recognized COMMENT line for `ext`'s own comment syntax,
    joined -- a change here means real code changed, not just a comment or
    docstring.

    `ext` picks the comment syntax from `_LINE_COMMENT_BY_EXT` /
    `_BLOCK_COMMENT_EXTS`; an unrecognized (or empty) `ext` strips nothing,
    per the fail-safe default documented on those tables. A `/* */` block
    comment's own state is tracked ACROSS lines, so a ` * `-prefixed
    continuation line is only ever treated as a comment while an open block
    is actually in progress -- never on its own, which is what let a bare
    `*p = 0;` pointer-deref line get swallowed under the old blind-prefix
    heuristic.

    When `_has_multiline_construct` finds a multi-line string/heredoc/block
    construct this function cannot track the state of, comment stripping is
    skipped entirely and the full text comes back verbatim -- every line
    counts as code, which is the fail-safe direction to be wrong in.
    """
    if _has_multiline_construct(text, ext):
        return text
    line_comment = _LINE_COMMENT_BY_EXT.get(ext)
    has_block = ext in _BLOCK_COMMENT_EXTS
    lines: list[str] = []
    in_block = False
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if has_block:
            if in_block:
                end = stripped.find("*/")
                if end == -1:
                    continue  # still inside the open block comment
                in_block = False
                stripped = stripped[end + 2:].strip()
                if not stripped:
                    continue
            if stripped.startswith("/*"):
                close = stripped.find("*/", 2)
                if close == -1:
                    in_block = True
                    continue
                stripped = stripped[close + 2:].strip()
                if not stripped:
                    continue
        if line_comment and stripped.startswith(line_comment):
            continue
        lines.append(stripped)
    return "\n".join(lines)


def build_snapshot(files: list[Path], root: Path) -> dict[str, dict]:
    snapshot: dict[str, dict] = {}
    for path in files:
        rel = _relposix(root, path)
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if path.suffix == ".py":
            try:
                tree = ast.parse(text)
            except SyntaxError:
                continue
            snapshot[rel] = {"kind": "python", "dump": _ast_dump_without_docstrings(tree)}
        else:
            ext = path.suffix.lower()
            snapshot[rel] = {
                "kind": "text",
                "code_lines": _code_line_signature(text, ext),
                "verbatim": _has_multiline_construct(text, ext),
            }
    return snapshot


def verify_docs_only(snapshot_path: Path, root: Path) -> tuple[list[str], list[str]]:
    """Returns (violations, notes) -- violations empty == clean. A file
    present in the snapshot but now missing, or whose non-docstring content
    changed, is a violation. `notes` carries one informational line per
    non-Python file that was (or still is) compared verbatim because of a
    multi-line string/heredoc construct `_code_line_signature` cannot track
    -- surfaced regardless of whether that file is also a violation, since
    "this file got the weaker, whole-file comparison" is worth knowing on a
    clean run too."""
    data = json.loads(snapshot_path.read_text(encoding="utf-8", errors="replace"))
    violations: list[str] = []
    notes: list[str] = []
    for rel, before in data.items():
        path = root / rel
        if not path.is_file():
            violations.append(f"{rel}: present at snapshot time, missing now")
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            violations.append(f"{rel}: unreadable now ({exc})")
            continue
        if before["kind"] == "python":
            try:
                tree = ast.parse(text)
            except SyntaxError as exc:
                violations.append(f"{rel}: fails to parse now (line {exc.lineno}: {exc.msg})")
                continue
            after_dump = _ast_dump_without_docstrings(tree)
            if after_dump != before["dump"]:
                violations.append(f"{rel}: non-docstring code changed (AST mismatch)")
        else:
            ext = Path(rel).suffix.lower()
            if before.get("verbatim") or _has_multiline_construct(text, ext):
                notes.append(
                    f"{rel}: compared verbatim (multi-line string/heredoc construct detected)"
                )
            after_lines = _code_line_signature(text, ext)
            if after_lines != before["code_lines"]:
                violations.append(f"{rel}: a non-comment line changed (heuristic)")
    return violations, notes


# ── Claims / verdicts: carrying judgment (a probability-scoring judge or an
# LLM triage agent) back into this script's Finding vocabulary. The script
# owns the action table -- a judge picks a verdict, code decides what that
# means ─────────────────────────────────────────────────────────────────

# On `.` followed by whitespace or end-of-string, per the plain-heuristic
# contract -- no NLP dependency, just enough to keep one sentence per claim.
_SENTENCE_SPLIT_RE = re.compile(r"\.(?:\s+|\Z)")

_CLAIM_SOURCE_LIMIT = 200


def _split_sentences(text: str) -> list[str]:
    text = text.strip()
    if not text:
        return []
    return [s.strip() for s in _SENTENCE_SPLIT_RE.split(text) if s.strip()]


def _strip_doc_section_noise(doc: str) -> str:
    """Drop structural markup (a Google/NumPy section header, a NumPy
    underline, a Sphinx `:param x:`/`:returns:` field marker) from a
    docstring, keeping the prose -- including param/return descriptions --
    for sentence splitting. Reuses the same header/underline regexes the
    THIN check parses sections with, rather than re-deriving new ones."""
    out: list[str] = []
    for line in doc.splitlines():
        stripped = line.strip()
        if _GOOGLE_SECTION_RE.match(stripped):
            continue
        if stripped in _NUMPY_SECTION_NAMES:
            continue
        if _NUMPY_UNDERLINE_RE.match(stripped):
            continue
        sphinx_field = re.match(r"^\s*:(?:param|returns?|raises?|type)\s*(?:[\w.]+\s+)?[\w.]*\s*:\s*", line)
        if sphinx_field:
            out.append(line[sphinx_field.end():])
            continue
        out.append(line)
    return "\n".join(out)


def _extract_claim_sentences(doc: str) -> list[str]:
    return _split_sentences(_strip_doc_section_noise(doc))


def _iter_claim_symbols(
    files: list[Path], root: Path,
) -> list[tuple[str, str, ast.AST, list[ast.expr], str, list[str]]]:
    """Yield (rel_path, qualified, node, decorators, doc, source_lines) for
    every symbol with a non-empty docstring across every scanned Python
    file. `source_lines` is the whole file's text split on newlines, so a
    caller can slice out one symbol's own source (with its decorators)
    without re-reading the file."""
    out: list[tuple[str, str, ast.AST, list[ast.expr], str, list[str]]] = []
    for path in files:
        if path.suffix != ".py":
            continue
        try:
            source = path.read_text(encoding="utf-8", errors="replace")
            tree = ast.parse(source)
        except (OSError, SyntaxError):
            continue
        rel = _relposix(root, path)
        source_lines = source.splitlines()
        for node, qualified in _walk_symbols(tree):
            doc = ast.get_docstring(node, clean=False)
            if doc is None or not doc.strip():
                continue
            decorators = list(getattr(node, "decorator_list", []))
            out.append((rel, qualified, node, decorators, doc, source_lines))
    return out


def build_claim_records(
    result: ScanResult, files: list[Path], root: Path, include_all: bool,
) -> tuple[list[dict], list[dict], list[tuple[str, str]]]:
    """Returns (records, oversized, dup_errors). Each record carries the
    on-disk id/claim/evidence triple plus the path/line/symbol a matching
    verdict later needs to build a Finding -- --claims-out writes only the
    first three keys; --verdicts-in uses all of them.

    A claim id is `<rel-path>::<qualified-symbol>::<sentence-index>` --
    path-prefixed, since a bare qualified name (e.g. a top-level `main`) is
    only unique within one file's own AST, not across every scanned file.
    `dup_errors` is populated (never silently overwritten, never a
    last-wins) if the same id is ever produced twice anyway -- normally
    only reachable by scanning the same path more than once (overlapping
    positional paths)."""
    candidate_keys: set[tuple[str, str]] | None = None
    if not include_all:
        candidate_keys = {
            (f.path, f.symbol) for f in result.findings
            if f.kind != "MISSING" and f.symbol
        }
    records: list[dict] = []
    oversized: list[dict] = []
    dup_errors: list[tuple[str, str]] = []
    seen_ids: set[str] = set()
    for rel, qualified, node, decorators, doc, source_lines in _iter_claim_symbols(files, root):
        if candidate_keys is not None and (rel, qualified) not in candidate_keys:
            continue
        start_line = decorators[0].lineno if decorators else node.lineno
        end_line = getattr(node, "end_lineno", node.lineno)
        segment_lines = source_lines[start_line - 1:end_line]
        is_oversized = len(segment_lines) > _CLAIM_SOURCE_LIMIT
        if is_oversized:
            oversized.append({
                "symbol": qualified, "path": rel, "line": node.lineno,
                "body_lines": len(segment_lines),
            })
            # Still produce a claim record per sentence, under the same id
            # scheme, WITHOUT inlining the oversized body as evidence -- an
            # oversized symbol must still be triage-able and its id must
            # still resolve in --verdicts-in (SKILL.md's Step 4 supplies the
            # full source out of band, from the `oversized` list above).
            # apply_verdicts has no evidence to check a quote against here,
            # so an oversized STALE verdict is never `certain`, only
            # `suspect` -- that's the correct, conservative outcome, not a
            # bug: nothing here can verify the quote itself.
            evidence: list[str] = []
        else:
            evidence = [ "\n".join(segment_lines) ]
        for idx, sentence in enumerate(_extract_claim_sentences(doc)):
            claim_id = f"{rel}::{qualified}::{idx}"
            if claim_id in seen_ids:
                dup_errors.append((
                    claim_id,
                    "duplicate claim id produced by --claims-out -- the same "
                    "path was scanned more than once",
                ))
                continue
            seen_ids.add(claim_id)
            record = {
                "id": claim_id,
                "claim": f"`{qualified}`: {sentence}",
                "evidence": evidence,
                "path": rel,
                "line": node.lineno,
                "symbol": qualified,
            }
            if is_oversized:
                record["oversized"] = True
            records.append(record)
    return records, oversized, dup_errors


_PROB_KEYS = ("supported", "overgeneralized", "contradicted")


def _resolve_verdict(entry: object, evidence: list[str]) -> tuple[str | None, str | None]:
    """(verdict, internal_band) per the action table -- auto-detects which
    of the two accepted verdicts-in shapes `entry` is."""
    if not isinstance(entry, dict):
        return None, None
    if all(isinstance(entry.get(k), (int, float)) for k in _PROB_KEYS) \
            and isinstance(entry.get("band"), str):
        band = entry["band"]
        if band == "corroborated":
            return "supported", "act"
        if band in ("contradicted", "overgeneralized"):
            return band, "act"
        if band == "uncertain":
            return None, "uncertain"
        return None, None  # "error", or an unrecognized band value
    if "verdict" in entry:
        verdict = entry.get("verdict")
        if verdict == "not-addressed":
            return None, None
        if verdict == "supported":
            return "supported", None
        if verdict in ("contradicted", "overgeneralized"):
            quote = entry.get("quote")
            found = False
            if isinstance(quote, str) and quote.strip():
                norm_quote = re.sub(r"\s+", " ", quote).strip()
                norm_evidence = re.sub(r"\s+", " ", " ".join(evidence)).strip()
                found = norm_quote in norm_evidence
            return verdict, ("act" if found else "uncertain")
        return None, None
    return None, None


def apply_verdicts(
    verdicts_path: Path, claim_records: dict[str, dict],
) -> tuple[list[Finding], list[tuple[str, str]]]:
    findings: list[Finding] = []
    errors: list[tuple[str, str]] = []
    try:
        data = json.loads(verdicts_path.read_text(encoding="utf-8", errors="replace"))
    except (OSError, json.JSONDecodeError) as exc:
        errors.append((str(verdicts_path), f"malformed verdicts file: {exc}"))
        return findings, errors
    if not isinstance(data, dict):
        errors.append((str(verdicts_path), "verdicts file must be a JSON object keyed by claim id"))
        return findings, errors
    for claim_id, entry in data.items():
        record = claim_records.get(claim_id)
        if record is None:
            errors.append((claim_id, "id does not resolve to a claim in the current scan"))
            continue
        verdict, internal_band = _resolve_verdict(entry, record["evidence"])
        if verdict is None or verdict == "supported":
            continue  # no signal, or nothing to act on -- never bloat findings
        severity = "certain" if internal_band == "act" else "suspect"
        message = f"{record['claim']} -- verdict={verdict}"
        quote = entry.get("quote") if isinstance(entry, dict) else None
        if quote:
            message += f", quote: {quote!r}"
        findings.append(Finding(
            path=record["path"], line=record["line"], kind="STALE", severity=severity,
            symbol=record["symbol"], message=message,
        ))
    return findings, errors


# ── Reporting ────────────────────────────────────────────────────────────────


def print_report(
    result: ScanResult, as_json: bool, claims_out_path: str | None = None,
    claims_written: int | None = None, oversized: list[dict] | None = None,
) -> int:
    if as_json:
        payload = {
            "files_scanned": result.files_scanned,
            "findings": [asdict(f) for f in result.findings],
            "parse_errors": [{"path": p, "error": e} for p, e in result.parse_errors],
        }
        if claims_written is not None:
            payload["oversized"] = oversized or []
            payload["claims_written"] = claims_written
        print(json.dumps(payload, indent=2))
    else:
        by_kind: dict[str, list[Finding]] = {}
        for f in result.findings:
            by_kind.setdefault(f.kind, []).append(f)
        for kind in ("POINTER", "PLACEHOLDER", "THIN", "MISSING", "BODY_NEWER", "STALE"):
            items = by_kind.get(kind, [])
            if not items:
                continue
            print(f"\n{kind}: {len(items)} finding(s)")
            for f in items:
                loc = f"{f.path}:{f.line}"
                sym = f" {f.symbol}" if f.symbol else ""
                tags = f"[{f.severity}]"
                if f.pointer_only:
                    tags += "[pointer-only]"
                if f.runtime_visible:
                    tags += "[runtime-visible]"
                if f.heuristic:
                    tags += "[heuristic]"
                print(f"  {loc}{sym} {tags} {f.message}")
        if result.parse_errors:
            print(f"\nPARSE ERRORS: {len(result.parse_errors)}")
            for p, e in result.parse_errors:
                print(f"  {p}: {e}")
        total = len(result.findings)
        print(f"\n{total} finding(s) across {result.files_scanned} file(s)")
        if claims_written is not None:
            oversized = oversized or []
            names = ", ".join(o["symbol"] for o in oversized)
            suffix = f": {names}" if names else ""
            print(f"\n{claims_written} claim(s) written to {claims_out_path}; "
                  f"{len(oversized)} symbol(s) skipped (oversized, >{_CLAIM_SOURCE_LIMIT} "
                  f"lines){suffix}")

    if result.parse_errors or result.files_scanned == 0:
        return 2
    return 1 if result.findings else 0


# ── --self-test ──────────────────────────────────────────────────────────────


def _write(base: Path, rel: str, content: str, newline: str = "\n") -> Path:
    p = base / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    # Write raw bytes so a CRLF fixture is actually CRLF on disk regardless
    # of platform line-ending translation.
    p.write_bytes(content.replace("\n", newline).encode("utf-8"))
    return p


def _self_test_body_newer() -> bool:
    """A real git repo (never this repo's own git state) with a positive --
    docstring committed first, body edited in a later commit -- and a
    negative control where both land in the same commit. Skips gracefully,
    never failing the self-test, if git itself is unavailable."""
    git = shutil.which("git")
    if git is None:
        print("docstring_check.py --self-test: git unavailable, skipping body-newer checks",
              file=sys.stderr)
        return True

    tmp = Path(tempfile.mkdtemp(prefix="docstring_check_selftest_git_"))
    ok = True
    try:
        def run(args: list[str]) -> None:
            subprocess.run(
                [git, *args], cwd=str(tmp), check=True, capture_output=True,
                encoding="utf-8", errors="replace",
            )

        def commit(message: str, date: str) -> None:
            # Two automated commits can otherwise land in the same wall-clock
            # second, which collapses "newer" into a tie -- an explicit,
            # distinct --date per commit (this is the AUTHOR date, the one
            # `git blame`'s author-time reports) is what makes the
            # comparison deterministic rather than a coin flip.
            run(["-c", "user.name=Docstring Sync Self-Test", "-c",
                 "user.email=selftest@example.invalid",
                 "commit", "-q", "-m", message, "--date", date])

        run(["init", "-q"])

        _write(tmp, "body_newer_positive.py", '''\
def widget():
    """Compute the widget value."""
    return 1
''')
        run(["add", "body_newer_positive.py"])
        commit("add widget with its docstring", "2025-01-01T00:00:00")

        _write(tmp, "body_newer_negative.py", '''\
def gadget():
    """Compute the gadget value."""
    return 1
''')
        run(["add", "body_newer_negative.py"])
        commit("add gadget (docstring and body in the same commit)", "2025-01-02T00:00:00")

        # A second, later commit touches ONLY widget's body -- its docstring
        # line is untouched since the first commit.
        _write(tmp, "body_newer_positive.py", '''\
def widget():
    """Compute the widget value."""
    return 2
''')
        run(["add", "body_newer_positive.py"])
        commit("change widget's body only", "2025-06-01T00:00:00")

        result = scan_paths(
            [tmp / "body_newer_positive.py", tmp / "body_newer_negative.py"],
            tmp, include_tests=True, pointers_only=False,
        )
        by_path_kind: dict[tuple[str, str], list[Finding]] = {}
        for f in result.findings:
            by_path_kind.setdefault((f.path, f.kind), []).append(f)

        if not by_path_kind.get(("body_newer_positive.py", "BODY_NEWER")):
            print("SELF-TEST FAIL: expected a BODY_NEWER finding for body_newer_positive.py, "
                  f"got {result.findings}", file=sys.stderr)
            ok = False
        elif by_path_kind[("body_newer_positive.py", "BODY_NEWER")][0].severity != "suspect":
            print("SELF-TEST FAIL: BODY_NEWER must always be severity=suspect", file=sys.stderr)
            ok = False

        if by_path_kind.get(("body_newer_negative.py", "BODY_NEWER")):
            print("SELF-TEST FAIL: expected NO BODY_NEWER finding for body_newer_negative.py "
                  f"(same-commit edit), got {by_path_kind[('body_newer_negative.py', 'BODY_NEWER')]}",
                  file=sys.stderr)
            ok = False
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return ok


def _self_test_fixtures_discovery() -> bool:
    """Both halves of the `fixtures`-segment discovery exclusion: (1) a
    planted pointer under a `fixtures` directory segment must NOT surface
    when discovery is given an ancestor path that does not itself name
    `fixtures` (mirrors `docstring_check.py .` on this very repo); (2) the
    same planted pointer MUST surface when the fixtures-bearing path (or a
    path under it) is named explicitly as a positional argument. Exercised
    against `discover()` directly, not `scan_paths()`, since the exclusion
    lives in file selection, not in any check."""
    ok = True
    tmp = Path(tempfile.mkdtemp(prefix="docstring_check_selftest_fixtures_"))
    try:
        planted = _write(tmp, "evals/skills/fixtures/sample/pointer_in_fixture.py", '''\
def f():
    # plans/HIDDEN_PLAN.md -- do not reintroduce here either.
    return 1
''')
        _write(tmp, "real_source.py", '''\
def g():
    return 1
''')

        # (1) An ancestor path that does NOT itself name `fixtures` (the repo
        # root, "."-shaped) must exclude the planted file entirely.
        found_via_root = discover([str(tmp)], tmp, changed=False)
        if planted in found_via_root:
            print("SELF-TEST FAIL: a path under a `fixtures` segment was discovered "
                  "via an ancestor that did not name it explicitly", file=sys.stderr)
            ok = False
        if not any(f.name == "real_source.py" for f in found_via_root):
            print("SELF-TEST FAIL: ordinary source outside `fixtures` went missing "
                  "from discovery too", file=sys.stderr)
            ok = False

        # (1b) The same exclusion applies with no positional paths at all --
        # discover() falls back to a filesystem walk in this non-git tmp tree.
        found_via_walk = discover(None, tmp, changed=False)
        if planted in found_via_walk:
            print("SELF-TEST FAIL: the no-positional-args fallback walk did not "
                  "exclude a `fixtures`-segment path", file=sys.stderr)
            ok = False

        # (2) Naming the fixtures directory itself explicitly is an honored ask.
        found_via_dir = discover(
            [str(tmp / "evals" / "skills" / "fixtures" / "sample")], tmp, changed=False
        )
        if planted not in found_via_dir:
            print("SELF-TEST FAIL: explicitly naming a `fixtures` directory did not "
                  "surface the file under it", file=sys.stderr)
            ok = False

        # (2b) Naming the planted FILE itself (not just its parent dir) too.
        found_via_file = discover([str(planted)], tmp, changed=False)
        if planted not in found_via_file:
            print("SELF-TEST FAIL: explicitly naming a `fixtures`-segment FILE did not "
                  "surface it", file=sys.stderr)
            ok = False
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return ok


def _self_test_nongit_fallback_root_ancestor() -> bool:
    """The non-git fallback walk (no positional paths, no usable git) must
    exclude on a path RELATIVE to `root`, not on `root`'s own absolute path
    -- otherwise every real file is excluded the moment `root` itself sits
    under a directory that happens to share a name with `_has_fixtures_segment`
    or `_DEFAULT_EXCLUDES` (a scan run from inside a `fixtures/` tree, or a
    repo checked out under a directory literally named `venv`), even though
    none of that name appears in any path relative to `root`."""
    ok = True
    tmp = Path(tempfile.mkdtemp(prefix="docstring_check_selftest_rootancestor_"))
    try:
        # `root` itself is nested under a `fixtures` segment -- the file
        # underneath it names no `fixtures` dir relative to `root`.
        fixtures_root = tmp / "fixtures" / "legacy"
        real_under_fixtures = _write(fixtures_root, "real_source.py", '''\
def f():
    """A plain docstring."""
    return 1
''')
        found = discover(None, fixtures_root, changed=False)
        if real_under_fixtures not in found:
            print("SELF-TEST FAIL: the non-git fallback walk excluded a real file just "
                  "because `root` itself sits under a `fixtures` ancestor", file=sys.stderr)
            ok = False

        # `root` itself is nested under a `_DEFAULT_EXCLUDES`-matching name
        # (`venv`) -- same bug, sibling exclusion in the same loop.
        venv_root = tmp / "venv" / "myproject"
        real_under_venv = _write(venv_root, "main.py", '''\
def g():
    """A plain docstring."""
    return 1
''')
        found_venv = discover(None, venv_root, changed=False)
        if real_under_venv not in found_venv:
            print("SELF-TEST FAIL: the non-git fallback walk excluded a real file just "
                  "because `root` itself sits under a `venv` ancestor", file=sys.stderr)
            ok = False

        # Negative control: a file genuinely under a `node_modules` dir
        # RELATIVE TO root must still be excluded -- the fix must not
        # disable real exclusion, only the false one from root's ancestry.
        real_root = tmp / "real_project"
        excluded = _write(real_root, "node_modules/pkg/lib.py", '''\
def h():
    return 1
''')
        kept = _write(real_root, "app.py", '''\
def i():
    return 1
''')
        found_real = discover(None, real_root, changed=False)
        if excluded in found_real:
            print("SELF-TEST FAIL: a real `node_modules`-relative-to-root file was NOT "
                  "excluded after the relative-path fix", file=sys.stderr)
            ok = False
        if kept not in found_real:
            print("SELF-TEST FAIL: an ordinary file went missing from the fixed fallback "
                  "walk", file=sys.stderr)
            ok = False
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return ok


def _self_test_dangling_ref_full_index() -> bool:
    """The dangling-ref definition index must be built from the full
    discoverable file set, independent of the (possibly narrower) set of
    files being reported on -- otherwise `--limit`, `--changed`, or an
    explicit single positional path makes a name defined only in an
    unscanned file look dangling, when it is simply out of report scope."""
    ok = True
    tmp = Path(tempfile.mkdtemp(prefix="docstring_check_selftest_fullindex_"))
    cwd_before = Path.cwd()
    try:
        _write(tmp, "definer.py", '''\
def helper_defined_elsewhere():
    return 1
''')
        _write(tmp, "citer.py", '''\
def uses_it():
    """Delegates to `helper_defined_elsewhere` for the real work."""
    return 1
''')
        os.chdir(tmp)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            main(["citer.py", "--json"])
        payload = json.loads(buf.getvalue())
        dangling = [
            f for f in payload["findings"]
            if f["kind"] == "POINTER" and "helper_defined_elsewhere" in f["message"]
        ]
        if dangling:
            print(f"SELF-TEST FAIL: a name defined only in an unscanned file (definer.py) "
                  f"was flagged as dangling when scanning citer.py alone: {dangling}",
                  file=sys.stderr)
            ok = False
    finally:
        os.chdir(cwd_before)
        shutil.rmtree(tmp, ignore_errors=True)
    return ok


def _self_test_all_flag_warning() -> bool:
    """`--all` widens the candidate scope for BOTH `--claims-out` and
    `--verdicts-in` (build_claim_records' `include_all`), so the CLI's own
    "has no effect" warning must fire only when neither flag is present --
    not on a `--verdicts-in`-only call, which is exactly SKILL.md's Step 4
    shape (`--verdicts-in <file> --all`, no `--claims-out` on that call)."""
    ok = True
    tmp = Path(tempfile.mkdtemp(prefix="docstring_check_selftest_allflag_"))
    cwd_before = Path.cwd()
    try:
        _write(tmp, "sample.py", '''\
def f():
    """A plain, accurate docstring."""
    return 1
''')
        os.chdir(tmp)

        buf_neither = io.StringIO()
        with contextlib.redirect_stderr(buf_neither), contextlib.redirect_stdout(io.StringIO()):
            main(["sample.py", "--all"])
        if "has no effect" not in buf_neither.getvalue():
            print("SELF-TEST FAIL: --all with neither --claims-out nor --verdicts-in should "
                  "warn, got no warning", file=sys.stderr)
            ok = False

        verdicts_file = tmp / "verdicts.json"
        verdicts_file.write_text("{}", encoding="utf-8")
        buf_verdicts = io.StringIO()
        with contextlib.redirect_stderr(buf_verdicts), contextlib.redirect_stdout(io.StringIO()):
            main(["sample.py", "--all", "--verdicts-in", str(verdicts_file)])
        if "has no effect" in buf_verdicts.getvalue():
            print(f"SELF-TEST FAIL: --all with --verdicts-in (no --claims-out) must not "
                  f"warn, got: {buf_verdicts.getvalue()!r}", file=sys.stderr)
            ok = False
    finally:
        os.chdir(cwd_before)
        shutil.rmtree(tmp, ignore_errors=True)
    return ok


def _self_test_language_aware_code_signature() -> bool:
    """`_code_line_signature` must key its comment syntax off the file's
    OWN extension, not a blind cross-language prefix list -- a C
    `#define`/`#include`, a pointer-deref `*p = 0;`, a pre-decrement
    `--i;`, a Rust `#[attr]`, a JS/TS `#private` field, and a YAML `---`
    document marker must all count as CODE for their own language, so a
    real edit to any of them is CAUGHT by `--verify-docs-only`, never
    waved through as "docs only". A `/* ... */` block comment (including
    a ` * ` continuation line) must still be recognized as a comment, so
    editing only the text inside one stays clean."""
    ok = True
    tmp = Path(tempfile.mkdtemp(prefix="docstring_check_selftest_langaware_"))
    try:
        def assert_caught(rel: str, before: str, after: str, label: str) -> None:
            nonlocal ok
            target = _write(tmp, rel, before)
            snapshot = build_snapshot([target], tmp)
            snap_file = tmp / f"{rel.replace('/', '_')}.snapshot.json"
            snap_file.write_text(json.dumps(snapshot), encoding="utf-8")
            _write(tmp, rel, after)
            violations, _notes = verify_docs_only(snap_file, tmp)
            if not violations:
                print(f"SELF-TEST FAIL: {label} -- a real code edit in {rel} was "
                      "waved through as docs-only", file=sys.stderr)
                ok = False

        def assert_clean(rel: str, before: str, after: str, label: str) -> None:
            nonlocal ok
            target = _write(tmp, rel, before)
            snapshot = build_snapshot([target], tmp)
            snap_file = tmp / f"{rel.replace('/', '_')}.clean.snapshot.json"
            snap_file.write_text(json.dumps(snapshot), encoding="utf-8")
            _write(tmp, rel, after)
            violations, _notes = verify_docs_only(snap_file, tmp)
            if violations:
                print(f"SELF-TEST FAIL: {label} -- a comment/docstring-only edit in "
                      f"{rel} was flagged as code: {violations}", file=sys.stderr)
                ok = False

        # C: a #define line is a preprocessor directive, not a comment --
        # and a bare pointer-deref line must not be swallowed by a blind
        # "*"-prefix match either.
        assert_caught(
            "lang/c_define.c",
            "#define MAX 10\nint f(void) { return MAX; }\n",
            "#define MAX 20\nint f(void) { return MAX; }\n",
            "C #define",
        )
        assert_caught(
            "lang/c_pointer.c",
            "int f(int *p) {\n    /* adjust */\n    *p = 0;\n    return 1;\n}\n",
            "int f(int *p) {\n    /* adjust */\n    *p = 1;\n    return 1;\n}\n",
            "C pointer-deref `*p = 0;`",
        )
        # C: editing only the text INSIDE a /* */ block (including a ` * `
        # continuation line) must still read as docs-only.
        assert_clean(
            "lang/c_block_comment.c",
            "/**\n * Old explanation.\n */\nint f(void) { return 1; }\n",
            "/**\n * New, better explanation.\n */\nint f(void) { return 1; }\n",
            "C /* */ block-comment-only edit",
        )
        # JS/TS: a pre-decrement statement and a `#private` field are both
        # code, not comments, despite starting with "--" / "#".
        assert_caught(
            "lang/js_decrement.js",
            "function tick(i) {\n    --i;\n    return i;\n}\n",
            "function tick(i) {\n    ++i;\n    return i;\n}\n",
            "JS pre-decrement `--i;`",
        )
        assert_caught(
            "lang/js_private.js",
            "class Foo {\n    #secret = 1;\n}\n",
            "class Foo {\n    #secret = 2;\n}\n",
            "JS `#private` field",
        )
        # Rust: a #[attr] line is an attribute, not a comment.
        assert_caught(
            "lang/rust_attr.rs",
            "#[derive(Debug)]\nfn f() -> i32 {\n    1\n}\n",
            "#[derive(Clone)]\nfn f() -> i32 {\n    1\n}\n",
            "Rust `#[attr]`",
        )
        # YAML: a "---" document marker is structural, not a "--" comment.
        assert_caught(
            "lang/yaml_marker.yml",
            "---\nkey: 1\n",
            "----\nkey: 1\n",
            "YAML `---` document marker",
        )
        # Negative control: an ordinary shell "#" comment is still
        # correctly treated as a comment -- the fix must not regress the
        # one case the old blind heuristic got right.
        assert_clean(
            "lang/sh_comment.sh",
            "#!/usr/bin/env bash\n# old comment\necho hi\n",
            "#!/usr/bin/env bash\n# new comment text\necho hi\n",
            "shell comment-only edit",
        )
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return ok


def _self_test_docstring_pointer_scan() -> bool:
    """A plan/ticket pointer living inside a FUNCTION or CLASS docstring
    (not just a bare comment or the module docstring) must be scanned and
    reported the same way, with the same severity/pointer-only rules, and
    must carry that symbol's name -- and must not be double-reported
    alongside the (textually distinct) module-docstring or comment scans."""
    ok = True
    tmp = Path(tempfile.mkdtemp(prefix="docstring_check_selftest_docpointer_"))
    try:
        _write(tmp, "symbol_pointer.py", '''\
"""Module docstring, no pointer here."""


def uses_plan_in_docstring():
    """Mirrors the retry policy in plans/RETRY_POLICY.md -- do not change
    the backoff formula without updating that doc too.
    """
    return 1


def uses_tasks_row_in_docstring():
    """See TASKS.md row 12."""
    return 1


class HasPlanPointer:
    """Implements the design in docs/plans/LEGACY_DESIGN.md exactly."""

    def method(self):
        return 1
''')
        result = scan_paths([tmp / "symbol_pointer.py"], tmp, include_tests=True, pointers_only=False)
        by_symbol: dict[str, list[Finding]] = {}
        for f in result.findings:
            if f.kind == "POINTER":
                by_symbol.setdefault(f.symbol, []).append(f)

        plan_findings = by_symbol.get("uses_plan_in_docstring", [])
        if len(plan_findings) != 1 or plan_findings[0].severity != "certain" \
                or plan_findings[0].pointer_only:
            print(f"SELF-TEST FAIL: expected exactly one certain, non-pointer-only POINTER "
                  f"finding on uses_plan_in_docstring's own docstring, got {plan_findings}",
                  file=sys.stderr)
            ok = False

        tasks_findings = by_symbol.get("uses_tasks_row_in_docstring", [])
        if len(tasks_findings) != 1 or not tasks_findings[0].pointer_only:
            print(f"SELF-TEST FAIL: expected one pointer-only POINTER finding on "
                  f"uses_tasks_row_in_docstring's docstring, got {tasks_findings}",
                  file=sys.stderr)
            ok = False

        class_findings = by_symbol.get("HasPlanPointer", [])
        if len(class_findings) != 1 or class_findings[0].severity != "certain":
            print(f"SELF-TEST FAIL: expected one certain POINTER finding on the CLASS "
                  f"docstring HasPlanPointer, got {class_findings}", file=sys.stderr)
            ok = False

        # No double-reporting: the module docstring carries no pointer, and
        # the three symbol docstrings above must not ALSO surface under
        # symbol=None (which would mean they got counted a second time via
        # the module-doc or comment-token scan paths).
        untagged = by_symbol.get(None, [])
        if untagged:
            print(f"SELF-TEST FAIL: unexpected un-attributed POINTER finding(s), "
                  f"possible double-report: {untagged}", file=sys.stderr)
            ok = False
        total_pointer_findings = sum(len(v) for v in by_symbol.values())
        if total_pointer_findings != 3:
            print(f"SELF-TEST FAIL: expected exactly 3 POINTER findings total (one per "
                  f"symbol docstring), got {total_pointer_findings}: {by_symbol}",
                  file=sys.stderr)
            ok = False
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return ok


def _self_test_changed_from_subdir() -> bool:
    """`--changed` run from a repo SUBDIRECTORY must resolve both tracked
    and untracked paths against `root` (cwd) consistently -- `git diff
    --name-only HEAD` prints paths relative to the repo's TOP LEVEL by
    default while `git ls-files --others` is already cwd-relative; without
    `--relative` on the diff call the two disagree the moment root is a
    subdirectory, doubling the subdirectory segment and producing a path
    that does not exist on disk. Skips gracefully if git is unavailable."""
    git = shutil.which("git")
    if git is None:
        print("docstring_check.py --self-test: git unavailable, skipping "
              "--changed-from-subdir checks", file=sys.stderr)
        return True

    ok = True
    tmp = Path(tempfile.mkdtemp(prefix="docstring_check_selftest_subdir_"))
    cwd_before = Path.cwd()
    try:
        def run(args: list[str]) -> None:
            subprocess.run(
                [git, *args], cwd=str(tmp), check=True, capture_output=True,
                encoding="utf-8", errors="replace",
            )

        run(["init", "-q"])
        run(["-c", "user.name=Docstring Sync Self-Test", "-c",
             "user.email=selftest@example.invalid",
             "commit", "-q", "--allow-empty", "-m", "init"])

        _write(tmp, "pkg/pkg/a.py", "def f():\n    return 1\n")
        run(["add", "pkg/pkg/a.py"])
        run(["-c", "user.name=Docstring Sync Self-Test", "-c",
             "user.email=selftest@example.invalid",
             "commit", "-q", "-m", "add a.py"])

        # A tracked change AND an untracked file, both under the
        # subdirectory the scan will run from.
        _write(tmp, "pkg/pkg/a.py", "def f():\n    return 2\n")
        _write(tmp, "pkg/pkg/b.py", "def g():\n    return 1\n")

        subdir_root = tmp / "pkg"
        os.chdir(subdir_root)
        changed = _git_changed_files(subdir_root)
        if changed is None:
            print("SELF-TEST FAIL: --changed-from-subdir got no usable git output",
                  file=sys.stderr)
            ok = False
        else:
            for rel in changed:
                if not (subdir_root / rel).is_file():
                    print(f"SELF-TEST FAIL: --changed-from-subdir resolved {rel!r} "
                          f"against root {subdir_root} to a path that does not exist "
                          f"on disk", file=sys.stderr)
                    ok = False
            if "pkg/a.py" not in changed:
                print(f"SELF-TEST FAIL: expected the tracked change to resolve as "
                      f"'pkg/a.py' relative to the subdirectory root, got {changed}",
                      file=sys.stderr)
                ok = False
            if "pkg/b.py" not in changed:
                print(f"SELF-TEST FAIL: expected the untracked file to resolve as "
                      f"'pkg/b.py' relative to the subdirectory root, got {changed}",
                      file=sys.stderr)
                ok = False

        found = discover(None, subdir_root, changed=True)
        if not found:
            print("SELF-TEST FAIL: discover(--changed) from a subdirectory found nothing",
                  file=sys.stderr)
            ok = False
        elif not all(f.is_file() for f in found):
            print(f"SELF-TEST FAIL: discover(--changed) from a subdirectory produced "
                  f"unreadable paths: {found}", file=sys.stderr)
            ok = False
    finally:
        os.chdir(cwd_before)
        shutil.rmtree(tmp, ignore_errors=True)
    return ok


def _self_test_dir_walk_excludes_default_patterns() -> bool:
    """A directory passed as a positional PATH is walked with `rglob`,
    which bypasses `_DEFAULT_EXCLUDES`/git on its own -- `discover(["src"],
    ...)` must still drop a nested `node_modules/` the same way
    no-argument discovery would. But naming an excluded directory itself is
    explicit intent: `discover(["node_modules/foo"], ...)` must scan it,
    while a FURTHER excluded directory nested below it is still dropped."""
    ok = True
    tmp = Path(tempfile.mkdtemp(prefix="docstring_check_selftest_dirwalk_"))
    try:
        kept = _write(tmp, "src/app.py", "def f():\n    return 1\n")
        nested_in_named_dir = _write(
            tmp, "src/node_modules/pkg/lib.py", "def g():\n    return 1\n"
        )
        found = discover([str(tmp / "src")], tmp, changed=False)
        if nested_in_named_dir in found:
            print("SELF-TEST FAIL: a directory walk surfaced a nested node_modules/ "
                  "file", file=sys.stderr)
            ok = False
        if kept not in found:
            print("SELF-TEST FAIL: a directory walk dropped an ordinary file "
                  "alongside a nested excluded one", file=sys.stderr)
            ok = False

        explicit_file = _write(tmp, "node_modules/foo/vendor.py", "def h():\n    return 1\n")
        deeper_excluded = _write(
            tmp, "node_modules/foo/node_modules/sub/x.py", "def i():\n    return 1\n"
        )
        found_explicit = discover([str(tmp / "node_modules" / "foo")], tmp, changed=False)
        if explicit_file not in found_explicit:
            print("SELF-TEST FAIL: explicitly naming an excluded directory did not "
                  "scan its own contents", file=sys.stderr)
            ok = False
        if deeper_excluded in found_explicit:
            print("SELF-TEST FAIL: a further excluded directory NESTED below an "
                  "explicitly-named excluded directory was not dropped", file=sys.stderr)
            ok = False
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return ok


def _self_test_deleted_files_excluded() -> bool:
    """A file git still reports -- `ls-files -c` for an uncommitted
    deletion, `git diff --name-only HEAD` for the same -- must never reach
    the scanned file set: it is not a finding, it is nothing to read.
    `--diff-filter=d` keeps a deletion out of the diff listing in the first
    place; the `.is_file()` filter on every discovered path is the second,
    independent backstop (it is what covers `ls-files -c`, which has no
    such filter flag). Skips gracefully if git is unavailable."""
    git = shutil.which("git")
    if git is None:
        print("docstring_check.py --self-test: git unavailable, skipping "
              "deleted-files checks", file=sys.stderr)
        return True

    ok = True
    tmp = Path(tempfile.mkdtemp(prefix="docstring_check_selftest_deleted_"))
    try:
        def run(args: list[str]) -> None:
            subprocess.run(
                [git, *args], cwd=str(tmp), check=True, capture_output=True,
                encoding="utf-8", errors="replace",
            )

        run(["init", "-q"])
        _write(tmp, "present.py", "def f():\n    return 1\n")
        _write(tmp, "gone.py", "def g():\n    return 1\n")
        run(["add", "present.py", "gone.py"])
        run(["-c", "user.name=Docstring Sync Self-Test", "-c",
             "user.email=selftest@example.invalid",
             "commit", "-q", "-m", "init"])

        (tmp / "gone.py").unlink()

        found = discover(None, tmp, changed=False)
        if any(f.name == "gone.py" for f in found):
            print("SELF-TEST FAIL: a deleted-but-still-indexed file was discovered "
                  "via plain `git ls-files`", file=sys.stderr)
            ok = False
        if not any(f.name == "present.py" for f in found):
            print("SELF-TEST FAIL: an ordinary tracked file went missing from "
                  "discovery alongside the deleted one", file=sys.stderr)
            ok = False

        _write(tmp, "new_untracked.py", "def h():\n    return 1\n")
        found_changed = discover(None, tmp, changed=True)
        if any(f.name == "gone.py" for f in found_changed):
            print("SELF-TEST FAIL: a deleted tracked file was discovered via "
                  "`--changed` despite `--diff-filter=d`", file=sys.stderr)
            ok = False
        if not any(f.name == "new_untracked.py" for f in found_changed):
            print("SELF-TEST FAIL: a genuinely new untracked file went missing "
                  "from `--changed` discovery", file=sys.stderr)
            ok = False
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return ok


def _self_test_nonascii_filenames_unquoted() -> bool:
    """A non-ASCII filename (`café.py`) must survive git-backed discovery
    even under the DEFAULT `core.quotepath=true`: without `-z` on every git
    listing call, git quotes it as a literal octal-escaped string
    (`"caf\\303\\251.py"`), which does not end in a real extension and is
    silently dropped by `_scannable`. `-z` disables that quoting outright,
    for both the tracked (`ls-files -co`) and `--changed` (`ls-files
    --others`) paths. Skips gracefully if git is unavailable."""
    git = shutil.which("git")
    if git is None:
        print("docstring_check.py --self-test: git unavailable, skipping "
              "non-ASCII filename checks", file=sys.stderr)
        return True

    ok = True
    tmp = Path(tempfile.mkdtemp(prefix="docstring_check_selftest_nonascii_"))
    try:
        def run(args: list[str]) -> None:
            subprocess.run(
                [git, *args], cwd=str(tmp), check=True, capture_output=True,
                encoding="utf-8", errors="replace",
            )

        run(["init", "-q"])
        run(["config", "core.quotepath", "true"])
        tracked_name = "café.py"
        _write(tmp, tracked_name, "def f():\n    return 1\n")
        run(["add", tracked_name])
        run(["-c", "user.name=Docstring Sync Self-Test", "-c",
             "user.email=selftest@example.invalid",
             "commit", "-q", "-m", "add non-ascii file"])

        untracked_name = "naïve.py"
        _write(tmp, untracked_name, "def g():\n    return 1\n")

        found = discover(None, tmp, changed=False)
        if not any(f.name == tracked_name for f in found):
            print("SELF-TEST FAIL: a committed non-ASCII filename was not "
                  "discovered (quotepath likely swallowed it)", file=sys.stderr)
            ok = False

        found_changed = discover(None, tmp, changed=True)
        if not any(f.name == untracked_name for f in found_changed):
            print("SELF-TEST FAIL: an untracked non-ASCII filename was not "
                  "discovered via --changed (quotepath likely swallowed it)",
                  file=sys.stderr)
            ok = False
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return ok


def _self_test_multiline_construct_verbatim_fallback() -> bool:
    """A `//`-prefixed line that is actually DATA inside a JS/TS/Go backtick
    template literal must not be silently stripped as a comment -- the
    per-line heuristic has no notion of "currently inside a backtick
    string" (unlike its stateful `/* */` tracking), so
    `_has_multiline_construct` detects the backtick and
    `_code_line_signature` falls back to comparing the whole file verbatim
    instead. `verify_docs_only` must also report this in its `notes`."""
    ok = True
    tmp = Path(tempfile.mkdtemp(prefix="docstring_check_selftest_multiline_"))
    try:
        rel = "lang/template_literal.js"
        target = _write(tmp, rel, '''\
const sql = `
// NOTE: old reason
SELECT 1
`;
function f() { return 1; }
''')
        snapshot = build_snapshot([target], tmp)
        snap_file = tmp / "snapshot.json"
        snap_file.write_text(json.dumps(snapshot), encoding="utf-8")

        if not snapshot[rel].get("verbatim"):
            print("SELF-TEST FAIL: a backtick-template-literal file was not "
                  "flagged for verbatim comparison in the snapshot", file=sys.stderr)
            ok = False

        _write(tmp, rel, '''\
const sql = `
// NOTE: new reason -- the query body itself is unchanged
SELECT 1
`;
function f() { return 1; }
''')
        violations, notes = verify_docs_only(snap_file, tmp)
        if not violations:
            print("SELF-TEST FAIL: a real content change inside a backtick "
                  "template literal, on a `//`-prefixed line, was waved through "
                  "as docs-only", file=sys.stderr)
            ok = False
        if not any(rel in n for n in notes):
            print("SELF-TEST FAIL: verify_docs_only did not report the verbatim "
                  "fallback in its notes", file=sys.stderr)
            ok = False
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return ok


def _self_test_paths_and_changed_intersection() -> bool:
    """Positional paths and `--changed` combine as an INTERSECTION --
    `src --changed` must scan only the changed files under `src`, not
    every file under it (which would silently drop the whole point of
    passing `--changed`) and not a changed file OUTSIDE `src` either.
    Skips gracefully if git is unavailable."""
    git = shutil.which("git")
    if git is None:
        print("docstring_check.py --self-test: git unavailable, skipping "
              "paths-and-changed-intersection checks", file=sys.stderr)
        return True

    ok = True
    tmp = Path(tempfile.mkdtemp(prefix="docstring_check_selftest_pathschanged_"))
    try:
        def run(args: list[str]) -> None:
            subprocess.run(
                [git, *args], cwd=str(tmp), check=True, capture_output=True,
                encoding="utf-8", errors="replace",
            )

        run(["init", "-q"])
        _write(tmp, "src/a.py", "def f():\n    return 1\n")
        _write(tmp, "src/b.py", "def g():\n    return 1\n")
        _write(tmp, "other/c.py", "def h():\n    return 1\n")
        run(["add", "src/a.py", "src/b.py", "other/c.py"])
        run(["-c", "user.name=Docstring Sync Self-Test", "-c",
             "user.email=selftest@example.invalid",
             "commit", "-q", "-m", "init"])

        # Only b.py (under src) and c.py (outside src) actually change.
        _write(tmp, "src/b.py", "def g():\n    return 2\n")
        _write(tmp, "other/c.py", "def h():\n    return 2\n")

        found = discover([str(tmp / "src")], tmp, changed=True)
        names = {f.name for f in found}
        if names != {"b.py"}:
            print(f"SELF-TEST FAIL: `src --changed` should scan exactly the "
                  f"changed files under src ({{'b.py'}}), got {names}", file=sys.stderr)
            ok = False
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return ok


def _run_self_test() -> bool:
    import shutil as _shutil

    tmp = Path(tempfile.mkdtemp(prefix="docstring_check_selftest_"))
    ok = True
    try:
        # -- Positive: plan path present, reason text present (not pointer-only)
        _write(tmp, "pointer_plan_present.py", '''\
def f():
    # plans/LAUNCH_REQUIREMENT_PHASES.md -- Do not reintroduce the retry wrapper here.
    return 1
''')
        # -- Positive: plan path cited but the plan file does not exist on
        # disk (proves POINTER fires from the missing/gitignored status
        # alone, independent of whether the cited file still exists).
        _write(tmp, "pointer_plan_absent.py", '''\
def g():
    # docs/plans/GONE_PLAN.md -- never retry more than three times here.
    return 1
''')
        # -- Positive: pointer-only TASKS.md row reference
        _write(tmp, "pointer_tasks_row.py", '''\
def h():
    # see TASKS.md row 12
    return 1
''')
        # -- Positive (demotion, signal: leading Usage: header block): a
        # plan-path citation inside a CLI's own usage manual documents the
        # tool's interface, not a justification for code -- suspect, not
        # certain, per the coordinator's fix (a `certain` example pointer
        # pushed the verify gate to "fix" working documentation).
        _write(tmp, "usage_block_example.sh", '''\
#!/usr/bin/env bash
# Usage:
#   run --plan plans/foo.md --scope resolved
#   run --plan plans/bar.md --scope plan
echo "real code starts here, well past the header"
''')
        # -- Positive (demotion, signals: echo/redirect + quoted path): a
        # worked shell-command EXAMPLE later in the file, not part of any
        # leading header block, still demoted on its own per-line signals.
        _write(tmp, "usage_snippet_example.sh", '''\
#!/usr/bin/env bash
echo "start"
# Example: echo '/sdlc plans/session-note.md' >> .claude/.next-action
''')
        # -- Positive: THIN param drift, Google style
        _write(tmp, "thin_google.py", '''\
def add(a, b):
    """Add two numbers.

    Args:
        a: the first number.
        c: the second number.
    """
    return a + b
''')
        # -- Positive: THIN param drift, NumPy style
        _write(tmp, "thin_numpy.py", '''\
def add(a, b):
    """Add two numbers.

    Parameters
    ----------
    a : int
        the first number.
    c : int
        the second number.
    """
    return a + b
''')
        # -- Positive: THIN param drift, Sphinx style
        _write(tmp, "thin_sphinx.py", '''\
def add(a, b):
    """Add two numbers.

    :param a: the first number.
    :param c: the second number.
    """
    return a + b
''')
        # -- Positive: PLACEHOLDER stub
        _write(tmp, "placeholder_stub.py", '''\
def stub():
    """_summary_"""
    return 1
''')
        # -- Positive: FastAPI route with a placeholder docstring (runtime_visible)
        _write(tmp, "route_placeholder.py", '''\
from fastapi import APIRouter
router = APIRouter()

@router.get("/health")
def health():
    """_summary_"""
    return {"ok": True}
''')
        # -- Positive: doctest + Returns-drift together (runtime_visible via doctest).
        # Body is a real statement (not pass/.../NotImplementedError) so the
        # stub-body exclusion does not swallow the Returns-drift finding.
        _write(tmp, "doctest_thin.py", '''\
def noop():
    """Do nothing useful.

    >>> noop()

    Returns:
        None: always.
    """
    _ = 1
''')
        # -- Negative control: pointer to a TRACKED, non-plan file (an ADR) --
        # left alone entirely.
        _write(tmp, "docs/ADR-0001-example.md", "# ADR 0001\n\nAn accepted decision.\n")
        _write(tmp, "pointer_tracked_adr.py", '''\
def uses_adr():
    # see docs/ADR-0001-example.md for the accepted rationale
    return 1
''')
        # -- Negative control: lowercase "step 3" is legitimate protocol prose
        _write(tmp, "pointer_lowercase_step.py", '''\
def handshake():
    # step 3 of the TLS handshake verifies the certificate chain
    return 1
''')
        # -- Negative control: accurate docstring, no drift
        _write(tmp, "accurate.py", '''\
def add(a, b):
    """Add two numbers.

    Args:
        a: the first number.
        b: the second number.

    Returns:
        The sum of a and b.
    """
    return a + b
''')
        # -- Negative control: NotImplementedError stub with a Returns section
        _write(tmp, "stub_returns.py", '''\
def not_yet(x):
    """Not implemented yet.

    Returns:
        The eventual result.
    """
    raise NotImplementedError
''')
        # -- CRLF handling: same plan-pointer positive, written with CRLF
        _write(tmp, "crlf_pointer.py", '''\
def crlf_case():
    # plans/CRLF_PLAN.md -- Do not remove this guard.
    return 1
''', newline="\r\n")

        # -- dangling-ref cases: one negative control per false-positive
        # class the code-shape gate and the widened resolution universe
        # exist to rule out, plus one true positive.
        _write(tmp, "dangling_ref_cases.py", '''\
import os


def real_helper():
    """A real helper that exists in this module."""
    return 1


def uses_real_symbol():
    """See `real_helper` for details."""
    return real_helper()


def uses_builtin_call():
    """Returns a `sorted()` list of results."""
    return sorted([])


def uses_import():
    """Uses `os` under the hood."""
    return os.getcwd()


def uses_plain_word():
    """This function just returns `one`."""
    return 1


def process(rel_path):
    """Uses `rel_path` to locate the file."""
    return rel_path


def scan_tree(base):
    """Uses `rglob()` under the hood to walk the tree recursively."""
    return list(base.rglob("*.py"))


def build_payload():
    """Returns a dict with a `total_cost_usd` key."""
    return {"total_cost_usd": 0.0}


def uses_dunder():
    """Relies on `__enter__` being defined by the language, not this repo."""
    return 1


def uses_dangling():
    """See `load_confg_v2()` for details."""
    return 1
''')

        # -- claims/verdicts round-trip fixture: a THIN finding makes this a
        # default candidate; two sentences give distinct claim ids.
        _write(tmp, "claims_candidate.py", '''\
def stale_candidate(value):
    """Summary sentence one. Second sentence describes more.

    Args:
        value: the input.
        extra: not in the signature.
    """
    return value
''')

        # -- oversized-source fixture: a THIN finding makes it a candidate
        # too, but its source exceeds the 200-line evidence cap.
        _oversized_body = "\n".join(f"    x{i} = {i}" for i in range(210))
        _write(tmp, "oversized_symbol.py", f'''\
def huge():
    """Do a huge amount of stuff.

    Args:
        missing_param: not in the signature.
    """
{_oversized_body}
    return x0
''')

        # -- id-collision fixture: two different files each define a
        # same-named top-level symbol (`main`) with its own drifted
        # docstring -- the claim id must be path-prefixed so these don't
        # collide, and a verdict against one must never touch the other.
        _write(tmp, "dup_id_pkg_one/mod.py", '''\
def main(value):
    """Entry point one.

    Args:
        value: the input.
        extra: not in the signature.
    """
    return value
''')
        _write(tmp, "dup_id_pkg_two/mod.py", '''\
def main(value):
    """Entry point two.

    Args:
        value: the input.
        extra: not in the signature.
    """
    return value
''')

        # Discover and scan everything under tmp directly (bypassing git
        # discovery entirely -- the self-test tree is not a git repo, which
        # also exercises the "git absent/not-a-repo" degrade-gracefully path).
        scan_files = sorted(tmp.rglob("*.py")) + sorted(tmp.rglob("*.sh"))
        result = scan_paths(scan_files, tmp, include_tests=True, pointers_only=False)

        by_key = {}
        for f in result.findings:
            by_key.setdefault((f.path, f.kind), []).append(f)

        def expect(path: str, kind: str, count: int, **attrs) -> None:
            nonlocal ok
            items = by_key.get((path, kind), [])
            if len(items) != count:
                print(f"SELF-TEST FAIL: expected {count} {kind} finding(s) in {path}, "
                      f"got {len(items)}: {items}", file=sys.stderr)
                ok = False
                return
            for k, v in attrs.items():
                for item in items:
                    if getattr(item, k) != v:
                        print(f"SELF-TEST FAIL: {path} {kind} expected {k}={v!r}, "
                              f"got {getattr(item, k)!r}", file=sys.stderr)
                        ok = False

        def expect_none(path: str, kind: str) -> None:
            nonlocal ok
            items = by_key.get((path, kind), [])
            if items:
                print(f"SELF-TEST FAIL: expected NO {kind} finding in {path}, got {items}",
                      file=sys.stderr)
                ok = False

        expect("pointer_plan_present.py", "POINTER", 1, severity="certain", pointer_only=False)
        expect("pointer_plan_absent.py", "POINTER", 1, severity="certain")
        expect("pointer_tasks_row.py", "POINTER", 1, severity="certain", pointer_only=True)
        expect("thin_google.py", "THIN", 1)
        expect("thin_numpy.py", "THIN", 1)
        expect("thin_sphinx.py", "THIN", 1)
        expect("placeholder_stub.py", "PLACEHOLDER", 1, runtime_visible=False)
        expect("route_placeholder.py", "PLACEHOLDER", 1, runtime_visible=True)
        expect("doctest_thin.py", "THIN", 1, runtime_visible=True)
        expect("crlf_pointer.py", "POINTER", 1, severity="certain")
        # Demotion: both usage-example shapes come back `suspect`, never
        # `certain` -- the fix this self-test guards against a regression of.
        expect("usage_block_example.sh", "POINTER", 2, severity="suspect")
        expect("usage_snippet_example.sh", "POINTER", 1, severity="suspect")

        expect_none("pointer_tracked_adr.py", "POINTER")
        expect_none("pointer_lowercase_step.py", "POINTER")
        expect_none("accurate.py", "THIN")
        expect_none("stub_returns.py", "THIN")

        # -- dangling-ref: exactly one POINTER finding in this file (the
        # nonexistent `load_confg_v2()`) -- if any of the eight negative
        # controls above (plain word, same-file symbol, a called builtin,
        # an imported module, a function's own param, a stdlib-style
        # method call, a dict/JSON string key, or a language-level dunder)
        # also fired, the count would be higher than 1.
        expect("dangling_ref_cases.py", "POINTER", 1, severity="suspect")

        # -- --snapshot / --verify-docs-only: a planted CODE edit must be
        # caught, and a docstring-only edit must pass.
        verify_target = _write(tmp, "verify_target.py", '''\
def calc(x):
    """Calculate something.

    Args:
        x: the input.
    """
    return x + 1
''')
        snapshot = build_snapshot([verify_target], tmp)
        snap_file = tmp / "snapshot.json"
        snap_file.write_text(json.dumps(snapshot), encoding="utf-8")

        # Docstring-only edit -- must PASS.
        _write(tmp, "verify_target.py", '''\
def calc(x):
    """Calculate something else entirely.

    Args:
        x: the input value.
    """
    return x + 1
''')
        violations, _notes = verify_docs_only(snap_file, tmp)
        if violations:
            print(f"SELF-TEST FAIL: docstring-only edit was flagged: {violations}", file=sys.stderr)
            ok = False

        # Code edit -- must be CAUGHT.
        _write(tmp, "verify_target.py", '''\
def calc(x):
    """Calculate something else entirely.

    Args:
        x: the input value.
    """
    return x + 2
''')
        violations, _notes = verify_docs_only(snap_file, tmp)
        if not violations:
            print("SELF-TEST FAIL: a planted code edit was NOT caught by --verify-docs-only",
                  file=sys.stderr)
            ok = False

        # -- Undecodable bytes must not crash the scan.
        bad = tmp / "undecodable.py"
        bad.write_bytes(b"def f():\n    # \xff\xfe garbage\n    return 1\n")
        findings, error = check_python_file(bad, tmp, include_tests=True, pointers_only=False)
        if error is not None:
            print(f"SELF-TEST FAIL: undecodable file raised a parse error: {error}", file=sys.stderr)
            ok = False

        # -- claims/verdicts round trip.
        records_default, oversized_default, dup_errors_default = build_claim_records(
            result, scan_files, tmp, include_all=False)
        records_all, oversized_all, dup_errors_all = build_claim_records(
            result, scan_files, tmp, include_all=True)
        if dup_errors_default or dup_errors_all:
            print(f"SELF-TEST FAIL: unexpected duplicate claim ids from a normal scan: "
                  f"{dup_errors_default + dup_errors_all}", file=sys.stderr)
            ok = False

        bare = [{"id": r["id"], "claim": r["claim"], "evidence": r["evidence"]} for r in records_default]
        if not isinstance(bare, list) or any(set(c.keys()) != {"id", "claim", "evidence"} for c in bare):
            print("SELF-TEST FAIL: --claims-out shape is not a bare id/claim/evidence array",
                  file=sys.stderr)
            ok = False
        claims_out_file = tmp / "claims.json"
        claims_out_file.write_text(json.dumps(bare), encoding="utf-8")
        reloaded = json.loads(claims_out_file.read_text(encoding="utf-8"))
        if not isinstance(reloaded, list) or any(
            set(c.keys()) != {"id", "claim", "evidence"} for c in reloaded
        ):
            print("SELF-TEST FAIL: claims file on disk is not a bare id/claim/evidence array",
                  file=sys.stderr)
            ok = False

        if not len(records_all) > len(records_default):
            print(f"SELF-TEST FAIL: --all ({len(records_all)}) did not produce a superset of "
                  f"the default candidates ({len(records_default)})", file=sys.stderr)
            ok = False

        oversized_syms_default = {o["symbol"] for o in oversized_default}
        if "huge" not in oversized_syms_default:
            print(f"SELF-TEST FAIL: expected 'huge' in oversized, got {oversized_default}",
                  file=sys.stderr)
            ok = False
        # An oversized symbol must still get claim records under the same id
        # scheme (so a verdict against it can resolve), but with no inlined
        # body -- it is listed in `oversized`, not silently dropped from
        # `records` entirely.
        huge_records = [r for r in records_default if r["symbol"] == "huge"]
        if not huge_records:
            print("SELF-TEST FAIL: an oversized symbol produced no claim records/ids at all -- "
                  "a verdict targeting it would have nowhere to resolve", file=sys.stderr)
            ok = False
        else:
            if not all(r.get("oversized") is True for r in huge_records):
                print(f"SELF-TEST FAIL: an oversized symbol's claim records are missing the "
                      f"oversized marker: {huge_records}", file=sys.stderr)
                ok = False
            if any(r["evidence"] for r in huge_records):
                print(f"SELF-TEST FAIL: an oversized symbol's claim record inlined its body "
                      f"into evidence: {huge_records}", file=sys.stderr)
                ok = False
            huge_id = huge_records[0]["id"]
            by_id_huge = {r["id"]: r for r in records_default}
            huge_verdict_file = tmp / "huge_verdict.json"
            huge_verdict_file.write_text(
                json.dumps({huge_id: {"verdict": "contradicted", "quote": "n/a"}}),
                encoding="utf-8")
            huge_findings, huge_errors = apply_verdicts(huge_verdict_file, by_id_huge)
            if huge_errors:
                print(f"SELF-TEST FAIL: a verdict against an oversized symbol's id did not "
                      f"resolve: {huge_errors}", file=sys.stderr)
                ok = False
            if not huge_findings or huge_findings[0].symbol != "huge":
                print(f"SELF-TEST FAIL: an accepted oversized-symbol verdict did not produce "
                      f"a STALE finding: {huge_findings}", file=sys.stderr)
                ok = False
            elif huge_findings[0].severity != "suspect":
                print("SELF-TEST FAIL: an oversized symbol has no evidence to verify a quote "
                      f"against, so its STALE finding must be `suspect`, got "
                      f"{huge_findings[0].severity}", file=sys.stderr)
                ok = False

        # -- id collision: two files each define `main` -- ids must be
        # path-prefixed and distinct, and a verdict targeting only one
        # file's id must not produce a finding for the other file's `main`.
        main_one = [r for r in records_default if r["path"] == "dup_id_pkg_one/mod.py" and r["symbol"] == "main"]
        main_two = [r for r in records_default if r["path"] == "dup_id_pkg_two/mod.py" and r["symbol"] == "main"]
        if not main_one or not main_two:
            print("SELF-TEST FAIL: expected both dup_id_pkg_one/two `main` symbols as candidates",
                  file=sys.stderr)
            ok = False
        else:
            ids_one = {r["id"] for r in main_one}
            ids_two = {r["id"] for r in main_two}
            if ids_one & ids_two:
                print(f"SELF-TEST FAIL: claim ids collided across files: {ids_one & ids_two}",
                      file=sys.stderr)
                ok = False
            expected_prefix_one = "dup_id_pkg_one/mod.py::main::"
            expected_prefix_two = "dup_id_pkg_two/mod.py::main::"
            if not all(i.startswith(expected_prefix_one) for i in ids_one) or \
                    not all(i.startswith(expected_prefix_two) for i in ids_two):
                print(f"SELF-TEST FAIL: claim ids are not path-prefixed as expected: "
                      f"{ids_one}, {ids_two}", file=sys.stderr)
                ok = False
            else:
                by_id_dup = {r["id"]: r for r in records_default}
                one_id = sorted(ids_one)[0]
                dup_verdicts = {one_id: {"verdict": "contradicted", "quote": "value"}}
                dup_file = tmp / "dup_verdicts.json"
                dup_file.write_text(json.dumps(dup_verdicts), encoding="utf-8")
                dup_findings, dup_finding_errors = apply_verdicts(dup_file, by_id_dup)
                if dup_finding_errors:
                    print(f"SELF-TEST FAIL: unexpected verdict errors: {dup_finding_errors}",
                          file=sys.stderr)
                    ok = False
                paths_touched = {f.path for f in dup_findings}
                if paths_touched != {"dup_id_pkg_one/mod.py"}:
                    print(f"SELF-TEST FAIL: a verdict against pkg_one's `main` id touched "
                          f"unexpected file(s): {paths_touched}", file=sys.stderr)
                    ok = False

        # -- forced duplicate: scanning the same file twice must be caught
        # as a loud error (parse_errors), never a silent last-wins overwrite.
        forced_records, _forced_oversized, forced_dup_errors = build_claim_records(
            result, [tmp / "dup_id_pkg_one/mod.py", tmp / "dup_id_pkg_one/mod.py"], tmp,
            include_all=True,
        )
        if not forced_dup_errors:
            print("SELF-TEST FAIL: scanning the same path twice did not produce a "
                  "duplicate-id error", file=sys.stderr)
            ok = False
        forced_ids = [r["id"] for r in forced_records]
        if len(forced_ids) != len(set(forced_ids)):
            print(f"SELF-TEST FAIL: a duplicate id leaked into records despite dup_errors: "
                  f"{forced_records}", file=sys.stderr)
            ok = False

        def _first_record(symbol: str) -> dict | None:
            matches = sorted((r for r in records_all if r["symbol"] == symbol), key=lambda r: r["id"])
            return matches[0] if matches else None

        stale_records = sorted(
            (r for r in records_all if r["symbol"] == "stale_candidate"), key=lambda r: r["id"]
        )
        dangling_record = _first_record("uses_dangling")
        builtin_record = _first_record("uses_builtin_call")
        import_record = _first_record("uses_import")

        if len(stale_records) < 2 or dangling_record is None or builtin_record is None or import_record is None:
            print("SELF-TEST FAIL: verdicts-in fixture symbols are missing from --all claims",
                  file=sys.stderr)
            ok = False
        else:
            quote_present = "return 1"  # a real substring of uses_dangling's own source
            verdicts = {
                stale_records[0]["id"]: {
                    "supported": 0.9, "overgeneralized": 0.05, "contradicted": 0.05,
                    "band": "corroborated",
                },
                stale_records[1]["id"]: {
                    "supported": 0.05, "overgeneralized": 0.1, "contradicted": 0.85,
                    "band": "contradicted",
                },
                dangling_record["id"]: {"verdict": "contradicted", "quote": quote_present},
                builtin_record["id"]: {
                    "verdict": "contradicted",
                    "quote": "this exact phrase is definitely absent from the evidence",
                },
                import_record["id"]: {"verdict": "not-addressed"},
                "nonexistent/path.py::no_such_symbol::0": {"verdict": "contradicted", "quote": "irrelevant"},
            }
            verdicts_file = tmp / "verdicts.json"
            verdicts_file.write_text(json.dumps(verdicts), encoding="utf-8")
            by_id_all = {r["id"]: r for r in records_all}
            stale_findings, verdict_errors = apply_verdicts(verdicts_file, by_id_all)

            stale_by_symbol: dict[str, list[Finding]] = {}
            for f in stale_findings:
                stale_by_symbol.setdefault(f.symbol, []).append(f)

            candidate_findings = stale_by_symbol.get("stale_candidate", [])
            if len(candidate_findings) != 1 or candidate_findings[0].severity != "certain":
                print(f"SELF-TEST FAIL: expected exactly one certain STALE finding for "
                      f"stale_candidate (judge-contradicted only), got {candidate_findings}",
                      file=sys.stderr)
                ok = False

            dangling_findings = stale_by_symbol.get("uses_dangling", [])
            if len(dangling_findings) != 1 or dangling_findings[0].severity != "certain":
                print(f"SELF-TEST FAIL: expected a certain STALE finding for uses_dangling "
                      f"(quote verified), got {dangling_findings}", file=sys.stderr)
                ok = False

            builtin_findings = stale_by_symbol.get("uses_builtin_call", [])
            if len(builtin_findings) != 1 or builtin_findings[0].severity != "suspect":
                print(f"SELF-TEST FAIL: expected a suspect STALE finding for uses_builtin_call "
                      f"(quote not found), got {builtin_findings}", file=sys.stderr)
                ok = False

            if "uses_import" in stale_by_symbol:
                print(f"SELF-TEST FAIL: not-addressed verdict must not produce a finding, "
                      f"got {stale_by_symbol['uses_import']}", file=sys.stderr)
                ok = False

            if not any(e[0] == "nonexistent/path.py::no_such_symbol::0" for e in verdict_errors):
                print("SELF-TEST FAIL: a bogus verdict id did not land in parse_errors",
                      file=sys.stderr)
                ok = False

        ok = _self_test_body_newer() and ok
        ok = _self_test_fixtures_discovery() and ok
        ok = _self_test_nongit_fallback_root_ancestor() and ok
        ok = _self_test_dangling_ref_full_index() and ok
        ok = _self_test_all_flag_warning() and ok
        ok = _self_test_language_aware_code_signature() and ok
        ok = _self_test_docstring_pointer_scan() and ok
        ok = _self_test_changed_from_subdir() and ok
        ok = _self_test_dir_walk_excludes_default_patterns() and ok
        ok = _self_test_deleted_files_excluded() and ok
        ok = _self_test_nonascii_filenames_unquoted() and ok
        ok = _self_test_multiline_construct_verbatim_fallback() and ok
        ok = _self_test_paths_and_changed_intersection() and ok

        if ok:
            print("docstring_check.py --self-test: all assertions passed")
        return ok
    finally:
        _shutil.rmtree(tmp, ignore_errors=True)


# ── CLI ──────────────────────────────────────────────────────────────────────


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="docstring_check.py",
        description="Find docstrings/comments that drifted from their code "
                     "(pointers, placeholders, param/return drift, missing "
                     "docstrings). Mechanical only -- no model calls.",
    )
    parser.add_argument("paths", nargs="*", help="files or directories to scan")
    parser.add_argument("--changed", action="store_true",
                         help="scan git-changed files (diff vs HEAD, plus untracked) instead")
    parser.add_argument("--include-tests", action="store_true",
                         help="run docstring checks (PLACEHOLDER/THIN/MISSING) on test files too")
    parser.add_argument("--pointers-only", action="store_true",
                         help="run only the POINTER check (fast legacy-pointer pass)")
    parser.add_argument("--json", action="store_true", help="emit JSON instead of text")
    parser.add_argument("--limit", type=int, default=None,
                         help="scan at most N discovered files (deterministic order)")
    parser.add_argument("--snapshot", action="store_true",
                         help="write a docstring-stripped snapshot for the scanned files "
                              "to a temp file and print its path, instead of reporting findings")
    parser.add_argument("--verify-docs-only", metavar="SNAPSHOT_FILE",
                         help="compare the current files against a --snapshot file; "
                              "exit 1 if anything but a docstring/comment changed")
    parser.add_argument("--claims-out", metavar="FILE",
                         help="write candidate docstring sentences (as {id, claim, evidence} "
                              "entries) to FILE for judgment triage")
    parser.add_argument("--verdicts-in", metavar="FILE",
                         help="read judgment verdicts (probability-style or triage-style shape, "
                              "auto-detected per entry) from FILE and fold them into STALE "
                              "findings; must use the same paths/scope and --all as the "
                              "--claims-out run it closes the loop on")
    parser.add_argument("--all", action="store_true",
                         help="with --claims-out, widen the claims scope to every symbol with "
                              "a non-empty docstring, not just ones with an existing finding")
    parser.add_argument("--self-test", action="store_true",
                         help="run the built-in self-test against a synthetic tree and exit")
    args = parser.parse_args(argv)

    if args.self_test:
        return 0 if _run_self_test() else 1

    # --all also governs a --verdicts-in-only call (it widens which symbols
    # build_claim_records considers, which is what a verdict id has to
    # resolve against) -- it is a no-op only when NEITHER flag is present.
    if args.all and not args.claims_out and not args.verdicts_in:
        print("docstring_check: --all has no effect without --claims-out or --verdicts-in",
              file=sys.stderr)

    root = Path.cwd()

    if args.verify_docs_only:
        snap_path = Path(args.verify_docs_only)
        if not snap_path.is_file():
            print(f"error: snapshot file not found: {snap_path}", file=sys.stderr)
            return 2
        violations, notes = verify_docs_only(snap_path, root)
        for n in notes:
            print(f"verify-docs-only: note: {n}")
        if violations:
            print("verify-docs-only: VIOLATIONS found (non-docstring content changed):")
            for v in violations:
                print(f"  {v}")
            return 1
        print("verify-docs-only: clean -- only docstrings/comments changed")
        return 0

    files = discover(args.paths or None, root, args.changed)
    if args.limit is not None:
        files = files[: args.limit]

    if not files:
        print("error: no files discovered to scan", file=sys.stderr)
        return 2

    if args.snapshot:
        snapshot = build_snapshot(files, root)
        fd, path_str = tempfile.mkstemp(prefix="docstring_check_snapshot_", suffix=".json")
        with open(fd, "w", encoding="utf-8") as fh:
            json.dump(snapshot, fh)
        print(path_str)
        return 0

    # The dangling-ref name index must cover the full discoverable file set,
    # never just the narrower one being reported on -- otherwise `--limit`,
    # `--changed`, or a single positional path makes a real, defined-elsewhere
    # name look dangling. Only worth recomputing when the report set is
    # actually narrower than a full discovery; a plain full-repo run already
    # scans everything discoverable, so `files` doubles as the index for free.
    # This only builds the cheap identifier/string index (no comment scan, no
    # blame, no per-symbol checks) over the extra files -- not a second full
    # check pass.
    index_files = files
    if args.paths or args.changed or args.limit is not None:
        index_files = discover(None, root, changed=False)

    result = scan_paths(
        files, root, args.include_tests, args.pointers_only, index_files=index_files,
    )

    claims_written = None
    oversized_list = None
    if args.claims_out or args.verdicts_in:
        records, oversized_list, dup_errors = build_claim_records(result, files, root, include_all=args.all)
        result.parse_errors.extend(dup_errors)

        if args.claims_out:
            bare = [{"id": r["id"], "claim": r["claim"], "evidence": r["evidence"]} for r in records]
            Path(args.claims_out).write_text(json.dumps(bare, indent=2), encoding="utf-8")
            claims_written = len(bare)

        if args.verdicts_in:
            verdicts_path = Path(args.verdicts_in)
            if not verdicts_path.is_file():
                print(f"error: verdicts file not found: {verdicts_path}", file=sys.stderr)
                return 2
            by_id = {r["id"]: r for r in records}
            stale_findings, verdict_errors = apply_verdicts(verdicts_path, by_id)
            result.findings.extend(stale_findings)
            result.parse_errors.extend(verdict_errors)

    return print_report(
        result, args.json, claims_out_path=args.claims_out,
        claims_written=claims_written, oversized=oversized_list,
    )


if __name__ == "__main__":
    raise SystemExit(main())
