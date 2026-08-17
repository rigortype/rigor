# frozen_string_literal: true

module Rigor
  module Effects
    # The effect-label grammar and the subsumption relation over it (ADR-103 WD1; normative in
    # `docs/type-specification/effect-labels.md`).
    #
    # A label is a dot-path of lowercase segments — `io`, `io.net.http`, `nondet.time`. The relation
    # that matters is **segment-aware prefix subsumption**: `io` admits `io.net.http` and rejects
    # `iota`. Every method here is pure and total; a malformed input is answered, never raised on,
    # so a caller can ask `valid?` and the rest in either order.
    module Label
      # `label = segment { "." segment }`, `segment = [a-z][a-z0-9]*`. Deliberately narrow: no
      # underscores, no hyphens, no uppercase, no empty segment, no trailing dot. The same grammar
      # is the RFC's `label` production, so a label spells identically in Steins and Rigor.
      PATTERN = /\A[a-z][a-z0-9]*(?:\.[a-z][a-z0-9]*)*\z/

      SEPARATOR = "."
      private_constant :SEPARATOR

      module_function

      # Whether `str` is a well-formed label. Anything that is not a String is not.
      def valid?(str)
        str.is_a?(String) && PATTERN.match?(str)
      end

      # The label's segments, outermost first: `"io.net.http"` -> `["io", "net", "http"]`.
      # A malformed label yields an empty array rather than a partial parse.
      def segments(label)
        return [].freeze unless valid?(label)

        label.split(SEPARATOR).freeze
      end

      # Whether `bound` admits `label` under segment-aware prefix subsumption. A label subsumes
      # itself; `io` subsumes `io.net.http`; `io` does NOT subsume `iota`, because the match is on
      # segment boundaries and not on characters.
      def subsumes?(bound, label)
        return false unless valid?(bound) && valid?(label)
        return true if bound == label

        label.start_with?("#{bound}#{SEPARATOR}")
      end

      # The label one segment shallower, or `nil` for a root (and for a malformed label).
      def parent(label)
        return nil unless valid?(label)

        index = label.rindex(SEPARATOR)
        return nil unless index

        label[0, index]
      end

      # The label's proper ancestors, outermost first and excluding the label itself:
      # `"io.net.http"` -> `["io", "io.net"]`. A root has no ancestors.
      def ancestors(label)
        parts = segments(label)
        return [].freeze if parts.length <= 1

        result = []
        prefix = nil
        parts[0...-1].each do |segment|
          prefix = prefix ? "#{prefix}#{SEPARATOR}#{segment}" : segment
          result << prefix
        end
        result.freeze
      end

      # The label's outermost segment — the root whose ownership the registry checks.
      def root(label)
        segments(label).first
      end
    end
  end
end
