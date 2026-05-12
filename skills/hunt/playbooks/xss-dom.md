# Playbook: xss-dom — DOM-based XSS

## What this hunts

Client-side JavaScript that writes attacker-controlled data into a sink
that the browser parses as HTML, JavaScript, or a same-origin URL. The
server may be doing everything right; the bug is in the browser code.

## Sweep targets

### Sources (untrusted in the browser)
- `location.hash`, `location.search`, `location.href`, `location.pathname`
- `document.referrer`
- `window.name`, `postMessage` event data (without origin check)
- `localStorage` / `sessionStorage` / `IndexedDB` (if attacker-controlled
  data ever lands there)
- URL params parsed via `URLSearchParams`

### Sinks (interpret as code/HTML)
- `innerHTML`, `outerHTML`, `insertAdjacentHTML`
- `document.write`, `document.writeln`
- Code-evaluation primitives: the global JS evaluator, `Function()`,
  `setTimeout(string)`, `setInterval(string)`
- `<a href={attacker}>` if the value can be `javascript:`
- `<iframe src={attacker}>`
- jQuery: `$()` with a string starting `<`, `$.html(`, `$.append(` with
  HTML strings
- React: the `dangerously`-prefixed inner-HTML prop (`__html: attackerString`)
- Vue: `v-html="attackerString"`
- Angular: `[innerHTML]="attackerString"` (Angular sanitizes by default;
  watch for `bypassSecurityTrustHtml`)

## Vulnerable shape

```javascript
// Hash-based router that echoes the fragment:
document.getElementById("title").innerHTML = location.hash.slice(1);
```

```jsx
// React with the inner-HTML bypass:
<div dangerouslySetInnerHTML={{ __html: queryParams.bio }} />
```

## Safe shape

- Use text-node sinks: `el.textContent = value`, `el.innerText = value`.
- For HTML output, sanitize with DOMPurify *before* setting `innerHTML`.
- For href construction, validate scheme: `if (!/^https?:/.test(url)) reject`.
- Treat `postMessage` events as untrusted: check `event.origin` against
  an allowlist *before* using `event.data`.

## Suppression rules

- The HTML being injected was rendered from a server template that uses
  a context-aware escaping engine (Jinja autoescape, ERB `<%=`, React's
  default `{value}` interpolation) AND the value isn't routed back
  through a code sink.
- The value comes from a JSON parse of a server response that the
  attacker provably can't influence (admin-only feed, signed payload).
- Framework default escaping applies (React's `{value}` JSX
  interpolation, Vue's `{{ value }}` mustache).

## Trace direction

Sink-first for HTML sinks: grep for `innerHTML =`, the React inner-HTML
bypass prop, `document.write`. For each, trace the RHS expression back
to its source. URL-derived data is the highest-confidence source.

## Fix vocabulary

For each finding: name the sink, name the source, recommend the
text-node replacement or DOMPurify sanitization. If the framework's
escape default is already being bypassed (React's `dangerously`-prefixed
inner-HTML prop, `v-html`), the fix is to remove the bypass and
reintroduce escaping.
