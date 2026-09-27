# frozen_string_literal: true

require_relative "../declaration_walk/traversal"

module Rigor
  module Inference
    module ScopeIndexer
      # ADR-48's two member-layout tables as one {DeclarationWalk} collector: the ordered members of each
      # `Data.define` class and of each `Struct.new` class (with its `keyword_init:` flag), in both the subclass
      # form (`class Point < Data.define(:x, :y)`) and the constant form (`Point = Data.define(:x, :y)`). The
      # legacy walkers built the two tables in two walks with the same rules; one collector builds both.
      class MemberLayoutsCollector
        include DeclarationWalk::Collector

        # The rules the member-layout walkers answered differently from the walk, kept so both tables stay
        # byte-identical (ADR-116 WD5). Each is a legacy answer, and #1521 tracks converging it:
        #
        # - `factory_block: :ordinary_call` — no bare-factory arm, so a `self::` header in a `Class.new { … }`
        #   block anchors on the enclosing `self` and the block's parameters are walked (#1521 item 8).
        # - `unrendered_header: :skip` — a header that renders no name (a parse error) stops the walk there:
        #   neither its parts nor its body are walked (#1521 item 3).
        VARIANTS = { factory_block: :ordinary_call, unrendered_header: :skip }.freeze

        def initialize
          @data = {}
          @struct = {}
        end

        # A `class Point < Data.define(:x, :y)` header, recorded under the class it names; an unnameable
        # header (`class D` below `class <<` opens `#<Class:C>::D`, which no name spells) records nothing.
        def on_declaration(node, _context, body)
          if node.is_a?(Prism::ClassNode) && !body.singleton_cref
            ScopeIndexer.record_data_member_layout(@data, body.prefix, node.superclass, allow_outer_block: false)
            ScopeIndexer.record_struct_member_layout(@struct, body.prefix, node.superclass, allow_outer_block: false)
          end
          DeclarationWalk::DESCEND
        end

        # A `Point = Data.define(:x, :y)` write, recorded under the class the write names. Below an unnameable
        # cref only a path write still names one.
        def on_constant_write(node, context)
          self_owner = context.self_owner
          unless context.singleton_cref && !ScopeIndexer.meta_new_path_target_nameable?(node, self_owner)
            child_prefix = ScopeIndexer.meta_new_child_prefix(node, context.prefix, self_owner)
          end
          if child_prefix
            rvalue = ScopeIndexer.meta_new_rvalue(node)
            ScopeIndexer.record_data_member_layout(@data, child_prefix, rvalue)
            ScopeIndexer.record_struct_member_layout(@struct, child_prefix, rvalue)
          end
          DeclarationWalk::DESCEND
        end

        # `[data_member_layouts, struct_member_layouts]`, each frozen.
        def tables
          [@data.freeze, @struct.freeze]
        end
      end
    end
  end
end
