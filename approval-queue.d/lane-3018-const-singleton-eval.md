# A def in `OBJ.singleton_class.instance_eval` is not filed under the constant, and the class-object path reads a new definer-only entry

- **PR:** [#3027](https://github.com/rigortype/rigor/pull/3027)
- **Issue:** [#3018](https://github.com/rigortype/rigor/issues/3018)
- **Class:** open-choice
- **Precedent:** [#339](https://github.com/rigortype/rigor/pull/339)
- **Decided:** 2026-11-10

## Background

The issue asks for each `def` in a `singleton_class.class_eval` / `instance_eval` block on a constant to be filed
under that constant. It also asks for a replacing definer to stop the typing tier from answering, and for the
class-object path to read the same envelope as the plain-object path. Four readings were left open.

## Options and trade-offs

- **`OBJ.singleton_class.instance_eval { def si }`.** Filing it as the issue words it would silence `OBJ.si`.
  Ruby 4.0.5 raises NoMethodError there, because the def lands on the singleton class's own singleton. Leaving it
  unfiled keeps that report. `OBJ.instance_eval { def oi }` already defines on `OBJ` and is already silent.
- **Which defs in the block count.** Option one is direct statements only, which reports a def under an `if`
  that Ruby runs. Option two is every receiverless def except under a nested `class` / `module` / `class <<`
  body or another `def`. That reuses the grandfathered `each_refinement_def` walk, so no producers.yml row is
  needed.
- **Replacement order.** Option one declines only when the replacing definer follows the body def in source. A
  two-file project has no order, so the alternative declines whatever the order. That gives up typing a call
  whose replacer was written first.
- **Class-object evidence.** Reading the opaque `[:singleton, x]` envelope, as the issue words it, silences real
  reports. A receiverless class-body macro naming a symbol (`my_attr :foo`) also makes that envelope opaque, which
  four `#2901`/`#2975` rows pin. A new `[ENVELOPE_OBJECT_SINGLETON_KIND, x]` entry, filed only by the three literal
  definers, keeps those rows.

## Decision

Leave `singleton_class.instance_eval` defs unfiled, count every def except under a nested definee body or `def`,
decline typing whatever the order, and read the new definer-only entry on the class-object path. Each choice
withholds a report only where Ruby defines the method, and keeps reports where it raises. That follows #339, which
scopes recovery to names the project defines.

## To undo

Remove `ScopeIndexer#record_constant_singleton_eval_defs`, `#record_object_singleton`,
`SingletonObjectConstant.replaceable?`, `CheckRules.foreign_singleton_through_ancestors?` and
`Scope::DiscoveryIndex::ENVELOPE_OBJECT_SINGLETON_KIND`, along with `spec/integration/constant_singleton_eval_spec.rb`.
Nothing else reads the new entry.
