# ADR-117 — Assume the core line readers: `$_` trusts the standard streams and `Kernel#gets`

Status: **Accepted, 2026-09-26.** The explicit-receiver half has held since #1405: `$stdin.gets`,
`STDIN.gets`, `ARGF.gets` and `Kernel.gets` narrow `$_`, and a replacement made outside the file is not
modelled. The spec's gap list for that half now reads as this assumption, and #1411 closes as by design.
The implicit-self half (`while gets`) still declines everywhere and is #1415.

Grounding: the three adversarial review rounds of #1405 (issue #1359), and the probes filed as #1411
and #1415.

## Context

A C-implemented line reader sets its caller's `$_` (`$_` is frame-local, see
[`control-flow-analysis.md`](../type-specification/control-flow-analysis.md) § "Last-line (`$_`)
narrowing"). A reader defined in Ruby does not: `Tempfile#gets`, `Reline`'s `readline`, a test double,
or any object a gem swaps into `$stdin`. Whether a given `gets` is the C one is decided at run time, by
what the program and its gems have put behind `$stdin` or `self`. Static analysis cannot close that
set, because any gem can inject into it.

#1405 first narrowed implicit-self readers in the script body. Each review round then found another way
the reader could be Ruby's: a mixin on `main` (`include Readline`, `class << self; include M; end`),
`def self.gets`, a top-level method called with another `self`, a rebound block `self`, `load(file, M)`,
a DSL's `instance_eval(File.read(f))`. The PR settled on "an implicit-self reader never narrows", which
gave up the most common script idiom (`while gets; $_`). The same argument also reaches the explicit
receivers #1405 kept: another file, or a gem, can reassign `$stdin`.

The spec already has a principle for this. [`overview.md`](../type-specification/overview.md): *the
working program is the most important fact* — a worst-case reading the running program never reaches is
outranked by the runtime evidence.

## Decision

**Rigor assumes that the line readers the program relies on are the core ones.** It trusts
`$stdin` / `STDIN` / `$<` / `ARGF` / `Kernel`, receivers typed as `IO` or its kin, and an implicit-self
`gets` / `readline`. Each is assumed to set the caller's `$_`, unless the analysed code itself shows
otherwise.

The criterion is **the program's evident expectation**. Code that reads `$_` after a reader only works
if the reader set it. If the reader is Ruby's at run time, that code is already broken, and the
narrowing only turns the breakage into a missed report. It never turns into a diagnostic on a program
that works. A worst-case reading ("any reader may be Ruby's") would instead cost precision in every
correct script to guard programs that do not work.

### Working decisions

- **WD1 — In-file counter-evidence still declines.** A replacement the analysed code shows is not
  assumed away, because it is cheap to see and exact when seen:
  - a `def gets` / `def readline` anywhere in the program;
  - in the file being read, a `define_method`-family patch or an `alias` of either name, including
    computed names (`patched_line_readers`, collected by `ScopeIndexer#build_program_global_index`);
  - `$stdin` / `$<` bound in the file to something that is not a core reader;
  - a receiver typed as a known Ruby forwarder (`LastLine::DELEGATING_CLASSES`, today `Tempfile`).

  These live in `lib/rigor/inference/last_line.rb` (`reads_line?`, `reader_global?`, `reader_class?`).
- **WD2 — Replacement outside the file is by design, not a gap.** This covers `$stdin` reassigned in
  another file, a patch installed by a test helper or a String `class_eval`, a test double, a gem's
  injection, and the run modes a file cannot show (`load(file, M)`, a DSL `instance_eval`). Rigor does
  not build a program-wide census of them (#1411's proposal): it could not see gems or run modes anyway.
- **WD3 — Implicit-self readers narrow under the same assumption (#1415).** They narrow in the script
  body and in method bodies, and decline on counter-evidence the file shows about `self`:
  - a mixin into `main` or `Object` in any spelling;
  - a reader defined on `main`;
  - a block whose `self` is rebound (`instance_eval` / `instance_exec`);
  - a class whose ancestry names a Ruby reader.

  A top-level method called with another `self` is the assumed case (WD2's reasoning).
- **WD4 — The stream globals type as IO-compatible.** `$stdin`, `$stdout` and `$stderr` read as their
  RBS declarations (`IO`) when unbound (#1366). A write the file makes joins its value, so a test's
  `$stdout = StringIO.new` keeps `$stdout.string` typed (#1362). Here the assumption is about the type,
  not the reader: `StringIO` and `Tempfile` are IO-compatible for typing, but WD1 still keeps their
  readers from narrowing `$_`.

## Rejected / deferred alternatives

| Alternative | Verdict | Reason |
| --- | --- | --- |
| Narrow only where no replacement is possible (#1405's final reading) | Rejected | No receiver qualifies once gems can inject. It loses `while gets` and contradicts the working-program principle. |
| Program-wide census of stream reassignments and reader patches (#1411) | Rejected | About two dozen touch points (pre-pass, seeding, workers, incremental edges), and it still misses gems, run modes and doubles. The in-file part (WD1) is kept. |
| "IO / StringIO-compatible" as the narrowing criterion | Rejected for `$_`, kept for typing (WD4) | `Tempfile`, doubles and `StringIO` subclasses with a Ruby `gets` are IO-compatible and still leave `$_` alone. The criterion has to be about the reader. |
| Detect destructive stream writes with effect summaries | Deferred to #1367 | Effect summaries already label `$stdin = …` as `global.write`. A generic "stream replaced" warning would flag the common test idiom `$stdout = StringIO.new`. A write Ruby rejects (`$stdout = 1`, no `write`) is #1367's typed-write check. |

## Consequences

- **Positive.** The script idiom `while gets; $_` can be typed again (#1415). The spec states one rule
  instead of a growing list of reader shapes it cannot see.
- **Negative, accepted.** A program that swaps a Ruby reader into a stream and still reads `$_` loses a
  report. By the criterion above, that program already misbehaves.
- **Carry-over.** #1411 closes as by design. #1415 implements WD3. #1366 implements WD4's unbound read.

## Relationship to other ADRs

- Applies the working-program principle of [`overview.md`](../type-specification/overview.md), as
  [ADR-58](58-ivar-field-typing.md) does for declaration-sourced `nil`.
- [ADR-101](101-optimistic-carrier-branch-elision.md) draws the line this assumption must respect: a
  certainty verdict (branch elision, an always-truthy report) may not rest on an optimistic bet alone.
  The core reader's `$_` is exact rather than optimistic, and defending against a `nil` `$_` right after
  one's own reader test (`while $stdin.gets; next if $_.nil?`) is not a shape seen in the corpus.
  **Re-evaluation trigger:** if such a report appears on correct code, mark the narrowing with ADR-101's
  optimistic origin rather than drop it.
