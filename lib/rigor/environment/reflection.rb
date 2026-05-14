# frozen_string_literal: true

module Rigor
  class Environment
    # Frozen, `Ractor.shareable?` read-only RBS query facade.
    # [ADR-15](../../../docs/adr/15-ractor-concurrency.md)
    # Phase 2b extracts the read-only surface of {RbsLoader}
    # into this carrier so future Ractor-isolated workers
    # can share one Reflection across the pool while keeping
    # the per-Ractor mutable accelerator state (per-process
    # memo Hashes) where it belongs.
    #
    # Backing tables (all frozen at construction):
    #
    # - `known_class_names` — `Set<String>` of every
    #   class / module / alias name in the loaded RBS
    #   environment. Top-level prefixed (`"::Hash"`); plain
    #   queries normalise via {#normalise}.
    # - `instance_definitions` —
    #   `Hash<String, RBS::Definition>` keyed on
    #   `RBS::TypeName#to_s` (top-level prefixed).
    # - `singleton_definitions` — same shape, singleton side.
    # - `type_param_names` —
    #   `Hash<String, Array<Symbol>>` of declared type
    #   parameters per class.
    # - `constant_types` — `Hash<String, Rigor::Type>` of
    #   translated constant declarations.
    # - `ancestor_names` — `Hash<String, Array<String>>` of
    #   normalised ancestor chains per class.
    #
    # Each `Reflection` instance is `frozen?` at construction
    # — every cached table is frozen, `self` is frozen.
    # **NOT** `Ractor.shareable?`: the `instance_definitions`
    # / `singleton_definitions` tables hold upstream
    # `RBS::Definition` objects that transitively reference
    # `RBS::Location` (C-extension state that
    # `Ractor.make_shareable` rejects).
    #
    # The Ractor worker pool (ADR-15 Phase 4) sidesteps this
    # by having each worker build ITS OWN `Reflection` from
    # the shared `Cache::Store`. The cross-Ractor sharing
    # point is the Store's on-disk + in-process memo layer,
    # NOT the Reflection itself. Each Reflection is a per-
    # Ractor immutable read-side view; this carrier exists
    # to GUARANTEE the per-worker view never mutates after
    # construction.
    #
    # If a future RBS release makes `RBS::Location`
    # Ractor-shareable, swapping the `freeze` call below for
    # `Ractor.make_shareable(self)` makes the whole carrier
    # cross-Ractor-shareable in one line. Until then, the
    # frozen-read-only contract is the deliverable.
    class Reflection
      attr_reader :known_class_names, :instance_definitions, :singleton_definitions,
                  :type_param_names, :constant_types, :ancestor_names

      def initialize(known_class_names:, instance_definitions:, singleton_definitions:,
                     type_param_names:, constant_types:, ancestor_names:)
        @known_class_names = freeze_set(known_class_names)
        @instance_definitions = freeze_hash(instance_definitions)
        @singleton_definitions = freeze_hash(singleton_definitions)
        @type_param_names = freeze_hash(type_param_names)
        @constant_types = freeze_hash(constant_types)
        @ancestor_names = freeze_hash(ancestor_names)
        freeze
      end

      def class_known?(name)
        @known_class_names.include?(rooted(name))
      end

      def instance_definition(name)
        @instance_definitions[rooted(name)]
      end

      def singleton_definition(name)
        @singleton_definitions[rooted(name)]
      end

      def class_type_param_names(name)
        @type_param_names.fetch(unrooted(name), [])
      end

      def constant_type(name)
        @constant_types[rooted(name)]
      end

      # Three-valued `(lhs, rhs)` relation:
      # `:equal` / `:subclass` / `:superclass` / `:disjoint` /
      # `:unknown`. Mirrors {RbsHierarchy#class_ordering}'s
      # contract; the Reflection's frozen ancestor table
      # supports the same queries without any in-process
      # mutation.
      def class_ordering(lhs, rhs)
        lhs = unrooted(lhs)
        rhs = unrooted(rhs)
        return :equal if lhs == rhs

        lhs_ancestors = @ancestor_names[lhs]
        rhs_ancestors = @ancestor_names[rhs]
        return :unknown if lhs_ancestors.nil? || rhs_ancestors.nil? || lhs_ancestors.empty? || rhs_ancestors.empty?

        if lhs_ancestors.include?(rhs)
          :subclass
        elsif rhs_ancestors.include?(lhs)
          :superclass
        else
          :disjoint
        end
      end

      # Yields every known class / module / alias name in
      # the loader's canonical rooted form (`"::Hash"`).
      def each_known_class_name(&)
        @known_class_names.each(&)
      end

      private

      # The cached tables use mixed key conventions inherited
      # from the underlying RBS::TypeName surface: the
      # name-set / definition tables / constant table store
      # rooted `"::Foo"` keys; the type-param / ancestor
      # tables store unrooted `"Foo"`. Reflection's queries
      # normalise per-lookup so callers can pass either form.
      def rooted(name)
        s = name.to_s
        s.start_with?("::") ? s : "::#{s}"
      end

      def unrooted(name)
        name.to_s.delete_prefix("::")
      end

      def freeze_set(value)
        return value if value.is_a?(Set) && value.frozen?

        case value
        when Set then value.dup.freeze
        when Array, Hash then Set.new(value).freeze
        else raise ArgumentError, "expected Set / Array / Hash, got #{value.class}"
        end
      end

      def freeze_hash(value)
        return value if value.frozen?

        value.dup.freeze
      end
    end
  end
end
