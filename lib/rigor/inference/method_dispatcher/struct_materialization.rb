# frozen_string_literal: true

require "prism"

require_relative "../../type"
require_relative "../../source/constant_path"
require_relative "../../source/node_children"
require_relative "../struct_fold_safety"

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

        # Nodes one factory-body scan may visit before it gives up and refuses. A factory is a handful of
        # nodes; the bound exists so a pathological body cannot turn a per-call-site gate into a walk.
        FACTORY_BODY_SCAN_BUDGET = 200

        # Issue #595 / #525 — the ONE materialisation test. Both places that must answer "was this receiver
        # expression's struct newly built?" go through it: this module's direct member-read gate above, and
        # `ExpressionTyper`'s caller-side `:self`-grant arm. They had forked answers once (the grant arm was
        # tightened for #591 while this one still trusted any chained call), which is exactly how the
        # composed `x.dup_self.with(indent: 9).shout` shape survived — a correctly whitelisted `.with` fold
        # firing off a receiver the other gate should never have called fresh.
        #
        # @param node — the receiver EXPRESSION.
        # @param receiver — the carrier the expression produced.
        def materialization_call?(node, receiver, scope)
          return false unless node.is_a?(Prism::CallNode)

          case node.name
          when :new, :[] then struct_class_expression?(node.receiver, scope)
          when :with then !hand_written_with?(receiver, scope)
          else fresh_factory_call?(node, scope)
          end
        end

        # Issue #599 — the FACTORY-METHOD idiom, the one shape #595's whitelist knowingly paid for as a
        # missed error: `def build = Pair.new("hi", [1, 2])` then `build.items`. The whitelist could not see
        # through `build`, so the chain declined and a typo on it went unreported.
        #
        # It is recovered by asking the callee, under two bounds that keep the answer cheap and fail-closed.
        #
        # 1. RESOLUTION is one table read on a shape whose target cannot be an arbitrary object: a
        #    receiverless send resolved through the confidence-gated top-level def table, or `Const.name`
        #    resolved through the singleton-side ancestor walk. An INSTANCE-side receiver is refused
        #    outright — `x.dup_self` is the #595 bug shape, and what `x` holds at the call is exactly what
        #    this gate has no way to know.
        # 2. ACCEPTANCE is decided on the callee's RETURN POSITION, not on a self-alias scan of its body.
        #    "Cannot return `self`" is not the property freshness needs: the factory's `self` is the module
        #    or `main`, never the struct, while `def get = GLOBAL` over a mutated constant returns a
        #    long-lived instance with no `self` anywhere in it. What the gate needs is that the returned
        #    object was built BY THIS CALL, so the body's tail must itself be a materialisation
        #    ({#fresh_materialization_tail?}) and no `return` may hand back anything else. That subsumes the
        #    self-alias refusal — a body returning `self` has a `SelfNode` tail, not a `.new` — while
        #    admitting the idiom the issue is about.
        def fresh_factory_call?(node, scope)
          return false if scope.nil?

          body = factory_def_body(node, scope)
          return false unless body.is_a?(Prism::StatementsNode)

          fresh_materialization_tail?(body.body.last, scope) && !early_return?(body)
        end

        # The two CHEAPLY RESOLVABLE callee shapes, each a single table read against the frozen discovery
        # index. `bindable_top_level_def_for` is the confidence-gated accessor — the only one the inference
        # may bind through — so a call inside a block whose `self` is unmodelled declines here as it does
        # everywhere else. Anything else, an instance-side receiver above all, resolves to nil.
        def factory_def_body(node, scope)
          def_node =
            case node.receiver
            when nil then scope.bindable_top_level_def_for(node.name)
            when Prism::ConstantReadNode, Prism::ConstantPathNode
              owner = Source::ConstantPath.qualified_name_or_nil(node.receiver)
              owner && scope.singleton_def_through_ancestors(owner, node.name).first
            end
          def_node&.body
        end

        # A materialisation written in the CALLEE's body, judged syntactically. Deliberately narrower than
        # {#struct_class_expression?}: that predicate's local-variable arm reads the binding off the scope it
        # is handed, which is the CALLER's — a local of the same name in the callee body is a different
        # binding entirely, so the arm is dropped rather than answered from the wrong scope.
        def fresh_materialization_tail?(node, scope)
          return false unless node.is_a?(Prism::CallNode)
          return false unless %i[new []].include?(node.name)

          case node.receiver
          when Prism::ConstantReadNode, Prism::ConstantPathNode
            name = Source::ConstantPath.qualified_name_or_nil(node.receiver)
            !name.nil? && !scope.struct_member_layout(name).nil?
          when Prism::CallNode then inline_struct_factory?(node.receiver)
          else false
          end
        end

        # An explicit `return` anywhere in the body hands back an expression the tail check never saw, so the
        # body is refused rather than scanned arm by arm. Nested `def` / `class` / `module` bodies are a
        # different method's returns; a block's `return` is this method's, so the walk descends into it. The
        # visit budget is the fail-closed bound: a body too large to scan is not proven, and unproven is not
        # fresh.
        def early_return?(node, budget = [FACTORY_BODY_SCAN_BUDGET])
          return true if node.is_a?(Prism::ReturnNode)
          return false if Inference::StructFoldSafety.scope_boundary?(node)

          budget[0] -= 1
          return true if budget[0].negative?

          found = false
          node.rigor_each_child { |child| found ||= early_return?(child, budget) }
          found
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
