# Record ReplacedSingletonDefs's two class-body walkers in producers.yml

- **PR:** [#3168](https://github.com/rigortype/rigor/pull/3168)
- **Issue:** [#3155](https://github.com/rigortype/rigor/issues/3155)
- **Class:** gate-row
- **Precedent:** [#2086](https://github.com/rigortype/rigor/pull/2086)
- **Decided:** 2026-11-13

## Background

#3155 has `def.return-type-mismatch` skip a singleton def that a later def of the same name replaces, because Ruby keeps the later body. Review round 1 found the first cut too loose. It asked the indexer's singleton table, which also holds a def from a `Class.new` / `Struct.new` block or from under a condition, so a real mismatch went unreported (`class SV; def self.g = "bad"; Class.new do; def self.g = 1; end; end`). The rule the coordinator set is that only a later certain def counts: a direct statement of the same class or module body, or a direct statement of a `class << self` in it.

No table records which defs are direct statements of a body, so the new `Analysis::CheckRules::ReplacedSingletonDefs` reads that from the file's syntax. Two of its methods match Prism body-node classes, which `spec/rigor/declaration_facts/producers_spec.rb` counts as declaration producers:

- `#each_class_body` yields the body of each `ClassNode` / `ModuleNode`. It only groups defs by the body node they are written in. It names no class and builds no prefix or nesting.
- `#certain_singleton_defs` lists a body's direct `def self.x` / `def K.x` statements and the direct defs of a `class << self` (or `class << K`) statement there. To decide whether a constant receiver names the class, it asks the def's own Scope (`self_type.class_name`, the indexer's declaration context). It does not render the header itself.

A first cut rendered the class header to get the name. That would have been a declaration context of its own, so it was replaced with the Scope read before the row was written.

## Options and trade-offs

- Add a producers.yml row with this reason. The rule stays exact (direct statements only). The cost is one more syntactic walk over class bodies, run lazily and only once a return mismatch would report, for a later reader to keep consistent with the indexer.
- Route the question through `DeclarationWalk::Context` or the indexer, by having the singleton table record whether each write is a certain direct statement. That needs no row, but it changes the shared discovery tables for one rule's decline.
- Drop the skip and report every replaced singleton def. That needs no row either, but it brings back the report the issue lists (`def V.w = "first"; def self.w = :second` checked against the last def's signature), a false positive on correct code.

## Decision

The first option, accepted by the coordinator. Each entry's reason names #3155, says the method groups defs by body node, and says the class name comes from the def's Scope, so it derives no declaration context. #2086 recorded `LexicalMethodSites` rows in the same file for the same kind of reason: a per-file syntactic walk that serves a check rule's decline. No other producers.yml row moved.

## To undo

Delete the `lib/rigor/analysis/check_rules/replaced_singleton_defs.rb` block from producers.yml, together with `ReplacedSingletonDefs` and its use in `CheckRules#receiver_def_side`. Then either report every replaced singleton def again (the redefinition rows in `spec/rigor/sig_gen/foreign_receiver_def_spec.rb` then fail), or have the indexer's singleton table carry a certainty mark that the rule reads instead.
