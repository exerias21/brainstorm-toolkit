#!/usr/bin/env python3
"""Prove the prose and the config agree: five static contract checks.

`validate_skills.py` lints frontmatter and bundled-resource references.
`check_install_refs.py` proves an INSTALLED tree's template citations resolve.
This proves something neither of those does: that the *facts* a skill states
in prose are still true, plus one hand-editable-tree regression guard. Five
checks:

  1. Config keys   -- every `project.json` dotted key path a skill names
                       exists in `templates/project.json.example` (the
                       registry).
  2. Citations      -- every backticked `skills/...`, `scripts/...`,
                       `templates/...`, `docs/...`, `agents/...`, `hooks/...`,
                       `examples/...` path resolves in the repo, and no
                       `docs/` path is cited as something a skill LOADS (`docs/`
                       is never installed by setup.sh).
  3. Forbidden phrases -- `scripts/ci/forbidden-phrases.txt` is a denylist of
                       facts a rename or design decision invalidated (dead
                       keys, dangling filenames, "opens a PR" claims a merge
                       made false). Each row is regex<TAB>reason<TAB>allow-glob.
                       An allow-glob entry pins an EXPECTED OCCURRENCE COUNT
                       (`path/glob:N`, bare `path/glob` means exactly 1) --
                       the file is still scanned; a count above the pin is a
                       finding naming the first excess occurrence, and a count
                       below the pin is a finding that the pin is stale.
  4. Collapsed pairs -- the same `/command` token named twice in one sentence,
                       the shape a global rename (`s|/old|/new|g`) leaves
                       behind. Verbatim regex from docs/CONVENTIONS.md
                       "Migration policy".
  5. Portable frontmatter -- copilot/skills/*/SKILL.md and codex/skills/*/
                       SKILL.md (the two hand-edited overlay trees) may only
                       declare the Agent Skills portable subset (name,
                       description, license, metadata, compatibility,
                       allowed-tools). A strict Copilot/Codex consumer
                       hard-errors on an unknown key. The canonical
                       skills/*/SKILL.md is exempt -- it is the Claude install
                       source and legitimately keeps Claude-only keys
                       (setup.sh strips them for the Copilot/Codex install
                       paths only).

Checks 1-4's file scope also covers CLAUDE.md, AGENTS.md and docs/*.md (not
just skills/copilot/codex/agents/templates), and three more checks cover
facts only those wider files can state:

  6. Doc status markers -- every docs/*.md declares `Live contract` or
                       `Historical design record` in its header. A historical
                       marker must carry a pointer to the live contract that
                       superseded it, and the pointer must resolve; the COUNT
                       of historical docs is pinned so a new one is a
                       reviewed diff. A historical doc is exempt from checks
                       1-4 and 8 -- it is an amending instrument, never
                       re-verified once the consolidated text exists.
  7. No cardinality  -- a number-word (`one`..`twenty`) immediately
                       followed by `checks`/`hooks`/`skills`/`agents`, outside
                       fenced code, in CLAUDE.md/AGENTS.md/a `Live contract`
                       doc: a derivable count that goes stale with no local
                       edit to catch it.
  8. Header-list-count -- where check 7's pattern is immediately followed by
                       a bulleted list (README.md's "five hooks"), the count
                       must equal the list length instead of being banned --
                       deleting the number there makes the sentence worse.

A ninth mechanism, `recheck-by` pins (`<!-- assert-manual: recheck-by
YYYY-MM-DD "<claim>" -->` in CLAUDE.md/AGENTS.md/docs/*.md), is a permanent
WARN, never a failure -- see `recheck_by_warnings()`. It never contributes to
the exit code, mirroring `model_cap_pointer_warnings()` in validate_skills.py.

The `portable-invocation` check is a Windows-portability check with two
rules: no bare `python3 ` invocation in
shipped skill/agent/template prose (a Microsoft Store stub trap -- see
scripts/py.sh, GOTCHAS.md), and every `hooks/hooks.json` command starting
with an interpreter token instead of a bare path.

This targets the exact failure class a 2026-09 review found 46 instances of.
Stdlib only, no model calls, runs in well under 5s.

Usage:
  python scripts/ci/check_contracts.py            # check this repo, exit 0/1
  python scripts/ci/check_contracts.py --json      # machine-readable output
  python scripts/ci/check_contracts.py --self-test # exercise the checks
                                                    # against a synthetic tree
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import date
from pathlib import Path
from typing import NamedTuple

REPO_ROOT = Path(__file__).resolve().parents[2]

# ── Shared file-set walking convention (mirrors scripts/validate_skills.py) ──

SKILL_TREE_DIRS = ("skills", "copilot", "codex")

# Cross-Module Touchpoint:
# evals/skills/fixtures/** is a committed MOCK CONSUMER REPO for
# scripts/ci/skill-eval.py, not toolkit prose -- it legitimately contains
# things these checks would otherwise flag (its own AGENTS.md, TASKS.md, a
# plan file, all shaped like a consumer repo, not this one). None of the
# walks below currently reach into evals/ (SKILL_TREE_DIRS are repo-root
# skills/copilot/codex only, and templates_dir is non-recursive), so this
# filter is a no-op today -- kept as an explicit, structural guard so a
# future broader walk can't silently sweep the fixture back into scope.
FIXTURE_EXCLUDE_PREFIX = "evals/skills/fixtures/"


def _exclude_fixtures(root: Path, files: list[Path]) -> list[Path]:
    return [f for f in files if not relposix(root, f).startswith(FIXTURE_EXCLUDE_PREFIX)]


# ── Doc status markers (Step 1) -- decides the historical exemption ─────────
#
# A docs/*.md file marked `Historical design record` is an amending
# instrument (docs/CONVENTIONS.md "Migration policy"'s legal-codification
# framing): it records what a design USED to be, and its dead keys, dangling
# filenames and merged-away skill names are the whole point of the sentence,
# not a bug. Detecting it as content (not just a path) is what lets checks
# 1-4 skip it without a second, parallel exclusion list to keep in sync.
#
# The marker must live in the file's own HEADER, not anywhere in its body:
# docs/FLOW.md cites "historical design record for the adversarial
# Review->Fix stage" in its own see-also table, and a whole-file search would
# misclassify FLOW.md itself as historical from that one citation.
DOC_STATUS_HEADER_LINES = 15
DOC_STATUS_LIVE_RE = re.compile(r"Live contract", re.IGNORECASE)
DOC_STATUS_HISTORICAL_RE = re.compile(r"Historical design record", re.IGNORECASE)


def docs_status_files(root: Path) -> list[Path]:
    """Every docs/*.md file, non-recursive -- independent of scope_files()'s
    historical exclusion, since this is the function that decides it."""
    d = root / "docs"
    return sorted(d.glob("*.md")) if d.is_dir() else []


def _doc_header(path: Path) -> str:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""
    return "\n".join(text.splitlines()[:DOC_STATUS_HEADER_LINES])


def is_historical_doc(path: Path) -> bool:
    return bool(DOC_STATUS_HISTORICAL_RE.search(_doc_header(path)))


def _exclude_historical_docs(files: list[Path]) -> list[Path]:
    return [f for f in files if not is_historical_doc(f)]


def scope_files(root: Path) -> list[Path]:
    """The file set every check but citations runs over: skills/**/*.md,
    copilot/**/*.md, codex/**/*.md, agents/*.md, templates/*.template,
    CLAUDE.md, AGENTS.md, and non-recursive docs/*.md (minus any doc marked
    `Historical design record` -- see `is_historical_doc()`).

    docs/ is walked with `glob()`, not `rglob()`: `docs/plans/**`,
    `docs/archive/**` and `docs/gap-analysis/**` are deliberate
    historical/working trees a rename or a prose sweep must never rewrite
    (see CONVENTIONS.md "Migration policy"). A non-recursive glob already
    can't reach them, so no separate exclusion filter is needed here -- one
    would be dead code, same as the docs/ exclusion `check_collapsed_pairs`
    used to carry before docs/ was ever in scope.
    """
    files: list[Path] = []
    for base in SKILL_TREE_DIRS:
        d = root / base
        if d.is_dir():
            files.extend(sorted(d.rglob("*.md")))
    agents_dir = root / "agents"
    if agents_dir.is_dir():
        files.extend(sorted(agents_dir.glob("*.md")))
    templates_dir = root / "templates"
    if templates_dir.is_dir():
        files.extend(sorted(templates_dir.glob("*.template")))
    for name in ("CLAUDE.md", "AGENTS.md"):
        f = root / name
        if f.is_file():
            files.append(f)
    files.extend(_exclude_historical_docs(docs_status_files(root)))
    return _exclude_fixtures(root, files)


def citation_scope_files(root: Path) -> list[Path]:
    """Citations additionally cover README.md (paths only, per the plan's
    Open Question: yes for paths, no for phrases) -- on top of the CLAUDE.md,
    AGENTS.md and docs/*.md that scope_files() itself now covers."""
    files = scope_files(root)
    readme = root / "README.md"
    if readme.is_file():
        files.append(readme)
    return files


def load_only_scope_files(root: Path) -> list[Path]:
    """The docs/-is-a-load-not-a-cite sub-check is scoped to skills/ only
    (which already includes skills/sdlc/templates/) -- overlays and agents/
    are a separate axis the plan doesn't ask this sub-check to cover."""
    d = root / "skills"
    return _exclude_fixtures(root, sorted(d.rglob("*.md"))) if d.is_dir() else []


def relposix(root: Path, path: Path) -> str:
    return path.relative_to(root).as_posix()


def owning_skill_dir(root: Path, path: Path) -> Path | None:
    """The skill directory that owns `path`, if any -- .../skills/<name>/...
    under skills/, copilot/skills/, or codex/skills/. Returns the <name> dir
    regardless of how deep under it `path` sits (so a citation made from
    inside skills/sdlc/templates/*.md still resolves against skills/sdlc/)."""
    try:
        parts = path.relative_to(root).parts
    except ValueError:
        return None
    for i, part in enumerate(parts):
        if part == "skills" and i + 1 < len(parts):
            return root.joinpath(*parts[: i + 2])
    return None


class Finding(NamedTuple):
    path: str
    line: int
    message: str
    check: str


# ── Check 1: config keys ─────────────────────────────────────────────────────

CONFIG_KEY_TOPLEVEL = [
    "models", "agents", "pipeline", "test", "logs", "stack", "eval",
    "discipline", "migrations", "gotchas_file", "main_branch",
    "coauthor_trailer", "modules", "python",
]
_ROOT_ALT = "|".join(sorted(CONFIG_KEY_TOPLEVEL, key=len, reverse=True))
_SEGMENT = r"(?:\.[A-Za-z0-9_]+|\.\*[A-Za-z0-9_]*|\.<[^>`]+>)"
CONFIG_KEY_RE = re.compile(
    rf"`(?:\.claude/project\.json::)?((?:{_ROOT_ALT})(?:{_SEGMENT})*)`"
)
# A bare `<root>.<ext>` (e.g. `models.md`) is a FILE citation (the shared
# models.md contract), not a config-key path -- these extensions never appear
# as a literal two-segment project.json key.
_FILE_EXTENSIONS = {"md", "py", "sh", "json", "template", "txt"}

# Small, explicit, EXACT-STRING allowlist for wildcard/placeholder key
# references that are genuinely open lists or otherwise-legitimate generic
# mentions -- per the plan's "small inline allowlist for keys that are
# documented as open lists (`pipeline.loop.*`, `stack.*`)". Matched by exact
# equality against the full captured key, never by prefix -- so mentioning
# `pipeline.*` here does NOT cover a bogus `pipeline.bogus_thing.*`, which
# still gets flagged as an unknown key. Determined empirically by running this
# check and reading every live wildcard-bearing citation in context.
OPEN_LIST_PREFIXES: dict[str, str] = {
    "stack.*": "documented open list (the plan's own example) -- project "
        "stack commands are project-specific, not enumerable",
    "test.*": "collective reference to the test block's keys (unit, "
        "frontend, e2e, ...); always used generically ('no test.* keys "
        "configured'), never as a claim about one specific undocumented key",
    "agents.*": "collective reference to the agents block -- a section "
        "header, and project.json.example says its lists are 'deliberately "
        "open so a repo can add its own'",
    "pipeline.*": "collective reference to the pipeline block: 'every gated "
        "pipeline setting' (skills/sdlc/SKILL.md) and the old-vs-new "
        "namespace contrast in the models.md migration note",
    "models.*": "collective reference in the models.md migration note "
        "('renamed to models.* / agents.*') -- models' own keys are fixed, "
        "but this citation names the namespace generically, not a new key",
    "pipeline.*.model": "historical dead-key SHAPE (pipeline.sanity_check."
        "model / pipeline.review_fix.model, both renamed away already -- "
        "see forbidden-phrases.txt); describes the pattern, not a live key",
    "models.*_effort": "documents a key that deliberately does NOT exist "
        "('there is deliberately no models.*_effort key') -- a negation, "
        "not an open list, but still must never be flagged as unknown",
    "pipeline.loop.*": "documented open list (the plan's own example) -- "
        "--queue's loop knobs",
    "pipeline.review_fix.*": "collective reference to the review_fix block "
        "(enabled, mode)",
    "logs.*": "collective reference in docs/CONFIG.md's 'which skill reads "
        "which key' table -- /test-check reads the logs block generically",
    "eval.*": "collective reference in docs/CONFIG.md's 'which skill reads "
        "which key' table -- /sdlc delegates the whole eval block to "
        "/test-check",
    "pipeline.cleanup.*": "collective reference in docs/CONFIG.md's 'which "
        "skill reads which key' table -- Stage 5.9 reads the cleanup block "
        "generically",
    "discipline.*": "collective reference in docs/CONFIG.md's 'which skill "
        "reads which key' table -- the changed-files gate and /repo-health "
        "each read discipline.* keys generically",
}

# Config-keys equivalent of CITATION_ALLOWLIST, for a CONCRETE (non-wildcard)
# dotted key that is correct where it's cited -- a migration table's OLD
# column, never a live claim the key still resolves. docs/MODEL-AXES.md's
# "Migration from the old keys" table is exactly this: three of its eight
# rows already have a forbidden-phrases.txt denylist row of their own (the
# check that actually asserts these are dead); the other five have no
# corresponding denylist row today and would otherwise read as unknown keys.
CONFIG_KEY_ALLOWLIST: dict[tuple[str, str], str] = {
    ("docs/MODEL-AXES.md", key): "MODEL-AXES.md 'Migration from the old "
        "keys' table OLD column -- documents a dead key by design, not a "
        "live one"
    for key in (
        "pipeline.sanity_check.model",
        "pipeline.sanity_check.focuses",
        "pipeline.review_fix.model",
        "pipeline.review_fix.second_pass_model",
        "pipeline.review_fix.lenses",
        "pipeline.review_fix.passes",
        "pipeline.review_fix.max_fix_loops",
        "pipeline.decompose_min_tasks",
    )
}


def load_registry(root: Path) -> set[str]:
    """Every dotted key path in templates/project.json.example, at every
    nesting level, with `_*comment` / `_recommended*` keys stripped."""
    example = root / "templates" / "project.json.example"
    data = json.loads(example.read_text(encoding="utf-8"))
    paths: set[str] = set()

    def walk(obj: object, prefix: str) -> None:
        if isinstance(obj, dict):
            for key, value in obj.items():
                if key.startswith("_"):
                    continue
                full = f"{prefix}.{key}" if prefix else key
                paths.add(full)
                walk(value, full)

    walk(data, "")
    return paths


def check_config_keys(files: list[Path], root: Path, registry: set[str]) -> list[Finding]:
    findings: list[Finding] = []
    for path in files:
        text = path.read_text(encoding="utf-8", errors="replace")
        rel = relposix(root, path)
        seen: set[tuple[int, str]] = set()
        for m in CONFIG_KEY_RE.finditer(text):
            full = m.group(1)
            segments = full.split(".")
            if any("*" in seg or seg.startswith("<") for seg in segments):
                if full in OPEN_LIST_PREFIXES:
                    continue  # named, justified open list -- never flagged
                # else: an unrecognized wildcard/placeholder key falls through
                # to the registry check below, which flags it (it can never
                # match a registry path literally)
            if len(segments) == 2 and segments[1] in _FILE_EXTENSIONS:
                continue  # e.g. `models.md` -- a file citation, not a key
            if full in registry:
                continue
            if (rel, full) in CONFIG_KEY_ALLOWLIST:
                continue  # a dead key, correct in a migration table's OLD column
            line = text.count("\n", 0, m.start()) + 1
            key = (line, full)
            if key in seen:
                continue
            seen.add(key)
            findings.append(
                Finding(
                    relposix(root, path), line,
                    f"config key `{full}` not in templates/project.json.example",
                    "config-keys",
                )
            )
    return findings


# ── Check 2: citations resolve ───────────────────────────────────────────────

# Widened to see a citation written as a runnable command, not just a bare
# path -- an optional interpreter prefix (`bash `/`sh `/`python`/`python3 `/
# `py `), an optional
# `scripts/py.sh ` between the prefix and the path (the wrapper this repo
# routes every shipped Python command through), and trailing arguments before
# the closing backtick. The interpreter/wrapper/argument text is matched, never
# captured -- group(1) stays exactly the path portion, so citation_resolves()
# and the historical-doc pointer check (~line 700) keep working unchanged.
CITATION_RE = re.compile(
    r"`(?:(?:bash|sh|python3?|py)\s+)?(?:scripts/py\.sh\s+)?"
    r"((?:skills|scripts|templates|docs|agents|hooks|examples)/"
    r"[A-Za-z0-9_./-]+\.(?:md|py|sh|json|template|txt))"
    r"(?:\s+[^`]*)?`"
)

LOAD_INSTRUCTION_RE = re.compile(r"\*{0,2}(?:Read|Load)\s+`([^`]+)`\s*now\b")

# Citations that are correct despite not resolving in THIS repo: forward
# references to a file a skill instructs the USER to create in their own
# (consumer) repo, explicitly guarded by "if not already present". Never a
# dangling reference to something that was supposed to already exist here.
CITATION_ALLOWLIST: dict[tuple[str, str], str] = {
    ("skills/repo-onboarding/SKILL.md", "scripts/hooks/secret-scan.sh"):
        "consumer-repo stub target, explicitly guarded by "
        "'if ... is not already present ... stub one out' -- never expected "
        "to exist in this repo",
}


def citation_resolves(root: Path, file: Path, ref: str) -> bool:
    if (root / ref).is_file():
        return True
    skill_dir = owning_skill_dir(root, file)
    if skill_dir is not None and (skill_dir / ref).is_file():
        return True
    return False


def check_citations(files: list[Path], root: Path) -> list[Finding]:
    findings: list[Finding] = []
    for path in files:
        text = path.read_text(encoding="utf-8", errors="replace")
        rel = relposix(root, path)
        seen: set[tuple[int, str]] = set()
        for m in CITATION_RE.finditer(text):
            ref = m.group(1)
            if citation_resolves(root, path, ref):
                continue
            if CITATION_ALLOWLIST.get((rel, ref)):
                continue
            line = text.count("\n", 0, m.start()) + 1
            key = (line, ref)
            if key in seen:
                continue
            seen.add(key)
            findings.append(
                Finding(rel, line, f"citation `{ref}` does not resolve", "citations")
            )
    return findings


def check_docs_load_vs_cite(files: list[Path], root: Path) -> list[Finding]:
    """`docs/` is never installed by setup.sh, so a `**Read X now**` /
    `**Load X now**` instruction naming a docs/ path is a load, not a cite --
    it dangles for every consumer. Scoped to skills/ (already includes
    skills/sdlc/templates/) per the plan."""
    findings: list[Finding] = []
    for path in files:
        text = path.read_text(encoding="utf-8", errors="replace")
        for m in LOAD_INSTRUCTION_RE.finditer(text):
            ref = m.group(1)
            if not ref.startswith("docs/"):
                continue
            line = text.count("\n", 0, m.start()) + 1
            findings.append(
                Finding(
                    relposix(root, path), line,
                    f"`{ref}` is loaded (Read...now) but docs/ is never "
                    f"installed by setup.sh -- move it to references/",
                    "citations",
                )
            )
    return findings


# ── Check 3: forbidden phrases ───────────────────────────────────────────────


def _parse_allow_glob_entry(raw: str) -> tuple[str, int]:
    """`path/glob:N` pins N expected occurrences; bare `path/glob` means
    exactly 1 (keeps existing terse rows valid)."""
    if ":" in raw:
        glob_part, count_part = raw.rsplit(":", 1)
        if count_part.isdigit():
            return glob_part, int(count_part)
    return raw, 1


def load_forbidden_phrases(
    phrases_file: Path,
) -> list[tuple[re.Pattern, str, list[tuple[str, int]]]]:
    rows: list[tuple[re.Pattern, str, list[tuple[str, int]]]] = []
    if not phrases_file.is_file():
        return rows
    for raw_line in phrases_file.read_text(encoding="utf-8").splitlines():
        if not raw_line.strip() or raw_line.lstrip().startswith("#"):
            continue
        parts = raw_line.split("\t")
        if len(parts) < 2:
            continue
        pattern_str, reason = parts[0], parts[1]
        allow_globs = (
            [_parse_allow_glob_entry(g) for g in parts[2].split(",") if g]
            if len(parts) > 2 else []
        )
        rows.append((re.compile(pattern_str), reason.strip(), allow_globs))
    return rows


def check_forbidden_phrases(
    files: list[Path],
    root: Path,
    phrases: list[tuple[re.Pattern, str, list[tuple[str, int]]]],
) -> list[Finding]:
    findings: list[Finding] = []
    for path in files:
        text = path.read_text(encoding="utf-8", errors="replace")
        rel = relposix(root, path)
        for pattern, reason, allow_globs in phrases:
            matches = list(pattern.finditer(text))
            pinned: int | None = None
            for glob, count in allow_globs:
                if fnmatch.fnmatch(rel, glob):
                    pinned = count
                    break
            if pinned is None:
                # Not an allowlisted file for this phrase at all -- every
                # occurrence is a finding, as before.
                for m in matches:
                    line = text.count("\n", 0, m.start()) + 1
                    findings.append(
                        Finding(rel, line, f"forbidden phrase `{m.group(0)}`: {reason}", "forbidden-phrases")
                    )
                continue
            # Allowlisted file: still scanned, but only a count ABOVE the pin
            # is a finding (naming the first unexpected occurrence) -- a
            # count BELOW the pin is a separate finding that the pin is stale.
            actual = len(matches)
            if actual > pinned:
                first_excess = matches[pinned]
                line = text.count("\n", 0, first_excess.start()) + 1
                findings.append(
                    Finding(
                        rel, line,
                        f"forbidden phrase '{pattern.pattern}': {actual} occurrence(s) in "
                        f"an allowlisted file that pins {pinned} -- a new occurrence must "
                        f"be reviewed by hand, then the pin updated",
                        "forbidden-phrases",
                    )
                )
            elif actual < pinned:
                line = text.count("\n", 0, matches[-1].start()) + 1 if matches else 1
                findings.append(
                    Finding(
                        rel, line,
                        f"forbidden phrase '{pattern.pattern}': only {actual} occurrence(s) "
                        f"found but the pin in forbidden-phrases.txt says {pinned} -- stale "
                        f"pin, lower it",
                        "forbidden-phrases",
                    )
                )
    return findings


# ── Check 4: collapsed pairs ──────────────────────────────────────────────────

# Verbatim from docs/CONVENTIONS.md "Migration policy" (the `-P` backreference
# form; Python's `re` supports backreferences natively, no `-P` needed here).
COLLAPSED_PAIR_RE = re.compile(r"`(/[a-z][a-z-]*)`[^`]{0,40}`\1`")

# (relpath, matched text) -> reason. A command legitimately repeated in one
# sentence is common (docs/CONVENTIONS.md says so outright) -- read every hit
# by hand.
#
# Keyed on the MATCHED TEXT, never a line number. A line-pinned entry silently
# stops matching the moment anything above it is edited: these two entries were
# pinned to 214/220, an unrelated frontmatter removal shifted them to 212/218,
# and the check went red on prose nobody had touched. Anchoring to content
# means the exemption survives edits elsewhere and, better, stops applying if
# the sentence itself is ever rewritten -- which is exactly when a human should
# look again.
COLLAPSED_PAIR_ALLOWLIST: dict[tuple[str, str], str] = {
    ("copilot/skills/sdlc/SKILL.md",
     "`/sdlc-status` on pause) so `/sdlc-status`"):
        "legitimate repeat: '(`/repo-health` on complete; `/sdlc-status` on "
        "pause) so `/sdlc-status` recovers the handoff' -- both mentions of "
        "/sdlc-status refer to the same command's real behavior, not a "
        "collapsed rename pair",
    ("codex/skills/sdlc/SKILL.md",
     "`/sdlc-status` on pause) so\n`/sdlc-status`"):
        "same legitimate repeat as the copilot overlay above: both mentions "
        "of /sdlc-status refer to the same command's real behavior, not a "
        "collapsed rename pair",
}


def check_collapsed_pairs(files: list[Path], root: Path) -> list[Finding]:
    findings: list[Finding] = []
    for path in files:
        text = path.read_text(encoding="utf-8", errors="replace")
        rel = relposix(root, path)
        # No docs/ exclusion here: this check runs over scope_files(), which
        # never includes docs/ (only skills/, copilot/, codex/, agents/,
        # templates/*.template) -- so a docs/archive|gap-analysis exclusion
        # could never fire and was removed as dead code carried over from the
        # CONVENTIONS.md manual-grep recipe.
        for m in COLLAPSED_PAIR_RE.finditer(text):
            line = text.count("\n", 0, m.start()) + 1
            if (rel, m.group(0)) in COLLAPSED_PAIR_ALLOWLIST:
                continue
            findings.append(
                Finding(rel, line, f"same command named twice: `{m.group(0)}`", "collapsed-pairs")
            )
    return findings


# ── Check 5: portable frontmatter (overlay-only) ─────────────────────────────

# The Agent Skills portable frontmatter subset documented by GitHub Copilot and
# OpenAI Codex. Claude Code additionally supports keys like `argument-hint` and
# `disable-model-invocation` -- legitimate on the CANONICAL skills/*/SKILL.md
# (the Claude install source, which setup.sh's strip_nonportable_frontmatter
# strips only for the Copilot/Codex install paths) but never on the
# copilot/skills/ or codex/skills/ overlay files a maintainer hand-edits,
# because a strict Copilot/Codex consumer hard-errors on an unknown key.
PORTABLE_FRONTMATTER_KEYS = {
    "name", "description", "license", "metadata", "compatibility", "allowed-tools",
}

# Only a true top-level key: no leading whitespace before the identifier, so an
# indented nested key (e.g. `  brainstorm-toolkit-applies-to:` under `metadata:`)
# is never mistaken for one, and a folded-scalar continuation line under
# `description: >` (also indented) is never mistaken for one either.
FRONTMATTER_TOPLEVEL_KEY_RE = re.compile(r"^([A-Za-z][A-Za-z0-9_-]*):", re.MULTILINE)

FRONTMATTER_BLOCK_RE = re.compile(r"\A---\n(.*?)\n---\n", re.DOTALL)


def overlay_skill_files(root: Path) -> list[Path]:
    """copilot/skills/*/SKILL.md and codex/skills/*/SKILL.md only -- the two
    hand-edited overlay trees. skills/*/SKILL.md (canonical, the Claude install
    source) legitimately keeps Claude-only keys and must never be flagged."""
    files: list[Path] = []
    for base in ("copilot", "codex"):
        d = root / base / "skills"
        if d.is_dir():
            files.extend(sorted(d.glob("*/SKILL.md")))
    return files


def check_portable_frontmatter(files: list[Path], root: Path) -> list[Finding]:
    findings: list[Finding] = []
    for path in files:
        text = path.read_text(encoding="utf-8", errors="replace")
        m = FRONTMATTER_BLOCK_RE.match(text)
        if not m:
            continue
        frontmatter = m.group(1)
        fm_offset = m.start(1)
        rel = relposix(root, path)
        for key_m in FRONTMATTER_TOPLEVEL_KEY_RE.finditer(frontmatter):
            key = key_m.group(1)
            if key in PORTABLE_FRONTMATTER_KEYS:
                continue
            line = text.count("\n", 0, fm_offset + key_m.start()) + 1
            findings.append(
                Finding(
                    rel, line,
                    f"frontmatter key `{key}` is outside the Agent Skills portable "
                    "subset (name/description/license/metadata/compatibility/"
                    "allowed-tools) -- Copilot/Codex overlays must not carry "
                    "Claude-only keys",
                    "portable-frontmatter",
                )
            )
    return findings


# ── Check 6: doc status markers (docs/*.md only) ─────────────────────────────

# Step 1's loophole-closer (b): pin the COUNT of historical docs/*.md files
# using the same `path/glob:N` idiom as forbidden-phrases.txt's allow-glob
# column -- a third historical doc appearing is then a visible, reviewed
# diff (raise this pin) rather than a silent addition to the exemption.
HISTORICAL_DOC_GLOB = "docs/*.md"
HISTORICAL_DOC_PINNED_COUNT = 2


def check_doc_status_markers(files: list[Path], root: Path) -> list[Finding]:
    """Step 1: every docs/*.md declares `Live contract` or `Historical
    design record` in its header. A historical marker is never a free pass:
    (a) it must carry a pointer to the live contract that superseded it, and
    the pointer must resolve (docs/FLOW.md:105's see-also entry models the
    shape: "the stage shipped; its live contract is `skills/...`"); (b) the
    COUNT of historical docs is pinned (`HISTORICAL_DOC_PINNED_COUNT`), so
    review, not a silent grep, is what lets that count change."""
    findings: list[Finding] = []
    historical_count = 0
    for path in files:
        rel = relposix(root, path)
        header = _doc_header(path)
        is_live = bool(DOC_STATUS_LIVE_RE.search(header))
        is_historical = bool(DOC_STATUS_HISTORICAL_RE.search(header))
        if not is_live and not is_historical:
            findings.append(
                Finding(
                    rel, 1,
                    "no `Live contract` / `Historical design record` status "
                    f"marker in the header (first {DOC_STATUS_HEADER_LINES} lines)",
                    "doc-status-markers",
                )
            )
            continue
        if is_historical:
            historical_count += 1
            pointer_ok = any(
                citation_resolves(root, path, m.group(1))
                for m in CITATION_RE.finditer(header)
            )
            if not pointer_ok:
                findings.append(
                    Finding(
                        rel, 1,
                        "`Historical design record` marker has no resolving "
                        "pointer (in the header) to the live contract that "
                        "superseded it",
                        "doc-status-markers",
                    )
                )
    if historical_count > HISTORICAL_DOC_PINNED_COUNT:
        findings.append(
            Finding(
                HISTORICAL_DOC_GLOB, 0,
                f"{historical_count} docs/*.md file(s) now carry the "
                "`Historical design record` marker but check_contracts.py's "
                f"HISTORICAL_DOC_PINNED_COUNT says {HISTORICAL_DOC_PINNED_COUNT} "
                "-- review the new one by hand, then raise the pin",
                "doc-status-markers",
            )
        )
    elif historical_count < HISTORICAL_DOC_PINNED_COUNT:
        findings.append(
            Finding(
                HISTORICAL_DOC_GLOB, 0,
                f"only {historical_count} docs/*.md file(s) carry the "
                "`Historical design record` marker but the pin says "
                f"{HISTORICAL_DOC_PINNED_COUNT} -- stale pin, lower it",
                "doc-status-markers",
            )
        )
    return findings


# ── Check 7: no-cardinality (narrowed) ───────────────────────────────────────

# Number-words only (`one`..`twenty`) -- the digit form (`5 hooks`) measured
# 7 hits in CLAUDE.md + docs/*.md with 0 real defects and is left alone.
NUMBER_WORDS: dict[str, int] = {
    "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
    "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
    "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
    "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    "twenty": 20,
}
# The four nouns a derivable count actually goes stale for. NOT "corruptions"
# et al -- docs/CONVENTIONS.md's "Six corruptions have shipped this way" is a
# historical tally that is the point of its sentence, and staying off that
# noun is how this check avoids flagging it without needing to know the
# sentence is historical.
CARDINALITY_NOUNS = ("checks", "hooks", "skills", "agents")
CARDINALITY_RE = re.compile(
    rf"\b({'|'.join(NUMBER_WORDS)})\s+({'|'.join(CARDINALITY_NOUNS)})\b",
    re.IGNORECASE,
)

FENCE_LINE_RE = re.compile(r"^\s*```")


def strip_code_fences(text: str) -> str:
    """Blank fenced code-block bodies (and their ``` delimiter lines) while
    preserving line numbers -- check_contracts.py has no fenced-code
    stripper today; no-cardinality is the first check that needs one (a
    fenced shell example naming a count is not a prose claim)."""
    out: list[str] = []
    in_fence = False
    for line in text.split("\n"):
        if FENCE_LINE_RE.match(line):
            in_fence = not in_fence
            out.append("")
            continue
        out.append("" if in_fence else line)
    return "\n".join(out)


def cardinality_scope_files(root: Path) -> list[Path]:
    """no-cardinality's scope, per the plan: CLAUDE.md, AGENTS.md, and
    `Live contract` docs/*.md only -- never a `Historical design record` doc
    (a frozen tally is the point there) and never README.md (its one
    numbered claim is checked for list-length consistency instead, by
    check_header_list_counts, because deleting the number there would make
    the sentence worse)."""
    files: list[Path] = []
    for name in ("CLAUDE.md", "AGENTS.md"):
        f = root / name
        if f.is_file():
            files.append(f)
    files.extend(f for f in docs_status_files(root) if not is_historical_doc(f))
    return files


# Same shape as COLLAPSED_PAIR_ALLOWLIST: keyed on the MATCHED TEXT (lowered),
# never a line number, so an unrelated edit above it can't silently stop the
# exemption from applying. At ~50% measured precision this check WILL flag
# stable, correct counts -- each entry here was read by hand and is a fixed
# fact (a fixed-size enumeration named in the same sentence, or a specific
# case study), never a live check/hook/skill/agent count that could drift.
NO_CARDINALITY_ALLOWLIST: dict[tuple[str, str], str] = {
    ("CLAUDE.md", "two checks"): "the Migration policy grep pair enumerated "
        "immediately below (1. collapsed pairs, 2. the fact the rename "
        "invalidated) -- a fixed, numbered list, not a check_contracts.py "
        "check count",
    ("AGENTS.md", "two checks"): "same as CLAUDE.md (byte-identical) -- the "
        "Migration policy grep pair",
    ("docs/CONVENTIONS.md", "two checks"): "the canonical source of the same "
        "Migration policy grep pair CLAUDE.md/AGENTS.md mirror",
    ("docs/FLOW.md", "three agents"): "the toolkit's three target runtimes, "
        "named in the same sentence (Claude Code, GitHub Copilot, OpenAI "
        "Codex) -- a structural fact, not a driftable check/hook/skill/agent "
        "count",
    ("docs/PROSE-FIDELITY.md", "two skills"): "the two specific dogfood runs "
        "the case study is about, named in the two bullets immediately "
        "below -- a fixed anecdote, not a live count",
}


def check_cardinality_claims(files: list[Path], root: Path) -> list[Finding]:
    findings: list[Finding] = []
    for path in files:
        raw = path.read_text(encoding="utf-8", errors="replace")
        text = strip_code_fences(raw)
        rel = relposix(root, path)
        for m in CARDINALITY_RE.finditer(text):
            if (rel, m.group(0).lower()) in NO_CARDINALITY_ALLOWLIST:
                continue
            line = text.count("\n", 0, m.start()) + 1
            findings.append(
                Finding(
                    rel, line,
                    f"derivable count `{m.group(0)}` in prose -- counts drift "
                    "with no local edit to catch it; state the fact without "
                    "the number, or let a list/table carry the count instead",
                    "no-cardinality",
                )
            )
    return findings


# ── Check 8: header-list-count (README.md only) ──────────────────────────────


def header_list_scope_files(root: Path) -> list[Path]:
    """README.md only -- the one site the plan asks this mechanism to cover
    (`It also wires five hooks` above exactly five bullets)."""
    readme = root / "README.md"
    return [readme] if readme.is_file() else []


def check_header_list_counts(files: list[Path], root: Path) -> list[Finding]:
    """Where check 7's pattern is immediately followed (after at most one
    blank line) by a run of `- ` bullets -- README.md's "It also wires five
    hooks" above exactly five bullets -- assert header count == list length
    instead of banning the number: deleting it there would make the
    sentence worse, since the list is right there to keep it honest."""
    findings: list[Finding] = []
    for path in files:
        text = strip_code_fences(path.read_text(encoding="utf-8", errors="replace"))
        lines = text.split("\n")
        rel = relposix(root, path)
        for i, line in enumerate(lines):
            if line.lstrip().startswith("- "):
                continue  # a header for a sub-list is prose, not itself a
                # bullet in some larger, unrelated list (README's own
                # scripts-reference list is exactly this shape)
            m = CARDINALITY_RE.search(line)
            if not m:
                continue
            expected = NUMBER_WORDS[m.group(1).lower()]
            j = i + 1
            while j < len(lines) and lines[j].strip() == "":
                j += 1
            count = 0
            while j < len(lines) and lines[j].lstrip().startswith("- "):
                count += 1
                j += 1
            if count == 0 or count == expected:
                continue  # not list-shaped, or already consistent
            findings.append(
                Finding(
                    rel, i + 1,
                    f"header says '{m.group(0)}' but the following list has "
                    f"{count} item(s)",
                    "header-list-count",
                )
            )
    return findings


# ── portable-invocation (Windows-safe shipped commands) ─────────────────────
#
# Two deterministic rules, both about a command a consumer would copy-paste
# or a hook would literally exec:
#
#   (a) no bare `python3 ` invocation in shipped skill/agent/template prose --
#       `python3` is commonly a Microsoft Store stub on Windows that resolves
#       on PATH and then fails (see scripts/py.sh, GOTCHAS.md). This never
#       touches scripts/*.sh's own `for c in python3 python py; do ...` probe
#       idiom: scope_files() does not walk scripts/ at all, only the shipped
#       prose trees every other check in this file already scans.
#   (b) every hooks/hooks.json `command` starts with an interpreter token
#       (`bash`, `python`, ...), never a bare path -- a `.sh`/`.py` path is
#       not directly executable on Windows without the interpreter naming it.

BARE_PYTHON3_RE = re.compile(r"\bpython3 ")

# EXACT-STRING allowlist, same shape as CITATION_ALLOWLIST /
# COLLAPSED_PAIR_ALLOWLIST: (file, 1-based line) pairs whose `python3 ` names
# the anti-pattern in prose (warning against it, or narrating the probe
# order) rather than a bare invocation a consumer would copy verbatim. Empty
# today -- add an entry here, never widen the regex, if a future edit needs
# one.
BARE_PYTHON3_ALLOWLIST: dict[tuple[str, int], str] = {}


def check_bare_python3(files: list[Path], root: Path) -> list[Finding]:
    findings: list[Finding] = []
    for path in files:
        text = path.read_text(encoding="utf-8", errors="replace")
        rel = relposix(root, path)
        for m in BARE_PYTHON3_RE.finditer(text):
            line = text.count("\n", 0, m.start()) + 1
            if (rel, line) in BARE_PYTHON3_ALLOWLIST:
                continue
            findings.append(
                Finding(
                    rel, line,
                    "bare `python3 ` invocation -- python3 is commonly a "
                    "Microsoft Store stub on Windows that resolves on PATH "
                    "and then fails; route through `bash scripts/py.sh` or "
                    "name the python3/python/py probe idiom instead",
                    "portable-invocation",
                )
            )
    return findings


# Interpreter tokens a hooks/hooks.json `command` may start with -- the same
# probe set scripts/py.sh uses (python3/python/py) plus bash/sh, the only
# interpreters any shipped hook command names today.
HOOK_INTERPRETER_TOKENS = {"bash", "sh", "python3", "python", "py"}

# `"command": "<value>"` with the value's escaped-quote content captured raw
# (`(?:[^"\\]|\\.)*`, the standard JSON-string-body pattern) -- read as text
# with a line count, matching this file's own regex+line-count idiom, rather
# than json.loads()-ing the whole tree and losing position information.
HOOKS_JSON_COMMAND_RE = re.compile(r'"command"\s*:\s*"((?:[^"\\]|\\.)*)"')


def check_hooks_json_interpreter(root: Path) -> list[Finding]:
    hooks_json = root / "hooks" / "hooks.json"
    if not hooks_json.is_file():
        return []
    text = hooks_json.read_text(encoding="utf-8", errors="replace")
    rel = relposix(root, hooks_json)
    findings: list[Finding] = []
    for m in HOOKS_JSON_COMMAND_RE.finditer(text):
        try:
            command = json.loads(f'"{m.group(1)}"')
        except json.JSONDecodeError:
            command = m.group(1)
        token = command.strip().strip("\"'").split(None, 1)[0] if command.strip() else ""
        if token in HOOK_INTERPRETER_TOKENS:
            continue
        line = text.count("\n", 0, m.start()) + 1
        findings.append(
            Finding(
                rel, line,
                f"hooks.json command `{command}` does not start with an "
                "interpreter token (bash/sh/python/python3/py) -- a bare "
                "path is not directly executable on Windows",
                "portable-invocation",
            )
        )
    return findings


# ── recheck-by pins (warn-only, never contributes to the exit code) ─────────

RECHECK_BY_RE = re.compile(
    r'<!--\s*assert-manual:\s*recheck-by\s+(\d{4}-\d{2}-\d{2})\s+"([^"]*)"\s*-->'
)


def recheck_by_scope_files(root: Path) -> list[Path]:
    """CLAUDE.md, AGENTS.md, docs/*.md -- the pin's declared home per the
    plan. A claim about the outside world is read by a maintainer, not
    re-read by a stage template on every /sdlc run, so this stays narrower
    than scope_files()'s skills/copilot/codex tree."""
    files: list[Path] = []
    for name in ("CLAUDE.md", "AGENTS.md"):
        f = root / name
        if f.is_file():
            files.append(f)
    files.extend(docs_status_files(root))
    return files


def recheck_by_warnings(root: Path, today: date | None = None) -> list[str]:
    """Step 3: `<!-- assert-manual: recheck-by YYYY-MM-DD "<claim>" -->` pins
    a claim about something outside this repo that no local diff can
    invalidate. Permanent WARN, never a failure -- mirrors
    `model_cap_pointer_warnings()` in validate_skills.py, this repo's own
    precedent for a soft warning: check_contracts.py exits 1 on any finding
    and runs in `setup-roundtrip`, so a date-triggered failure would be
    indistinguishable from a real contract break and would train people to
    ignore both."""
    today = today or date.today()
    warnings: list[str] = []
    for path in recheck_by_scope_files(root):
        text = path.read_text(encoding="utf-8", errors="replace")
        rel = relposix(root, path)
        for m in RECHECK_BY_RE.finditer(text):
            due = date.fromisoformat(m.group(1))
            if due >= today:
                continue
            line = text.count("\n", 0, m.start()) + 1
            warnings.append(
                f'{rel}:{line}: recheck-by {due.isoformat()} expired -- '
                f'reverify: "{m.group(2)}"'
            )
    return warnings


# ── Runner ────────────────────────────────────────────────────────────────────


# Content that is SHIPPED to a consumer. A change under any of these is a
# change to what an installed plugin actually runs.
SHIPPED_GLOBS = ("skills", "agents", "copilot", "codex", "templates", "scripts")

# setup.sh:288-294 copies the whole `scripts/` tree and then strips these two
# paths back out (scripts/ci/ tests THIS repo's installer, sync-global.sh
# installs FROM this repo -- neither ships to a consumer). Excluded here via
# git pathspec magic so a change to scripts/ci/check_contracts.py itself does
# not demand a version bump it doesn't deserve.
SCRIPTS_NOT_SHIPPED = (":(exclude)scripts/ci", ":(exclude)scripts/sync-global.sh")


def check_version_freshness(root: Path) -> list[Finding]:
    """Fail when shipped content moved but `version` did not.

    Claude Code caches an installed plugin under `<marketplace>/<plugin>/<version>/`
    and keys freshness off that version string. Ship new skills under an
    unchanged version and the cache never refreshes: the consumer keeps running
    the old prose, silently, with no error anywhere.

    This is not hypothetical. On 2026-09-11 the local install was found pinned
    at gitCommitSha 21099d9 with a three-week-old `sdlc/SKILL.md` (1,069 lines
    against the repo's 327) and a renamed agent the registry still exposed under
    its old name -- eight commits of drift behind a `version` that never moved.
    Nothing caught it, because nothing looked.
    """
    plugin_json = root / ".claude-plugin" / "plugin.json"
    if not plugin_json.is_file():
        return []

    def git(*args: str) -> str:
        try:
            r = subprocess.run(["git", *args], cwd=str(root), capture_output=True,
                               text=True, encoding="utf-8", errors="replace", timeout=20)
        except (OSError, subprocess.SubprocessError):
            return ""
        return r.stdout.strip() if r.returncode == 0 else ""

    # A shallow (depth-limited) checkout -- e.g. actions/checkout@v4's default --
    # makes this check unreliable rather than merely empty: the truncated boundary
    # commit reads to git as adding the whole file from scratch, so `-L` can find a
    # "version_commit" (the boundary commit itself) even though the real history is
    # missing. That collapses the version_commit..HEAD range and lets shipped-but-
    # unbumped changes pass with ZERO findings instead of skipping loudly. Detected
    # directly via `rev-parse --is-shallow-repository` rather than relying on
    # version_commit failing to resolve, which this scenario does not reproduce.
    if git("rev-parse", "--is-shallow-repository") == "true":
        msg = "version-freshness: skipped -- shallow clone, cannot see history"
        print(msg, file=sys.stderr)
        if os.environ.get("GITHUB_ACTIONS"):
            print(f"::warning::{msg}", file=sys.stderr)
        return []

    # The commit that last CHANGED the version string, not merely touched the file.
    version_commit = ""
    log = git("log", "--format=%H", "-L", "/\"version\"/,+1:.claude-plugin/plugin.json")
    if log:
        version_commit = log.splitlines()[0].strip()
    if not version_commit:
        # No git, or an unparseable repo -- do not invent a failure. A shallow
        # clone is handled above, before this can be reached via that path.
        return []

    ts = git("show", "-s", "--format=%ct", version_commit)
    if not ts.isdigit():
        return []
    version_ts = int(ts)

    newer: list[str] = []
    for glob in SHIPPED_GLOBS:
        if not (root / glob).exists():
            continue
        pathspecs = (glob, *SCRIPTS_NOT_SHIPPED) if glob == "scripts" else (glob,)
        out = git("log", "--format=%H %ct", "-1", version_commit + "..HEAD", "--", *pathspecs)
        if out:
            parts = out.split()
            if len(parts) == 2 and parts[1].isdigit() and int(parts[1]) > version_ts:
                newer.append(glob)
    if not newer:
        return []
    return [Finding(
        path=".claude-plugin/plugin.json", line=1,
        message=(
            "shipped content changed after the last version bump ("
            + ", ".join(sorted(newer))
            + "). A consumer's plugin cache is keyed by version, so it will keep "
              "serving the OLD skills with no error. Bump `version` in "
              ".claude-plugin/plugin.json AND .claude-plugin/marketplace.json."
        ),
        check="version-freshness",
    )]


def run_all(root: Path, phrases_file: Path) -> dict[str, list[Finding]]:
    files = scope_files(root)
    cite_files = citation_scope_files(root)
    load_files = load_only_scope_files(root)
    doc_files = docs_status_files(root)
    registry = load_registry(root)
    phrases = load_forbidden_phrases(phrases_file)

    return {
        "config-keys": check_config_keys(files, root, registry),
        "citations": check_citations(cite_files, root) + check_docs_load_vs_cite(load_files, root),
        "forbidden-phrases": check_forbidden_phrases(files, root, phrases),
        "collapsed-pairs": check_collapsed_pairs(files, root),
        "portable-frontmatter": check_portable_frontmatter(overlay_skill_files(root), root),
        "version-freshness": check_version_freshness(root),
        "doc-status-markers": check_doc_status_markers(doc_files, root),
        "no-cardinality": check_cardinality_claims(cardinality_scope_files(root), root),
        "header-list-count": check_header_list_counts(header_list_scope_files(root), root),
        "portable-invocation": check_bare_python3(files, root) + check_hooks_json_interpreter(root),
    }


def print_report(
    results: dict[str, list[Finding]], as_json: bool, warnings: list[str] | None = None,
) -> int:
    warnings = warnings or []
    total = sum(len(v) for v in results.values())
    if as_json:
        payload = {
            check: [f._asdict() for f in findings] for check, findings in results.items()
        }
        payload["total"] = total
        payload["recheck-by-warnings"] = warnings
        print(json.dumps(payload, indent=2))
        return 1 if total else 0

    for check, findings in results.items():
        print(f"{check}: {len(findings)} finding(s)")
        for f in findings:
            print(f"  {f.path}:{f.line}: {f.message}")

    if warnings:
        # Permanent WARN, never contributes to `total` or the exit code --
        # see recheck_by_warnings()'s docstring.
        print(f"\nrecheck-by warnings: {len(warnings)} (does not affect exit code)")
        for w in warnings:
            print(f"  {w}")

    if total:
        print(f"\n{total} total finding(s) across {len(results)} checks")
        return 1
    print("\nall contract checks pass")
    return 0


# ── --self-test ───────────────────────────────────────────────────────────────

SELF_TEST_REGISTRY = {
    "_comment": "synthetic registry for --self-test",
    "models": {"cap": "sonnet"},
    "gotchas_file": "GOTCHAS.md",
}

SELF_TEST_PHRASES = "badphrase\tthis phrase is dead, seeded for --self-test\n"

SELF_TEST_SKILL_MD = """---
name: testskill
description: synthetic skill for check_contracts.py --self-test
metadata:
  brainstorm-toolkit-applies-to: claude
---

# Test skill

One bad config key: `models.totally_bogus_key`.

One bad citation: `templates/does-not-exist-xyz.md`.

One bad PREFIXED citation (Step 11: must still be reported): `bash scripts/does-not-exist-prefixed.sh`.

One good PREFIXED citation (Step 11: resolves, must NOT be reported): `bash skills/testskill/SKILL.md`.

One forbidden phrase: badphrase appears right here.

One collapsed pair: use `/foo` to do a thing, then use `/foo` again.
"""

# Portable-frontmatter case: a synthetic Copilot overlay carrying a Claude-only
# key. Lives under copilot/skills/ in the same self_test() tree (not skills/)
# because the check only scans the two hand-edited overlay trees.
SELF_TEST_OVERLAY_SKILL_MD = """---
name: testoverlay
description: synthetic Copilot overlay skill for check_contracts.py --self-test
argument-hint: "[foo] - bogus Claude-only key seeded for --self-test"
metadata:
  brainstorm-toolkit-applies-to: copilot
---

# Test overlay skill
"""

# Fifth assertion: an allowlisted file with MORE occurrences than its pin
# must produce exactly one finding (naming the first excess occurrence),
# not one finding per occurrence and not zero. Built in its own temp tree so
# it can't perturb the four expectations above.
COUNT_BASELINE_PHRASES = (
    "counted phrase\tseeded reason for the count-baseline self-test\t"
    "skills/counttest/SKILL.md:1\n"
)

COUNT_BASELINE_SKILL_MD = """---
name: counttest
description: synthetic skill for check_contracts.py --self-test count-baseline case
metadata:
  brainstorm-toolkit-applies-to: claude
---

# Count baseline test skill

This skill's forbidden-phrases pin is 1, but the text below says it once
(counted phrase), then says it again (counted phrase) -- two occurrences
against a pin of one.
"""


def self_test_count_baseline() -> bool:
    with tempfile.TemporaryDirectory(prefix="check_contracts_selftest_count_") as tmp:
        root = Path(tmp)
        skill_dir = root / "skills" / "counttest"
        skill_dir.mkdir(parents=True)
        (skill_dir / "SKILL.md").write_text(COUNT_BASELINE_SKILL_MD, encoding="utf-8")
        phrases_file = root / "forbidden-phrases.txt"
        phrases_file.write_text(COUNT_BASELINE_PHRASES, encoding="utf-8")

        phrases = load_forbidden_phrases(phrases_file)
        findings = check_forbidden_phrases(scope_files(root), root, phrases)

    ok = len(findings) == 1
    status = "OK" if ok else "FAIL"
    print(
        f"[{status}] forbidden-phrases count-baseline: expected 1 violation(s) "
        f"(2 occurrences vs. a pin of 1), caught {len(findings)}"
    )
    for f in findings:
        print(f"    {f.path}:{f.line}: {f.message}")
    return ok


def self_test_doc_status_markers() -> bool:
    """Step 1, primary case: a `Live contract` doc and two `Historical
    design record` docs with a resolving pointer (matching the real
    HISTORICAL_DOC_PINNED_COUNT of 2, so the count check stays quiet) all
    pass silently; a doc with no status marker at all is the seeded
    violation."""
    with tempfile.TemporaryDirectory(prefix="check_contracts_selftest_docstatus_") as tmp:
        root = Path(tmp)
        docs_dir = root / "docs"
        docs_dir.mkdir(parents=True)
        target_dir = root / "skills" / "target"
        target_dir.mkdir(parents=True)
        (target_dir / "live.md").write_text("the live contract target\n", encoding="utf-8")

        (docs_dir / "LIVE.md").write_text(
            "# A live doc\n\n> **Live contract.**\n\nBody text.\n", encoding="utf-8"
        )
        (docs_dir / "HIST-A.md").write_text(
            "# Historical A\n\n> **Historical design record.** Its live "
            "contract is `skills/target/live.md`.\n", encoding="utf-8",
        )
        (docs_dir / "HIST-B.md").write_text(
            "# Historical B\n\n> **Historical design record.** Its live "
            "contract is `skills/target/live.md`.\n", encoding="utf-8",
        )
        (docs_dir / "NO-MARKER.md").write_text(
            "# No marker at all\n\nJust prose, no status line.\n", encoding="utf-8",
        )

        findings = check_doc_status_markers(docs_status_files(root), root)

    ok = len(findings) == 1 and findings[0].path == "docs/NO-MARKER.md"
    status = "OK" if ok else "FAIL"
    print(
        f"[{status}] doc-status-markers: expected 1 violation(s) (missing "
        f"status marker), caught {len(findings)}"
    )
    for f in findings:
        print(f"    {f.path}:{f.line}: {f.message}")
    return ok


def self_test_doc_status_pointer() -> bool:
    """Step 1, loophole-closer (a): a `Historical design record` marker with
    NO resolving pointer is caught -- even though the total historical count
    (2) still matches the real pin, isolating this from the count check."""
    with tempfile.TemporaryDirectory(prefix="check_contracts_selftest_docptr_") as tmp:
        root = Path(tmp)
        docs_dir = root / "docs"
        docs_dir.mkdir(parents=True)
        (docs_dir / "HIST-OK.md").write_text(
            "# Historical, pointer resolves\n\n> **Historical design "
            "record.** Its live contract is `docs/HIST-OK.md`.\n",
            encoding="utf-8",
        )
        (docs_dir / "HIST-DANGLING.md").write_text(
            "# Historical, pointer dangles\n\n> **Historical design "
            "record.** Its live contract is `skills/does-not-exist/x.md`.\n",
            encoding="utf-8",
        )
        findings = check_doc_status_markers(docs_status_files(root), root)

    ok = len(findings) == 1 and findings[0].path == "docs/HIST-DANGLING.md"
    status = "OK" if ok else "FAIL"
    print(
        f"[{status}] doc-status-markers pointer: expected 1 violation(s) "
        f"(dangling live-contract pointer), caught {len(findings)}"
    )
    for f in findings:
        print(f"    {f.path}:{f.line}: {f.message}")
    return ok


def self_test_doc_status_count() -> bool:
    """Step 1, loophole-closer (b): a THIRD well-formed historical doc (all
    three pointers resolve, so no per-file finding fires) still trips the
    pinned-count check -- adding one must be a visible, reviewed diff."""
    with tempfile.TemporaryDirectory(prefix="check_contracts_selftest_doccount_") as tmp:
        root = Path(tmp)
        docs_dir = root / "docs"
        docs_dir.mkdir(parents=True)
        for name in ("HIST-A.md", "HIST-B.md", "HIST-C.md"):
            (docs_dir / name).write_text(
                f"# {name}\n\n> **Historical design record.** Its live "
                f"contract is `docs/{name}`.\n", encoding="utf-8",
            )
        findings = check_doc_status_markers(docs_status_files(root), root)

    ok = len(findings) == 1 and "3 docs/*.md file(s)" in findings[0].message
    status = "OK" if ok else "FAIL"
    print(
        f"[{status}] doc-status-markers count pin: expected 1 violation(s) "
        f"(3 historical docs against a pin of {HISTORICAL_DOC_PINNED_COUNT}), "
        f"caught {len(findings)}"
    )
    for f in findings:
        print(f"    {f.path}:{f.line}: {f.message}")
    return ok


def self_test_no_cardinality() -> bool:
    """Step 4: a number-word directly before a target noun is caught in
    prose; the same phrase inside a fenced code block is not (the fenced-
    code stripper this check introduces)."""
    with tempfile.TemporaryDirectory(prefix="check_contracts_selftest_card_") as tmp:
        root = Path(tmp)
        (root / "CLAUDE.md").write_text(
            "# Test\n\n"
            "There are four skills that matter here.\n\n"
            "```bash\n"
            "# five hooks inside a fence must never be flagged\n"
            "```\n",
            encoding="utf-8",
        )
        findings = check_cardinality_claims(cardinality_scope_files(root), root)

    ok = len(findings) == 1 and "four skills" in findings[0].message
    status = "OK" if ok else "FAIL"
    print(
        f"[{status}] no-cardinality: expected 1 violation(s) (prose count, "
        f"fenced one excluded), caught {len(findings)}"
    )
    for f in findings:
        print(f"    {f.path}:{f.line}: {f.message}")
    return ok


def self_test_header_list_count() -> bool:
    """Step 4's paired consistency check: a numbered header immediately
    followed by a mismatched bullet list is caught (README's real 'five
    hooks' / five-bullets site is the one this models -- there, the numbers
    genuinely match, so nothing should ever fire)."""
    with tempfile.TemporaryDirectory(prefix="check_contracts_selftest_hlc_") as tmp:
        root = Path(tmp)
        (root / "README.md").write_text(
            "# Test\n\nIt wires three hooks:\n\n- one\n- two\n",
            encoding="utf-8",
        )
        findings = check_header_list_counts(header_list_scope_files(root), root)

    ok = len(findings) == 1 and "three hooks" in findings[0].message
    status = "OK" if ok else "FAIL"
    print(
        f"[{status}] header-list-count: expected 1 violation(s) (header "
        f"says three, list has two), caught {len(findings)}"
    )
    for f in findings:
        print(f"    {f.path}:{f.line}: {f.message}")
    return ok


def self_test_portable_invocation() -> bool:
    """Self-test for portable-invocation: one violation of each rule -- a
    bare `python3 ` invocation in shipped prose, and a hooks/hooks.json
    command that names a bare path instead of an interpreter token."""
    with tempfile.TemporaryDirectory(prefix="check_contracts_selftest_portinv_") as tmp:
        root = Path(tmp)
        skill_dir = root / "skills" / "testskill"
        skill_dir.mkdir(parents=True)
        (skill_dir / "SKILL.md").write_text(
            "---\nname: testskill\ndescription: synthetic\n---\n\n"
            "Run it with `python3 scripts/foo.py` to verify.\n",
            encoding="utf-8",
        )
        hooks_dir = root / "hooks"
        hooks_dir.mkdir(parents=True)
        (hooks_dir / "hooks.json").write_text(
            json.dumps({
                "hooks": {
                    "Stop": [{
                        "matcher": "*",
                        "hooks": [{
                            "type": "command",
                            "command": "\"${CLAUDE_PLUGIN_ROOT}/scripts/hooks/next-action.sh\"",
                        }],
                    }],
                },
            }, indent=2),
            encoding="utf-8",
        )
        findings = (
            check_bare_python3(scope_files(root), root)
            + check_hooks_json_interpreter(root)
        )

    python3_hits = [f for f in findings if "bare `python3 `" in f.message]
    hooks_hits = [f for f in findings if "hooks.json command" in f.message]
    ok = len(findings) == 2 and len(python3_hits) == 1 and len(hooks_hits) == 1
    status = "OK" if ok else "FAIL"
    print(
        f"[{status}] portable-invocation: expected 2 violation(s) (one bare "
        f"python3, one bare hooks.json path), caught {len(findings)}"
    )
    for f in findings:
        print(f"    {f.path}:{f.line}: {f.message}")
    return ok


def self_test() -> int:
    with tempfile.TemporaryDirectory(prefix="check_contracts_selftest_") as tmp:
        root = Path(tmp)
        (root / "templates").mkdir(parents=True)
        (root / "templates" / "project.json.example").write_text(
            json.dumps(SELF_TEST_REGISTRY, indent=2), encoding="utf-8"
        )
        skill_dir = root / "skills" / "testskill"
        skill_dir.mkdir(parents=True)
        (skill_dir / "SKILL.md").write_text(SELF_TEST_SKILL_MD, encoding="utf-8")
        overlay_skill_dir = root / "copilot" / "skills" / "testoverlay"
        overlay_skill_dir.mkdir(parents=True)
        (overlay_skill_dir / "SKILL.md").write_text(SELF_TEST_OVERLAY_SKILL_MD, encoding="utf-8")
        phrases_file = root / "forbidden-phrases.txt"
        phrases_file.write_text(SELF_TEST_PHRASES, encoding="utf-8")

        results = run_all(root, phrases_file)

    ok = True
    expectations = {
        "config-keys": 1,
        "citations": 2,
        "forbidden-phrases": 1,
        "collapsed-pairs": 1,
        "portable-frontmatter": 1,
    }
    for check, expected in expectations.items():
        found = results[check]
        status = "OK" if len(found) == expected else "FAIL"
        if len(found) != expected:
            ok = False
        print(f"[{status}] {check}: expected {expected} violation(s), caught {len(found)}")
        for f in found:
            print(f"    {f.path}:{f.line}: {f.message}")

    if not self_test_count_baseline():
        ok = False
    if not self_test_doc_status_markers():
        ok = False
    if not self_test_doc_status_pointer():
        ok = False
    if not self_test_doc_status_count():
        ok = False
    if not self_test_no_cardinality():
        ok = False
    if not self_test_header_list_count():
        ok = False
    if not self_test_portable_invocation():
        ok = False

    if not ok:
        print("\nself-test FAILED")
        return 1
    print("\nself-test passed: each check caught exactly its seeded violation")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    parser.add_argument(
        "--self-test", action="store_true",
        help="run the checks against a synthetic tree with one seeded violation per check",
    )
    args = parser.parse_args(argv)

    if args.self_test:
        return self_test()

    phrases_file = REPO_ROOT / "scripts" / "ci" / "forbidden-phrases.txt"
    results = run_all(REPO_ROOT, phrases_file)
    warnings = recheck_by_warnings(REPO_ROOT)
    return print_report(results, args.json, warnings)


if __name__ == "__main__":
    sys.exit(main())
