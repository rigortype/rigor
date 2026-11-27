# frozen_string_literal: true

require "prism"

require_relative "../../analysis/check_rules/published_constant_guard"
require_relative "../../source/node_children"
require_relative "../../type"
require_relative "../declaration_walk/rules"
require_relative "census_scope"

module Rigor
  module Inference
    module ScopeIndexer
      # The #667 census of the instance variables seeded from a published constant, moved out of
      # `scope_indexer.rb` whole (ADR-116 WD9, U3). {.seed_published_constant_ivars} walks one file and puts the
      # table on the discovery index of the scope it is handed; every other function here is an arm or a step of
      # that walk. It asks {DeclarationWalk::Rules} for each declaration context and calls nothing left in
      # `scope_indexer.rb`, which requires this file; this file does not require it back and reads none of the
      # indexer's constants.
      module PublishedConstantIvars
        module_function

        # Issue #667 — `{class name => Set[ivar name]}` for an ivar whose class-ivar seed is a copy of a
        # foreign published constant (`@mode = AppConfig::MODE` in `initialize`). The cross-method half of the
        # copy provenance: the write and the `@mode == :production` that reads it sit in different method
        # bodies, so no flow edge connects them and the fact has to be censused per class, exactly as the
        # ADR-58 nil seed it rides beside is. Runs only when the project published something.
        def seed_published_constant_ivars(seeded_scope, root)
          return seeded_scope if seeded_scope.published_constant_names.empty?

          table = {}
          walk_published_constant_ivars(root, [], seeded_scope, table)
          return seeded_scope if table.empty?

          seeded_scope.with_discovery(
            seeded_scope.discovery.with(published_constant_ivars: table.transform_values(&:freeze).freeze)
          )
        end

        # `def_owner` names the class a `def` leaf's ivar writes belong to when `self` is
        # rebound — see {ClassIvarIndex.walk_class_ivars}; `[]` marks a self no name covers.
        def walk_published_constant_ivars(node, qualified_prefix, scope, table, def_owner: nil,
                                          singleton_cref: false)
          return unless node.is_a?(Prism::Node)

          case node
          when Prism::ClassNode, Prism::ModuleNode
            return if walk_published_ivar_declaration?(node, qualified_prefix, scope, table,
                                                       def_owner, singleton_cref)
          when Prism::SingletonClassNode
            # The expression evaluates in the enclosing cref; the body's cref is unnameable.
            return walk_singleton_published_ivars(node, qualified_prefix, scope, table,
                                                  def_owner, singleton_cref)
          when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode,
               Prism::ConstantOrWriteNode, Prism::ConstantPathOrWriteNode
            return if walk_published_ivar_meta_new?(node, qualified_prefix, scope, table,
                                                    def_owner, singleton_cref)
          when Prism::CallNode
            return if walk_published_ivar_eval_call?(node, qualified_prefix, scope, table,
                                                     def_owner, singleton_cref)
          else
            return if walk_published_ivar_leaf?(node, qualified_prefix, scope, table, def_owner)
          end

          node.rigor_each_child do |child|
            walk_published_constant_ivars(child, qualified_prefix, scope, table,
                                          def_owner: def_owner, singleton_cref: singleton_cref)
          end
        end

        # The remaining leaf arms of {#walk_published_constant_ivars}: a `def self.…` body writes the
        # singleton's ivars, which take no instance seed at all; an ivar write seeds the owner row.
        # Returns true when the node was consumed and its children must not be walked.
        def walk_published_ivar_leaf?(node, qualified_prefix, scope, table, def_owner)
          return !node.receiver.nil? if node.is_a?(Prism::DefNode)
          return false unless node.is_a?(Prism::InstanceVariableWriteNode)

          record_published_constant_ivar(node, def_owner || qualified_prefix, rvalue_scope(scope, qualified_prefix),
                                         table)
          true
        end

        # The `K = Class.new { … }` arm of {#walk_published_constant_ivars}: the block's `def`
        # ivar writes belong to the class the write names; its declarations stay lexical.
        def walk_published_ivar_meta_new?(node, qualified_prefix, scope, table, def_owner,
                                          singleton_cref)
          split = DeclarationWalk::Rules.meta_new_block_split(node, qualified_prefix, def_owner, singleton_cref)
          return false unless split

          enclosing, body, body_self = split
          enclosing.each do |part|
            walk_published_constant_ivars(part, qualified_prefix, scope, table,
                                          def_owner: def_owner, singleton_cref: singleton_cref)
          end
          if body
            walk_published_constant_ivars(body, qualified_prefix, scope, table,
                                          def_owner: body_self, singleton_cref: singleton_cref)
          end
          true
        end

        # The eval-family arm of {#walk_published_constant_ivars}: the receiver's `self` anchors
        # `self::` declarations and owns the block's class-body-level `@x` seeds the way the
        # enclosing class owns this body's.
        def walk_published_ivar_eval_call?(node, qualified_prefix, scope, table, def_owner,
                                           singleton_cref)
          split = DeclarationWalk::Rules.eval_block_split(node, qualified_prefix, def_owner, singleton_cref)
          return false unless split

          enclosing, body, body_self = split
          enclosing.each do |part|
            walk_published_constant_ivars(part, qualified_prefix, scope, table,
                                          def_owner: def_owner, singleton_cref: singleton_cref)
          end
          if body
            walk_published_constant_ivars(body, qualified_prefix, scope, table,
                                          def_owner: body_self, singleton_cref: singleton_cref)
          end
          true
        end

        # The class/module arm of {#walk_published_constant_ivars}: under an unnameable
        # cref a bare/`self::` header opens `#<singleton>::Name` — ownerless; nameable
        # headers re-anchor at a real cref.
        def walk_published_ivar_declaration?(node, qualified_prefix, scope, table,
                                             def_owner, singleton_cref)
          ctx = DeclarationWalk::Rules.decl_body_context(node, qualified_prefix, def_owner, singleton_cref)
          return false unless ctx

          _self_decl, child_prefix, child_cref = ctx
          return true unless node.body

          walk_published_constant_ivars(node.body, child_cref ? [] : child_prefix, scope, table,
                                        singleton_cref: child_cref)
          true
        end

        def walk_singleton_published_ivars(node, qualified_prefix, scope, table, def_owner,
                                           singleton_cref)
          walk_published_constant_ivars(node.expression, qualified_prefix, scope, table,
                                        def_owner: def_owner, singleton_cref: singleton_cref)
          return unless node.body

          # `def` below `class <<` defines singleton methods — their `@x` writes are the
          # class object's own ivars, not instance-ivar seeds — so the body walks ownerless.
          walk_published_constant_ivars(node.body, qualified_prefix, scope, table,
                                        def_owner: [], singleton_cref: true)
        end

        # Issue #3437 — the scope the guard is asked under: the write's lexical cref, which is the walk's prefix and
        # not the `def_owner` a rebound `self` credits the ivar to. `Scope#published_constant?` matches a file's own
        # constant by the names a reference resolves to where it is written, so a scope with no `Module.nesting`
        # would read every `@mode = MODE` as the top-level `MODE`. It is {CensusScope.census_body_scope}, the scope
        # {ClassIvarIndex} typed the same rvalue under.
        def rvalue_scope(scope, qualified_prefix)
          return scope if qualified_prefix.empty?

          CensusScope.census_body_scope(scope, qualified_prefix,
                                        Type::Combinator.nominal_of(qualified_prefix.join("::")))
        end

        # The class-ivar accumulator (already seeded when this runs) is the pre-gate: an ivar whose seed is not
        # a `Type::Constant` can never fold a predicate, so there is nothing for the mark to withhold and the
        # guard's one interprocedural hop is not worth paying for it.
        def record_published_constant_ivar(node, qualified_prefix, scope, table)
          return if qualified_prefix.empty?

          class_name = qualified_prefix.join("::")
          return unless scope.class_ivars_for(class_name)[node.name].is_a?(Type::Constant)
          return unless Analysis::CheckRules::PublishedConstantGuard.rooted?(node.value, scope)

          (table[class_name] ||= Set.new) << node.name
        end

        private_class_method :walk_published_constant_ivars, :walk_published_ivar_leaf?, :walk_published_ivar_meta_new?,
                             :walk_published_ivar_eval_call?, :walk_published_ivar_declaration?,
                             :walk_singleton_published_ivars, :record_published_constant_ivar, :rvalue_scope
      end
    end
  end
end
