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

## When NOT to use

- The plan is under ~3 sections. Markdown reads fine.
- You need a live edit surface — this skill writes static HTML.
- You need to feed the artifact back into `/sdlc-lite` — those
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

## Stage 2c — Auto-generate visuals (inline SVG, data-driven)

When the plan's structure makes a picture clearly more legible than the text,
emit ONE inline-SVG `<figure>` for it, placed just under the heading of the
section it illustrates. **No flag** — generate a visual only when the content
warrants it (table below) and omit it otherwise, so a plain plan stays lean.
Always **inline SVG** — never a `<script>`, never a CDN, never Mermaid — so the
output stays a single, offline, emailable file (the whole point of plan-html).

Trigger a visual on these shapes (cap ~2 per plan; pick the highest-signal):

| Plan shape | Visual | When |
|---|---|---|
| A ranked list whose items each carry an effort (S/M/L) and an impact/priority | **effort × impact scatter** | the highest-value strategy-doc visual |
| `## Roadmap` / `## Phases` or a numbered stage sequence | **left-to-right flow** of the phases | pipeline / staged plans |
| A small lifecycle / state machine described in prose | **state diagram** (nodes + arrows) | only if explicitly described |

Authoring rules:
- Hand-author compact, valid SVG (~`viewBox="0 0 660 400"`, `width:100%`).
  Use the CSS classes the template defines so it inherits light/dark colors —
  **don't hardcode hex** in the SVG:
  - **scatter**: `.svg-axis`, `.svg-grid`, `.svg-q`, `.svg-dot-S/M/L`,
    `.svg-num`, `.svg-lbl`, `.svg-qlbl`.
  - **flow / state diagram**: `.svg-node` (neutral box), `.svg-node-done`
    (already-built, green), `.svg-node-new` (net-new, amber),
    `.svg-node-text` (box label), `.svg-sub` (small sublabel), `.svg-flow`
    (connector line). All theme-aware via the same tokens.
- Wrap in `<figure>…<figcaption>one-line read</figcaption></figure>`.
- **Stay honest:** plot only data actually in the plan. If you can't place a
  point confidently, omit the visual rather than guess. If nothing qualifies,
  generate nothing — most plans get zero visuals.

Effort × impact skeleton (numbered dots keyed to the ranked list; x by effort
S→L, y by impact — lower y = higher impact; top-left = quick wins):

```html
<figure><svg viewBox="0 0 660 400" role="img" aria-label="effort vs impact">
  <line class="svg-axis" x1="70" y1="40" x2="70" y2="340"/>
  <line class="svg-axis" x1="70" y1="340" x2="620" y2="340"/>
  <text class="svg-lbl" x="345" y="372" text-anchor="middle">effort →</text>
  <circle class="svg-dot-S" cx="140" cy="80" r="11"/><text class="svg-num" x="140" y="84">1</text>
  <!-- one dot per ranked item -->
</svg><figcaption>Effort × impact — top-left = quick wins.</figcaption></figure>
```

Flow skeleton (left-to-right phases/steps; `svg-node-done` = already built,
`svg-node-new` = net-new, so a reviewer sees the build surface at a glance):

```html
<figure><svg viewBox="0 0 720 120" role="img" aria-label="upload to action flow">
  <rect class="svg-node-done" x="6" y="40" width="96" height="40" rx="6"/>
  <text class="svg-node-text" x="54" y="64">Upload</text>
  <line class="svg-flow" x1="102" y1="60" x2="128" y2="60"/>
  <rect class="svg-node-new" x="128" y="40" width="110" height="40" rx="6"/>
  <text class="svg-node-text" x="183" y="60">Review</text>
  <text class="svg-sub" x="183" y="73">LLM + consent</text>
  <!-- repeat box → line → box for each step -->
</svg><figcaption>The flow — green = built, amber = net-new.</figcaption></figure>
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
