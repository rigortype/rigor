# frozen_string_literal: true

require "json"

module Rigor
  module Inference
    # TEMPORARY INSTRUMENTATION for issue #286 — NOT FOR RELEASE.
    #
    # Records one JSONL row per `if` / `unless` branch-elision verdict, so the corpus can be asked how many
    # verdicts rest on a carrier that is nil-free by optimism ({OptimisticOrigin}) rather than by class. Inert
    # unless `RIGOR_CENSUS_286` names an output path, so a normal run pays one `nil` check per verdict.
    #
    # The 2026-08-05 census classified verdicts by carrier *shape*; this one classifies by *provenance*, which
    # is the axis the decision actually turns on. The two disagree in a way the shape census could not see: a
    # Hash whose values share one type gives `V` = a single `Constant`, which shape-classifies as sound while
    # being exactly as optimistic as the union case.
    module ElisionCensus
      module_function

      def path
        ENV.fetch("RIGOR_CENSUS_286", nil)
      end

      def enabled?
        !path.nil?
      end

      # @param consumer [Symbol] `:scope` (StatementEvaluator) or `:value` (ExpressionTyper)
      # @param verdict [Symbol] `:truthy` / `:falsey`
      # @param type [Rigor::Type] the predicate's carrier
      # @param optimistic [Boolean] whether the carrier's nil-freeness traces to an ignored annotation
      # @param written_arm_dropped [Boolean] whether the elided branch had source (not the implicit `nil` else)
      def record(consumer:, verdict:, type:, optimistic:, written_arm_dropped:, node:, source_path:)
        return unless enabled?

        write(
          consumer: consumer,
          verdict: verdict,
          carrier: type.class.name.to_s.split("::").last,
          type: safe_describe(type),
          optimistic: optimistic,
          written_arm_dropped: written_arm_dropped,
          predicate_node: node.class.name.to_s.split("::").last,
          file: source_path.to_s,
          line: node.respond_to?(:location) ? node.location.start_line : nil
        )
      end

      def write(row)
        File.open(path, "a") { |io| io.puts(JSON.generate(row)) }
      rescue StandardError
        nil
      end

      def safe_describe(type)
        type.describe(:short).to_s[0, 120]
      rescue StandardError
        type.class.name.to_s
      end
    end
  end
end
