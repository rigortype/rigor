# The producers gate reads rule (v) from a table of file, module and roots; a file with no roots starts at what other files call on its module; and a stale row fails in an example of its own

- **PR:** [#3387](https://github.com/rigortype/rigor/pull/3387)
- **Issue:** [#3346](https://github.com/rigortype/rigor/issues/3346)
- **Class:** open-choice
- **Precedent:** [ADR-119](../docs/adr/119-discovery-fact-certainty.md)
- **Decided:** 2026-11-25

## Background

Slice G0 of ADR-116's amendment for #3346 asks that the producer tripwire's rule (v) (ADR-119 WD6: the
methods reachable from an entry point that write into a table parameter) read a table of file, module
and that file's own roots, that a module be "matched as a fully qualified suffix", and that "a root
missing from its file fails". It needs this before any code moves: without a row for the new file, the
next three slices would stop finding rows that only rule (v) marks (5 of 7 for `DeclarationWalk::Rules`,
7 of 7 for the declaration signature, 1 of 2 for the program-globals seed, measured by moving each unit
in memory; the last two units taken as the closures of `declaration_signature` and
`seed_program_globals`). The amendment left four things open: what a file with no roots of its own starts from,
what exactly "suffix" compares, where the failure for a stale row surfaces, and whether the admission
census's owner directory changes.

## Options and trade-offs

**A file with no roots of its own.**

- *Reached from the other files' roots through cross-file calls.* The narrower reading, and it needs a
  call graph across files that the gate does not have.
- *A root set of its own: every method another covered file calls on its module is a root*, whether or
  not the caller is reachable. This is what the gate has done for `NodePropagation` since #3311, and it
  is a superset of the first. Moving each of the three units in memory with one `roots: []` row re-keys
  exactly that unit's rows (7, 7 and 2) and changes no other row.

**What "suffix" compares.**

- *The end of the receiver's text*, as `end_with?("ScopeIndexer", "NodePropagation")` did. A row for
  `Rules` would also take the 22 calls on `CheckRules` and `Analysis::CheckRules` in the covered files.
- *The module's full name or a trailing part of it that starts at a `::`.* `Rules`,
  `DeclarationWalk::Rules` and the full name match; `CheckRules` and `Analysis::Rules` do not. It also
  takes a module of another namespace written with the same trailing name (none exists today).
- *The names a reference can denote where it is written* (`DeclarationFactSources.candidates`). The
  strictest, but a module called through a same-named alias constant (`Rules = DeclarationWalk::Rules`
  inside `ScopeIndexer`) would lose its roots without a failure.

On `master` the three name the same methods of each file as roots: 52 for `scope_indexer.rb`, from 103
call sites, and 3 for `node_propagation.rb`.

**Where a stale row fails.**

- *In the scan*, by raising. Eight examples scan a part of the tree with the committed table, and each
  would need a table of its own.
- *In a check of its own* (`DeclarationWriterScan.source_problems`), which an example runs on the real
  tree. The scan keeps skipping what it does not find, so every such example but one is unchanged.

**The admission census.** Run over the 44 `def`s and 7 constants `Rules` takes, as a file outside the
owners, it records nothing. Run over those two closures it records 11 and 8 members, so those two
must stay under `lib/rigor/inference/scope_indexer/`, which the owner directory already covers.

## Decision

A file with no roots is a root set of its own; a receiver is matched as the module's full name or a
trailing part of it from a `::`, the amendment's wording; a stale row fails in
`source_problems`; and the census is not changed. Beyond the missing root the amendment names,
`source_problems` also fails a row whose file is not covered, whose file defines no method of its
module, and in whose file the rule starts nowhere, since each is the same silent loss by another road.
The precedent is ADR-119 WD6's own rule ("any method another covered file calls as `ScopeIndexer.x`")
and its second file, #3311.

One existing example changes its setup and keeps its assertion: "follows rule (v) from a method
another file calls" passes a table naming its fixture's module, `Rigor::ScopeIndexer`, which is not a
trailing part of `Rigor::Inference::ScopeIndexer`.

The gate's answer on `master` is unchanged: the 615 producers and their reasons are byte-identical,
and `producers.yml`, the grandfathered pin and `admission_census.yml` are untouched.

## To undo

`DeclarationWriterScan.names?` is the whole of the matching rule, and one example pins each of its
cases. The lenient scan and `source_problems` are separate functions; raising in the scan instead means
giving the eight part-tree examples their own tables. The rows the later slices of #3346 add
(`declaration_walk/rules.rb`, and each new file under `scope_indexer/`) depend on the table's shape.
