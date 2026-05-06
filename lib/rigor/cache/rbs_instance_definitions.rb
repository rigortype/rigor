# frozen_string_literal: true

require_relative "rbs_descriptor"
require_relative "rbs_environment_marshal_patch"

module Rigor
  module Cache
    # Cache producer that materialises the full
    # `Hash<String, RBS::Definition>` for instance-side class
    # definitions in the RBS environment, in a single cache
    # entry. Mirrors the {RbsConstantTable} layout.
    #
    # ADR-7 § "Slice 6-D" carry-over and dogfooding feedback:
    # the earlier per-class cache layout (one entry per class,
    # ~1300 files) made warm runs *slower* than `--no-cache`
    # because each `instance_definition` call paid disk-open +
    # `Marshal.load` overhead and the in-memory
    # `RBS::DefinitionBuilder.build_instance` was actually fast
    # given a cached `RBS::Environment`. The single-blob layout
    # collapses that to one `Marshal.load` per process; warm runs
    # now match `--no-cache` timing while preserving the
    # cross-process invalidation story.
    #
    # Marshal-cleanness of `RBS::Definition` is enabled by the
    # v0.0.9 C2 `RBS::Location` patch.
    class RbsInstanceDefinitions
      PRODUCER_ID = "rbs.instance_definitions"

      # @param loader [Rigor::Environment::RbsLoader]
      # @param store [Rigor::Cache::Store]
      # @return [Hash{String => RBS::Definition}]
      def self.fetch(loader:, store:)
        descriptor = RbsDescriptor.build(loader)
        store.fetch_or_compute(producer_id: PRODUCER_ID, params: {}, descriptor: descriptor) do
          compute(loader)
        end
      end

      def self.compute(loader)
        table = {}
        loader.each_known_class_name do |name|
          definition = loader.uncached_instance_definition(name)
          table[name] = definition if definition
        end
        table
      end

      private_class_method :compute
    end

    # Singleton-side equivalent of {RbsInstanceDefinitions}.
    # Caches the full `Hash<String, RBS::Definition>` for the
    # singleton class of every RBS-known class.
    class RbsSingletonDefinitions
      PRODUCER_ID = "rbs.singleton_definitions"

      # @param loader [Rigor::Environment::RbsLoader]
      # @param store [Rigor::Cache::Store]
      # @return [Hash{String => RBS::Definition}]
      def self.fetch(loader:, store:)
        descriptor = RbsDescriptor.build(loader)
        store.fetch_or_compute(producer_id: PRODUCER_ID, params: {}, descriptor: descriptor) do
          compute(loader)
        end
      end

      def self.compute(loader)
        table = {}
        loader.each_known_class_name do |name|
          definition = loader.uncached_singleton_definition(name)
          table[name] = definition if definition
        end
        table
      end

      private_class_method :compute
    end
  end
end
