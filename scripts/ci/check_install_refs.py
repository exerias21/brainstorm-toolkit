#!/usr/bin/env python3
"""Verify every template citation in an INSTALLED toolkit tree actually resolves.

`validate_skills.py` checks the plugin repo. This checks what a consumer ends up with,
which is a different question: `setup.sh` installs a per-tool overlay *instead of* the
canonical skill tree, so a citation that resolves in the repo can dangle after install.

That gap shipped 21 dangling references to Copilot and Codex consumers, invisible to the
repo-side linter. This is the regression test for it.

Usage:
  bash setup.sh --target /tmp/probe --tools copilot
  python scripts/ci/check_install_refs.py /tmp/probe

Exit 0 if every citation resolves; 1 otherwise. Stdlib only.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# Both citation forms the repo uses:
#   `templates/<file>`                  -- skill-relative
#   `skills/<skill>/templates/<file>`   -- cross-skill (the shared sdlc templates)
# Also matches the per-tool rewritten forms setup.sh produces (.claude/, .github/, .agents/).
REF_RE = re.compile(
    r"`(?:\.(?:claude|github|agents)/)?((?:skills/[A-Za-z0-9._-]+/)?templates/[A-Za-z0-9_./-]+)`"
)

# Where each tool's skills land, in the order we try to resolve against.
TOOL_ROOTS = [".claude", ".github", ".agents"]


def resolve(target: Path, skill_dir: Path, ref: str) -> bool:
    """True if `ref` resolves from any plausible base in the installed tree."""
    candidates = [
        skill_dir / ref,                    # skill-relative: <skill>/templates/x.md
        skill_dir.parent / ref,             # sibling skill:  skills/<other>/templates/x.md
        target / ref,                       # repo-root form
    ]
    for root in TOOL_ROOTS:
        candidates.append(target / root / ref)
    return any(c.is_file() for c in candidates)


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    target = Path(sys.argv[1])
    if not target.is_dir():
        print(f"no such install tree: {target}", file=sys.stderr)
        return 2

    skill_files = []
    for root in TOOL_ROOTS:
        skill_files.extend(sorted((target / root).rglob("SKILL.md")))
    if not skill_files:
        print(f"no installed SKILL.md under {target} — did setup.sh run?", file=sys.stderr)
        return 2

    dangling = []
    checked = 0
    for sf in skill_files:
        body = sf.read_text(encoding="utf-8", errors="replace")
        for ref in sorted(set(REF_RE.findall(body))):
            checked += 1
            if not resolve(target, sf.parent, ref):
                dangling.append((sf.relative_to(target).as_posix(), ref))

    print(f"checked {checked} template citation(s) across {len(skill_files)} installed skill(s)")
    if dangling:
        print(f"\n{len(dangling)} DANGLING:")
        for sf, ref in dangling:
            print(f"  {sf}  ->  {ref}")
        return 1
    print("all citations resolve")
    return 0


if __name__ == "__main__":
    sys.exit(main())
