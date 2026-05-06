# frozen_string_literal: true

require_relative "rbs_descriptor"

module Rigor
  module Cache
    # Per-class cache producer for RBS-side `RBS::Definition`
    # objects (instance side). Each (class_name, signature_paths,
    # libraries) combination is one cache entry; subsequent calls
    # for the same class skip the `RBS::DefinitionBuilder.build_instance`
    # work and load from disk via Marshal round-trip.
    #
    # ADR-7 § "Slice 6-D" carry-over re-attempt. Marshal-cleanness
    # of `RBS::Definition` is enabled by the v0.0.9 C2
    # `RBS::Location` patch. A previous v0.0.9 attempt at this
    # wiring triggered an analyzer regression
    # (`uninitialized constant Rigor::Cache::RbsDescriptor::Descriptor`);
    # the producer here uses fully-qualified
    # `Rigor::Cache::Descriptor` references throughout to keep
    # constant lookup unambiguous.
    class RbsInstanceDefinitions
      PRODUCER_ID = "rbs.instance_definition"

      # @param loader [Rigor::Environment::RbsLoader]
      # @param store [Rigor::Cache::Store]
      # @param class_name [String, Symbol]
      # @return [RBS::Definition, nil]
      def self.fetch(loader:, store:, class_name:)
        require_relative "rbs_environment_marshal_patch"
        descriptor = RbsDescriptor.build(loader)
        store.fetch_or_compute(
          producer_id: PRODUCER_ID,
          params: { class_name: class_name.to_s },
          descriptor: descriptor
        ) do
          loader.uncached_instance_definition(class_name)
        end
      end
    end

    # Per-class cache producer for RBS-side `RBS::Definition`
    # objects (singleton side — `Class#new`, class methods,
    # singleton-class inheritance). Mirrors {RbsInstanceDefinitions};
    # see that class for the full cache contract.
    class RbsSingletonDefinitions
      PRODUCER_ID = "rbs.singleton_definition"

      # @param loader [Rigor::Environment::RbsLoader]
      # @param store [Rigor::Cache::Store]
      # @param class_name [String, Symbol]
      # @return [RBS::Definition, nil]
      def self.fetch(loader:, store:, class_name:)
        require_relative "rbs_environment_marshal_patch"
        descriptor = RbsDescriptor.build(loader)
        store.fetch_or_compute(
          producer_id: PRODUCER_ID,
          params: { class_name: class_name.to_s },
          descriptor: descriptor
        ) do
          loader.uncached_singleton_definition(class_name)
        end
      end
    end
  end
end
