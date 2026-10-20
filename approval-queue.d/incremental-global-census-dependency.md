# The global write rules record a new `global_census:` dependency key family for the census entries they read

- **PR:** [#2205](https://github.com/rigortype/rigor/pull/2205)
- **Issue:** [#2158](https://github.com/rigortype/rigor/issues/2158)
- **Class:** open-choice
- **Precedent:** [#2136](https://github.com/rigortype/rigor/pull/2136)
- **Decided:** 2026-10-20

## Background

`global.write-type-mismatch` and `global.readonly-write` stay silent on a write when any file may let the
literal answer the setter: a `write`, `to_str`, `to_int` or hatch defined in any spelling on any receiver, a
definition whose name no literal spells, an alias of the variable, a top-level mixin of a module RBS does not
rule out, or a refinement adding `write`. They read this from the whole-program `GlobalWriteCensus` and
recorded no ADR-46 edge. So when a file stopped writing such an entry, `rigor check --incremental` re-analysed
only that file and kept the silenced write silent, where a cold run reports it. The run already re-checks every
file whose last result holds a `global.*` diagnostic, so the other direction was correct. The issue asked for
keys for every census entry kind, with producers where a key had none. Most of those kinds had no key, so the
fix needed a new key family, which no earlier decision covered.

## Options and trade-offs

- **Record only the existing `defines:<name>` key.** It needs no new key, but its producer diffs the method
  tables (`ScopeIndexer.defined_method_names`). Those tables hold no delegation macro, string `eval`, computed
  `define_method`, global alias or top-level mixin. Of the five forms probed (`def write`, `def_delegator`,
  `class_eval "def write…"`, `alias $stdout $my_out`, computed `define_method`), it fixes only the first.
- **A new `global_census:<entry>` key family.** Its producer diffs each changed, added or removed file's census
  between its seed bundle and the recheck scan, and fires the key of every entry that appeared or vanished. The
  seed bundles already carry the census, so no row moves and `SCHEMA` is unchanged. This covers every entry
  kind. The cost is one more name-keyed producer, and a recheck that also fires on census entries in files no
  reader depends on, which is cheap because the census is small.
- **Re-check every file with a census-reading write on any census change.** No key is needed, but every file
  holding a checked special-global write would re-check whenever any census moved. That is over-invalidation of
  the kind #2136's reviews rejected, and it still needs a per-file census diff to know that something moved.

## Decision

The new key family. It is the only option that makes every probed form, and the main-mixin and refinement
entries, answer warm as cold, while an edit that leaves a file's census unchanged re-checks nothing (pinned by
the precision example in `spec/integration/incremental_global_census_edge_spec.rb`). #2136 is the closest
precedent: a dependency key for a whole-program table whose producer diffs per-file seed-bundle data, with no
cache format change. The coordinator approved this option before implementation. The producer's read of the seed
bundle's census adds `lib/rigor/analysis/incremental_session.rb` to the `discovered_global_write_census` reads in
`spec/rigor/declaration_facts/admission_census.yml`, as the session's seed-bundle reads of `discovered_def_nodes`
and `discovered_singleton_def_nodes` already are.

## To undo

Revert the `record_global_census` calls in `CheckRules`, `GlobalWriteCensus.dependency_key`,
`Incremental.changed_global_census_keys`, `IncrementalSession#global_census_affected`, and the
`global_write_census` member of `ScopeIndexer.scan_summary_for_paths`, together with the cache.md paragraph and
the inference-engine.md sentence. The removal examples in `incremental_global_census_edge_spec.rb` then fail.
Nothing else reads the key.
