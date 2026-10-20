# Warn on a legacy alias severity key instead of honouring it

- **PR:** [#2223](https://github.com/rigortype/rigor/pull/2223)
- **Issue:** [#2005](https://github.com/rigortype/rigor/issues/2005)
- **Class:** open-choice
- **Precedent:** none — sets one
- **Decided:** 2026-10-21

## Background

`severity_overrides:` keyed by a legacy unprefixed alias (`undefined-method: "off"`) reached no diagnostic row. `disable:` accepts the same alias, because it expands aliases to canonical ids (ADR-8 backward compatibility). The severity resolver matches canonical ids only, so the alias key was inert: the row kept its `error` severity and nothing told the user. #2005 offered two fixes: honour the alias, mapping it to the canonical id, or warn that the key has no effect. The issue does not choose between them, and honouring changes which diagnostics a configuration drops, so the choice belonged to the maintainer.

## Options and trade-offs

- **Warn, keep the key inert (taken).** `ConfigAudit` reports the key, names the canonical id, and says the override has no effect. No configuration that works today changes behaviour; the cost is that a user who wrote an alias key on purpose must rewrite it.
- **Honour the alias.** The key would map to its canonical id, as `disable:` does. Users with an alias key would see rows re-stamped or dropped that they did not see before. That is a user-visible behaviour change, and it would widen one spelling of the override map.

## Decision

Warn. The conservative option says more and changes no existing result, and the issue leaves the honouring question open. Honouring can follow as its own decision once the maintainer has ratified this one. Precedent: none; this sets one for alias keys in `severity_overrides:`.

## To undo

To honour the alias: have `SeverityProfile.resolve` (or `row_override`) map a key found in `CheckRules::LEGACY_RULE_ALIASES` to its canonical id, then delete the `legacy_alias_problem` warning in `lib/rigor/config_audit.rb` and invert the "flags a legacy unprefixed alias" example in `spec/rigor/config_audit_spec.rb`. The runner spec `spec/rigor/analysis/severity_override_legacy_alias_spec.rb` would then need its `undefined-method` example changed to expect the row dropped.
