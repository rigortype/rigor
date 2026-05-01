# frozen_string_literal: true

require "prism"

require_relative "../type"
require_relative "../analysis/fact_store"
require_relative "../source/node_walker"
require_relative "block_parameter_binder"
require_relative "closure_escape_analyzer"
require_relative "method_dispatcher"
require_relative "method_parameter_binder"
require_relative "multi_target_binder"
require_relative "narrowing"

module Rigor
  module Inference
    # Statement-level evaluator that complements `Rigor::Inference::ExpressionTyper`
    # by threading an immutable {Rigor::Scope} through control-flow constructs.
    # The output is the pair `[Rigor::Type, Rigor::Scope]`: the type that the
    # evaluated node produces, and the scope that callers should observe
    # AFTER the node has run.
    #
    # Slice 3 phase 2 ships the evaluator surface and the scope-threading
    # rules for the canonical statement-y nodes:
    #
    # - sequential evaluation across `Prism::StatementsNode`/`ProgramNode`,
    # - local-variable assignment (`Prism::LocalVariableWriteNode`) binding
    #   the rvalue's type into the post-scope,
    # - branching constructs (`IfNode`, `UnlessNode`, `CaseNode`,
    #   `CaseMatchNode`, `BeginNode`/`RescueNode`/`EnsureNode`,
    #   `WhileNode`/`UntilNode`, `AndNode`/`OrNode`) that evaluate each
    #   branch under a forked scope and merge the results with
    #   nil-injection on half-bound names,
    # - pass-through helpers for `ParenthesesNode`, `ElseNode`,
    #   `WhenNode`/`InNode`, and `RescueNode`.
    #
    # Anything outside the catalogue defers to `Rigor::Scope#type_of` and
    # returns the receiver scope unchanged. This matches the Slice 1
    # fail-soft policy: an unrecognised statement-level node MUST NOT
    # raise and MUST keep the scope intact.
    #
    # The class is stateful (`@scope`, `@tracer`) but every public call
    # returns fresh values; the receiver scope MUST never be mutated.
    # Recursive evaluation always allocates a new instance with the
    # forked scope so different branches stay isolated.
    #
    # See docs/internal-spec/inference-engine.md for the public contract
    # and docs/adr/4-type-inference-engine.md for the slice rationale.
    # rubocop:disable Metrics/ClassLength
    class StatementEvaluator
      # Hash-based dispatch keeps `evaluate` linear and lets future slices
      # add control-flow node kinds without growing a single case
      # statement past RuboCop's cyclomatic budget. Anonymous Prism
      # subclasses are not expected.
      HANDLERS = {
        Prism::StatementsNode => :eval_statements,
        Prism::ProgramNode => :eval_program,
        Prism::LocalVariableWriteNode => :eval_local_write,
        Prism::InstanceVariableWriteNode => :eval_ivar_write,
        Prism::ClassVariableWriteNode => :eval_cvar_write,
        Prism::GlobalVariableWriteNode => :eval_global_write,
        Prism::MultiWriteNode => :eval_multi_write,
        Prism::IfNode => :eval_if,
        Prism::UnlessNode => :eval_unless,
        Prism::ElseNode => :eval_else,
        Prism::CaseNode => :eval_case,
        Prism::CaseMatchNode => :eval_case,
        Prism::WhenNode => :eval_when_or_in,
        Prism::InNode => :eval_when_or_in,
        Prism::BeginNode => :eval_begin,
        Prism::RescueNode => :eval_rescue,
        Prism::EnsureNode => :eval_ensure,
        Prism::WhileNode => :eval_loop,
        Prism::UntilNode => :eval_loop,
        Prism::AndNode => :eval_and_or,
        Prism::OrNode => :eval_and_or,
        Prism::ParenthesesNode => :eval_parentheses,
        Prism::DefNode => :eval_def,
        Prism::ClassNode => :eval_class_or_module,
        Prism::ModuleNode => :eval_class_or_module,
        Prism::SingletonClassNode => :eval_singleton_class,
        Prism::CallNode => :eval_call,
        Prism::BlockNode => :eval_block
      }.freeze
      private_constant :HANDLERS

      # Lexical class frame: the `name:` field is the qualified class
      # name as it would render in Ruby (e.g., `"Foo::Bar"`); the
      # `singleton:` field is `true` for `class << self` frames so
      # nested defs resolve to singleton-method RBS lookups.
      ClassFrame = Data.define(:name, :singleton)

      # @param scope [Rigor::Scope]
      # @param tracer [Rigor::Inference::FallbackTracer, nil]
      # @param on_enter [#call, nil] optional `(node, scope) ->` callable
      #   invoked once at the start of every {#evaluate} call (the node
      #   itself, *before* its handler runs). Threaded through every
      #   recursive `sub_eval` so the tooling that builds a per-node
      #   scope index (`Rigor::Inference::ScopeIndexer`) can record the
      #   entry scope for every Prism node the evaluator visits without
      #   the StatementEvaluator carrying any additional state itself.
      # @param class_context [Array<ClassFrame>] lexical class scope used
      #   by {#eval_def} to look up the method's RBS signature. Each
      #   `ClassNode`/`ModuleNode` entry pushes a frame; `SingletonClassNode`
      #   over `self` flips the innermost frame to singleton mode.
      def initialize(scope:, tracer: nil, on_enter: nil, class_context: [].freeze)
        @scope = scope
        @tracer = tracer
        @on_enter = on_enter
        @class_context = class_context.freeze
      end

      # Evaluate `node` under the receiver scope. Returns `[type, scope']`
      # where `type` is the value the node produces and `scope'` is the
      # scope observable after the node has run. The receiver scope is
      # never mutated.
      #
      # @param node [Prism::Node]
      # @return [Array(Rigor::Type, Rigor::Scope)]
      def evaluate(node)
        @on_enter&.call(node, @scope)

        handler = HANDLERS[node.class]
        return send(handler, node) if handler

        # Default: the node is treated as a pure expression. Type it
        # through the existing expression typer (which observes the
        # current scope's locals) and leave the scope unchanged.
        [@scope.type_of(node, tracer: @tracer), @scope]
      end

      private

      attr_reader :scope, :tracer

      # Thread the scope through every child statement in declaration
      # order. The body's value is the type of the last statement (or
      # `Constant[nil]` for an empty body); intermediate statements'
      # types are discarded, but their scope effects are preserved.
      def eval_statements(node)
        result_type = Type::Combinator.constant_of(nil)
        current = scope
        node.body.each do |stmt|
          result_type, current = sub_eval(stmt, current)
        end
        [result_type, current]
      end

      def eval_program(node)
        return [Type::Combinator.constant_of(nil), scope] if node.statements.nil?

        sub_eval(node.statements, scope)
      end

      # `name = rvalue` evaluates the rvalue under the entry scope (so
      # earlier assignments in a chained `a = b = expr` propagate
      # left-to-right) and binds `name` to the result type. Compound
      # assignment forms (`+=` etc.) are deferred to a follow-up; for
      # now they degrade to "type the rhs, do not rebind" via the
      # default branch in {#evaluate}.
      def eval_local_write(node)
        rhs_type, post_rhs = sub_eval(node.value, scope)
        [rhs_type, post_rhs.with_local(node.name, rhs_type)]
      end

      # Slice 7 phase 1 — instance/class/global variable
      # writes. Each handler evaluates the rvalue under the
      # entry scope and binds the named variable into the
      # post-scope's per-kind binding map. The expression value
      # is the rvalue type, matching Ruby's semantics. Bindings
      # are method-local: a fresh scope is built at every `def`
      # entry through `build_method_entry_scope`, so writes do
      # not leak across method boundaries until cross-method
      # ivar/cvar tracking lands.
      def eval_ivar_write(node)
        rhs_type, post_rhs = sub_eval(node.value, scope)
        [rhs_type, post_rhs.with_ivar(node.name, rhs_type)]
      end

      def eval_cvar_write(node)
        rhs_type, post_rhs = sub_eval(node.value, scope)
        [rhs_type, post_rhs.with_cvar(node.name, rhs_type)]
      end

      def eval_global_write(node)
        rhs_type, post_rhs = sub_eval(node.value, scope)
        [rhs_type, post_rhs.with_global(node.name, rhs_type)]
      end

      # `a, b = rhs` — Slice 5 phase 2 sub-phase 2 destructuring.
      # Evaluates the right-hand side under the entry scope, then
      # decomposes its type against the multi-write target tree
      # (Prism::MultiWriteNode#lefts/rest/rights, including nested
      # Prism::MultiTargetNode for the `(b, c)` form). Tuple-shaped
      # right-hand sides produce per-slot types element-wise; other
      # carriers fall back to `Dynamic[Top]` per slot. The expression
      # value is the right-hand side type (matching Ruby's semantics:
      # `(a, b = [1, 2])` evaluates to `[1, 2]`).
      def eval_multi_write(node)
        rhs_type, post_rhs = sub_eval(node.value, scope)
        bindings = MultiTargetBinder.bind(node, rhs_type)
        post = bindings.reduce(post_rhs) { |acc, (name, type)| acc.with_local(name, type) }
        [rhs_type, post]
      end

      # `if pred; t; (elsif/else)?` runs the predicate first (its
      # post-scope is shared by both branches), then asks
      # `Rigor::Inference::Narrowing` for the truthy and falsey edge
      # scopes derived from the predicate. Slice 6 phase 1 narrows
      # local-variable bindings on truthiness, `nil?`, `!`, and `&&`/
      # `||` predicate composition; predicates the analyser does not
      # specialise return the post-predicate scope unchanged on both
      # edges, preserving the Slice 3 phase 2 behaviour. The branches'
      # result types are unioned; their post-scopes are joined with
      # nil-injection on half-bound names so a name set in one branch
      # but not the other is observable as `T | nil` after the if.
      def eval_if(node)
        _pred_type, post_pred = sub_eval(node.predicate, scope)
        truthy_scope, falsey_scope = Narrowing.predicate_scopes(node.predicate, post_pred)
        then_type, then_scope = eval_branch_or_nil(node.statements, truthy_scope)
        else_type, else_scope = eval_branch_or_nil(node.subsequent, falsey_scope)
        [
          Type::Combinator.union(then_type, else_type),
          join_with_nil_injection(then_scope, else_scope)
        ]
      end

      # `unless pred; t; else; e; end`. Same shape as `if`, but Prism
      # exposes the else-branch as `else_clause` (no elsif chain). The
      # narrower's truthy/falsey edges are routed in swapped form
      # because `unless` runs its body when the predicate is falsey.
      def eval_unless(node)
        _pred_type, post_pred = sub_eval(node.predicate, scope)
        truthy_scope, falsey_scope = Narrowing.predicate_scopes(node.predicate, post_pred)
        then_type, then_scope = eval_branch_or_nil(node.statements, falsey_scope)
        else_type, else_scope = eval_branch_or_nil(node.else_clause, truthy_scope)
        [
          Type::Combinator.union(then_type, else_type),
          join_with_nil_injection(then_scope, else_scope)
        ]
      end

      def eval_else(node)
        return [Type::Combinator.constant_of(nil), scope] if node.statements.nil?

        sub_eval(node.statements, scope)
      end

      # `case pred; when ...; when ...; else; end` and the pattern-
      # matching variant. The predicate's post-scope is shared with
      # every branch (including the else); branches are evaluated
      # independently and merged with nil-injection so half-bound
      # names degrade to `T | nil`.
      def eval_case(node)
        post_pred = node.predicate ? sub_eval(node.predicate, scope).last : scope

        branch_results = node.conditions.map { |branch| sub_eval(branch, post_pred) }
        else_result =
          if node.else_clause
            sub_eval(node.else_clause, post_pred)
          else
            [Type::Combinator.constant_of(nil), post_pred]
          end

        all_results = [*branch_results, else_result]
        types = all_results.map(&:first)
        scopes = all_results.map(&:last)
        [
          Type::Combinator.union(*types),
          reduce_scopes_with_nil_injection(scopes)
        ]
      end

      def eval_when_or_in(node)
        return [Type::Combinator.constant_of(nil), scope] if node.statements.nil?

        sub_eval(node.statements, scope)
      end

      # `begin; body; rescue ...; else; ensure; end`. The body and the
      # rescue chain are alternative exit paths whose scopes are joined
      # with nil-injection. The else-clause replaces the body's value
      # when present (matching Ruby semantics: else runs only if the
      # body raises no exception). The ensure-clause runs but does not
      # contribute to the value; its scope effects are layered on the
      # joined exit scope so locals bound exclusively in `ensure` stay
      # observable.
      def eval_begin(node)
        primary_type, primary_scope = eval_begin_primary(node)
        rescue_chain = collect_rescue_chain_results(node.rescue_clause, scope)

        if rescue_chain.empty?
          exit_type = primary_type
          exit_scope = primary_scope
        else
          exit_type = Type::Combinator.union(primary_type, *rescue_chain.map(&:first))
          exit_scope = reduce_scopes_with_nil_injection([primary_scope, *rescue_chain.map(&:last)])
        end

        if node.ensure_clause
          _ensure_type, ensure_scope = sub_eval(node.ensure_clause, exit_scope)
          exit_scope = ensure_scope
        end

        [exit_type, exit_scope]
      end

      # `BeginNode#statements` is the primary body; when an else-clause
      # is present, its value replaces the body's per Ruby semantics
      # (the else runs only when no exception was raised), but the
      # body's scope effects still apply because the body did run
      # before the else.
      def eval_begin_primary(node)
        body_type, body_scope =
          if node.statements
            sub_eval(node.statements, scope)
          else
            [Type::Combinator.constant_of(nil), scope]
          end

        if node.else_clause
          else_type, else_scope = sub_eval(node.else_clause, body_scope)
          [else_type, else_scope]
        else
          [body_type, body_scope]
        end
      end

      def collect_rescue_chain_results(rescue_node, entry_scope)
        results = []
        current = rescue_node
        while current
          results << eval_branch_or_nil(current.statements, entry_scope)
          current = current.subsequent
        end
        results
      end

      def eval_rescue(node)
        eval_branch_or_nil(node.statements, scope)
      end

      def eval_ensure(node)
        eval_branch_or_nil(node.statements, scope)
      end

      # `while pred; body; end` / `until pred; body; end`. The body
      # might run zero or more times, so half-bound names degrade to
      # `T | nil` in the post-loop scope. The loop expression itself
      # types as `Constant[nil]` (Slice 3 phase 1), reflecting the
      # common case where no `break VALUE` is observed.
      def eval_loop(node)
        _pred_type, post_pred = sub_eval(node.predicate, scope)
        return [Type::Combinator.constant_of(nil), post_pred] if node.statements.nil?

        _body_type, body_scope = sub_eval(node.statements, post_pred)
        [
          Type::Combinator.constant_of(nil),
          join_with_nil_injection(post_pred, body_scope)
        ]
      end

      # `a && b` / `a || b`. The LHS always runs, the RHS only
      # sometimes runs. Slice 6 phase 1 narrows the RHS evaluation:
      # `a && b` evaluates `b` under the truthy edge of `a`, and
      # `a || b` evaluates `b` under the falsey edge of `a`. The
      # narrowed RHS post-scope is joined with the LHS post-scope
      # (RHS skipped) using nil-injection so half-bound names from
      # the RHS still degrade to `T | nil`. The result type is
      # edge-aware: `a && b` can only produce the falsey fragment of
      # `a` when the RHS is skipped, while `a || b` can only produce
      # the truthy fragment of `a` when the RHS is skipped.
      def eval_and_or(node)
        left_type, left_scope = sub_eval(node.left, scope)
        truthy_left, falsey_left = Narrowing.predicate_scopes(node.left, left_scope)
        rhs_entry = node.is_a?(Prism::AndNode) ? truthy_left : falsey_left
        right_type, right_scope = sub_eval(node.right, rhs_entry)
        skipped_type =
          if node.is_a?(Prism::AndNode)
            Narrowing.narrow_falsey(left_type)
          else
            Narrowing.narrow_truthy(left_type)
          end
        [
          Type::Combinator.union(skipped_type, right_type),
          join_with_nil_injection(left_scope, right_scope)
        ]
      end

      # `(body)`. Threads scope through the inner expression so
      # `(x = 1; x + 2)` binds `x` and produces `Constant[3]`.
      def eval_parentheses(node)
        return [Type::Combinator.constant_of(nil), scope] if node.body.nil?

        sub_eval(node.body, scope)
      end

      # `class Foo; body; end` and `module Foo; body; end`. The class
      # body runs in a fresh scope (Ruby's class scope does not see
      # the outer locals), and the StatementEvaluator pushes a new
      # `ClassFrame` so nested `def`s know their lexical owner. The
      # outer scope is unchanged on exit because Ruby's class
      # definition does not bind any local in the enclosing scope.
      # The class body's value is the value of its last statement
      # (`Constant[nil]` for an empty body); we discard the body's
      # post-scope.
      def eval_class_or_module(node)
        name = qualified_name_for(node.constant_path)
        new_context = @class_context + [ClassFrame.new(name: name, singleton: false)]
        body_type, _body_scope = eval_class_body(node, new_context)
        [body_type, scope]
      end

      # `class << expr; body; end`. When `expr` is `self`, the body
      # defines class methods on the immediate enclosing class — the
      # innermost frame flips to `singleton: true` so a nested
      # `def foo` resolves through `singleton_method` rather than
      # `instance_method`. For non-`self` expressions we cannot
      # statically resolve the receiver, so we keep the existing
      # context and accept that nested defs degrade to the
      # `Dynamic[Top]` default.
      def eval_singleton_class(node)
        new_context = singleton_context_for(node)
        body_type, _body_scope = eval_class_body(node, new_context)
        [body_type, scope]
      end

      # `def name(params); body; end`. Builds the method-entry scope
      # by binding the parameter list (RBS-driven where available, or
      # `Dynamic[Top]` for the slice 3 phase 2 fallback) into a fresh
      # scope, then evaluates the body under that scope. The outer
      # scope is left unchanged: a `def` does not introduce a binding
      # in its enclosing scope. Ruby evaluates `def` to the method's
      # name as a Symbol, so the produced type is `Constant[:name]`.
      def eval_def(node)
        body_scope = build_method_entry_scope(node)
        sub_eval(node.body, body_scope, class_context: @class_context) if node.body
        [Type::Combinator.constant_of(node.name), scope]
      end

      # `recv.foo(args) { |params| body }` and friends. The call
      # type comes from `Scope#type_of` (which routes through
      # `ExpressionTyper#call_type_for` and is itself block-aware
      # since Slice 6 phase C sub-phase 2: it builds the block-entry
      # scope from the receiving method's RBS signature, types the
      # block body, and threads the body's type into
      # `MethodDispatcher.dispatch`'s `block_type:` so generic
      # methods like `Array#map { |n| n.to_s }` resolve to
      # `Array[String]`).
      #
      # The handler still re-evaluates the block under its entry
      # scope so the per-node scope index sees the bindings on the
      # `on_enter` callback path. Block effects do NOT leak into the
      # post-call scope: a block-local write is observed only
      # inside the block body. The receiver and arguments still
      # observe the outer scope, matching Ruby evaluation order.
      def eval_call(node)
        call_type = scope.type_of(node, tracer: tracer)
        evaluate_block_if_present(node)
        post_scope = record_closure_escape_if_any(node)
        [call_type, post_scope]
      end

      def evaluate_block_if_present(node)
        block = node.block
        return unless block.is_a?(Prism::BlockNode)

        block_entry = build_block_entry_scope(node, block)
        sub_eval(block, block_entry)
      end

      # Slice 6 phase C sub-phase 3b/3c. When the call carries a
      # block whose receiving method is NOT proven non-escaping:
      #
      # - 3b: attach a `dynamic_origin` `closure_escape` fact to the
      #   post-call scope so consumers can see that the closure may
      #   have been retained past the call.
      # - 3c: drop the narrowed type of every captured outer local
      #   that the block body can rebind, replacing it with
      #   `Dynamic[Top]` through `Scope#with_local` (which also
      #   invalidates the local's `local_binding` facts). Locals
      #   shadowed by a block parameter or a `;`-prefixed
      #   block-local declaration are untouched. Locals the block
      #   only reads (without writing) are also untouched: read-only
      #   captures cannot rebind the outer variable.
      #
      # A `:non_escaping` classification (or any block-less call)
      # leaves the post-call scope unchanged.
      def record_closure_escape_if_any(node)
        return scope unless node.block.is_a?(Prism::BlockNode)

        classification = classify_closure_escape(node)
        return scope if classification == :non_escaping

        post_scope = drop_captured_narrowing(node.block, scope)
        post_scope.with_fact(
          Analysis::FactStore::Fact.new(
            bucket: :dynamic_origin,
            target: Analysis::FactStore::Target.new(kind: :closure, name: node.name.to_sym),
            predicate: :closure_escape,
            payload: { method_name: node.name.to_sym, classification: classification },
            stability: :unstable
          )
        )
      end

      def classify_closure_escape(call_node)
        receiver_type = call_node.receiver ? scope.type_of(call_node.receiver, tracer: tracer) : nil
        ClosureEscapeAnalyzer.classify(
          receiver_type: receiver_type,
          method_name: call_node.name,
          environment: scope.environment
        )
      rescue StandardError
        :unknown
      end

      # Sub-phase 3c. Replace the outer-local types that the block
      # body can rebind with `Dynamic[Top]`. The conservative drop
      # matches the spec line "facts about locals it can write
      # become unstable after the escape point": rather than
      # synthesise the union of the block's write types (which the
      # current pass does not yet expose), we discard the narrowed
      # binding altogether. A future sub-phase MAY refine this to
      # the union of the block's actual writes.
      def drop_captured_narrowing(block_node, base_scope)
        names = captured_local_writes(block_node, base_scope)
        return base_scope if names.empty?

        names.reduce(base_scope) { |acc, name| acc.with_local(name, Type::Combinator.untyped) }
      end

      def captured_local_writes(block_node, base_scope)
        body = block_node.body
        return [] if body.nil?

        introduced = block_introduced_locals(block_node)
        outer_writes = []
        Source::NodeWalker.each(body) do |descendant|
          next unless descendant.is_a?(Prism::LocalVariableWriteNode)
          next if introduced.include?(descendant.name)
          next unless base_scope.locals.key?(descendant.name)

          outer_writes << descendant.name
        end
        outer_writes.uniq
      end

      # Names introduced by the block itself (parameters, numbered
      # parameters via `BlockParameterBinder`, plus explicit
      # `;`-prefixed block-locals on `BlockParametersNode`). Writes
      # to these names are local to the block and MUST NOT be
      # treated as captured rebinds of an outer local.
      def block_introduced_locals(block_node)
        introduced = Set.new(BlockParameterBinder.new.bind(block_node).keys)
        params_root = block_node.parameters
        params_root.locals.each { |loc| introduced << loc.name } if params_root.is_a?(Prism::BlockParametersNode)
        introduced
      end

      # `Prism::BlockNode` is reached through {#eval_call}; the
      # handler runs the body under `scope`, which the caller has
      # already augmented with the block's parameter bindings. Effects
      # do not leak past the block (the outer eval_call returns the
      # caller's scope unchanged), but the body's local writes are
      # threaded through subsequent statements *inside* the block so
      # `each { |x| sum = x; sum.succ }` types `sum.succ` under the
      # `sum: x` binding.
      def eval_block(node)
        return [Type::Combinator.constant_of(nil), scope] if node.body.nil?

        sub_eval(node.body, scope)
      end

      # Builds the entry scope for a block body. The block sees the
      # outer scope's locals (Ruby's lexical scoping rule) and adds
      # bindings for every named block parameter on top. Parameter
      # types come from the receiving method's RBS signature when
      # one is available; the rest default to `Dynamic[Top]`.
      def build_block_entry_scope(call_node, block_node)
        expected = expected_block_param_types_for(call_node)
        bindings = BlockParameterBinder.new(expected_param_types: expected).bind(block_node)
        bindings.reduce(scope) { |acc, (name, type)| acc.with_local(name, type) }
      end

      def expected_block_param_types_for(call_node)
        receiver_type = call_node.receiver ? scope.type_of(call_node.receiver, tracer: tracer) : nil
        return [] if receiver_type.nil?

        arg_types = call_arg_types_for(call_node)
        MethodDispatcher.expected_block_param_types(
          receiver_type: receiver_type,
          method_name: call_node.name,
          arg_types: arg_types,
          environment: scope.environment
        )
      rescue StandardError
        []
      end

      def call_arg_types_for(call_node)
        arguments = call_node.arguments
        return [] if arguments.nil?

        arguments.arguments.map { |arg| scope.type_of(arg, tracer: tracer) }
      end

      # ----- def/class helpers -----

      def eval_class_body(node, new_context)
        return [Type::Combinator.constant_of(nil), scope] if node.body.nil?

        # Class/module bodies run in a fresh scope: the outer scope's
        # locals are NOT visible inside `class Foo; ... end`. We keep
        # the same Environment so RBS lookups continue to work, and
        # simply drop the locals. Slice A-engine: `self` inside a
        # class body is the class object itself, so we set
        # `self_type` to `Singleton[<qualified>]`.
        fresh = build_fresh_body_scope
        body_self = self_type_for_class_body(new_context)
        fresh = fresh.with_self_type(body_self) if body_self
        sub_eval(node.body, fresh, class_context: new_context)
      end

      def build_method_entry_scope(def_node)
        singleton = singleton_def?(def_node)
        binder = MethodParameterBinder.new(
          environment: scope.environment,
          class_path: current_class_path,
          singleton: singleton
        )
        bindings = binder.bind(def_node)

        # Method bodies do NOT see the outer scope's locals. They start
        # from a fresh scope with the same environment, then receive
        # the parameter bindings. Slice 7 phase 2: instance defs ALSO
        # seed their `ivars` map from the class-level accumulator so
        # `def get; @x; end` reads the type that a sibling
        # `def init; @x = 1; end` wrote.
        fresh = build_fresh_body_scope
        body_self = self_type_for_method_body(singleton: singleton)
        fresh = fresh.with_self_type(body_self) if body_self
        fresh = seed_instance_ivars(fresh, singleton: singleton)
        bindings.reduce(fresh) { |acc, (name, type)| acc.with_local(name, type) }
      end

      def seed_instance_ivars(body_scope, singleton:)
        return body_scope if singleton

        path = current_class_path
        return body_scope if path.nil?

        seeded = scope.class_ivars_for(path)
        return body_scope if seeded.empty?

        seeded.reduce(body_scope) { |acc, (name, type)| acc.with_ivar(name, type) }
      end

      # Slice A-declarations. Class- and method-bodies start from a
      # fresh local-empty scope, but they MUST keep the
      # `declared_types` table visible at the outer scope so the
      # ScopeIndexer-populated declaration overrides
      # (`Prism::ConstantReadNode` for `module Foo` headers, etc.)
      # remain reachable from inside nested bodies.
      def build_fresh_body_scope
        Scope.empty(environment: scope.environment)
             .with_declared_types(scope.declared_types)
             .with_class_ivars(scope.class_ivars)
      end

      def singleton_def?(def_node)
        def_node.receiver.is_a?(Prism::SelfNode) || current_frame_singleton?
      end

      # Slice A-engine. Inside a class body `class Foo; ...; end`,
      # `self` is the class object — `Singleton[Foo]`. Returns nil
      # at the top level (no enclosing class).
      def self_type_for_class_body(class_context)
        return nil if class_context.empty?

        Type::Combinator.singleton_of(class_context.map(&:name).join("::"))
      end

      # Slice A-engine. Inside a method body, `self` depends on
      # whether the def is on the singleton or instance side of the
      # surrounding class:
      #
      # - `def self.foo` or any def inside `class << self`: self is
      #   the class object → `Singleton[Foo]`.
      # - ordinary instance `def foo`: self is an instance →
      #   `Nominal[Foo]`.
      #
      # Returns nil for top-level defs that have no enclosing class.
      def self_type_for_method_body(singleton:)
        path = current_class_path
        return nil if path.nil?

        if singleton
          Type::Combinator.singleton_of(path)
        else
          Type::Combinator.nominal_of(path)
        end
      end

      def qualified_name_for(constant_path_node)
        case constant_path_node
        when Prism::ConstantReadNode
          constant_path_node.name.to_s
        when Prism::ConstantPathNode
          render_constant_path(constant_path_node)
        end
      end

      def render_constant_path(node)
        prefix =
          case node.parent
          when Prism::ConstantReadNode then "#{node.parent.name}::"
          when Prism::ConstantPathNode then "#{render_constant_path(node.parent)}::"
          else ""
          end
        "#{prefix}#{node.name}"
      end

      def singleton_context_for(node)
        return @class_context unless node.expression.is_a?(Prism::SelfNode)
        return @class_context if @class_context.empty?

        outer = @class_context[0..-2]
        last = @class_context.last
        outer + [ClassFrame.new(name: last.name, singleton: true)]
      end

      # The qualified name of the immediately-enclosing class (joining
      # every nested `ClassFrame` with `::`). Returns `nil` for a
      # top-level def with no enclosing class, which routes the
      # parameter binder past RBS lookup.
      def current_class_path
        return nil if @class_context.empty?

        @class_context.map(&:name).join("::")
      end

      def current_frame_singleton?
        @class_context.last&.singleton == true
      end

      # ----- helpers -----

      def sub_eval(node, with_scope, class_context: @class_context)
        StatementEvaluator.new(
          scope: with_scope,
          tracer: tracer,
          on_enter: @on_enter,
          class_context: class_context
        ).evaluate(node)
      end

      def eval_branch_or_nil(branch_node, branch_scope)
        return [Type::Combinator.constant_of(nil), branch_scope] if branch_node.nil?

        sub_eval(branch_node, branch_scope)
      end

      # Joins two branch scopes at a control-flow merge point. Names
      # bound in only one branch are nil-injected into the other side
      # so the joined scope sees them as `T | nil` rather than dropping
      # them outright. This implements the contract the Slice 3 phase 1
      # `Scope#join` documentation defers to the statement-level
      # evaluator.
      def join_with_nil_injection(scope_a, scope_b)
        nil_const = Type::Combinator.constant_of(nil)
        a_keys = scope_a.locals.keys
        b_keys = scope_b.locals.keys
        a_only = a_keys - b_keys
        b_only = b_keys - a_keys

        aug_a = b_only.reduce(scope_a) { |acc, name| acc.with_local(name, nil_const) }
        aug_b = a_only.reduce(scope_b) { |acc, name| acc.with_local(name, nil_const) }
        aug_a.join(aug_b)
      end

      # Generalises {#join_with_nil_injection} to N branches (case/when,
      # begin/rescue chain). The reduce order does not affect the
      # result because nil-injection commutes with union under
      # `Scope#join`.
      def reduce_scopes_with_nil_injection(scopes)
        scopes.reduce { |a, b| join_with_nil_injection(a, b) }
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
