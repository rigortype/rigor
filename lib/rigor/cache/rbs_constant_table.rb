# frozen_string_literal: true

require_relative "rbs_descriptor"

module Rigor
  module Cache
    # Cache producer that materialises every RBS-declared constant
    # to its translated `Rigor::Type` form and stores the result as
    # a `Hash<String, Rigor::Type>` keyed by canonical constant name.
    # This is the v0.0.8 first cached producer per ADR-6 § 7; it
    # caches a post-translation artefact so the cache value is
    # `Marshal`-clean (RBS-native objects carry `RBS::Location`,
    # which lacks `_dump_data`).
    #
    # Cache descriptor shape is shared with every other cache
    # producer that depends on the RBS environment — see
    # {RbsDescriptor.build} for the slot definitions.
    class RbsConstantTable
      PRODUCER_ID = "rbs.constant_type_table"

      # @param loader [Rigor::Environment::RbsLoader]
      # @param store [Rigor::Cache::Store]
      # @return [Hash{String => Rigor::Type}]
      def self.fetch(loader:, store:)
        descriptor = RbsDescriptor.build(loader)
        store.fetch_or_compute(producer_id: PRODUCER_ID, params: {}, descriptor: descriptor) do
          compute(loader)
        end
      end

      def self.compute(loader)
        table = {}
        loader.each_constant_decl do |name, entry|
          translated = Inference::RbsTypeTranslator.translate(entry.decl.type)
          table[name] = translated unless translated.is_a?(Type::Bot)
        rescue StandardError
          # Skip entries whose RBS type fails to translate; the cache
          # stays robust to a broken signature rather than corrupting
          # the whole table.
        end
        table
      end

      private_class_method :compute
    end
  end
end
