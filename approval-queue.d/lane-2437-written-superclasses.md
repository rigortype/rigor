# sig-gen demotes a subclass whose project superclass it does not write, rather than writing an empty shell for the superclass

- **PR:** [#2478](https://github.com/rigortype/rigor/pull/2478)
- **Issue:** [#2437](https://github.com/rigortype/rigor/issues/2437)
- **Class:** open-choice
- **Precedent:** [#2454](https://github.com/rigortype/rigor/pull/2454)
- **Decided:** 2026-10-28

## Background

`Generator#declared_by_run` counted every candidate's class as declared by the run, including a class whose
every method was skipped. Its subclasses were written `< ::That::Class`, and the next run failed with
`RBS::NoSuperclassFoundError`. Issue #2461 found the same over-count for a class shell on a `sig/` file the writer
refuses (unparseable or not valid UTF-8). The issue left two fixes open: write an empty shell for the skipped
superclass, or count only what reaches disk and demote the subclass. The coordinator ruled for demotion and asked
for the trade-off to be recorded here.

## Options and trade-offs

- **Demote the subclass (taken).** Only a class the writer will put on disk counts: one with a candidate it is
  sure to write to a target it accepts, a class shell on such a file, or a wrapper namespace of either. A subclass
  whose chain reaches anything else is skipped with `:unresolvable_superclass`, as for a gem superclass with no RBS
  (#735). The cost is coverage: every subclass of an all-skipped base loses its declaration and goes back to
  source inference, the state before sig-gen ran. On mastodon that is about 70 `BaseService` subclasses.
- **Write an empty shell for the superclass.** This keeps the subclasses' declarations, but an empty
  `class TextBase < ::Lib::Base` closes `TextBase`: a source-only class is open, and a declared one is not. Any
  method it gets from a mixin, `method_missing` or a file outside `paths:` then fires `call.undefined-method`, the
  #2438 false positive. Measured on a fixture: with an empty `sig/` declaration, `TextBase.new.nope` fires; without
  it, it is silent.

## Decision

Demote. A correct but thin result beats a collapsed or falsely closed one (ADR-5, and AGENTS.md's false-positive
rule). It follows #2454, which already counted a shell only when its file is written; this extends the same rule
to the class's own candidates and to the target file. The sig-gen warning now tells a superclass the project
declares (and would close if written) apart from one no source or RBS declares, and advises typing the superclass,
fixing its `sig/` file, or hand-writing its declaration, instead of `rbs collection install`.

## To undo

Restore the `acc << candidate.class_name` line in `declared_by_run` and drop `written?`'s target check in
`lib/rigor/sig_gen/generator.rb`. The subclasses then come back, with the `NoSuperclassFoundError` the issue
reports. The warning split in `CLI::SigGenCommand#report_unresolvable_superclasses` can stay either way.
