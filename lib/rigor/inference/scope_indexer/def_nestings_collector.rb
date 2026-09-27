# frozen_string_literal: true

require_relative "../declaration_walk/traversal"

module Rigor
  module Inference
    module ScopeIndexer
      # Issue #681's `{Prism::DefNode => Module.nesting}` table as a {DeclarationWalk} collector: the chain every
      # `def` is declared under, keyed by node identity. A top-level `def` records the empty chain (#716); a `def`
      # below a header that renders no name records nothing, because no chain survives it.
      class DefNestingsCollector
        include DeclarationWalk::Collector

        # The rules `walk_def_nestings` answered differently from the walk, kept so the table stays
        # byte-identical (ADR-116 WD5). Each is a legacy answer, and #1521 tracks converging it:
        #
        # - `factory_block: :ordinary_call` — no bare-factory arm, so a `self::` header in a `Class.new { … }`
        #   block anchors on the enclosing `self` and the block's parameters are walked (#1521 item 8).
        # - `lexical_prefix: :nesting_head` — the walker threads no qualified prefix; its meta-new and eval
        #   splits resolve against `nesting.first` split into segments, which differs from the walk's prefix
        #   below a compact header and below an unnameable cref (#1521 item 1).
        # - `unrendered_header: :body_with_lost_nesting` — a header that renders no name (a parse error) walks
        #   its body alone, with the chain lost unless an unnameable cref encloses it (#1521 item 3).
        VARIANTS = {
          factory_block: :ordinary_call,
          lexical_prefix: :nesting_head,
          unrendered_header: :body_with_lost_nesting
        }.freeze

        def initialize
          @table = {}.compare_by_identity
        end

        # Nothing below a `def` declares a class or module, so the walk goes no further in for this table.
        def on_def(node, context)
          nesting = context.nesting
          @table[node] = nesting unless nesting.nil?
          DeclarationWalk::DECLINE
        end

        def table
          @table.freeze
        end
      end
    end
  end
end
