# Four ScopeIndexer helpers of the computed-send reading are listed in producers.yml

- **PR:** [#3021](https://github.com/rigortype/rigor/pull/3021)
- **Issue:** [#3006](https://github.com/rigortype/rigor/issues/3006)
- **Class:** gate-row
- **Precedent:** [#3011](https://github.com/rigortype/rigor/pull/3011)
- **Decided:** 2026-11-09

## Background

`spec/rigor/declaration_facts/producers_spec.rb` flags a method that reads a constant built from a mixin name or
appends to a list. The two new helpers that read a computed `send` name trip it: `literal_send_name` reads
`MIXIN_KINDS`, and `collect_local_send_names` reads `LOCAL_SCOPE_BOUNDARIES` and appends the literals it finds.

## Options and trade-offs

- List both as consumers, as #3011 listed `unnamed_singleton_include?`, which reads a call's name and arguments.
- Restructure them to dodge the scanner, which moves code to pass a gate.

## Decision

List both as consumers. Each reads a call's or a local's literal names and writes no table and derives no owner or
side; the side is decided by `taint_computed_mixin_send`, which the scanner does not flag.

Review round 1 adds `taint_computed_mixin_send` and `taint_computed_hook_send`, which the scanner flags for spelling
`:include`. Each taints the side its caller names on the owner the walk passes in, as `taint_unrecorded_mixin` (listed
for #2991) does, and derives no declaration context, so each is listed with that reason.

## To undo

Delete the four rows when the helpers go.
