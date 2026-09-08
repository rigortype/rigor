# frozen_string_literal: true

require_relative "rbs_descriptor"
require_relative "rbs_cache_producer"

module Rigor
  module Cache
    # Cache producer that materialises the set of every RBS-declared class / module / alias name (top-level
    # prefixed, e.g. `"::Math"`) currently loaded into the environment. Marshal-clean — the cache value is a
    # `Set<String>`.
    #
    # The set lets `RbsLoader#class_known?` answer point lookups in O(1) without re-parsing the name on each
    # call, and lets a warm process skip the env walk entirely (the env still has to be built to enumerate
    # decls on cold misses; subsequent processes sharing the Store load the set straight from disk).
    #
    # Cache descriptor shape is shared with {RbsConstantTable} via {RbsDescriptor.build}; a single signature
    # change or rbs gem bump invalidates both producers in lockstep.
    class RbsKnownClassNames < RbsCacheProducer
      PRODUCER_ID = "rbs.known_class_names"

      def self.compute(loader)
        names = Set.new
        loader.each_known_class_name { |name| names << name }
        names
      end

      private_class_method :compute
    end
  end
end
