# frozen_string_literal: true

require_relative "label_intent"

module Rigor
  module Effects
    # One `effect.unknown-label` finding, rendered (ADR-103 WD1 / WD14; #384).
    #
    # It carries the spelling, the nearest recognised label and the retirement record, and knows how
    # to say all three in one sentence. What it deliberately does NOT carry is where the label was
    # written or what the surface was: an envelope in `.rbs`, an rbs-inline annotation in `.rb` and a
    # `.rigor.yml` list all reduce to "a place named this label, and now it means nothing", so the
    # caller supplies the `subject` and the `consequence` and this supplies the vocabulary judgment.
    # That is the seam [#385](https://github.com/rigortype/rigor/issues/385)'s `envelopes[].effect`
    # and `attribution:` values point at.
    #
    # {.for} answers `nil` unless {LabelIntent} says the spelling is evidently a label — the whole
    # point of the diagnostic is that it fires where intent is evident and nowhere else.
    class UnknownLabelReport < Data.define(:token, :suggestion, :retirement)
      # @param token [String] the spelling as written.
      # @param registry [Rigor::Effects::Registry, nil] the vocabulary after plugin load.
      # @param siblings [Array<String>] the other tokens written alongside it.
      # @return [UnknownLabelReport, nil]
      def self.for(token:, registry:, siblings: [])
        return nil unless LabelIntent.evident?(token, registry, siblings: siblings)

        new(
          token: token.to_s,
          suggestion: registry.suggest(token.to_s),
          retirement: Array(registry.retired(token.to_s)).map(&:to_s).freeze
        )
      end

      # Whether the vocabulary once carried this spelling and moved it. A retirement outranks a
      # nearest-neighbour guess: the registry KNOWS where this label went, so guessing would be
      # strictly worse information.
      def retired?
        !retirement.nil? && !retirement.empty?
      end

      # The sentence a reader can act on. `subject` names the declaration ("Effect envelope on
      # `Foo#bar`"), `consequence` says what the degradation cost ("the annotation now bounds
      # nothing") — the fail-open reading stated out loud, because a silently-unbounded envelope is
      # exactly what this diagnostic exists to make visible.
      def message(subject:, consequence:)
        "#{subject} names #{token}, which is not a known effect label#{qualifier}; #{consequence}."
      end

      private

      def qualifier
        return " (#{token} is retired; write #{retirement.join(' or ')} instead)" if retired?
        return " (did you mean #{suggestion}?)" if suggestion

        ""
      end
    end
  end
end
