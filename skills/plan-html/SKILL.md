---
name: plan-html
description: >
  Render a markdown plan file as a self-contained, shareable HTML page.
  Zero external assets (no CDN, no JS framework), embedded CSS with
  light/dark mode, anchored TOC at top, every section open by default,
  and auto-generated inline-SVG visuals (effort×impact map, phase flow)
  when the plan's structure warrants — no flag, data-driven. Composes
  with any plan — brainstorm output, SDLC plans, refactor docs, threat
  models. Use when you want to share a plan with a stakeholder,
  scroll-engage with a long plan in a browser, or hand off a roadmap.
  Output is throwaway: the .md remains canonical.
argument-hint: "<plan-file>"
metadata:
  brainstorm-toolkit-applies-to: claude copilot codex
---

# /plan-html — markdown plan to a single-file shareable HTML

## When to use

- You have a markdown plan (`plans/<slug>.md`, brainstorm output, threat
  model, SDLC plan) and want to share it visually with someone who
  isn't going to scroll through raw markdown.
- The plan has 3+ top-level sections — the TOC starts paying for itself
  there. For 1–2 section plans, markdown reads fine and the TOC is noise
  (the skill omits it automatically).
- Never auto-fires. You invoke it on demand. The markdown stays the
  source of truth.

## Argument

`<plan-file>` — path to a markdown file. Required. Relative paths
resolve against the current working directory. Common locations:

- `plans/<slug>.md`
- `plans/tasks/task-N-<slug>.md`
- `docs/<name>.md`
- Any markdown file in the repo

If the path doesn't exist or isn't markdown, stop and report.

## Output

Writes to `<plan-file>.html` (same dir, same stem). E.g.
`plans/refactor-zero-flag.md` → `plans/refactor-zero-flag.html`.

Single self-contained file, ~5–15 KB depending on plan size. Embedded
`<style>`, zero external assets, zero JavaScript. Opens in any browser.

## Stage 1 — Parse the plan

Read the plan file. Extract:

- **Title**: `# Heading` on line 1 (or the first `# ` heading). If none,
  use the file's stem with `_` and `-` replaced by spaces, title-cased.
- **Frontmatter** (optional, between two `---` lines at top): YAML
  fields. Most useful: `status`, `owner`, `parent_plan`, `updated`,
  `created`. All optional.
- **Sections**: `## ` headings as top-level sections, `### ` as
  subsections. Preserve order.
- **Roadmap section**: a `## Roadmap` or `## Phases` heading, if
  present, gets pinned at the top in the roadmap block. Otherwise,
  auto-derive (see Stage 2).

## Stage 2 — Build the generated blocks

**Read `skills/plan-html/references/blocks.md` now.** It carries all three, with the exact
markup for each:

- **2a — table of contents** from the plan's headings, with anchor ids that match the body.
- **2b — roadmap** from the plan's Implementation Steps, one row per step.
- **2c — inline SVG visuals**, data-driven from the plan's own content. Hand-author compact,
  valid SVG (`viewBox="0 0 660 400"`, `width:100%`); never link an external image — the page
  must stand alone.

Skip any block the plan gives no material for, and say which you skipped rather than emitting
an empty shell.

## Stage 3 — Convert markdown body to HTML

Walk the plan body (everything after the title and frontmatter,
excluding the roadmap section since it's already rendered above).
Translate inline, no library — the substitutions are simple and
deterministic:

| Markdown | HTML |
|---|---|
| `## Section` | `<h2 id="section-slug">Section</h2>` |
| `### Sub` | `<h3 id="sub-slug">Sub</h3>` |
| `#### Sub-sub` | `<h4>Sub-sub</h4>` |
| `**bold**` | `<strong>bold</strong>` |
| `*italic*` | `<em>italic</em>` |
| `` `code` `` | `<code>code</code>` |
| ```` ```lang ... ``` ```` | `<pre><code>...</code></pre>` (escape `<>&`) |
| `- item` / `* item` | `<ul><li>` |
| `1. item` | `<ol><li>` |
| `- [x] item` | `<li><input type="checkbox" checked disabled> item</li>` |
| `- [ ] item` | `<li><input type="checkbox" disabled> item</li>` |
| `> quote` | `<blockquote>` |
| `[text](url)` | `<a href="url">text</a>` |
| `---` on its own line | `<hr>` |
| Markdown tables | `<table><thead><tr><th>` etc. |

**No auto-collapse.** Render every `## ` section as a plain
`<section><h2 id="slug">Title</h2>...</section>` with all of its
content visible. The TOC at the top is the navigation aid; the doc
itself is scannable top-to-bottom (reader-mode default, not
explorer-mode). If a future plan genuinely needs a foldable subsection,
the author can drop raw `<details>` HTML into the markdown — markdown
allows it and the browser renders it natively.

**Always escape** `<`, `>`, `&` inside code blocks and inline code.
Pass them through outside code (markdown allows raw HTML).

## Stage 4 — Substitute into the template

Read `templates/plan.html.template` (sibling of this SKILL.md). Fill
placeholders:

| Placeholder | Value |
|---|---|
| `{{TITLE}}` | Parsed title (HTML-escaped) |
| `{{STATUS_BADGE}}` | `<span class="badge badge-<status>">status</span>` if frontmatter `status:` present, else empty |
| `{{META_LINE}}` | Joined non-status frontmatter fields: `by {owner} · updated {updated}`. Empty if no frontmatter. |
| `{{TOC_BLOCK}}` | Stage 2a output, or empty string (1–2 section docs) |
| `{{ROADMAP_BLOCK}}` | Stage 2b output, or empty string |
| `{{CONTENT_HTML}}` | Stage 3 output |
| `{{SOURCE_PATH}}` | Original plan path (relative to repo root) |
| `{{RENDER_DATE}}` | ISO date (YYYY-MM-DD) of the render |

Status badge variants supported by template CSS: `active`,
`in-progress`, `completed`, `done`, `blocked`, `draft`, `pending`.
Unknown values fall through with no styling (just default gray).

## Stage 5 — Write and report

Write to `<plan-file-stem>.html` next to the source. Print:

```
Wrote <output-path> (<size> KB)
Open: <platform-appropriate open command>
```

Open commands by platform:

- macOS: `open <path>`
- Linux: `xdg-open <path>`
- Windows / WSL: `wslview <path>` (or `start <path>` on native Windows)

Don't actually run the open command — just print it. The user opens
when ready.

## Gotchas

- **Don't fetch external assets.** No `<script src="...">`, no
  `<link rel="stylesheet" href="...">`, no CDNs. The output must work
  offline and as an email/Slack attachment.
- **Don't add JavaScript.** Anchor links + `<details>` cover everything
  the skill needs. If you find yourself wanting JS, the answer is "the
  markdown is the truth, the HTML is a sidecar — keep it static."
- **Don't try to parse complex markdown.** This isn't a full CommonMark
  renderer. Stick to the table in Stage 3. If a plan uses something
  exotic (footnotes, definition lists, image embeds with sizing), pass
  it through as best-effort and note "rendered as-is" in the footer.
- **Don't write `.html` when the source is in a non-`plans/` location**
  without checking. If the user passes `docs/CONVENTIONS.md`, the output
  goes to `docs/CONVENTIONS.html`. Mention this in the final report so
  they aren't surprised.
- **The template lives at `skills/plan-html/templates/plan.html.template`.**
  If a future change forks the template, update the cross-references
  in this SKILL.md too — no template duplication.
