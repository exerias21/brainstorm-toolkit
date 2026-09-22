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
                  kind of rot this check targets.
  PLACEHOLDER  -- an empty docstring, an autoDocstring stub (`_summary_`,
                  `_description_`), a bare TODO, or a generated
                  "Docstring for X" line.
  THIN         -- documented params disagree with the signature (Google,
                  NumPy or Sphinx sections only -- an unrecognized style is
                  skipped, never guessed at), or a Returns section on a body
                  that never returns a value (excluding stub/NotImplementedError
                  bodies, where "no return yet" is the honest state).
  MISSING      -- a public symbol with no docstring at all. Report-only: this
                  script never writes a docstring, so there is nothing here
                  for a human to approve or reject.

Every finding also carries `runtime_visible` (a route/CLI decorator,
`description=__doc__`, or a `>>>` doctest block makes a docstring a public
contract, not just documentation) so a downstream rewrite can skip it by
default.

Discovery respects `.gitignore` via `git ls-files` (read-only) when the
target is a git repository, and falls back to a fixed exclude list
otherwise. Any git call resolves the binary with `shutil.which("git")`,
never a bare `git`, and uses only read-only subcommands (`ls-files`,
`diff --name-only`, `check-ignore`); an absent git or a non-repo path is a
silent, graceful fallback, never a crash.

Exit codes:
  0  no findings
  1  findings reported
  2  a file could not be parsed, or nothing was discovered (loud, never a
     silent "0 files, all clean")

Usage:
    bash scripts/py.sh docstring_check.py [PATH ...] [--changed]
                        [--include-tests] [--pointers-only] [--json]
                        [--limit N] [--snapshot] [--verify-docs-only FILE]
                        [--self-test]

Examples:
    bash scripts/py.sh docstring_check.py skills/
    bash scripts/py.sh docstring_check.py --changed --json
    bash scripts/py.sh docstring_check.py --pointers-only .
"""
from __future__ import annotations

import argparse
import ast
import fnmatch
import io
import json
import re
import shutil
import subprocess
import sys
import tempfile
import tokenize
from dataclasses import dataclass, field, asdict
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


def _git_tracked_files(root: Path) -> set[str] | None:
    out = _run_git(["ls-files", "-co", "--exclude-standard"], root)
    if out is None:
        return None
    return {line.strip() for line in out.splitlines() if line.strip()}


def _git_changed_files(root: Path) -> set[str] | None:
    """Tracked changes against HEAD plus untracked-not-ignored files --
    read-only (`diff --name-only`, `ls-files --others`)."""
    diffed = _run_git(["diff", "--name-only", "HEAD"], root)
    others = _run_git(["ls-files", "--others", "--exclude-standard"], root)
    if diffed is None and others is None:
        return None
    changed: set[str] = set()
    for out in (diffed, others):
        if out:
            changed.update(line.strip() for line in out.splitlines() if line.strip())
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


# ── Discovery ────────────────────────────────────────────────────────────────


def discover(paths: list[str] | None, root: Path, changed: bool) -> list[Path]:
    """Resolve the file set to scan.

    Positional paths win outright (a directory is walked; a file is used
    as-is). Otherwise: `--changed` uses read-only git diff/ls-files;
    plain invocation uses `git ls-files` when the root is a repo, falling
    back to a filesystem walk with `_DEFAULT_EXCLUDES` otherwise.
    """
    if paths:
        files: list[Path] = []
        for p in paths:
            pp = Path(p)
            if pp.is_dir():
                files.extend(sorted(pp.rglob("*.py")))
                for ext in _HEURISTIC_TEXT_EXTS:
                    files.extend(sorted(pp.rglob(f"*{ext}")))
            elif pp.is_file():
                files.append(pp)
        return files

    if changed:
        rels = _git_changed_files(root)
        if rels is None:
            print("docstring_check: --changed requires a git repository; "
                  "found none usable here", file=sys.stderr)
            return []
        return sorted(root / r for r in rels if _scannable(r))

    tracked = _git_tracked_files(root)
    if tracked is not None:
        return sorted(root / r for r in tracked if _scannable(r))

    files = []
    for ext in (".py", *_HEURISTIC_TEXT_EXTS):
        for p in sorted(root.rglob(f"*{ext}")):
            posix = p.as_posix()
            if any(fnmatch.fnmatch(posix, pat) for pat in _DEFAULT_EXCLUDES):
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
    kind: str  # POINTER | PLACEHOLDER | THIN | MISSING
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
    in_usage_block: bool = False,
) -> list[Finding]:
    """Scan one comment or docstring body for POINTER findings. `base_line`
    is the 1-based source line the text starts on (findings report the
    line the match itself falls on, computed from `base_line` plus the
    number of newlines before the match)."""
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
                    pointer_only=pointer_only, heuristic=heuristic,
                ))
            else:
                findings.append(Finding(
                    path=rel_file, line=line_of(start), kind="POINTER", severity="certain",
                    message=f"cites plan path `{cited_norm}` ({status}) -- plan references rot; "
                            "the reason belongs in the comment itself, not a pointer to it",
                    pointer_only=pointer_only, heuristic=heuristic,
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
                pointer_only=pointer_only, heuristic=heuristic,
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
                pointer_only=pointer_only, heuristic=heuristic,
            ))
        if pointer_only:
            for m in ticket_hits:
                findings.append(Finding(
                    path=rel_file, line=line_of(m.start()), kind="POINTER", severity="suspect",
                    message=f"comment is only a ticket reference (`{m.group(0)}`) -- "
                            "confirm whether the reason should be inlined",
                    pointer_only=True, heuristic=heuristic,
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


# ── Symbol-level checks (PLACEHOLDER, THIN, MISSING) ────────────────────────


def check_symbol(
    node: ast.AST, qualified: str, rel_file: str, decorators: list[ast.expr],
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
) -> tuple[list[Finding], str | None]:
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

    if pointers_only:
        return findings, None

    if is_test and not include_tests:
        return findings, None

    if module_doc is not None:
        runtime_visible = _module_has_description_doc(tree) or _has_doctest(module_doc)
        placeholder = scan_text_for_placeholder(module_doc, rel, 1, "<module>", runtime_visible)
        if placeholder:
            findings.append(placeholder)

    for node, qualified in _walk_symbols(tree):
        decorators = list(getattr(node, "decorator_list", []))
        findings.extend(check_symbol(node, qualified, rel, decorators))

    return findings, None


# ── Scan driver ──────────────────────────────────────────────────────────────


def scan_paths(
    files: list[Path], root: Path, include_tests: bool, pointers_only: bool,
) -> ScanResult:
    result = ScanResult()
    for path in files:
        result.files_scanned += 1
        if path.suffix == ".py":
            findings, error = check_python_file(path, root, include_tests, pointers_only)
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


def _code_line_signature(text: str) -> str:
    """Non-Python fallback for the docs-only guard: every line that is not
    blank and not a recognized comment line, joined -- a change here means
    real code changed, not just a comment or docstring."""
    lines = []
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if any(stripped.startswith(p) for p in _COMMENT_PREFIXES):
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
            snapshot[rel] = {"kind": "text", "code_lines": _code_line_signature(text)}
    return snapshot


def verify_docs_only(snapshot_path: Path, root: Path) -> list[str]:
    """Returns a list of violation messages (empty == clean). A file
    present in the snapshot but now missing, or whose non-docstring content
    changed, is a violation."""
    data = json.loads(snapshot_path.read_text(encoding="utf-8", errors="replace"))
    violations: list[str] = []
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
            after_lines = _code_line_signature(text)
            if after_lines != before["code_lines"]:
                violations.append(f"{rel}: a non-comment line changed (heuristic)")
    return violations


# ── Reporting ────────────────────────────────────────────────────────────────


def print_report(result: ScanResult, as_json: bool) -> int:
    if as_json:
        payload = {
            "files_scanned": result.files_scanned,
            "findings": [asdict(f) for f in result.findings],
            "parse_errors": [{"path": p, "error": e} for p, e in result.parse_errors],
        }
        print(json.dumps(payload, indent=2))
    else:
        by_kind: dict[str, list[Finding]] = {}
        for f in result.findings:
            by_kind.setdefault(f.kind, []).append(f)
        for kind in ("POINTER", "PLACEHOLDER", "THIN", "MISSING"):
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
        violations = verify_docs_only(snap_file, tmp)
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
        violations = verify_docs_only(snap_file, tmp)
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
    parser.add_argument("--self-test", action="store_true",
                         help="run the built-in self-test against a synthetic tree and exit")
    args = parser.parse_args(argv)

    if args.self_test:
        return 0 if _run_self_test() else 1

    root = Path.cwd()

    if args.verify_docs_only:
        snap_path = Path(args.verify_docs_only)
        if not snap_path.is_file():
            print(f"error: snapshot file not found: {snap_path}", file=sys.stderr)
            return 2
        violations = verify_docs_only(snap_path, root)
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

    result = scan_paths(files, root, args.include_tests, args.pointers_only)
    return print_report(result, args.json)


if __name__ == "__main__":
    raise SystemExit(main())
