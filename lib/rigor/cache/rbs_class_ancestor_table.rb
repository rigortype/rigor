# frozen_string_literal: true

require_relative "rbs_descriptor"

module Rigor
  module Cache
    # Cache producer that materialises the RBS-declared ancestor
    # chain of every loaded class / module into a Marshal-clean
    # `Hash<String, Array<String>>`. Ancestor names are top-level-
    # stripped (e.g. `"Integer"` not `"::Integer"`) to match
    # `Environment::RbsHierarchy#normalize_name`.
    #
    # The hierarchy is the substrate behind every `class_ordering`
    # query, which is itself a hot path on the dispatcher (overload
    # selection, narrowing, etc.). Building one ancestor chain
    # requires a full `RBS::DefinitionBuilder#build_instance` over
    # that class — a cold-cost dominated by RBS's own resolution
    # work. Caching the table lets a warm process skip the build
    # entirely and pay only a `Marshal.load` of the resulting
    # hash.
    #
    # Cache descriptor shape is shared with every other cache
    # producer that depends on the RBS environment — see
    # {RbsDescriptor.build}.
    class RbsClassAncestorTable
      PRODUCER_ID = "rbs.class_ancestor_table"

      # @param loader [Rigor::Environment::RbsLoader]
      # @param store [Rigor::Cache::Store]
      # @return [Hash{String => Array<String>}]
      def self.fetch(loader:, store:)
        descriptor = RbsDescriptor.build(loader)
        store.fetch_or_compute(producer_id: PRODUCER_ID, params: {}, descriptor: descriptor) do
          compute(loader)
        end
      end

      def self.compute(loader)
        table = {}
        loader.each_known_class_name do |name|
          key = name.delete_prefix("::")
          ancestors = ancestors_for(loader, key)
          table[key] = ancestors unless ancestors.nil?
        end
        table
      end

      def self.ancestors_for(loader, class_name)
        definition = loader.instance_definition(class_name)
        return nil if definition.nil?

        definition.ancestors.ancestors
                  .map { |ancestor| ancestor.name.to_s.delete_prefix("::") }
                  .uniq
                  .freeze
      rescue StandardError
        nil
      end

      private_class_method :compute, :ancestors_for
    end
  end
end
