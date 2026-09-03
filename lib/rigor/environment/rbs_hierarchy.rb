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

      # Issue #696 review, second pass — the ancestry lookup moved to {RbsLoader#ancestor_names_for}, and
      # what moved with it is the reason.
      #
      # This method used to fetch `Cache::RbsClassAncestorTable` DIRECTLY, bypassing the loader's own
      # accessor, and branch on `loader.cache_store`: a whole-universe table build with a store, a
      # single-class demand without one. Same project, same question, three different answers to "which
      # classes failed to build" — 504 on a cold store, 0 on a warm one, 2 with no store. On the DEFAULT
      # `--workers=0` path nothing pre-warms the store, so the cold answer was the one written into the
      # run-result cache and replayed until a file changed.
      #
      # The cache-state branch still exists — it is worth 50x on the warm path — but it lives behind the
      # loader now, where both of its sides are marked as RIGOR'S OWN demand. Ordering two classes is not
      # the analysis asking whether either one's methods resolve, so neither side reaches the diagnostic,
      # and the answer is identical on both (the table's producer computes exactly this, keyed the same
      # way). What this method keeps is its own per-name memo, which is about repeated comparisons.
      def ancestor_names(class_name)
        key = normalize_name(class_name)
        return @ancestor_names_cache[key] if @ancestor_names_cache.key?(key)

        @ancestor_names_cache[key] = loader.ancestor_names_for(key)
      end

      def normalize_name(name)
        name.to_s.delete_prefix("::")
      end
    end
  end
end
