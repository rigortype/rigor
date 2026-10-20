# A file outside the configured paths also discovers what it loads with a literal require_relative

- **PR:** [#2236](https://github.com/rigortype/rigor/pull/2236)
- **Issue:** [#2021](https://github.com/rigortype/rigor/issues/2021)
- **Class:** open-choice
- **Precedent:** [#734](https://github.com/rigortype/rigor/pull/734)
- **Decided:** 2026-10-21

## Background

`rigor check plugins/rigor-activejob/lib/rigor/plugin/activejob.rb` in Rigor's own repository (`paths: [lib]`)
reported four `call.undefined-method` on correct code. A run over path arguments widens its discovery to the
configured paths (#684, PR #734), but this file lies outside them, so its sibling `activejob/effects.rb` was never
discovered. The bare `Effects` inside `Rigor::Plugin::Activejob` then fell through the lexical lookup to the
project's `Rigor::Effects`, whose signature lacks the plugin's methods. Checking the plugin's `lib` was clean. The
issue left open whether to widen discovery or to decline the lookup.

## Options and trade-offs

- **Decline.** Treat a lexical lookup that resolves past a namespace the file opens as unknown when the file is
  outside the configured paths. This covers files with no `require_relative`, but it has no principled boundary:
  every fall-through (`Type::Combinator`, `String`) passes such a namespace, so a file checked on its own would
  lose most of its typing and report less than the same file checked with its directory.
- **Widen to the file's directory or a guessed load root** (`lib/`). This is a heuristic about layout, and it
  discovers files the analysed one never loads.
- **Follow `require_relative`.** Ruby loads these files before the file's code runs, so their declarations are in
  scope at runtime. This is the issue's first expected outcome: the file is checked together with the files its
  constants resolve through, with the precision of a directory run. It does not cover a tree loaded by `require`
  against `$LOAD_PATH` or by Zeitwerk, which still reads the outer constant.

## Decision

Follow literal `require_relative` targets, transitively, from analysed files outside the configured paths. A
target under a configured path ends the walk, so a file inside `paths:` is discovered exactly as before, and the
answer for such a file does not depend on whether it was named on the command line. Paths are compared as real paths.
`exclude:` drops a target as it drops a configured file. A walked file is discovered as uncertain: its classes,
modules and constants resolve and its methods exist, but every method contribution is `possible` (ADR-119 WD3), so
no return type, arity or visibility is read from it. The walk sees one entry point's load graph, and a file it does
not reach (through `require`, a computed name, Zeitwerk or another entry point) may redefine a method a walked file
defines; reading the walked body would then report on correct code. What the walk guarantees is therefore:

- a class, module or constant a walked file declares is found before an outer one of the same name;
- a call on a method a walked file defines is not reported as undefined;
- no return type, arity or visibility is read from a walked file's method, so the walk never makes a call's answer
  more precise than the run without it;
- a walked file's def-node, visibility and parameter slots never override a configured file's: the walked files fold
  after every configured file and skip each such slot (instance or singleton) already written, so a walked reopening
  of a configured class does not move those slots' answers.

Ancestry and dynamic-dispatch declarations in a walked file (`include`, `extend`, `prepend`, a `define_method` on a
receiver, `method_missing` / `respond_to_missing?`) still apply, as they do in the run over the walked file's
directory.

Constant VALUE types are still read from walked files, as from any discovered file: `H::LIMIT = 1` in a walked
file makes `H::LIMIT.upcase` report, which is what the run over the walked file's directory reports. A run can also
report a call on a constant it previously left unresolved when the constant's own signature or an analysed file
answers it. The precedent is PR #734's reasoning: a file's
diagnostics should not depend on what else was on the command line, and widening discovery buys that where
declining makes the subset run answer a different question.

## To undo

Remove `Runner#required_outside_paths`, `Runner#required_missing_entries`, `Analysis::RequireRelativeClosure`, the
`uncertain:` parameter of the two `ScopeIndexer` project-index walks and `Certainty.every_contribution`, and the #2021 paragraphs in
`docs/internal-spec/cache.md` and `docs/manual/02-cli-reference.md`. `make verify-changed` then reports the
four false positives again for a change touching `activejob.rb` or `sidekiq.rb`.
