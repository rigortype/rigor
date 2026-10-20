# Warn on a legacy alias severity key instead of honouring it

- **PR:** [#2223](https://github.com/rigortype/rigor/pull/2223)
- **Issue:** [#2005](https://github.com/rigortype/rigor/issues/2005)
- **Class:** open-choice
- **Precedent:** [#2000](https://github.com/rigortype/rigor/pull/2000)
- **Decided:** 2026-10-21

## Background

A `severity_overrides:` key that is a legacy unprefixed alias (`undefined-method: "off"`) reached no diagnostic row. `disable:` accepts the same alias and expands it to its canonical id, as ADR-8 § "Backward compatibility" asks for `disable:` names. The severity resolver matches canonical ids only, so the alias key was inert: the row kept its `error` severity and nothing told the user. #2005 offered two fixes: honour the alias, mapping it to the canonical id, or warn that the key has no effect. The issue does not choose between them, and honouring changes which diagnostics a configuration drops, so the choice was left to the maintainer.

## Options and trade-offs

- **Warn, keep the key inert (taken).** `ConfigAudit` reports the key, names the canonical id, and says the override has no effect. No configuration that works today changes behaviour. The cost: a user who wrote an alias key on purpose must rewrite it to the canonical id. The warning is the same kind #1953 and #1985 added for other inert keys, so it follows the precedent exactly.
- **Honour the alias.** The key would map to its canonical id, as `disable:` does. The argument for it is ADR-8 § "Backward compatibility": a legacy name that works in one key should work in its sibling. The cost is that users with an alias key see rows re-stamped or dropped that they did not see before. That is a user-visible behaviour change, and it adds a second spelling the override map must resolve.

## Decision

Warn. The precedent is #2000 (which shipped #1953 and #1985): it made `severity_overrides:` keys answer by qualified id and warn about an inert key, rather than give an inert key a new meaning. `docs/type-specification/diagnostic-policy.md` line 94 states the same rule. The conservative option changes no existing result. The ADR-8 argument for honouring is real and is the case for a follow-up decision, not for this one. Honouring can follow once the maintainer has ratified this entry.

## To undo

To honour the alias: have `SeverityProfile.resolve` (or `row_override`) map a key found in `CheckRules::LEGACY_RULE_ALIASES` to its canonical id; remove the `legacy_alias_problem` warning in `lib/rigor/config_audit.rb`; amend `docs/type-specification/diagnostic-policy.md` line 94, which now says the alias is not mapped, and the warning sentence on the audit's reasons; invert the "flags a legacy unprefixed alias" example in `spec/rigor/config_audit_spec.rb`; and change the `undefined-method` example in `spec/rigor/analysis/severity_override_legacy_alias_spec.rb` to expect the row dropped. The CLI examples in `spec/rigor/cli/check_command_spec.rb` and the `docs/manual/03-configuration.md` example would also change.
