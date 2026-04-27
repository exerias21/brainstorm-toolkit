# Cheatsheet category map + chains footer

Bundled resource consumed by `/cheatsheet`. Edit this file (NOT the SKILL.md
procedure) when recategorizing or adding chain entries.

## Category map

Each line is `<skill-name>: <category>`. Skills not listed here fall into
`Uncategorized` so newly-added skills surface without requiring an edit.

```
brainstorm:           Plan
brainstorm-team:      Plan
task:                 Plan
pbi:                  Plan
status:               Discover
cheatsheet:           Discover
repo-onboarding:      Discover
sdlc:                 Build & ship
flowsim:              Build & ship
test-check:           Build & ship
e2e-loop:             Build & ship
eval-harness:         Build & ship
repo-health:          Health
dead-code-review:     Health
gotcha:               Health
data-source-pattern:  Knowledge
logging-conventions:  Knowledge
post-deploy-verify:   Operate
```

Future Phase-2+ skills (locked by CONVENTIONS.md):
```
brd-ingest:           Plan
pbi-decompose:        Plan
approve:              Operate
deploy:               Operate
monitor:              Operate
rollback:             Operate
coverage:             Operate
```

## Typical chains (footer)

Printed verbatim at the end of the cheatsheet output. Indented to align with
the skill list above. Two-space indent matches the per-skill bullet style.

```
Typical chains:
  Idea → ship:        /brainstorm  →  /sdlc {plan}        →  PR  →  merge
  Single task:        /task "..."  →  (TDD inline)        →  PR
  Bounded PBI:        /pbi "..."   →  /sdlc {pbi-plan}    →  PR  →  merge
  Plan vs. delivered: /flowsim {plan}  (run after merge to spot drift)
  Hygiene sweep:      /repo-health  →  triage  →  /sdlc on each finding
  Dead code only:     /dead-code-review  (deeper than /repo-health's pass)
  New repo intake:    /repo-onboarding  →  /cheatsheet  →  /repo-health
  Pitfall capture:    /gotcha "<entry>"  (after a bug bites; future runs
                                          consult GOTCHAS.md automatically)
  Post-merge verify:  /post-deploy-verify  (pipeline profile)

Tip: many skills drop a one-line .claude/.next-action file when they finish.
If you separately install optional Stop-hook support, that hook can surface
the file as a suggested next command. If you've never seen "Next: /...",
that's normal on repos that haven't wired in that optional hook.
```
