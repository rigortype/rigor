# A class-body computed-name send lists the unnamed marker unless its name is provably no mixin's

- **PR:** [#3021](https://github.com/rigortype/rigor/pull/3021)
- **Issue:** [#3006](https://github.com/rigortype/rigor/issues/3006)
- **Class:** open-choice
- **Precedent:** [#2993](https://github.com/rigortype/rigor/pull/2993)
- **Decided:** 2026-11-09

## Background

Issue #3006 asked that a class-body `send` / `public_send` / `__send__` with a computed name and a further argument
list the unnamed marker, and left open how narrow to keep it: which call sites count as the class body, which names
are provably not a mixin's, and whether a local bound to `:include` is recorded as the literal call would be.

## Options and trade-offs

- Mark every computed `send` with arguments in the class's subtree. Simplest, but a `send(attr, value)` in an
  instance method is common and would open the class on every such call, though `include` cannot run there.
- Mark only the calls whose `self` is the class: the body's own statements through control flow, a core iterator's
  block on a literal receiver, and a `def self.` body (the reach `MainSelfCalls` already has for `main`). Instance
  `def`s and other blocks stay closed.
- For the name: treat every computed name as a possible mixin, or read a local of the call's scope bound only by
  name-literal writes as those names, and an interpolation with a literal part no mixin name contains as no mixin.
- For a local bound to `:include`: record its module as `include M` would be, or list the unnamed marker.

## Decision

The second reach, the literal-local and interpolation reading, and the unnamed marker for a local bound to a mixin
name. The survey corpus has 5 class-body computed-name sends with a further argument across 48 projects (4 in a Rails
test's literal-array `each`, 1 in redmine's `Setting.set_from_params`, which the interpolation rule leaves closed), so
the open stays narrow without more machinery. Recording `meth = :include` as `include M` would need the name
resolution in every `mixin_call_view` reader; the marker is the false-positive-safe answer #2993 gives an unnamed
include, and it costs only the reports on that class.

## To undo

Drop `local_send_names` and `literal_send_name`'s interpolation arm to mark every computed name; pass
`instance_defs: true` to `MainSelfCalls.collect` in `MixinAccumulator#class_body_scope` to widen the reach. Nothing
depends on the narrowing beyond the rows in `spec/integration/computed_send_mixin_spec.rb`.
