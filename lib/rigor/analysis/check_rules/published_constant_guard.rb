# frozen_string_literal: true

require "prism"

require_relative "../../source/constant_path"
require_relative "../../source/node_children"

module Rigor
  module Analysis
    module CheckRules
      # Issue #644 — the shared "does this expression's constancy rest on a constant declared in ANOTHER
      # file?" predicate, and the single question the truthiness rule family must ask.
      #
      # The cross-file value-constant table publishes `MODE = :production` project-wide so a reader can
      # dispatch on it, type an argument with it, and see `MODE.upcase` fail. That is the precision the table
      # exists for. What it must NOT do is let a rule *conclude* from the value: `if MODE == :production` in
      # another file folds to `Constant[true]`, and reporting that as `flow.always-truthy-condition` fires on
      # correct code — on the single Ruby idiom whose whole point is a project-wide constant that gets
      # branched on, whose declaration the reader's author never opened. A configuration constant read in ten
      # files would put a warning in all ten.
      #
      # This is [ADR-58](../../../../docs/adr/58-declaration-sourced-ivar-typing.md)'s discipline applied to a
      # different carrier: "a consumer may only ever *withhold* a firing it would otherwise make, so the mark
      # can lose precision but can never manufacture a false positive"
      # (`docs/internal-spec/inference-engine.md` § "Carrier and discipline"). The carrier is deliberately NOT
      # the ADR-58 `Set[[kind, name]]`: that set is flow state, keyed on a *binding* that rebinding drops, and
      # it is already shared by two marks with opposite join policies (ADR-67 WD6b's `:inferred_param` unions
      # where ADR-58's kinds intersect). "Which constants did the project publish, and which does this file
      # declare itself" is ambient, never varies along a flow edge, and so belongs in the
      # `Scope::DiscoveryIndex` — which is exactly ADR-53's membership criterion.
      #
      # `rooted?` is purely syntactic, in the shape of {InferredParamGuard}: it walks a predicate expression
      # down to the roots its constancy could rest on and reports whether any is a published foreign
      # constant. It covers
      #
      # - the bare predicate: `if PAGE_SIZE`, `unless AppConfig::LOG_LEVEL`
      # - a comparison or any method chain on one: `MODE == :production`, `PAGE_SIZE > 100`, `VERSION >= 3`
      # - a constant in ARGUMENT position: `%i[development test].include?(ENV_NAME)` — unlike
      #   {InferredParamGuard}, arguments are walked, because a predicate's fold rests on its arguments just
      #   as much as on its receiver
      # - `&&` / `||` / parentheses / `rescue` composition, and `!`, which Prism spells as a `CallNode`
      # - ONE interprocedural hop into a project predicate method whose body reads such a constant, whatever
      #   spells its owner: `unless production?` (implicit self), `self.prod?`, `AppConfig.production?` (the
      #   idiomatic shape — a configuration module exposing predicates), a lexically relative
      #   `Inner.production?`, and a call chain `KlassConfig.new.production?`. The owner comes from the
      #   receiver's inferred TYPE, so every spelling that names the same module lands on the same table. The
      #   hop is bounded (one level, a node budget) and deliberately coarse: ANY published foreign constant
      #   anywhere in the callee's body declines, rather than a proof that the return value derives from it.
      #   Over-declining withholds a warning; under-declining would emit one. ADR-58's *Non-transitivity*
      #   passage is the precedent for stopping at one hop rather than building a provenance channel through
      #   the return memo.
      #
      # Deliberately NOT covered, and a separate change: a value copied into a local (`m = MODE; m == :x`),
      # into an ivar (`@mode = MODE` in `initialize`), or through a same-file constant alias
      # (`MODE2 = AppConfig::MODE`). Each needs flow provenance — ADR-58's `r = @x` stamping is the shape —
      # rather than a syntactic root walk, and approximating it here is exactly the ad-hoc widening ADR-58's
      # *Non-transitivity* passage forbids. Two hops (`live? -> prod? -> MODE`) also stay uncovered.
      module PublishedConstantGuard
        # A defensive depth cap against a pathological chain (the walk is otherwise linear in chain length).
        MAX_DEPTH = 64

        # A node cap on the one-hop callee-body scan, so a predicate calling a very large method cannot make
        # rule collection quadratic. Exhausting it answers false — the firing direction, and the same
        # conservative default the collector's other gates take when they cannot decide.
        BODY_SCAN_BUDGET = 2000

        module_function

        # @return [Boolean] true when the rule MUST withhold its firing.
        def rooted?(node, scope, depth = 0)
          return false if node.nil? || depth > MAX_DEPTH || scope.nil?

          case node
          when Prism::ConstantReadNode then scope.published_constant?(node.name.to_s)
          when Prism::ConstantPathNode then published_path?(node, scope)
          when Prism::CallNode then rooted_call?(node, scope, depth)
          else rooted_through_composition?(node, scope, depth)
          end
        end

        # `&&` / `||` / `rescue` combine two operands and a parenthesised or multi-statement body yields its
        # last: the produced value is constant only if a rooted operand made it so, so declining on either
        # side is the withholding direction.
        def rooted_through_composition?(node, scope, depth)
          case node
          when Prism::AndNode, Prism::OrNode
            rooted?(node.left, scope, depth + 1) || rooted?(node.right, scope, depth + 1)
          when Prism::RescueModifierNode
            rooted?(node.expression, scope, depth + 1) || rooted?(node.rescue_expression, scope, depth + 1)
          when Prism::ParenthesesNode then rooted?(last_statement(node.body), scope, depth + 1)
          when Prism::StatementsNode then rooted?(node.body.last, scope, depth + 1)
          else false
          end
        end

        # A call is rooted when its receiver is, when any argument is, or when the project method it names
        # reads such a constant (the one interprocedural hop).
        def rooted_call?(node, scope, depth)
          return true if rooted?(node.receiver, scope, depth + 1)
          return true if Array(node.arguments&.arguments).any? { |arg| rooted?(arg, scope, depth + 1) }

          callee_reads_published_constant?(node, scope)
        end

        # The reference AS WRITTEN (`AppConfig::MODE`), so `Scope#published_constant?` can match its local
        # exemption exactly rather than on the last segment. A path that renders no qualified name falls back
        # to its own last segment, which is all there is to ask about.
        def published_path?(node, scope)
          rendered = Source::ConstantPath.qualified_name_or_nil(node) || node.name&.to_s
          !rendered.nil? && scope.published_constant?(rendered)
        end

        # The one hop. Resolves the callee through the ordinary `Scope` accessors (so the ADR-46 recorder sees
        # the read and the caller gains an edge to the callee — the conservative direction) and scans its
        # body. Fails soft to false: a resolution this cannot make is not a reason to withhold.
        def callee_reads_published_constant?(node, scope)
          return false if scope.published_constant_names.empty?

          def_node = resolve_callee(node, scope)
          return false if def_node.nil?

          body_reads_published_constant?(def_node.body, scope)
        rescue StandardError
          false
        end

        # `foo` / `self.foo` resolve against the enclosing self. Every other receiver resolves through its
        # inferred TYPE, never through the name it was spelled with: `Inner.production?` inside `module Outer`
        # is `Outer::Inner`, and keying the table on the bare `Inner` both misses that (a new warning on
        # ordinary code) and, where a top-level `Inner` also exists, reads the WRONG module's methods. That is
        # the defect family #635 fixed in `Narrowing`, so the engine's own resolver answers it rather than a
        # walk reimplemented here. Going through the type also covers a call-chain receiver for free —
        # `KlassConfig.new.production?` types `Nominal[KlassConfig]`, whose instance table is the one to read.
        def resolve_callee(node, scope)
          receiver = node.receiver
          return resolve_self_call(node.name, scope) if receiver.nil? || receiver.is_a?(Prism::SelfNode)

          resolve_typed_receiver_call(receiver, node.name, scope)
        end

        # A `Singleton[X]` receiver names the singleton table (`AppConfig.production?`, a module's own
        # predicates); a `Nominal[X]` receiver names the instance one. Anything else — `Dynamic`, a constant
        # that resolves to no project class — is not a hop this walk can make.
        def resolve_typed_receiver_call(receiver, method_name, scope)
          receiver_type = scope.type_of(receiver)
          case receiver_type
          when Type::Singleton then scope.singleton_def_for(receiver_type.class_name, method_name)
          when Type::Nominal then scope.user_def_for(receiver_type.class_name, method_name)
          end
        end

        # A `Singleton[X]` self (a `def self.…` body) names the singleton table; a `Nominal[X]` self names
        # the instance one; no class at all is the top-level pseudo-class.
        def resolve_self_call(method_name, scope)
          self_type = scope.self_type
          owner = self_type.respond_to?(:class_name) ? self_type.class_name : nil
          return scope.top_level_def_for(method_name) if owner.nil?

          if self_type.is_a?(Type::Singleton)
            scope.singleton_def_for(owner, method_name)
          else
            scope.user_def_for(owner, method_name)
          end
        end

        # An explicit worklist rather than recursion, so the node budget is one loop-carried local instead of
        # a shared mutable cell (the engine value-pins a one-element Array counter and then self-flags the
        # guard's own `negative?` as an always-falsey condition — this rule's own medicine).
        def body_reads_published_constant?(root, scope)
          stack = [root]
          budget = BODY_SCAN_BUDGET
          until stack.empty?
            node = stack.pop
            next unless node.is_a?(Prism::Node)

            budget -= 1
            return false if budget.negative?
            return true if published_constant_node?(node, scope)

            node.rigor_each_child { |child| stack << child }
          end
          false
        end

        def published_constant_node?(node, scope)
          case node
          when Prism::ConstantReadNode then scope.published_constant?(node.name.to_s)
          when Prism::ConstantPathNode then published_path?(node, scope)
          else false
          end
        end

        def last_statement(body)
          body.is_a?(Prism::StatementsNode) ? body.body.last : body
        end
      end
    end
  end
end
