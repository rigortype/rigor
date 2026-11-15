# ADR-43's claim that the `rbs_complete_ancestors` bridge carries the negative call rules onto a subclass receiver is withdrawn, and the engine's silence kept

- **PR:** [#3240](https://github.com/rigortype/rigor/pull/3240)
- **Issue:** [#3246](https://github.com/rigortype/rigor/issues/3246)
- **Class:** open-choice
- **Precedent:** [ADR-5](../docs/adr/5-robustness-principle.md)
- **Decided:** 2026-11-15

## Background

ADR-43 lets a Ruby-source subclass of an allow-listed RBS-only ancestor resolve its inherited calls
against that ancestor's RBS. Its Decision says that resolution makes "the normal
`call.undefined-method` / `call.wrong-arity` / override rules apply to inherited contract calls",
and `docs/internal-spec/inference-engine.md` restated it as "MUST be observationally identical to
dispatching directly against that ancestor's RBS".

The engine does not do that. `CheckRules` gates every signature-reading rule on the **receiver's
own** class being RBS-known (`return nil unless Rigor::Reflection.rbs_class_known?(class_name,
scope: scope)`), and a bridged subclass is by construction absent from RBS — that absence is the
precondition the bridge exists to work around. So `call.undefined-method`, `call.wrong-arity` and
`call.argument-type-mismatch` all decline on any call whose receiver is the subclass, including a
call to a member the ancestor's RBS declares completely. That gate predates ADR-43 and is not a
deliberate guard for it; the silence is incidental.

The two documents and the engine therefore disagreed, and the disagreement had to be resolved one
way or the other before #3240 (which corrects the rigor-graphql comment that describes this
behaviour) could land. #3246 recorded the open question.

ADR-43's Context had argued that "the precision gain and the risk flow through the same resolution
path — you cannot get one without the other", and the Decision was written on that premise. The
premise is false: resolution lives in `RbsDispatch` and rule-gating in `CheckRules`, and they gate
independently.

## Options and trade-offs

**A — the engine is right; amend ADR-43 and the internal spec.** Costs the documents' claim and
the precision the rules would add on a subclass receiver; a contract misuse written inside a
subclass stays unreported. Buys zero new false-positive surface, and no engine change.

**B — ADR-43 is right; the engine has a gap.** Buys teeth on a subclass receiver, which is where a
plugin author actually writes the DSL. Costs an engine change that must thread false-positive
protection through four resolution paths that currently need none — the superclass bridge, the
extend-edge twin, the included-module arm and the core/stdlib arm — on classes whose runtime
surface is wider than any signature. All three consumers of the feature (rigor-grape,
rigor-graphql, rigor-sorbet) wrap DSLs whose method surface is generated at runtime, and
graphql-ruby ships no RBS at all, so the plugin's bundled signature is the whole authority for what
exists.

## Decision

**A.** ADR-43's Decision is amended, the two documents corrected, and the engine left as it is.

Three things decide it. The premise the Decision rested on turned out false, and a decision whose
stated reason has gone does not keep its conclusion by inertia. The misuse case ADR-43 was written
for is already caught: a directly constructed `Rigor::Plugin::Manifest.new(...)` types as
`Nominal[Manifest]`, an RBS-known class, and `m.totally_bogus_method` fires today — the spike's own
finding and WD6's end-to-end `manifest.bogus` check both read that receiver, so what B would add is
the part that was never the motivation. And ADR-5's asymmetry points the other way here: with three
runtime-generated DSL surfaces as the only consumers, a finding on a correct program costs more
than the missed finding.

The narrower option is recorded as open, not taken: `call.wrong-arity` and
`call.argument-type-mismatch` for a call to a name the ancestor's RBS **declares**, without
`call.undefined-method` and without claiming the subclass's surface is closed. It needs its own
false-positive measurement over the three consumers.

`spec/integration/plugins/graphql_plugin_spec.rb` pins both halves of the behaviour the amendment
now describes: the subclass fixture passes `description 42` / `graphql_name 42` to declared members
and reports nothing, while the control arms all three rules on
`GraphQL::Types::Relay::PageInfo` as a direct receiver.

## To undo

Reverting means taking option B: re-arming the three rules when the receiver's class is
RBS-unknown but reached the bridge, with a false-positive measurement over `plugins/` and
`examples/` before flag-on, and restoring the ADR-43 and `inference-engine.md` wording this entry
removed. Nothing has been built on the amendment beyond the rigor-graphql comment and
`docs/internal-spec/plugin.md`'s `rbs_complete_ancestors` row, both of which describe behaviour
rather than depend on it.
