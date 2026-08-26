#!/usr/bin/env python3

from __future__ import annotations

import json
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
# B2'': the CROSS-SKILL citation form, `skills/<skill>/templates/<file>`. The narrow regex above
# matched only a backtick immediately followed by `templates/`, so 26 cross-skill citations per
# tool could dangle in an installed consumer with the linter reporting nothing. Captured
# separately because it resolves against another skill's dir, not this one's.
CROSS_TEMPLATE_REF_RE = re.compile(
    r"`(?:\.(?:claude|github|agents)/)?skills/([A-Za-z0-9._-]+)/templates/([A-Za-z0-9_./-]+)`"
)

STRICT_AUTO_COPILOT_PATTERNS = [
    (re.compile(r"\bPlan mode\b", re.IGNORECASE), "mentions Plan mode"),
    (re.compile(r"\bAgent tool\b", re.IGNORECASE), "mentions the Agent tool"),
    (re.compile(r"\bAskUserQuestion\b"), "mentions AskUserQuestion"),
]

HARD_FORBIDDEN_COPILOT_PATTERNS = [
    (re.compile(r"\.claude/agents/"), "references .claude/agents"),
]

VALID_TARGETS = {"claude", "copilot", "codex"}

# C: the fan-out skills — these dispatch sub-agents (the Agent tool / Workflow
# agent() seam) and are therefore governed by the shared model-tier cap
# contract at skills/sdlc/templates/models.md. Each must carry a one-line
# pointer to that file so the cap rule is checkable, not just documented.
MODEL_CAP_FAN_OUT_SKILLS = {
    "sdlc-lite",
    "brainstorm",
    "brainstorm-deep",
    "brainstorm-team",
    "dead-code-review",
}
MODEL_CAP_REF = "models.md"

# D: the review-fix skills -- sdlc and sdlc-lite ship an adversarial Review->Fix
# stage governed by the reviewer-model axis contract at
# skills/sdlc/templates/models.md. Deliberately separate from
# MODEL_CAP_FAN_OUT_SKILLS: different axis, and brainstorm*/dead-code-review
# have no review stage.
REVIEW_STAGE_SKILLS = {"sdlc-lite"}
REVIEW_MODEL_REF = "models.md"


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
        repo_root / ".agents" / "skills",
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


def find_cross_template_refs(body: str) -> list[tuple[str, str]]:
    """B2'': find `skills/<skill>/templates/<file>` references. Returns (skill, file) pairs."""
    return sorted(set(CROSS_TEMPLATE_REF_RE.findall(body)))


def cross_template_ref_resolves(skill: str, ref: str, repo_root: Path) -> bool:
    """A cross-skill citation resolves against the OWNING skill's templates dir."""
    return (repo_root / "skills" / skill / "templates" / ref).exists()


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

        # B2'': cross-skill citations (`skills/<skill>/templates/<file>`). These are the
        # shared sdlc templates cited from eight other skills. setup.sh ships them per tool
        # and retargets the prefix at install; this check guards the repo-side source.
        for owner, ref in find_cross_template_refs(body):
            if not cross_template_ref_resolves(owner, ref, repo_root):
                problems.append(
                    f"{skill_file}: references missing cross-skill template "
                    f"`skills/{owner}/templates/{ref}` "
                    f"(checked {repo_root}/skills/{owner}/templates/{ref})"
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


def model_cap_pointer_warnings(skills_root: Path) -> list[str]:
    """C: soft-warn when a fan-out skill's canonical SKILL.md doesn't
    reference the shared model-tier cap contract (`models.md`).

    Conservative by design: only checks the five skills named in
    MODEL_CAP_FAN_OUT_SKILLS (the sub-agent-dispatching skills governed by
    the cap); every other skill is left alone. A missing pointer is a soft
    warning, not a validation failure — the pointer rollout across skills
    can land independently of this gate.
    """
    warnings: list[str] = []
    for name in sorted(MODEL_CAP_FAN_OUT_SKILLS):
        skill_file = skills_root / name / "SKILL.md"
        if not skill_file.exists():
            continue
        content = skill_file.read_text(encoding="utf-8")
        if MODEL_CAP_REF not in content:
            warnings.append(
                f"{skill_file}: fan-out skill does not reference the shared "
                f"model-cap contract (`{MODEL_CAP_REF}`)"
            )
    return warnings


def review_model_pointer_warnings(skills_root: Path) -> list[str]:
    """D: soft-warn when sdlc/sdlc-lite's canonical SKILL.md doesn't reference
    the shared reviewer-model contract (`models.md`)."""
    warnings: list[str] = []
    for name in sorted(REVIEW_STAGE_SKILLS):
        skill_file = skills_root / name / "SKILL.md"
        if not skill_file.exists():
            continue
        content = skill_file.read_text(encoding="utf-8")
        if REVIEW_MODEL_REF not in content:
            warnings.append(
                f"{skill_file}: review-stage skill does not reference the shared "
                f"reviewer-model contract (`{REVIEW_MODEL_REF}`)"
            )
    return warnings


# E: sub-agent definitions in agents/. These are a separate artifact from skills --
# a `.md` with YAML frontmatter that Claude Code loads into its agent registry (and
# that setup.sh copies into a consumer's .claude/agents/). Two fields are load-bearing
# and were historically absent on every agent in this repo:
#   `model:`  omitted => the agent INHERITS the parent session's model. An agent whose
#             prose says "you are a Haiku agent" therefore runs at Opus in an Opus
#             session, silently, forever.
#   `tools:`  omitted => the agent inherits every tool. A prose promise of "you do not
#             write any file" is then advisory, not enforced.
# Both are enforced when present (verified empirically 2026-07-26). The checks below
# make a prose claim that frontmatter does not back a WARNING, not a silent lie.
AGENT_MODEL_TIERS = {"haiku", "sonnet", "opus", "fable", "inherit"}
AGENT_WRITE_TOOLS = {"Write", "Edit", "NotebookEdit"}
# "You are a read-only Haiku state-join agent" -- a tier word inside a self-description.
AGENT_SELF_DESC_RE = re.compile(
    r"You are[^.\n]{0,160}?\b(Haiku|Sonnet|Opus|Fable)\b", re.IGNORECASE
)
AGENT_READONLY_CLAIM_RE = re.compile(
    r"read-only|do\s+\*{0,2}not\*{0,2}\s+(?:execute anything,\s*)?write any file",
    re.IGNORECASE,
)


def validate_agents(repo_root: Path) -> tuple[list[str], list[str], int]:
    """E: validate agents/*.md frontmatter. Returns (problems, warnings, count)."""
    problems: list[str] = []
    warnings: list[str] = []
    agents_root = repo_root / "agents"
    if not agents_root.is_dir():
        return problems, warnings, 0

    # Cross-check against the plugin manifest so an agent can't be added or removed
    # without its registration moving too.
    registered: set[str] = set()
    manifest = repo_root / ".claude-plugin" / "marketplace.json"
    if manifest.exists():
        try:
            data = json.loads(manifest.read_text(encoding="utf-8"))
            for plugin in data.get("plugins", []):
                for ref in plugin.get("agents", []) or []:
                    registered.add(Path(ref).name)
        except (json.JSONDecodeError, OSError) as exc:
            warnings.append(f"{manifest}: could not read agent registrations ({exc})")

    count = 0
    for agent_file in sorted(agents_root.glob("*.md")):
        count += 1
        content = agent_file.read_text(encoding="utf-8")
        match = FRONTMATTER_RE.match(content)
        if not match:
            problems.append(
                f"{agent_file}: missing YAML frontmatter. `name:` and `description:` are "
                f"required; without them the agent loads with a generated fallback "
                f"description and is invisible to auto-delegation"
            )
            continue
        frontmatter, body = match.groups()

        name_match = NAME_RE.search(frontmatter)
        if not name_match:
            problems.append(f"{agent_file}: missing or malformed `name:` in frontmatter")
        elif name_match.group(1) != agent_file.stem:
            problems.append(
                f"{agent_file}: `name: {name_match.group(1)}` does not match the filename "
                f"stem `{agent_file.stem}` -- the registry surfaces the filename, so these "
                f"must agree"
            )
        if not DESCRIPTION_RE.search(frontmatter):
            problems.append(
                f"{agent_file}: missing `description:` -- this is what drives delegation; "
                f"without it the registry shows a generated placeholder"
            )

        model_match = re.search(r"^model:\s*(\S+)\s*$", frontmatter, re.MULTILINE)
        model = model_match.group(1) if model_match else None
        if model and model not in AGENT_MODEL_TIERS and not model.startswith("claude-"):
            problems.append(
                f"{agent_file}: `model: {model}` is not a recognized tier "
                f"({'|'.join(sorted(AGENT_MODEL_TIERS))}) or a claude-* model id"
            )

        tools_match = re.search(r"^tools:\s*(.+)$", frontmatter, re.MULTILINE)
        tools = (
            {t.strip() for t in tools_match.group(1).split(",") if t.strip()}
            if tools_match
            else None
        )

        # The defect this check exists for: prose asserts a tier the frontmatter
        # doesn't pin, so the agent silently inherits the parent session's model.
        if model is None and AGENT_SELF_DESC_RE.search(body):
            warnings.append(
                f"{agent_file}: prose describes this agent's own model tier but no "
                f"`model:` field pins it -- it will INHERIT the parent session's model. "
                f"Either add `model:` or drop the claim from the prose"
            )

        # Same shape, for the read-only promise.
        if AGENT_READONLY_CLAIM_RE.search(body):
            if tools is None:
                warnings.append(
                    f"{agent_file}: prose claims read-only behavior but no `tools:` field "
                    f"restricts it -- the agent inherits every tool, so the promise is "
                    f"advisory. Add a `tools:` allowlist without Write/Edit"
                )
            elif tools & AGENT_WRITE_TOOLS:
                writers = ", ".join(sorted(tools & AGENT_WRITE_TOOLS))
                problems.append(
                    f"{agent_file}: prose claims read-only behavior but `tools:` grants "
                    f"{writers}"
                )

        if registered and agent_file.name not in registered:
            problems.append(
                f"{agent_file}: not registered in .claude-plugin/marketplace.json "
                f"`plugins[].agents[]` -- it will not ship with the plugin"
            )

    for ref in sorted(registered):
        if not (agents_root / ref).exists():
            problems.append(
                f".claude-plugin/marketplace.json registers agents/{ref}, which does not exist"
            )

    return problems, warnings, count


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    skills_root = resolve_skills_root(repo_root)
    copilot_overrides_root = resolve_copilot_overrides_root(repo_root)

    if skills_root is None:
        print(
            "Skills directory not found. Expected one of: skills, .github/skills, .claude/skills, .agents/skills",
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
            # A shared-template holder (e.g. skills/sdlc/, which keeps templates/
            # after its SKILL.md was folded into /sdlc-lite) is not a skill and has
            # no SKILL.md to validate. setup.sh installs its templates via
            # install_shared_templates() and skips it in the per-skill loop.
            if (skill_dir / "templates").is_dir():
                continue
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

    # C: fan-out skills must point at the shared model-cap contract (soft warning).
    all_warnings.extend(model_cap_pointer_warnings(skills_root))
    # D: review-fix skills must point at the shared reviewer-model contract (soft warning).
    all_warnings.extend(review_model_pointer_warnings(skills_root))

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

    # E: sub-agent definitions in agents/ (separate artifact, same discipline).
    agent_problems, agent_warnings, agent_count = validate_agents(repo_root)
    all_problems.extend(agent_problems)
    all_warnings.extend(agent_warnings)

    if all_warnings:
        print("Skill validation warnings:", file=sys.stderr)
        for warning in all_warnings:
            print(f"- {warning}", file=sys.stderr)

    if all_problems:
        print("Skill validation failed:", file=sys.stderr)
        for problem in all_problems:
            print(f"- {problem}", file=sys.stderr)
        return 1

    agent_note = f", {agent_count} agents" if agent_count else ""
    print(f"Validated {count} skills{agent_note}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())