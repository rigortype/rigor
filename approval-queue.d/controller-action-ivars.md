# Match an undeclared external superclass by its written name when deciding per-invocation descent

- **PR:** [#2307](https://github.com/rigortype/rigor/pull/2307)
- **Issue:** [#575](https://github.com/rigortype/rigor/issues/575)
- **Class:** open-choice
- **Precedent:** none — sets one
- **Decided:** 2026-10-22

## Background

ADR-125 lets a plugin declare per-invocation classes, and `def.ivar-write-mismatch` asks whether a class descends from
one by reading the class's resolution chain. The brief said to use the class-ancestry machinery. That machinery
resolves an external superclass (`< ActionController::Base`) only through the RBS environment. But rigor-actionpack
leaves `ActionController::Base` and `ActionController::API` undeclared on purpose: declaring them would close every
controller's method surface (see `plugins/rigor-actionpack/sig/action_controller.rbs`). Without a fallback, the
carve-out would never fire for the plugin that motivated it.

## Options and trade-offs

- **Require an RBS-known superclass.** Silences nothing in a Rails app without controller signatures, so #575 stays
  open.
- **Declare the two classes in the plugin's RBS.** Turns `render`, `before_action` and the rest into
  `call.undefined-method` on working code. Rejected.
- **Match the written name when the environment knows none of the candidate spellings.** A candidate that is
  literally a declared name (`ActionController::Base`) matches, unless some candidate names a class the project
  declares. An ambiguous spelling (no candidates) and a truncated chain do not.

## Decision

The third option. An external superclass the environment *does* know still goes through its first known candidate,
compared by name or by an RBS `:subclass` ordering. The literal match applies only when no candidate resolves, and it is
skipped when any candidate names a class the project declares: in `module MyApp; module ActionController; class
Base; end; end; class Report < ActionController::Base`, the spelling resolves to the project's empty class, and the
rule keeps firing (pinned). The remaining risk is a spelling whose other candidate the project neither declares nor
loads from RBS, which Ruby itself could not resolve to anything but the declared name.

## To undo

Replace the `known.nil?` branch of `IvarWriteCollector#matched_declarations` with `return nil`. The integration
examples "is silent on divergent writes in two public actions, through an ApplicationController superclass" and "is
silent on a controller that inherits ActionController::API directly" then fail, and #575 reopens.
