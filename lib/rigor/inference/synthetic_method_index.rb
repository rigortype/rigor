# frozen_string_literal: true

require_relative "synthetic_method"

module Rigor
  module Inference
    # Frozen, Ractor-shareable lookup table for the synthetic
    # methods emitted by ADR-16 Tier C declarations during a
    # single `Analysis::Runner#run`. Constructed by the pre-pass
    # scanner (see {SyntheticMethodScanner}) and consulted by
    # {MethodDispatcher} below `RbsDispatch.try_dispatch` (per WD13:
    # user-authored RBS overrides substrate synthesis).
    #
    # The index is keyed by `(class_name, method_name, kind)`. A
    # single key may resolve to multiple {SyntheticMethod} records
    # if two plugins emit the same name (e.g. `rigor-dry-struct`
    # and a hypothetical `rigor-dry-struct-extras` both registering
    # the same attribute). Per ADR-16 WD11 / the WD-discussion in
    # `## Open questions` the dispatcher uses first-wins by
    # registration order; this index preserves that order in
    # `lookup`'s return.
    #
    # ## Slice 2b — return-type precision posture
    #
    # The recorded `SyntheticMethod#return_type` is a String
    # (e.g. `"ActiveStorage::Attached::One"`), preserved verbatim
    # from the manifest's emit table. Slice 2b's engine wiring
    # treats every match as returning `Dynamic[T]` per WD13's
    # floor — the recorded string is the input to a later slice's
    # precision promotion via ADR-13's `Plugin::TypeNodeResolver`.
    class SyntheticMethodIndex
      attr_reader :entries

      def initialize(entries: [])
        unless entries.is_a?(Array) && entries.all?(SyntheticMethod)
          raise ArgumentError,
                "SyntheticMethodIndex#entries must be an Array of SyntheticMethod, got #{entries.inspect}"
        end

        @entries = Ractor.make_shareable(entries.dup)
        @by_instance = Ractor.make_shareable(bucket(entries, SyntheticMethod::INSTANCE))
        @by_singleton = Ractor.make_shareable(bucket(entries, SyntheticMethod::SINGLETON))
        freeze
      end

      def empty?
        entries.empty?
      end

      # Returns an Array of matching {SyntheticMethod} records in
      # plugin-registration order. Empty Array when no plugin has
      # declared a Tier C entry that interpolates to this name.
      def lookup_instance(class_name, method_name)
        @by_instance.fetch([class_name, method_name.to_sym], EMPTY_ROW)
      end

      def lookup_singleton(class_name, method_name)
        @by_singleton.fetch([class_name, method_name.to_sym], EMPTY_ROW)
      end

      def to_h
        { "entries" => entries.map(&:to_h) }
      end

      EMPTY_ROW = [].freeze

      def bucket(entries, kind)
        h = {}
        entries.each do |entry|
          next unless entry.kind == kind

          key = [entry.class_name, entry.method_name]
          (h[key] ||= []) << entry
        end
        h.each_value(&:freeze).freeze
      end
      private :bucket

      EMPTY = new(entries: []).freeze
    end
  end
end
