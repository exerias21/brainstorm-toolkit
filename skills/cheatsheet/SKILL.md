---
name: cheatsheet
description: >
  Print a one-page guide to every brainstorm-toolkit skill installed in this
  repo, grouped by category, with the typical command chains. Use this when
  the user says /cheatsheet, asks "what skills do I have?", "what can the
  toolkit do?", "remind me the commands", or is onboarding a teammate to the
  toolkit. Also covers `/cheatsheet --brief` for a one-line-per-skill listing
  and `/cheatsheet <name>` for a deep-dive on a specific skill.
argument-hint: "[skill-name] [--brief] [--tool auto|claude|copilot]"
metadata:
  brainstorm-toolkit-applies-to: claude copilot
---

# Cheatsheet

Discoverability for the toolkit. Reads the SKILL.md frontmatter of every
installed skill in this repo and prints a categorized one-page guide.

## Arguments

- `[skill-name]` (optional): if given, print only that skill's full SKILL.md
  body (deep-dive mode). If omitted, list everything.
- `--brief`: one-line-per-skill mode. Skip the descriptions and chains
  footer. Good for a teammate who already knows the toolkit.
- `--tool auto|claude|copilot`: which install root to read.
  - `auto` (default): probe `.claude/skills/` first, then `.github/skills/`.
  - `claude`: force `.claude/skills/`.
  - `copilot`: force `.github/skills/`.

## Procedure

1. **Resolve install root** per `--tool`. If the resolved root doesn't exist,
   error out with: "no skills installed. Run `bash setup.sh --target .` from
   the brainstorm-toolkit plugin root."

2. **Single-skill mode** (`[skill-name]` given):
   - Glob `<root>/<skill-name>/SKILL.md`. If absent, fall back to a
     case-insensitive substring match against directory names — e.g.,
     `/cheatsheet sdlc` should resolve to `skills/sdlc/`. If still no match,
     error with the list of installed skills as a hint.
   - Read the matched SKILL.md and print its full body. Append a footer:
     `Bundled resources: <list of files in <root>/<name>/templates/ if any>`.
   - Stop here.

3. **List mode** (no `[skill-name]`):
   - For each `<root>/*/SKILL.md`, parse frontmatter:
     `name`, `description`, `argument-hint`,
     `metadata.brainstorm-toolkit-applies-to`. Skip dirs without a SKILL.md.
   - Resolve each skill's category via the static map in
     `templates/categories.md` (read once at the start of this stage).
     Skills not in the map land in a final `Uncategorized` bucket so new
     skills surface immediately without requiring a categories.md edit.
   - Print, in this category order: Discover, Plan, Build & ship, Health,
     Knowledge, Operate, Uncategorized. Empty categories are omitted.
   - Format per skill:
     - Default mode: `  /<name> <argument-hint>` then the description on the
       next line, indented two spaces.
     - `--brief` mode: `  /<name>  — <one-line description>` with the
       description truncated to 80 chars.
   - After the categories, print the "Typical chains" footer from
     `templates/categories.md` (an ASCII Mermaid-style diagram, copy-pastable
     into terminal review). Skip the footer in `--brief` mode.
   - Final line: `Cheatsheet template at CHEATSHEET.md if you want a
     printable copy.` (only if `CHEATSHEET.md` exists at repo root.)

4. **Output target**: print directly to the conversation. Do not write any
   file. Do not drop a `.next-action` sentinel — `/cheatsheet` is
   informational, never a chain start.

## When this skill triggers

- User types `/cheatsheet` or `/cheatsheet <name>`
- User asks "what skills do I have", "what can the toolkit do", "remind me
  the commands", "what's available"
- A teammate is onboarding and the user wants to share a quick map

## When NOT to use

- For up-to-date skill *behavior* on a specific skill, just open its
  SKILL.md directly — don't shell out to `/cheatsheet <name>` from inside
  another skill. Direct file reads are cheaper.
- For automation that needs to enumerate skills programmatically, parse
  the SKILL.md frontmatter directly (this skill is human-facing).

## Bundled resources

- `templates/categories.md` — category map (skill name → bucket) and the
  "Typical chains" footer. Edit this file to recategorize without touching
  the SKILL.md procedure.
