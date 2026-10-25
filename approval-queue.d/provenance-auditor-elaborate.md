# Mark the Set-element declarations that the elaborated provenance comparison now reads as divergent

- **PR:** [#2365](https://github.com/rigortype/rigor/pull/2365)
- **Issue:** [#2317](https://github.com/rigortype/rigor/issues/2317)
- **Class:** gate-row
- **Precedent:** [#2316](https://github.com/rigortype/rigor/pull/2316)
- **Decided:** 2026-10-26

## Background

`SigProvenanceAuditor` compared a declaration's return with the raw inferred carrier. A written `Set` is
`Set[untyped]` in what sig-gen proposes (#2177), so a hand-written `Set[String]` that matched the raw carrier counted
as `generated` while sig-gen would have written something else. #2317 made the classifier elaborate the inferred
return through `TypeElaborator` before comparing, which is the correct gate. It moved six hand-written Set returns
off their earlier class: five that read `generated` (`scope.rbs` `discovered_global_write_census`,
`published_constant_names`, `local_constant_names`, `discovered_class_sources` and `constant_sources`) and one that
read `parameter_intent` (`inference.rbs` `ScopeIndexer#finalize_constant_writes`, through its second return element).
Each now reads `declared_divergent` and, unmarked, counts against the residue pin.
The gate had no decision for that: a residue pin rising, or a marker, is a choice the coordinator owns.

## Options and trade-offs

- Mark each row `# authored:` with its element type by contract, in the wording #2316 used for the three
  Set readers already marked (`struct_fold_safe_locals`, `published_constant_sourced`, `declaration_sourced`).
  Costs six comment blocks in `sig/` and no change to any declaration text. Buys a pin that stays where it was
  before the classifier change, and the reason is stated where a reader looks.
- Leave the six rows unmarked and raise `scope.rbs` 43 to 48 and `inference.rbs` 83 to 84. Costs a higher residue
  count that says nothing new, and a ratchet that reads as an engine regression. Buys no `sig/` edits.
- Make sig-gen propose the declared element. Rejected: it would weaken the #2177 rule that a written Set's element
  stays `untyped`, and it is engine work, not a gate fix.

The element type of each marker was checked against its write site: census entries are Arrays led by a Symbol
kind, `class_sources` and `constant_sources` hold source paths, and `published_constant_names` and
`local_constant_names` hold constant names, all Strings.

## Decision

Mark the six rows, and return both pins to their pre-PR values (`scope.rbs` 43, `inference.rbs` 83). The
precedent #2316 fits this closely: the same elaboration gap, the same marker wording, and the same ratchet
arithmetic. The three files whose rows now classify `generated` (a bare `Array` elaborated to `Array[untyped]`, the
spelling the declaration already names) drop from 1 to 0 in the same PR, a tightening.

## To undo

Remove the six `# authored:` blocks and restore the pins to `scope.rbs` 48 and `inference.rbs` 84. The rows then
read as residue again. Reverting the classifier change in PR #2365 (its commit "Classify sig/ returns on the
elaborated type sig-gen writes") returns the raw comparison, under which the six rows read `generated` again and
the markers would be unnecessary.
