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

The job fails on any firing the PR removes or adds, unless this file lists it: `{base, path, line, column, message,
verdict, reason}`, where a removed firing is `fp-silenced` or `tp-lost` and an added one is `named-mechanism`
(ADR-119 WD2 allows a head firing outside the base's only for a mechanism the change names and a fixture witnesses;
the reason names both). `base` is the merge-base sha the entry was written against, which the job prints; an entry
for another base is reported as ignored and neither adjudicates nor fails. Among the entries for the current base,
one that matches no removed or added row fails the job. So the PR that lands a change fills the file with its own
base, its entries go dormant once it merges (every later PR has a different merge base), and any later PR may
empty it back to `[]`. Rebasing a PR onto a newer master changes its merge base, so update the `base` of its entries.
An entry whose path is under `survivors/` fails the job whatever its verdict: those firings are the floor and the
job also requires them in the head.

## What the job compares

Both engines run under the head's `Gemfile.lock` and the corpus's configuration, so a dependency or configuration
change in a PR can make the base engine fail loudly; the job then fails rather than compare.
