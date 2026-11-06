# ADR-129 G1' witness for :def_node_resolver_run (the consumer file, with its project in the sibling directory
# `def_node_resolver_run/`; the shape is `unsettled_chain_incremental_spec`'s, issue #2874). A harness runs the project
# through an `IncrementalSession`: after the baseline, `q.rb` is edited and the recheck re-types this file, while the
# unchanged files' defs are handles that typing resolves through the run's tables from inside `type_of`.
Factory.build.foo.even?
