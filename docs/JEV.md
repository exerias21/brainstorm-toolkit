# Jev integration

> **Live contract — current and maintained.** The integration this page describes is
> **planned, not implemented**: nothing in this toolkit reads a Jev key, shells out to a
> judge command, or writes a verdict file today.

<!-- assert-manual: recheck-by 2026-12-19 "The Jev integration is still planned, not implemented in this toolkit" -->

Full design: [docs/plans/jev-integration.md](plans/jev-integration.md).

## What it will do

An optional external judge — Jev, from TypeSafe — that classifies fix-loop failures into a
closed taxonomy and checks recorded claims against the evidence cited for them. The
organising rule is **"Jev picks, code decides"**: a call returns a typed judgment, and
threshold, action and anything countable stay in deterministic code — a judgment never
becomes the final word on its own. Rollout is **shadow first**: a newly enabled integration
only records what it would have done until it earns promotion on labelled data.

## Opt-in only

Nothing changes unless a repo explicitly turns this on. The plan describes a top-level,
off-by-default settings block for `.claude/project.json` — a master switch, the external
judge command to run, which environment variable to read a key's name from, a shadow/enforce
mode, and a timeout — every one of them optional and inert until both the switch is on and a
command is configured. An absent block, a disabled switch, or an unconfigured command all
mean exactly the same thing: every call site behaves exactly as it does today, with no
network call and nothing written.

## What you'll need

- **A judge command.** The toolkit never calls Jev itself: it runs an external command that
  reads one JSON request on stdin and writes one JSON verdict on stdout. `claude-wiki` is the
  reference implementation, and it is **not published** — it is a local project today. Until it
  ships, or the command contract in the design plan is implemented by someone else, there is no
  judge to point at, and the integration stays inert for everyone else.
- **A TypeSafe API key.** See below.

**Not needed: the TypeSafe agent skill** (`typesafe-ai`), or any other way for the model to know
what Jev is. The toolkit's prose never asks the model to reason about Jev's question types or
probabilities — code runs the command and reads back a typed verdict and a band (act / uncertain
/ no). That is deliberate: Copilot and Codex load no Claude skills at all, so a design that relied
on one would already fail on both. The skill is useful only when you are *writing or tuning* the
judge's questions, which happens in the judge command's own project.

## Where the API key lives

- **Today:** the only Jev key that exists is claude-wiki's own. It reads
  `JEV_API_KEY` from its own `.env` and maps it internally to `TYPESAFE_API_KEY`. This
  toolkit does not read, store, or forward a key today.
- **Planned:** resolution will check the environment variable `TYPESAFE_API_KEY` first (the
  setting will let a repo name a different variable), then a user-level credentials file at
  `${XDG_CONFIG_HOME:-~/.config}/brainstorm-toolkit/credentials` — outside every repo, so one
  setup covers all of them. That file will be written by a planned setup command,
  `bash scripts/jev-key.sh set`, which reads the key with hidden terminal input so it never
  appears on screen or in a command's argument list. **That script does not exist yet.**
- **Never:** in a repo's `.claude/project.json` (a plugin-only install never gets that file's
  gitignore entry, and models open `project.json` routinely), in a consumer repo's `.env` (it
  belongs to the application, and is one of the most commonly committed-by-accident files
  there is).

**Onboarding, when this ships, will ask for the key** and write it straight to the user-level
credentials file — never to `.claude/project.json` or anywhere in the repo, and never echoed back.
A pasted key does stay in that session's local conversation transcript; if you would rather avoid
that, choose the private option instead, which runs the hidden-input setup command.

## Using claude-wiki standalone today

`claude-wiki` is a separate project with no dependency on this toolkit. It builds a memory
wiki from your own Claude Code session transcripts and exposes itself as a single skill,
`/claude-wiki`. **It is not published yet**, so this applies only where it is already installed;
on those machines it runs on its own, whether or not this integration ever ships.
