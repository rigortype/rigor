# frozen_string_literal: true

module Rigor
  module Effects
    # Where one bundle of labels in a summary came from (ADR-103 WD14).
    #
    # An origin is the pair of **what** coloured the labels and **which source** did the colouring, and it
    # is deliberately **line-free**: two `puts` calls in one method share one origin, so a summary is stable
    # under a line move and a snapshot diff shows a change of behaviour rather than a change of formatting.
    # Call sites are kept separately, per run, for the report only.
    #
    # `name` is the callee key (`Kernel#puts`, `Time.now`) for a catalogued row, and the construct's name
    # (`xstring`, `gvar-write`) for a language construct. `source` says which of the two it is, because the
    # two namespaces overlap in principle and a later slice discharges policy per origin.
    class Origin < Data.define(:name, :source)
      # A Ruby language construct — backticks, a `$gvar` write, an `@ivar` write (§ 5.1 of the design note).
      CONSTRUCT = :construct
      # A row of the built-in effect catalogue ({Catalog}; `data/effects/core.yml` from #380).
      CATALOGUE = :catalogue
      # A row of the project's own `effects.attribution:` table — a claim about code Rigor did not
      # analyse. Its labels land in the summary's DECLARED lane and never in the proven one, and the site
      # keeps its `plugin-attribution` taint (ADR-103 WD6: "declared this, and possibly more").
      ATTRIBUTION = :attribution
      # An {Envelope} the callee's own declaration carries — a project annotation, an
      # `effects.envelopes:` convention, or an accepted signature's `%a{…}` (#386). Its labels land in
      # the DECLARED lane, like an attribution's, but unlike an attribution the bound is *checked* (or
      # trusted at the type tier), so the site is exhaustive rather than tainted: ADR-103 WD6's
      # discharging strata. `name` is the callee key the bound was resolved for.
      ENVELOPE = :envelope
      # A row of a loaded plugin's `effect_attributions:` — what the plugin that models a framework says a
      # call into it does (#387; ADR-103 WD6 / WD10). Its labels land in the DECLARED lane, like an
      # attribution's and an envelope's, and which of those two it behaves like is decided by the plugin's
      # standing: a **first-party bundled** plugin's row discharges, so the site is exhaustive, exactly as
      # an accepted signature's `%a{…}` is; a third-party plugin's does not, and the site keeps its
      # `plugin-attribution` taint. One origin source for both, because the label came from the same place
      # either way and `explain` should say so.
      PLUGIN = :plugin

      def self.construct(name)
        new(name: name.to_s, source: CONSTRUCT)
      end

      def self.catalogue(name)
        new(name: name.to_s, source: CATALOGUE)
      end

      def self.attribution(name)
        new(name: name.to_s, source: ATTRIBUTION)
      end

      def self.envelope(name)
        new(name: name.to_s, source: ENVELOPE)
      end

      def self.plugin(name)
        new(name: name.to_s, source: PLUGIN)
      end

      # The rendering the report and the JSON payload key on. Sorted lexicographically, so `catalogue:`
      # rows group before `construct:` ones and the output is deterministic.
      def to_s
        "#{source}:#{name}"
      end
    end
  end
end
