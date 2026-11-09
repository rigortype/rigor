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
- Mark only the calls written in the class body itself: its statements through control flow, any block written there
  (`KINDS.each { … }`, a concern's `included do`), and a `def self.` body. Instance `def`s stay closed. Review round 1
  widened the blocks from a core iterator's on a literal receiver (the reach `MainSelfCalls` has for `main`) to every
  block, since a `?` mark only silences.
- A hook parameter's `base.send(meth, M)` in a `self.included(base)`-style hook, read wherever the hook is, as the
  literal `base.send(:include, M)` is (#2991): the enclosing module's instance side lists the marker when the name may be
  `include` / `prepend`, and its sides are tainted without it otherwise.
- For the name: treat every computed name as a possible mixin, or read a local of the call's scope bound only by
  name-literal writes as those names, and an interpolation with a literal part no mixin name contains as no mixin.
- For a local bound to `:include`: record its module as `include M` would be, or list the unnamed marker.

## Decision

The second reach with the hook-parameter reading, the literal-local and interpolation reading, and the unnamed marker for a local bound to a mixin
name. With every class-body block in reach, the survey corpus (48 projects) has 29 class-body computed-name sends with a
further argument: 19 mark (in about a dozen classes, most of them Rails test classes and railties), 8 are interpolations
the literal-part rule leaves closed, and 2 are locals bound to non-mixin literals. No hook parameter's computed `send`
appears. So the open stays narrow without more machinery. Recording `meth = :include` as `include M` would need the name
resolution in every `mixin_call_view` reader; the marker is the false-positive-safe answer #2993 gives an unnamed
include, and it costs only the reports on that class.

## To undo

Drop `local_send_names` and `literal_send_name`'s interpolation arm to mark every computed name; pass
`instance_defs: true` to `MainSelfCalls.collect` in `MixinAccumulator#class_body_scope` to widen the reach. Nothing
depends on the narrowing beyond the rows in `spec/integration/computed_send_mixin_spec.rb`.
