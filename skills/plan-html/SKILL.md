---
name: plan-html
description: >
  Render a markdown plan file as a self-contained, shareable HTML page.
  Zero external assets (no CDN, no JS framework), embedded CSS with
  light/dark mode, anchored TOC at top, every section open by default.
  Composes with any plan — brainstorm output, SDLC plans, refactor
  docs, threat models. Use when you want to share a plan with a
  stakeholder, scroll-engage with a long plan in a browser, or hand
  off a roadmap. Output is throwaway: the .md remains canonical.
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

## When NOT to use

- The plan is under ~3 sections. Markdown reads fine.
- You need a live edit surface — this skill writes static HTML.
- You need to feed the artifact back into `/sdlc` or `/sdlc-lite` — those
  consume the `.md`, not the `.html`.

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

## Stage 2a — Build the TOC block

If the plan has **3 or more** top-level `## ` sections, render a small
"On this page" navigation list at the top. For 1–2 sections, omit it
(the template's `{{TOC_BLOCK}}` becomes empty) — a TOC there is noise.

Per section, derive an item count to put in muted text next to the
title. Scan the section body for the first matching shape:

| Section body contains | Count label |
|---|---|
| A markdown table | `N rows` (header row excluded) |
| An ordered list (`1.`, `2.`, …) | `N steps` |
| An unordered list (`-`, `*`) | `N items` |
| Nested mix → pick the first found from the top | per the above |
| None of the above (just prose) | omit count |

Slugs: lowercase the section title, replace any non-alphanumeric run
with `-`, strip leading/trailing `-`. Use these as both the `<h2 id>`
in the body and the `<a href="#...">` in the TOC — link clicks scroll
the page to the heading.

Render the TOC block as:

```html
<nav class="toc">
  <h2>On this page</h2>
  <ul>
    <li><a href="#why-extracted">Why extracted</a></li>
    <li><a href="#whats-preserved-here">What's preserved here<span class="count">(9 rows)</span></a></li>
    <li><a href="#bootstrap-recipe">Bootstrap recipe<span class="count">(5 steps)</span></a></li>
  </ul>
</nav>
```

## Stage 2b — Build the roadmap block

If the plan has a `## Roadmap` or `## Phases` section with a checkbox
list (`- [ ]` / `- [x]`), use that verbatim — each item becomes a
roadmap entry. Checked items render with `✓` (done, green). Unchecked
with `○` (pending, muted).

Otherwise, scan all `## ` sections for checkbox lists. If any have
mixed `- [x]` / `- [ ]` items, auto-derive a roadmap entry per such
section:

- Section title → roadmap label
- Counts: `X/Y` where X is `- [x]` count, Y is total checkbox count
- Progress bar (CSS `width: (X/Y * 100)%`)
- Icon: `✓` if X == Y, `⏳` if 0 < X < Y, `○` if X == 0

If no checkboxes anywhere → omit the roadmap block entirely (the
template's `{{ROADMAP_BLOCK}}` becomes an empty string).

Render the roadmap block as:

```html
<section class="roadmap">
  <h2>Roadmap</h2>
  <ul>
    <li><span class="icon icon-done">✓</span> Phase 1 — Direction</li>
    <li><span class="icon icon-progress">⏳</span> Phase 2 — Implementation
      <span class="progress-text">13/20</span>
      <span class="progress-bar"><span class="fill" style="width: 65%"></span></span>
    </li>
    <li><span class="icon icon-pending">○</span> Phase 3 — Validation</li>
  </ul>
</section>
```

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
