# ADR-117 — Standard streams: typed by idiom, checked by runtime contract

Status: **Accepted, 2026-09-26.** One part has held since #1405: `$stdin.gets`, `STDIN.gets`,
`ARGF.gets` and `Kernel.gets` narrow `$_` (WD4), and a replacement the analysed code does not show is
not modelled, so #1411 closes as by design. The rest is open:

| Decision | Tracked in |
| --- | --- |
| WD1, stream reads | #1366, after #1426 and #1427 |
| WD2, write check | #1367 |
| WD3, test-scope view | #1426, #1427 |
| WD4 gap: in-file `def` spellings | #1423 |
| WD5, implicit-self readers | #1415 |
| WD6, `$_` guardrail | binds #1366 |

Grounding: the three review rounds of #1405 (issue #1359), the probes behind #1411 and #1415, and the
review of this ADR (PR #1418).

## Context

In a dynamic language, a value can have two kinds of type. One is what the runtime guarantees. The
other is what the language's idioms lead people to expect. The standard streams show both, and the two
diverge. On Ruby 4.0.5:

- **`$stdin`** — its setter checks nothing. `$stdin = 1` is accepted, so at worst `$stdin` is unknown.
- **`$stdout`, `$stderr` and `$>`** — the setter raises `TypeError` unless the value responds to
  `write`. The runtime guarantees `_Writer`, nothing more.
- **Idiom** — all three hold an `IO`. Tests assign an IO-compatible object for a while, usually a
  `StringIO` (which is not an `IO` subclass), and put the original back.

Ruby code that assumes anything else about a stream, or validates it at run time, is not idiomatic.

`$_` depends on the stream in a sharper way. A C-implemented reader sets its caller's `$_`, but a
reader defined in Ruby does not: `Tempfile#gets`, `Reline`'s `readline`, a test double. `Kernel#gets`
and `ARGF.gets` set `$_` whatever `$stdin` holds, and `Kernel#readline` follows `$stdin`.

#1405's reviews kept finding a `gets` that might be Ruby's, for three reasons: a mixin on `main`, a
patch in another file, and a run mode such as `load(file, M)`. The PR settled on the worst case, which
gave up `while gets; $_`. A gem can inject into the streams at run time, so no static rule closes that
set. The type specification already names the governing principle
([`overview.md`](../type-specification/overview.md)): *the working program is the most important fact.*

## Decision

**Rigor diagnoses only what the runtime enforces, and types reads by the idiom.**

1. **Enforced contract.** Where the runtime enforces a contract on a value, Rigor reports only a write
   that provably violates it, because that write raises.
2. **Idiomatic expectation.** Where the runtime enforces nothing more, Rigor types reads by the
   idiomatic expectation and never warns that a value might deviate from it. Such a warning would fire
   on nearly every correct program and tell its author nothing, crying wolf.
3. **Default, not opt-in.** The expectation holds without any configuration, and making it opt-in is
   the posture Rigor rejects. Evidence that changes it comes from what the analysed code and its
   configuration literally say. The engine never infers it from a file's name or a framework
   convention.
4. **Earned reports.** A report the expectation adds must hold under the idiomatic occupant. An exact
   dead-condition report, such as `puts "tail" if $_` after a `while $stdin.gets` loop, is intended.

### Working decisions

- **WD1 — Reads.** An unbound `$stdin`, `$stdout` or `$stderr` reads as `IO` (#1366).
  - This is the expectation, not a claim about the runtime class. Application code may be running with
    a `StringIO` behind `$stdout` and has no business knowing it.
  - A write the file makes joins its value (#1362).
  - `LastLine.reader_global?` accepts a joined `$stdin` whose members are all core readers, so the join
    does not stop `$_` narrowing.
- **WD2 — Writes.**
  - A write to `$stdout`, `$stderr` or `$>` is checked against `_Writer` only (#1367). `$stdout = 1`
    reports; `$stdout = StringIO.new` or any object with a `write` does not.
  - A write to `$stdin` is never checked.
- **WD3 — The test-scope view.** A test helper that swaps a stream (`config.before { $stdout =
  StringIO.new }`) is a monkey patch in [ADR-17](17-monkey-patch-pre-evaluation.md)'s sense. The
  engine therefore takes it from configuration: a `pre_eval:` entry scoped to the paths it serves,
  whose global writes re-type the global for that scope as the union of the written values (#1426).
  - The onboarding skill `rigor-project-init` writes that entry. It reads the project's own wiring
    (`.rspec`'s `--require`, a test file's `require`), never a file name alone (#1427).
  - Until a project has the entry, `$stdout.string` in a test file reports `call.undefined-method`, as
    any unlisted monkey patch does. The report should point at `pre_eval:`.
- **WD4 — `$_` trusts the core reader.** `$stdin`, `STDIN`, `ARGF`, `Kernel` and receivers typed as `IO`
  or its kin (`StringIO` included: its reader is C) are assumed to set the caller's `$_`. Code that
  reads `$_` after a reader only works if it did. Visible counter-evidence still declines (all in
  `lib/rigor/inference/last_line.rb` unless noted):
  - a `def gets` / `def readline` in a class, module or singleton body anywhere in the program
    (`BlockCallTiming.project_defines_anywhere?`, `block_call_timing.rb` ~L168);
  - in the file, a `define_method`-family patch or an `alias` of either name, computed names included
    (`LastLine.patched_readers` via `ScopeIndexer#build_program_global_index`);
  - `$stdin` bound in the file to a non-reader (`LastLine.reader_global?`);
  - a `Tempfile` receiver (`LastLine::DELEGATING_CLASSES`);
  - a receiver class RBS does not know (`LastLine.reader_class?`).

  A replacement outside the analysed code, other than a `def`, is assumed away: another file, a test
  double, a gem, `load(file, M)`, a DSL `instance_eval`. Three in-file `def` spellings still escape the
  first bullet: `class << $stdin; def gets`, `STDIN.singleton_class.class_eval { def gets }` and
  `$stdin.instance_eval { def gets }` (#1423).
- **WD5 — Implicit-self readers** (`while gets`) narrow under WD4's assumption and decline on evidence
  the file shows about `self`. #1415 holds the canonical list and the acceptance criteria.
- **WD6 — A declined or forgotten `$_` reads `Dynamic[top]`, never its RBS type.** `Scope#forget_last_line`
  unbinds `$_` wherever a reader may have run. An RBS fallback (`$_: String?`) there would report
  correct code such as `if $stdin.gets; items.each(&h); $_.chomp; end`. #1366 MUST exclude `$_` or bind
  it as `untyped_last_line` does, and its `$_` part comes after #1415.

## Rejected alternatives

| Alternative | Reason |
| --- | --- |
| Type `$stdin` by its worst case (unknown) | That is true of the runtime and useless to a reader. Every Ruby program treats `$stdin` as an `IO`. |
| Type `$stdout` reads as `_Writer`, the enforced contract | `$stdout.sync = true`, `$stdout.tty?` and `$stdout.flush` would all report. The contract is for checking writes (WD2), not for typing reads. |
| A hard-coded `IO \| StringIO` | It reads Ruby as a nominal type system. The test view comes from evidence (WD3), not from a fixed union. |
| Pre-evaluate `spec/spec_helper.rb` / `test/test_helper.rb` by default | Framework knowledge biases the engine, and a project with a same-named file that is not a test helper would be evaluated implicitly. The skill reads the wiring instead (WD3). |
| Keep streams `Dynamic` under `test_paths` until configured | `test_paths` auto-detects by directory name, so this is the same name-based bias. A missing patch reports like any other (WD3). |
| Warn about a stream replaced by a non-IO, from effect summaries or otherwise | Crying wolf: `$stdout = StringIO.new` is idiomatic. Only an enforced violation reports (WD2). |
| Narrow `$_` only where no replacement is possible (#1405's final reading), or census replacements program-wide (#1411) | No receiver qualifies once gems can inject, and a census still misses gems, run modes and doubles, at about two dozen touch points. |

## Consequences

- **Positive**
  - Stream reads get useful types.
  - `while gets; $_` can be typed (#1415).
  - Diagnostics on streams are limited to writes that raise.
- **Negative, accepted**
  - A program that swaps a Ruby reader into a stream and still reads `$_` can lose a report, or get one
    that only its replaced reader makes wrong. For example,
    `if $stdin.gets; x = $_ ? 1 : "none"; x.upcase; end` elides the `"none"` arm.
  - A project analysing its tests before #1427 configures it sees `$stdout.string` reported until the
    entry is added.
- **Verification**
  - #1366, #1367, #1415 and #1426 each carry fixtures. The corpus reads `$_` almost nowhere, so
    fixtures carry the evidence.
  - #1415 adds controls for defensive shapes that stay quiet today: `next if $_.nil?`,
    `$_ || "default"`, `case $_ when nil`, `unless $_`.

## Relationship to other ADRs

- Applies the working-program principle of [`overview.md`](../type-specification/overview.md), as
  [ADR-58](58-ivar-field-typing.md) does for declaration-sourced `nil`.
- Extends [ADR-17](17-monkey-patch-pre-evaluation.md): global writes become patches, and entries gain a
  scope (#1426, which amends ADR-17). Framework knowledge stays out of the engine, per AGENTS.md's
  "CLI-first; keep metaprogramming support in the plugin API", and lives in the onboarding skill.
- **Scoped exception to [ADR-101](101-optimistic-carrier-branch-elision.md).**
  - ADR-101 forbids a certainty verdict that rests on knowingly optimistic typing. WD4's truthy-edge
    `String` already drives `if` / `unless` elision.
  - The exception holds because the elided arm runs only when the program is set up with a replaced
    reader, whereas ADR-101's Hash miss happens in normal runs of a correct program.
  - **Re-evaluation trigger:** a fixture or user report of such a verdict on a program that works under
    the core reader. The response is to extend `Inference::OptimisticOrigin` (local and ivar reads
    today) to global reads and mark the narrowing.
