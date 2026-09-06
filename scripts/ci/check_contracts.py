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
import re
import sys
import tempfile
from pathlib import Path
from typing import NamedTuple

REPO_ROOT = Path(__file__).resolve().parents[2]

# ── Shared file-set walking convention (mirrors scripts/validate_skills.py) ──

SKILL_TREE_DIRS = ("skills", "copilot", "codex")

# Cross-Module Touchpoint (docs/plans/skill-evals-2-fixture-harness.md):
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


def scope_files(root: Path) -> list[Path]:
    """The file set every check but citations runs over: skills/**/*.md,
    copilot/**/*.md, codex/**/*.md, agents/*.md, templates/*.template."""
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
    return _exclude_fixtures(root, files)


def citation_scope_files(root: Path) -> list[Path]:
    """Citations additionally cover README.md (paths only, per the plan's
    Open Question: yes for paths, no for phrases)."""
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
    "coauthor_trailer", "modules",
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

CITATION_RE = re.compile(
    r"`((?:skills|scripts|templates|docs|agents|hooks|examples)/"
    r"[A-Za-z0-9_./-]+\.(?:md|py|sh|json|template|txt))`"
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


# ── Runner ────────────────────────────────────────────────────────────────────


def run_all(root: Path, phrases_file: Path) -> dict[str, list[Finding]]:
    files = scope_files(root)
    cite_files = citation_scope_files(root)
    load_files = load_only_scope_files(root)
    registry = load_registry(root)
    phrases = load_forbidden_phrases(phrases_file)

    return {
        "config-keys": check_config_keys(files, root, registry),
        "citations": check_citations(cite_files, root) + check_docs_load_vs_cite(load_files, root),
        "forbidden-phrases": check_forbidden_phrases(files, root, phrases),
        "collapsed-pairs": check_collapsed_pairs(files, root),
        "portable-frontmatter": check_portable_frontmatter(overlay_skill_files(root), root),
    }


def print_report(results: dict[str, list[Finding]], as_json: bool) -> int:
    total = sum(len(v) for v in results.values())
    if as_json:
        payload = {
            check: [f._asdict() for f in findings] for check, findings in results.items()
        }
        payload["total"] = total
        print(json.dumps(payload, indent=2))
        return 1 if total else 0

    for check, findings in results.items():
        print(f"{check}: {len(findings)} finding(s)")
        for f in findings:
            print(f"  {f.path}:{f.line}: {f.message}")

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
        "citations": 1,
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
    return print_report(results, args.json)


if __name__ == "__main__":
    sys.exit(main())
