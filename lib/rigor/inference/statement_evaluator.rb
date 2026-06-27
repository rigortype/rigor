# frozen_string_literal: true

require "prism"

require_relative "../reflection"
require_relative "../type"
require_relative "../analysis/fact_store"
require_relative "../source/node_walker"
require_relative "../source/constant_path"
require_relative "block_parameter_binder"
require_relative "body_fixpoint"
require_relative "struct_fold_safety"
require_relative "closure_escape_analyzer"
require_relative "indexed_narrowing"
require_relative "method_dispatcher"
require_relative "method_parameter_binder"
require_relative "multi_target_binder"
require_relative "mutation_widening"
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
        Prism::LocalVariableOrWriteNode => :eval_local_or_write,
        Prism::LocalVariableAndWriteNode => :eval_local_and_write,
        Prism::LocalVariableOperatorWriteNode => :eval_local_operator_write,
        Prism::InstanceVariableWriteNode => :eval_ivar_write,
        Prism::InstanceVariableOrWriteNode => :eval_ivar_or_write,
        Prism::InstanceVariableAndWriteNode => :eval_ivar_and_write,
        Prism::InstanceVariableOperatorWriteNode => :eval_ivar_operator_write,
        Prism::ClassVariableWriteNode => :eval_cvar_write,
        Prism::ClassVariableOrWriteNode => :eval_cvar_or_write,
        Prism::ClassVariableAndWriteNode => :eval_cvar_and_write,
        Prism::ClassVariableOperatorWriteNode => :eval_cvar_operator_write,
        Prism::GlobalVariableWriteNode => :eval_global_write,
        Prism::GlobalVariableOrWriteNode => :eval_global_or_write,
        Prism::GlobalVariableAndWriteNode => :eval_global_and_write,
        Prism::GlobalVariableOperatorWriteNode => :eval_global_operator_write,
        Prism::IndexOrWriteNode => :eval_index_or_write,
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
        Prism::ForNode => :eval_for,
        Prism::AndNode => :eval_and_or,
        Prism::OrNode => :eval_and_or,
        Prism::ParenthesesNode => :eval_parentheses,
        Prism::DefNode => :eval_def,
        Prism::ClassNode => :eval_class_or_module,
        Prism::ModuleNode => :eval_class_or_module,
        Prism::SingletonClassNode => :eval_singleton_class,
        Prism::CallNode => :eval_call,
        Prism::BlockNode => :eval_block,
        Prism::ReturnNode => :eval_return,
        Prism::BreakNode => :eval_break,
        Prism::MatchWriteNode => :eval_match_write
      }.freeze
      private_constant :HANDLERS

      # Thread-local sink (an Array) collecting the value types of explicit
      # `return value` nodes reached while evaluating a method body, so
      # `ExpressionTyper#infer_user_method_return` can join them into the
      # method's inferred return type. The flow value of a `return` is still
      # `Bot` (it transfers control rather than producing a value); the sink
      # only records what the method *returns* through that edge. nil means
      # "not collecting" — a top-level / DSL-block walk, or inside a nested
      # `def` barrier (whose returns belong to the inner method).
      RETURN_SINK_KEY = :rigor_return_sink
      private_constant :RETURN_SINK_KEY

      # Thread-local sink (an Array of `[BreakNode, Scope]`) collecting the
      # scope at each `break` reached while evaluating a loop body, so
      # `eval_loop` / `eval_for` can join a `break`-path binding (`flag = true;
      # break`) into the loop continuation that the fall-through would
      # otherwise drop. Stacks like the return sink: a nested loop installs its
      # own sink, restored on exit, so an inner loop's break does not leak to
      # the outer one. A `break` inside a block / nested loop targets that
      # inner construct, not the lexical loop — filtered out by the
      # directly-targeting break set, see {#directly_targeting_breaks}.
      # See docs/notes/20260615-loop-break-binding-propagation-design.md.
      BREAK_SINK_KEY = :rigor_break_sink
      private_constant :BREAK_SINK_KEY

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
      # @param converged_loop_recording [Boolean] when true (and an
      #   `on_enter` recorder is installed), {#eval_loop} re-evaluates a
      #   fixpoint-tracked loop body ONE extra time from the CONVERGED
      #   bindings so the last-visit-wins per-node scope index reflects
      #   the post-writeback state instead of the cap-N intermediate
      #   assumption (`result *= i` annotating `1 | 2` rather than
      #   `Integer`). Display-path only — `rigor check` leaves it off,
      #   keeping its diagnostics and wall-clock unchanged.
      def initialize(scope:, tracer: nil, on_enter: nil, class_context: [].freeze,
                     converged_loop_recording: false)
        @scope = scope
        @tracer = tracer
        @on_enter = on_enter
        @class_context = class_context.freeze
        @converged_loop_recording = converged_loop_recording
      end

      # Runs `block` with a fresh return sink installed, then yields the
      # collected explicit-`return` value types to the caller. The sink is
      # an array of `Rigor::Type`. Nested invocations stack: the previous
      # sink is restored on exit so a `def` evaluated inside another method's
      # body (which itself installed a sink) does not corrupt the outer one.
      # Used by `ExpressionTyper#infer_user_method_return` to join the
      # explicit returns into the inferred method-return type.
      def self.with_return_sink
        previous = Thread.current[RETURN_SINK_KEY]
        sink = []
        Thread.current[RETURN_SINK_KEY] = sink
        begin
          result = yield
        ensure
          Thread.current[RETURN_SINK_KEY] = previous
        end
        [result, sink]
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
        # ADR-58 WD1 — `r = @right` where `@right`'s optionality is purely
        # declaration-sourced makes `r` declaration-sourced too (the survey's
        # exact rotation/traversal shape `r = @right; r.key`). The mark is
        # computed on the RHS *value*'s provenance — a pure ivar read of a
        # currently declaration-sourced ivar — so it survives the local copy.
        # Any other RHS (a call result, a method-local-nil-bearing value)
        # leaves the local flow-live and the diagnostic fires as before.
        if declaration_sourced_ivar_read?(node.value, post_rhs)
          return [rhs_type, post_rhs.with_declaration_sourced_local(node.name, rhs_type)]
        end

        [rhs_type, post_rhs.with_local(node.name, rhs_type)]
      end

      # True when `value_node` is a bare instance-variable read whose binding
      # in `scope_at_read` is currently marked declaration-sourced.
      def declaration_sourced_ivar_read?(value_node, scope_at_read)
        return false unless value_node.is_a?(Prism::InstanceVariableReadNode)

        scope_at_read.declaration_sourced?(:ivar, value_node.name)
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

      # Slice 7 phase 3 — compound writes (||=, &&=, +=/-=/...)
      # for every variable kind. Each handler:
      #   1. Reads the current type from the appropriate scope
      #      binding map (or `Dynamic[Top]` when unbound).
      #   2. Evaluates the rvalue under the entry scope and
      #      threads any scope effects (rare for compound RHS,
      #      but matches Ruby evaluation order).
      #   3. Computes the result type via `compound_result_type`:
      #      `||=` → `union(narrow_truthy(current), rhs)`;
      #      `&&=` → `union(narrow_falsey(current), rhs)`;
      #      operator forms (`+=`, `-=`, `*=`, ...) dispatch
      #      `current.send(op, rhs)` through `MethodDispatcher`,
      #      falling back to `Dynamic[Top]` on a miss.
      #   4. Rebinds the variable into the post-scope through
      #      the same `with_*` builder used by the plain write
      #      handler, so subsequent reads observe the result.
      def eval_local_or_write(node)
        compound_eval(node, kind: :local, op: :or)
      end

      def eval_local_and_write(node)
        compound_eval(node, kind: :local, op: :and)
      end

      def eval_local_operator_write(node)
        compound_eval(node, kind: :local, op: node.binary_operator)
      end

      def eval_ivar_or_write(node)
        compound_eval(node, kind: :ivar, op: :or)
      end

      def eval_ivar_and_write(node)
        compound_eval(node, kind: :ivar, op: :and)
      end

      def eval_ivar_operator_write(node)
        compound_eval(node, kind: :ivar, op: node.binary_operator)
      end

      def eval_cvar_or_write(node)
        compound_eval(node, kind: :cvar, op: :or)
      end

      def eval_cvar_and_write(node)
        compound_eval(node, kind: :cvar, op: :and)
      end

      def eval_cvar_operator_write(node)
        compound_eval(node, kind: :cvar, op: node.binary_operator)
      end

      def eval_global_or_write(node)
        compound_eval(node, kind: :global, op: :or)
      end

      def eval_global_and_write(node)
        compound_eval(node, kind: :global, op: :and)
      end

      def eval_global_operator_write(node)
        compound_eval(node, kind: :global, op: node.binary_operator)
      end

      def compound_eval(node, kind:, op:) # rubocop:disable Naming/MethodParameterName
        current_type = current_type_for(kind, node.name)
        rhs_type, post_rhs = sub_eval(node.value, scope)
        result_type = compound_result_type(current_type, rhs_type, op)
        [result_type, rebind_variable(post_rhs, kind, node.name, result_type)]
      end

      VAR_KIND_GETTERS = {
        local: :local, ivar: :ivar, cvar: :cvar, global: :global
      }.freeze
      VAR_KIND_BUILDERS = {
        local: :with_local, ivar: :with_ivar, cvar: :with_cvar, global: :with_global
      }.freeze
      private_constant :VAR_KIND_GETTERS, :VAR_KIND_BUILDERS

      def current_type_for(kind, name)
        scope.public_send(VAR_KIND_GETTERS.fetch(kind), name) || Type::Combinator.untyped
      end

      def rebind_variable(target_scope, kind, name, type)
        target_scope.public_send(VAR_KIND_BUILDERS.fetch(kind), name, type)
      end

      def compound_result_type(current, rhs, operator)
        case operator
        when :or
          Type::Combinator.union(Narrowing.narrow_truthy(current), rhs)
        when :and
          Type::Combinator.union(Narrowing.narrow_falsey(current), rhs)
        else
          dispatch_operator(current, rhs, operator)
        end
      end

      # `receiver[key] ||= default` — the Redmine `Query#as_params`
      # idiom. After the `||=`, the next read at `receiver[key]` is known
      # non-nil; the next `<<` / `[]=` / other mutator runs against
      # a Tuple / Hash carrier instead of the `Constant[nil]` an
      # empty `HashShape{}` lookup would otherwise fold to.
      #
      # The handler:
      # 1. Types the equivalent `receiver[key]` read under the
      #    entry scope (so any previously-recorded narrowing for
      #    the same address is already applied).
      # 2. Types the rvalue under the entry scope.
      # 3. Computes `union(narrow_truthy(current), rhs)` — the
      #    standard `||=` result shape used by locals / ivars /
      #    cvars / globals.
      # 4. Records the result type in the post-scope as a
      #    narrowing keyed on `(receiver_kind, receiver_name,
      #    literal_key)` when both receiver and key are stable
      #    (see {Inference::IndexedNarrowing}). Unstable shapes
      #    fall through to "no scope effect", matching the old
      #    `Prism::IndexOrWriteNode` default-branch behaviour.
      #
      # The expression value is the result type, matching Ruby's
      # semantics: `(x = params[:f] ||= []); x` observes the
      # post-`||=` value, not the rvalue alone.
      def eval_index_or_write(node)
        rhs_type, post_rhs = sub_eval(node.value, scope)
        current_type = scope.type_of(node, tracer: tracer)
        result_type = Type::Combinator.union(Narrowing.narrow_truthy(current_type), rhs_type)

        key_node = first_index_argument(node)
        address = key_node && IndexedNarrowing.stable_address(node.receiver, key_node)
        post = post_rhs
        post = post.with_indexed_narrowing(*address, result_type) if address

        [result_type, post]
      end

      def first_index_argument(node)
        args = node.arguments
        return nil if args.nil?

        list = args.respond_to?(:arguments) ? args.arguments : args
        list.first
      end

      def dispatch_operator(current, rhs, operator)
        result = MethodDispatcher.dispatch(
          receiver_type: current,
          method_name: operator.to_sym,
          arg_types: [rhs],
          environment: scope.environment
        )
        result || Type::Combinator.untyped
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
        pred_type, post_pred = sub_eval(node.predicate, scope)

        # When the predicate is a known-truthy / known-falsey type
        # (notably `Constant[true]` / `Constant[false]` after the
        # constant-fold tier), only the live branch contributes a
        # type and a post-scope. The dead branch is skipped so the
        # result type is precise (`Constant[:even]` instead of the
        # joined `Constant[:even] | Constant[:odd]`).
        live = live_branch_for_if(node, pred_type, post_pred)
        if live
          live_type, _live_scope = live
          # When the provably-live then-branch terminates and there is no
          # else, apply the same falsey-scope narrowing as the standard
          # early-return path below. Without this, `return if @ivar.nil?`
          # with an ivar seeded as Constant[nil] (making nil? = Constant[true]
          # and the then-branch "provably live") propagates the un-narrowed
          # nil scope past the guard instead of Bot.
          if branch_terminates?(node.statements, live_type) && node.subsequent.nil?
            _, falsey_scope = Narrowing.predicate_scopes(node.predicate, post_pred)
            return [live_type, falsey_scope]
          end
          return live
        end

        truthy_scope, falsey_scope = Narrowing.predicate_scopes(node.predicate, post_pred)
        then_type, then_scope = eval_branch_or_nil(node.statements, truthy_scope)
        else_type, else_scope = eval_branch_or_nil(node.subsequent, falsey_scope)
        # Slice 7 phase 14 — early-return narrowing. When the
        # then-branch unconditionally exits (return / next /
        # break / raise) and there is no else, the post-scope
        # is the falsey edge of the predicate (subsequent
        # statements observe the predicate-was-false world). The
        # then-body is the *skipped* path, so the bare narrowing
        # (no body assignments) is the correct continuation.
        return [Type::Combinator.union(then_type, else_type), falsey_scope] \
          if branch_terminates?(node.statements, then_type) && node.subsequent.nil?
        # Symmetric case: the else / elsif-chain (`node.subsequent`)
        # unconditionally exits, so the only surviving path is the
        # then-branch that RAN. The continuation must therefore carry
        # `then_scope` — the predicate-truthy narrowing PLUS the
        # then-body's assignments — not the bare `truthy_scope`.
        # Returning `truthy_scope` drops every local the then-body
        # bound, leaving it unbound for any enclosing merge to
        # spuriously nil-inject: e.g. the inner `elsif … else raise`
        # of `if a then x=… elsif b then x=… else raise end` would
        # return with `x` unbound, and the outer if's join would then
        # read `x` as `… | nil` and fire a false `possible-nil-receiver`
        # (liquid v5.x sweep, Event 3).
        return [Type::Combinator.union(then_type, else_type), then_scope] \
          if branch_terminates?(node.subsequent, else_type) && node.statements

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
        pred_type, post_pred = sub_eval(node.predicate, scope)

        live = live_branch_for_unless(node, pred_type, post_pred)
        if live
          live_type, _live_scope = live
          # Mirror of the eval_if fix: when the provably-live unless-body
          # terminates and there is no else, apply the truthy-scope narrowing
          # so `return unless @ivar` with a nil-seeded ivar doesn't propagate
          # the nil scope past the guard.
          if branch_terminates?(node.statements, live_type) && node.else_clause.nil?
            truthy_scope, = Narrowing.predicate_scopes(node.predicate, post_pred)
            return [live_type, truthy_scope]
          end
          return live
        end

        truthy_scope, falsey_scope = Narrowing.predicate_scopes(node.predicate, post_pred)
        then_type, then_scope = eval_branch_or_nil(node.statements, falsey_scope)
        else_type, else_scope = eval_branch_or_nil(node.else_clause, truthy_scope)
        # Slice 7 phase 14 — same early-return narrowing as
        # `if`: when the body unconditionally exits and there
        # is no else, the post-scope is the truthy edge (the body
        # is the skipped path, so the bare narrowing is correct).
        return [Type::Combinator.union(then_type, else_type), truthy_scope] \
          if branch_terminates?(node.statements, then_type) && node.else_clause.nil?
        # Symmetric to the `if` else-exits fix: when the else-clause
        # exits, the surviving path is the unless-body that RAN, so the
        # continuation carries `then_scope` (the predicate-falsey
        # narrowing PLUS the body's assignments), not the bare
        # `falsey_scope` — otherwise body-bound locals are dropped and
        # an enclosing merge nil-injects them.
        return [Type::Combinator.union(then_type, else_type), then_scope] \
          if branch_terminates?(node.else_clause, else_type) && node.statements

        [
          Type::Combinator.union(then_type, else_type),
          join_with_nil_injection(then_scope, else_scope)
        ]
      end

      # Returns the `[type, post_scope]` of the live branch when the
      # predicate is provably truthy / falsey, else nil so the
      # caller falls through to the standard both-branch evaluation.
      # Constant `true`/`false` is the obvious trigger; non-falsey
      # carriers like `Nominal[Integer]` (Integer is always truthy
      # in Ruby — including 0) also collapse the dead else.
      def live_branch_for_if(node, pred_type, post_pred)
        case Narrowing.predicate_certainty(pred_type)
        when :truthy then eval_branch_or_nil(node.statements, post_pred)
        when :falsey then eval_branch_or_nil(node.subsequent, post_pred)
        end
      end

      def live_branch_for_unless(node, pred_type, post_pred)
        case Narrowing.predicate_certainty(pred_type)
        when :truthy then eval_branch_or_nil(node.else_clause, post_pred)
        when :falsey then eval_branch_or_nil(node.statements, post_pred)
        end
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
        branch_results, falsey_scope = eval_case_when_branches(node.predicate, node.conditions, post_pred)
        else_result = eval_case_else(node.else_clause, falsey_scope)

        all_results = [*branch_results, else_result]
        branch_nodes = [*node.conditions, node.else_clause]
        [
          Type::Combinator.union(*all_results.map(&:first)),
          join_case_branch_scopes(all_results, branch_nodes)
        ]
      end

      # Joins the post-scopes of every `when`/`in`/`else` branch, dropping
      # the scope of any branch that terminates (raises / returns / throws /
      # types to `Bot`) before the merge — control never falls through such
      # a branch, so its half-bound locals must not nil-inject the names a
      # live sibling branch assigned. Mirrors the `branch_terminates?` rule
      # `eval_if`/`eval_unless` already apply to the if/else merge: e.g.
      # `case x; when 1 then v="a"; when 2 then v="b"; else raise; end`
      # keeps `v: "a" | "b"` instead of `... | nil`. When every branch
      # terminates the merge is itself unreachable; fall back to the full
      # join so the continuation scope stays well-formed.
      def join_case_branch_scopes(results, nodes)
        live = []
        results.each_with_index do |(type, branch_scope), i|
          live << branch_scope unless branch_terminates?(nodes[i], type)
        end

        live = results.map(&:last) if live.empty?
        reduce_scopes_with_nil_injection(live)
      end

      def eval_case_when_branches(subject, conditions, entry_scope)
        results = []
        falsey_scope = entry_scope
        conditions.each do |branch|
          # ADR-47 WD2 — record the scope ENTERING this clause (the
          # subject narrowed by every earlier clause's negation) on the
          # clause's first condition node, so `flow.unreachable-clause`
          # can tell a prior-exhausted subject (entry already `bot`)
          # from a per-clause-disjoint one (entry concrete, this clause
          # disjoint). `on_enter`-only (no recursion) so no condition
          # sub-expression is newly typed; `propagate` preserves the
          # entry because it already keys the node.
          record_clause_entry_scope(branch, falsey_scope)
          body_scope, falsey_scope = branch_body_and_falsey_scopes(subject, branch, falsey_scope)
          results << sub_eval(branch, body_scope)
        end
        [results, falsey_scope]
      end

      # ADR-47 WD2/WD3 — record the scope ENTERING a `when`/`in` clause on
      # the node `flow.unreachable-clause` reads to classify a dead clause
      # (`when`: first condition; `in`: the pattern). `on_enter`-only so no
      # sub-expression is newly typed; `propagate` preserves it.
      def record_clause_entry_scope(branch, entry_scope)
        node =
          case branch
          when Prism::WhenNode then branch.conditions.first
          when Prism::InNode then branch.pattern
          end
        @on_enter&.call(node, entry_scope) if node
      end

      # Returns `[body_scope, updated_falsey_scope]` for a single branch.
      # `WhenNode` branches narrow through `Narrowing.case_when_scopes`.
      # `InNode` branches narrow soundly only for a bare class pattern
      # (`in C` / `in C => x`, pure `is_a?`); every other pattern keeps
      # the conservative "body = entry + bindings, falsey unchanged" shape.
      def branch_body_and_falsey_scopes(subject, branch, falsey_scope)
        if branch.is_a?(Prism::InNode)
          in_branch_body_and_falsey_scopes(subject, branch, falsey_scope)
        else
          when_conditions = branch.respond_to?(:conditions) ? branch.conditions : []
          Narrowing.case_when_scopes(subject, when_conditions, falsey_scope)
        end
      end

      # ADR-47 WD3a — a bare class pattern matches on `C === subject`, i.e.
      # exactly `subject.is_a?(C)` with no deconstruction, so it narrows
      # like `when C`: the body sees the subject narrowed to `C` and the
      # next clause's falsey scope has `C` removed. Other patterns can fail
      # to match even when a class test would pass (deconstruction arity,
      # hash keys, ...), so removing anything from the falsey scope would
      # be unsound — they keep the conservative shape.
      def in_branch_body_and_falsey_scopes(subject, branch, falsey_scope)
        class_node = bare_class_pattern_node(branch.pattern)
        return [apply_in_pattern_bindings(subject, branch.pattern, falsey_scope), falsey_scope] unless class_node

        truthy_scope, narrowed_falsey = Narrowing.case_when_scopes(subject, [class_node], falsey_scope)
        [apply_in_pattern_bindings(subject, branch.pattern, truthy_scope), narrowed_falsey]
      end

      # The class-constant node of a `in C` / `in C => x` pattern (the only
      # `in` shapes whose match is pure `is_a?`), or nil for any pattern
      # that deconstructs, binds, or matches a value.
      def bare_class_pattern_node(pattern)
        case pattern
        when Prism::ConstantReadNode, Prism::ConstantPathNode
          pattern
        when Prism::CapturePatternNode
          value = pattern.value
          value if value.is_a?(Prism::ConstantReadNode) || value.is_a?(Prism::ConstantPathNode)
        end
      end

      def eval_case_else(else_clause, falsey_scope)
        return sub_eval(else_clause, falsey_scope) if else_clause

        [Type::Combinator.constant_of(nil), falsey_scope]
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
        entry = scope
        primary_type, primary_scope = eval_begin_primary_under(node, entry)
        rescue_chain = collect_rescue_chain_results(node.rescue_clause, entry)

        # B2.1 — retry-edge widening. When any rescue body
        # contains `Prism::RetryNode`, control re-enters the
        # primary body with the rescue arm's rebinds visible.
        # Today's flow loses that effect, so a counter like
        # `tries = 0; ...; rescue; tries += 1; retry; end`
        # observes `tries: Constant[0]` inside the body and any
        # `tries > 100` predicate folds to always-falsey.
        # The fix: widen rebound locals / ivars in any
        # retry-emitting arm to their Nominal envelope (Constant
        # → Nominal[<class>], Tuple → Array, HashShape → Hash),
        # then re-evaluate primary body AND rescue chain once
        # under the widened entry. Nominal envelope is the
        # maximally widened form so the re-evaluation converges
        # in one step.
        widened_entry = widen_entry_for_retry(entry, rescue_chain)
        if widened_entry
          primary_type, primary_scope = eval_begin_primary_under(node, widened_entry)
          rescue_chain = collect_rescue_chain_results(node.rescue_clause, widened_entry)
        end

        # Rescue arms whose body unconditionally exits (`return`,
        # `next`, `break`, `raise`, `throw`, `exit`, `abort`,
        # `fail`) contribute neither a type fragment NOR a scope
        # to the post-begin flow — control left the `begin` via
        # that arm. Mirrors the `eval_if` / `eval_unless` /
        # `eval_and_or` early-return narrowing. Without this
        # filter, a `rescue ... return` on a local bound only in
        # the primary body nil-injects that local across the
        # join, defeating the rescue arm's whole point of guaranteeing
        # the primary local is in scope for downstream statements.
        live_rescues = rescue_chain.reject { |_pair, arm_node| branch_unconditionally_exits?(arm_node.statements) }
                                   .map(&:first)

        if live_rescues.empty?
          exit_type = primary_type
          exit_scope = primary_scope
        else
          exit_type = Type::Combinator.union(primary_type, *live_rescues.map(&:first))
          exit_scope = reduce_scopes_with_nil_injection([primary_scope, *live_rescues.map(&:last)])
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
        eval_begin_primary_under(node, scope)
      end

      def eval_begin_primary_under(node, entry_scope)
        body_type, body_scope =
          if node.statements
            sub_eval(node.statements, entry_scope)
          else
            [Type::Combinator.constant_of(nil), entry_scope]
          end

        if node.else_clause
          else_type, else_scope = sub_eval(node.else_clause, body_scope)
          [else_type, else_scope]
        else
          [body_type, body_scope]
        end
      end

      # B2.1 — return a widened entry scope when at least one
      # rescue arm in `rescue_chain` contains a `Prism::RetryNode`
      # AND that arm rebinds at least one local or ivar relative
      # to the original entry. Returns nil when no widening is
      # needed (no retry, or no rebinds reachable across the
      # retry edge).
      #
      # Always-safe: the widening can only LOSE precision; it
      # never invents a fact (Nominal envelope is a superset of
      # the Constant / shape carrier it widens from). Convergent
      # in one step because Nominal envelope is the maximally
      # widened form against the engine's current carrier set.
      def widen_entry_for_retry(entry_scope, rescue_chain)
        widened = nil
        rescue_chain.each do |(_arm_type, arm_post_scope), arm_node|
          next unless arm_contains_retry?(arm_node)

          accumulator = widened || entry_scope
          accumulator = absorb_retry_rebinds(accumulator, entry_scope, arm_post_scope)
          widened = accumulator
        end
        return nil if widened.nil? || widened == entry_scope

        widened
      end

      def arm_contains_retry?(node)
        return false unless node.is_a?(Prism::Node)
        return true if node.is_a?(Prism::RetryNode)
        # Don't descend into nested blocks / defs / classes /
        # modules — a `retry` inside a nested method body or
        # block targets its own enclosing `begin`, not this one.
        return false if node.is_a?(Prism::DefNode) ||
                        node.is_a?(Prism::ClassNode) ||
                        node.is_a?(Prism::ModuleNode) ||
                        node.is_a?(Prism::BlockNode)

        node.compact_child_nodes.any? { |c| arm_contains_retry?(c) }
      end

      def absorb_retry_rebinds(accumulator, entry_scope, arm_post_scope)
        scope_acc = accumulator
        # Walk every local visible in either side, compare types,
        # widen to Nominal envelope on a difference.
        local_keys = arm_post_scope.locals.keys | entry_scope.locals.keys
        local_keys.each do |name|
          pre = entry_scope.local(name)
          post = arm_post_scope.local(name)
          next if pre == post || post.nil?

          widened = retry_widened_type(pre, post)
          scope_acc = scope_acc.with_local(name, widened)
        end
        ivar_keys = arm_post_scope.ivars.keys | entry_scope.ivars.keys
        ivar_keys.each do |name|
          pre = entry_scope.ivar(name)
          post = arm_post_scope.ivar(name)
          next if pre == post || post.nil?

          widened = retry_widened_type(pre, post)
          scope_acc = scope_acc.with_ivar(name, widened)
        end
        scope_acc
      end

      def retry_widened_type(pre, post)
        # `pre` is nil when the local was introduced inside the
        # rescue body. The retry edge brings it back into the
        # primary body's entry — widen the post type itself.
        envelope = nominal_envelope_for(post)
        return envelope if pre.nil?

        nominal_envelope_for(Type::Combinator.union(pre, envelope))
      end

      # Nominal envelope of a value type: widens Constant /
      # Tuple / HashShape carriers to the underlying class's
      # `Nominal`, preserving everything else (`Nominal`,
      # `Union` of non-shape members, `Top`, `Dynamic`, `Bot`).
      # Union members are walked individually.
      def nominal_envelope_for(type)
        members = type.is_a?(Type::Union) ? type.members : [type]
        widened = members.map { |m| nominal_envelope_member(m) }
        Type::Combinator.union(*widened)
      end

      def nominal_envelope_member(member)
        case member
        when Type::Constant
          Type::Combinator.nominal_of(member.value.class.name)
        when Type::Tuple
          MutationWidening.widen_tuple(member)
        when Type::HashShape
          MutationWidening.widen_hash_shape(member)
        else
          member
        end
      end

      def collect_rescue_chain_results(rescue_node, entry_scope)
        results = []
        current = rescue_node
        while current
          rescue_scope = bind_rescue_reference(current, entry_scope)
          results << [eval_branch_or_nil(current.statements, rescue_scope), current]
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
        return [Type::Combinator.constant_of(nil), narrow_loop_exit_edge(node, post_pred)] if node.statements.nil?

        # The historical single body pass joined with the pre-loop scope.
        # This continues to carry everything the fixpoint does NOT track:
        # receiver-mutation widening of non-rebound locals (`buf.push(i)`
        # widens `buf`'s Tuple), body-introduced locals' nil-injection, and
        # the loop value itself. The fixpoint then OVERLAYS only the
        # rebound-local bindings it corrects.
        #
        # The pass runs under a break sink so a `break`-path binding
        # (`flag = true; break`) the fall-through `body_scope` drops is
        # collected for the continuation join below.
        break_targets, break_sink, body_scope = capture_loop_body_breaks(node.statements, post_pred)
        base_scope = join_with_nil_injection(post_pred, body_scope)

        rebound, body_first = loop_body_local_writes(node.statements, post_pred)
        names = rebound + body_first

        # Fast path: a loop whose body rebinds no local skips the rebind
        # fixpoint, but still needs the slice-C content writeback (a loop may
        # content-mutate a collection without rebinding any local — `acc <<
        # x`), so apply it to the single-pass join before returning.
        if names.empty?
          fast = loop_content_writeback(node.statements, base_scope)
          return [Type::Combinator.constant_of(nil), narrow_loop_exit_edge(node, fast)]
        end

        post_loop = converged_loop_scope(node, post_pred, base_scope, names, body_first)
        # Recover `break`-path bindings the fall-through dropped (`flag = true;
        # break` -> `flag` is `false | true`, not the stale `false`).
        post_loop = join_break_scopes(post_loop, break_sink, break_targets, names)
        post_loop = narrow_loop_exit_edge(node, post_loop)
        [Type::Combinator.constant_of(nil), post_loop]
      end

      # The continuation scope for a loop whose body rebinds locals: the
      # ADR-56 slice-B rebind fixpoint overlaid on `base_scope`, then the
      # slice-C receiver-content writeback.
      def converged_loop_scope(node, post_pred, base_scope, names, body_first)
        # ADR-56 slice B — loop-body fixpoint. The body runs 0..N times and
        # may compound (`d *= 2`), so the historical single body pass joined
        # with the pre-loop scope kept stale folded constants
        # (`d = 1; while …; d *= 2; end` → `1 | 2`, never reaching `4, 8`).
        # Fold each body-written local's continuation binding through the same
        # capped fixpoint slice A uses for non-escaping block captures. Seed:
        # a pre-existing local seeds with its post-predicate binding; a local
        # FIRST assigned inside the body seeds with `nil` so the 0-iteration
        # path degrades it to `T | nil`, matching the nil-injection treatment.
        result = loop_rebind_fixpoint(node, post_pred, names, body_first)
        # Display-path re-record: the fixpoint's body re-evaluations fire
        # `on_enter` with the cap-N INTERMEDIATE assumptions, so the
        # last-visit-wins scope index would annotate loop-body lines with
        # stale pre-convergence constants. One extra pass from the converged
        # bindings (result discarded) re-records the body's entry scopes.
        record_converged_loop_body(node, post_pred, result, names, body_first)
        post_loop = result.reduce(base_scope) { |acc, (name, type)| acc.with_local(name, type) }
        # ADR-56 slice C — loop-body receiver-content element-type join. A loop
        # that content-mutates a collection (`acc << n`) keeps only the seed's
        # element types after the single-pass widen; join the appended/stored
        # types into the continuation collection (pre-state read from
        # `post_loop` so a local both rebound and content-mutated composes).
        loop_content_writeback(node.statements, post_loop)
      end

      # Item 4 — loop-exit predicate narrowing. A `while pred` / `until pred`
      # loop exits PRECISELY on the predicate's exit edge: `while` exits when
      # `pred` is falsey, `until` when `pred` is truthy. So after the loop the
      # predicate-assignment target carries the exit polarity — `until line =
      # io.gets; …; end; line.foo` reads `line` non-nil because the loop ran
      # until `gets` returned a truthy (non-nil) line. Apply the exit edge of
      # `Narrowing.predicate_scopes` to the continuation scope.
      #
      # Guarded against `break`: a `break` exits the loop WITHOUT the predicate
      # ever going false (`while line = gets; break if done; end` can leave
      # `line` truthy on a `while`, or exit before the `until` predicate fires),
      # so the exit-edge proof does not hold and the loop is left un-narrowed.
      # `break` inside a NESTED loop/block does not target this loop, but a
      # nested-loop `break` is rare in predicate-assignment loops and the
      # conservative bail only costs precision, never soundness.
      def narrow_loop_exit_edge(node, post_loop)
        return post_loop if loop_body_breaks?(node.statements)

        truthy_scope, falsey_scope = Narrowing.predicate_scopes(node.predicate, post_loop)
        node.is_a?(Prism::UntilNode) ? truthy_scope : falsey_scope
      end

      # True when the loop body can `break` out of THIS loop. Conservatively
      # treats any `BreakNode` under the body as a break for this loop (a
      # break inside a nested loop/block actually targets the inner construct,
      # but bailing is precision-only).
      def loop_body_breaks?(statements)
        return false if statements.nil?

        found = false
        Source::NodeWalker.each(statements) do |descendant|
          found = true if descendant.is_a?(Prism::BreakNode)
        end
        found
      end

      # A `break` inside one of these nested constructs targets the inner
      # construct (an inner loop, a block's method, a nested def), NOT the
      # lexical loop — so the directly-targeting break scan does not descend
      # into them.
      BREAK_BOUNDARY_NODES = [
        Prism::ForNode, Prism::WhileNode, Prism::UntilNode,
        Prism::BlockNode, Prism::LambdaNode, Prism::DefNode,
        Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode
      ].freeze
      private_constant :BREAK_BOUNDARY_NODES

      # The `BreakNode`s that lexically target THIS loop — reachable from the
      # body without crossing a nested loop / block / def boundary. An
      # identity-keyed Hash used as a membership set to filter the collected
      # break scopes (the thread-local sink also collects breaks from nested
      # blocks that did not install their own sink).
      def directly_targeting_breaks(statements)
        found = {}.compare_by_identity
        collect_direct_breaks(statements, found)
        found
      end

      def collect_direct_breaks(node, found)
        return if node.nil?

        found[node] = true if node.is_a?(Prism::BreakNode)
        node.compact_child_nodes.each do |child|
          next if BREAK_BOUNDARY_NODES.any? { |klass| child.is_a?(klass) }

          collect_direct_breaks(child, found)
        end
      end

      # Installs a fresh thread-local break sink around `yield` (a loop-body
      # evaluation), returning `[collected, yield_result]`. Stacks: the
      # previous sink is restored on exit so a nested loop's breaks do not
      # leak to the enclosing loop.
      def collect_break_scopes
        previous = Thread.current[BREAK_SINK_KEY]
        sink = []
        Thread.current[BREAK_SINK_KEY] = sink
        begin
          result = yield
        ensure
          Thread.current[BREAK_SINK_KEY] = previous
        end
        [sink, result]
      end

      # Runs a loop body's single pass under a break sink. Returns the
      # directly-targeting break set, the collected break scopes, and the
      # fall-through body scope — the three inputs the continuation's
      # {#join_break_scopes} needs. Shared by `eval_loop` and `eval_for`.
      def capture_loop_body_breaks(statements, entry)
        targets = directly_targeting_breaks(statements)
        sink, (_type, body_scope) = collect_break_scopes { sub_eval(statements, entry) }
        [targets, sink, body_scope]
      end

      # Joins each directly-targeting break's body-written local bindings into
      # the loop continuation, so a `break`-path binding the fall-through
      # dropped is recovered (`flag = true; break` -> `flag` becomes `false |
      # true`). Only loop-body-written names are joined — an unchanged local
      # unions to itself; a break-only-written local is already present via the
      # fixpoint / nil-injection seed, so the union reflects its break value.
      def join_break_scopes(continuation, sink, targeting, names)
        return continuation if sink.empty? || names.empty?

        breaks = sink.select { |(node, _scope)| targeting.key?(node) }
        breaks.reduce(continuation) do |cont, (_node, break_scope)|
          names.reduce(cont) do |acc, name|
            break_value = break_scope.local(name)
            next acc if break_value.nil?

            current = acc.local(name)
            joined = current ? Type::Combinator.union(current, break_value) : break_value
            acc.with_local(name, joined)
          end
        end
      end

      # Joins loop-body content mutations into the continuation collection
      # bindings. The mutator arguments are typed against `post_loop`, whose
      # locals already carry the loop-body fixpoint widening (so an
      # appended `n` that the loop decrements types `Integer`, not its
      # entry `Constant[3]` — otherwise only the first iteration's value
      # would be captured, an unsound under-approximation). Pre-state is
      # read from `post_loop` too. A loop body shares the surrounding scope,
      # so the receiver is any `LocalVariableReadNode` (no depth filter).
      def loop_content_writeback(statements, post_loop)
        return post_loop if statements.nil?

        mutations = Hash.new { |h, k| h[k] = [] }
        Source::NodeWalker.each(statements) do |descendant|
          name, node = content_mutation_target(descendant) { |_r| true }
          mutations[name] << node unless name.nil?
        end
        return post_loop if mutations.empty?

        mutations.reduce(post_loop) do |acc, (name, calls)|
          joined = join_content_for_local(name, calls, acc, post_loop)
          joined.nil? ? acc : acc.with_local(name, joined)
        end
      end

      # Re-evaluates the loop body once from the converged fixpoint
      # bindings, solely for the `on_enter` side effect of re-recording
      # the body's per-node entry scopes. Gated behind the
      # display-path-only `converged_loop_recording` flag so the check
      # path neither pays the extra body evaluation nor risks any
      # diagnostic drift.
      def record_converged_loop_body(node, post_pred, bindings, names, body_first)
        return unless @converged_loop_recording && @on_enter

        loop_body_exit_bindings(node, post_pred, bindings, names, body_first)
        nil
      end

      # Runs the slice-B loop-body rebind fixpoint, returning the per-name
      # continuation binding. Seed: a pre-existing local seeds with its
      # post-predicate binding; a local FIRST assigned inside the body seeds
      # with `nil` so the 0-iteration path (the body may never run) degrades
      # it to `T | nil`, matching the historical nil-injection treatment.
      def loop_rebind_fixpoint(node, post_pred, names, body_first)
        nil_const = Type::Combinator.constant_of(nil)
        seed = names.to_h { |name| [name, post_pred.local(name) || nil_const] }
        BodyFixpoint.converge(
          names: names,
          seed_bindings: seed,
          widen: Type::Combinator.method(:widen_value_pinned),
          evaluate_body: ->(bindings) { loop_body_exit_bindings(node, post_pred, bindings, names, body_first) }
        )
      end

      # Names of locals the loop body can rebind, partitioned into those
      # already bound in `base_scope` (their pre-loop binding seeds the
      # fixpoint) and those FIRST assigned inside the body (no pre-state, so
      # they seed with `nil` for 0-iteration soundness). A loop body
      # introduces no new binding scope — every write leaks to the
      # surrounding scope — so unlike a block there is no introduced-name
      # filter; every local-write form under the body node counts.
      def loop_body_local_writes(statements, base_scope)
        pre_existing = []
        body_first = []
        Source::NodeWalker.each(statements) do |descendant|
          next unless LOCAL_WRITE_NODES.any? { |klass| descendant.is_a?(klass) }

          name = descendant.name
          if base_scope.locals.key?(name)
            pre_existing << name
          else
            body_first << name
          end
        end
        [pre_existing.uniq, body_first.uniq - pre_existing.uniq]
      end

      # Evaluates the loop body once with each fixpoint-tracked local bound
      # to the supplied running assumption and returns the per-name exit
      # binding. Used as the {BodyFixpoint} body-evaluator for `eval_loop`.
      #
      # The body runs from `post_pred` overlaid with the assumptions, then
      # narrowed by the predicate's loop-entry edge: a `while` body only
      # runs when the predicate is TRUTHY, an `until` body only when it is
      # FALSEY. Re-applying that narrowing per iteration keeps loop-carried
      # narrowing sound — without it, an accumulator whose rebind can
      # introduce `nil` (`prefix = idx ? prefix[0, idx] : nil` under
      # `while prefix && …`) would re-enter the body with `nil` un-narrowed
      # and false-fire `possible nil receiver` on the guarded re-read. The
      # historical single body pass (which seeds these locals from their
      # never-nil pre-loop binding) did not need this; the fixpoint, which
      # feeds the widened assumption back in, does.
      #
      # A body-FIRST local (no pre-loop binding) is deliberately NOT overlaid
      # into the body-entry scope: when the body runs it assigns the local
      # before any use, exactly as the historical single body pass saw it.
      # Its `nil` seed exists only to model the 0-iteration path and is kept
      # as a join constituent by {BodyFixpoint#converge}; feeding that `nil`
      # back into the body re-evaluation would leak it past a condition-form
      # assignment the engine does not thread into the branch (`if exps.size
      # > (count = 3)`), false-firing `+`/nil-receiver on the guarded use.
      def loop_body_exit_bindings(node, post_pred, bindings, names, body_first)
        overlaid = bindings.except(*body_first)
        entry = overlaid.reduce(post_pred) { |acc, (name, type)| acc.with_local(name, type) }
        truthy_scope, falsey_scope = Narrowing.predicate_scopes(node.predicate, entry)
        body_entry = node.is_a?(Prism::UntilNode) ? falsey_scope : truthy_scope
        _type, exit_scope = sub_eval(node.statements, body_entry)
        names.to_h { |name| [name, exit_scope.local(name)] }
      end

      # `for index in collection; body; end`. Unlike `each {}` blocks,
      # `for` does NOT create a new variable scope: the index variable
      # AND every local written in the body leak to the surrounding
      # scope. The collection is evaluated once; the body runs zero or
      # more times, so the post-loop scope is the join of the
      # no-iteration scope (just `post_collection`) and the body scope,
      # with half-bound names degraded to `T | nil` via nil-injection.
      # The loop expression itself types as `Constant[nil]` (the common
      # case where no `break VALUE` is observed), matching the policy
      # `eval_loop` uses for `while` / `until`.
      def eval_for(node)
        coll_type, post_coll = sub_eval(node.collection, scope)
        element_type = for_iteration_element_type(coll_type)
        body_entry = bind_for_index(node.index, element_type, post_coll)

        if node.statements.nil?
          return [Type::Combinator.constant_of(nil), join_with_nil_injection(post_coll, body_entry)]
        end

        # Run the body pass under a break sink so a `break`-path binding the
        # fall-through drops is recovered into the continuation (the `for`
        # sibling of `eval_loop`'s break join; `for` has no fixpoint, so the
        # single-pass join is the only continuation).
        break_targets, break_sink, body_scope = capture_loop_body_breaks(node.statements, body_entry)
        continuation = join_with_nil_injection(post_coll, body_scope)
        pre_existing, body_first = loop_body_local_writes(node.statements, post_coll)
        continuation = join_break_scopes(continuation, break_sink, break_targets, pre_existing + body_first)
        [Type::Combinator.constant_of(nil), continuation]
      end

      # `for x in coll` is semantically `coll.each { |x| ... }`. We
      # ask the method dispatcher for `coll.each`'s expected block
      # parameter types — that path consults RBS and the iterator
      # dispatch table, which is more precise than the structural
      # `collection_element_type` fallback (it knows, e.g., that
      # `Hash[K, V]#each` yields `[K, V]` even when the receiver is
      # not a literal Hash carrier in our local lattice). When the
      # dispatcher returns nothing (no signature, unknown receiver)
      # we fall back to the structural extractor.
      def for_iteration_element_type(coll_type)
        structural = collection_element_type(coll_type)
        return structural unless structural.equal?(Type::Combinator.untyped)

        block_params = MethodDispatcher.expected_block_param_types(
          receiver_type: coll_type,
          method_name: :each,
          arg_types: [],
          environment: scope.environment
        )
        return structural if block_params.nil? || block_params.empty?

        block_params.size == 1 ? block_params.first : Type::Combinator.tuple_of(*block_params)
      rescue StandardError
        Type::Combinator.untyped
      end

      # Binds the `for` index variable(s) into `scope`. A single
      # `LocalVariableTargetNode` is bound to `element_type` (the
      # per-iteration value the collection yields). A `MultiTargetNode`
      # (`for a, b in pairs`) delegates to {MultiTargetBinder}, which
      # decomposes a tuple-shaped element into the inner slots.
      def bind_for_index(index_node, element_type, scope)
        case index_node
        when Prism::LocalVariableTargetNode
          scope.with_local(index_node.name, element_type)
        when Prism::MultiTargetNode
          MultiTargetBinder.bind(index_node, element_type)
                           .reduce(scope) { |s, (name, type)| s.with_local(name, type) }
        else
          scope
        end
      end

      # Extracts the per-iteration element type from a collection
      # carrier. `Tuple[T1..Tn]` yields the union of its elements;
      # `Nominal[Array, [T]]` and `Nominal[Range, [T]]` yield `T`;
      # `Nominal[Hash, [K, V]]` yields `Tuple[K, V]` (Hash#each yields
      # `[key, value]` pairs); `IntegerRange` yields `Integer`;
      # `Constant<Range>` reads the literal range's element class.
      # Anything else falls back to `untyped`.
      def collection_element_type(type)
        case type
        when Type::Tuple
          type.elements.empty? ? Type::Combinator.untyped : Type::Combinator.union(*type.elements)
        when Type::Nominal
          nominal_element_type(type)
        when Type::IntegerRange
          Type::Combinator.nominal_of("Integer")
        when Type::Constant
          constant_element_type(type)
        else
          Type::Combinator.untyped
        end
      end

      def constant_element_type(constant)
        value = constant.value
        case value
        when Range
          first = value.first
          first.nil? ? Type::Combinator.untyped : Type::Combinator.nominal_of(first.class.name)
        when Array
          return Type::Combinator.untyped if value.empty?

          Type::Combinator.union(*value.map { |v| Type::Combinator.constant_of(v) })
        else
          Type::Combinator.untyped
        end
      rescue StandardError
        Type::Combinator.untyped
      end

      def nominal_element_type(nominal)
        args = nominal.type_args
        case nominal.class_name
        when "Array", "Range", "Set", "Enumerator" then args[0] || Type::Combinator.untyped
        when "Hash"
          k = args[0] || Type::Combinator.untyped
          v = args[1] || Type::Combinator.untyped
          Type::Combinator.tuple_of(k, v)
        else Type::Combinator.untyped
        end
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
      #
      # When the RHS is a terminating branch — it `raise`s /
      # `return`s / `throw`s / `exit`s / `break`s / `next`s, OR its
      # inferred type is `Bot` (ADR-24 WD6: a divergent helper such
      # as `a or fail_with_message(...)`, recognised via
      # `branch_terminates?`) — the post-OR / post-AND scope is the
      # LHS-skipped edge alone: `a or raise` only survives when `a`
      # was truthy, so subsequent statements observe `a` narrowed to
      # its truthy fragment; the symmetric `a and raise` survives
      # only when `a` was falsey. Same shape as the `eval_if` /
      # `eval_unless` early-return narrowing.
      def eval_and_or(node)
        left_type, left_scope = sub_eval(node.left, scope)
        truthy_left, falsey_left = Narrowing.predicate_scopes(node.left, left_scope)
        rhs_entry = node.is_a?(Prism::AndNode) ? truthy_left : falsey_left
        right_type, right_scope = sub_eval(node.right, rhs_entry)

        if branch_terminates?(node.right, right_type)
          # Control never reaches any statement after `a or raise`
          # via the RHS edge — the RHS scope is discarded.
          surviving_type =
            if node.is_a?(Prism::AndNode)
              Narrowing.narrow_falsey(left_type)
            else
              Narrowing.narrow_truthy(left_type)
            end
          surviving_scope = node.is_a?(Prism::AndNode) ? falsey_left : truthy_left
          return [surviving_type, surviving_scope]
        end

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
        name = Source::ConstantPath.qualified_name(node.constant_path)
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
        # Parameter default value expressions (e.g. `self.x` in
        # `def copy(x: self.x)`) execute when the method is
        # *invoked*, not when the `def` is read; their `self` is
        # the instance receiver, not the surrounding class body.
        # Walk the parameters subtree under `body_scope` so the
        # scope-index records the instance `self_type` for every
        # node inside parameter defaults. `propagate` would
        # otherwise drop them to the outer class-body scope (where
        # `self_type` is `singleton(C)`), making `self.foo` look
        # like a singleton-side call. Observed surfacing 915 false
        # positives in `prism-1.9.0`'s auto-generated `copy`
        # methods alone.
        # A nested `def` is a return barrier: its body's `return`s belong to
        # the inner method, not the one currently being inferred. Suspend the
        # return sink across the nested body so `eval_return` does not record
        # them into the outer method's return type.
        outer_sink = Thread.current[RETURN_SINK_KEY]
        Thread.current[RETURN_SINK_KEY] = nil
        begin
          sub_eval(node.parameters, body_scope, class_context: @class_context) if node.parameters
          sub_eval(node.body, body_scope, class_context: @class_context) if node.body
        ensure
          Thread.current[RETURN_SINK_KEY] = outer_sink
        end
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
        # ADR-56 slice C (B3) — `each_with_object(memo) { |x, acc| acc << … }`
        # returns the memo; the engine otherwise types the call `Dynamic[top]`.
        # Compute the joined memo type from the block's content mutations of
        # the memo block-param and adopt it as the call's return type.
        call_type = each_with_object_return(node, call_type)
        evaluate_block_if_present(node)
        # `ruby2_keywords def foo(...)` (and similar wrappers like
        # `private def`, `public def`, `module_function def`) parse
        # the def as the call's positional argument; the
        # ExpressionTyper#type_of_def handler types it as
        # `Constant[:foo]` without walking the body. Without
        # explicitly evaluating the argument-position def, the body's
        # scope-index entries inherit the outer class-body
        # `self_type = singleton(C)` from `ScopeIndexer.propagate`,
        # so `self.helper` inside reports `undefined method 'helper'
        # for singleton(C)`. Walking each argument-position def under
        # the current evaluator (not a sub_eval — the def's effects
        # do not bind into the surrounding scope) populates the
        # scope index with the correct instance / singleton
        # `self_type` for the def's body.
        evaluate_def_arguments(node)
        post_scope = record_closure_escape_if_any(node)
        # ADR-56 slice A — non-escaping block captured-local write-back.
        # A `:non_escaping` block (each / times / upto / map …) that
        # rebinds an outer local must not leave that local's pre-call
        # binding unmodified in the continuation scope; the spec MUST in
        # § "Fact stability and mutation" names captured locals a
        # first-class invalidation category. (The escaping / unknown path
        # already widened to Dynamic[top] via `record_closure_escape_if_any`.)
        post_scope = write_back_block_captures(node, post_scope)
        post_scope = apply_rbs_extended_assertions(node, post_scope)
        post_scope = apply_plugin_assertions(node, post_scope)
        post_scope = apply_rspec_matcher_narrowing(node, post_scope)
        # Flow-folding G1 / G2 — widen a local- or instance-variable
        # binding when the call is an in-place mutator on it (e.g.
        # `arms << x`, `@tags << hashtag`). Stops a literal-shape
        # carrier (`Tuple` / `HashShape`) from outliving its
        # justification when the value is mutated. Always-safe
        # (loses precision, never invents facts).
        post_scope = MutationWidening.widen_after_call(call_node: node, current_scope: post_scope)
        # ADR-57 slice 3 work-item 1 (cross-method-boundary variant). When a
        # self-call resolves to a user method that CONTENT-mutates one of its
        # parameters inside an escaping block (the `build_option_parser(opts)`
        # idiom — the callee returns an `OptionParser` whose
        # `opts.on { o[:k] = v }` blocks close over the passed-in hash), floor
        # the matching caller-argument local. The callee's escape is invisible
        # across the boundary, so without this the caller's `options` keeps its
        # seed and `options.fetch(:mode)` folds to a wrong constant. Precise:
        # fires only when the resolved callee actually escape-mutates that
        # parameter (not for every self-call), and sound — only loses
        # precision on the floored argument.
        post_scope = widen_callee_escaped_argument_captures(node, post_scope)
        # Same always-safe rationale as `widen_after_call` above —
        # propagates outer-scope local / ivar widening from block body
        # mutations (`items.each { |x| arr << x }`).
        post_scope = MutationWidening.widen_after_block(call_node: node, outer_scope: post_scope)
        # ADR-56 slice C — receiver-content element-type join. Joins
        # appended / stored element / key / value types into the
        # continuation collection so `out = [0]; arr.each { |x| out << x }`
        # types `Array[0 | Integer]`, not `Array[0]`. Same always-safe
        # rationale (only widens).
        post_scope = content_writeback_block_captures(node, post_scope)
        # Indexed-collection narrowing — drop any
        # `receiver[key] ||= default` narrowing the analyzer
        # recorded earlier when an intervening `[]=` writes the
        # same slot or any other mutator runs against the
        # receiver. Always-safe (only forgets; never invents).
        post_scope = IndexedNarrowing.invalidate_after_call(call_node: node, current_scope: post_scope)
        # Single-hop method-chain narrowing — drop every
        # `(receiver, *)` chain narrowing rooted at the call's
        # outer stable receiver (any-call-against-the-root
        # invalidation rule, B2 from the slice's design
        # notes). Calls whose outer receiver is itself a chain
        # node (e.g. `x.last << y`) do NOT drop narrowings
        # keyed on `x` — only direct calls against the root
        # variable invalidate the chain.
        post_scope = IndexedNarrowing.invalidate_chain_after_call(call_node: node, current_scope: post_scope)
        # B2.2 — intervening method call ivar invalidation.
        # An implicit-self / self-receiver call could mutate any
        # ivar of the enclosing class (we cannot prove purity
        # without an effect system). Reset each ivar whose
        # current local binding has narrowed below the class-ivar
        # seed back to the seed itself, so a subsequent
        # `if @flag` predicate observes the seed's union (not the
        # pre-call narrowed value). Always-safe (only widens; no
        # new facts). See [`docs/CURRENT_WORK.md`](../../../docs/CURRENT_WORK.md)
        # § "Flow-folding" — G2 intervening-call case.
        post_scope = invalidate_ivars_for_intervening_call(node, post_scope)
        # C1 — regex match-data globals (`$~`, `$1..$9`, `$&`, …) are
        # narrowed to non-nil on a successful-match edge; a later call
        # that itself runs a regex match rebinds them, so the narrowed
        # facts must be dropped. We forget them only when the call is
        # match-CAPABLE (a regex-matching method, or an implicit-self /
        # unknown-receiver call whose body we cannot prove match-free).
        # A call provably match-free on a known receiver — `$3.to_i`,
        # `year < 50` — does NOT clobber, so the multi-statement
        # `m = /…/ =~ s; …; use($2)` stdlib idiom keeps its precision
        # while a genuinely interposed match still invalidates.
        post_scope = post_scope.forget_match_globals if match_capable_call?(node)
        [call_type, post_scope]
      end

      # Method names that (may) run a regex match and therefore rebind
      # the `$~` family. Conservative over-approximation — a few set
      # globals only with a Regexp argument, but we do not inspect args.
      MATCH_CAPABLE_METHODS = %i[
        =~ match match? gsub gsub! sub sub! scan split slice slice!
        [] partition rpartition index rindex === grep grep_v
      ].freeze
      private_constant :MATCH_CAPABLE_METHODS

      # True when `node` could rebind the regex match-data globals:
      # a known regex-matching method by name, or an implicit-self /
      # self-receiver call whose body we cannot inspect for an internal
      # match. An explicit-receiver call to a non-matching method
      # (`$3.to_i`, `year < 50`, `buf << c`) is treated as match-free so
      # the multi-statement `m = /…/ =~ s; …; use($2)` idiom keeps the
      # narrowed globals. The over-approximation is one-directional: a
      # user method that secretly matches on an explicit receiver is the
      # only escape, and re-narrowing on the next real guard recovers —
      # weighed against the false-positive cost, precision wins here.
      def match_capable_call?(node)
        return true unless node.is_a?(Prism::CallNode)
        return true if MATCH_CAPABLE_METHODS.include?(node.name)

        receiver = node.receiver
        receiver.nil? || receiver.is_a?(Prism::SelfNode)
      end

      # Returns a scope with each ivar's narrowed local binding
      # widened back to its class-ivar seed value when the call
      # is one that could plausibly mutate ivars on the enclosing
      # class (implicit-self or explicit `self.foo`). External-
      # receiver calls (`obj.method`) cannot reach the caller's
      # ivars; they pass through unchanged.
      def invalidate_ivars_for_intervening_call(call_node, current_scope)
        return current_scope unless intervening_call_candidate?(call_node)

        class_name = enclosing_class_name_for(current_scope.self_type)
        return current_scope if class_name.nil?

        seed = current_scope.class_ivars_for(class_name)
        return current_scope if seed.empty?

        seed.reduce(current_scope) do |acc, (ivar_name, seed_type)|
          local_type = current_scope.ivar(ivar_name)
          next acc if local_type.nil? || local_type == seed_type

          acc.with_ivar(ivar_name, Type::Combinator.union(local_type, seed_type))
        end
      end

      def intervening_call_candidate?(call_node)
        return false unless call_node.is_a?(Prism::CallNode)

        receiver = call_node.receiver
        receiver.nil? || receiver.is_a?(Prism::SelfNode)
      end

      def enclosing_class_name_for(self_type)
        case self_type
        when Type::Nominal, Type::Singleton then self_type.class_name
        end
      end

      def evaluate_def_arguments(call_node)
        args = call_node.arguments
        return unless args.respond_to?(:arguments)

        args.arguments.each do |arg|
          eval_def(arg) if arg.is_a?(Prism::DefNode)
        end
      end

      # v0.0.3 — recognises a small catalogue of RSpec
      # matcher patterns as assert-shaped narrows on the
      # local passed to `expect(...)`. The pattern is
      # matched purely on AST shape; no RBS for RSpec is
      # required (and none is shipped today).
      #
      # Recognised today:
      #
      #   expect(x).not_to(be_nil)
      #   expect(x).to_not(be_nil)
      #     → narrow `x` AWAY from `NilClass`.
      #
      #   expect(x).to(be_a(C))
      #   expect(x).to(be_kind_of(C))
      #   expect(x).to(be_an_instance_of(C))
      #     → narrow `x` to `C` (exact for
      #       `be_an_instance_of`, subtype-permitting
      #       otherwise).
      #
      # Anything else is silently passed through. Symmetric
      # negative class assertions (`not_to be_a(C)`) and
      # narrowing TO `NilClass` are intentionally NOT
      # modelled: they are rarely useful in practice and
      # risk masking bugs if the assertion later fails.
      def apply_rspec_matcher_narrowing(call_node, current_scope)
        narrow = rspec_matcher_narrowing_request(call_node)
        return current_scope if narrow.nil?

        local_name = narrow.fetch(:local)
        current_type = current_scope.local(local_name)
        return current_scope if current_type.nil?

        narrowed = apply_rspec_narrow(current_type, narrow, current_scope.environment)
        current_scope.with_local(local_name, narrowed)
      end

      # Decodes an `expect(x).<chain>` outer call into a
      # narrowing request hash, or `nil` when the shape is
      # not recognised. The hash carries `:local` (the local
      # name being narrowed) plus the narrowing parameters.
      def rspec_matcher_narrowing_request(call_node)
        local_name = rspec_expectation_target(call_node)
        return nil if local_name.nil?

        case call_node.name
        when :not_to, :to_not
          rspec_negative_narrow(call_node, local_name)
        when :to
          rspec_positive_narrow(call_node, local_name)
        end
      end

      def rspec_negative_narrow(call_node, local_name)
        return nil unless rspec_matcher_argument?(call_node, :be_nil)

        { local: local_name, kind: :not_class, class_name: "NilClass", exact: false }
      end

      def rspec_positive_narrow(call_node, local_name)
        matcher = rspec_matcher_node(call_node)
        return nil if matcher.nil?

        case matcher.name
        when :be_a, :be_kind_of
          rspec_be_a_narrow(matcher, local_name, exact: false)
        when :be_an_instance_of, :be_instance_of
          rspec_be_a_narrow(matcher, local_name, exact: true)
        end
      end

      # `be_a` / `be_kind_of` / `be_an_instance_of` accept a
      # single class argument — either a `ConstantReadNode`
      # (`Integer`) or a `ConstantPathNode` (`Rigor::Type::Nominal`).
      def rspec_be_a_narrow(matcher, local_name, exact:)
        args = matcher.arguments&.arguments || []
        return nil unless args.size == 1

        class_name = Source::ConstantPath.qualified_name_or_nil(args.first)
        return nil if class_name.nil?

        { local: local_name, kind: :class, class_name: class_name, exact: exact }
      end

      def apply_rspec_narrow(current_type, narrow, environment)
        case narrow.fetch(:kind)
        when :not_class
          Narrowing.narrow_not_class(current_type, narrow.fetch(:class_name),
                                     exact: narrow.fetch(:exact), environment: environment)
        when :class
          Narrowing.narrow_class(current_type, narrow.fetch(:class_name),
                                 exact: narrow.fetch(:exact), environment: environment)
        end
      end

      # Returns the local name passed to `expect(...)` when
      # the receiver chain matches `expect(<local>)` exactly,
      # or nil otherwise. Centralised so each per-matcher
      # decoder can short-circuit on a non-matching outer
      # call.
      def rspec_expectation_target(call_node)
        receiver = call_node.receiver
        return nil unless receiver.is_a?(Prism::CallNode) && receiver.name == :expect
        return nil unless receiver.receiver.nil?

        args = receiver.arguments&.arguments || []
        return nil unless args.size == 1

        target = args.first
        target.is_a?(Prism::LocalVariableReadNode) ? target.name : nil
      end

      def rspec_matcher_node(call_node)
        args = call_node.arguments&.arguments || []
        return nil unless args.size == 1

        matcher = args.first
        return nil unless matcher.is_a?(Prism::CallNode) && matcher.receiver.nil? && matcher.block.nil?

        matcher
      end

      # True when `call_node`'s sole argument is an
      # implicit-self matcher call with the given name and
      # no positional arguments — used by the no-arg
      # matchers (`be_nil`).
      def rspec_matcher_argument?(call_node, matcher_name)
        matcher = rspec_matcher_node(call_node)
        return false if matcher.nil?
        return false unless matcher.name == matcher_name

        matcher.arguments.nil? || matcher.arguments.arguments.empty?
      end

      # Slice 4b-2 (ADR-7 § "Slice 4-A/4-B") — applies the
      # post-return facts the merger produces for an
      # `RBS::Extended`-annotated call. Reads through
      # `RbsExtended.read_flow_contribution` so the bundle
      # carries the canonical `Rigor::FlowContribution::Fact`
      # rows for `:always` assert directives (the slice-4a
      # routing places conditional asserts on `truthy_facts` /
      # `falsey_facts`, which `Narrowing.predicate_scopes`
      # consumes). Plugin `:always` assertions are handled by
      # the sibling `apply_plugin_assertions`, not this path.
      def apply_rbs_extended_assertions(call_node, current_scope)
        method_def = resolve_call_method(call_node, current_scope)
        return current_scope if method_def.nil?

        contribution = RbsExtended.read_flow_contribution(method_def, environment: current_scope.environment)
        return current_scope if contribution.nil?

        result = Rigor::FlowContribution::Merger.merge([contribution])
        post_return = result.post_return_facts
        return current_scope if post_return.empty?

        post_return.reduce(current_scope) do |scope_acc, fact|
          apply_post_return_fact(fact, call_node, scope_acc, method_def)
        end
      end

      # ADR-7 § "Slice 4-A" / T.bind priority slice 2 — applies
      # the post-return facts plugin contributions produce. This
      # is the sibling of {apply_rbs_extended_assertions}: the
      # carrier (`Rigor::FlowContribution::Fact`) and the
      # downstream narrowing path (`apply_post_return_fact` →
      # `apply_self_post_return_fact`) are the same; only the
      # *source* of the bundle changes (RBS::Extended vs the
      # registered plugins' `flow_contribution_for`).
      #
      # `:self`-targeted facts narrow `scope.self_type` for the
      # surrounding scope. In a block body, the surrounding
      # scope is the block's own scope, so the narrowing applies
      # to the rest of the block — exactly the contract Sorbet's
      # `T.bind(self, T)` commits to.
      #
      # `:parameter`-targeted facts only land when the called
      # method has an authoritative RBS sig (via
      # `resolve_call_method`); plugins recognising their own
      # synthetic call shapes (e.g. `T.assert_type!`) have no
      # method_def and the parameter facts silently skip — the
      # plugin's own diagnostics_for_file path covers those
      # cases. The full plugin-side parameter-targeting story
      # (PHPStan-style Type-Specifying Extensions on
      # plugin-recognised calls) lives behind a follow-up slice
      # that introduces `:local` / `:argument_at` target kinds.
      def apply_plugin_assertions(call_node, current_scope)
        registry = current_scope.environment&.plugin_registry
        return current_scope if registry.nil? || registry.empty?

        contributions = collect_plugin_contributions(registry, call_node, current_scope)
        return current_scope if contributions.empty?

        result = Rigor::FlowContribution::Merger.merge(contributions)
        post_return = result.post_return_facts
        return current_scope if post_return.empty?

        method_def = resolve_call_method(call_node, current_scope)
        post_return.reduce(current_scope) do |scope_acc, fact|
          apply_post_return_fact(fact, call_node, scope_acc, method_def)
        end
      end

      # ADR-37 slice 2 / ADR-52 WD3 — gathers each plugin's post-return
      # narrowing from the method-gated `narrowing_facts` DSL, wrapped as
      # a facts-only `FlowContribution`, swallowing per-plugin
      # exceptions so a buggy plugin can't abort the assertion path.
      EMPTY_CONTRIBUTIONS = [].freeze
      private_constant :EMPTY_CONTRIBUTIONS

      # Fast-exit guard: skip if no plugin declares a `narrowing_facts` rule, or if
      # no registered method-name gate matches the call. See
      # `collect_gated_statement_contributions` for the full consultation.
      def collect_plugin_contributions(registry, call_node, current_scope)
        index = registry.contribution_index
        relevant = index.for_statement
        return EMPTY_CONTRIBUTIONS if relevant.empty?

        name = call_node.respond_to?(:name) ? call_node.name : nil
        return EMPTY_CONTRIBUTIONS unless index.statement_candidate?(name)

        collect_gated_statement_contributions(index, relevant, name, call_node, current_scope)
      end

      # ADR-37 slice 2 / ADR-52 WD1 — post-gate walk in registry order.
      # Visits only plugins in `for_statement` (declare a `narrowing_facts` rule),
      # further gated by the method-name Set probe so the common no-candidate
      # case is a single lookup. Accumulates lazily; caller is read-only.
      def collect_gated_statement_contributions(index, relevant, name, call_node, current_scope)
        result = nil
        relevant.each do |plugin|
          next unless index.type_specifier_candidate_for?(plugin, name)

          facts = plugin.type_specifier_facts(call_node: call_node, scope: current_scope)
          (result ||= []) << Rigor::FlowContribution.new(post_return_facts: facts) if facts && !facts.empty?
        rescue StandardError
          next
        end
        result || EMPTY_CONTRIBUTIONS
      end

      def resolve_call_method(call_node, current_scope)
        receiver_node = call_node.receiver
        receiver_type =
          if receiver_node
            current_scope.type_of(receiver_node, tracer: tracer)
          else
            current_scope.self_type
          end
        return nil if receiver_type.nil?

        class_name = assertion_class_name(receiver_type)
        return nil if class_name.nil?
        return nil unless Rigor::Reflection.rbs_class_known?(class_name, scope: current_scope)

        if receiver_type.is_a?(Type::Singleton)
          Rigor::Reflection.singleton_method_definition(class_name, call_node.name, scope: current_scope)
        else
          Rigor::Reflection.instance_method_definition(class_name, call_node.name, scope: current_scope)
        end
      rescue StandardError
        nil
      end

      def assertion_class_name(receiver_type)
        case receiver_type
        when Type::Nominal, Type::Singleton then receiver_type.class_name
        end
      end

      # Slice 4b-2 — applies a single post-return Fact to the
      # scope. Mirrors `Narrowing#apply_fact_to_scope` (Fact
      # variant of the v0.0.2 `apply_assert_effect`); shares the
      # narrowing logic via `Narrowing.narrow_for_fact` so the
      # predicate / assert / plugin paths all converge on the
      # same hierarchy-aware narrowing rules.
      #
      # v0.1.8 Pillar 2 Slice 1 added the `:local` target_kind
      # branch so plugins recognising bespoke call shapes
      # (`expect(x).to be_a(T)`) can directly narrow a named
      # local in the surrounding scope, bypassing the
      # parameter-name lookup that requires an authoritative RBS
      # sig on the called method (which RSpec matchers lack).
      def apply_post_return_fact(fact, call_node, current_scope, method_def)
        return apply_local_post_return_fact(fact, current_scope) if fact.target_kind == :local

        target_node = fact_target_node(fact, call_node, method_def)
        return apply_self_post_return_fact(fact, target_node, current_scope) if fact.target_kind == :self
        return current_scope unless target_node.is_a?(Prism::LocalVariableReadNode)

        local_name = target_node.name
        current_type = current_scope.local(local_name)
        return current_scope if current_type.nil?

        narrowed = Narrowing.narrow_for_fact(current_type, fact, current_scope.environment)
        current_scope.with_local(local_name, narrowed)
      end

      # v0.1.8 Pillar 2 Slice 1 — narrows the named local directly
      # without consulting the call node's argument list. The fact's
      # `target_name` is the local-variable name as written in
      # source. Silently no-ops when the local is unbound in the
      # current scope (the plugin's named local may have already
      # gone out of scope when the contribution fires).
      def apply_local_post_return_fact(fact, current_scope)
        local_name = fact.target_name
        current_type = current_scope.local(local_name)
        return current_scope if current_type.nil?

        narrowed = Narrowing.narrow_for_fact(current_type, fact, current_scope.environment)
        current_scope.with_local(local_name, narrowed)
      end

      # v0.1.1 Track 1 slice 3 — `assert self is T` post-return
      # narrowing for the four supported receiver shapes (mirrors
      # `Narrowing#apply_self_fact`).
      def apply_self_post_return_fact(fact, receiver_node, current_scope)
        case receiver_node
        when nil, Prism::SelfNode
          current = current_scope.self_type
          return current_scope if current.nil?

          narrowed = Narrowing.narrow_for_fact(current, fact, current_scope.environment)
          current_scope.with_self_type(narrowed)
        when Prism::LocalVariableReadNode
          current = current_scope.local(receiver_node.name)
          return current_scope if current.nil?

          narrowed = Narrowing.narrow_for_fact(current, fact, current_scope.environment)
          current_scope.with_local(receiver_node.name, narrowed)
        when Prism::InstanceVariableReadNode
          current = current_scope.ivar(receiver_node.name)
          return current_scope if current.nil?

          narrowed = Narrowing.narrow_for_fact(current, fact, current_scope.environment)
          current_scope.with_ivar(receiver_node.name, narrowed)
        else
          current_scope
        end
      end

      # `:self` routes to the call receiver; otherwise we look
      # up the matching positional argument by parameter name.
      def fact_target_node(fact, call_node, method_def)
        if fact.target_kind == :self
          call_node.receiver
        else
          lookup_post_return_arg(call_node, method_def, fact.target_name)
        end
      end

      def lookup_post_return_arg(call_node, method_def, target_name)
        # Plugin-source contributions arrive without an
        # authoritative method_def (the plugin recognised the
        # call shape directly). Parameter-targeting falls back
        # to "no narrow" in that case — the wider plugin-side
        # parameter mapping (`:local` / `:argument_at`) is a
        # follow-up slice.
        return nil if method_def.nil?

        arguments = call_node.arguments&.arguments || []
        method_def.method_types.each do |mt|
          params = mt.type.required_positionals + mt.type.optional_positionals
          index = params.find_index { |param| param.name == target_name }
          return arguments[index] if index && arguments[index]
        end
        nil
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
        # ADR-57 slice 3 work-item 1: an escaping block can also be attached
        # to a RECEIVER call in a chain rather than to `node` itself — the
        # canonical `OptionParser.new do |opts| opts.on { o[:k] = v } end
        # .parse!(argv)` idiom, where the content-mutating block hangs off
        # `OptionParser.new` but the statement-level call node is the chained
        # `.parse!`. A receiver call is evaluated as an expression, never as a
        # statement, so its block never reaches this escape handler on its own.
        # Fold each escaping receiver-chain block's content widening into the
        # continuation here so the captured collection is floored regardless of
        # how deep in the receiver chain its mutating block lives.
        post_scope = widen_escaping_receiver_chain_captures(node, scope)

        return post_scope unless node.block.is_a?(Prism::BlockNode)

        classification = classify_closure_escape(node)
        return post_scope if classification == :non_escaping

        post_scope = drop_captured_narrowing(node.block, post_scope)
        post_scope = widen_escaping_content_captures(node.block, post_scope)
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

      # Floor each caller-argument local whose matching parameter the resolved
      # callee escape-mutates (see the call-site comment). Only self-dispatch
      # calls resolving to a discovered user def are considered; the per-def
      # "which parameters escape-mutate" set is memoised on the def node.
      def widen_callee_escaped_argument_captures(node, base_scope)
        # Apply to the statement call AND every call in its receiver chain: the
        # `build_option_parser(options).parse!(argv)` idiom puts the escape-
        # mutating helper call in the RECEIVER position, where its argument is
        # never the statement node's own argument.
        acc = floor_callee_escaped_args_for_call(node, base_scope)
        receiver = node.receiver
        while receiver.is_a?(Prism::CallNode)
          acc = floor_callee_escaped_args_for_call(receiver, acc)
          receiver = receiver.receiver
        end
        acc
      end

      def floor_callee_escaped_args_for_call(node, base_scope)
        return base_scope unless self_dispatch_call?(node)
        # Fast path — the floor only ever touches a local passed as an
        # argument, so a call with no arguments cannot floor anything. Skip the
        # def resolution + body scan entirely (the overwhelming common case).
        return base_scope unless call_passes_local_argument?(node)

        def_node = resolve_self_callee_def(node)
        return base_scope if def_node.nil?

        escaped = escaped_content_parameters(def_node)
        return base_scope if escaped.empty?

        floor_arguments_at_positions(node, escaped, base_scope)
      end

      # The user def a self-dispatch `node` resolves to in the enclosing class,
      # or nil. Reuses the discovery index `Scope#user_def_for` reads; no
      # ancestor walk (the boundary-escape idiom is same-class), keeping this
      # off the hot path for the overwhelming majority of self-calls that
      # resolve to nothing escaping.
      def resolve_self_callee_def(node)
        class_name = enclosing_class_name_for(scope.self_type)
        return scope.top_level_def_for(node.name) if class_name.nil?

        scope.user_def_for(class_name, node.name)
      end

      def self_dispatch_call?(node)
        return false unless node.is_a?(Prism::CallNode)

        node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)
      end

      # The set of `[name, position]` parameters of `def_node` whose content a
      # block in the body escape-mutates. Memoised per def node (the body walk
      # is otherwise repeated at every call site). A parameter is "escape-
      # mutated" when a `param[k] = v` / `param << x` mutation on it appears
      # inside a block whose receiving call is not proven non-escaping.
      def escaped_content_parameters(def_node)
        cache = (@escaped_param_cache ||= {}.compare_by_identity)
        cache[def_node] ||= compute_escaped_content_parameters(def_node)
      end

      def compute_escaped_content_parameters(def_node)
        positions = positional_parameter_positions(def_node)
        return {} if positions.empty?

        mutated = Set.new
        Source::NodeWalker.each(def_node.body) do |descendant|
          next unless descendant.is_a?(Prism::CallNode) && descendant.block.is_a?(Prism::BlockNode)
          next if syntactically_non_escaping_call?(descendant)

          collect_content_mutations(descendant.block.body).each_key do |name|
            mutated << name if positions.key?(name)
          end
        end
        positions.slice(*mutated)
      end

      # A receiver-independent over-approximation of `ClosureEscapeAnalyzer`'s
      # non-escaping verdict, used when scanning a callee body where the block-
      # owning call's receiver TYPE is not available. A call whose method name
      # is a known structural iterator (`each` / `map` / `tap` / …) runs its
      # block synchronously and does not retain it, so its captured mutations
      # are not a cross-boundary escape. Any other name (`on`, `subscribe`,
      # `define_method`, an unknown DSL hook) is treated as escaping — sound,
      # since mis-classifying a truly-non-escaping call only floors an argument
      # that was about to be precise.
      SYNTACTIC_NON_ESCAPING_BLOCK_METHODS = (
        ClosureEscapeAnalyzer::ENUMERABLE_NON_ESCAPING +
        ClosureEscapeAnalyzer::OBJECT_NON_ESCAPING +
        ClosureEscapeAnalyzer::ARRAY_EXTRA +
        ClosureEscapeAnalyzer::HASH_EXTRA +
        ClosureEscapeAnalyzer::RANGE_EXTRA +
        ClosureEscapeAnalyzer::INTEGER_EXTRA
      ).to_set.freeze
      private_constant :SYNTACTIC_NON_ESCAPING_BLOCK_METHODS

      def syntactically_non_escaping_call?(call_node)
        SYNTACTIC_NON_ESCAPING_BLOCK_METHODS.include?(call_node.name)
      end

      # `{ name => position }` for the required / optional positional
      # parameters of a def. Keyword / rest / block parameters are skipped —
      # the boundary-escape idiom passes a plain positional collection.
      def positional_parameter_positions(def_node)
        params = def_node.parameters
        return {} if params.nil?

        ordered = (params.requireds || []) + (params.optionals || [])
        positions = {}
        ordered.each_with_index do |param, index|
          positions[param.name] = index if param.respond_to?(:name)
        end
        positions
      end

      # True when at least one argument of `node` is a bare local-variable read
      # (positional or keyword value) bound in the current scope — a cheap
      # pre-filter so the def resolution / body scan only runs for calls that
      # could actually floor something.
      def call_passes_local_argument?(node)
        args = node.arguments
        return false unless args.respond_to?(:arguments)

        args.arguments.any? do |arg|
          case arg
          when Prism::LocalVariableReadNode
            scope.locals.key?(arg.name)
          when Prism::KeywordHashNode
            arg.elements.any? do |pair|
              pair.is_a?(Prism::AssocNode) &&
                pair.value.is_a?(Prism::LocalVariableReadNode) &&
                scope.locals.key?(pair.value.name)
            end
          else
            false
          end
        end
      end

      def floor_arguments_at_positions(node, positions, base_scope)
        args = node.arguments
        return base_scope unless args.respond_to?(:arguments)

        argument_nodes = args.arguments
        positions.values.uniq.reduce(base_scope) do |acc, index|
          arg = argument_nodes[index]
          next acc unless arg.is_a?(Prism::LocalVariableReadNode) && acc.locals.key?(arg.name)

          floored = content_floor_for(acc.local(arg.name))
          floored.nil? ? acc : acc.with_local(arg.name, floored)
        end
      end

      # Walk the receiver chain of `node` and fold the escaping-content
      # widening of every block-bearing, escaping receiver call into
      # `base_scope`. Only receiver calls are walked — `node` itself is handled
      # by the caller. A `:non_escaping` receiver block is left to slice C's
      # non-escaping write-back (which the receiver expression evaluation
      # already drives), so we only floor the escaping / unknown ones here.
      def widen_escaping_receiver_chain_captures(node, base_scope)
        receiver = node.receiver
        acc = base_scope
        while receiver.is_a?(Prism::CallNode)
          if receiver.block.is_a?(Prism::BlockNode) &&
             classify_closure_escape(receiver) != :non_escaping
            acc = widen_escaping_content_captures(receiver.block, acc)
          end
          receiver = receiver.receiver
        end
        acc
      end

      # ADR-57 slice 2 (ADR-56 mechanisms 2 / 8 extended to escaping blocks).
      # An escaping / unknown block that CONTENT-mutates a captured outer
      # local (`options[:k] = v` in an `OptionParser#on` block, `s << x` in a
      # stored proc) previously left that local's content untouched — only its
      # narrowing was dropped, so a constant seed (`options = {}`, `s = ""`)
      # survived and its element fold (`options[:format]` -> `"text"`,
      # `s.empty?` -> `true`) was unsoundly precise.
      #
      # An escaping block may run later and any number of times, so joining a
      # bounded evidence set is not sound (unlike slice C's non-escaping
      # join): the sound continuation is the bare-collection floor — Array ->
      # `Array[Dynamic[top]]`, Hash -> `Hash[untyped, untyped]`, String ->
      # `String`. The seed's element/key/value precision is forgotten; only
      # the carrier survives. Read-only captures and locals the block merely
      # rebinds (already floored by `drop_captured_narrowing`) are untouched.
      def widen_escaping_content_captures(block_node, post_scope)
        body = block_node.body
        return post_scope if body.nil?

        # Transitive case first: the body may content-mutate a captured local
        # through a self-call rather than a direct `local[k] = v` write, which
        # `collect_content_mutations` cannot see (see below).
        post_scope = floor_block_body_callee_escaped_args(body, post_scope)

        mutations = collect_content_mutations(body)
        return post_scope if mutations.empty?

        mutations.keys.reduce(post_scope) do |acc, name|
          floored = content_floor_for(acc.local(name))
          floored.nil? ? acc : acc.with_local(name, floored)
        end
      end

      # Inside an ESCAPING block body, a captured outer local can be content-
      # mutated transitively: the body is (or contains) a self-call that
      # escape-mutates one of its arguments. The canonical shape is the CLI's
      # own `OptionParser.new { |opts| define_options(opts, options) }` — the
      # block body is a bare `define_options(opts, options)` whose `options`
      # parameter is escape-mutated inside ITS nested `opts.on { options[:k] =
      # v }` blocks. `collect_content_mutations` only sees direct `local[k] =
      # v` writes in THIS body, so it misses the transitive write and the
      # captured Hash keeps its literal-false seed (folding the caller's
      # `options[:mutation]` guard to an always-falsey constant). Reuse the
      # cross-method-boundary callee-escaped-argument floor (the same gate the
      # receiver-chain path uses at the call site) on every self-call in the
      # body. Sound — only ever floors a captured local passed as an argument
      # to a callee that demonstrably escape-mutates the matching parameter.
      def floor_block_body_callee_escaped_args(body, post_scope)
        acc = post_scope
        Source::NodeWalker.each(body) do |descendant|
          acc = floor_callee_escaped_args_for_call(descendant, acc) if descendant.is_a?(Prism::CallNode)
        end
        acc
      end

      # The Dynamic-floor carrier for a content-mutated escaping capture, or
      # nil when the pre-state is not a recognised mutable collection (leave
      # it alone — e.g. an already-`Dynamic` binding or an unknown shape).
      def content_floor_for(type)
        return nil if type.nil?

        if stringish?(type)
          Type::Combinator.nominal_of("String")
        elsif hashish?(type)
          Type::Combinator.nominal_of("Hash",
                                      type_args: [Type::Combinator.untyped,
                                                  Type::Combinator.untyped])
        elsif arrayish?(type)
          Type::Combinator.nominal_of("Array", type_args: [Type::Combinator.untyped])
        end
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

      # Names of outer locals the block body can REBIND, across every
      # local-write form: plain `=` (`LocalVariableWriteNode`), the
      # operator / `||=` / `&&=` compound forms, and a multi-assign target
      # (`x, y = ...` → `LocalVariableTargetNode` under `MultiWriteNode`).
      # Block-introduced names (parameters, numbered params, `;`-locals) and
      # names not bound in the outer scope are excluded — a write to either
      # is not a captured rebind of an outer variable.
      LOCAL_WRITE_NODES = [
        Prism::LocalVariableWriteNode,
        Prism::LocalVariableOperatorWriteNode,
        Prism::LocalVariableOrWriteNode,
        Prism::LocalVariableAndWriteNode,
        Prism::LocalVariableTargetNode
      ].freeze
      private_constant :LOCAL_WRITE_NODES

      def captured_local_writes(block_node, base_scope)
        body = block_node.body
        return [] if body.nil?

        introduced = block_introduced_locals(block_node)
        outer_writes = []
        Source::NodeWalker.each(body) do |descendant|
          next unless LOCAL_WRITE_NODES.any? { |klass| descendant.is_a?(klass) }
          next if introduced.include?(descendant.name)
          next unless base_scope.locals.key?(descendant.name)

          outer_writes << descendant.name
        end
        outer_writes.uniq
      end

      # ADR-56 slice A. For a `:non_escaping` block, fold the continuation
      # binding of every outer local the body can rebind back into
      # `post_scope`. The binding is a capped fixpoint (cap 3) over the
      # block body re-evaluated under the running per-name assumption,
      # joined with the pre-call binding (kept as a constituent so the
      # 0-iteration path — `[].each { … }` — stays sound), value-pinned-
      # widened on the final permitted iteration, and floored to
      # `Dynamic[top]` on non-convergence (matching `drop_captured_narrowing`).
      #
      # Fast path: a block writing no outer local leaves `post_scope`
      # byte-identical (the overwhelming majority of blocks), so this costs
      # one extra `captured_local_writes` walk and nothing else.
      def write_back_block_captures(call_node, post_scope)
        block = call_node.block
        return post_scope unless block.is_a?(Prism::BlockNode)
        return post_scope unless classify_closure_escape(call_node) == :non_escaping

        names = captured_local_writes(block, scope)
        return post_scope if names.empty?

        seed = names.to_h { |name| [name, scope.local(name)] }
        result = BodyFixpoint.converge(
          names: names,
          seed_bindings: seed,
          widen: Type::Combinator.method(:widen_value_pinned),
          evaluate_body: ->(bindings) { block_exit_bindings(call_node, block, bindings, names) }
        )

        result.reduce(post_scope) { |acc, (name, type)| acc.with_local(name, type) }
      end

      # ADR-56 slice C — receiver-content element-type join. After the
      # rebind write-back and `MutationWidening.widen_after_block` (which
      # forgets a content-mutated collection's literal arity but keeps only
      # the SEED's element types), join the appended/stored element / key /
      # value types INTO the continuation collection's parameter, so
      # `out = [0]; arr.each { |x| out << x }` types `out` as
      # `Array[0 | Integer]` (sound) rather than `Array[0]` (the B1
      # under-approximation: the runtime array is `[0, 1, 2, 3]`).
      #
      # Pre-state is read from `post_scope` so a local that is BOTH rebound
      # and content-mutated composes: the rebind fixpoint result feeds the
      # content join. The block body is typed once for argument evidence;
      # the floor is `Array[Dynamic[top]]` / `Hash[untyped, untyped]` (the
      # sound empty-seed behaviour). Always sound — only ever widens.
      def content_writeback_block_captures(call_node, post_scope)
        block = call_node.block
        return post_scope unless block.is_a?(Prism::BlockNode)
        return post_scope unless classify_closure_escape(call_node) == :non_escaping

        body = block.body
        return post_scope if body.nil?

        mutations = collect_content_mutations(body)
        return post_scope if mutations.empty?

        entry = build_block_entry_scope(call_node, block)
        mutations.reduce(post_scope) do |acc, (name, calls)|
          joined = join_content_for_local(name, calls, acc, entry)
          joined.nil? ? acc : acc.with_local(name, joined)
        end
      end

      # ADR-56 slice C (B3). For `recv.each_with_object(memo) { |x, acc| … }`
      # the return is the memo object after the block has mutated it through
      # the `acc` alias. Compute the joined memo type the same way captured-
      # local content mutations are joined: pre-state = the memo argument's
      # type, added evidence = the content-mutator args on the memo block
      # param. Returns `call_type` unchanged for any other call, a missing
      # block, or a memo whose pre-state is not a collection.
      def each_with_object_return(call_node, call_type)
        return call_type unless call_node.name == :each_with_object

        block = call_node.block
        return call_type unless block.is_a?(Prism::BlockNode)

        memo_arg = call_node.arguments&.arguments&.first
        return call_type if memo_arg.nil?

        memo_param = each_with_object_memo_param(block)
        return call_type if memo_param.nil?

        body = block.body
        return call_type if body.nil?

        # The memo alias is a block-local (depth 0) — collect content
        # mutations on it directly rather than via the captured-local walk.
        calls = body_content_mutations_on(body, memo_param)
        return call_type if calls.empty?

        pre_state = scope.type_of(memo_arg, tracer: tracer)
        entry = build_block_entry_scope(call_node, block)
        joined = join_content_for_param(calls, pre_state, entry)
        joined || call_type
      end

      # The name of the memo block parameter (the SECOND positional param of
      # an `each_with_object` block), or nil when the block does not bind a
      # second positional param.
      def each_with_object_memo_param(block)
        params_root = block.parameters
        return nil unless params_root.is_a?(Prism::BlockParametersNode)

        params = params_root.parameters
        return nil if params.nil?

        requireds = params.requireds
        return nil if requireds.size < 2

        second = requireds[1]
        second.respond_to?(:name) ? second.name : nil
      end

      # Content-mutator calls on a block-local receiver `var_name`
      # (depth 0) within `body`.
      def body_content_mutations_on(body, var_name)
        calls = []
        Source::NodeWalker.each(body) do |descendant|
          next unless descendant.is_a?(Prism::CallNode)
          next unless MutationWidening::CONTENT_ADDERS.include?(descendant.name)

          receiver = descendant.receiver
          next unless receiver.is_a?(Prism::LocalVariableReadNode)
          next unless receiver.name == var_name

          calls << descendant
        end
        calls
      end

      # Joins content evidence for a memo / param given its pre-state and a
      # list of mutator calls, dispatching Array vs Hash by the mutator set.
      def join_content_for_param(calls, pre_state, block_entry)
        return nil if pre_state.nil?

        if stringish?(pre_state)
          # String carries no element parameter; mutating `<<`/`concat`
          # makes the constant value unsound (`s = "a"; s << x` → runtime
          # `"a…"`), so widen to the nominal base. Sound — only widens.
          Type::Combinator.nominal_of("String")
        elsif hashish?(pre_state) || (hash_mutations?(calls) && !arrayish?(pre_state))
          join_hash_param(calls, pre_state, block_entry)
        else
          join_array_param(calls, pre_state, block_entry)
        end
      end

      def join_hash_param(calls, pre_state, block_entry)
        pairs = calls.flat_map { |c| hash_pair_types(c, block_entry) }
        return nil if pairs.empty? && !hashish?(pre_state)

        MutationWidening.join_hash_content(pre_state, pairs)
      end

      def join_array_param(calls, pre_state, block_entry)
        return nil unless arrayish?(pre_state)

        added = calls.flat_map do |c|
          # Index-write on an array (`a[i] += v`) introduces no new element
          # evidence we can cheaply attribute — the array-arity forget
          # already widened the binding; contribute nothing.
          next [] if index_write?(c)

          MutationWidening.array_added_elements(c.name, content_arg_types(c, block_entry))
        end
        MutationWidening.join_array_content(pre_state, added)
      end

      # Walks the block body for content-mutator calls (`<<`, `push`,
      # `[]=`, …) whose receiver is a captured outer local (depth >= 1),
      # returning `{ name => [call_node, ...] }`. Mirrors the
      # `MutationWidening.widen_after_block` walk (descends into nested
      # blocks; the depth check keeps nested block-locals out).
      def collect_content_mutations(body)
        mutations = Hash.new { |h, k| h[k] = [] }
        Source::NodeWalker.each(body) do |descendant|
          name, node = content_mutation_target(descendant) { |r| r.is_a?(Prism::LocalVariableReadNode) && r.depth.positive? }
          mutations[name] << node unless name.nil?
        end
        mutations
      end

      # Index-write forms (`h[k] ||= v`, `h[k] += v`, `h[k] = v` via a
      # multi-assign target) that mutate a collection's CONTENT without a
      # `[]=` CallNode. `h[k] ||= []; h[k] << v` mutates `h` through the
      # OrWrite even though the appended values land on the nested array —
      # leaving `h` an empty `{}` is unsound (`h.empty?` folds to `true`).
      INDEX_WRITE_NODES = [
        Prism::IndexOrWriteNode,
        Prism::IndexAndWriteNode,
        Prism::IndexOperatorWriteNode,
        Prism::IndexTargetNode
      ].freeze
      private_constant :INDEX_WRITE_NODES

      # `[receiver_name, node]` when `node` is a content mutation whose
      # receiver is a local variable satisfying `accept` (depth predicate),
      # else `[nil, nil]`. Covers `[]=`-style CallNode mutators and the
      # index-write node forms.
      def content_mutation_target(node)
        is_call_mutator = node.is_a?(Prism::CallNode) && MutationWidening::CONTENT_ADDERS.include?(node.name)
        return [nil, nil] unless is_call_mutator || index_write?(node)

        receiver = node.receiver
        return [nil, nil] unless receiver.is_a?(Prism::LocalVariableReadNode)
        return [nil, nil] unless yield(receiver)

        [receiver.name, node]
      end

      # Computes the joined continuation collection type for one captured
      # local from its content-mutator calls. Returns `nil` (no overlay)
      # when the pre-state is neither an Array-ish nor a Hash-ish binding —
      # e.g. a String accumulator, whose `<<` carries no element parameter
      # and whose binding already types as `String`.
      def join_content_for_local(name, calls, post_scope, block_entry)
        join_content_for_param(calls, post_scope.local(name), block_entry)
      end

      def hash_mutations?(calls)
        calls.any? do |c|
          index_write?(c) || (c.is_a?(Prism::CallNode) && MutationWidening::HASH_CONTENT_ADDERS.include?(c.name))
        end
      end

      def index_write?(node)
        INDEX_WRITE_NODES.any? { |k| node.is_a?(k) }
      end

      def arrayish?(type)
        case type
        when Type::Tuple then true
        when Type::Nominal then type.class_name == "Array"
        when Type::Union then type.members.any? { |m| arrayish?(m) }
        else false
        end
      end

      def hashish?(type)
        case type
        when Type::HashShape then true
        when Type::Nominal then type.class_name == "Hash"
        when Type::Union then type.members.any? { |m| hashish?(m) }
        else false
        end
      end

      def stringish?(type)
        (type.is_a?(Type::Constant) && type.value.is_a?(String)) ||
          (type.is_a?(Type::Nominal) && type.class_name == "String")
      end

      # `[key_type, value_type]` for a `h[k] = v` / `h.store(k, v)` call or
      # an index-write node (`h[k] ||= v`), typed in the block-entry scope.
      # For an index-write the stored value is opaque (the appended values
      # often land on a NESTED collection via `h[k] << v`), so the value is
      # floored to `untyped` — sound: it only ever widens the value param.
      # Returns `[]` for other forms.
      def hash_pair_types(node, block_entry)
        if index_write?(node)
          key = index_key_type(node, block_entry)
          return [] if key.nil?

          return [[key, Type::Combinator.untyped]]
        end

        args = content_arg_types(node, block_entry)
        return [] if args.size < 2

        [[args.first, args.last]]
      end

      # Type of the index expression of an index-write node (`h[k] ||= v`).
      def index_key_type(node, block_entry)
        args = node.arguments
        return nil unless args.is_a?(Prism::ArgumentsNode)

        first = args.arguments.first
        first.nil? ? nil : block_entry.type_of(first, tracer: tracer)
      rescue StandardError
        nil
      end

      # Argument types for a content-mutator call, typed against the
      # block-entry scope (block params bound). A sub-evaluator over
      # `block_entry` keeps the argument typing flow-correct for params /
      # `;`-locals without leaking into the outer scope.
      def content_arg_types(call_node, block_entry)
        arguments = call_node.arguments
        return [] if arguments.nil?

        arguments.arguments.map { |arg| block_entry.type_of(arg, tracer: tracer) }
      rescue StandardError
        []
      end

      # Evaluates `block`'s body once with each written outer local bound to
      # the supplied `bindings` (block params / `;`-locals re-bound as
      # usual) and returns the per-name exit binding for `names`. Used as
      # the `BodyFixpoint` body-evaluator.
      def block_exit_bindings(call_node, block, bindings, names)
        entry = build_block_entry_scope(call_node, block)
        entry = bindings.reduce(entry) { |acc, (name, type)| acc.with_local(name, type) }
        _type, exit_scope = sub_eval(block, entry)
        names.to_h { |name| [name, exit_scope.local(name)] }
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
      #
      # `;`-prefixed block-locals (`do |i; x|`) are bound to
      # `Constant[nil]` so the inner read shadows any outer
      # `x` per Ruby's semantics — at runtime the block-local is
      # a fresh nil-valued variable on every block invocation.
      # Without this shadow, an inner `x.even?` before the first
      # write would type-check against the OUTER `x` (e.g.
      # `Integer`) when the runtime would actually `NoMethodError`
      # on `nil`.
      def build_block_entry_scope(call_node, block_node)
        expected = expected_block_param_types_for(call_node)
        bindings = BlockParameterBinder.new(expected_param_types: expected).bind(block_node)
        scope_with_params = bindings.reduce(scope) { |acc, (name, type)| acc.with_local(name, type) }
        block_local_names(block_node).reduce(scope_with_params) do |acc, name|
          acc.with_local(name, Type::Combinator.constant_of(nil))
        end
      end

      def block_local_names(block_node)
        params_root = block_node.parameters
        return [] unless params_root.is_a?(Prism::BlockParametersNode)

        params_root.locals.map(&:name)
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
          singleton: singleton,
          source_path: scope.source_path
        )
        bindings = binder.bind(def_node)
        # ADR-67 WD3 — override an undeclared parameter with its call-site
        # inferred type (precision-additive; an RBS-declared parameter wins,
        # the table is empty on a normal `check` run). The inferred type lives
        # only as a body local, never as an RBS contract, so it cannot fire a
        # parameter-boundary diagnostic (WD1, satisfied by construction).
        bindings = seed_inferred_param_types(bindings, def_node, singleton)

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
        fresh = seed_class_cvars(fresh)
        fresh = seed_program_globals(fresh)
        # ADR-48 Struct slice 3 — install the method body's fold-safe-local set
        # so a member read off a mutation-free local folds during the in-body
        # walk (the call-return inference path is seeded separately).
        fresh = fresh.with_struct_fold_safe(
          StructFoldSafety.fold_safe_locals(
            def_node.body, ->(name) { scope.struct_member_layout(name)&.[](:members) }
          )
        )
        bindings.reduce(fresh) { |acc, (name, type)| acc.with_local(name, type) }
      end

      # ADR-67 WD3 — consult the call-site parameter-inference table for this
      # `def` and replace each undeclared (untyped) parameter binding with its
      # inferred type. Keyed by `[class_name, method_name, kind]`, reconstructed
      # from the lexical class path — the same triple
      # {Inference::ParameterInferenceCollector} records. An RBS-declared
      # parameter (a non-untyped binding) always wins. No-op when the table is
      # empty (the normal `check` path), so the seed is byte-identical there.
      def seed_inferred_param_types(bindings, def_node, singleton)
        inferred = scope.param_inferred_types
        return bindings if inferred.empty?

        path = current_class_path
        return bindings if path.nil?

        table = inferred[[path, def_node.name, singleton ? :singleton : :instance]]
        return bindings if table.nil? || table.empty?

        merged = bindings.dup
        table.each do |name, type|
          merged[name] = type if merged.key?(name) && untyped_binding?(merged[name])
        end
        merged
      end

      # True for the `Dynamic[Top]` carrier `MethodParameterBinder` leaves on an
      # undeclared parameter — the only bindings ADR-67 WD3 overrides.
      def untyped_binding?(type)
        type.is_a?(Type::Dynamic) && type.static_facet.is_a?(Type::Top)
      end

      def seed_instance_ivars(body_scope, singleton:)
        return body_scope if singleton

        path = current_class_path
        return body_scope if path.nil?

        seeded = scope.class_ivars_for(path)
        return body_scope if seeded.empty?

        # ADR-58 WD1 — the class-ivar index unions every `@x = …` write across
        # the class flow-insensitively, so a ctor `@x = nil` seed makes a read
        # in a *different* method type `T | nil`. That `nil` is
        # declaration-sourced, not flow-live, so `seed_declaration_sourced_ivar`
        # marks each seeded ivar: `possible-nil-receiver` then declines to fire
        # on the cross-method invariant unless a method-local write or
        # narrowing makes the nil flow-live (which drops the mark).
        seeded.reduce(body_scope) { |acc, (name, type)| acc.seed_declaration_sourced_ivar(name, type) }
      end

      # Cvars are visible from BOTH instance and singleton method
      # bodies of the enclosing class, so this seed is unconditional
      # (no `singleton:` gate). At the top-level (no class context)
      # the accumulator is empty and the seed is a no-op.
      def seed_class_cvars(body_scope)
        path = current_class_path
        return body_scope if path.nil?

        seeded = scope.class_cvars_for(path)
        return body_scope if seeded.empty?

        seeded.reduce(body_scope) { |acc, (name, type)| acc.with_cvar(name, type) }
      end

      # Globals are process-wide. The body scope already inherited
      # the program-globals accumulator through `with_program_globals`;
      # seeding here just materialises each entry into the body's
      # `globals` map so reads observe a precise type without
      # consulting the accumulator on every lookup.
      def seed_program_globals(body_scope)
        seeded = scope.program_globals
        return body_scope if seeded.empty?

        seeded.reduce(body_scope) { |acc, (name, type)| acc.with_global(name, type) }
      end

      # Slice A-declarations. Class- and method-bodies start from a
      # fresh local-empty scope, but they MUST keep the
      # `declared_types` table visible at the outer scope so the
      # ScopeIndexer-populated declaration overrides
      # (`Prism::ConstantReadNode` for `module Foo` headers, etc.)
      # remain reachable from inside nested bodies.
      def build_fresh_body_scope
        # Single allocation instead of a deep `with_*` chain — this runs
        # per class/method body on the main walk, so the chain's throwaway
        # intermediate Scopes were a top `Scope#rebuild` source (ADR-44).
        # Local-empty by design; the discovery index is inherited whole by
        # reference (ADR-53 Track A), so a table added to the index can no
        # longer be dropped here by a missed per-field copy.
        Scope.new(
          environment: scope.environment,
          locals: {}.freeze,
          source_path: scope.source_path,
          discovery: scope.discovery,
          dynamic_origins: scope.dynamic_origins
        )
      end

      def singleton_def?(def_node)
        return true if def_node.receiver.is_a?(Prism::SelfNode) || current_frame_singleton?

        def_receiver_targets_lexical_self?(def_node.receiver)
      end

      # `def Foo.bar` inside `module Foo` (or `def Meta.init` inside
      # `module Meta`) — explicit-receiver def that semantically
      # equals `def self.bar` because the receiver constant
      # resolves to `self` at the def-site. Matched against the
      # current class context's tail to cover both the
      # `def OpenURI.x` form (single segment) and the
      # `def OpenURI::Meta.x` form (qualified path). Cross-class
      # receivers (`def Bar.baz` inside `module Foo` where the
      # receiver names a different constant) are not promoted to
      # singleton at this slice.
      def def_receiver_targets_lexical_self?(receiver)
        return false if @class_context.empty?

        prefix = @class_context.map(&:name)
        case receiver
        when Prism::ConstantReadNode
          receiver.name.to_s == prefix.last
        when Prism::ConstantPathNode
          rendered = Source::ConstantPath.render(receiver)
          return false unless rendered

          path = rendered.split("::")
          prefix.last(path.length) == path
        else
          false
        end
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

      def singleton_context_for(node)
        case node.expression
        when Prism::SelfNode
          return @class_context if @class_context.empty?

          outer = @class_context[0..-2]
          last = @class_context.last
          outer + [ClassFrame.new(name: last.name, singleton: true)]
        when Prism::ConstantReadNode, Prism::ConstantPathNode
          target = singleton_constant_target(node.expression)
          return @class_context unless target

          # `class << Foo` inside `class Foo` (the canonical
          # pattern in Ruby's own time.rb) is semantically
          # `class << self` — replace the enclosing frame with a
          # singleton frame for the same name so method
          # registration and `self_type` lookup land on Foo.
          # When the target names a different constant (rare
          # cross-class form), append a fresh singleton frame
          # tagged with the target FQN; the bodies are scoped to
          # that target rather than to the lexical enclosing
          # class.
          if !@class_context.empty? && @class_context.last.name == target
            outer = @class_context[0..-2]
            outer + [ClassFrame.new(name: target, singleton: true)]
          else
            [ClassFrame.new(name: target, singleton: true)]
          end
        else
          @class_context
        end
      end

      def singleton_constant_target(expression)
        case expression
        when Prism::ConstantReadNode
          expression.name.to_s
        when Prism::ConstantPathNode
          Source::ConstantPath.render(expression)
        end
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

      # Explicit `return value` (including `return` inside a block, which in
      # Ruby returns from the *enclosing method*). The control-transfer value
      # is `Bot` — a `return` produces no value at its own position — but the
      # returned expression's type is recorded into the active return sink so
      # the method-return inference joins it with the body's tail type.
      # Returns inside a nested `def`/lambda are barriers: `eval_def` clears
      # the sink around the nested body, so this handler only ever appends a
      # return that genuinely exits the method currently being inferred.
      def eval_return(node)
        sink = Thread.current[RETURN_SINK_KEY]
        record_return_value(node, sink) if sink
        [Type::Combinator.bot, scope]
      end

      # A `break` transfers control to the loop exit (its flow value is `Bot`,
      # like `return`). It records the current scope into the active loop's
      # break sink so the loop join can recover a `break`-path binding the
      # fall-through would drop (`flag = true; break` -> `flag` is `false |
      # true` after the loop). nil sink = a `break` not inside an inferred
      # loop body (a block targeting a method, or top-level) — left to the
      # existing escaping-block / no-op handling.
      def eval_break(node)
        sink = Thread.current[BREAK_SINK_KEY]
        sink << [node, scope] if sink
        [Type::Combinator.bot, scope]
      end

      def record_return_value(node, sink)
        args = node.arguments&.arguments || []
        # `return` with no argument returns nil; `return a` records the
        # argument's type; `return a, b, c` packs a Tuple — in Ruby a
        # multi-value return yields the array `[a, b, c]`, so the inferred
        # return contributes the corresponding Tuple element-by-element.
        if args.empty?
          sink << Type::Combinator.constant_of(nil)
        elsif args.size == 1
          type, = sub_eval(args.first, scope)
          sink << type
        else
          element_types = args.map { |arg| sub_eval(arg, scope).first }
          sink << Type::Combinator.tuple_of(*element_types)
        end
      end

      def sub_eval(node, with_scope, class_context: @class_context)
        StatementEvaluator.new(
          scope: with_scope,
          tracer: tracer,
          on_enter: @on_enter,
          class_context: class_context,
          converged_loop_recording: @converged_loop_recording
        ).evaluate(node)
      end

      # Slice 7 phase 14 — branch exit detection. Returns true
      # when the branch's body unconditionally exits the
      # surrounding control flow through a `return`, `next`,
      # `break`, or `raise`. Used by `eval_if` / `eval_unless`
      # to narrow the post-scope: when one branch exits, the
      # surrounding scope can carry the OTHER branch's edge
      # forward without nil-injection.
      #
      # The detection is intentionally conservative — it
      # recognises only the most common patterns:
      # - A `Prism::ReturnNode`, `NextNode`, `BreakNode`.
      # - A `Prism::CallNode` whose name is `:raise` or `:throw`.
      # - A `Prism::StatementsNode`, `Prism::ParenthesesNode`, or
      #   `Prism::IfNode`/`UnlessNode` whose final / both
      #   branches recursively exit.
      EXIT_CALL_NAMES = %i[raise throw exit abort fail].freeze
      private_constant :EXIT_CALL_NAMES

      def branch_unconditionally_exits?(node)
        return false if node.nil?

        case node
        when Prism::ReturnNode, Prism::NextNode, Prism::BreakNode
          true
        when Prism::CallNode
          node.receiver.nil? && EXIT_CALL_NAMES.include?(node.name)
        when Prism::StatementsNode
          last = node.body.last
          branch_unconditionally_exits?(last)
        when Prism::ParenthesesNode
          branch_unconditionally_exits?(node.body)
        when Prism::IfNode, Prism::UnlessNode
          branch_unconditionally_exits?(node.statements) &&
            branch_unconditionally_exits?(node_else_branch(node))
        else
          false
        end
      end

      def node_else_branch(node)
        case node
        when Prism::IfNode then node.subsequent
        when Prism::UnlessNode then node.else_clause
        end
      end

      # ADR-24 WD6 / slice 3 — generalised terminating-branch
      # detection. `branch_unconditionally_exits?` recognises a
      # branch SYNTACTICALLY (return / next / break / a call
      # named raise / throw / exit / abort / fail). A branch
      # whose *inferred type is `Bot`* also terminates — it
      # cannot produce a value, so control never falls through
      # it — regardless of how it is spelled. The canonical
      # case is a resolved guard helper (`fail_with_message(...)`)
      # whose body always raises: ADR-24 slice 1 types the call
      # `bot`, and this OR-test makes `helper(...) if x.nil?`
      # narrow exactly like `raise ... if x.nil?`. The branch
      # type is already computed by `eval_if` / `eval_unless`.
      def branch_terminates?(branch_node, branch_type)
        branch_unconditionally_exits?(branch_node) ||
          branch_type.is_a?(Type::Bot)
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

      # ---------------------------------------------------------------
      # rescue variable binding helpers
      # ---------------------------------------------------------------

      # Returns `scope` extended with the rescue reference variable bound
      # to the exception instance type. Leaves scope unchanged when the
      # node carries no reference (bare `rescue` without `=> var`).
      def bind_rescue_reference(rescue_node, scope)
        ref = rescue_node.reference
        return scope unless ref.is_a?(Prism::LocalVariableTargetNode)

        scope.with_local(ref.name, rescue_exception_type(rescue_node, scope))
      end

      # Derives the exception instance type for a `RescueNode`. When the
      # exceptions list is empty (bare `rescue`) the type is
      # `StandardError`. When one or more exception classes are named the
      # types are unioned. Falls back to `StandardError` for any class
      # that cannot be resolved to a `Singleton` type.
      def rescue_exception_type(rescue_node, scope)
        exceptions = rescue_node.exceptions
        if exceptions.empty?
          Type::Combinator.nominal_of("StandardError")
        else
          types = exceptions.map do |exc_node|
            singleton_type, = sub_eval(exc_node, scope)
            singleton_to_nominal(singleton_type)
          end
          Type::Combinator.union(*types)
        end
      end

      # ---------------------------------------------------------------
      # `case/in` pattern variable binding helpers
      # ---------------------------------------------------------------

      # Builds the entry scope for an `in` branch by injecting every
      # variable captured by the pattern as a local binding.
      def apply_in_pattern_bindings(subject, pattern, scope)
        bindings = collect_in_pattern_bindings(subject, pattern, scope)
        bindings.reduce(scope) { |s, (name, type)| s.with_local(name, type) }
      end

      # Returns an array of `[Symbol, Rigor::Type]` pairs for every
      # variable captured by `pattern`. Unrecognised pattern nodes
      # contribute no bindings (fail-soft).
      def collect_in_pattern_bindings(subject, pattern, scope)
        case pattern
        when Prism::CapturePatternNode
          [[pattern.target.name, pattern_capture_type(pattern.value, scope)]]
        when Prism::LocalVariableTargetNode
          subject_type = subject.is_a?(Prism::LocalVariableReadNode) ? scope.local(subject.name) : nil
          [[pattern.name, subject_type || Type::Combinator.untyped]]
        when Prism::ImplicitNode
          collect_in_pattern_bindings(subject, pattern.value, scope)
        when Prism::ArrayPatternNode
          collect_array_pattern_bindings(pattern, scope)
        when Prism::FindPatternNode
          collect_find_pattern_bindings(pattern, scope)
        when Prism::HashPatternNode
          collect_hash_pattern_bindings(pattern, scope)
        when Prism::AlternationPatternNode
          collect_alternation_pattern_bindings(subject, pattern, scope)
        else
          []
        end
      end

      def collect_array_pattern_bindings(pattern, scope)
        bindings = [*pattern.requireds, *pattern.posts].flat_map do |elem|
          collect_in_pattern_bindings(nil, elem, scope)
        end
        append_array_splat_binding(bindings, pattern.rest)
        bindings
      end

      def collect_hash_pattern_bindings(pattern, scope)
        bindings = pattern.elements.flat_map do |assoc|
          next [] unless assoc.is_a?(Prism::AssocNode) && assoc.value

          collect_in_pattern_bindings(nil, assoc.value, scope)
        end
        rest = pattern.rest
        if rest.is_a?(Prism::AssocSplatNode)
          val = rest.value
          bindings << [val.name, hash_pattern_rest_type] if val.is_a?(Prism::LocalVariableTargetNode)
        end
        bindings
      end

      def collect_find_pattern_bindings(pattern, scope)
        bindings = pattern.requireds.flat_map do |elem|
          collect_in_pattern_bindings(nil, elem, scope)
        end
        [pattern.left, pattern.right].each { |splat| append_array_splat_binding(bindings, splat) }
        bindings
      end

      # `[..., *rest, ...]` / `[*pre, x, *post]` capture an Array of
      # the unmatched elements; bind `rest` to `Array[untyped]` rather
      # than the previous bare `untyped`. Per-element typing waits on
      # subject-aware element-type extraction (the binder doesn't see
      # the case subject).
      def append_array_splat_binding(bindings, splat)
        return unless splat.is_a?(Prism::SplatNode)

        target = splat.expression
        return unless target.is_a?(Prism::LocalVariableTargetNode)

        bindings << [target.name, Type::Combinator.nominal_of("Array", type_args: [Type::Combinator.untyped])]
      end

      # `{ key:, **rest }` binds `rest` to a Hash whose keys are
      # Symbols (the only legal key shape for a hash pattern) and
      # whose values are untyped (the binder can't see the subject's
      # value type).
      def hash_pattern_rest_type
        Type::Combinator.nominal_of(
          "Hash",
          type_args: [Type::Combinator.nominal_of("Symbol"), Type::Combinator.untyped]
        )
      end

      # ---------------------------------------------------------------
      # named-capture regex binding (`MatchWriteNode`)
      # ---------------------------------------------------------------

      # `/(?<year>\d+)/ =~ str` — Prism emits a `MatchWriteNode` that
      # wraps the `=~` call and lists the named-capture targets. Each
      # target is bound to `String | nil` (the capture is absent as nil
      # when the pattern doesn't match or the group didn't participate).
      def eval_match_write(node)
        match_type, post_scope = sub_eval(node.call, scope)
        string_or_nil = Type::Combinator.union(
          Type::Combinator.nominal_of("String"),
          Type::Combinator.constant_of(nil)
        )
        bound_scope = node.targets.reduce(post_scope) do |s, target|
          next s unless target.is_a?(Prism::LocalVariableTargetNode)

          s.with_local(target.name, string_or_nil)
        end
        [match_type, bound_scope]
      end

      # ---------------------------------------------------------------
      # shared type conversion helper
      # ---------------------------------------------------------------

      # Converts a `Singleton[ClassName]` (the class object) to the
      # corresponding `Nominal[ClassName]` (an instance). Falls back to
      # `untyped` for carriers that are not Singleton (e.g. Dynamic[Top]
      # when the class could not be resolved).
      def singleton_to_nominal(type)
        type.is_a?(Type::Singleton) ? Type::Combinator.nominal_of(type.class_name) : Type::Combinator.untyped
      end

      # Returns the type to bind for a `CapturePatternNode`'s target.
      # Plain class references collapse to the matching `Nominal[T]`;
      # `AlternationPatternNode` (`Integer | String => x`) unions every
      # alternate's resolved type. Anything else falls back to
      # `untyped` (the conservative legacy behaviour).
      def pattern_capture_type(value_node, scope)
        if value_node.is_a?(Prism::AlternationPatternNode)
          left = pattern_capture_type(value_node.left, scope)
          right = pattern_capture_type(value_node.right, scope)
          Type::Combinator.union(left, right)
        else
          singleton_to_nominal(sub_eval(value_node, scope).first)
        end
      end

      # `in PatternA | PatternB` — Ruby requires both alternates to
      # bind the same names, but the binder runs against the AST and
      # cannot enforce that. We collect bindings from each side and
      # merge by name, unioning types when both alternates contribute.
      # Names that only one alternate contributes still surface (the
      # parser would have rejected the case at compile time, so by the
      # time we see it the user's intent is the merged set).
      def collect_alternation_pattern_bindings(subject, pattern, scope)
        left = collect_in_pattern_bindings(subject, pattern.left, scope)
        right = collect_in_pattern_bindings(subject, pattern.right, scope)
        merged = {}
        (left + right).each do |name, type|
          merged[name] = merged.key?(name) ? Type::Combinator.union(merged[name], type) : type
        end
        merged.to_a
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
