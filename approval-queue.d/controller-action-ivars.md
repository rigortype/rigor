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
  literally a declared name (`ActionController::Base`) matches. An ambiguous spelling (no candidates) and a
  truncated chain do not.

## Decision

The third option. An external superclass the environment *does* know still goes through its first known candidate,
compared by name or by an RBS `:subclass` ordering. The literal match applies only when no candidate resolves. The
risk is a project-local `Foo::ActionController::Base` written as `ActionController::Base` inside `module Foo` with
no declaration anywhere, which only withholds a warning.

## To undo

Replace the `known.nil?` branch of `IvarWriteCollector#per_invocation_entry?` with `return false`. The integration
examples "is silent on divergent writes in two public actions, through an ApplicationController superclass" and "is
silent on a controller that inherits ActionController::API directly" then fail, and #575 reopens.
