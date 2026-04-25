# Stage 5 — Skill-repo validation procedure

When `/sdlc --skill-repo` is in effect, this replaces the standard Stage 5 (full
test suite) and Stage 5.5 (api/ui/data validators). Markdown skills have no
test surface; the equivalent discipline is structural and contract-level.

Run each check; collect findings. The pipeline pauses if any HARD check fails
and proceeds (with warnings logged) on SOFT checks.

---

## HARD checks (block the PR)

### 1. Skill validator passes

```bash
python3 scripts/validate_skills.py
```

Must exit 0 and report all skills validated. A failure here means a skill's
frontmatter, structure, or required sections are broken.

### 2. Marketplace registration is current

For each new skill directory under `skills/`, confirm its path is listed in
`.claude-plugin/marketplace.json` under `plugins[0].skills`. A new skill that
isn't registered won't ship via `setup.sh`.

```bash
# Quick check: every skills/* dir should appear in marketplace.json
for d in skills/*/; do
  name="${d#skills/}"; name="${name%/}"
  grep -q "skills/${name}" .claude-plugin/marketplace.json || echo "MISSING: ${name}"
done
```

Any "MISSING" output is a HARD fail.

### 3. Template references resolve

Grep each modified or new SKILL.md for `templates/` references. For each
reference, confirm the target file exists.

```bash
# For every skills/<name>/SKILL.md changed in this run, list its templates/ refs
# and verify each exists at skills/<name>/templates/<file>.
```

A reference to a non-existent template file is a HARD fail.

### 4. Setup.sh dry install succeeds

```bash
bash setup.sh --target /tmp/sdlc-skill-repo-test-$$ --tools both
```

Must complete without error. Any "skip (exists)" output is fine; "wrote:" output
should include every changed skill. If `setup.sh` errors out, it's a HARD fail
— consumers couldn't install the plugin in this state.

---

## SOFT checks (warn, don't block)

### 5. Line-count ceiling per `CLAUDE.md` rule 3

```bash
for f in skills/*/SKILL.md; do
  lines=$(wc -l < "$f")
  if [ "$lines" -gt 250 ]; then
    # SOFT warning — over the rule-3 ceiling
    echo "WARN: $f is $lines lines (>250)"
  fi
done
```

The rule says "small utility skills ≤100 lines, larger orchestration skills
≤250 lines". Going over is a smell, not a blocker — `/sdlc` itself has been
above the ceiling and shipping work. Note the count in the PR body and move on.

### 6. AGENTS.md / CLAUDE.md drift check

If the change adds a new skill, slash-command, agent, or template, check that
the skills table in `README.md` was updated. SOFT warning if not — easy to
miss, easy to fix in a follow-up.

### 7. Copilot overlay parity

For any skill that has a `copilot/skills/<name>/SKILL.md` override, re-run the
validator scoped to it. The override is a separate file; an edit to the
canonical version may need a mirror. SOFT warning if the override has
materially different content.

---

## Output

Summarize as a table for the PR body:

| Check | Status | Detail |
|---|---|---|
| validate_skills.py | PASS / FAIL | exit code, count |
| marketplace registration | PASS / FAIL | missing skills, if any |
| template references | PASS / FAIL | unresolved refs, if any |
| setup.sh dry install | PASS / FAIL | exit code |
| line-count ceiling | OK / WARN | files over 250 |
| README skills table | OK / WARN | drift detected? |
| copilot overlay parity | OK / WARN / N/A | drift detected? |

Any HARD-check FAIL → STOP, do not proceed to Stage 6.
All HARD pass → proceed to Stage 6 with the table embedded in the PR body.
