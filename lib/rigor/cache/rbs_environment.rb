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

      # Issue #610 — the deferred (plugin-contributed) subset rides through too. This is the build path every
      # cached run takes: a cache store is the CLI default and only `--no-cache` reaches the loader's own
      # `build_env`, so a list threaded through the loader but not through here ran the arity stand-down on
      # no real `rigor check` at all — 0.3.8 shipped exactly that, behind a green gate built over a
      # store-less loader. Any input `build_env_for` takes MUST be passed from here as well.
      def self.compute(loader)
        Rigor::Environment::RbsLoader.build_env_for(
          libraries: loader.libraries,
          signature_paths: loader.signature_paths,
          virtual_rbs: loader.respond_to?(:virtual_rbs) ? loader.virtual_rbs : [],
          deferred_signature_paths:
            loader.respond_to?(:deferred_signature_paths) ? loader.deferred_signature_paths : []
        )
      end

      private_class_method :compute
    end
  end
end
