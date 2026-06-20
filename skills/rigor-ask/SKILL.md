---
name: rigor-ask
description: |
  Answer ANY question about Rigor from its docs, never from memory: why a diagnostic fired or is a false positive; how the type model works (narrowing, refinements, shapes, `Dynamic`, RBS interop); what a config key, CLI flag, or baseline does; how it compares to other checkers (Sorbet, Steep, TypeScript, mypy, PHPStan); whether it handles X (generics, Rails, RSpec, a given gem); how to write an RBS signature or `rigor:` annotation; and "what is Rigor / why use it / is it right for us?". Reach for `rigor docs` (handbook + manual ship in the gem, OFFLINE and version-matched) and `rigor explain`; for questions about THEIR code run `rigor check` / `annotate` / `type-of` to answer from what Rigor infers. Use it whenever someone asks about Rigor, its types, a diagnostic, or how it handles their Ruby — even casual or indirect phrasing. If it's really "do X for me" (set up CI, reduce a baseline, init a project), answer briefly, then hand off to rigor-next-steps or the matching skill.
license: MPL-2.0
metadata:
  version: 0.2.0
  homepage: https://github.com/rigortype/rigor
---

# Ask Rigor anything

Someone has a question about Rigor. It might be about a diagnostic, the
type model, a flag, how Rigor stacks up against another type checker,
whether Rigor can handle their framework, how to type a method — or just
"what is this, and should I use it?" Whatever it is, **answer from the
source, not from memory.**

Two things make that easy, and you have both offline:

- **Rigor's own docs ship inside the gem.** `rigor docs` serves the full
  handbook and manual, always matching the user's installed version, no
  network. This is the authoritative copy: a rule's exact firing
  condition, a flag's spelling, a config default — all drift release to
  release, and `rigor docs` is the copy that shipped with *this* install,
  so an answer drawn from it cannot disagree with the binary they run.
- **Rigor can read the user's actual code.** When the question is about
  *their* program — "why is this flagged?", "what type does Rigor see
  here?", "how well-typed is my project?" — `rigor check` / `annotate` /
  `type-of` / `triage` / `coverage` answer from what Rigor inferred. A
  concrete inferred type beats any abstract explanation.

This is the user's shortcut: they only ever need to remember two skills —
**`rigor-next-steps`** ("what should we do next?") and **`rigor-ask`**
("answer this about Rigor"). They ask in plain language; *you* turn it
into the right lookup or analysis so they never have to remember the
command.

## The toolbox

Everything here is read-only and needs no network.

### Reading the docs

| Command | Use |
| --- | --- |
| `rigor docs` | The offline doc index (`llms.txt`) — the map. Start here when you don't know which page. |
| `rigor docs --list [manual\|handbook]` | List every bundled page with its path (optionally one category). |
| `rigor docs <name>` | Print a page. `<name>` is a category-qualified path (`handbook/03-narrowing`), a prefixed basename (`03-narrowing`), or a unique short name (`narrowing`). Pages that exist in **both** trees (e.g. `plugins`) must be qualified — `manual/07-plugins` vs `handbook/09-plugins`. |
| `rigor explain <rule>` | The catalogue entry for a diagnostic id (`rigor explain call.undefined-method`) — what it means, why it fires, how to address it. |

### Grounding the answer in the user's code

| Command | Use |
| --- | --- |
| `rigor check <path>` | Run the analysis. Scope it to a file or directory for a quick answer — don't analyse the whole project just to settle one question. `--format json` exposes structured fields (`receiver_type`, `method_name`, `evidence_tier`, …). |
| `rigor annotate <file>` | Reprint the file with the inferred type of each line in the margin — *what Rigor actually sees*. |
| `rigor type-of <file>:<line>:<col>` | The inferred type at one position. |
| `rigor triage` | Cluster the project's diagnostics by rule / receiver / method — for "what's the shape of my errors?". |
| `rigor coverage [--protection]` | Type / type-protection coverage — for "how well-typed is this?" and "where are the holes?". |
| `rigor plugins` | Which plugins are installed and enabled *here* — the honest answer to "does Rigor support <gem/framework>?". |
| `rigor sig-gen <path>` | Generate RBS for code — for "how do I type this?". Offer it and show the result; this project prefers sig-gen over hand-written RBS. |

## Where the answer lives

Classify the question, then go to the page(s) — and, for anything about
*their* code, the command(s) — that own it. When unsure where a page is,
`rigor docs` (the index) or `rigor docs --list handbook` routes you.

| The question is about… | Go to |
| --- | --- |
| **A specific diagnostic** — "why is this flagged?", "what does this error mean?", "is this a false positive?" | `rigor explain <rule>`, then `rigor docs diagnostics`. If it's *their* code, also `rigor annotate <file>` / `rigor type-of` to see the inferred types the rule fired on. |
| **The type model / a concept** — narrowing, refinements, tuple & hash shapes, `Dynamic`, RBS interop, lightweight HKT | The handbook: `rigor docs --list handbook`, then the chapter — `handbook/03-narrowing`, `04-tuples-and-shapes`, `07-rbs-and-extended`, `12-lightweight-hkt`, … |
| **Operating Rigor** — a config key, CLI flag, baseline, plugins, CI, caching | The manual: `rigor docs configuration`, `cli-reference`, `baseline`, `manual/07-plugins`, `ci`, `caching`, `troubleshooting`. |
| **How Rigor compares to another tool** — Sorbet, Steep, RBS, TypeScript, mypy, PHPStan, TypeProf, Go, Rust, Java/C# | The chapter/appendix written for exactly that: `handbook/10-sorbet`, `appendix-steep`, `appendix-typescript`, `appendix-mypy`, `appendix-phpstan`, `appendix-typeprof`, `appendix-rust`, `appendix-go`, `appendix-java-csharp` (`rigor docs --list handbook` shows them all). |
| **Whether Rigor can do X** — generics, Rails, RSpec, a specific gem, concurrency | The handbook for the language feature; for framework/gem support, **`rigor plugins`** (what's actually available in *this* install) plus the per-plugin page `rigor docs rigor-<gem>` (e.g. `rigor docs rigor-sidekiq`) and the catalogue `rigor docs --list manual`. |
| **Writing a type / RBS** — "how do I type this?", an annotation, a signature | Handbook `07-rbs-and-extended` + `11-sig-gen`; manual `rbs-extended-annotations`. Then offer `rigor sig-gen <path>` to generate it (preferred over hand-RBS) and show the output. |
| **What Rigor is / why use it / is it right for me** | Handbook `01-getting-started` for the pitch, `handbook/02-everyday-types` for a quick mental model of the type zoo. Ground "is it right for *my* project" in a scoped `rigor check` / `rigor coverage` so they see Rigor on their real code. |

## Answer from the page, name the page

Quote or paraphrase the relevant passage and **say which page you drew
from** (e.g. "per `rigor docs handbook/03-narrowing` …"), so the user can
re-read it with the same command. Prefer the doc's own wording over a
remembered approximation. When you ran a command against their code, show
the relevant line of output — a concrete inferred type is more convincing
than prose, and it proves the answer rather than asserting it.

## When the question is really "do X for me"

Some questions are a task in disguise: *"how do I get Rigor into CI?"*,
*"how do I shrink this baseline?"*, *"how do I set Rigor up here?"* The
useful reply is **short**: orient the user — what the thing is, the one
decision that actually matters, the rough shape of it — then **hand the
doing to the skill built for it.** Resist pasting the full procedure
inline (the entire CI workflow YAML, the whole baseline-reduction loop):
that skill owns the steps, keeps them correct, and updates as the tool
moves, so duplicating them here only bloats the answer and drifts out of
date. The line is *explaining* the thing (yours) versus *wiring it in*
(the setup skill's).

A good hand-off is two or three sentences of orientation plus the pointer:

- setup / "what next?" → **`rigor-next-steps`** (it probes the project and routes)
- CI → **`rigor-ci-setup`** · editor → **`rigor-editor-setup`** · MCP agent → **`rigor-mcp-setup`**
- baseline reduction → **`rigor-baseline-reduce`** · coverage holes → **`rigor-protection-uplift`**
- a missing gem/DSL → **`rigor-plugin-author`** · monkey-patch clusters → **`rigor-monkeypatch-resolve`**

When in doubt, give less and point — it respects the user's "two skills
to remember" promise and keeps each answer to the part only `rigor-ask`
can give.

## If the docs don't cover it

The bundled set is the **drive-Rigor** corpus (manual + handbook). The
normative **type specification**, the internal spec, and the ADRs are
contributor-facing and stay web-only — they are *not* in `rigor docs`; if
a question genuinely needs them, say so and point at
<https://rigor.typedduck.fail/llms.txt> rather than guessing.

But before you defer, remember Rigor installs from RubyGems **with its
full source** — the per-plugin pages under the gem's `docs/manual/plugins/`,
the analyzer and plugin code under `lib/`. For a detail no doc page spells
out (a plugin's exact rule, a default baked into the code), reading the
bundled file directly is a perfectly good way to ground the answer, and
beats a guess. The rule that never bends: **never invent a flag, rule id,
config key, or behaviour** — read the page, read the source, or run the
command. A confident wrong answer about a type checker is worse than "let
me check."

## Examples

**A diagnostic on their code** — *"Why is Rigor flagging `s.lenght`?"*

```sh
rigor explain call.undefined-method   # what the rule means and why it fires
rigor annotate demo.rb                # the inferred type of `s` on that line
```

Answer from both: Rigor inferred a concrete `String` receiver for `s`,
and `String` has no `lenght` (a typo for `length`) — grounded in what
`annotate` showed, not in a guess.

**A comparison** — *"How is Rigor different from Sorbet?"*

```sh
rigor docs handbook/10-sorbet         # the chapter written for this
```

Answer from the chapter's framing (RBS-superset, gradual `Dynamic`,
inference-first) rather than a remembered summary, and name it so they
can read on.

**A capability** — *"Does Rigor understand our Sidekiq workers?"*

```sh
rigor plugins                          # is rigor-sidekiq enabled in THIS project?
rigor docs rigor-sidekiq               # the per-plugin page: what it teaches Rigor
```

Answer from what's actually installed, plus — if useful — a scoped
`rigor check app/workers` so they see Rigor on their real workers.

**Authoring** — *"How do I type this method?"*

```sh
rigor sig-gen path/to/file.rb          # generate the RBS, show it
rigor docs handbook/07-rbs-and-extended
```

Generate it, show the signature, and explain it from the handbook —
preferring sig-gen's output over hand-written RBS.
