# frozen_string_literal: true

require_relative "../declaration_walk/rules"

module Rigor
  module Inference
    module ScopeIndexer
      # The scope a census pre-pass types an rvalue under, moved out of `scope_indexer.rb` whole (ADR-116 WD9,
      # #3400): {.census_body_scope}, and {.census_nesting}, the chain that scope answers `Module.nesting` with.
      # Three censuses ask for it, each a module of its own: the class ivar index ({ClassIvarIndex}, at four sites),
      # the class-variable census ({ClassCvarCensus}, at two) and the typed constant walk ({ConstantTables}, which
      # asks for the chain alone too). A fourth, the published-constant ivar census ({PublishedConstantIvars}), types
      # nothing and asks the truthiness guard about an rvalue under the same scope (issue #3437). Both functions are
      # public, because another file calls each.
      #
      # It asks {DeclarationWalk::Rules} for the chain a prefix stands for, calls nothing left in `scope_indexer.rb`
      # and reads none of its constants. `scope_indexer.rb` and the four modules require this file, and it requires
      # none of them back. It requires the file of what it names, so it loads alone and answers there as it does
      # with the indexer loaded.
      module CensusScope
        module_function

        # Issue #681 — the scope a census pre-pass types an rvalue under. The census walks never enter a body
        # through `StatementEvaluator`, so nothing stamped the declaration's `Module.nesting` on the scope they
        # build and `Reflection.lexical_nesting_chain` fell back to peeling `self_type`'s qualified name. That
        # peel cannot tell a compact `class Admin::Census` (nesting `[Admin::Census]`, so a bare `Post` names
        # `::Post`) from the nested spelling (nesting `[Admin::Census, Admin]`, where it names `Admin::Post`),
        # so `@post = Post.new` and `DEFAULT = Post` were recorded under the wrong class and every later read
        # answered it. The prefix these walks already thread IS the chain — `["Admin::Census"]` for the compact
        # form, `["Admin", "Census"]` for the nested one — so the fact was in hand and only the stamp was
        # missing.
        def census_body_scope(default_scope, qualified_prefix, self_type)
          default_scope.with_self_type(self_type)
                       .with_lexical_nesting(census_nesting(default_scope, qualified_prefix))
        end

        # The chain a census walk answers `Module.nesting` with: the one
        # {DeclarationWalk::Rules.scope_entering_declaration} threaded on the scope when a header was entered, and only
        # failing that the prefix-derived approximation below.
        def census_nesting(scope, qualified_prefix)
          scope&.lexical_nesting || DeclarationWalk::Rules.lexical_nesting_for_prefix(qualified_prefix)
        end
      end
    end
  end
end
