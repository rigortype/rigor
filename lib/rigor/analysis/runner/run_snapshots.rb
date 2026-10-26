# frozen_string_literal: true

require_relative "run_level_facts"

module Rigor
  module Analysis
    class Runner
      # Mutable per-run store for the run-level facts ({RunLevelFacts}): one slot per declared fact, keyed by
      # its name. The analysis paths write it ({PoolCoordinator} — sequential, fork-pool, Ractor-pool,
      # fallback, empty closure) and the rest of the run reads it back: the {DiagnosticAggregator} rows,
      # {RunStats}, {EffectAnnotationResidualPass} and the incremental snapshot's `RunLevelRows`.
      #
      # A shared mutable holder keeps the write/read timing of the original inline ivars while letting the
      # writer and the readers live in separate objects without a back-reference cycle.
      #
      # The analysis paths write through {#absorb}, which folds each value in by its fact's declared merge
      # rule. `[]=` and the per-fact `name=` writers (defined from the declarations, like the readers) are a
      # plain assignment that bypasses the merge rule: they exist for specs that seed a slot, and no
      # production path calls them.
      class RunSnapshots
        def initialize
          @values = RunLevelFacts.empty_values
        end

        # Per-`#run` reset to every fact's declared empty value.
        def reset_for_run
          @values = RunLevelFacts.empty_values
        end

        def [](name)
          RunLevelFacts.fact(name)
          @values[name]
        end

        def []=(name, value)
          RunLevelFacts.fact(name)
          @values[name] = value
        end

        # Folds `facts` (`{name => value}`) into the store, each by its fact's merge rule.
        def absorb(facts)
          facts.each do |name, value|
            merge = RunLevelFacts.fact(name).merge
            @values[name] = RunLevelFacts::Merge.public_send(merge, @values[name], value)
          end
          self
        end

        def to_h
          @values.dup
        end

        RunLevelFacts.facts.each do |fact|
          define_method(fact.name) { @values[fact.name] }
          define_method(:"#{fact.name}=") { |value| @values[fact.name] = value }
        end
      end
    end
  end
end
