# frozen_string_literal: true

require "prism"

require_relative "../../type"
require_relative "../../source/constant_path"

module Rigor
  module Inference
    module MethodDispatcher
      # Issue #595 / #525 — the ONE answer to "did this receiver expression just BUILD the struct?", shared by
      # the two gates that must not disagree about it: {StructFolding#fresh_receiver?}, which decides whether a
      # direct member read folds, and `ExpressionTyper`'s caller-side `:self`-grant arm, which decides whether a
      # whole method body may fold its receiverless member reads.
      #
      # They had forked answers once — the grant arm was tightened for #591 while the read gate still trusted
      # any chained call — and that is exactly how the composed `x.dup_self.with(indent: 9).shout` shape
      # survived: a correctly whitelisted `.with` fold firing off a receiver the other gate wrongly called
      # fresh. One implementation is the fix for the class of divergence, not just for that shape — and the
      # module takes NO resolver parameter for the same reason: a lookup each consumer supplies is a fork
      # waiting to happen, so the `.with` guard resolves through `Scope` itself (#598 review).
      #
      # Scope is this module's only entry: `StructFolding` `extend`s it, and since `module_function` copies
      # arrive private through `extend`, the predicate stays callable under this module's own name.
      module StructMaterialization
        module_function

        # Issue #595 / #525 — the ONE materialisation test. Both places that must answer "was this receiver
        # expression's struct newly built?" go through it: this module's direct member-read gate above, and
        # `ExpressionTyper`'s caller-side `:self`-grant arm. They had forked answers once (the grant arm was
        # tightened for #591 while this one still trusted any chained call), which is exactly how the
        # composed `x.dup_self.with(indent: 9).shout` shape survived — a correctly whitelisted `.with` fold
        # firing off a receiver the other gate should never have called fresh.
        #
        #
        # @param node [Prism::Node, nil] the receiver EXPRESSION.
        # @param receiver [Rigor::Type, nil] the carrier the expression produced.
        def materialization_call?(node, receiver, scope)
          return false unless node.is_a?(Prism::CallNode)

          case node.name
          when :new, :[] then struct_class_expression?(node.receiver, scope)
          when :with then !hand_written_with?(receiver, scope)
          else false
          end
        end

        # `.with` copies the receiver into a new instance — unless the struct wrote its own, which is free to
        # return `self` and would reopen the very hole above.
        #
        # An ANONYMOUS carrier cannot have one: a `StructInstance` with no class name came from a blockless
        # `Struct.new(…)` (the block form defers in {fold_struct_new} before any instance exists), and a
        # blockless factory defines nothing but the generated accessors. So it is the NAMED carriers that
        # need the lookup — and a named one with no scope to ask refuses, since unproven is not fresh.
        def hand_written_with?(receiver, scope)
          return true unless receiver.is_a?(Type::StructInstance)

          class_name = receiver.class_name
          return false if class_name.nil?
          return true if scope.nil?

          # The ANCESTOR walk, not the own-class table: a `with` contributed by an included module is just as
          # free to return `self`. Both consumers reach the identical answer because there is one lookup here
          # rather than a parameter each of them supplies (#598 review).
          !scope.user_def_through_ancestors(class_name, :with).first.nil?
        end

        # An expression naming the struct class itself. All three definition forms ADR-48 supports qualify,
        # because each of them really does construct: a constant whose member layout the project side-table
        # recorded (`Point.new(…)`), a local holding a `StructClass` carrier (`c = Struct.new(:x, :y)` then
        # `c.new(…)`), and the inline factory chain (`Struct.new(:x, :y).new(…)`). The local arm reads the
        # binding rather than re-typing the node, so it costs one hash read and cannot re-enter dispatch.
        def struct_class_expression?(node, scope)
          return false if scope.nil?

          case node
          when Prism::ConstantReadNode, Prism::ConstantPathNode
            name = Source::ConstantPath.qualified_name_or_nil(node)
            !name.nil? && !scope.struct_member_layout(name).nil?
          when Prism::LocalVariableReadNode
            scope.local(node.name).is_a?(Type::StructClass)
          when Prism::CallNode
            inline_struct_factory?(node)
          else false
          end
        end

        # `Struct.new(:a, :b)` / `Data.define(:a, :b)` written inline as the receiver of the `.new` that
        # materialises the instance.
        def inline_struct_factory?(node)
          return false unless %i[new define].include?(node.name)

          receiver = node.receiver
          case receiver
          when Prism::ConstantReadNode then %i[Struct Data].include?(receiver.name)
          when Prism::ConstantPathNode then receiver.parent.nil? && %i[Struct Data].include?(receiver.name)
          else false
          end
        end
      end
    end
  end
end
