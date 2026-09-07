# frozen_string_literal: true

require_relative "rbs_descriptor"
require_relative "rbs_cache_producer"
require_relative "rbs_environment_marshal_patch"

module Rigor
  module Cache
    # Cache producer that materialises the entire `RBS::Environment` (the loader's `build_env` result) and
    # round-trips it through `Marshal` against the patched `RBS::Location` (see
    # {RbsEnvironmentMarshalPatch}).
    #
    # Cold runs pay the full `RBS::EnvironmentLoader#load + RBS::Environment.from_loader +
    # resolve_type_names` cost once; warm runs (and a separate loader sharing the same Store) load the
    # marshalled blob and skip the parse / resolve stages entirely. The `RbsConstantTable`,
    # `RbsKnownClassNames`, `RbsClassAncestorTable`, and `RbsClassTypeParamNames` caches still live alongside
    # this producer — their cached values are reached without re-touching env, but when an uncached lookup
    # happens (`instance_method`, `singleton_method`, …) the env produced here is what answers it.
    #
    # Cache descriptor shape is shared with every other cache producer that depends on the RBS environment —
    # see {RbsDescriptor.build}.
    class RbsEnvironment < RbsCacheProducer
      PRODUCER_ID = "rbs.environment"

      def self.compute(loader)
        Rigor::Environment::RbsLoader.build_env_for(
          libraries: loader.libraries,
          signature_paths: loader.signature_paths,
          virtual_rbs: loader.respond_to?(:virtual_rbs) ? loader.virtual_rbs : []
        )
      end

      private_class_method :compute
    end
  end
end
