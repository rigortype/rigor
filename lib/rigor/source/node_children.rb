# frozen_string_literal: true

require "prism"

module Rigor
  module Source
    # Allocation-free replacement for the `node.compact_child_nodes.each { … }` idiom.
    #
    # `Prism::Node#compact_child_nodes` allocates a fresh Array on every call — for the ~43 leaf node classes
    # (`IntegerNode`, `LocalVariableReadNode`, `NilNode`, …) it is literally `def compact_child_nodes; []; end`.
    # Rigor's tree walkers call it unconditionally on every node of every walk, so one full-tree walk allocates one
    # Array per node visited. On leaf-heavy sources (a Ragel-generated parser has hundreds of thousands of
    # integer-literal leaves) these throwaway arrays are the single largest allocation source in a run — over half of
    # all allocations on mail's `lib`.
    #
    # {each_child} yields the same child nodes, in the same order, without materialising the intermediate array. It
    # reads each child-bearing field directly and iterates a `NodeListField`'s already-materialised array in place
    # (the reader returns the stored array, not a copy). Nil optional children and nil list elements are skipped,
    # mirroring `compact_child_nodes`'s "compact" semantics.
    #
    # Field access is compiled, not reflective: a per-class method with the field readers inlined as direct calls
    # (`node.receiver`, `node.arguments`, …) is generated once at load and dispatched by node class, so iteration
    # costs one method dispatch per node rather than one per field. A `public_send(reader)`-per-field loop was
    # measured ~45 % slower than `compact_child_nodes` on a full-tree walk — the dynamic-dispatch-per-field cost
    # swamps the allocation win; the compiled form stays within a few percent while dropping the allocations.
    #
    # The field map is derived once at load from `Prism::Reflection`, so it tracks whatever `prism` version resolves
    # at runtime (ADR-79) instead of a hand-maintained table. `spec/rigor/source/node_children_spec.rb` is the
    # binding contract: over a corpus of real source it asserts {each_child}'s output is element-for-element
    # identical (object identity and order) to `compact_child_nodes` for every node reached — the equivalence this
    # optimisation rests on.
    module NodeChildren
      module_function

      # The concrete `Prism::*Node` classes (`< Prism::Node`).
      NODE_CLASSES =
        Prism.constants.grep(/Node\z/).filter_map do |name|
          const = Prism.const_get(name)
          const if const.is_a?(Class) && const < Prism::Node
        end.freeze

      # Shared frozen empty entry for leaf classes, so a single hash lookup covers them with no per-leaf array.
      # Identity (`equal?`) distinguishes a leaf entry from a childless-in-practice non-leaf.
      EMPTY = [].freeze

      # node class => frozen Array of `[reader_symbol, :node | :list]` pairs, in field declaration order (the order
      # `compact_child_nodes` emits its children). Leaf classes map to {EMPTY}. This is the source of truth the
      # dispatch methods are generated from, and is exposed for introspection / the equivalence spec.
      CHILD_READERS =
        NODE_CLASSES.each_with_object({}) do |klass, map|
          pairs = Prism::Reflection.fields_for(klass).filter_map do |field|
            case field
            when Prism::Reflection::NodeField, Prism::Reflection::OptionalNodeField
              [field.name, :node].freeze
            when Prism::Reflection::NodeListField
              [field.name, :list].freeze
            end
          end
          map[klass] = pairs.empty? ? EMPTY : pairs.freeze
        end.freeze

      # The leaf classes — no child-bearing field, so `compact_child_nodes` is always `[]`. Exposed for the
      # equivalence spec and introspection; a leaf has no dispatch entry, so {each_child} no-ops on it.
      LEAF_CLASSES = NODE_CLASSES.select { |klass| CHILD_READERS[klass].equal?(EMPTY) }.to_set.freeze

      # Holds the generated per-class child-yielding methods, one per non-leaf node class, so their names can never
      # collide with anything. Each reads its class's child fields directly and `yield`s each non-nil child.
      module Dispatch
      end

      # node class => Symbol naming the {Dispatch} method that yields that class's children. Absent for leaf classes
      # and for non-node keys (e.g. `NilClass`), so {each_child} is a no-op on both.
      DISPATCH =
        NODE_CLASSES.each_with_object({}) do |klass, map|
          readers = CHILD_READERS[klass]
          next if readers.equal?(EMPTY)

          method_name = :"yield_children_#{klass.name.gsub('::', '__')}"
          statements = readers.map do |reader, kind|
            if kind == :list
              "node.#{reader}.each { |child| yield child unless child.nil? }"
            else
              "child = node.#{reader}; yield child unless child.nil?"
            end
          end
          # Codegen (not per-call reflection) so iteration reads fields directly — see the class comment on why this
          # beats a `public_send`-per-field loop. For a `CallNode` (one optional-node field per non-nil child) the
          # emitted source is:
          #
          #   def self.yield_children_Prism__CallNode(node)
          #     child = node.receiver; yield child unless child.nil?
          #     child = node.arguments; yield child unless child.nil?
          #     child = node.block; yield child unless child.nil?
          #   end
          Dispatch.module_eval(<<~RUBY, __FILE__, __LINE__ + 1) # rubocop:disable Style/DocumentDynamicEvalDefinition
            def self.#{method_name}(node)
              #{statements.join("\n  ")}
            end
          RUBY
          map[klass] = method_name
        end.freeze

      # Yield each direct child `Prism::Node` of `node` in `compact_child_nodes` order, without allocating an
      # intermediate array. Leaf nodes and non-node input yield nothing. Pure and re-entrant; `break` / `next` /
      # `return` in the block behave exactly as they would with `compact_child_nodes.each`.
      #
      # @yieldparam child [Prism::Node]
      def each_child(node, &)
        method_name = DISPATCH[node.class]
        Dispatch.send(method_name, node, &) if method_name
      end
    end
  end
end
