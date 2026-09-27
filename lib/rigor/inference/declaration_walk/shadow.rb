# frozen_string_literal: true

require_relative "../../analysis/shadow_harness"

module Rigor
  module Inference
    module DeclarationWalk
      # ADR-53 Track B's shadow harness, extended from the rule collectors to the discovery tables (ADR-116
      # WD5). With `RIGOR_SHADOW_RULE_WALK` set, a table a {DeclarationWalk} collector builds is compared with
      # the one the legacy walker it replaces builds from the same input, and the first difference raises
      # {Divergence}. Unset, the legacy walker never runs.
      #
      # Equality is stricter than `Hash#==`: key ORDER counts, and so do a container's frozenness and
      # `compare_by_identity`. A table is iterated when it is merged, folded and written to a seed bundle, so
      # an order change is a change in what later stages see even where `==` holds. Not compared yet: a
      # `Set`'s order and frozenness (a `Set` compares by `==` alone), a Hash's `default` / `default_proc`,
      # and the fields inside a `Data` or `Struct` value beyond its `==`. No ported table holds one yet; a
      # port whose table does extends {#first_difference} first.
      #
      # ## Running it
      #
      # Set the variable for the whole `rigor check` process, pool workers included: `RIGOR_SHADOW_RULE_WALK=1
      # rigor check …`. Under `rigor check` a raise lands in the per-file rescue and reports as an error
      # diagnostic on the file, carrying the message, the same way a rule-walk divergence does; a run with no
      # such row found no divergence. The rule-walk harness reads the same variable
      # ({Analysis::ShadowHarness}).
      #
      # A warm cache cannot answer for a run the harness did not check. The ADR-45 run-result cache (and the
      # ADR-87 boot-slim probe and the effects sidecar, which share its key) and the ADR-46 incremental
      # snapshot, seed bundles included, key on {Analysis::ShadowHarness.cache_identity}. So a run with the
      # variable never replays a result computed without it, and a divergence row cached under it never
      # replays into a run without it. A warm hit WITH the variable replays what the same engine computed on
      # the same inputs with the harness on, divergence rows included; `--no-cache` sends every file through
      # the check again.
      module Shadow
        ENV_KEY = Analysis::ShadowHarness::ENV_KEY

        class Divergence < StandardError; end

        module_function

        def enabled?
          Analysis::ShadowHarness.enabled?
        end

        # `walk`, after checking it against the table the block builds when the harness is on. The block is
        # the legacy walker, so a disabled harness never pays for it.
        def verified(table, path, walk)
          verify!(table, path, walk, yield) if enabled?
          walk
        end

        def verify!(table, path, walk, legacy)
          difference = first_difference(legacy, walk, "")
          return if difference.nil?

          raise Divergence,
                "#{ENV_KEY} divergence: discovery table `#{table}` for #{path || '(no path)'}: #{difference}"
        end

        # A description of the first place `walk` differs from `legacy`, or nil when they are the same.
        # `at` is the key path walked so far, rendered as Ruby index syntax.
        def first_difference(legacy, walk, at)
          if legacy.is_a?(Hash) && walk.is_a?(Hash)
            hash_difference(legacy, walk, at)
          elsif legacy.is_a?(Array) && walk.is_a?(Array)
            array_difference(legacy, walk, at)
          elsif legacy.class != walk.class || legacy != walk
            "#{location(at)}: legacy #{render(legacy)}, declaration walk #{render(walk)}"
          end
        end

        def hash_difference(legacy, walk, at)
          container_difference(legacy, walk, at) ||
            key_difference(legacy, walk, at) ||
            legacy.each_key.lazy.filter_map do |key|
              first_difference(legacy[key], walk[key], "#{at}[#{key.inspect}]")
            end.first
        end

        def array_difference(legacy, walk, at)
          container_difference(legacy, walk, at) ||
            (legacy.size == walk.size ? nil : size_difference(legacy, walk, at)) ||
            legacy.each_index.lazy.filter_map do |index|
              first_difference(legacy[index], walk[index], "#{at}[#{index}]")
            end.first
        end

        def container_difference(legacy, walk, at)
          if legacy.frozen? != walk.frozen?
            "#{location(at)}: legacy frozen=#{legacy.frozen?}, declaration walk frozen=#{walk.frozen?}"
          elsif legacy.is_a?(Hash) && legacy.compare_by_identity? != walk.compare_by_identity?
            "#{location(at)}: legacy compare_by_identity=#{legacy.compare_by_identity?}, " \
              "declaration walk compare_by_identity=#{walk.compare_by_identity?}"
          end
        end

        def key_difference(legacy, walk, at)
          missing = legacy.each_key.find { |key| !walk.key?(key) }
          return "#{location(at)}: key #{missing.inspect} only in legacy" if missing

          extra = walk.each_key.find { |key| !legacy.key?(key) }
          return "#{location(at)}: key #{extra.inspect} only in declaration walk" if extra

          index = legacy.keys.zip(walk.keys).index { |ours, theirs| !ours.eql?(theirs) }
          return nil if index.nil?

          "#{location(at)}: key order differs at position #{index}: legacy #{legacy.keys[index].inspect}, " \
            "declaration walk #{walk.keys[index].inspect}"
        end

        def size_difference(legacy, walk, at)
          "#{location(at)}: legacy has #{legacy.size} elements, declaration walk #{walk.size}"
        end

        def location(at)
          at.empty? ? "the table" : at
        end

        # A Rigor type renders as it describes itself; anything else as it inspects.
        def render(value)
          value.respond_to?(:describe) ? value.describe : value.inspect
        end
      end
    end
  end
end
