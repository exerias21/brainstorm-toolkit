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
# B2': capture references like `templates/<name>` (e.g. templates/AGENTS.md.template,
# templates/stage-2-implement.md). Allows sub-paths and most filename chars.
TEMPLATE_REF_RE = re.compile(r"`templates/([A-Za-z0-9_./-]+)`")

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


def extract_metadata_block(frontmatter: str) -> dict[str, str]:
    """B1': extract the YAML `metadata:` mapping as a flat dict of key->value.

    Tolerant scanner — does not import PyYAML. Returns {} if no metadata block.
    Reads the indented lines immediately following a top-level `metadata:` key.
    """
    lines = frontmatter.splitlines()
    in_block = False
    out: dict[str, str] = {}
    for line in lines:
        if not in_block:
            if re.match(r"^metadata:\s*$", line):
                in_block = True
            continue
        # End of block when an unindented non-empty line appears.
        if line and not line.startswith((" ", "\t")):
            break
        stripped = line.strip()
        if not stripped:
            continue
        m = re.match(r"^([A-Za-z0-9_-]+):\s*(.*)$", stripped)
        if m:
            out[m.group(1)] = m.group(2).strip()
    return out


def find_template_refs(body: str) -> list[str]:
    """B2': find backtick-quoted `templates/<path>` references in skill body."""
    return sorted(set(TEMPLATE_REF_RE.findall(body)))


def template_ref_resolves(ref: str, skill_dir: Path, repo_root: Path) -> bool:
    """B2' resolution order:

    1. Skill-local: `<skill_dir>/templates/<ref>`
    2. Repo-root:  `<repo_root>/templates/<ref>`
    """
    if (skill_dir / "templates" / ref).exists():
        return True
    if (repo_root / "templates" / ref).exists():
        return True
    return False


def find_bundled_resource_refs(body: str) -> list[str]:
    """B1': find references to bundled resources inside a skill's own directory.

    Returns relative `templates/...` paths extracted from backtick-quoted
    references in *body*. These are skill-local bundled resources that a
    Copilot override must also ship if it keeps the same reference.
    """
    refs: set[str] = set()
    # Skill-local templates references (already extracted by find_template_refs).
    refs.update(TEMPLATE_REF_RE.findall(body))
    return sorted(refs)


def validate_skill(
    skill_dir: Path,
    *,
    is_copilot_override: bool = False,
    has_copilot_override: bool = False,
    repo_root: Path | None = None,
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

    # B2': template-reference linter. Every backtick-quoted `templates/<path>`
    # mention in the skill body must resolve either skill-locally
    # (`<skill_dir>/templates/<path>`) or at the repo root
    # (`<repo_root>/templates/<path>`). Hard error.
    if repo_root is not None:
        for ref in find_template_refs(body):
            if not template_ref_resolves(ref, skill_dir, repo_root):
                problems.append(
                    f"{skill_file}: references missing template `templates/{ref}` "
                    f"(checked {skill_dir}/templates/{ref} and "
                    f"{repo_root}/templates/{ref})"
                )

    return problems


def overlay_parity_warnings(
    canonical_dir: Path, override_dir: Path, repo_root: Path
) -> list[str]:
    """B1': diff a skill's canonical SKILL.md against its Copilot override.

    Emits warnings (not errors) when:
      - The override's `metadata` block diverges from canonical, beyond the
        required `brainstorm-toolkit-applies-to` flip.
      - The override references a bundled resource (e.g. `templates/foo.md`)
        that resolves skill-locally in the canonical skill but does not exist
        skill-locally in the override.
    """
    warnings: list[str] = []
    canonical_file = canonical_dir / "SKILL.md"
    override_file = override_dir / "SKILL.md"
    if not canonical_file.exists() or not override_file.exists():
        return warnings

    cm = FRONTMATTER_RE.match(canonical_file.read_text(encoding="utf-8"))
    om = FRONTMATTER_RE.match(override_file.read_text(encoding="utf-8"))
    if not cm or not om:
        return warnings

    canonical_fm, canonical_body = cm.groups()
    override_fm, override_body = om.groups()

    canonical_meta = extract_metadata_block(canonical_fm)
    override_meta = extract_metadata_block(override_fm)

    # Routing key is *expected* to differ — that's the whole point of an override.
    routing_key = "brainstorm-toolkit-applies-to"
    cmp_canonical = {k: v for k, v in canonical_meta.items() if k != routing_key}
    cmp_override = {k: v for k, v in override_meta.items() if k != routing_key}

    if cmp_canonical != cmp_override:
        only_canonical = sorted(set(cmp_canonical) - set(cmp_override))
        only_override = sorted(set(cmp_override) - set(cmp_canonical))
        differing = sorted(
            k
            for k in set(cmp_canonical) & set(cmp_override)
            if cmp_canonical[k] != cmp_override[k]
        )
        details = []
        if only_canonical:
            details.append(f"missing in override: {', '.join(only_canonical)}")
        if only_override:
            details.append(f"only in override: {', '.join(only_override)}")
        if differing:
            details.append(f"differing values: {', '.join(differing)}")
        warnings.append(
            f"{override_file}: metadata block diverges from canonical "
            f"({'; '.join(details)})"
        )

    # Bundled-resource parity: only warn when the *override itself* still
    # references a skill-local templates resource that the override does not
    # ship. (If the override drops the reference entirely, that's a deliberate
    # simplification — no warning.)
    for ref in find_bundled_resource_refs(override_body):
        canonical_local = canonical_dir / "templates" / ref
        override_local = override_dir / "templates" / ref
        # Only flag references that look skill-local (canonical bundles them).
        if not canonical_local.exists():
            continue
        if not override_local.exists():
            warnings.append(
                f"{override_file}: references `templates/{ref}` but does not "
                f"ship it at {override_local} (canonical bundles it skill-locally)"
            )

    return warnings


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

    all_warnings: list[str] = []

    for skill_dir in skill_dirs:
        skill_file = skill_dir / "SKILL.md"
        if not skill_file.exists():
            all_problems.append(f"{skill_dir}: missing SKILL.md")
            continue
        all_problems.extend(
            validate_skill(
                skill_dir,
                has_copilot_override=skill_dir.name in copilot_override_names,
                repo_root=repo_root,
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
                validate_skill(
                    override_dir,
                    is_copilot_override=True,
                    repo_root=repo_root,
                )
            )
            count += 1

            # B1': overlay parity check (warning, not error) when both halves exist.
            if canonical.exists():
                all_warnings.extend(
                    overlay_parity_warnings(canonical, override_dir, repo_root)
                )

    if all_warnings:
        print("Skill validation warnings:", file=sys.stderr)
        for warning in all_warnings:
            print(f"- {warning}", file=sys.stderr)

    if all_problems:
        print("Skill validation failed:", file=sys.stderr)
        for problem in all_problems:
            print(f"- {problem}", file=sys.stderr)
        return 1

    print(f"Validated {count} skills.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())