# Slice 3 of #3400 moves the alias def-node pass and the declaration artifacts in one pull request, as `AliasDefNodes` and `DeclarationArtifacts`, each behind one function, gives both moved `sig/` rows their `def`'s parameter list, states `private_class_method` in `sig/` by a `private` section, keeps `index`'s method-length directive, and accepts the `module Rigor` wrappers of the two new files as two more expressions that read `Dynamic` in the self-typing scan

- **PR:** [#3409](https://github.com/rigortype/rigor/pull/3409)
- **Issue:** [#3400](https://github.com/rigortype/rigor/issues/3400)
- **Class:** open-choice
- **Precedent:** [ADR-116](../docs/adr/116-hot-file-restructuring.md)
- **Decided:** 2026-11-26

## Background

ADR-116's re-measure of 2026-11-26 names two clusters of `scope_indexer.rb` candidates and commits to neither:
the alias def-node pass (`apply_alias_def_nodes`), with `AliasMap`, and the declaration artifacts
(`build_declaration_artifacts`). #3400 holds the candidates, and this is its third slice. Re-measured at
`56a24a10d` with the re-measure's own scripts, the pass is 11 functions and 151 lines of code with one call back
(`follow_slot_writer`, at two sites) and one entry, called once; the artifacts are 6 functions and 103 lines of
code with three calls back, all to the cross-file fold (`compact_header_renames`, `rename_compact_name`,
`synthesize_namespace_prefixes`, one site each), and one entry, called from `index` and from
`pre_eval_constants.rb`. Both meet the #3318 cut-off: at most four calls back, and no function of the file reads
or writes an instance variable.

The amendment says a cluster moves "whole, behind its entry" to `ScopeIndexer::<Name>` and leaves the rest to the
slice. Seven things were open.

- One pull request or two. The coordinator's brief left it to the slice.
- The names, and what each module shows. One spec example reached `collect_class_alias_map` on `ScopeIndexer`
  through `send`.
- What moves with each. `AliasMap` is a nested class only the pass builds, and `EMPTY_RENAMES` a constant only
  the artifacts read.
- The two rows of `sig/` the artifacts have. Each lists fewer parameters than its `def`.
- How `sig/` says that a declared function is `private_class_method`. The review of #3406 asked it of two rows
  of `ConstantTables`, and the same question holds for `DeclarationArtifacts.record_declarations`.
- `index`, which slice 2 left at 33 lines under a directive, calls the artifacts' entry first.
- What the move costs the self-typing ratchet.

## Options and trade-offs

**One pull request or two.** The two clusters share no function, and each could land alone. They share three
numeric pins: the grandfathered digest of `producers_spec.rb`, the budget row of `scope_indexer.rb` and the block
of `sig/rigor/inference.rbs`.

- *Two.* The second is cut from the first's branch, and a stacked pull request may not be pushed, so it waits for
  the first to land and then recounts the digest and the budget row. Each review is smaller: 151 and 103 lines of
  moved code.
- *One.* One recount of each pin and one set of guardrail runs, whose base and head engines then cover both
  moves. Slice 1 moved three clusters this way. The review reads two modules, each with its own mirror spec and
  its own rows of the mutation table.

**The names and the lists.** `AliasDefNodes` is the entry's name (`apply_alias_def_nodes`) and the row's ("the
alias def-node pass"); `DeclarationArtifacts` is the entry's and the row's. No constant of either name exists.
As U1 to U5 and slices 1 and 2 decided, the functions another file of `lib/` calls are public and the rest
private, with the mirror spec pinning the list: one function each. `collect_class_alias_map` is private by that
rule; the one example that called it alone moves to the mirror spec with its text and reaches it through `send`,
as it did.

**What moves with each.** The re-measure counts with a row the constants and nested classes only that row reads.
`AliasMap` moves into `AliasDefNodes`, a public constant as it was, and `EMPTY_RENAMES` into
`DeclarationArtifacts`, public as it was. The alternative, leaving either on `ScopeIndexer` to be read lexically,
keeps on the indexer a name nothing in its file reads. The modules read `INSTANCE_EVAL_CALLS`, `EMPTY_PREFIX` and
`RECEIVER_EVAL_CALLS` lexically, since other rows of the file and other modules read each.

**The two `sig/` rows.** `build_declaration_artifacts: (untyped root)` and `record_declarations` with four
parameters, where the `def`s take `(root, declared_names = nil)` and four parameters more
(`renames = EMPTY_RENAMES, self_prefix = nil, singleton_cref: false`). A short row is one the parameter-shape
check accepts, since an overload may omit an optional parameter.

- *Move each with its text.* The brief asked the `def`'s list of `record_declarations` alone. Moved as it was,
  the other row failed the self-check: `index` hands the entry the project's names, and
  `rigor check` reported `call.wrong-arity`, "given 2, expected 1", at `scope_indexer.rb:153`. On `ScopeIndexer`
  the call had no receiver and was not held to the declaration; spelled on the module it is. This is what U1 to
  U3 met with `collect_class_decls`.
- *Give each the `def`'s list*, the added parameters untyped, as `rigor sig-gen` proposes them for the functions
  it declares beside these. The types the rows already state are kept.
- *Delete the rows.* That takes the declared types of the two tables away from the entry's callers.

**`private_class_method` in `sig/`.** Three rows declare a function its module makes private: `ConstantTables`'
`constant_writes_for_file` and `constant_literal_value`, and `DeclarationArtifacts.record_declarations`. Spelled
`def self?.` beside the entries, they read as public. Each spelling was tried against RBS 4.2.0, the provenance
gate's own auditor and `rigor check`:

| Spelling | RBS | The provenance gate | `rigor check` |
| --- | --- | --- | --- |
| `private def self?.x` | does not parse: "`self?` method cannot have visibility" | | |
| `private def self.x` | the singleton method, private; no instance half | the row no longer joins its `def`: the three turn `synthetic_source`, the parameter-shape check compares 1,132 rows where it compared 1,135 (its floor is 1,132), and the file's unmarked residue is 69 against a pin of 68 | as `def self?.` |
| `private def self.x` and `private def x` | both halves, private | not run: its first row is the one above, which the gate does not join, and each function would have two rows | not run |
| a `private` section over `def self?.x` | the singleton half stays public; the instance half is private, as `self?` makes it already | as `def self?.`: 538 residue rows, 68 in the file, 1,135 compared, each row joined to its `def`; each `private` member is one more row that is no method | as `def self?.` |
| a comment on the row | no change | no change | no change |

`rigor check` reads none of them as a visibility: over a two-file project, a call of the function on the module
from another file draws no diagnostic under any spelling, and its arity is held to the declaration under all of
them.

**`index`.** Its first statement holds the call of the entry. Spelled on the module it still fits the two lines
it had (110 columns), so `index` is 33 lines against `Metrics/MethodLength`'s 30, as slice 2 left it. Checked
with the directive taken off: `Method has too many lines. [33/30]`. It could go only if the three statements
slices 1 and 2 lengthened came back to the lines they had.

**The ratchet.** No expression changes tier, call or not: every call the slice respelled, and every constant
the moved code reads, is in the tier it had (`tmp/wd9/lens_account.rb`, over the eight files the slice touched).
The `Dynamic` call sites are 50,954 on both sides. Two expressions that read `Dynamic[top]` are new: the
`module Rigor` wrapper of each new file, which reads so in seven of those eight files. They are rows a new file
brings, not a precision the move gave up.

- *Put the code in an existing file*, so that no wrapper is new. That is not a module behind its entry in a
  file of its own, which is what the amendment asks.
- *Accept them.* Precision is 0.5991 against a pin of 0.5958 and the `Dynamic` call share 0.4961 against
  0.4983, each better than its pin and better than at the base.

## Decision

One pull request. Two modules, `ScopeIndexer::AliasDefNodes` in `scope_indexer/alias_def_nodes.rb` and
`ScopeIndexer::DeclarationArtifacts` in `scope_indexer/declaration_artifacts.rb`, each showing its one entry and
keeping the rest private; `AliasMap` and `EMPTY_RENAMES` move with them. Both moved `sig/` rows take their
`def`'s parameter list. The three rows of private functions stand under a `private` section of their module's
block, with a comment that says the section is for the reader. `index` keeps its directive.
The two wrappers are accepted with no pin of `tool/coverage_ratchet.yml` touched.

The precedent for each is the amendment and the slices landed under it. The amendment moves a cluster "whole,
behind its entry". Slice 1 ([#3405](https://github.com/rigortype/rigor/pull/3405)) moved three clusters in one
pull request and is the precedent for `index`'s directive; the re-measure counts a row's own constants and
nested classes with it, and slices 1 and 2 moved theirs the same way. U1 to U3
([#3393](https://github.com/rigortype/rigor/pull/3393)) gave `collect_class_decls`' row its `def`'s list for the
same `call.wrong-arity`, and the brief asked the same of `record_declarations`; `build_declaration_artifacts`
is the row the self-check held, so it follows. For the `private` section there is no precedent in `sig/`, which
had no `private` anywhere: of the RBS forms tried it is the one that moves no gate, and the coordinator named
it as the form to try first; a comment alone would say the same in no RBS at all. What the section does not do
is make the singleton half private to a checker that reads RBS visibility, and the comment over each says so.

Four smaller choices follow landed slices and need no ruling. Comment links to a module function are spelled
with a dot, `{.x}` inside the module and `{AliasDefNodes.x}` or `{ScopeIndexer::DeclarationArtifacts.x}` outside
it. The example of `scope_indexer_spec.rb` that called `collect_class_alias_map` alone is in the mirror spec
with its assertions unchanged. Each file has a row in rule (v)'s table. And `factory_call_resolver.rb`'s head
comment counts three files that call it where it counted two.

## To undo

To split the pull request, revert it and land each module from its own branch; the digest of the grandfathered
pin and the budget row of `scope_indexer.rb` are recounted at each. To rename a module, rename the file, its
mirror spec, its rows in `typing_state_closure_spec.rb` and `DeclarationWriterScan::SOURCES`, its section of
`producers.yml` (eight grandfathered keys for the pass and four for the artifacts, so the pin's digest moves
again), its block of `sig/rigor/inference.rbs` where it has one, and the calls spelled on it. To put `AliasMap`
or `EMPTY_RENAMES` back on `ScopeIndexer`, move the statement; the module reads the name lexically with no other
change. To take a `sig/` row back to its short list, first make every call of the function on its module pass
no more arguments than the row lists. To spell the three private rows another way, delete the `private` member
and its comment from each block: the rows are `def self?.` under it as they were, so nothing else moves. To
take the directive off `index`, bring its statements back within 30 lines. The wrappers' reading goes only
with the files.
Nothing outside this pull request depends on any of these yet; the next slice of #3400 reads `index` at 33
lines, `scope_indexer.rb` at 9,772 lines under a budget of 9,800, and the grandfathered pin at the digest this
slice leaves.
