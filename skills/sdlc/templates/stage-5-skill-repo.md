# Stage 5 — Skill-repo validation procedure

When skill-repo mode is auto-detected (`.claude-plugin/marketplace.json`
exists at repo root), this replaces only the **test half** of the standard
Stage 5 (the full test suite) — Markdown skills have no test surface, so the
equivalent discipline is structural and contract-level. **The plan-vs-diff
check stays on**: see "Plan axis" below.

Run each check; collect findings. The pipeline pauses if any HARD check fails
and proceeds (with warnings logged) on SOFT checks.

---

## HARD checks (block the hand-off)

### 1. Skill validator passes

```bash
bash scripts/py.sh scripts/validate_skills.py
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
for f in skills/*/SKILL.md copilot/skills/*/SKILL.md codex/skills/*/SKILL.md; do
  [ -f "$f" ] || continue
  lines=$(wc -l < "$f")
  if [ "$lines" -gt 500 ]; then
    # SOFT warning — over the rule-3 ceiling
    echo "WARN: $f is $lines lines (>500)"
  fi
done
```

The ceiling is 500 lines, the Agent Skills spec limit (`CLAUDE.md` rule 3).
Going over is a smell, not a blocker. Note the count in the Stage 7 report and move on.

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

## Plan axis (whenever there is a plan target)

**Read `skills/sdlc/templates/stage-5-validate.md` now**, §2 ("Check the delivery
against the plan"), and run its plan axis — same dispatch, same brief, same runtime
delta (Claude dispatches the `plan-conformance-validator` agent; the overlays run it
as one inline pass). Skip it exactly as that section says: no plan target, no check.

**Gating rule.** The **requirements** axis gates exactly as it does in standard
mode — `requirements_green: false` fails the stage, unconditionally. The **flow**
axis is **advisory only** in skill-repo mode: it always runs and its findings are
always reported, but they can never fail the stage or open the fix loop. Skill-repo
mode has no test evidence to witness a flow (`stage-5-validate.md`'s "Witnessed" /
"Unwitnessed" split), and the structural HARD/SOFT checks above are not flow
evidence — they check shape (paths, registration, references), not behavior. Set
`data.flow_witnessed: false` unconditionally here.

## Output

Summarize as a table for the Stage 7 report:

| Check | Status | Detail |
|---|---|---|
| validate_skills.py | PASS / FAIL | exit code, count |
| marketplace registration | PASS / FAIL | missing skills, if any |
| template references | PASS / FAIL | unresolved refs, if any |
| setup.sh dry install | PASS / FAIL | exit code |
| line-count ceiling | OK / WARN | files over 500 |
| README skills table | OK / WARN | drift detected? |
| copilot overlay parity | OK / WARN / N/A | drift detected? |
| plan requirements | PASS / FAIL / N/A | missing/partial criteria, if any |
| plan flow (advisory) | OK / WARN / N/A | MISMATCH/MISSING findings, if any |

A requirements FAIL is a HARD fail (STOP, do not proceed to Stage 6) exactly like
the checks above; a flow finding never blocks, per the gating rule above.
All HARD pass → proceed to Stage 6 and embed the table in the Stage 7 report.
