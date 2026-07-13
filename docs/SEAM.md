# The `.next-action` seam — contract

The `.claude/.next-action` sentinel is the cross-skill handoff channel: a skill that
finishes writes what should happen next, and the Stop hook
(`scripts/hooks/next-action.sh`) surfaces it once. This page is the canonical contract now
that the channel is **multi-slot and structured** (gap-analysis Lever A). Referenced from the
hook header and every writer skill.

## Format — one entry per line

The file is **append-friendly**: one entry per line, each either a JSON object or a bare
command string.

```
{"cmd": "/gotcha [Testing] eval fixture drift", "source": "sdlc-lite", "confirm": false}
{"cmd": "/sdlc-lite plans/brainstorm-radius.md", "source": "brainstorm", "confirm": false}
{"cmd": "/sdlc plans/big-feature.md",            "source": "brainstorm", "confirm": true}
/gotcha [Legacy] a bare command line still works
```

| Field | Meaning |
|---|---|
| `cmd` (required) | the slash-command to surface / run |
| `source` | the skill that wrote it (provenance; for dedup/debugging) |
| `confirm` | `true` ⇒ a human must approve before running (anything that writes git history, e.g. `/sdlc`). A human reader can ignore it; a future auto-continue consumer **must** honor it. |

**Backward compatibility:** a line that does not parse as a JSON object is treated as a bare
`cmd` (the legacy single-slot format). Old writers and hand-written lines keep working.

## Writer protocol

- **Append, never overwrite** (`>>`, not `>`) — so independent sources coexist instead of
  racing for one slot (the old "only if absent — outermost run wins" rule is gone; the gotcha
  seam and a pipeline handoff now both land).
- **Dedup by `cmd`** — append only if that exact line isn't already present:
  ```sh
  line='{"cmd":"/sdlc-lite plans/foo.md","source":"brainstorm","confirm":false}'
  grep -qF "$line" .claude/.next-action 2>/dev/null || echo "$line" >> .claude/.next-action
  ```
- **Set `confirm:true`** for any command that writes git history (`/sdlc`). Default `false`.
- **Never write a bare, argument-less command** (e.g. a lone `/gotcha`) — always include the
  drafted argument.

Current writers: `/brainstorm` (pipeline handoff), `/sdlc-lite` + `/task` (gotcha seam),
`/repo-health` (highest-impact suggestion). Three-way-sync: the canonical skill, its
copilot/codex overlays, and this page move together.

**No-hook nudge (SEAM2).** A sentinel is *inert* until a Stop hook reads it — and in a repo
that uses the plugin but never ran `setup.sh`/`/repo-onboarding`, no hook is wired, so the
line goes nowhere silently. After writing a sentinel, do a best-effort check and nudge if
nothing will surface it (SEAM1-aware — the plugin cache counts as "wired"):

```sh
grep -rlqs 'next-action' .claude/settings.json ~/.claude/settings.json .github/hooks/ \
  ~/.claude/plugins/ 2>/dev/null \
  || echo "Note: next-action written, but no Stop hook is installed to surface it — enable the brainstorm-toolkit plugin (it now ships the hook, SEAM1) or run setup.sh / /repo-onboarding, else the 'Next: …' hint won't appear."
```

## Reader protocol — peek vs consume

- **The Stop hook is the ONLY consumer.** It prints every pending line as `Next: <cmd>` (with
  `(confirm before running)` appended when `confirm:true`), then deletes the whole file —
  fire-once, per file.
- **Every other reader must PEEK** — read without deleting. `/next` and `/status` inspect the
  pending action to fold it into their output; if they consumed it, the hook would have
  nothing to surface at the next Stop. A second consumer eats the hint before the user sees it.

## Cross-tool

- **Claude Code, Copilot, AND Codex** all have a `Stop` hook — wired via
  `.claude/settings.json`, `.github/hooks/next-action.json`, and **`.codex/hooks.json`**
  respectively. Codex's Stop hook uses the same `systemMessage` / `decision:block` contract
  (learn.chatgpt.com/docs/hooks). The plugin ships it (SEAM1); `setup.sh` wires it for
  copy-installs. Two Codex caveats: project-local `.codex/` hooks fire only once the user
  **trusts** the directory (`/hooks`), and Codex may run the hook from a subdirectory, so the
  script path resolves via the git top-level.
- **Inline fallback** — writers still ALSO print `Next: <cmd>` inline (useful on Codex before
  the hook is trusted, or on any runtime with no hook wired) so the handoff never silently
  vanishes.

## Auto-continue (Lever C / L9) — OPT-IN, default off

With `pipeline.auto_continue: true` in `.claude/project.json`, on **Claude Code or Codex**
(both honor the Stop-hook `decision:block` contract), the Stop hook stops *printing* the next
action and starts *executing* it: it returns
`{"decision":"block","reason":"Continue with: <cmd>"}`, which feeds `<cmd>` back to the model
as its next instruction. The session becomes the loop; the sentinel is its program counter.

Guardrails (all enforced in `next-action.sh`, all non-negotiable):
1. **Opt-in** — unset knob ⇒ unchanged print behavior. Nothing auto-runs by default.
2. **Never a `confirm:true` action** — anything that writes git history (`/sdlc`) always parks
   to a printed hint. This is why every writer must set `confirm` honestly.
3. **Single action only** — if more than one line is pending, the hook parks (prints). It
   never guesses which of several to execute.
4. **Hop budget** — `pipeline.loop.max_hops` (default 5), tracked in
   `.claude/.auto-continue-hops`, decremented per hop; at 0 the loop parks. Bounds a runaway
   `brainstorm → pipeline → gotcha → …` chain exactly like the 3-iteration fix budget bounds a
   fix loop. Reset whenever the chain ends in a print.
5. **Runtime must support `decision:block`** — gated on `CLAUDE_PROJECT_DIR` (Claude) or a
   `CODEX_*` env (Codex; both honor `decision:block`). Copilot's block-equivalent is unverified,
   so it stays print-only. (The Codex env marker should be confirmed on a real install; if it
   doesn't match, auto-continue safely falls back to print.)

## Deliberately NOT here (deferred)

- **Unattended worker** (Lever C / L12) — a daemon polling the queue headlessly. Stays a
  documented deployment pattern in `docs/` (see `AUTONOMOUS-DISCOVERY.md`), not a shipped skill.
