# A selected core_root: still loads Rigor's core overlay, Ruby 4.1 additions included

- **PR:** [#2518](https://github.com/rigortype/rigor/pull/2518)
- **Issue:** [#2517](https://github.com/rigortype/rigor/issues/2517)
- **Class:** scope
- **Precedent:** none — sets one
- **Decided:** 2026-10-31

## Background

#2517 asks for `core_root:`, a core signature directory loaded in place of the `rbs` gem's core, and says
Rigor's own core overlays must not reintroduce APIs absent from the selected target. `data/core_overlay/`
does two things. It fills genuine holes in upstream core, such as `Numeric#to_f` and `StringIO`'s
`Enumerable`. It also declares Ruby 4.1 methods that no rbs release through 4.2 has (`Integer#bit_count`,
`String#bit_*`, `Range#clamp`, `Module#descendants`, …), unconditionally per ADR-121, because gating them on
`target_ruby` would report every correct 4.1 call under the default target. On a 3.3 core those 4.1 methods
are absent from the target, and the overlay adds them back.

The overlay does not reintroduce anything rbs-shifter's current rules remove (`Array#rfind`, `String#strip`
with arguments). The PR's specs check both.

## Options and trade-offs

- **Keep the overlay as is (taken).** No new mechanism. The cost is false negatives only: on a 3.3 core,
  `5.bit_count` is accepted. No correct program gets a new finding.
- **Skip `data/core_overlay/` entirely when a core is selected.** This also drops the hole-filling
  declarations, and turns correct calls such as `Numeric#to_f` into `call.undefined-method`: false
  positives, which AGENTS.md ranks above misses.
- **Gate the Ruby 4.1 entries on the selected core.** This is the right end state. It needs the 4.1
  declarations tagged by version (they are mixed into files with hole fillers) and a rule for what a
  selected core "is". It is larger than the interface #2517 asks for.

## Decision

The overlay loads unchanged on top of a selected core, and target-aware gating of its version-specific
entries is left for a follow-up. ADR-121's own trade-off (misses over false positives) is the closest
reasoning. No earlier decision covers a replaced core, so this sets the precedent that the overlay's
hole fillers apply to any core.

## To undo

Gate or skip `RbsLoader.add_bundled_signatures`'s `core_overlay_sig_paths` loop when the loader's
`core_root` is set. Nothing depends on the overlay loading there except the specs that assert core
classification parity, which do not involve the 4.1 entries.
