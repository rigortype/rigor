# frozen_string_literal: true

require_relative "../../source/constant_path"

module Rigor
  module Inference
    module DeclarationWalk
      # What `self`, the cref and `Module.nesting` are at one node of a {DeclarationWalk} (ADR-116 WD5). The walk
      # derives each child's context from its parent's through the transitions below, so every collector reads
      # the same answer for the same node and none of them recomputes it.
      #
      # - `prefix` — the lexical cref as qualified-name segments: `["Admin", "User"]` inside `module Admin;
      #   class User`, and `[]` at the top level and under an unnameable cref (a bare header inside `class <<`
      #   opens `#<Class:C>::D`, which no name spells).
      # - `self_owner` — the rebound `self` a `self::` header, write target or eval receiver anchors on. nil
      #   while `self` is the lexical class; a prefix while a meta-new or eval-family block rebinds it; `[]`
      #   while it names nothing (a `class <<` body, an anonymous factory block, an eval receiver no name
      #   reaches).
      # - `singleton_cref` — whether the lexical cref is unnameable. `class <<` sets it, and a header that
      #   still names its class re-anchors it.
      # - `nesting` — `Module.nesting` as the ancestry tables record it (issue #682): a nameable
      #   `class`/`module` keyword pushes, a `self::` header pushes the prefix its rebound self gives it, and
      #   nothing else pushes. nil when the caller does not track it, and then no transition allocates one.
      # - `scope` — the census scope a collector types an rvalue under, carrying the chain
      #   {ScopeIndexer.scope_entering_declaration} stamps at each header. nil when the caller has none.
      #
      # Nameability is derived, not stored: {#unnameable_self?} answers it from the fields above.
      #
      # `nesting` and the chain on `scope` are two fields because the walks that threaded them disagree. The
      # scope's chain is pushed at EVERY header, an unnameable one and the lenient render of a `self::` header
      # included (`class self::D` pushes `Outer::D`); the ancestry chain is not. A move keeps both answers.
      #
      # The rules themselves stay in {ScopeIndexer} ({ScopeIndexer.decl_body_context},
      # {ScopeIndexer.meta_new_block_split}, {ScopeIndexer.eval_block_split}), where the walkers not yet ported
      # still call them; this class is the one place a ported collector reaches them from.
      class Context
        EMPTY_PREFIX = [].freeze

        attr_reader :prefix, :self_owner, :singleton_cref, :nesting, :scope

        # A file's top level: `self` is `main`, which the lexical-class convention (a nil `self_owner`)
        # already answers.
        def self.root(scope: nil, nesting: nil)
          new(EMPTY_PREFIX, nil, false, nesting, scope)
        end

        def initialize(prefix, self_owner, singleton_cref, nesting, scope)
          @prefix = prefix
          @self_owner = self_owner
          @singleton_cref = singleton_cref
          @nesting = nesting
          @scope = scope
          freeze
        end

        # Whether a bare, `self` or `self::` reference here names nothing a table can key on: inside a
        # `class <<` body, under a `self` an eval or factory block left unnamed, or below an unnameable cref
        # that no rebound self re-anchors.
        def unnameable_self?
          ScopeIndexer.unnameable_eval_self?(false, self_owner, prefix, singleton_cref)
        end

        # The context a `class` / `module` header gives its body, or nil when the header renders no prefix
        # (a parsed header always renders one; nil keeps the transition total). `self` is the class again,
        # so the rebound self resets.
        def declaration_body(node)
          self_decl, child_prefix, child_cref =
            ScopeIndexer.decl_body_context(node, prefix, self_owner, singleton_cref)
          return nil unless child_prefix

          Context.new(child_cref ? EMPTY_PREFIX : child_prefix, nil, child_cref,
                      declaration_nesting(node, self_decl, child_cref),
                      ScopeIndexer.scope_entering_declaration(scope, node.constant_path))
        end

        # The context of a `class << expr` body. `self` is the singleton class, which no `self::` path names,
        # and the cref is unnameable until a nameable header re-anchors it. The rung Ruby pushes names nothing,
        # so neither chain moves.
        def singleton_class_body
          Context.new(prefix, EMPTY_PREFIX, true, nesting, scope)
        end

        # The context of a block that rebinds only `self` — a meta-new write's, an anonymous factory's
        # (`EMPTY_PREFIX`), an eval-family call's. The cref and both chains stay lexical.
        def rebound(owner)
          Context.new(prefix, owner, singleton_cref, nesting, scope)
        end

        # `[enclosing_parts, body, body_self]` for a `K = Class.new { … }`-shaped write, or nil when its
        # rvalue is not the idiom ({ScopeIndexer.meta_new_block_split}).
        def meta_new_split(node)
          ScopeIndexer.meta_new_block_split(node, prefix, self_owner, singleton_cref)
        end

        # `[enclosing_parts, body, eval_self]` for an eval-family call with a block, or nil
        # ({ScopeIndexer.eval_block_split}).
        def eval_split(node)
          ScopeIndexer.eval_block_split(node, prefix, self_owner, singleton_cref)
        end

        private

        def declaration_nesting(node, self_decl, child_cref)
          return nesting if nesting.nil? || child_cref
          return [self_decl.join("::"), *nesting].freeze if self_decl

          Source::ConstantPath.pushed_nesting(nesting, node.constant_path) || nesting
        end
      end
    end
  end
end
