# Hold a declared-parameter ivar write to parity with a literal write

- **PR:** [#2199](https://github.com/rigortype/rigor/pull/2199)
- **Issue:** [#1154](https://github.com/rigortype/rigor/issues/1154)
- **Class:** open-choice
- **Precedent:** [ADR-58](../docs/adr/58-ivar-field-typing.md)
- **Decided:** 2026-10-21

## Background

#1154 types `@x = x` with the parameter's declared type. The census is per file and flow-free, so other code may overwrite the ivar unseen. Review rounds 1 and 2 of #2199 ran on an earlier design (a single-file gate and a list of named writers) and kept finding writer spellings it missed; the revision answering round 2 replaced the list with a rule that declined every credit in a project holding any open-world writer anywhere (`o.extend(M)`, a computed `send`, `instance_eval(&b)`, …). Measured on herb, textbringer, kramdown, alba, mail, yard, redmine and Rigor's own `lib/`, every one holds such a writer, so the rule credited nothing anywhere. Meanwhile the ADR-58 census already accepts every one of those writers for a literal write: `@x = 1` in `initialize` reads `1` in sibling methods whatever an unknown object does, and `ReflectiveIvarWrite` (`lib/rigor/inference/reflective_ivar_write.rb`) leaves `o.instance_variable_set` alone.

## Options and trade-offs

- **Project-wide decline** (round 3). No new false positive from an unseen writer; zero yield on every surveyed project, so #1154 delivers nothing.
- **Parity with a literal write** (taken). Decline where the class, its ancestors or code naming the ivar answer for it: an ancestor writer or setter, a non-core superclass, an open-world writer on `self` in an instance body of the class or an ancestor (`[:ivar_set_class, K]`), a second file writing the same ivar in an instance body of the class (`[:own_write, K, @x, path]`), a named foreign write (`[:ivar_set, @x]`). A writer on an object the census cannot place records nothing. The cost: when such a writer stores a value of another type, a sibling reports on the declared type, a false positive of exactly the class a literal write already carries.
- **sig-gen only.** Use the declared parameter type for `rigor sig-gen` proposals and not in `rigor check`. No new check finding, but it contradicts the maintainer's decision of 2026-10-20 (#1154, point 4: the engine uses it), and a proposal `check` does not believe is a contract the user then writes into `sig/`.

## Decision

Parity, by the precedent of the ADR-58 literal-write census and `ReflectiveIvarWrite`: an ivar's seed has never answered for code on an object the analysis cannot place, and the declared parameter type is a contract (ADR-1), at least as strong as a literal. The PR body's yield table and new-row classification are the evidence.

## To undo

Restore a project-wide entry in `Inference::IvarWriterCensus` for a writer on an unknown receiver (an `[:ivar_set_any]` the gate declines on) and its incremental key, or drop the check-side credit and keep it for sig-gen (`ScopeIndexer.index`'s `ivar_writer_scope:` and the census `declared` override). Nothing else depends on the parity reading.
