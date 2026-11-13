# Record the override walk's literal const_set scan as a producers.yml row and an admission_census.yml read

- **PR:** [#3174](https://github.com/rigortype/rigor/pull/3174)
- **Issue:** [#3156](https://github.com/rigortype/rigor/issues/3156)
- **Class:** gate-row
- **Precedent:** [#2086](https://github.com/rigortype/rigor/pull/2086)
- **Decided:** 2026-11-13

## Background

#3156 lets `def.override-return-widened` and `def.override-param-narrowed` ask a project class or module whose Ruby body records nothing (`ResolutionChain::Entry#declared_name`). Review round 2 found a false positive: `module NS; const_set(:AMid, ::Other); class ALeaf < AMid` still read the body-less top-level `AMid` as `NS::ALeaf`'s parent, because the project constant census files no `const_set` write. The coordinator ruled that the census stays as it is and that the decline reads the file's own literal `const_set` calls. That read tripped two gates:

- `spec/rigor/declaration_facts/producers_spec.rb`: the new walk `LastLine::SelfEvidence#collect_const_sets` matches `Prism::ClassNode` / `Prism::ModuleNode` to qualify each name by its body's nesting, so it counts as a declaration producer;
- `spec/rigor/declaration_facts/admission_census_spec.rb`: `lib/rigor/scope/resolution_chain.rb` now reads the `implicit_self_evidence` discovery member.

## Options and trade-offs

- **Record the walk in the constant census.** Every reader would see literal `const_set` writes, including those in other files. But it changes a project-wide table that the typing and incremental paths read, which goes beyond #3156. The coordinator ruled it out.
- **Scan the analysed file and record both gate rows** (taken). Only the override walk's decline reads it, and only on that path, memoised per file. It nests through the shared `Source::ConstantPath.pushed_nesting` rather than its own rendering. The cost is a residue: a `const_set(:AMid, ::Other)` in `module NS` in **another** file is not seen, so `NS::ALeaf < AMid` against a body-less top-level `AMid` still fires there. The coordinator accepted that residue and tracks it in #3176.
- **Drop the decline.** This keeps the gates unchanged but leaves the same-file false positive that round 2 reported.

## Decision

The second option. The producers.yml row's reason says what it permits: the walk computes the namespaces a literal `const_set` binds a name in, the override walk reads it only to decline, and it nests through the shared helper. The admission_census.yml path records the one new reader of `implicit_self_evidence`. #2086 is the ratified precedent for a producers.yml row with a stated reason for a narrow syntactic walk (its `LexicalMethodSites` rows). The fit is close: both are bounded reads that derive no declaration context for anything else.

## To undo

Remove `SelfEvidence#const_set_spellings` / `#collect_const_sets` and the `const_set_spellings` clause in `ResolutionChain::Entry#constant_written?`, then drop the producers.yml row and the admission_census.yml path. The two `const_set` rows in `override_and_return_type_spec.rb` ("a body-less project ancestor (#3156)") then fail, which brings the same-file false positive back. If the constant census later records literal `const_set` writes, replace this scan with that table, which also closes the cross-file residue.
