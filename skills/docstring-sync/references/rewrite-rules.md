# Docstring Sync — rewrite rules

Read at Step 6 of `SKILL.md`, before the first edit. Never read on a `--report` run — there is
no symbol queued to edit, so nothing here applies.

## Minimal edit, not a rewrite

Edit only the flagged sentence, section, or comment line — never the whole docstring. A
docstring can be half accurate and half stale; the accurate half is the author's own knowledge
and this run is not the place to lose it. If a summary line is fine and only the `Returns`
section drifted, touch the `Returns` section.

Keep the file's existing docstring convention (Google, NumPy, Sphinx, or plain) exactly as
found. Converting between conventions is out of scope here — see `skills/code-tour/SKILL.md`
and its `references/standards.md` for type-hint duplication and the no-restated-signature rule
rather than restating either here; this file only adds what is specific to *repair*.

## The pointer policy

A pointer to a **tracked, durable** file — an ADR, or an architecture doc committed alongside
the code — is left alone. Those are the recommended home for system-level "why"
(`skills/code-tour/references/standards.md`), and this skill's job is rot, not relocation.

A pointer to a plan path, a `TASKS.md` row, plan/phase/step numbering, or a cited path that is
missing or gitignored is the kind this skill exists to fix. So is a comment that is a ticket
reference and **nothing else** — a ticket cited alongside its own explanation is not pointer-only
and is left alone.

When rewriting one:

1. **Look for the plan on disk first.** A consumer repo's `plans/` directory is often
   gitignored but still present locally. If the plan is there, harvest the load-bearing reason
   from it and inline that reason in place of the pointer.
2. **If the plan is gone, keep the bare instruction and drop the pointer.** Turn
   `# plans/LAUNCH_REQUIREMENT_PHASES.md: do not reintroduce the retry wrapper here` into
   `# Do not reintroduce the retry wrapper here.` — the instruction survives, the dead path does
   not.
3. **Never invent a reason.** If neither the on-disk plan nor the surrounding code explains
   *why* the instruction exists, do not guess one (`skills/code-tour/SKILL.md`, on inventing
   rationale). Keep the bare instruction as in step 2 and add the symbol to the unresolved list
   for a human to fill in.

## Runtime-visible docstrings

A docstring can be behavior, not just documentation: a FastAPI/Flask route publishes it as
OpenAPI text, a click/typer/argparse command prints it as `--help`, and a `>>>` block runs
under `--doctest-modules`. The script marks these `runtime_visible`. Skip them unless the run
was given `--include-runtime-docstrings` — editing one changes what the running program shows
or executes, which is a behavior change wearing a docs-only disguise.

## Never restate, never guess

- Don't repeat a type the annotation already carries, and don't restate the signature in prose
  — `skills/code-tour/references/standards.md` covers both with their sourcing; follow it rather
  than re-deriving it here.
- An edit you cannot verify against the function's actual body is not a fix. If the flagged
  claim's truth is genuinely ambiguous from the code alone, leave it and list it, rather than
  picking a plausible-sounding rewrite.

## COMMENTS — verbatim, every edit

> COMMENTS: never reference the plan in code — no plan file paths, plan/phase/step numbers, or TASKS.md rows in comments or docstrings. Write the reason itself; the plan does not ship with the code and its numbering means nothing once it is gone.

This is the rule the pointer policy above exists to enforce on repair. It also applies to any
*new* text this run writes: harvesting a reason from an on-disk plan means inlining that reason,
never citing the plan file it came from.
