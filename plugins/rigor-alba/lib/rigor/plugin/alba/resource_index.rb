# frozen_string_literal: true

module Rigor
  module Plugin
    class Alba < Rigor::Plugin::Base
      # The project's alba resource classes, as the {ResourceCollector} found them. A frozen value object the
      # `:resource_index` producer caches.
      #
      # One question is answered from it, and deliberately conservatively — a wrong "no" costs a
      # missing type or a missing root, a wrong "yes" costs a false positive or a hidden dead class:
      #
      # {#inferred_roots}: which classes alba's association inference would load, for associations that name
      # neither `resource:` nor `serializer:` (see {ResourceCollector}).
      class ResourceIndex
        # `owner` is the enclosing class's full name, which alba hands to `Object.const_get` as `nesting`.
        # `in_block` is true when the call sits in a block of the resource body (`trait`, `nested`, an
        # association's own block): alba `class_eval`s those on an anonymous class, whose `name` is nil, so
        # only the top-level candidates are tried.
        Association = Data.define(:owner, :name, :in_block)

        # A class the project declares. `superclass` is the constant as written (`nil` when absent) and
        # `nesting` the `Module.nesting` chain (innermost first) its header was written under, which is where
        # Ruby resolves that constant.
        ClassEntry = Data.define(:name, :superclass, :nesting, :includes_resource)

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

          nesting = association.in_block ? "" : association.owner.rpartition("::").first
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

        # Resolves the superclass as written the way Ruby does: against the `Module.nesting` chain of the header,
        # innermost first, then the top level. A compact header (`class Admin::UserResource < Base`) does not put
        # `Admin` on the chain, so `Base` is not looked up under it.
        def superclass_of(entry)
          written = entry.superclass
          return nil if written.nil?

          if written.start_with?("::")
            rooted = written.delete_prefix("::")
            return @classes.key?(rooted) ? rooted : nil
          end

          (entry.nesting.map { |scope| "#{scope}::#{written}" } + [written]).find { |name| @classes.key?(name) }
        end
      end
    end
  end
end
