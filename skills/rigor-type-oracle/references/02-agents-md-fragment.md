# 02 — The paragraph to keep in the project's agent contract

A skill only binds an agent that loaded it. The rule below binds every
session, because it lives in the file the agent reads at startup —
`AGENTS.md`, or `CLAUDE.md` for Claude Code (which pulls `AGENTS.md` in
with `@AGENTS.md` when both exist).

Paste it verbatim. `rigor-project-init` installs it during onboarding; if
the project is already onboarded, add it now.

## Where it goes

- **`AGENTS.md` exists** → append the section at the end. Do not
  reorganise the file.
- **Only `CLAUDE.md` exists** → append it there.
- **Both exist** → put it in `AGENTS.md`; add `@AGENTS.md` to `CLAUDE.md`
  only if it is not already pulled in.
- **Neither exists** → create `AGENTS.md` with this as its first section.
- **A "Types" / "Type checking" section already exists** → merge into it
  rather than adding a second one, and keep the five bullets intact.

Never overwrite unrelated content, and never rewrite a rule the project
already wrote for itself — show the user the conflict instead.

## The fragment

```markdown
## Types come from Rigor, not from reading code

This project is type-checked by [Rigor](https://github.com/rigortype/rigor). A type you did not obtain from Rigor is a guess, and a guessed type is never written anywhere: not in `sig/`, not in an inline annotation (`#:`, `# @rbs`), not in a doc comment, not in a review comment, and not as the reason for a nil check or an `is_a?` guard.

- The type of an expression: `rigor type-of FILE:LINE:COL`, or `rigor annotate FILE` for a whole file.
- The signature of a method: `rigor sig-gen --print FILE`; paste what it prints, never what you expect.
- A parameter type is the one thing inference does not give you: derive it from the call sites with `rigor sig-gen --observe PATH` and keep it only while `rigor check` stays green.
- When Rigor answers `Dynamic[top]` or `untyped`, or `sig-gen` skips the method, do not fill the gap. Report the exact command and its output; the gap is the finding.
- Every type you state to a human carries the command that produced it, so it can be re-run.

The `rigor-type-oracle` skill (`rigor skill --full rigor-type-oracle`) has the full procedure. With the Rigor MCP server connected, `rigor_type_of`, `rigor_annotate`, and `rigor_sig_gen` are the same oracle as tool calls.
```

## Two notes for whoever installs it

- **The single-long-line shape is deliberate.** Each bullet is one line,
  however long. Some of these files are rendered as Markdown by tools
  that turn a newline inside a paragraph into a line break, so a
  column-wrapped bullet reads ragged. Do not re-wrap it to fit an editor
  ruler.
- **Tell the user it landed.** It is a change to the file that governs
  every future agent session in the repo — it belongs in the "here is
  what I created, and whether to commit it" report, not in a silent diff.
  It should be committed: the point is that every contributor's agent
  reads the same rule.
