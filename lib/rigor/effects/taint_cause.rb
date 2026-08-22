# frozen_string_literal: true

module Rigor
  module Effects
    # The closed enum of reasons a method's effect summary is not exhaustive (ADR-103 WD14;
    # normative in `docs/type-specification/effect-labels.md`).
    #
    # A tainted summary reads "these effects, and possibly more": the cause says which knowledge the
    # analyzer could not have. Taint never produces a finding — diagnostics read the proven lane
    # only — so this enum is a reporting vocabulary, not a diagnostic one.
    #
    # Nothing produces causes yet; the collector of #379 is the first writer.
    module TaintCause
      # Closed and ordered by how it arises: dispatch the analyzer could not resolve first, then
      # attribution it had to take on trust, then the collector's own limits.
      ALL = %w[
        dynamic-receiver
        dynamic-send
        method-missing
        unresolved-self-call
        unresolved-super
        opaque-callable
        unknown-ownership
        plugin-attribution
        template-not-analysed
        collector-error
        budget
      ].freeze

      module_function

      # Whether `cause` is one of the enum's members. The enum is closed: a spelling outside it is
      # a bug in the producer, not a vocabulary extension point.
      def valid?(cause)
        ALL.include?(cause.to_s)
      end
    end
  end
end
