# frozen_string_literal: true

require_relative "rbs_descriptor"

module Rigor
  module Cache
    # Cache producer that materialises every loaded class's
    # RBS-declared type-parameter names as a Marshal-clean
    # `Hash<String, Array<Symbol>>` keyed by top-level-stripped
    # class name (e.g. `"Array"` → `[:Elem]`, `"Hash"` →
    # `[:K, :V]`). Producer id `"rbs.class_type_param_names"`.
    #
    # The dispatcher reads type-parameter names every time it
    # builds a substitution map from a receiver's `type_args`
    # into a method's return type — it is one of the hottest
    # reflection lookups during analysis. Building one entry
    # requires a full `RBS::DefinitionBuilder#build_instance`
    # over that class, the same expensive operation
    # {RbsClassAncestorTable} caches; the two producers share
    # the build cost when populated together.
    #
    # Cache descriptor shape is shared with every other cache
    # producer that depends on the RBS environment — see
    # {RbsDescriptor.build}.
    class RbsClassTypeParamNames
      PRODUCER_ID = "rbs.class_type_param_names"

      # @param loader [Rigor::Environment::RbsLoader]
      # @param store [Rigor::Cache::Store]
      # @return [Hash{String => Array<Symbol>}]
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
          params = type_params_for(loader, key)
          table[key] = params unless params.nil?
        end
        table
      end

      def self.type_params_for(loader, class_name)
        definition = loader.instance_definition(class_name)
        return nil if definition.nil?

        definition.type_params.dup.freeze
      rescue StandardError
        nil
      end

      private_class_method :compute, :type_params_for
    end
  end
end
