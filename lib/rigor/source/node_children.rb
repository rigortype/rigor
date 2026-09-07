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
    # integer-literal leaves) these throwaway arrays are the single largest allocation source in a run — over half
    # of all allocations on mail's `lib`.
    #
    # Loading this file compiles a `#rigor_each_child` method onto every `Prism::*Node` class (additive reopening of
    # a dependency's class, the `Cache::RbsEnvironmentMarshalPatch` precedent; the `rigor_` prefix keeps it
    # collision-free). It yields the same child nodes, in the same order, without materialising the intermediate
    # array: each child-bearing field is read directly in field declaration order — exactly the order
    # `compact_child_nodes` emits — and a `NodeListField`'s already-materialised array is iterated in place (the
    # reader returns the stored array, not a copy). Nil optional children and nil list elements are skipped,
    # mirroring `compact_child_nodes`'s "compact" semantics. Leaf classes compile to an empty method.
    #
    # A method compiled onto the node class is the fastest dispatch available for this shape — one virtual send on
    # the receiver, the same mechanism `compact_child_nodes` itself uses, with zero allocation. The reflective
    # alternatives were measured and rejected: a `public_send`-per-field loop is ~45 % *slower* than
    # `compact_child_nodes` on a full-tree walk (dynamic dispatch per field swamps the allocation win), and a
    # central generated-method table dispatched via `Module#send` + a per-class Hash lookup still regressed
    # Rails-corpus wall ~5 % under YJIT. Walkers therefore call `node.rigor_each_child { … }` directly.
    #
    # The field map is derived once at load from `Prism::Reflection`, so it tracks whatever `prism` version resolves
    # at runtime (ADR-79) instead of a hand-maintained table. `spec/rigor/source/node_children_spec.rb` is the
    # binding contract: over a corpus of real source it asserts — for every node reached — that both
    # `#rigor_each_child` and {each_child} yield output element-for-element identical (object identity and order) to
    # `compact_child_nodes`.
    module NodeChildren
      module_function

      # The concrete `Prism::*Node` classes (`< Prism::Node`).
      NODE_CLASSES =
        Prism.constants.grep(/Node\z/).filter_map do |name|
          const = Prism.const_get(name)
          const if const.is_a?(Class) && const < Prism::Node
        end.freeze

      # Shared frozen empty entry for leaf classes. Identity (`equal?`) distinguishes a leaf entry from a
      # childless-in-practice non-leaf.
      EMPTY = [].freeze

      # node class => frozen Array of `[reader_symbol, :node | :node_optional | :list]` pairs, in field declaration
      # order (the order `compact_child_nodes` emits its children). Leaf classes map to {EMPTY}. This is the source
      # of truth the per-class methods are compiled from, exposed for introspection and the equivalence spec.
      CHILD_READERS =
        NODE_CLASSES.each_with_object({}) do |klass, map|
          pairs = Prism::Reflection.fields_for(klass).filter_map do |field|
            case field
            when Prism::Reflection::OptionalNodeField
              [field.name, :node_optional].freeze
            when Prism::Reflection::NodeField
              [field.name, :node].freeze
            when Prism::Reflection::NodeListField
              [field.name, :list].freeze
            end
          end
          map[klass] = pairs.empty? ? EMPTY : pairs.freeze
        end.freeze

      # The leaf classes — no child-bearing field, so `compact_child_nodes` is always `[]` and `#rigor_each_child`
      # compiles to an empty method. Exposed for the equivalence spec and introspection.
      LEAF_CLASSES = NODE_CLASSES.select { |klass| CHILD_READERS[klass].equal?(EMPTY) }.to_set.freeze

      # Codegen (not per-call reflection) so iteration reads fields directly at hand-written speed — see the module
      # comment for the measurements ruling out the reflective forms. Each statement mirrors `compact_child_nodes`'s
      # own form for that field kind exactly: a required `NodeField` is yielded unconditionally (`compact <<
      # predicate`), an `OptionalNodeField` behind a truthiness guard (`compact << receiver if receiver`), and a
      # `NodeListField`'s stored array is iterated unfiltered (`compact.concat(requireds)`) — no extra nil checks
      # beyond what Prism itself performs. The explicit `self.` receiver keeps a hypothetical future field named
      # `child` from parsing as the just-assigned local. For a `CallNode` (three optional-node fields) the emitted
      # source is:
      #
      #   def rigor_each_child
      #     child = self.receiver
      #     yield child if child
      #     child = self.arguments
      #     yield child if child
      #     child = self.block
      #     yield child if child
      #   end
      NODE_CLASSES.each do |klass|
        statements = CHILD_READERS[klass].map do |reader, kind|
          case kind
          when :list          then "self.#{reader}.each { |child| yield child }"
          when :node_optional then "child = self.#{reader}\n  yield child if child"
          else                     "yield self.#{reader}"
          end
        end
        klass.class_eval(<<~RUBY, __FILE__, __LINE__ + 1) # rubocop:disable Style/DocumentDynamicEvalDefinition
          def rigor_each_child
            #{statements.join("\n  ")}
          end
        RUBY
      end

      # Yield each direct child `Prism::Node` of `node` in `compact_child_nodes` order, without allocating an
      # intermediate array. Nil / non-node input yields nothing (an optional field can be nil, so a caller may pass
      # e.g. `node.body`). Pure and re-entrant; `break` / `next` / `return` in the block behave exactly as they
      # would with `compact_child_nodes.each`. Walkers holding a known `Prism::Node` call `#rigor_each_child`
      # directly; this wrapper is the nil-tolerant entry.
      #
      def each_child(node, &)
        node.rigor_each_child(&) if node.is_a?(Prism::Node)
      end
    end
  end
end
