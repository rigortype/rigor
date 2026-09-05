# frozen_string_literal: true

require_relative "label_set"
require_relative "method_key"

module Rigor
  module Effects
    # The project's own `effects.attribution:` table — what a call into code Rigor never analysed does
    # (ADR-103 WD5 (6) / WD6; design note § 6.6).
    #
    # A gem method has no body here, so someone must colour it. The catalogue ({Catalog}) answers for
    # Ruby's own surface, a plugin answers for a framework it models, and this table is the project's
    # answer for everything left: `attribution: {"Net::HTTP.get": [io.net.http]}`.
    #
    # **It never discharges the taint.** A configured attribution is an unchecked claim about code the
    # analyzer did not read, so WD6 puts it in the *declared* lane and keeps the site's
    # `plugin-attribution` cause: the summary reads "declared this, and possibly more" rather than
    # "proven this". That is the whole difference between this table and a catalogue row, and it is why an
    # envelope can never fire because of one — diagnostics read the proven lane only.
    #
    # The lookup is deliberately the same shape the catalogue's is: the owner the syntax names when it
    # names one (`Net::HTTP.get`), and the class the typer projected the receiver to otherwise. So a table
    # keyed `Logger#info` colours `logger.info(…)` on a receiver typed `Logger`, by name, without needing
    # the dispatcher to have resolved anything.
    class Attribution
      EMPTY_ROWS = {}.freeze
      private_constant :EMPTY_ROWS

      def self.empty
        @empty ||= new({})
      end

      # @rbs table: Hash[String, Array[String]] --
      #   `Configuration#effects_attribution` — method key to label list, both already shape-validated at load (tier
      #   2).
      def self.build(table)
        return empty if table.nil? || table.empty?

        new(table)
      end

      def initialize(table)
        @rows = build_rows(table)
        freeze
      end

      def empty?
        @rows.empty?
      end

      # The labels attributed to a method key (`Net::HTTP.get`), or nil when the table says nothing about
      # it. The key is spelled by the caller, which already builds the same string for the catalogue.
      #
      # @rbs return: LabelSet?
      def [](key)
        @rows[key]
      end

      private

      # A malformed key cannot arrive from `Configuration` (tier 2 rejects it), but this class is also
      # constructed straight from a Hash in specs and by a future plugin channel (#387), so an
      # unparseable key is dropped rather than raised on: attribution is an enrichment, and a bad row
      # must not take a run down.
      def build_rows(table)
        return EMPTY_ROWS if table.empty?

        table.each_with_object({}) do |(key, labels), out|
          next if MethodKey.split(key.to_s).nil?

          set = LabelSet.new(Array(labels).map(&:to_s))
          out[key.to_s] = set unless set.empty?
        end.freeze
      end
    end
  end
end
