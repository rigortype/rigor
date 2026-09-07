# frozen_string_literal: true

require "prism"

require_relative "void_origin"
require_relative "../reflection"
require_relative "../source/node_children"

module Rigor
  module Inference
    # ADR-100 WD4 — the lazy per-`def` "void tail" summary that carries an author-declared `-> void`
    # provenance ACROSS an intermediate method whose own signature declares nothing. The direct case
    # (`x = logger.log(...)`, an RBS `-> void` resolved on the receiver's own class) is recorded at the
    # call site by {MethodDispatcher::RbsDispatch}; this summary answers the transitive case
    # (`def bar; foo; end; b = bar`) where the `void` reaches the use through `bar`'s body, so no rule
    # reading `bar`'s signature can see it.
    #
    # `VoidTail(def_node) -> VoidOrigin | nil`: computed on demand at the first consult, memoised per
    # `def_node` (identity-keyed), cycle-guarded (a def already on the current chain rejects), and
    # **pure** — AST shape + RBS reflection ({Reflection.instance_method_definition} /
    # {Reflection.singleton_method_definition}) + discovery-index lookups ({Scope#user_def_for} /
    # {Scope#singleton_def_for}) only, never expression evaluation. Because it never evaluates, it can
    # neither re-enter the dispatcher nor depend on evaluation order or the fork-pool's file
    # partitioning — the eager record-at-body-evaluation table WD4 rejected failed exactly there.
    #
    # A `def` (resolved on `owner` / `kind`) is admitted iff all four hold:
    #
    #   1. its OWN resolved RBS signature for `(owner, name, kind)` is absent, or every overload
    #      returns `untyped` (`RBS::Types::Bases::Any`). An author-declared concrete return — including
    #      `-> void` itself, which the direct rule already serves at the call site — keeps it out, so
    #      the direct rule and the summary are disjoint by construction (no double record).
    #   2. its body is a plain statements body (no `rescue` / `else` / `ensure` on the `def` — those
    #      shapes make `def_node.body` a `Prism::BeginNode`) containing NO `Prism::ReturnNode` anywhere:
    #      a bare `return` yields `nil`, a non-void path, so the void tail must be the SOLE return path.
    #      The walk is deliberately over-conservative — a `return` inside a nested block also
    #      disqualifies.
    #   3. its tail (last) expression is a `Prism::CallNode` with an implicit-`self` receiver (`nil`
    #      receiver or a literal `self`).
    #   4. that tail resolves on the SAME owner (exact class, no ancestor walk on the discovery side) to
    #      either (a) an RBS definition whose EVERY overload returns `void` — the leaf, whose origin is
    #      `VoidOrigin(owner, tail_name, kind)` — or (b) another discovered `def` of the same kind, which
    #      recurses. Composition (`def baz; bar; end`) is the recursion, and the origin stays the leaf,
    #      so the message still names the author's `-> void` method. The RBS-void-leaf branch is checked
    #      FIRST because under ADR-93 auto-wire the leaf `def` is BOTH RBS-`void` and a discovered `def`;
    #      recursing into its body would miss the leaf.
    #
    # Everything else — explicit-receiver tails, conditional / boolean / `begin` tails, unresolvable
    # names, non-void concrete RBS — rejects.
    #
    # Each tail chain is a functional graph (every `def` has exactly one tail, hence at most one
    # successor), so a `def`'s result is fully determined by its own forward chain and is independent of
    # the entry point: a chain either reaches a void leaf (`VoidOrigin`), a non-admitted node (nil), or a
    # cycle (nil). Memoising is therefore always sound, and the cycle guard only ever rejects a node that
    # is still mid-computation on the current chain (never yet memoised).
    class VoidTailSummary
      # Run-scoped memo, the ADR-84 `return_memo_bucket` house pattern: a single retained slot on
      # `Thread.current` keyed by the run-generation token's identity, so a re-run in one process (LSP,
      # ADR-62 warm loop) lands in a fresh bucket and can neither serve stale entries nor accumulate
      # them. Thread-local ⇒ each fork-pool worker (a separate process) and each Ractor-pool worker (its
      # own Ractor-local `Thread.current`) builds its own bucket; the bucket hash is created and mutated
      # inside the worker and never shared, so no frozen / shared object is mutated and no
      # graceful-degradation branch is needed. `def_node` identity is stable per run (the ADR-85
      # {DefNodeResolver} yields one node object per `(path, node_id)`), the same identity the ADR-84
      # return memo relies on.
      MEMO_KEY = :__rigor_void_tail_summary_memo__
      private_constant :MEMO_KEY

      def initialize(scope)
        @scope = scope
        @environment = scope.environment
      end

      # The recovered `-> void` origin for `def_node` (whose owner / kind the caller resolved through
      # the discovery index), or nil when the `def` is not admitted. A fresh visited set per top-level
      # consult; the memo persists across consults for the run. The memo is probed before the visited
      # set is allocated so the common post-warmup hit path allocates nothing.
      #
      # @rbs owner: String -- The qualified receiver class the `def` belongs to.
      # @rbs kind: :instance | :singleton
      # @rbs return: Inference::VoidOrigin?
      def origin_for(def_node, owner, kind)
        return nil if def_node.nil?

        memo = memo_bucket
        return memo[def_node] if memo.key?(def_node)

        walk(def_node, owner, kind, {}.compare_by_identity)
      end

      private

      attr_reader :scope, :environment

      # Memo + cycle-guarded computation. A def already on the current chain rejects WITHOUT memoising
      # (it is mid-computation; its true result is memoised when its own frame completes).
      def walk(def_node, owner, kind, visited)
        return nil if def_node.nil?
        return nil if visited.key?(def_node)

        memo = memo_bucket
        return memo[def_node] if memo.key?(def_node)

        visited[def_node] = true
        memo[def_node] = compute(def_node, owner, kind, visited)
      end

      def compute(def_node, owner, kind, visited)
        return nil unless own_signature_admits?(owner, def_node.name, kind) # admission 1

        tail = admissible_tail(def_node) # admissions 2 + 3
        return nil if tail.nil?

        resolve_tail(tail.name, owner, kind, visited) # admission 4
      end

      # Admission 1 — absent own signature, or every overload `untyped`. `untyped` is read as "no claim"
      # per RBS's own semantics, so a hand-written `-> untyped` intermediate still admits: the provenance
      # fact (this value was produced by an author-declared `-> void` return) remains true of it.
      def own_signature_admits?(owner, method_name, kind)
        definition = method_definition(owner, method_name, kind)
        return true if definition.nil?

        every_overload_return?(definition, RBS::Types::Bases::Any)
      end

      # Admissions 2 + 3 — the tail expression when the body is a plain statements body with no
      # `ReturnNode` anywhere and the tail is an implicit-self call; nil (reject) otherwise.
      def admissible_tail(def_node)
        body = def_node.body
        return nil if body.nil?
        return nil if body.is_a?(Prism::BeginNode) # def-level rescue / else / ensure
        return nil if contains_return?(body)

        tail = tail_expression(body)
        return nil unless tail.is_a?(Prism::CallNode)
        return nil unless implicit_self_receiver?(tail.receiver)

        tail
      end

      # A `Prism::StatementsNode` (the plain and endless-def shapes both parse to one) tails on its last
      # statement; any other surviving shape is treated as the tail expression itself.
      def tail_expression(body)
        case body
        when Prism::StatementsNode then body.body.last
        else body
        end
      end

      def implicit_self_receiver?(receiver)
        receiver.nil? || receiver.is_a?(Prism::SelfNode)
      end

      # True when a `Prism::ReturnNode` appears anywhere in the subtree — nested blocks and defs
      # included (over-conservative is correct: a method that can return anything other than the void
      # tail must never enter the table).
      def contains_return?(node)
        return false unless node.is_a?(Prism::Node)
        return true if node.is_a?(Prism::ReturnNode)

        node.rigor_each_child { |child| return true if contains_return?(child) }
        false
      end

      # Admission 4 — the void leaf (RBS every-overload `void`) wins over the discovered-def recursion,
      # because under ADR-93 auto-wire the annotated leaf is both.
      def resolve_tail(tail_name, owner, kind, visited)
        definition = method_definition(owner, tail_name, kind)
        if definition && every_overload_return?(definition, RBS::Types::Bases::Void)
          return VoidOrigin.new(class_name: owner, method_name: tail_name, kind: kind)
        end

        next_def = discovered_def(owner, tail_name, kind)
        return nil if next_def.nil?

        walk(next_def, owner, kind, visited)
      end

      def method_definition(owner, method_name, kind)
        if kind == :singleton
          Reflection.singleton_method_definition(owner, method_name, environment: environment)
        else
          Reflection.instance_method_definition(owner, method_name, environment: environment)
        end
      end

      def discovered_def(owner, method_name, kind)
        if kind == :singleton
          scope.singleton_def_for(owner, method_name)
        else
          scope.user_def_for(owner, method_name)
        end
      end

      # True when the definition declares at least one overload and EVERY overload's return type is an
      # instance of `base_klass` (`RBS::Types::Bases::Any` for admission 1, `...::Void` for the leaf).
      # An `UntypedFunction` (`(?) -> T`) still responds to `return_type`, so it is handled the same way.
      def every_overload_return?(definition, base_klass)
        method_types = definition.method_types
        return false if method_types.empty?

        method_types.all? do |method_type|
          fun = method_type.type
          fun.respond_to?(:return_type) && fun.return_type.is_a?(base_klass)
        end
      end

      def memo_bucket
        generation = scope.run_generation || scope.discovered_def_nodes
        slot = Thread.current[MEMO_KEY]
        unless slot && slot[0].equal?(generation)
          slot = [generation, {}.compare_by_identity]
          Thread.current[MEMO_KEY] = slot
        end
        slot[1]
      end
    end
  end
end
