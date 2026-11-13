# frozen_string_literal: true

require_relative "../declaration_walk/traversal"

module Rigor
  module Inference
    module ScopeIndexer
      # The `class_cvars` discovery table (slice 7 phase 6) as a {DeclarationWalk} collector: every
      # `@@x = …` a `def` body writes, typed under the census scope and unioned per class, joined by what a
      # `class` / `module` body writes to the same cvar. Ruby cvars are shared by the instance and singleton
      # facets, so every `def` counts, `def self.x` included.
      class ClassCvarsCollector
        include DeclarationWalk::Collector

        def initialize
          @table = {}
        end

        # Issue #3204 — a `class` / `module` body's own writes, outside its `def`s, under the body's context;
        # each only joins an entry a `def` body's write creates. An unnameable cref (a header below
        # `class << expr`) leaves the prefix empty, and the gather skips it.
        def on_declaration(node, _context, body)
          ScopeIndexer.collect_body_cvar_writes(node.body, body.prefix, body.scope, @table)
          DeclarationWalk::DESCEND
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

        # The table as the discovery index holds it ({ScopeIndexer#finished_cvar_census}).
        def table = ScopeIndexer.finished_cvar_census(@table)
      end
    end
  end
end
