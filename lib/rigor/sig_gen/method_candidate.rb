# frozen_string_literal: true

module Rigor
  module SigGen
    # Per-method record produced by the generator.
    #
    # `classification` is one of the {Classification} constants;
    # the remaining fields are populated only when applicable
    # to that classification.
    #
    # - `path` — the source `.rb` file the def came from.
    # - `class_name` — qualified receiver class name (e.g.
    #   `"Foo::Bar"`). `nil` for top-level / DSL-block defs
    #   the MVP skips.
    # - `method_name` — the def's `Symbol` name.
    # - `kind` — `:instance` or `:singleton`.
    # - `inferred_return` — `Rigor::Type` instance (or `nil`
    #   when the inference pass disqualified the def).
    # - `declared_return_rbs` — the existing RBS-declared return
    #   spelling, or `nil` when no RBS declares the method.
    # - `rbs` — the rendered RBS one-liner the generator would
    #   emit (`nil` for skipped / equivalent rows).
    # - `skip_reason` — one of {Classification::SKIP_DIAGNOSTIC_IDS}
    #   keys when classification is `:skipped`, else `nil`.
    class MethodCandidate
      attr_reader :path, :class_name, :method_name, :kind, :classification,
                  :inferred_return, :declared_return_rbs, :rbs, :skip_reason

      def initialize(path:, class_name:, method_name:, kind:, classification:, # rubocop:disable Metrics/ParameterLists
                     inferred_return: nil, declared_return_rbs: nil, rbs: nil, skip_reason: nil)
        @path = path
        @class_name = class_name
        @method_name = method_name
        @kind = kind
        @classification = classification
        @inferred_return = inferred_return
        @declared_return_rbs = declared_return_rbs
        @rbs = rbs
        @skip_reason = skip_reason
        freeze
      end

      def to_h
        {
          file: path,
          class: class_name,
          method: method_name.to_s,
          kind: kind.to_s,
          classification: classification.to_s,
          rbs: rbs,
          inferred_return: inferred_return&.erase_to_rbs,
          declared_return_rbs: declared_return_rbs,
          skip_reason: skip_reason ? Classification::SKIP_DIAGNOSTIC_IDS.fetch(skip_reason) : nil
        }.compact
      end
    end
  end
end
