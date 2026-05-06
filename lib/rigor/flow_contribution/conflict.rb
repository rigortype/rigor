# frozen_string_literal: true

module Rigor
  class FlowContribution
    # Records a contradiction between two or more flow contributions
    # detected during {Merger.merge}. Carried on {MergeResult#conflicts}
    # so the analyzer / formatter can surface a `:contribution_merge`
    # diagnostic per ADR-2 § "Plugin Contribution Merging".
    #
    # ADR-2 § "Plugin Contribution Merging" rules out first-wins /
    # last-wins behaviour: when contributions conflict, both sources
    # are reported and the merger falls back to the nearest non-
    # conflicting higher-tier (or default) value for the affected
    # `(target, edge, kind)` slot. The conflict object is the
    # carrier of that report.
    #
    # Slice-3 conflict reasons:
    #
    # - `:return_type_collapse` — two return-type contributions
    #   intersect to `bot`.
    # - `:exceptional_disagreement` — two contributions assert
    #   incompatible non-`nil` exceptional effects.
    # - `:lower_tier_contradiction` — a lower-tier contribution
    #   would weaken or contradict a higher-tier proof.
    CONFLICT_VALID_REASONS = %i[
      return_type_collapse
      exceptional_disagreement
      lower_tier_contradiction
    ].freeze

    Conflict = Data.define(:target, :edge, :kind, :reason, :provenances, :message) do
      def initialize(target:, edge:, kind:, reason:, provenances:, message:) # rubocop:disable Metrics/ParameterLists
        unless CONFLICT_VALID_REASONS.include?(reason)
          raise ArgumentError,
                "FlowContribution::Conflict reason must be one of " \
                "#{CONFLICT_VALID_REASONS.inspect}, got #{reason.inspect}"
        end

        super(target: target, edge: edge, kind: kind, reason: reason,
              provenances: provenances.dup.freeze, message: message.to_s.dup.freeze)
      end

      def to_h
        {
          "target" => target.to_s,
          "edge" => edge.to_s,
          "kind" => kind.to_s,
          "reason" => reason.to_s,
          "sources" => provenances.map { |p| p.respond_to?(:to_h) ? p.to_h : p.to_s },
          "message" => message
        }
      end

      # ADR-7 § "Slice 5-C" — converts the conflict into a
      # `Rigor::Analysis::Diagnostic` for the run result.
      # Carries `source_family: :contribution_merge` so the
      # qualified-rule formatter (slice 5 formatter half,
      # `ef730b2`) prefixes the rule id with
      # `contribution_merge.` and the JSON output side-bands
      # `source_family` + `rule` for plugin attribution.
      #
      # The `rule` identifier is the kebab-case form of the
      # conflict reason (`return_type_collapse` →
      # `return-type-collapse`, etc.) so the qualified rule
      # reads `[contribution_merge.return-type-collapse]` in
      # the standard text stream.
      def to_diagnostic(path:, line:, column:, severity: :error)
        require_relative "../analysis/diagnostic" unless defined?(Rigor::Analysis::Diagnostic)
        Rigor::Analysis::Diagnostic.new(
          path: path,
          line: line,
          column: column,
          message: message,
          severity: severity,
          rule: reason.to_s.tr("_", "-"),
          source_family: :contribution_merge
        )
      end
    end
  end
end
