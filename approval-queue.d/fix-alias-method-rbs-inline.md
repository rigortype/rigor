# Treat a class only rbs-inline declares as the project's own declaration, for all three readers

- **PR:** [#2172](https://github.com/rigortype/rigor/pull/2172)
- **Issue:** [#1934](https://github.com/rigortype/rigor/issues/1934)
- **Class:** open-choice
- **Precedent:** [#737](https://github.com/rigortype/rigor/pull/737)
- **Decided:** 2026-10-20

## Background

#1934 reported `call.undefined-method` on `alias_method :title, :label` in an rbs-inline file, called from another file. The cause was that `RbsLoader#project_declared_classes`, the #735 test of "this class's RBS is the project's own, so a method another project file defines is not a monkey-patch", counted only `sig/` buffers. RBS that rbs-inline synthesizes from the project's own source read as a bundled declaration. The issue asked for no diagnostic but did not say whether the fix should live in that predicate, which has two other readers, or in a narrower place.

## Options and trade-offs

- **Widen `project_declared_classes` (taken).** A class counts when every declaration of it is a `virtual:` buffer or a `sig/` file. This fixes `alias_method` of every shape, and a plain `def` in a sibling file, which drew the same report. The other two readers follow: `call.wrong-arity`'s source lane (#992) checks a cross-file `def` that no member declares against its own envelope, and `ExpressionTyper#overriding_own_def?` (#744) re-types a subclass override instead of trusting an inline-declared ancestor's signature. Both readers already treat a `sig/` class and an RBS-unknown class this way, so an inline-only class now gets the same treatment.
- **Suppress only alias rows in `call.undefined-method`.** Narrower, but it leaves the sibling-file `def` report on correct code, and the three readers would disagree about whose class this is.
- **Translate `alias_method` in the plugin.** This gives `title` its target's contract but does not fix the sibling `def`. It also has three shapes that would fail the class's whole definition build (see #2171), so it is deferred there rather than made the fix.

## Decision

Widen the predicate. #737 (#735) set the reading that a declaration the project wrote describes the source under analysis. RBS synthesized from that same source fits the reading more directly than a hand-written sidecar does. A bundled class that an inline file reopens is excluded by the every-declaration test, so ADR-17's monkey-patch report on core, stdlib and gem classes is unchanged.

## To undo

Drop `inline_only_entry?` from `build_project_declared_classes` in `lib/rigor/environment/rbs_loader.rb`, and revert the spec text in `docs/internal-spec/reflection.md` and `docs/type-specification/diagnostic-policy.md`. `spec/integration/rbs_inline_cross_file_method_spec.rb` would then need its alias and sibling-`def` rows flipped. Nothing else depends on it.
