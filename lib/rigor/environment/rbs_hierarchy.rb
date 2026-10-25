# frozen_string_literal: true

module Rigor
  class Environment
    # Small hierarchy oracle backed by RBS instance definitions.
    class RbsHierarchy
      def initialize(loader)
        @loader = loader
        @ancestor_names_cache = {}
        @class_ordering_cache = {}
      end

      def class_ordering(lhs, rhs)
        lhs = normalize_name(lhs)
        rhs = normalize_name(rhs)
        return :equal if lhs == rhs

        key = [lhs, rhs]
        return @class_ordering_cache[key] if @class_ordering_cache.key?(key)

        @class_ordering_cache[key] = compute_class_ordering(lhs, rhs)
      end

      private

      attr_reader :loader

      def compute_class_ordering(lhs, rhs)
        return :unknown unless loader.class_known?(lhs) && loader.class_known?(rhs)

        lhs_ancestors = ancestor_names(lhs)
        rhs_ancestors = ancestor_names(rhs)
        return :unknown if lhs_ancestors.empty? || rhs_ancestors.empty?

        if lhs_ancestors.include?(rhs)
          :subclass
        elsif rhs_ancestors.include?(lhs)
          :superclass
        else
          :disjoint
        end
      end

      # Issue #696 review, second pass — the ancestry lookup lives in {RbsLoader#ancestor_names_for}.
      # Read directly from `Cache::RbsClassAncestorTable`, the same question gave 504 failed classes on a
      # cold store, 0 on a warm one and 2 with no store, and the cold answer was cached into the run result.
      # Through the loader, both cache states are marked as Rigor's own demand, so ordering two classes
      # never reaches the "which classes failed to build" diagnostic. The cache-state branch stays behind
      # the loader (it is worth 50x on the warm path); this method keeps only its per-name memo.
      def ancestor_names(class_name)
        key = normalize_name(class_name)
        return @ancestor_names_cache[key] if @ancestor_names_cache.key?(key)

        @ancestor_names_cache[key] = loader.ancestor_names_for(key)
      end

      # Allocates only when there is a prefix to strip (see `Environment#normalize_class_name`).
      def normalize_name(name)
        name = name.to_s
        name.start_with?("::") ? name.delete_prefix("::") : name
      end
    end
  end
end
