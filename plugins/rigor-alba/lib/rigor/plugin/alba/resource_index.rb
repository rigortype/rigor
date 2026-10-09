# frozen_string_literal: true

module Rigor
  module Plugin
    class Alba < Rigor::Plugin::Base
      # The project's alba resource classes, as the {ResourceCollector} found them. A frozen value object the
      # `:resource_index` producer caches.
      #
      # Three questions are answered from it, and each is deliberately conservative — a wrong "no" costs a
      # missing type or a missing root, a wrong "yes" costs a false positive or a hidden dead class:
      #
      # - {#resource_names}: which classes are alba resources (`include Alba::Resource`, directly or through a
      #   superclass the project also defines), minus those that define their own `#serialize`.
      # - {#inferred_roots}: which classes alba's association inference would load, for associations that name
      #   neither `resource:` nor `serializer:` (see {ResourceCollector}).
      # - {#empty?}.
      class ResourceIndex
        # `lexical` is the enclosing class's full name, which alba hands to `Object.const_get` as `nesting`.
        Association = Data.define(:owner, :name)

        # A class the project declares. `superclass` is the constant as written (`nil` when absent).
        ClassEntry = Data.define(:name, :superclass, :includes_resource, :defines_serialize)

        # The resource-class suffixes alba's `infer_resource_class` tries, in order.
        SUFFIXES = %w[Resource Serializer].freeze
        VALID_ASSOCIATION_NAME = /\A[a-z_][a-z0-9_]*\z/

        def initialize(classes:, associations:)
          @classes = classes.to_h { |entry| [entry.name, entry] }.freeze
          @associations = associations.freeze
          freeze
        end

        def empty?
          @classes.empty?
        end

        # Full names of the alba resource classes whose `#serialize` is alba's own.
        def resource_names
          @classes.keys.select { |name| resource?(name) && !overrides_serialize?(name) }.sort
        end

        # The classes alba infers for the associations that name no resource, limited to
        #   those that exist in the project. The block receives each association name and returns alba's
        #   `classify` of it (the caller owns the inflector; ADR-39).
        def inferred_roots(&classify)
          roots = @associations.filter_map do |association|
            next unless resource?(association.owner)

            inferred_class(association, classify)
          end
          roots.uniq.sort
        end

        private

        # Alba tries `<Nesting>::<X>Resource`, then the top-level one (`const_get` on a module looks in Object),
        # and only then the same two for `<X>Serializer`. The first that exists is the one alba loads.
        def inferred_class(association, classify)
          return nil unless VALID_ASSOCIATION_NAME.match?(association.name)

          base = classify.call(association.name)
          return nil unless base.is_a?(String) && /\A[A-Z][A-Za-z0-9]*\z/.match?(base)

          nesting = association.owner.rpartition("::").first
          SUFFIXES.each do |suffix|
            candidates = ["#{base}#{suffix}"]
            candidates.unshift("#{nesting}::#{base}#{suffix}") unless nesting.empty?
            found = candidates.find { |candidate| @classes.key?(candidate) }
            return found if found
          end
          nil
        end

        def resource?(name)
          resource_chain?(name, {})
        end

        def resource_chain?(name, seen)
          entry = @classes[name]
          return false if entry.nil? || seen[name]

          seen[name] = true
          return true if entry.includes_resource

          parent = superclass_of(entry)
          !parent.nil? && resource_chain?(parent, seen)
        end

        def overrides_serialize?(name, seen = {})
          entry = @classes[name]
          return false if entry.nil? || seen[name]

          seen[name] = true
          return true if entry.defines_serialize

          parent = superclass_of(entry)
          !parent.nil? && overrides_serialize?(parent, seen)
        end

        # Resolves the superclass as written against the project's classes, innermost lexical scope first.
        def superclass_of(entry)
          written = entry.superclass
          return nil if written.nil?

          if written.start_with?("::")
            rooted = written.delete_prefix("::")
            return @classes.key?(rooted) ? rooted : nil
          end

          segments = entry.name.split("::")[0...-1]
          until segments.nil?
            candidate = (segments + [written]).join("::")
            return candidate if @classes.key?(candidate)

            segments = segments.empty? ? nil : segments[0...-1]
          end
          nil
        end
      end
    end
  end
end
