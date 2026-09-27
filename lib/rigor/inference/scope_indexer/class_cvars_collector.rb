# frozen_string_literal: true

require_relative "../declaration_walk/traversal"

module Rigor
  module Inference
    module ScopeIndexer
      # The `class_cvars` discovery table (slice 7 phase 6) as a {DeclarationWalk} collector: every
      # `@@x = …` a `def` body writes, typed under the census scope and unioned per class. Ruby cvars are
      # shared by the instance and singleton facets, so every `def` counts, `def self.x` included.
      class ClassCvarsCollector
        include DeclarationWalk::Collector

        def initialize
          @table = {}
        end

        # `@@x` in a `def` resolves through the LEXICAL cref: `Module.nesting` is the same inside a meta-new or
        # eval block, so the context's `prefix` keys the write and its rebound `self` never does —
        # `K = Class.new { def m = @@x }` inside `class C` writes `C::@@x`. The walk goes no further in: the
        # gather reads the body with `def`, `class` and `module` as barriers, and nothing below a `def` reaches
        # this table.
        def on_def(node, context)
          ScopeIndexer.collect_def_cvar_writes(node, context.prefix, context.scope, @table)
          DeclarationWalk::DECLINE
        end

        # The table as the discovery index holds it: each class's entry frozen, then the whole.
        def table
          @table.transform_values(&:freeze).freeze
        end
      end
    end
  end
end
