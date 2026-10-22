# frozen_string_literal: true

require "digest"

require_relative "synthetic_method"

module Rigor
  module Inference
    # Frozen, Ractor-shareable lookup table for the synthetic methods emitted by ADR-16 Tier C declarations during a
    # single `Analysis::Runner#run`. Constructed by the pre-pass scanner (see {SyntheticMethodScanner}) and consulted by
    # {MethodDispatcher} below `RbsDispatch.try_dispatch` (per WD13: user-authored RBS overrides substrate synthesis).
    #
    # The index is keyed by `(class_name, method_name, kind)`. A single key may resolve to multiple {SyntheticMethod}
    # records if two plugins emit the same name (e.g. `rigor-dry-struct` and a hypothetical `rigor-dry-struct-extras`
    # both registering the same attribute). Per ADR-16 WD11 / the WD-discussion in `## Open questions` the dispatcher
    # uses first-wins by registration order; this index preserves that order in `lookup`'s return.
    #
    # ## Slice 2b — return-type precision posture
    #
    # The recorded `SyntheticMethod#return_type` is a String (e.g. `"ActiveStorage::Attached::One"`), preserved verbatim
    # from the manifest's emit table. Slice 2b's engine wiring treats every match as returning `Dynamic[T]` per WD13's
    # floor — the recorded string is the input to a later slice's precision promotion via ADR-13's
    # `Plugin::TypeNodeResolver`.
    class SyntheticMethodIndex
      attr_reader :entries, :class_names

      # @param class_names — names of classes the substrate synthesises wholesale (ADR-36
      #   nested-class emission — the variant subclasses that have no RBS/source declaration of their own). Recorded so
      #   `Environment#class_known?` can resolve them as classes (their constant reference + `.new` dispatch) even
      #   though nothing else in the type universe declares them. Tier B/C method emissions leave this empty (their
      #   receiver classes are already real).
      def initialize(entries: [], class_names: [])
        unless entries.is_a?(Array) && entries.all?(SyntheticMethod)
          raise ArgumentError,
                "SyntheticMethodIndex#entries must be an Array of SyntheticMethod, got #{entries.inspect}"
        end

        @entries = Ractor.make_shareable(entries.dup)
        @by_instance = Ractor.make_shareable(bucket(entries, SyntheticMethod::INSTANCE))
        @by_singleton = Ractor.make_shareable(bucket(entries, SyntheticMethod::SINGLETON))
        @class_names = Ractor.make_shareable(class_names.to_a.map(&:to_s).uniq.freeze)
        @class_name_set = Ractor.make_shareable(@class_names.to_set)
        freeze
      end

      def empty?
        entries.empty? && class_names.empty?
      end

      # True when `name` is a substrate-synthesised class (an ADR-36 variant subclass). Used by
      # `Environment#class_known?` so the constant resolves and `.new` dispatches.
      def knows_class?(name)
        @class_name_set.include?(name.to_s)
      end

      # Returns an Array of matching {SyntheticMethod} records in plugin-registration order. Empty Array when no plugin
      # has declared a Tier C entry that interpolates to this name.
      def lookup_instance(class_name, method_name)
        @by_instance.fetch([class_name, method_name.to_sym], EMPTY_ROW)
      end

      def lookup_singleton(class_name, method_name)
        @by_singleton.fetch([class_name, method_name.to_sym], EMPTY_ROW)
      end

      def to_h
        { "entries" => entries.map(&:to_h), "class_names" => class_names }
      end

      # What a dispatch can read from the index, digested (nil for the empty index): each key's rows in their
      # first-wins order, with the return type and the Tier B `origin_module` the dispatcher promotes through,
      # and the synthesised class names. The rest of the provenance (the call site's path and line) is left
      # out, so an edit that only moves the `devise` line keeps the digest. `IncrementalSession` compares it
      # across runs (PR #2286 review M1): the index is built from class-body calls that no declaration
      # signature records, so a recheck that sees it move cannot trust its served files.
      def surface_digest
        return nil if empty?

        rows = entries.each_with_index
                      .sort_by { |entry, index| [entry.kind.to_s, entry.class_name, entry.method_name.to_s, index] }
                      .map { |entry, _| surface_row(entry) }
        Digest::SHA256.hexdigest((rows + class_names.sort.map { |name| "class\x1f#{name}" }).join("\x00"))
      end

      EMPTY_ROW = [].freeze

      def surface_row(entry)
        [entry.kind, entry.class_name, entry.method_name, entry.return_type,
         entry.provenance[:origin_module], entry.provenance[:plugin_id]].join("\x1f")
      end
      private :surface_row

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
