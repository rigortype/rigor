# Arity differential fixtures

The corpus of the `Arity differential` CI job (`tool/engine_diag_diff.rb`, ADR-119 WD2 "The `SourceArity`
differential"), together with `../declaration_witness/`: shapes that fire `call.wrong-arity` today. Unlike the witness
directory, nothing here is executed by a spec; each file is only analysed.

- The files here are shapes a change to `SourceArity`'s decision point is MEANT to silence (#1570, conditional
  `def` and `include`).
- `survivors/` holds firings it must KEEP. The job's floor counts only those rows, so silencing an ordinary true
  positive cannot hide behind the intended removals. Each is a real arity error under Ruby; verify a new one with
  `ruby -e 'load ARGV[0]'`.

## `arity_adjudication.yml`

The job fails on any firing the PR removes or adds, unless this file lists it: `{path, line, column, message,
verdict, reason}`, where a removed firing is `fp-silenced` or `tp-lost` and an added one is `named-mechanism`
(ADR-119 WD2 allows a head firing outside the base's only for a mechanism the change names and a fixture witnesses;
the reason names both). It also fails on an entry matching no removed or added row. So the file lists only the
current PR's differences: the PR that lands a change fills it, and the next PR, whose merge base already carries that
change, empties it back to `[]`.

## What the job compares

Both engines run under the head's `Gemfile.lock` and the corpus's configuration, so a dependency or configuration
change in a PR can make the base engine fail loudly; the job then fails rather than compare.
