# frozen_string_literal: true

require_relative "label"

module Rigor
  module Effects
    # Whether an unrecognised effect label is evidence of a **typo** rather than of a word that was
    # never meant to be a label at all (ADR-103 WD1; normative in
    # `docs/type-specification/effect-labels.md` § Unknown labels).
    #
    # The degradation an unknown label causes is silent by construction — the tag reads ⊤ and stops
    # bounding anything — so a paired diagnostic is the only thing that keeps the fail-open rule
    # honest. But the diagnostic cannot fire on every unrecognised spelling: a vocabulary is open by
    # design (`effects.labels:`, a plugin's own root), so an unknown word is as likely to be a label
    # this project has not registered yet as it is to be a misspelling. Reporting both would put a
    # finding on correct-by-intent code, which is the direction the false-positive budget is not
    # allowed to run ([ADR-5](../../../docs/adr/5-robustness-principle.md)).
    #
    # Intent is therefore read off four signals, any one of which is enough:
    #
    # 1. **A near miss** — the spelling is within {Registry::SUGGESTION_DISTANCE_CAP} edits of a
    #    label the registry knows (`io.bd` against `io.db`).
    # 2. **A known sibling** — another member of the same comma-separated list is recognised, so the
    #    list as a whole is demonstrably written in this vocabulary.
    # 3. **A dotted path** — the token carries two or more segments (`io.netw`). Nothing but a label
    #    is spelled that way; a project opening its own root writes a bare word first.
    # 4. **A retired spelling** — the registry's `retired:` table names it, so the author wrote a
    #    label that WAS correct and a vocabulary bump moved it.
    #
    # A lone far-off word (`%a{rigor:v1:effect database}`) matches none of them and stays silent
    # everywhere. It still degrades the tag to ⊤ — the reading never depends on this module.
    module LabelIntent
      # How many dot-separated segments make a token unmistakably label-shaped (signal 3).
      MULTI_SEGMENT_ARITY = 2

      module_function

      # Whether reporting `token` as an unknown label is justified.
      #
      # @rbs token: String -- The spelling as written.
      # @rbs registry: Rigor::Effects::Registry? --
      #   The vocabulary AFTER plugin load; `nil` (no vocabulary at all) makes every token unjudgeable and therefore
      #   silent.
      # @rbs siblings: Array[String] -- The other tokens of the same list / the same config value.
      def evident?(token, registry, siblings: [])
        return false if registry.nil?
        return false unless Label.valid?(token)
        return false if registry.known?(token)

        retired?(token, registry) || near_miss?(token, registry) ||
          multi_segment?(token) || known_sibling?(token, registry, siblings)
      end

      def retired?(token, registry)
        !Array(registry.retired(token)).empty?
      end

      def near_miss?(token, registry)
        !registry.suggest(token).nil?
      end

      def multi_segment?(token)
        Label.segments(token).length >= MULTI_SEGMENT_ARITY
      end

      def known_sibling?(token, registry, siblings)
        Array(siblings).any? { |sibling| sibling != token && registry.known?(sibling.to_s) }
      end

      private_class_method :retired?, :near_miss?, :multi_segment?, :known_sibling?
    end
  end
end
