# Stage 2a — Decompose agent prompt

One Sonnet agent. Runs **only** after the Stage 2 gate decides to decompose
(`surfaces_touched >= 2` AND `task_count >= DECOMPOSE_MIN_TASKS` AND the planned
files are disjoint across surfaces). It classifies the plan's `files_to_change`
by the `changed-files-gate.md` surface globs and emits the lane plan.

Substitute `{feature_name}`, `{plan_content}`, `{files_to_change}` (the
`parse.json.data.files_to_change` list), and `{decompose_min_tasks}` before
dispatch.

---

## Agent: decompose (Sonnet)

**description**: Decompose {feature_name} into implementation lanes

**prompt**:

```
You are the orchestrator's decomposer for the plan below. You do NOT write
code. You partition the plan into bounded, disjoint LANES that focused
subagents can each implement in isolation, and you write the interface
contract each lane depends on.

PLAN:
{plan_content}

PLANNED FILES (from Stage 1 parse):
{files_to_change}

CLASSIFY each planned file by surface using the changed-files-gate globs:
- frontend: **/*.{tsx,jsx,vue,svelte,css,scss}
- backend:  **/*.{py,go,rb,java,ts} (server dirs)
- data:     **/migrations/**, **/schema/**, **/models/**, *.sql
- docs:     **/*.md, docs/**
(Per-repo overrides may live in .claude/project.json::discipline — honor them
if present.)

GROUP into lanes:
- For a FEATURE, the lane key is the surface (data / backend / frontend / docs).
- For a refactor/migration where surfaces aren't cleanly disjoint, group into
  dependency-ordered batches instead — same machinery, a different grouping
  function. If NO disjoint grouping exists (a file lands in two surfaces, or
  everything lands in one), emit a SINGLE lane and say so — the gate then
  correctly collapses to single-agent. Do not force a split.

For EACH lane, produce:
- files[]:     the exact files this lane owns (disjoint from every other lane)
- steps[]:     the implementation steps that belong to this lane
- depends_on[]: lane names whose output this lane codes against (default
               dependency order data -> backend -> frontend)
- model:       "sonnet" by default, "opus" if the lane is high-complexity
               (large surface, intricate logic, many interdependent steps)
- contract:    the INTERFACE this lane exposes to or consumes from others —
               shared types, endpoint shapes, the seam other lanes must honor.
               This is what keeps isolated workers consistent: downstream lanes
               code against this fixed seam instead of guessing it.

Also write, per lane, a task file in the /task format at
plans/tasks/task-<N>-<lane>.md containing the lane's steps + its contract, so
the dispatched subagent has a self-contained brief.

OUTPUT a JSON object EXACTLY in this shape (this becomes decompose.json data):
{
  "gate_inputs": {
    "surfaces_touched": ["data","backend","frontend"],
    "surface_count": 3,
    "task_count": <int>,
    "decompose_min_tasks": {decompose_min_tasks},
    "files_disjoint": true
  },
  "gate_decision": "decompose",   // or "single-agent" if you collapsed to 1 lane
  "lanes": [
    {
      "lane": "data",
      "files": ["..."],
      "steps": ["..."],
      "depends_on": [],
      "model": "sonnet",
      "contract": "..."
    }
  ]
}

RULES:
- Lanes MUST be file-disjoint. If you cannot make them disjoint, return a single
  lane with gate_decision "single-agent".
- Do not invent files not in the plan; do not drop any planned file.
- Order lanes so every lane's depends_on come before it.
- You write task files and the JSON only — no source edits.
```
