# frozen_string_literal: true

module Rigor
  module Analysis
    class Runner
      # ADR-116 WD3 (#1195) — the run-level fact registry. A run-level fact is a fact about the RUN rather than
      # about one file: the project-signature state, the definition-build failures, the HKT-scan outcome, the
      # `RunStats` RBS tables, the effect-annotation carrier. Each is declared ONCE below, and every path that
      # used to hand-list the slots — the {RunSnapshots} store, the {PoolCoordinator} backends, the
      # {WorkerSession} drain, the {DiagnosticAggregator} rows and the incremental snapshot's
      # `RunLevelRows` — reads the declarations instead.
      #
      # A {Fact} carries:
      #
      # - `name` and `empty` — the store key and its value before anything is recorded;
      # - `merge` — how a recorded value folds into the slot: {Merge.assign}, {Merge.first_wins} (#784) or
      #   {Merge.union_by_class} (#696);
      # - `source` — `:environment` (read off a coordinator-side environment before the per-file loop, so a
      #   fork child inherits the demand it makes), `:analysis` (read after the loop, and drained out of each
      #   pool worker, because the per-file analysis is what demands it) or `:stats` (`RunStats` telemetry,
      #   read only when stats are collected);
      # - `gate` — for an `:environment` fact, which environment it is read from; an empty-closure run
      #   resolves one per gate, lazily, and every other path hands the same environment to both;
      # - `demand` — for an `:analysis` fact, whether collecting it makes a demand of its own (the HKT
      #   registry build, #784) rather than reading what the analysis already demanded. A path that must not
      #   pay for a demand (the Ractor prewarm, an empty closure with a replay in hand) drains only the others;
      # - `replay` — whether a narrowed incremental run replays the previous full run's value
      #   ({Cache::IncrementalSnapshot::RunLevelRows});
      # - `row` / `position` — the {DiagnosticAggregator} method that turns the slot into diagnostics, and
      #   where that row sits in the post-analysis stream (docs/type-specification/diagnostic-policy.md fixes
      #   the order). Nil for a fact no diagnostic reads.
      #
      # The declaration ORDER is the collection order: {.harvest} reads the `:environment` facts in it, and
      # that order is load-bearing (the stand-downs are read before the env-forcing reads, the conformance
      # scan — which demands definitions — last). The row order is `position`, independently.
      #
      # Rows whose producer is not a slot here — the reporter streams, which the reporters snapshot and
      # absorb themselves, and the two plugin tables the coordinator collects — are declared as {Row}s so
      # the whole post-analysis order lives in one place.
      #
      # Everything here is frozen data plus module functions, never a closure: {WorkerSession#drain_reporters}
      # reads these declarations inside a Ractor worker, and a drained value has to stay Marshal-clean (#805)
      # for the fork backend.
      module RunLevelFacts
        Fact = Data.define(:name, :empty, :merge, :source, :gate, :demand, :replay, :row, :position)
        Row = Data.define(:builder, :position)

        # The predicates an `:environment` collector consults, taken by the coordinator when it harvests.
        Context = Data.define(:project_signature_paths, :plugin_signature_paths, :record_effects)

        # How a recorded value folds into its slot.
        module Merge
          module_function

          def assign(_current, incoming)
            incoming
          end

          # Issue #784 — the HKT scan is one build over the overlay every worker shares, so the first tuple
          # recorded is the run's outcome.
          def first_wins(current, incoming)
            current.nil? ? incoming : current
          end

          # Issue #696 / #1902 — each pool worker holds its own loader, so the run's set is the union, one
          # tuple per class chosen by {Environment::RbsLoader.definition_build_detail_order} rather than by
          # arrival.
          def union_by_class(current, incoming)
            return current if incoming.nil? || incoming.empty?

            (current + incoming)
              .group_by(&:first)
              .map { |_, candidates| candidates.min_by { |c| Environment::RbsLoader.definition_build_detail_order(c) } }
              .freeze
          end
        end

        # One collector per fact, named after it: `(environment, context) -> value`.
        module Collect
          module_function

          # Issue #610 — gated on a loaded plugin contributing signatures, not on `signature_paths:`: the
          # source a plugin's `sig/` stands down against is typically an `rbs collection install`.
          def signature_standdowns(environment, context)
            return [] unless context.plugin_signature_paths

            loader = environment&.rbs_loader
            return [] if loader.nil? || !loader.respond_to?(:deferred_signature_paths)
            return [] if loader.deferred_signature_paths.empty?

            loader.signature_standdowns
          end

          # Issue #1713 — not behind the `signature_paths:` gate either; the loader answers without building
          # its env when no gated directory is active.
          def vendored_standdowns(environment, _context)
            loader = environment&.rbs_loader
            loader.respond_to?(:vendored_standdowns) ? loader.vendored_standdowns : []
          end

          # The four below read the project's OWN `signature_paths:` state, and each forces the otherwise-lazy
          # env build, so they are gated on the project declaring `signature_paths:`.
          def synthesized_namespaces(environment, context)
            return [] unless context.project_signature_paths

            environment&.rbs_loader&.synthesized_namespaces || []
          end

          # Read after the env-forcing read above: the collision derivation reads the BUILT env.
          def quarantined_signatures(environment, context)
            return [] unless context.project_signature_paths

            environment&.rbs_loader&.quarantined_signatures || []
          end

          def env_build_failure(environment, context)
            return nil unless context.project_signature_paths

            environment&.rbs_loader&.env_build_failure
          end

          # Read LAST of the signature state: the scan demands the definition of every `rigor:v1:conforms-to`
          # class, and a resulting definition-build failure has to be in the loader before the `:analysis`
          # read of {.definition_build_failures}.
          def conformance_results(environment, context)
            return [] unless context.project_signature_paths

            RbsExtended::ConformanceChecker.scan(environment&.rbs_loader)
          end

          # #441 — the inline stratum of `effect.annotations-unchecked`. Skipped when effect collection is on:
          # {EffectEnvelopePass} reads the loader directly then.
          def effect_annotation_carrier(environment, context)
            virtual = context.record_effects ? nil : environment&.rbs_loader&.virtual_rbs
            Effects::SignatureSources.annotated_carrier(virtual)
          rescue StandardError
            [].freeze
          end

          # Issue #696 — read after the loop: definition builds are lazy, per class, on first demand. NOT
          # gated on `signature_paths:` like the signature state: nothing is forced here (this reads what the
          # analysis already demanded), and two BUNDLED sources can collapse a class with no project sig set
          # in sight (the `bigdecimal` / `BigMath` shape, #299).
          def definition_build_failures(environment, _context)
            environment&.rbs_loader&.definition_build_failures || []
          end

          # Issue #784 — the run demands the registry once itself, so the outcome does not depend on which
          # files were analysed. One build, one outcome whoever demands it, so a Rigor-owned demand cannot
          # change what is reported (unlike #696's per-class list).
          def hkt_scan_failure(environment, _context)
            return nil if environment.nil?

            environment.hkt_registry
            environment.hkt_scan_failure
          end

          def class_decl_paths(environment, _context)
            environment&.rbs_loader&.class_decl_paths || {}.freeze
          end

          def signature_paths(environment, _context)
            environment&.rbs_loader&.signature_paths || [].freeze
          end
        end

        EMPTY_LIST = [].freeze
        EMPTY_TABLE = {}.freeze

        FACTS = [
          Fact.new(name: :signature_standdowns, empty: EMPTY_LIST, merge: :assign, source: :environment,
                   gate: :signature_state, demand: false, replay: false,
                   row: :rbs_plugin_signature_stood_down_diagnostics, position: 60),
          Fact.new(name: :vendored_standdowns, empty: EMPTY_LIST, merge: :assign, source: :environment,
                   gate: :signature_state, demand: false, replay: false,
                   row: :rbs_vendored_signature_stood_down_diagnostics, position: 70),
          Fact.new(name: :synthesized_namespaces, empty: EMPTY_LIST, merge: :assign, source: :environment,
                   gate: :signature_state, demand: false, replay: false,
                   row: :rbs_synthesized_namespace_diagnostics, position: 50),
          Fact.new(name: :quarantined_signatures, empty: EMPTY_LIST, merge: :assign, source: :environment,
                   gate: :signature_state, demand: false, replay: false,
                   row: :rbs_quarantined_signature_diagnostics, position: 10),
          Fact.new(name: :env_build_failure, empty: nil, merge: :assign, source: :environment,
                   gate: :signature_state, demand: false, replay: false,
                   row: :rbs_environment_build_failed_diagnostics, position: 20),
          Fact.new(name: :conformance_results, empty: EMPTY_LIST, merge: :assign, source: :environment,
                   gate: :signature_state, demand: false, replay: false,
                   row: :conforms_to_diagnostics, position: 80),
          # Read by {EffectAnnotationResidualPass}, outside this stream.
          Fact.new(name: :effect_annotation_carrier, empty: EMPTY_LIST, merge: :assign, source: :environment,
                   gate: :annotation_carrier, demand: false, replay: false, row: nil, position: nil),
          Fact.new(name: :definition_build_failures, empty: EMPTY_LIST, merge: :union_by_class, source: :analysis,
                   gate: nil, demand: false, replay: true,
                   row: :rbs_definition_build_failed_diagnostics, position: 30),
          Fact.new(name: :hkt_scan_failure, empty: nil, merge: :first_wins, source: :analysis,
                   gate: nil, demand: true, replay: true,
                   row: :rbs_hkt_scan_failed_diagnostics, position: 40),
          Fact.new(name: :class_decl_paths, empty: EMPTY_TABLE, merge: :assign, source: :stats,
                   gate: nil, demand: false, replay: false, row: nil, position: nil),
          Fact.new(name: :signature_paths, empty: EMPTY_LIST, merge: :assign, source: :stats,
                   gate: nil, demand: false, replay: false, row: nil, position: nil)
        ].freeze

        # The rows no slot above produces. The reporter streams follow the `rbs.coverage.*` ladder and the
        # conformance rows; the plugin-authored run disclosures (#1051) come before the engine-authored trust
        # refusal envelope (#959), which is read last so every per-file plugin call has recorded its refusals.
        ROWS = [
          Row.new(builder: :unresolved_payload_diagnostics, position: 90),
          Row.new(builder: :lossy_projection_diagnostics, position: 100),
          Row.new(builder: :hkt_directive_diagnostics, position: 110),
          Row.new(builder: :deprecated_form_diagnostics, position: 120),
          Row.new(builder: :boundary_cross_diagnostics, position: 130),
          Row.new(builder: :source_rbs_synthesis_diagnostics, position: 140),
          Row.new(builder: :plugin_run_disclosure_diagnostics, position: 150),
          Row.new(builder: :plugin_trust_refusal_diagnostics, position: 160)
        ].freeze

        # The per-run reporter accumulators, by drain key. Each reporter snapshots and absorbs its own
        # streams (`#snapshot` / `#absorb`), so a new stream inside one touches that reporter and its row.
        REPORTERS = %i[rbs_extended boundary_cross source_rbs_synthesis].freeze

        BY_NAME = FACTS.to_h { |fact| [fact.name, fact] }.freeze

        # Read inside a Ractor worker's drain, so every constant here is deeply shareable.
        Ractor.make_shareable(FACTS)
        Ractor.make_shareable(ROWS)
        Ractor.make_shareable(BY_NAME)

        module_function

        def facts
          FACTS
        end

        def fact(name)
          BY_NAME.fetch(name)
        end

        def names(source: nil)
          (source ? FACTS.select { |fact| fact.source == source } : FACTS).map(&:name)
        end

        def replayable_names
          FACTS.select(&:replay).map(&:name)
        end

        def empty_values
          FACTS.to_h { |fact| [fact.name, fact.empty] }
        end

        # The post-analysis diagnostic builders, in their contract order.
        def row_builders
          (FACTS.select(&:row).map { |fact| Row.new(builder: fact.row, position: fact.position) } + ROWS)
            .sort_by(&:position)
            .map(&:builder)
        end

        # Collects every fact of `source`, in declaration order, from the environment the block yields for
        # its gate (one call per gate, on first need). `:analysis` and `:stats` facts take the block's
        # environment with a nil gate.
        def harvest(source, context)
          environments = {}
          FACTS.each_with_object({}) do |fact, collected|
            next unless fact.source == source

            environment = environments.fetch(fact.gate) { environments[fact.gate] = yield(fact.gate) }
            collected[fact.name] = Collect.public_send(fact.name, environment, context)
          end
        end

        # The `:analysis` facts as an analysing process reports them: the {WorkerSession} drain, and the
        # coordinator's own environment on the paths that analyse on it. Plain tuples — Marshal-clean and
        # shareable.
        #
        # @param demanding — nil drains every `:analysis` fact; false only those that read what was already
        #   demanded; true only those that make a demand of their own.
        def drain(environment, demanding: nil)
          FACTS.each_with_object({}) do |fact, drained|
            next unless fact.source == :analysis
            next unless demanding.nil? || fact.demand == demanding

            drained[fact.name] = Collect.public_send(fact.name, environment, nil)
          end
        end

        # The `:analysis` facts out of a drained hash, for {RunSnapshots#absorb}.
        def drained_facts(drained)
          names(source: :analysis).each_with_object({}) do |name, facts|
            facts[name] = drained[name] if drained.key?(name)
          end
        end

        def snapshot_reporters(reporters)
          REPORTERS.to_h { |name| [name, reporters.fetch(name).snapshot] }
        end

        # A drain shape that lacks a reporter's key records nothing for it.
        def absorb_reporters(reporters, drained)
          REPORTERS.each { |name| reporters.fetch(name).absorb(drained[name]) }
        end
      end
    end
  end
end
