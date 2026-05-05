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

      def ancestor_names(class_name)
        key = normalize_name(class_name)
        return @ancestor_names_cache[key] if @ancestor_names_cache.key?(key)

        @ancestor_names_cache[key] =
          if loader.cache_store
            ancestor_table.fetch(key, [].freeze)
          else
            compute_ancestor_names(key)
          end
      end

      def compute_ancestor_names(key)
        definition = loader.instance_definition(key)
        return [].freeze if definition.nil?

        definition.ancestors.ancestors.map { |ancestor| normalize_name(ancestor.name.to_s) }.uniq.freeze
      rescue StandardError
        [].freeze
      end

      def ancestor_table
        @ancestor_table ||= begin
          require_relative "../cache/rbs_class_ancestor_table"
          Cache::RbsClassAncestorTable.fetch(loader: loader, store: loader.cache_store)
        end
      end

      def normalize_name(name)
        name.to_s.delete_prefix("::")
      end
    end
  end
end
