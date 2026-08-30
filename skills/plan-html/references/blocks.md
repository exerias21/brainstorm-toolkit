# Generated blocks — TOC, roadmap, and inline SVG

Loaded by `skills/plan-html/SKILL.md` at Stage 2. These are the three generated regions of the
page and the exact markup each produces. The skill body carries the pipeline; this file carries
the skeletons, so the markup lives in one place and the skill stays readable.

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
