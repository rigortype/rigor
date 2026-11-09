# Two new producers.yml rows for the concern reader, and the grandfathered pin lowered by one

- **PR:** [#3014](https://github.com/rigortype/rigor/pull/3014)
- **Issue:** [#3005](https://github.com/rigortype/rigor/issues/3005)
- **Class:** gate-row
- **Precedent:** [#3003](https://github.com/rigortype/rigor/pull/3003)
- **Decided:** 2026-11-09

## Background

The declaration-producers tripwire (`spec/rigor/declaration_facts/producers.yml`, ADR-119 WD6) flags two methods
#3005 adds:

- `ScopeIndexer#record_hook_block_singleton_defs`, which files a concern block's `def self.x` on
  `Owner::<included>`;
- `SyntheticMethodScanner#concern_extend_arguments`, split out of `concern_module_body?` to read the `self.extend` and
  `send(:extend, …)` spellings.

Once that check moved out, `concern_module_body?` is no longer a producer, and its grandfathered row went with it.
The `record_concern_class_methods` row gained a clause saying its hook blocks are read in every body.

## Options and trade-offs

- Add the rows with reasons, delete the stale grandfathered row, and set `grandfathered_pin` to the count and
  digest the spec reports (366). The spec's message names this as the review point for a removed grandfathered
  entry.
- Keep the extend check inline in `concern_module_body?` so that its row stays. The code would take that shape
  only to satisfy the gate.

## Decision

The first option. #3003 (rows for the hook recorders) and `c579f8015` (the pin lowered when a grandfathered entry
went) are the precedents.

## To undo

Delete the two rows and restore the `concern_module_body?` row and the 367 pin, together with the code.
