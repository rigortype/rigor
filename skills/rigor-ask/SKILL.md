---
name: rigor-ask
description: |
  Answer any question about Rigor itself — why a diagnostic fired, how its type model / narrowing / refinements / shapes work, what a config key or CLI flag does, how to write a plugin or a refinement annotation — by consulting Rigor's own documentation OFFLINE with `rigor docs` (and `rigor explain` for a diagnostic id), then answering from the source instead of guessing. This is the human's shortcut: they ask in plain language; you reach for `rigor docs` so they never have to remember the command. Triggers: "why is Rigor flagging this?", "what does this Rigor error / rule mean?", "how does Rigor infer or narrow this?", "how do I configure Rigor to do X?", "what does this rigor flag do?", "is this a Rigor false positive?", "where are the Rigor docs?". NOT for deciding what to do next on a project (use rigor-next-steps) or for running setup (use the setup skills).
license: MPL-2.0
metadata:
  version: 0.1.0
  homepage: https://github.com/rigortype/rigor
---

# Ask Rigor anything

The user has a question about Rigor — what a diagnostic means, why it
fired, how the type model behaves, what a flag or config key does. **Do
not answer from memory.** Once Rigor is installed, its handbook and full
manual ship inside the gem, and `rigor docs` serves them **offline** —
always matching the user's installed version. Consult them and answer
from the source, with a pointer to the page you used.

This skill is the agent-facing half of a simple promise to the user:
they only ever need to remember two skills — **`rigor-next-steps`** ("what
should we do next?") and **`rigor-ask`** ("answer this about Rigor"). They
ask in plain language; *you* turn it into the right `rigor docs` lookup.

## The commands you have

| Command | Use |
| --- | --- |
| `rigor docs` | Print the offline doc index (`llms.txt`) — the map of what is available. Start here when you don't know the page. |
| `rigor docs <name>` | Print a page. `<name>` is a category-qualified path (`handbook/03-narrowing`), a prefixed basename (`03-narrowing`), or a unique short name (`narrowing`). |
| `rigor docs --list [category]` | List every bundled page (optionally just `manual` or `handbook`) with its path. |
| `rigor explain <rule>` | The catalogue entry for a diagnostic id (e.g. `rigor explain call.undefined-method`) — what the rule means, why it fires, how to address it. |
| `rigor annotate <file>` | Reprint the user's own file with the inferred type of each line in the margin — to show *what Rigor actually sees* in their code. |
| `rigor type-of <file>:<line>:<col>` | The inferred type at one position. |

All are read-only and need **no network**.

## Procedure

### 1. Classify the question

- **About a specific diagnostic** (a rule id like `call.undefined-method`,
  or "why is this flagged?") → start with `rigor explain <rule>`, then the
  diagnostics chapter (`rigor docs diagnostics`). If it is about *their*
  code, also run `rigor annotate <file>` / `rigor type-of` to ground the
  answer in what Rigor inferred there.
- **About the type model / a concept** (narrowing, refinements, tuple &
  hash shapes, `Dynamic`, RBS interop) → the handbook
  (`rigor docs --list handbook`, then the matching chapter, e.g.
  `rigor docs handbook/03-narrowing`).
- **About operating Rigor** (a config key, a CLI flag, baselines, plugins,
  CI, caching) → the manual (`rigor docs --list manual`, then e.g.
  `rigor docs configuration` or `rigor docs cli-reference`).
- **Don't know where it lives** → `rigor docs` (the index) routes you.

### 2. Read the page, then answer from it

Quote or paraphrase the relevant passage and **name the page** you drew
from (e.g. "per `rigor docs handbook/03-narrowing` …"), so the user can
re-read it themselves with the same command. Prefer the doc's own wording
over a remembered approximation.

### 3. If the docs don't cover it

The bundled set is the **drive-Rigor** corpus (manual + handbook). The
normative **type specification**, the internal spec, and ADRs are
contributor-facing and stay web-only — they are *not* in `rigor docs`. If
a question needs them, say so and point at
<https://rigor.typedduck.fail/llms.txt> (the web index) rather than
guessing. Never invent a flag, rule id, or behaviour that you did not find
in the docs.

## Example

User: *"Why is Rigor flagging `s.lenght` as undefined?"*

```sh
rigor explain call.undefined-method   # what the rule means and why it fires
rigor annotate demo.rb                # the inferred type of `s` on that line
rigor docs diagnostics                # the full rule catalogue, for more depth
```

Then answer from what they said: the rule fires because Rigor inferred a
concrete receiver type for `s` and that type has no `lenght` method (a
typo for `length`) — grounding the explanation in what `rigor annotate`
showed and what `rigor explain call.undefined-method` documents, not in a
guess.

## Why this beats answering from memory

Rigor's catalogue is deliberately conservative and version-specific: a
rule's exact firing condition, a flag's spelling, a config key's default
all change release to release. `rigor docs` is the copy that shipped with
*this* install, so an answer drawn from it cannot drift from the binary
the user is actually running.
