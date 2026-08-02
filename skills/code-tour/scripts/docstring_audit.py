#!/usr/bin/env python3
"""Audit docstring coverage across a Python tree — the code-tour skill's survey step.

Why this is bundled rather than written fresh each run: the audit is mechanical,
easy to get subtly wrong (missing nested functions, counting `__init__.py`, being
fooled by a string expression that is not in the docstring position), and needed
at least twice per invocation — once to find the gaps, once to prove they are
closed. Writing it once here means every run measures the same thing the same way,
and the numbers from two different runs are comparable.

Uses `ast` rather than regex or `import`:
  * REGEX cannot tell a docstring from any other string literal, and cannot find
    nested definitions reliably.
  * IMPORTING the module would execute it — side effects, missing third-party
    dependencies, and a hard failure on any file that needs a configured
    environment. `ast.parse` only reads text, so it audits code that cannot even
    run here.

Reports two things deliberately kept separate:
  * SYMBOL coverage — functions, classes, methods (including nested ones).
  * MODULE coverage — files whose top-level docstring is missing.
A file can have perfect symbol coverage and no module docstring; conflating them
hides the gap that matters most for a reader arriving cold.

Exit codes make it CI-usable:
  0  coverage meets --min (default 100)
  1  coverage below --min
  2  a file could not be parsed (a real syntax error worth surfacing loudly,
     never silently skipped as "no symbols found")

Usage:
    python3 docstring_audit.py [PATH] [--min 100] [--json] [--quiet]
                               [--exclude PATTERN ...] [--include-private]
                               [--include-tests]

Examples:
    python3 docstring_audit.py backend/
    python3 docstring_audit.py . --min 90 --exclude '*/migrations/*'
    python3 docstring_audit.py src/ --json > coverage.json
"""
from __future__ import annotations

import argparse
import ast
import fnmatch
import json
import sys
from dataclasses import dataclass, field
from pathlib import Path

# Directories that are never the project's own source. Skipped before parsing so
# a vendored dependency's docstring habits never dilute (or flatter) the report.
_DEFAULT_EXCLUDES = (
    "*/.git/*", "*/node_modules/*", "*/.venv/*", "*/venv/*", "*/env/*",
    "*/__pycache__/*", "*/site-packages/*", "*/.tox/*", "*/.mypy_cache/*",
    "*/build/*", "*/dist/*", "*/.eggs/*", "*/migrations/*",
)

_TEST_PATTERNS = ("test_*.py", "*_test.py", "conftest.py", "selftest.py")


@dataclass
class FileReport:
    """Per-file audit result.

    `missing` holds `(line, qualified_name, kind)` so the caller can jump straight
    to each gap. Qualified names (`ClassName.method`) rather than bare names,
    because a report full of `__init__` entries is useless for navigation.
    """

    path: str
    has_module_docstring: bool
    documented: int = 0
    missing: list[tuple[int, str, str]] = field(default_factory=list)
    parse_error: str | None = None

    @property
    def total(self) -> int:
        """Symbols found, documented or not — the coverage denominator."""
        return self.documented + len(self.missing)


def _is_private(name: str) -> bool:
    """A leading underscore marks a private symbol — but dunders are not private.

    `_helper` is internal; `__init__`, `__enter__`, `__repr__` are the public
    protocol of a class and are excluded from `--include-private` filtering. Note
    that dunder methods are frequently left undocumented ON PURPOSE (their
    semantics come from the language, not the author), which is why the default
    run reports them but a reviewer may reasonably choose to ignore them.
    """
    return name.startswith("_") and not (name.startswith("__") and name.endswith("__"))


def _walk_symbols(tree: ast.AST) -> list[tuple[ast.AST, str]]:
    """Collect every def/class with its QUALIFIED name, descending into nesting.

    `ast.walk` alone would give a flat list with bare names, so two different
    `run_cli` helpers in two different test functions would be indistinguishable
    in the report. Walking the tree manually and threading a prefix keeps
    `test_batfish.run_cli` distinct from `test_mocklab.run_cli` — which matters,
    because those are exactly the nested closures that go undocumented.
    """
    found: list[tuple[ast.AST, str]] = []

    def visit(node: ast.AST, prefix: str) -> None:
        for child in ast.iter_child_nodes(node):
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                qualified = f"{prefix}{child.name}"
                found.append((child, qualified))
                visit(child, f"{qualified}.")
            else:
                # Descend through non-def nodes too: a def inside an `if
                # TYPE_CHECKING:` block or a `try:` still counts as a symbol.
                visit(child, prefix)

    visit(tree, "")
    return found


def audit_file(path: Path, *, include_private: bool = True) -> FileReport:
    """Parse one file and report which symbols carry docstrings.

    A syntax error is recorded on the report rather than raised, so one broken
    file does not abort a whole-tree audit — but it is surfaced as `parse_error`
    and drives exit code 2. Silently treating an unparseable file as "0 symbols,
    100% covered" would be the worst possible outcome: the report would improve.
    """
    try:
        source = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        return FileReport(str(path), False, parse_error=f"unreadable: {exc}")

    try:
        tree = ast.parse(source)
    except SyntaxError as exc:
        return FileReport(str(path), False, parse_error=f"syntax error line {exc.lineno}: {exc.msg}")

    # An entirely empty file needs no module docstring — reporting `__init__.py`
    # with 0 bytes as a gap is noise, and empty package markers are conventional.
    is_empty = not source.strip()
    report = FileReport(
        path=str(path),
        has_module_docstring=ast.get_docstring(tree) is not None or is_empty,
    )

    for node, qualified in _walk_symbols(tree):
        if not include_private and _is_private(node.name):
            continue
        kind = "class" if isinstance(node, ast.ClassDef) else "def"
        if ast.get_docstring(node) is None:
            report.missing.append((node.lineno, qualified, kind))
        else:
            report.documented += 1

    report.missing.sort()
    return report


def discover(root: Path, excludes: tuple[str, ...], include_tests: bool) -> list[Path]:
    """Find auditable .py files under `root`, honouring exclude globs.

    Tests are EXCLUDED by default. This is a judgement call worth stating: test
    functions are often self-documenting through their names, and a suite of a
    few thousand asserts can swamp the coverage number for the source you
    actually care about. Pass `--include-tests` when the tests are themselves a
    teaching artifact — which is the case in codebases where the suite is the
    specification.
    """
    if root.is_file():
        return [root] if root.suffix == ".py" else []

    files = []
    for p in sorted(root.rglob("*.py")):
        posix = p.as_posix()
        if any(fnmatch.fnmatch(posix, pat) for pat in excludes):
            continue
        if not include_tests and any(fnmatch.fnmatch(p.name, pat) for pat in _TEST_PATTERNS):
            continue
        files.append(p)
    return files


def summarize(reports: list[FileReport]) -> dict:
    """Roll per-file reports into the totals the caller reports and gates on."""
    total = sum(r.total for r in reports)
    documented = sum(r.documented for r in reports)
    no_module_doc = [r.path for r in reports if not r.has_module_docstring]
    errors = [(r.path, r.parse_error) for r in reports if r.parse_error]
    return {
        "files": len(reports),
        "symbols_total": total,
        "symbols_documented": documented,
        # A tree with no symbols at all is 100% covered, not 0% — the same
        # vacuous-truth care `all([])` demands. Guarding the division also stops
        # a ZeroDivisionError from killing the run on an empty package.
        "coverage_pct": round(100.0 * documented / total, 1) if total else 100.0,
        "modules_missing_docstring": no_module_doc,
        "parse_errors": errors,
    }


def main(argv: list[str] | None = None) -> int:
    """CLI entry: audit a tree, print a report, exit on the coverage gate.

    `argv=None` defers to `sys.argv` in normal use while letting a caller invoke
    `main([...])` directly in a test — the same testability convention the tool
    CLIs in a well-structured project use.
    """
    parser = argparse.ArgumentParser(
        prog="docstring_audit.py",
        description="Report docstring coverage for a Python tree (AST-based, never imports).",
    )
    parser.add_argument("path", nargs="?", default=".", help="file or directory to audit")
    parser.add_argument("--min", type=float, default=100.0,
                        help="minimum coverage%% required; exit 1 below it (default 100)")
    parser.add_argument("--json", action="store_true", help="emit JSON instead of text")
    parser.add_argument("--quiet", action="store_true", help="summary only, omit per-file detail")
    parser.add_argument("--exclude", action="append", default=[],
                        help="extra glob to skip (repeatable)")
    parser.add_argument("--include-private", action="store_true", default=True,
                        help="audit _private symbols (default: yes)")
    parser.add_argument("--no-private", dest="include_private", action="store_false",
                        help="skip _private symbols")
    parser.add_argument("--include-tests", action="store_true",
                        help="audit test files too (default: skipped)")
    args = parser.parse_args(argv)

    root = Path(args.path)
    if not root.exists():
        print(f"error: {root} does not exist", file=sys.stderr)
        return 2

    excludes = _DEFAULT_EXCLUDES + tuple(args.exclude)
    files = discover(root, excludes, args.include_tests)
    if not files:
        # An empty discovery is reported loudly, not as a pass: a mistyped path
        # or an over-broad exclude would otherwise look like a clean audit.
        print(f"error: no Python files found under {root}", file=sys.stderr)
        return 2

    reports = [audit_file(p, include_private=args.include_private) for p in files]
    summary = summarize(reports)

    if args.json:
        print(json.dumps({
            "summary": summary,
            "files": [
                {
                    "path": r.path,
                    "has_module_docstring": r.has_module_docstring,
                    "documented": r.documented,
                    "total": r.total,
                    "missing": [
                        {"line": ln, "name": nm, "kind": k} for ln, nm, k in r.missing
                    ],
                    "parse_error": r.parse_error,
                }
                for r in reports
            ],
        }, indent=2))
    else:
        if not args.quiet:
            for r in sorted(reports, key=lambda r: -len(r.missing)):
                if r.parse_error:
                    print(f"!! {r.path}: {r.parse_error}")
                    continue
                if not r.missing and r.has_module_docstring:
                    continue
                flag = "" if r.has_module_docstring else "  [NO MODULE DOCSTRING]"
                print(f"\n{r.path}  ({r.documented}/{r.total}){flag}")
                for line, name, kind in r.missing:
                    print(f"    {r.path}:{line}  {kind} {name}")

        print(f"\ncoverage: {summary['symbols_documented']}/{summary['symbols_total']} "
              f"symbols ({summary['coverage_pct']}%) across {summary['files']} files")
        if summary["modules_missing_docstring"]:
            print(f"modules without a docstring: {len(summary['modules_missing_docstring'])}")
        if summary["parse_errors"]:
            print(f"PARSE ERRORS: {len(summary['parse_errors'])}")

    if summary["parse_errors"]:
        return 2
    return 0 if summary["coverage_pct"] >= args.min else 1


if __name__ == "__main__":
    raise SystemExit(main())
