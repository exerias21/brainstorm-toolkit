#!/usr/bin/env python3
"""Verify every template/references/scripts citation in an INSTALLED toolkit tree resolves.

`validate_skills.py` checks the plugin repo. This checks what a consumer ends up with,
which is a different question: `setup.sh` installs a per-tool overlay *instead of* the
canonical skill tree, so a citation that resolves in the repo can dangle after install.

That gap shipped 21 dangling template references to Copilot and Codex consumers, invisible
to the repo-side linter. This is the regression test for it.

It also covers a second, later-discovered gap in the same family: a skill citing its OWN
`scripts/` or `references/` files (or a sibling skill's) by a repo-root-relative path such as
`` `skills/docstring-sync/scripts/docstring_check.py` ``. That path only resolves inside this
plugin repo; `setup.sh` never installs a bare `skills/` directory into a consumer (it installs
to `.claude/skills/`, `.github/skills/`, `.agents/skills/`), so the citation is dead on arrival
for every consumer and every tool. The fix for a skill's own citations is a skill-relative or
sibling-relative path (see `skills/plan-html/SKILL.md`'s `` `templates/plan.html.template`
(sibling of this SKILL.md)`` convention, and `skills/docstring-sync/SKILL.md`'s `<skill-dir>/...`
placeholder for paths a Bash command needs resolved literally) — this script's job is only to
catch a regression, not to pick the fix.

Usage:
  bash setup.sh --target /tmp/probe --tools copilot
  python scripts/ci/check_install_refs.py /tmp/probe

Exit 0 if every citation resolves; 1 otherwise. Stdlib only.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# Citation forms the repo uses:
#   `templates/<file>`                            -- skill-relative
#   `skills/<skill>/templates/<file>`              -- cross-skill (the shared sdlc templates)
#   `skills/<skill>/references/<file>`             -- cross- or SELF-skill (the docstring-sync bug)
#   `skills/<skill>/scripts/<file>`                -- same, for a bundled script
# Also matches the per-tool rewritten forms setup.sh produces (.claude/, .github/, .agents/).
#
# references/ and scripts/ require the `skills/<name>/` prefix in this regex (unlike
# templates/, where it's optional) on purpose: a BARE `scripts/py.sh` or `scripts/hooks/x.sh`
# is the normal, correct way to cite the shared repo-root scripts/ tree (setup.sh copies it to
# the consumer's own repo root), and matching it here would flag hundreds of correct citations
# as dangling. The bug this regex exists to catch always carries the `skills/<name>/` prefix --
# that is what makes the path repo-root-relative-and-wrong instead of repo-root-relative-and-
# right. A skill's correct self-citation is the skill-relative or `<skill-dir>/...`-resolved
# form (bare `references/x.md`, `<skill-dir>/scripts/x.py`), which this regex does not match at
# all -- nothing to check there, which is the point: it's not a repo-root-relative claim.
#
# The tool prefix is its OWN capture group (group 1), not folded away, because a rewritten
# citation asserts a specific repo-root-relative path -- e.g. `.claude/templates/x.template`
# means "resolve at target/.claude/templates/x.template", nothing else. Stripping the prefix
# out of the match (as a prior version of this script did by leaving it outside any group)
# let `resolve()` silently re-derive the base from the skill dir instead, so a citation
# setup.sh rewrote to a now-nonexistent root-prefixed path could still resolve against the
# skill-local templates/ dir it used to (correctly) point at -- the exact shape of the
# `skills/plan-html/SKILL.md` `plan.html.template` mangle this script exists to catch.
REF_RE = re.compile(
    r"`((?:\.(?:claude|github|agents)/)?)("
    r"(?:skills/[A-Za-z0-9._-]+/)?templates/[A-Za-z0-9_./-]+"
    r"|skills/[A-Za-z0-9._-]+/(?:references|scripts)/[A-Za-z0-9_./-]+"
    r")`"
)

# Where each tool's skills land, in the order we try to resolve against.
TOOL_ROOTS = [".claude", ".github", ".agents"]

_TEMPLATES_RE = re.compile(r"(?:skills/[A-Za-z0-9._-]+/)?templates/")


def resolve(target: Path, skill_dir: Path, prefix: str, ref: str) -> bool:
    """True if `ref` resolves from a plausible base in the installed tree.

    A citation carrying a tool prefix (`.claude/`, `.github/`, `.agents/`) is an explicit
    repo-root-relative claim -- it must resolve at exactly `target/prefix/ref`. It is NOT
    allowed to fall back to the skill-local or sibling-skill bases below: those bases are
    what an UNPREFIXED citation resolves against, and honoring them for a prefixed one is
    what let a broken rewrite pass silently before.
    """
    if prefix:
        return (target / prefix / ref).is_file()
    if _TEMPLATES_RE.match(ref):
        # Unchanged leniency for templates/, which setup.sh's install_shared_templates
        # actively rewrites to carry an explicit prefix -- these multi-root fallbacks are a
        # backward-compat safety net for the mechanism that DOES make a cross-skill
        # templates/ citation resolve, not a model of a real agent's working directory.
        candidates = [
            skill_dir / ref,                    # skill-relative: <skill>/templates/x.md
            skill_dir.parent / ref,             # sibling skill:  skills/<other>/templates/x.md
            target / ref,                       # repo-root form
        ]
        for root in TOOL_ROOTS:
            candidates.append(target / root / ref)
        return any(c.is_file() for c in candidates)
    # references/ and scripts/ reaching here always carry the required `skills/<name>/`
    # prefix (the regex has no bare alternative for these two kinds) and setup.sh has NO
    # rewrite step for them -- install_shared_templates's sed matches only `templates/`. So
    # there is no real working directory in a setup.sh-installed consumer (or the plugin
    # cache, which preserves the same `skills/<name>/...` tree but is never rooted at a bare
    # `skills/`) where an unprefixed `skills/<name>/references|scripts/<file>` citation
    # resolves. Trying the multi-root fallback here would reconstruct a skill's OWN correct
    # installed path from its OWN full-form self-citation and wrongly call that a pass -- the
    # exact shape of the bug this branch exists to catch. Unconditionally dangling.
    return False


def skill_root_for(target: Path, root: str, f: Path) -> Path:
    """The installed skill directory that owns `f` (SKILL.md itself, or a file under its
    templates/ or references/). A SKILL.md citing its own `references/x.md` as `<skill-dir>/x`
    resolves against this -- NOT against `f.parent`, which for a `references/*.md` file is the
    references/ directory itself, one level too deep.
    """
    rel = f.relative_to(target / root / "skills")
    return target / root / "skills" / rel.parts[0]


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    target = Path(sys.argv[1])
    if not target.is_dir():
        print(f"no such install tree: {target}", file=sys.stderr)
        return 2

    # SKILL.md itself, plus the bundled prose it tells the model to read now
    # (templates/*.md, references/*.md) -- a citation can live in any of these, and the
    # docstring-sync bug this script now also checks for lived in a references/*.md file,
    # invisible to a prior version of this script that only ever opened SKILL.md. Each entry
    # carries its own tool root alongside the path, rather than re-deriving it later, since a
    # fresh `--tools all` install puts the same skill under all three roots at once.
    skill_files: list[tuple[str, Path]] = []
    for root in TOOL_ROOTS:
        base = target / root / "skills"
        if not base.is_dir():
            continue
        for pattern in ("SKILL.md", "templates/*.md", "references/*.md"):
            skill_files.extend((root, f) for f in sorted(base.rglob(pattern)))
    if not skill_files:
        print(f"no installed SKILL.md under {target} — did setup.sh run?", file=sys.stderr)
        return 2

    dangling = []
    checked = 0
    for root, sf in skill_files:
        skill_dir = skill_root_for(target, root, sf)
        body = sf.read_text(encoding="utf-8", errors="replace")
        for prefix, ref in sorted(set(REF_RE.findall(body))):
            checked += 1
            if not resolve(target, skill_dir, prefix, ref):
                dangling.append((sf.relative_to(target).as_posix(), prefix + ref))

    print(f"checked {checked} citation(s) across {len(skill_files)} installed skill/prose file(s)")
    if dangling:
        print(f"\n{len(dangling)} DANGLING:")
        for sf, ref in dangling:
            print(f"  {sf}  ->  {ref}")
        return 1
    print("all citations resolve")
    return 0


if __name__ == "__main__":
    sys.exit(main())
