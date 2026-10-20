# Operator gate — advisor pass before any operator question

Loaded only when `pipeline.question_advisor.enabled` is `true`. Sub-agents never ask the
operator: they return draft questions to the orchestrator, which runs this protocol.

1. **Draft** every question you were about to ask, as text. Do not ask yet.
2. **Gather `measure_first`.** `pipeline.question_advisor.measure_first` lists files the advisor
   reads, or commands you run now and pass in as output (the advisor has no Bash). Skip when empty.
3. **Dispatch the advisor.** Resolve `models.question_advisor` (default `sonnet`, then
   `models.cap`) per `skills/sdlc/templates/models.md`; print
   `model: question_advisor=<tier> (cap: <cap|none>)`; dispatch
   `brainstorm-toolkit:question-advisor` (bare `question-advisor` when vendored) with an
   explicit `model`. Pass the drafts, the `measure_first` output and the paths of `DECISIONS.md`
   and `TASKS.md`. It returns `{dropped, ask}`.
4. **Record.** Pipe the `ask` list to `bash scripts/question-advice.sh approve`. It stores a
   hash of each question; the ask-gate hook compares against it.
5. **Ask exactly the `ask` texts**, unchanged. A reworded question is a new question and the
   hook denies it: re-run steps 3–4.
6. **Report** each dropped question and its answer in one line.

Limits: the gate covers the question tool only, not a question typed as plain text. The file
`.claude/pipeline/_advice/off` bypasses the hook. With no hook (Copilot, Codex, or `gate` off)
this protocol is the whole control.
