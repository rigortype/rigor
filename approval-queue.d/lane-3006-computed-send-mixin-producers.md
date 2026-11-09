# ScopeIndexer#collect_local_send_names and #literal_send_name are listed in producers.yml as consumers

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

## To undo

Delete the two rows when the helpers go.
