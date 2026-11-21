# Step 8 — sentinel and continue (body)

Loaded by `skills/brainstorm/SKILL.md` Step 8 after the plan-file check and the vendored-skill
routing guard, when the plan is about to be handed to `/sdlc`.

Drop a **next-action sentinel** naming that command so the Stop hook surfaces it.

```
# Append ONE structured line (multi-slot seam — coexists with a gotcha entry;
# see docs/SEAM.md). /sdlc does no git writes, so confirm stays false; set
# "confirm":true only if you substitute a command that is hard to reverse.
# Dedup by cmd, not the whole line (docs/SEAM.md) -- -F/-e as there, so a cmd
# containing regex metacharacters (a plan path's `.md`) is never misread as a pattern.
cmd='/sdlc plans/brainstorm-<topic-slug>.md'   # or docs/plans/<topic-slug>.md in a skill repo
grep -qF -e "\"cmd\":\"$cmd\"" -e "\"cmd\": \"$cmd\"" .claude/.next-action 2>/dev/null \
  || echo "{\"cmd\":\"$cmd\",\"source\":\"brainstorm\",\"confirm\":false}" >> .claude/.next-action
```

The Stop hook — **shipped by the plugin** (auto-wired when the plugin is enabled,
SEAM1) or installed by `setup.sh` (`.claude/settings.json` / `.github/hooks/next-action.json`
/ `.codex/hooks.json`) — reads the file once, prints `Next: <command>`, and deletes it.
Codex **does** have a Stop hook shipped the same way; until the Codex hook is wired and
`.codex/` is trusted (`/hooks`), also print `Next:` inline right after writing the
sentinel, so the handoff degrades gracefully instead of vanishing. **No-hook nudge
(SEAM2):** if no hook is wired at all, the sentinel is inert — after writing it, check for
one: `grep -rlqs 'next-action' .claude/settings.json ~/.claude/settings.json
.github/hooks/ ~/.claude/plugins/ 2>/dev/null` — and if that finds nothing, tell the user
to enable the plugin or run `setup.sh`/`/repo-onboarding` (else the `Next:` hint silently
never appears). Skip the sentinel only if the user explicitly chose "save for later" with
no intent to ship.

Continue:

1. **Show what's being built** (optional, cheap) — offer
   `/plan-html plans/brainstorm-<topic-slug>.md` (or `/plan-html docs/plans/<topic-slug>.md`
   in a skill repo) to render the plan as a single-file HTML view the user or a stakeholder
   can scroll, for a shape-of-the-work read before delivery starts.
2. **Continue into delivery** — `/sdlc plans/brainstorm-<topic-slug>.md` (or
   `/sdlc docs/plans/<topic-slug>.md` in a skill repo).
3. **Save for later** — if the user signals they're done for now, leave the
   plan file and skip the sentinel.

If the plan has clear implementation steps with file paths and acceptance
criteria, proceed with delivery (option 2). If it's exploratory or has
ambiguous tradeoffs, pause for the user to review (offer option 1's HTML view
first).

Transition conversationally.
