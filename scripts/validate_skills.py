#!/usr/bin/env python3

from __future__ import annotations

import re
import sys
from pathlib import Path


FRONTMATTER_RE = re.compile(r"\A---\n(.*?)\n---\n(.*)\Z", re.DOTALL)
NAME_RE = re.compile(r"^name:\s*([a-z0-9-]+)\s*$", re.MULTILINE)
DESCRIPTION_RE = re.compile(r"^description:\s*(.+)\s*$", re.MULTILINE)
DISABLE_MODEL_INVOCATION_RE = re.compile(
    r"^disable-model-invocation:\s*true\s*$", re.MULTILINE
)
TARGETS_RE = re.compile(
    r"^[ \t]*(?:brainstorm-toolkit-applies-to|applies-to):\s*(.+?)\s*$",
    re.MULTILINE,
)

STRICT_AUTO_COPILOT_PATTERNS = [
    (re.compile(r"\bPlan mode\b", re.IGNORECASE), "mentions Plan mode"),
    (re.compile(r"\bAgent tool\b", re.IGNORECASE), "mentions the Agent tool"),
    (re.compile(r"\bAskUserQuestion\b"), "mentions AskUserQuestion"),
]

HARD_FORBIDDEN_COPILOT_PATTERNS = [
    (re.compile(r"\.claude/agents/"), "references .claude/agents"),
]

VALID_TARGETS = {"claude", "copilot"}


def parse_targets(raw_value: str) -> list[str]:
    value = raw_value.strip().strip('"').strip("'")
    if value.startswith("[") and value.endswith("]"):
        value = value[1:-1]
    return [token for token in re.split(r"[\s,]+", value) if token]


def resolve_skills_root(repo_root: Path) -> Path | None:
    candidates = [
        repo_root / "skills",
        repo_root / ".github" / "skills",
        repo_root / ".claude" / "skills",
    ]
    for candidate in candidates:
        if candidate.exists():
            return candidate
    return None


def resolve_copilot_overrides_root(repo_root: Path) -> Path | None:
    candidate = repo_root / "copilot" / "skills"
    return candidate if candidate.exists() else None


def validate_skill(
    skill_dir: Path,
    *,
    is_copilot_override: bool = False,
    has_copilot_override: bool = False,
) -> list[str]:
    problems: list[str] = []
    skill_file = skill_dir / "SKILL.md"
    content = skill_file.read_text(encoding="utf-8")
    match = FRONTMATTER_RE.match(content)

    if not match:
        return [f"{skill_file}: missing YAML frontmatter"]

    frontmatter, body = match.groups()
    manual_only = bool(DISABLE_MODEL_INVOCATION_RE.search(frontmatter))

    name_match = NAME_RE.search(frontmatter)
    if not name_match:
        problems.append(f"{skill_file}: missing or invalid name field")
        return problems

    name = name_match.group(1)
    if name != skill_dir.name:
        problems.append(
            f"{skill_file}: name '{name}' does not match directory '{skill_dir.name}'"
        )
    if "--" in name:
        problems.append(f"{skill_file}: name contains consecutive hyphens")

    description_match = DESCRIPTION_RE.search(frontmatter)
    if not description_match:
        problems.append(f"{skill_file}: missing description field")

    targets_match = TARGETS_RE.search(frontmatter)
    if not targets_match:
        problems.append(
            f"{skill_file}: missing metadata.brainstorm-toolkit-applies-to routing field"
        )
        return problems

    targets = parse_targets(targets_match.group(1))
    if not targets:
        problems.append(f"{skill_file}: no targets declared")
        return problems

    invalid_targets = [target for target in targets if target not in VALID_TARGETS]
    if invalid_targets:
        problems.append(
            f"{skill_file}: invalid targets {', '.join(sorted(set(invalid_targets)))}"
        )

    # Copilot overrides must target copilot
    if is_copilot_override and "copilot" not in targets:
        problems.append(
            f"{skill_file}: copilot override does not include 'copilot' in targets"
        )

    if "copilot" in targets and not has_copilot_override:
        for pattern, message in HARD_FORBIDDEN_COPILOT_PATTERNS:
            if pattern.search(body):
                problems.append(f"{skill_file}: Copilot-targeted skill {message}")

        if not manual_only:
            for pattern, message in STRICT_AUTO_COPILOT_PATTERNS:
                if pattern.search(body):
                    problems.append(
                        f"{skill_file}: auto-invocable Copilot skill {message}"
                    )

    return problems


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    skills_root = resolve_skills_root(repo_root)
    copilot_overrides_root = resolve_copilot_overrides_root(repo_root)

    if skills_root is None:
        print(
            "Skills directory not found. Expected one of: skills, .github/skills, .claude/skills",
            file=sys.stderr,
        )
        return 1

    skill_dirs = sorted(path for path in skills_root.iterdir() if path.is_dir())
    all_problems: list[str] = []
    count = 0

    # Collect names of skills that have copilot overrides
    copilot_override_names: set[str] = set()
    if copilot_overrides_root is not None:
        copilot_override_names = {
            path.name
            for path in copilot_overrides_root.iterdir()
            if path.is_dir() and (path / "SKILL.md").exists()
        }

    for skill_dir in skill_dirs:
        skill_file = skill_dir / "SKILL.md"
        if not skill_file.exists():
            all_problems.append(f"{skill_dir}: missing SKILL.md")
            continue
        all_problems.extend(
            validate_skill(
                skill_dir,
                has_copilot_override=skill_dir.name in copilot_override_names,
            )
        )
        count += 1

    # Validate copilot overrides if present
    if copilot_overrides_root is not None:
        override_dirs = sorted(
            path for path in copilot_overrides_root.iterdir() if path.is_dir()
        )
        for override_dir in override_dirs:
            skill_file = override_dir / "SKILL.md"
            if not skill_file.exists():
                all_problems.append(f"{override_dir}: missing SKILL.md (copilot override)")
                continue
            # Verify the override corresponds to a canonical skill
            canonical = skills_root / override_dir.name
            if not canonical.exists():
                all_problems.append(
                    f"{override_dir}: copilot override has no matching canonical skill in {skills_root}"
                )
            all_problems.extend(
                validate_skill(override_dir, is_copilot_override=True)
            )
            count += 1

    if all_problems:
        print("Skill validation failed:", file=sys.stderr)
        for problem in all_problems:
            print(f"- {problem}", file=sys.stderr)
        return 1

    print(f"Validated {count} skills.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())