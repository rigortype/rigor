# frozen_string_literal: true

require "prism"

require_relative "../reflection"
require_relative "../type"
require_relative "../analysis/fact_store"
require_relative "../source/node_walker"
require_relative "../source/node_children"
require_relative "../source/constant_path"
require_relative "anonymous_meta_class"
require_relative "block_parameter_binder"
require_relative "body_fixpoint"
require_relative "captured_locals"
require_relative "dynamic_origin"
require_relative "jump_targets"
require_relative "../analysis/check_rules/inferred_param_guard"
require_relative "../analysis/check_rules/published_constant_guard"
require_relative "struct_fold_safety"
require_relative "closure_escape_analyzer"
require_relative "content_join"
require_relative "define_method_block_self"
require_relative "macro_block_self_type"
require_relative "match_rebinding"
require_relative "element_read_widening"
require_relative "hash_lookup_mutation"
require_relative "indexed_narrowing"
require_relative "index_write_widening"
require_relative "method_dispatcher"
require_relative "method_parameter_binder"
require_relative "multi_target_binder"
require_relative "mutation_widening"
require_relative "narrowing"
require_relative "operand_effects"
require_relative "operand_walk"
require_relative "optimistic_origin"
require_relative "return_barrier"
require_relative "rewrite_mutation"
require_relative "unknown_store_widening"
require_relative "version_guard"

module Rigor
  module Inference
    # Statement-level evaluator that complements `Rigor::Inference::ExpressionTyper` by threading an immutable
    # {Rigor::Scope} through control-flow constructs. The output is the pair `[Rigor::Type, Rigor::Scope]`: the type
    # that the evaluated node produces, and the scope that callers should observe AFTER the node has run.
    #
    # Slice 3 phase 2 ships the evaluator surface and the scope-threading rules for the canonical statement-y nodes:
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
    # Anything outside the catalogue defers to `Rigor::Scope#type_of` and returns the receiver scope unchanged. This
    # matches the Slice 1 fail-soft policy: an unrecognised statement-level node MUST NOT raise and MUST keep the scope
    # intact.
    #
    # The class is stateful (`@scope`, `@tracer`) but every public call returns fresh values; the receiver scope MUST
    # never be mutated. Recursive evaluation always allocates a new instance with the forked scope so different branches
    # stay isolated.
    #
    # See docs/internal-spec/inference-engine.md for the public contract and docs/adr/4-type-inference-engine.md for the
    # slice rationale.
    # rubocop:disable-next Metrics/ClassLength
    class StatementEvaluator
      # Hash-based dispatch keeps `evaluate` linear and lets future slices add control-flow node kinds without growing a
      # single case statement past RuboCop's cyclomatic budget. Anonymous Prism subclasses are not expected.
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
        Prism::IndexAndWriteNode => :eval_index_write,
        Prism::IndexOperatorWriteNode => :eval_index_write,
        Prism::CallOrWriteNode => :eval_attribute_compound_write,
        Prism::CallAndWriteNode => :eval_attribute_compound_write,
        Prism::CallOperatorWriteNode => :eval_attribute_compound_write,
        Prism::MultiWriteNode => :eval_multi_write,
        Prism::ConstantWriteNode => :eval_constant_write,
        Prism::ConstantPathWriteNode => :eval_constant_write,
        # Issue #963 — `Const ||= Struct.new(:a) do … end` opens the same class body. The handler's own result is
        # the default expression pair, so routing the or-writes here adds the body entry and nothing else.
        Prism::ConstantOrWriteNode => :eval_constant_write,
        Prism::ConstantPathOrWriteNode => :eval_constant_write,
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
        Prism::LambdaNode => :eval_lambda,
        Prism::ReturnNode => :eval_return,
        Prism::NextNode => :eval_next,
        Prism::BreakNode => :eval_break,
        Prism::MatchWriteNode => :eval_match_write,
        Prism::MatchPredicateNode => :eval_match_pattern,
        Prism::MatchRequiredNode => :eval_match_pattern,
        Prism::RescueModifierNode => :eval_rescue_modifier,
        Prism::ArrayNode => :eval_value_container,
        Prism::HashNode => :eval_value_container,
        Prism::InterpolatedStringNode => :eval_value_container,
        Prism::InterpolatedSymbolNode => :eval_value_container,
        Prism::InterpolatedXStringNode => :eval_value_container,
        Prism::RangeNode => :eval_value_container
      }.freeze
      private_constant :HANDLERS

      # Issue #1223 — the expressions that evaluate every child, in child order, before producing their value, so
      # a write inside one is threaded child by child ({#thread_operand}). A construct that may skip a child is
      # left out: a `rescue` modifier has its own handler, and a regexp interpolation with the `o` flag runs its
      # parts once per process.
      OPERAND_CONTAINERS = Set[
        Prism::ArgumentsNode, Prism::KeywordHashNode, Prism::AssocNode, Prism::AssocSplatNode, Prism::SplatNode,
        Prism::BlockArgumentNode, Prism::ArrayNode, Prism::HashNode, Prism::InterpolatedStringNode,
        Prism::InterpolatedSymbolNode, Prism::InterpolatedXStringNode, Prism::EmbeddedStatementsNode,
        Prism::RangeNode
      ].freeze
      private_constant :OPERAND_CONTAINERS

      # Statement sequences an operand may hold, threaded statement by statement like a container ({#thread_operand}).
      OPERAND_SEQUENCES = Set[Prism::StatementsNode, Prism::ParenthesesNode].freeze
      private_constant :OPERAND_SEQUENCES

      # The keywords of a pass whose scopes the per-node scope index must not keep — neither the nodes it
      # evaluates nor the later operands an {OperandWalk} inside it takes ({#walk_recorder}).
      UNRECORDED = { on_enter: nil, operand_recorder: nil }.freeze
      private_constant :UNRECORDED

      # Thread-local sink (an Array) collecting the value types of explicit `return value` nodes reached while
      # evaluating a method body, so `ExpressionTyper#infer_user_method_return` can join them into the method's inferred
      # return type. The flow value of a `return` is still `Bot` (it transfers control rather than producing a value);
      # the sink only records what the method *returns* through that edge. nil means "not collecting" — a top-level /
      # DSL-block walk, or inside a nested `def` barrier (whose returns belong to the inner method).
      RETURN_SINK_KEY = :rigor_return_sink
      private_constant :RETURN_SINK_KEY

      # Thread-local sink (an Array of `[NextNode, Type]`) collecting the value each `next` carries out of the block it
      # leaves, so `ExpressionTyper#type_block_body` can join those arms into the block's value type. Issue #841: the
      # block-return pass modelled only the fall-through tail, so `ops.all? { |o| next false unless o; true }` read as
      # `Constant[true]` and folded the call to always-truthy — the same defect `RETURN_SINK_KEY` fixes one level up for
      # a method's early `return`. The flow value of a `next` stays `Bot`.
      #
      # The sink also collects `next`s from nested blocks / loops / defs evaluated under the same installation (they do
      # not install their own), so the consumer filters by node identity against a statically computed
      # directly-targeting set, exactly as the break sink does. nil means "not collecting".
      NEXT_SINK_KEY = :rigor_next_sink
      private_constant :NEXT_SINK_KEY

      # Thread-local sink (an Array of `[BreakNode, Scope]`) collecting the scope at each `break` reached while
      # evaluating a loop body, so `eval_loop` / `eval_for` can join a `break`-path binding (`flag = true; break`) into
      # the loop continuation that the fall-through would otherwise drop. Stacks like the return sink: a nested loop
      # installs its own sink, restored on exit, so an inner loop's break does not leak to the outer one. A `break`
      # inside a block / nested loop targets that inner construct, not the lexical loop — filtered out by the loop's
      # {JumpTargets} set ({#loop_jumps}). See docs/notes/20260615-loop-break-binding-propagation-design.md.
      BREAK_SINK_KEY = :rigor_break_sink
      private_constant :BREAK_SINK_KEY

      # Thread-local sink (an Array of `[BreakNode, Type]`) collecting the value each `break` carries out of the
      # construct it leaves. Issue #853: `break value` terminates the yielding CALL and is that call's value, so —
      # unlike `next`, which {NEXT_SINK_KEY} joins into the block — these arms are consumed one level up, by
      # `ExpressionTyper#call_dispatch_type_for`. Without them `ops.all? { |o| break false unless o; true }` folded to
      # `Constant[true]` and warned about a program that really can answer false.
      #
      # Separate from {BREAK_SINK_KEY}, which records SCOPES for the loop-continuation join: the two consumers want
      # different things from the same node, and a loop body evaluated under a call's collection must keep feeding its
      # own sink. Both are filtered by node identity against a statically computed directly-targeting set, so a `break`
      # that belongs to an inner loop or block never reaches the wrong consumer. nil means "not collecting".
      BREAK_VALUE_SINK_KEY = :rigor_break_value_sink
      private_constant :BREAK_VALUE_SINK_KEY

      # Lexical class frame: the `name:` field is the qualified class name as it would render in Ruby (e.g.,
      # `"Foo::Bar"`); the `singleton:` field is `true` for `class << self` frames so nested defs resolve to
      # singleton-method RBS lookups.
      ClassFrame = Data.define(:name, :singleton)

      # Issue #652 — Ruby's `Module.nesting` for the body currently being evaluated, innermost first, built as
      # the walk ENTERS each declaration rather than reconstructed from the qualified name afterwards. A
      # compact `module A::B` contributes ONE entry, the nested `module A; module B` two, and both render the
      # same `class_name`, so the distinction survives only if it is recorded here. `[]` is the file top level,
      # and nothing is stamped for it — a scope with no recorded chain falls back to the name-peel, which
      # answers the same thing at the top level and answers correctly for a body this walk never entered.
      EMPTY_NESTING = [].freeze
      private_constant :EMPTY_NESTING

      # @param on_enter — optional `(node, scope) ->` callable
      #   invoked once at the start of every {#evaluate} call (the node
      #   itself, *before* its handler runs). Threaded through every
      #   recursive `sub_eval` so the tooling that builds a per-node
      #   scope index (`Rigor::Inference::ScopeIndexer`) can record the
      #   entry scope for every Prism node the evaluator visits without
      #   the StatementEvaluator carrying any additional state itself.
      # @param class_context — lexical class scope used
      #   by {#eval_def} to look up the method's RBS signature. Each
      #   `ClassNode`/`ModuleNode` entry pushes a frame; `SingletonClassNode`
      #   over `self` flips the innermost frame to singleton mode.
      # @param converged_loop_recording — when true (and an
      #   `on_enter` recorder is installed), {#eval_loop} re-evaluates a
      #   fixpoint-tracked loop body ONE extra time from the CONVERGED
      #   bindings so the last-visit-wins per-node scope index reflects
      #   the post-writeback state instead of the cap-N intermediate
      #   assumption (`result *= i` annotating `1 | 2` rather than
      #   `Integer`). Display-path only — `rigor check` leaves it off,
      #   keeping its diagnostics and wall-clock unchanged.
      # @param next_scope_sink — the Array of `[NextNode, Scope]` pairs
      #   the innermost enclosing block invocation or loop body collects
      #   its `next` exits into ({#evaluate_invocation},
      #   {#loop_iteration}), or nil. The scope twin of the thread-local
      #   `next` VALUE sink, threaded through `sub_eval` instead so an
      #   evaluation `ExpressionTyper` starts elsewhere — the block-return
      #   pass, a recursive method's inference — can never feed it a
      #   `next` from another context. A `->` body's `next` still lands
      #   here; the consumer filters by node identity.
      # @param operand_scope — the scope a call's receiver and arguments
      #   were typed under, when {#eval_call} runs the rest of that call
      #   from the scope its operands left ({#invoke_call}); nil otherwise,
      #   where it is the receiver scope itself ({#operand_scope}).
      # @param in_operand — true for an evaluator {#thread_operand} opened, and every evaluator it opens: the
      #   calls it runs are inside another expression's operand, which {#invoke_call} leaves the resets of a
      #   statement-position call out of; the statement that holds the operand answers for its match globals.
      # @param operand_recorder — the per-node scope index's recorder, for an evaluator {#thread_operand} opened
      #   (whose own `on_enter` is nil) and every evaluator it opens but an unrecorded pass ({UNRECORDED}), so an
      #   {OperandWalk} rooted inside an operand still records its later operands ({#walk_recorder}).
      # @param operand_types — the later operands' own values ({OperandWalk#types}) for the evaluator that runs a
      #   call from the scope its operands left, read by {#type_operand}.
      def initialize(scope:, tracer: nil, on_enter: nil, class_context: [].freeze, # rubocop:disable Metrics/ParameterLists
                     lexical_nesting: EMPTY_NESTING, converged_loop_recording: false, next_scope_sink: nil,
                     operand_scope: nil, in_operand: false, operand_recorder: nil, operand_types: nil)
        @scope = scope
        @tracer = tracer
        @on_enter = on_enter
        @class_context = class_context.freeze
        @lexical_nesting = lexical_nesting.freeze
        @converged_loop_recording = converged_loop_recording
        @next_scope_sink = next_scope_sink
        @operand_scope = operand_scope
        @in_operand = in_operand
        @operand_recorder = operand_recorder
        @operand_types = operand_types
      end

      # Runs `block` with a fresh return sink installed, then yields the collected explicit-`return` value types to the
      # caller. The sink is an array of `Rigor::Type`. Nested invocations stack: the previous sink is restored on exit
      # so a `def` evaluated inside another method's body (which itself installed a sink) does not corrupt the outer
      # one. Used by `ExpressionTyper#infer_user_method_return` to join the explicit returns into the inferred
      # method-return type.
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

      # Runs `block` with a fresh `next` sink installed, then yields the collected `[NextNode, Type]` pairs to the
      # caller. Stacks like the return sink, and for the same reason: a block body evaluated inside another block body's
      # evaluation must not spill its arms into the outer collection. Used by `ExpressionTyper#type_block_body` to join
      # the `next` arms into the block's value type.
      def self.with_next_sink
        previous = Thread.current[NEXT_SINK_KEY]
        sink = []
        Thread.current[NEXT_SINK_KEY] = sink
        begin
          result = yield
        ensure
          Thread.current[NEXT_SINK_KEY] = previous
        end
        [result, sink]
      end

      # Runs `block` with a fresh `break`-value sink installed, then yields the collected `[BreakNode, Type]` pairs to
      # the caller. Stacks like the other sinks: a block body evaluated inside another block body's evaluation must not
      # spill its arms into the outer collection. Used by `ExpressionTyper#call_dispatch_type_for` to union the `break`
      # arms into the yielding call's type (issue #853).
      def self.with_break_value_sink
        previous = Thread.current[BREAK_VALUE_SINK_KEY]
        sink = []
        Thread.current[BREAK_VALUE_SINK_KEY] = sink
        begin
          result = yield
        ensure
          Thread.current[BREAK_VALUE_SINK_KEY] = previous
        end
        [result, sink]
      end

      # Evaluate `node` under the receiver scope. Returns `[type, scope']` where `type` is the value the node produces
      # and `scope'` is the scope observable after the node has run. The receiver scope is never mutated.
      def evaluate(node)
        @on_enter&.call(node, @scope)

        handler = HANDLERS[node.class]
        return send(handler, node) if handler

        # Default: the node is treated as a pure expression. Type it through the existing expression typer (which
        # observes the current scope's locals) and leave the scope unchanged, but for the match globals a call in it
        # may rebind (`super(line.sub(re, ""))`, issue #1365).
        [@scope.type_of(node, tracer: @tracer), forget_rebound_match_globals(@scope, node)]
      end

      # One invocation of `block_node`'s body, from the receiver scope (which the caller has already bound the block's
      # parameters onto). Returns `[type, fall_through, exit]`: the body's tail type, the scope it falls off the end
      # with, and the scope the invocation ends with.
      #
      # A `next` ends the invocation as surely as falling off the end does, so `exit` is `fall_through` joined
      # (`Scope#join`) with the scope at every `next` that targets this block ({JumpTargets}). Without that join a
      # rebind on a jumping branch (`if e.odd?; n = e; next; end`) vanished — `eval_if` carries only the arm that falls
      # through — and both readers of the exit scope, ADR-56's write-back fixpoint ({#block_exit_bindings}) and issue
      # #587 (b)'s per-element fold (`ExpressionTyper#captured_exit_bindings`), kept the pre-call binding. A `break` is
      # NOT joined: it ends the call, so its scope feeds no further invocation ({#join_block_break_bindings}).
      # `fall_through` is exposed for the fold's unmoved-pin test, which must not count what a `next` arm adds.
      #
      # A body with no block-level `next` pays one allocation-free scan and nothing else.
      def evaluate_invocation(block_node)
        body = block_node.body
        return [Type::Combinator.constant_of(nil), scope, scope] if body.nil?

        unless JumpTargets.any?(body, Prism::NextNode)
          type, fall_through = sub_eval(body, scope, next_scope_sink: nil)
          return [type, fall_through, fall_through]
        end

        sink = []
        type, fall_through = sub_eval(body, scope, next_scope_sink: sink)
        [type, fall_through, join_jump_scopes(fall_through, sink, JumpTargets.of(body, Prism::NextNode))]
      end

      # ADR-89 WD2 — the sorted positions of the positional parameters whose CONTENT `def_node` mutates
      # (`callee_content_mutated_parameters`, the ADR-56 arg-flooring surface a caller consumes). A per-def
      # static property of the AST — this is a pure exposure of the existing private computation (it never
      # reads the scope), so the incremental session can compute it on any `StatementEvaluator` (an empty
      # scope suffices), persist it in a return summary, and re-check a callee's symbol dependents when it
      # moves (a caller's arg flooring changes even if the callee's return does not).
      def content_mutated_parameter_positions(def_node)
        callee_content_mutated_parameters(def_node).values.uniq.sort
      end

      # The local-variable reads among `call_node`'s positional arguments whose matching parameter the callee
      # content-mutates, when `call_node` is a self-dispatch call resolving to a user def in this evaluator's scope
      # (`callee_content_mutated_parameters`); empty for any other call. These are the locals the straight-line
      # callee floor ({#widen_callee_escaped_argument_captures}) floors after the call, and the ones
      # {CapturedLocals.content_mutations} reports as a block's callee-mutated captures.
      def content_mutated_arguments(call_node)
        return NO_ARGUMENT_READS unless self_dispatch_call?(call_node)
        # Fast path — only a local passed as an argument can be reported, so a call with none skips the def
        # resolution and the body scan entirely (the overwhelming common case).
        return NO_ARGUMENT_READS unless call_passes_local_argument?(call_node)

        def_node = resolve_self_callee_def(call_node)
        return NO_ARGUMENT_READS if def_node.nil?

        mutated = callee_content_mutated_parameters(def_node)
        return NO_ARGUMENT_READS if mutated.empty?

        argument_nodes = call_node.arguments.arguments
        mutated.values.uniq.filter_map do |index|
          argument = argument_nodes[index]
          argument if argument.is_a?(Prism::LocalVariableReadNode)
        end
      end

      NO_ARGUMENT_READS = [].freeze
      private_constant :NO_ARGUMENT_READS

      # The value `h[k] += v` / `h[k] ||= v` / `h[k] &&= v` evaluates to in this evaluator's scope: what it stores
      # through `[]=` ({#index_write_stored_type}). The `[]=` widening and the indexed-narrowing record are scope
      # effects, so they stay with {#eval_index_or_write} / {#eval_index_write}. `ExpressionTyper` types a
      # value-position index compound write from here.
      #
      # One reading departs from the statement's: a `||=` whose `[]` read is wholly gradual (`Dynamic`, not a
      # union with a `Dynamic` member) reads as the rvalue. That is the memoization idiom — `CACHE[key] ||=
      # build(key)`, `(@memo ||= {})[[a, b]] ||= compute`, `@targets[name] ||= new(name)` on an ivar the method
      # never writes — where the value the idiom returns is the one it stores, and `Dynamic[top] | rhs` sent
      # every such method to `sig.skipped.untyped-return`. It is the variable form's optimism for an unbound `||=`
      # target (`ExpressionTyper#type_of_compound_variable_write`) keyed on the slot, and no wider: `&&=` is no
      # memo (`h[k] &&= v` on an absent slot is `nil`), an operator write has no such reading, and an rvalue
      # with no truthy part stores nothing truthy, so the slot's own value is the answer whenever it is set:
      # `opts[k] ||= raise KeyError` is a guard, never `bot`, and `@flags[n] ||= false` is `true` after an
      # `@flags[n] = true` elsewhere, never provably `false`.
      #
      # Nor is a site a block-return pass marked (`Scope#repeated_or_write?`, {RepeatedOrWrites}): the pass types
      # every run of a repeating body from one entry scope, so its slot's gradual type may be what an EARLIER run
      # stored rather than an absence of evidence.
      def index_compound_write_value(node)
        return index_write_stored_type(node, scope) unless node.is_a?(Prism::IndexOrWriteNode)

        current = index_read_type(node, scope)
        rhs = scope.type_of(node.value, tracer: tracer)
        return rhs if memoizing_index_read?(node, current, rhs)

        index_write_stored_type(node, scope, current: current, rhs: rhs)
      end

      private

      attr_reader :scope, :tracer

      # Thread the scope through every child statement in declaration order. The body's value is the type of the last
      # statement (or `Constant[nil]` for an empty body); intermediate statements' types are discarded, but their scope
      # effects are preserved.
      #
      # Inside a retrying `begin`'s primary body, each statement's post-scope is also a point the body can raise from
      # ({#record_raise_points}).
      def eval_statements(node)
        result_type = Type::Combinator.constant_of(nil)
        current = scope
        raising = Thread.current[RETRY_FRAMES_KEY]
        node.body.each do |stmt|
          result_type, current = sub_eval(stmt, current)
          record_raise_points(raising, stmt, current) if raising
        end
        [result_type, current]
      end

      def eval_program(node)
        return [Type::Combinator.constant_of(nil), scope] if node.statements.nil?

        sub_eval(node.statements, scope)
      end

      # `name = rvalue` evaluates the rvalue under the entry scope (so earlier assignments in a chained `a = b = expr`
      # propagate left-to-right) and binds `name` to the result type. Compound assignment forms (`+=` etc.) are deferred
      # to a follow-up; for now they degrade to "type the rhs, do not rebind" via the default branch in {#evaluate}.
      def eval_local_write(node)
        rhs_type, post_rhs = sub_eval(node.value, scope)
        bound = bind_local_write(node, rhs_type, post_rhs)
        # Issue #667 — `m = AppConfig::MODE` makes `m` a copy of a constant the reader's file does not
        # declare, so `m == :production` folding to `true` is the project's configuration and not a logic
        # error the author can see. Stamped LAST, across every binding path above: an RHS can be both an
        # ADR-58 ivar copy and a published-constant copy (`@mode = AppConfig::MODE` in the ctor, `m = @mode`
        # here), and the two marks answer unrelated questions.
        return [rhs_type, bound] unless published_constant_copy?(node.value, rhs_type, post_rhs)

        [rhs_type, bound.with_published_constant_mark(:local, node.name)]
      end

      # The binding half of {#eval_local_write}: the three mutually exclusive provenance paths a local write
      # can take, unchanged from when they were inline.
      def bind_local_write(node, rhs_type, post_rhs)
        # ADR-58 WD1 — `r = @right` where `@right`'s optionality is purely declaration-sourced makes `r`
        # declaration-sourced too (the survey's exact rotation/traversal shape `r = @right; r.key`). The mark is
        # computed on the RHS *value*'s provenance — a pure ivar read of a currently declaration-sourced ivar — so it
        # survives the local copy. Any other RHS (a call result, a method-local-nil-bearing value) leaves the local
        # flow-live and the diagnostic fires as before.
        return post_rhs.with_declaration_sourced_local(node.name, rhs_type) if
          declaration_sourced_ivar_read?(node.value, post_rhs)

        bound = post_rhs.with_local(node.name, rhs_type)
        # ADR-67 WD6b — a local whose RHS is (transitively) rooted at an inferred parameter inherits the
        # "inferred, not declared" mark, so a subsequent use of the local declines the negative rules for the
        # same lower-bound reason (`vindex = codepoints[i] - x; vindex < y`). The mark is STICKY across
        # narrowing/joins (see `Scope#without_inferred_param_mark`), so a genuine rewrite from a non-param RHS
        # must clear it here. No-op unless the `parameter_inference:` gate seeded a parameter this RHS reaches.
        return bound.with_inferred_param_mark(node.name) if
          Analysis::CheckRules::InferredParamGuard.rooted?(node.value, scope)

        bound = bound.without_inferred_param_mark(node.name)
        bound = bound.with_local_origin(node.name, rhs_origin(node.value, post_rhs, rhs_type))
        bound.with_optimistic_local(node.name, optimistic_rhs_origin(node.value, post_rhs))
      end

      # Issue #667 — true when this write copies a value whose constancy rests on a foreign published
      # constant. The `Type::Constant` pre-gate is what keeps the question cheap and is not merely an
      # optimisation: the mark exists to withhold `flow.always-truthy-condition`, which only ever fires on a
      # predicate that folded, so a non-constant RHS has nothing to withhold. It also keeps the guard's one
      # interprocedural hop off every `x = foo(y)` in a project that publishes anything at all — the same
      # gate {Analysis::CheckRules::AlwaysTruthyConditionCollector} puts in front of it.
      def published_constant_copy?(value_node, rhs_type, scope_after_rhs)
        return false unless rhs_type.is_a?(Type::Constant)

        Analysis::CheckRules::PublishedConstantGuard.rooted?(value_node, scope_after_rhs)
      end

      # Issue #286 — the optimistic-nil-free counterpart of {#rhs_origin}, differing in two ways. It does not
      # gate on `Dynamic`: the values this channel marks are ordinary `Union` / `Constant` / `Nominal`
      # carriers, which is the whole point. And it resolves a bare local read through its binding, so
      # `w = v` keeps the mark — the same propagation `OriginLookup` performs for the Dynamic channel.
      def optimistic_rhs_origin(value_node, scope_after_rhs)
        optimistic_origin_for(value_node, scope_after_rhs)
      end

      # The effective optimistic-nil-free cause of an expression. {Inference::OptimisticOrigin.resolve} owns
      # the judgment — the mark on the node itself, the binding a bare local / ivar read resolves through, and
      # the predicate-fold derivation of issue #313.
      def optimistic_origin_for(node, scope)
        Inference::OptimisticOrigin.resolve(node, scope)
      end

      # ADR-82 WD1 — the {Inference::DynamicOrigin} cause to propagate onto a local / ivar being bound to `rhs`.
      # Returns the cause recorded on the assignment's rhs node when the value is `Dynamic` (so a later
      # `x` / `@x` receiver-read resolves to why it is dynamic), else `nil` — `with_local_origin` /
      # `with_ivar_origin` treat `nil` as a no-op, so this is safe to call unconditionally.
      def rhs_origin(value_node, scope_after_rhs, rhs_type)
        return nil unless rhs_type.is_a?(Type::Dynamic)

        scope_after_rhs.dynamic_origins[value_node]
      end

      # True when `value_node` is a bare instance-variable read whose binding in `scope_at_read` is currently marked
      # declaration-sourced.
      def declaration_sourced_ivar_read?(value_node, scope_at_read)
        return false unless value_node.is_a?(Prism::InstanceVariableReadNode)

        scope_at_read.declaration_sourced?(:ivar, value_node.name)
      end

      # Slice 7 phase 1 — instance/class/global variable writes. Each handler evaluates the rvalue under the entry scope
      # and binds the named variable into the post-scope's per-kind binding map. The expression value is the rvalue
      # type, matching Ruby's semantics. Bindings are method-local: a fresh scope is built at every `def` entry through
      # `build_method_entry_scope`, so writes do not leak across method boundaries until cross-method ivar/cvar tracking
      # lands.
      def eval_ivar_write(node)
        rhs_type, post_rhs = sub_eval(node.value, scope)
        bound = post_rhs.with_ivar(node.name, rhs_type)
        bound = bound.with_ivar_origin(node.name, rhs_origin(node.value, post_rhs, rhs_type))
        bound = bound.with_optimistic_ivar(node.name, optimistic_rhs_origin(node.value, post_rhs))
        # Issue #667 — the ivar twin of the local stamp. This is the SAME-method half; the cross-method one
        # (`@mode = AppConfig::MODE` in `initialize`, read in a sibling) rides the class-ivar census and is
        # stamped by {#seed_instance_ivars}.
        bound = bound.with_published_constant_mark(:ivar, node.name) if
          published_constant_copy?(node.value, rhs_type, post_rhs)
        [rhs_type, bound]
      end

      def eval_cvar_write(node)
        rhs_type, post_rhs = sub_eval(node.value, scope)
        [rhs_type, post_rhs.with_cvar(node.name, rhs_type)]
      end

      def eval_global_write(node)
        rhs_type, post_rhs = sub_eval(node.value, scope)
        [rhs_type, post_rhs.with_global(node.name, rhs_type)]
      end

      # `Const = rvalue` / `A::Const = rvalue`. The pair is exactly what the default expression path produced before
      # this handler existed — the expression typer types the rvalue and the scope comes back unchanged, a constant
      # write binding no local — plus one walk the default path could not make. Issue #590: when the rvalue is a
      # class-creating meta call with a literal block (`Const = Struct.new(:text) do … end` and its `Data.define` /
      # `Class.new` / `Module.new` twins) the block is a CLASS BODY, `class_eval`'d on the class the call creates,
      # and it is entered as one here — the constant-write counterpart of {#evaluate_block_if_present}'s #319 arm.
      # Left to the default path the body was never walked at all, so `ScopeIndexer.propagate` handed every node
      # inside the ENCLOSING scope: at file top level a nil `self_type`, which made `Scope#toplevel?` hold inside
      # every `def` of the body and `call.unresolved-toplevel` fire on the struct's own member reads (and on
      # `attr_reader`, the very macro #319 silenced at every other position); inside a module, the module's own
      # `self` — a wrong receiver for every implicit-self call in the body.
      def eval_constant_write(node)
        result = [scope.type_of(node, tracer: tracer), forget_rebound_match_globals(scope, node.value)]
        call_node = meta_new_block_call(node)
        return result if call_node.nil?

        context = meta_new_constant_body_context(node, call_node)
        return result if context.nil?

        enter_meta_class_body(call_node.block, build_block_entry_scope(call_node, call_node.block), context)
        result
      end

      # The rvalue call whose block is the class body, for every spelling of the write. Issue #963: the `.freeze`
      # tail and the `||=` / `Const = Const || …` guard are unwrapped by {ScopeIndexer.meta_new_rvalue}, the same
      # recognition the index walks under, so the two passes enter the same node or neither does. The recognition
      # is still the loose one — a CallNode carrying a literal block — because the strict-argument shapes the
      # index declines are entered under an anonymous name rather than dropped.
      def meta_new_block_call(node)
        rvalue = ScopeIndexer.meta_new_rvalue(node)
        rvalue if rvalue.is_a?(Prism::CallNode) && rvalue.block.is_a?(Prism::BlockNode)
      end

      # The class context a meta-new rvalue block is entered under, or nil when the rvalue is not that shape. The
      # KEY must be the one `ScopeIndexer` filed the body's defs and member layout under, so the two passes agree —
      # which is why the decision is delegated to the ScopeIndexer's own recognition rather than re-spelled here. A
      # constant write whose rvalue `ScopeIndexer.meta_new_block_body` recognises is keyed by the constant's
      # qualified name, one frame appended to the lexical context exactly as a `class Const` keyword body would be
      # — the path spelling included since [#703](https://github.com/rigortype/rigor/issues/703). A shape the
      # ScopeIndexer's stricter argument check rejects (`Const = Struct.new(*names) do … end`) is registered under
      # the call site's anonymous name and is entered under that.
      def meta_new_constant_body_context(node, call_node)
        constant = meta_new_constant_context(node)
        return constant if constant

        anonymous = AnonymousMetaClass.name_for(call_node, scope.source_path)
        anonymous && [ClassFrame.new(name: anonymous, singleton: false)]
      end

      # The frame stack for a constant-keyed meta-new body, or nil when nothing keys it by a constant. A ROOTED
      # path write re-anchors at the top level the way a rooted `class ::Rooted::Bar` header does
      # ({#eval_class_or_module}), so the stack resets to that frame alone rather than gaining one under the
      # enclosure — `current_class_path` joins the stack, and `ScopeIndexer`'s own prefix resets there too.
      def meta_new_constant_context(node)
        return nil unless ScopeIndexer.meta_new_block_body(node)

        case node
        when Prism::ConstantWriteNode, Prism::ConstantOrWriteNode
          @class_context + [ClassFrame.new(name: node.name.to_s, singleton: false)]
        when Prism::ConstantPathWriteNode, Prism::ConstantPathOrWriteNode
          frame = ClassFrame.new(name: Source::ConstantPath.qualified_name(node.target), singleton: false)
          Source::ConstantPath.rooted?(node.target) ? [frame] : @class_context + [frame]
        end
      end

      # Slice 7 phase 3 — compound writes (||=, &&=, +=/-=/...) for every variable kind. Each handler:
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

      # `receiver[key] ||= default` — the Redmine `Query#as_params` idiom. After the `||=`, the next read at
      # `receiver[key]` is known non-nil; the next `<<` / `[]=` / other mutator runs against a Tuple / Hash carrier
      # instead of the `Constant[nil]` an empty `HashShape{}` lookup would otherwise fold to.
      #
      # The handler: 1. Types the equivalent `receiver[key]` read under the
      #    entry scope (so any previously-recorded narrowing for
      #    the same address is already applied).
      # 2. Types the rvalue under the entry scope. 3. Computes `union(narrow_truthy(current), rhs)` — the
      #    standard `||=` result shape used by locals / ivars /
      #    cvars / globals.
      # 4. Records the result type in the post-scope as a
      #    narrowing keyed on `(receiver_kind, receiver_name,
      #    literal_key)` when both receiver and key are stable
      #    (see {Inference::IndexedNarrowing}). Unstable shapes
      #    fall through to "no scope effect", matching the old
      #    `Prism::IndexOrWriteNode` default-branch behaviour.
      #
      # The expression value is the result type, matching Ruby's semantics: `(x = params[:f] ||= []); x` observes the
      # post-`||=` value, not the rvalue alone.
      def eval_index_or_write(node)
        _rhs_type, post_rhs = sub_eval(node.value, scope)
        result_type = index_write_stored_type(node, scope)

        # A narrowing is keyed on ONE literal slot — `a[k]` — but a multi-index `||=` reads and
        # stores a splice REGION (`a[0, 1] ||= v`), so keying the result on the first index would
        # record `a[0]`'s type as the region answer: `a[0, 1] ||= []` would claim `a[0]` non-nil
        # where the store splices nothing and `a[0]` stays nil at runtime. Decline the record for
        # any form but the single-index one.
        key_node = single_index_argument(node)
        address = key_node && IndexedNarrowing.stable_address(node.receiver, key_node)
        # Issue #544 — a receiver with an untracked (Dynamic / Top) constituent can hold a caller-supplied
        # slot value the `||=` keeps, so the recorded default would invent a fact; decline the record.
        address = nil if address && !IndexedNarrowing.fully_tracked_receiver_type?(scope.type_of(node.receiver))
        post = post_rhs
        # Widen BEFORE recording the narrowing: rebinding the receiver drops the per-slot narrowings keyed on it, so
        # the reverse order would trade this feature away for the widening. The two are complementary — the shape
        # forgets that the collection is still empty, the narrowing remembers that THIS slot is now non-nil.
        post = IndexWriteWidening.widen(node: node, current_scope: post,
                                        arg_types: index_write_arg_types(node, result_type))
        post = post.with_indexed_narrowing(*address, result_type) if address

        [result_type, forget_rebound_match_globals(post, node)]
      end

      # `h[k] &&= v` / `h[k] += v`. Neither had a handler, so both fell to `evaluate`'s default — typed as a pure
      # expression, scope untouched — and the receiver never widened. They store through `[]=` exactly as
      # `eval_index_or_write` does, so they take the same widening; the stored value is the compound result —
      # `falsey(h[k]) | v` for `&&=`, the dispatched `h[k] + v` for `+=` — not the rvalue alone.
      def eval_index_write(node)
        _rhs_type, post_rhs = sub_eval(node.value, scope)
        stored = index_write_stored_type(node, scope)
        widened = IndexWriteWidening.widen(node: node, current_scope: post_rhs,
                                           arg_types: index_write_arg_types(node, stored))
        [stored, forget_rebound_match_globals(widened, node)]
      end

      # `[index_type..., stored_value_type]` for an index-write node, shaped exactly like a `[]=`
      # call's argument list so the widening seam can join it the same way (issue #560) — a
      # two-index compound write (`a[0, 1] += v`) keeps BOTH index arguments ahead of the stored
      # value, which is what lets the join read it as a splice (issue #1140). The stored value is
      # what the write put in the slot — for a compound write {#index_write_stored_type}'s
      # compound result (`t[0] += 5` stores the already-computed `t[0] + 5`), for an index target
      # the value its owner stores (the slot {MultiTargetBinder} decomposed, the `for` element, the
      # rescued exception) — which is the whole point: it
      # is the value the retained element evidence provably no longer covers. Returns `[]` when the
      # key is unresolvable, which reproduces the pre-join widening.
      # The index arguments are typed, and the receiver's joinability read, in `type_scope`: the
      # evaluator's entry scope by default; a `for` index passes its post-collection scope and a
      # rescue reference its arm's entry scope, the nearest the engine has to where Ruby evaluates
      # them (each iteration, the moment of the catch).
      # There is deliberately NO `rescue` here. `Scope#type_of` is a total query over well-formed Prism input,
      # so a raise is an engine bug, and swallowing it would silently downgrade a live seam to "no evidence" —
      # the join would quietly stop happening with nothing to show for it. Let it reach the runner's
      # internal-error path, where it is visible.
      def index_write_arg_types(node, stored_type, type_scope: scope)
        args = node.arguments
        return MutationWidening::NO_ARG_TYPES if args.nil? || stored_type.nil?
        return MutationWidening::NO_ARG_TYPES unless MutationWidening.joinable_receiver?(node.receiver, type_scope)

        list = args.respond_to?(:arguments) ? args.arguments : args
        # A splat argument is marked `nil` — its expansion decides the store's arity at
        # runtime, which an untyped index type could not express (issue #1140).
        list.map { |arg| arg.is_a?(Prism::SplatNode) ? nil : type_scope.type_of(arg, tracer: tracer) } + [stored_type]
      end

      # What a compound index write stores through `[]=` — `a[i] ||= v` stores `truthy(a[i]) | v`,
      # `a[i] &&= v` stores `falsey(a[i]) | v`, and `a[i] op= v` stores the dispatched `a[i] op v`:
      # `a[0, 1] += [2]` reads `a[0, 1] + [2]`, not `[2]` (issue #1140). It is also the node's value
      # outside {#index_compound_write_value}'s memoizing `||=`. That method passes the `current` read
      # and the `rhs` it already typed, so a nested `(a[i] ||= {})[j] ||= v` chain types each level's
      # receiver once rather than doubling per level. Any other node falls back to its own type (an
      # index target — a multi-assign slot, a `for` index, a rescue reference — keeps its untyped
      # answer).
      def index_write_stored_type(node, type_scope, current: nil, rhs: nil)
        case node
        when Prism::IndexOrWriteNode, Prism::IndexAndWriteNode
          current ||= index_read_type(node, type_scope)
          narrowed = if node.is_a?(Prism::IndexOrWriteNode)
                       Narrowing.narrow_truthy(current)
                     else
                       Narrowing.narrow_falsey(current)
                     end
          Type::Combinator.union(narrowed, rhs || type_scope.type_of(node.value, tracer: tracer))
        when Prism::IndexOperatorWriteNode
          MethodDispatcher.dispatch(
            receiver_type: index_read_type(node, type_scope), method_name: node.binary_operator,
            arg_types: [type_scope.type_of(node.value, tracer: tracer)],
            environment: type_scope.environment
          ) || Type::Combinator.untyped
        else
          type_scope.type_of(node, tracer: tracer)
        end
      end

      # True when {#index_compound_write_value} reads the `||=` `node` as the memoization idiom's rvalue: the slot
      # reads wholly gradual, the rvalue can store something truthy, and no block-return pass marked the site.
      def memoizing_index_read?(node, current, rhs)
        current.is_a?(Type::Dynamic) && !Narrowing.narrow_truthy(rhs).is_a?(Type::Bot) &&
          !scope.repeated_or_write?(node)
      end

      # The `receiver[i]` read a compound index write performs before storing — the `[]` read on the
      # receiver's own type with the write's index arguments (a splat reads untyped), refined by a
      # recorded indexed narrowing when the single-index form names a stable slot. The read takes the
      # tiers a plain `receiver[i]` call does ({ExpressionTyper#implicit_index_read_type}), so a project
      # `[]` with no signature answers from its body.
      def index_read_type(node, read_scope)
        receiver = read_scope.type_of(node.receiver, tracer: tracer)
        args = node.arguments
        list = args.respond_to?(:arguments) ? args.arguments : Array(args)
        index_types = list.map do |arg|
          arg.is_a?(Prism::SplatNode) ? Type::Combinator.untyped : read_scope.type_of(arg, tracer: tracer)
        end

        key = single_index_argument(node)
        address = key && IndexedNarrowing.stable_address(node.receiver, key)
        narrowed = address && read_scope.indexed_narrowing(*address)
        return narrowed if narrowed

        typer = ExpressionTyper.new(scope: read_scope, tracer: tracer)
        typer.implicit_index_read_type(node, receiver, index_types) || Type::Combinator.untyped
      end

      # Argument types for a straight-line content mutator (`arr << x`, `h[k] = v`).
      #
      # **The two scopes are different on purpose.** `current_scope` is the post-call scope the widening will
      # actually rewrite, so the receiver gate has to ask IT whether the binding is still a literal-shape
      # carrier — asking the entry scope could green-light a join the widening then declines, or miss one it
      # would make. The arguments, though, are evaluated BEFORE the call in Ruby's order, so their types come
      # from the entry `scope`; that also matches how the block path types its own mutator arguments against
      # the block-ENTRY scope. Between the two points the only edits to the scope are the block / escape /
      # plugin-assertion helpers above, none of which can rebind a mutator call's argument expressions.
      #
      # Both gates are about cost, not correctness — the join declines on its own in either case.
      # `Scope#type_of` builds a fresh `ExpressionTyper` per call and memoizes nothing, so typing arguments a
      # join will not consume is pure overhead, and `<<` on a String buffer is one of the commonest calls
      # there is. The content-adder table skips a non-adding mutator (`pop`, `sort!`); `joinable_receiver?`
      # skips a receiver whose current binding is not a literal-shape carrier.
      # Both mutator-receiver widenings, against one typing of the call's arguments: the bindings the
      # receiver NAMES ({MutationWidening.widen_after_call}) and, when it names none because the
      # receiver is an element read into a local, that element's pin inside its container
      # ({ElementReadWidening.widen_element_read}, issue #643).
      def widen_mutated_receivers(call_node, current_scope)
        arg_types = mutator_arg_types(call_node, current_scope)
        widened = MutationWidening.widen_after_call(call_node: call_node, current_scope: current_scope,
                                                    arg_types: arg_types)
        ElementReadWidening.widen_element_read(call_node: call_node, current_scope: widened, arg_types: arg_types)
      end

      # `tr!` / `tr_s!` are typed too: whether they can empty a `non-empty-string` turns on their replacement argument.
      def mutator_arg_types(call_node, current_scope)
        unless ContentJoin::CONTENT_ADDERS.include?(call_node.name) || StringMutation::TRANSLATORS.include?(call_node.name)
          return MutationWidening::NO_ARG_TYPES
        end
        unless MutationWidening.joinable_receiver?(call_node.receiver, current_scope) ||
               ElementReadWidening.joinable_element_read?(call_node.receiver, current_scope)
          return MutationWidening::NO_ARG_TYPES
        end

        content_arg_types(call_node, operand_scope, @operand_types)
      end

      # The index node of an index-write when it holds exactly one index argument — the only form
      # whose stored value lands on a nameable slot (`a[k]`). Multi-index forms address a splice
      # region and answer `nil`.
      def single_index_argument(node)
        args = node.arguments
        return nil if args.nil?

        list = args.respond_to?(:arguments) ? args.arguments : args
        list.size == 1 ? list.first : nil
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

      # `a, b = rhs` — Slice 5 phase 2 sub-phase 2 destructuring. Evaluates the right-hand side under the entry scope,
      # then decomposes its type against the multi-write target tree (Prism::MultiWriteNode#lefts/rest/rights, including
      # nested Prism::MultiTargetNode for the `(b, c)` form). Tuple-shaped right-hand sides produce per-slot types
      # element-wise, an `Array[T]` binds each fixed slot to `T` with the optimistic-nil-free mark (issue #1093), a
      # union distributes over its members and a value with no implicit `to_ary` binds as `[rhs]` (issue #1094), and
      # other carriers fall back to `Dynamic[Top]` per slot. Instance-variable targets bind by the same rules, with the
      # optimistic mark recorded per ivar (issue #1110). A right-hand side that is itself optimistically nil-free
      # (`k, v = pairs.first`, or a local bound to one) marks every name it binds, and a literal one
      # (`x, y = pairs.first, 1`) marks each slot by its element: a miss binds `nil` to every such slot
      # ({Inference::OptimisticOrigin.destructuring_marks}). The expression value is the right-hand side type
      # (matching Ruby's semantics: `(a, b = [1, 2])` evaluates to `[1, 2]`).
      #
      # An index target (`h[:a], z = 1, 2`, nested or splatted too) stores its slot through `[]=`, so its receiver
      # widens here exactly as the plain store `h[:a] = 1` widens it, joining the slot's value as content evidence
      # (issue #560) — otherwise the literal survives and a later `h[:a] == 0` folds on its stale `0`. The widening
      # runs AFTER the bindings: Ruby evaluates a target's receiver before any target is assigned, so
      # `h, h[:a] = h, 1` stores into the object `h` is bound to afterwards, and widening first would let the
      # binding of `h` restore the literal. When a target rebinds the receiver's variable to another object
      # instead, widening that one only loses precision.
      #
      # The stored value is the slot the binder decomposed, softened as a local in the same position is. The
      # ADR-57 softening that drops a slot's `nil` is honest for a local because of the optimistic mark, which a
      # stored value never carries — but it does not need one here: the straight-line join always adds the
      # `Dynamic[top]` floor ({MutationWidening#gradual_floor}), so no fold can rest on the dropped `nil`. Joining
      # the `nil` instead would fire `call.possible-nil-receiver` on the correlated guard the softening exists for,
      # `r[:k], r[:v] = h.find { … }; r[:v].upcase if r[:k]`.
      #
      # Each store then drops the indexed narrowing it overwrites, through the same
      # {IndexedNarrowing.invalidate_indexed_write} a `[]=` call takes (it reads only `receiver` and `arguments`,
      # which an index target shares): the widening carries a Nominal receiver's slot narrowings across its
      # rebind, so `m[:a] ||= "d"; m[:a], y = 1, 2` would otherwise keep reading `"d"`.
      def eval_multi_write(node)
        rhs_type, post_rhs = sub_eval(node.value, scope)
        marks = Inference::OptimisticOrigin.destructuring_marks(node.value, post_rhs)
        bound = MultiTargetBinder.bind_marked(node, rhs_type, optimistic: marks, scope: post_rhs)
        post = widen_index_targets(bound, bound.apply_to(post_rhs), type_scope: scope)
        [rhs_type, widen_attribute_targets(node, post)]
      end

      # `recv.attr ||= v` / `&&=` / `op=` calls the writer `attr=` on `recv`, so a writer the mutation widening
      # responds to widens the receiver as the plain call does: `h.default ||= 0` reopens `h` as `h.default = 0`
      # does ({HashLookupMutation}). The node's value is typed as before; the widening is its only scope effect.
      def eval_attribute_compound_write(node)
        widened = widen_attribute_write(node.receiver, node.write_name, scope)
        [scope.type_of(node, tracer: tracer), forget_rebound_match_globals(widened, node)]
      end

      # The scope effect of calling the writer `writer` on `receiver` outside a `CallNode`: the receiver widening, and
      # the receiver-wide drop of recorded `receiver[key]` narrowings `IndexedNarrowing` makes after a mutator call.
      def widen_attribute_write(receiver, writer, current_scope)
        widened = MutationWidening.widen_receiver_aliases(receiver, writer, current_scope)
        stable = IndexedNarrowing.stable_receiver(receiver)
        return widened unless stable && IndexedNarrowing.mutator?(writer)

        widened.without_indexed_narrowings_for(*stable)
      end

      # The attribute targets of a multi-write (`h.default, x = 0, 1`), nested ones included, each widening its
      # receiver as the plain writer call would.
      def widen_attribute_targets(node, post)
        targets = [*node.lefts, node.rest, *node.rights]
        targets.reduce(post) do |acc, target|
          target = target.expression if target.is_a?(Prism::SplatNode)
          case target
          when Prism::CallTargetNode then widen_attribute_write(target.receiver, target.name, acc)
          when Prism::MultiTargetNode then widen_attribute_targets(target, acc)
          else acc
          end
        end
      end

      # Widens the receiver of every index target a {MultiTargetBinder} result reports, over the scope its bindings
      # were applied to — the multi-write and the `for a, h[:k] in pairs` index share it.
      def widen_index_targets(bound, post, type_scope:)
        bound.index_targets.reduce(post) do |acc, (target, stored)|
          widen_index_target(target, stored, acc, type_scope: type_scope)
        end
      end

      # An index target (`Prism::IndexTargetNode`) stores `stored` through `[]=` on its receiver wherever it
      # appears — a multi-assign slot, a `for` index, a rescue reference — so its receiver widens exactly as the
      # plain store `h[:a] = v` widens it, joining `stored` as content evidence (issue #560), and drops the
      # `h[:a] ||= default` narrowing on the slot it overwrote, as `eval_call` drops it after a `[]=` — the
      # widening carries slot narrowings across the rebind, so without the drop `h[:a]` keeps reading the default.
      # `type_scope` types the index arguments and gates the evidence (`joinable_receiver?`); `current_scope` is
      # the one widened.
      def widen_index_target(target, stored, current_scope, type_scope:)
        widened = IndexWriteWidening.widen(node: target, current_scope: current_scope,
                                           arg_types: index_write_arg_types(target, stored, type_scope: type_scope))
        IndexedNarrowing.invalidate_indexed_write(target, widened)
      end

      # `if pred; t; (elsif/else)?` runs the predicate first (its post-scope is shared by both branches), then asks
      # `Rigor::Inference::Narrowing` for the truthy and falsey edge scopes derived from the predicate. Slice 6 phase 1
      # narrows local-variable bindings on truthiness, `nil?`, `!`, and `&&`/ `||` predicate composition; predicates the
      # analyser does not specialise return the post-predicate scope unchanged on both edges, preserving the Slice 3
      # phase 2 behaviour. The branches' result types are unioned; their post-scopes are joined with nil-injection on
      # half-bound names so a name set in one branch but not the other is observable as `T | nil` after the if.
      def eval_if(node)
        pred_type, post_pred, truthy_scope, falsey_scope = eval_with_edges(node.predicate, scope)

        # When the predicate is a known-truthy / known-falsey type (notably `Constant[true]` / `Constant[false]` after
        # the constant-fold tier), only the live branch contributes a type and a post-scope. The dead branch is skipped
        # so the result type is precise (`Constant[:even]` instead of the joined `Constant[:even] | Constant[:odd]`).
        live = live_branch_for_if(node, pred_type, post_pred, truthy_scope, falsey_scope)
        if live
          live_type, _live_scope = live
          # When the provably-live then-branch terminates and there is no else, apply the same falsey-scope narrowing as
          # the standard early-return path below. Without this, `return if @ivar.nil?` with an ivar seeded as
          # Constant[nil] (making nil? = Constant[true] and the then-branch "provably live") propagates the un-narrowed
          # nil scope past the guard instead of Bot.
          return [live_type, falsey_scope] if branch_terminates?(node.statements, live_type) && node.subsequent.nil?

          return live
        end

        then_type, then_scope = eval_branch_or_nil(node.statements, truthy_scope)
        else_type, else_scope = eval_branch_or_nil(node.subsequent, falsey_scope)
        # Slice 7 phase 14 — early-return narrowing. When the then-branch unconditionally exits (return / next / break /
        # raise) and there is no else, the post-scope is the falsey edge of the predicate (subsequent statements observe
        # the predicate-was-false world). The then-body is the *skipped* path, so the bare narrowing (no body
        # assignments) is the correct continuation.
        return [Type::Combinator.union(then_type, else_type), falsey_scope] \
          if branch_terminates?(node.statements, then_type) && node.subsequent.nil?
        # Symmetric case: the else / elsif-chain (`node.subsequent`) unconditionally exits, so the only surviving path
        # is the then-branch that RAN. The continuation must therefore carry `then_scope` — the predicate-truthy
        # narrowing PLUS the then-body's assignments — not the bare `truthy_scope`. Returning `truthy_scope` drops every
        # local the then-body bound, leaving it unbound for any enclosing merge to spuriously nil-inject: e.g. the inner
        # `elsif … else raise` of `if a then x=… elsif b then x=… else raise end` would return with `x` unbound, and the
        # outer if's join would then read `x` as `… | nil` and fire a false `possible-nil-receiver` (liquid v5.x sweep,
        # Event 3).
        return [Type::Combinator.union(then_type, else_type), then_scope] \
          if branch_terminates?(node.subsequent, else_type) && node.statements

        [
          Type::Combinator.union(then_type, else_type),
          join_with_nil_injection(then_scope, else_scope)
        ]
      end

      # `unless pred; t; else; e; end`. Same shape as `if`, but Prism exposes the else-branch as `else_clause` (no elsif
      # chain). The narrower's truthy/falsey edges are routed in swapped form because `unless` runs its body when the
      # predicate is falsey.
      def eval_unless(node)
        pred_type, post_pred, truthy_scope, falsey_scope = eval_with_edges(node.predicate, scope)

        live = live_branch_for_unless(node, pred_type, post_pred, truthy_scope, falsey_scope)
        if live
          live_type, _live_scope = live
          # Mirror of the eval_if fix: when the provably-live unless-body terminates and there is no else, apply the
          # truthy-scope narrowing so `return unless @ivar` with a nil-seeded ivar doesn't propagate the nil scope past
          # the guard.
          return [live_type, truthy_scope] if branch_terminates?(node.statements, live_type) && node.else_clause.nil?

          return live
        end

        then_type, then_scope = eval_branch_or_nil(node.statements, falsey_scope)
        else_type, else_scope = eval_branch_or_nil(node.else_clause, truthy_scope)
        # Slice 7 phase 14 — same early-return narrowing as `if`: when the body unconditionally exits and there is no
        # else, the post-scope is the truthy edge (the body is the skipped path, so the bare narrowing is correct).
        return [Type::Combinator.union(then_type, else_type), truthy_scope] \
          if branch_terminates?(node.statements, then_type) && node.else_clause.nil?
        # Symmetric to the `if` else-exits fix: when the else-clause exits, the surviving path is the unless-body that
        # RAN, so the continuation carries `then_scope` (the predicate-falsey narrowing PLUS the body's assignments),
        # not the bare `falsey_scope` — otherwise body-bound locals are dropped and an enclosing merge nil-injects them.
        return [Type::Combinator.union(then_type, else_type), then_scope] \
          if branch_terminates?(node.else_clause, else_type) && node.statements

        [
          Type::Combinator.union(then_type, else_type),
          join_with_nil_injection(then_scope, else_scope)
        ]
      end

      # Returns the `[type, post_scope]` of the live branch when the predicate is provably truthy / falsey, else nil so
      # the caller falls through to the standard both-branch evaluation. Constant `true`/`false` is the obvious trigger;
      # non-falsey carriers like `Nominal[Integer]` (Integer is always truthy in Ruby — including 0) also collapse the
      # dead else.
      def live_branch_for_if(node, pred_type, post_pred, truthy_scope, falsey_scope)
        truthy_scope, falsey_scope = live_branch_scopes(node.predicate, post_pred, truthy_scope, falsey_scope)
        case branch_certainty(node.predicate, pred_type, post_pred)
        when :truthy then eval_branch_or_nil(node.statements, truthy_scope)
        when :falsey then eval_branch_or_nil(node.subsequent, falsey_scope)
        end
      end

      def live_branch_for_unless(node, pred_type, post_pred, truthy_scope, falsey_scope)
        truthy_scope, falsey_scope = live_branch_scopes(node.predicate, post_pred, truthy_scope, falsey_scope)
        case branch_certainty(node.predicate, pred_type, post_pred)
        when :truthy then eval_branch_or_nil(node.else_clause, truthy_scope)
        when :falsey then eval_branch_or_nil(node.statements, falsey_scope)
        end
      end

      # A provably-live branch runs from the post-predicate scope, un-narrowed, except under an `&&` / `||` whose right
      # operand writes ({#eval_with_edges}): there the joined scope still reads the write as possibly `nil`, and the
      # live edge is the one on which the right operand ran (`if text && (w = text.size)` with `text` a String).
      def live_branch_scopes(predicate, post_pred, truthy_scope, falsey_scope)
        and_or_right_effects?(predicate) ? [truthy_scope, falsey_scope] : [post_pred, post_pred]
      end

      # ADR-47 WD5 — a decidable **version guard** answers first (#627). `RUBY_VERSION >= "3.1"` and the
      # `Gem::Version.new(…) <cmp> Gem::Version.new(…)` spellings fold from literals the analyzer can read, so the arm
      # that cannot run on the Ruby being checked with is elided exactly as `if false`'s is: it is never evaluated, so
      # it contributes no diagnostics and its writes do not join into the post-`if` scope. The guard expression's own
      # type stays `bool`, which is what keeps `flow.always-truthy-condition` off it — a version guard is intentional,
      # not a redundant condition. See {VersionGuard} for the folded shapes and the reference-Ruby premise.
      def branch_certainty(predicate, pred_type, post_pred)
        guard = VersionGuard.verdict(predicate)
        return guard if guard
        return nil if optimistic_carrier?(predicate, post_pred)

        Narrowing.predicate_certainty(pred_type)
      end

      # ADR-101 — the branch elision MUST NOT conclude truthiness from a carrier whose nil-freeness rests on
      # the `%a{implicitly-returns-nil}` that `RbsDispatch` reads past. Such a value is optimistic, not proof
      # (see {Inference::OptimisticOrigin} and docs/internal-spec/inference-engine.md), so eliding an arm on
      # it deletes a branch the program really takes when the lookup misses.
      #
      # The decline lives here and NOT in `Narrowing.falsey_nominal?` / `.narrow_falsey`: `&&=` / `||=` and
      # the and/or surviving-left edge read those too, and widening the falsey fragment there would re-admit
      # `nil` into a bound local and buy `possible nil receiver` false positives — a soundness fix paid for
      # in FPs, which is the wrong trade.
      def optimistic_carrier?(predicate, scope)
        !optimistic_origin_for(predicate, scope).nil?
      end

      def eval_else(node)
        return [Type::Combinator.constant_of(nil), scope] if node.statements.nil?

        sub_eval(node.statements, scope)
      end

      # `case pred; when ...; when ...; else; end` and the pattern- matching variant. The predicate's post-scope is
      # shared with every branch (including the else); branches are evaluated independently and merged with
      # nil-injection so half-bound names degrade to `T | nil`.
      def eval_case(node)
        subject_type, post_pred = node.predicate ? sub_eval(node.predicate, scope) : [nil, scope]
        branch_results, falsey_scope = eval_case_when_branches(subject_type, node.predicate, node.conditions, post_pred)
        if pattern_case_matches_every_path?(node, branch_results)
          return unmatched_pattern_result(branch_results, node.conditions)
        end

        else_result = eval_case_else(node.else_clause, falsey_scope)

        all_results = [*branch_results, else_result]
        branch_nodes = [*node.conditions, node.else_clause]
        [
          Type::Combinator.union(*all_results.map(&:first)),
          join_case_branch_scopes(all_results, branch_nodes)
        ]
      end

      # Issue #1122 — a `case/in` with no `else` has no "nothing matched" path: CRuby raises
      # `NoMatchingPatternError` when no pattern matches, so the continuation is reached only through a
      # matched clause. The shared `else` arm would inject that impossible path anyway — `Constant[nil]`
      # for the type and the entry scope for the continuation, which nil-injects every pattern-bound name.
      # `case [1, "a"] in [i, s] then i end; i + 1` then read as `i + 1` on `1 | nil` and drew a false
      # `possible nil receiver` on a name bound on every path that reaches it. A `case/when` keeps the
      # arm: a subject matching no clause really does fall through as `nil`.
      def pattern_case_matches_every_path?(node, branch_results)
        node.is_a?(Prism::CaseMatchNode) && node.else_clause.nil? && !branch_results.empty?
      end

      def unmatched_pattern_result(branch_results, branch_nodes)
        [Type::Combinator.union(*branch_results.map(&:first)), join_case_branch_scopes(branch_results, branch_nodes)]
      end

      # Joins the post-scopes of every `when`/`in`/`else` branch, dropping the scope of any branch that terminates
      # (raises / returns / throws / types to `Bot`) before the merge — control never falls through such a branch, so
      # its half-bound locals must not nil-inject the names a live sibling branch assigned. Mirrors the
      # `branch_terminates?` rule `eval_if`/`eval_unless` already apply to the if/else merge: e.g. `case x; when 1 then
      # v="a"; when 2 then v="b"; else raise; end` keeps `v: "a" | "b"` instead of `... | nil`. When every branch
      # terminates the merge is itself unreachable; fall back to the full join so the continuation scope stays
      # well-formed.
      def join_case_branch_scopes(results, nodes)
        live = []
        results.each_with_index do |(type, branch_scope), i|
          live << branch_scope unless branch_terminates?(nodes[i], type)
        end

        live = results.map(&:last) if live.empty?
        reduce_scopes_with_nil_injection(live)
      end

      def eval_case_when_branches(subject_type, subject, conditions, entry_scope)
        results = []
        falsey_scope = entry_scope
        conditions.each do |branch|
          # ADR-47 WD2 — record the scope ENTERING this clause (the subject narrowed by every earlier clause's negation)
          # on the clause's first condition node, so `flow.unreachable-clause` can tell a prior-exhausted subject (entry
          # already `bot`) from a per-clause-disjoint one (entry concrete, this clause disjoint). `on_enter`-only (no
          # recursion) so no condition sub-expression is newly typed; `propagate` preserves the entry because it already
          # keys the node.
          record_clause_entry_scope(branch, falsey_scope)
          body_scope, falsey_scope = branch_body_and_falsey_scopes(subject_type, subject, branch, falsey_scope)
          results << sub_eval(branch, body_scope)
        end
        [results, falsey_scope]
      end

      # ADR-47 WD2/WD3 — record the scope ENTERING a `when`/`in` clause on the node `flow.unreachable-clause` reads to
      # classify a dead clause (`when`: first condition; `in`: the pattern). `on_enter`-only so no sub-expression is
      # newly typed; `propagate` preserves it.
      def record_clause_entry_scope(branch, entry_scope)
        node =
          case branch
          when Prism::WhenNode then branch.conditions.first
          when Prism::InNode then branch.pattern
          end
        @on_enter&.call(node, entry_scope) if node
      end

      # Returns `[body_scope, updated_falsey_scope]` for a single branch. `WhenNode` branches narrow through
      # `Narrowing.case_when_scopes`. `InNode` branches narrow soundly only for a bare class pattern (`in C` / `in C =>
      # x`, pure `is_a?`); every other pattern keeps the conservative "body = entry + bindings, falsey unchanged" shape.
      # `subject_type` is the predicate's type, which an `in` branch's pattern decomposes to type the names it binds.
      def branch_body_and_falsey_scopes(subject_type, subject, branch, falsey_scope)
        if branch.is_a?(Prism::InNode)
          in_branch_body_and_falsey_scopes(subject_type, subject, branch, falsey_scope)
        else
          when_conditions = branch.respond_to?(:conditions) ? branch.conditions : []
          Narrowing.case_when_scopes(subject, when_conditions, falsey_scope)
        end
      end

      # ADR-47 WD3a — a bare class pattern matches on `C === subject`, i.e. exactly `subject.is_a?(C)` with no
      # deconstruction, so it narrows like `when C`: the body sees the subject narrowed to `C` and the next clause's
      # falsey scope has `C` removed. Other patterns can fail to match even when a class test would pass (deconstruction
      # arity, hash keys, ...), so removing anything from the falsey scope would be unsound — they keep the conservative
      # shape.
      def in_branch_body_and_falsey_scopes(subject_type, subject, branch, falsey_scope)
        class_node = bare_class_pattern_node(branch.pattern)
        unless class_node
          bound = apply_in_pattern_bindings(subject_type, subject, branch.pattern, falsey_scope)
          return [bound, falsey_scope]
        end

        truthy_scope, narrowed_falsey = Narrowing.case_when_scopes(subject, [class_node], falsey_scope)
        [apply_in_pattern_bindings(subject_type, subject, branch.pattern, truthy_scope), narrowed_falsey]
      end

      # The class-constant node of a `in C` / `in C => x` pattern (the only `in` shapes whose match is pure `is_a?`), or
      # nil for any pattern that deconstructs, binds, or matches a value.
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

      # `begin; body; rescue ...; else; ensure; end`. The body and the rescue chain are alternative exit paths whose
      # scopes are joined with nil-injection. The else-clause replaces the body's value when present (matching Ruby
      # semantics: else runs only if the body raises no exception). The ensure-clause runs but does not contribute to
      # the value; its scope effects are layered on the joined exit scope so locals bound exclusively in `ensure` stay
      # observable.
      def eval_begin(node)
        jump_marks = ensure_jump_marks(node)
        entry = scope
        edge = retry_edge_for(node)
        primary_type, primary_scope = eval_begin_primary_under(node, entry, edge: edge)
        rescue_chain = collect_rescue_chain_results(node.rescue_clause, entry, edge: edge)

        # B2.1 — retry-edge widening. When a `retry` in the rescue chain targets this `begin`, control re-enters the
        # primary body carrying every rebind made before the retry: the arm's (`rescue; tries += 1; retry; end`), and
        # the primary body's own, since it can raise after any prefix of itself (`begin; tries += 1; raise if tries < 3;
        # rescue; retry; end`). Without the widening the re-entry keeps `tries: Constant[0]` and the predicate folds.
        # {#eval_retried_begin} re-evaluates the primary body AND the rescue chain under a widened entry.
        retried = edge && eval_retried_begin(node, entry, edge)
        primary_type, primary_scope, rescue_chain = retried if retried

        live_rescues = live_rescue_results(rescue_chain)
        if live_rescues.empty?
          exit_type = primary_type
          exit_scope = primary_scope
        else
          exit_type = Type::Combinator.union(primary_type, *live_rescues.map(&:first))
          exit_scope = reduce_scopes_with_nil_injection([primary_scope, *live_rescues.map(&:last)])
        end

        if node.ensure_clause
          carry_jumps_through_ensure(node.ensure_clause, jump_marks)
          _ensure_type, ensure_scope = sub_eval(node.ensure_clause, exit_scope)
          exit_scope = ensure_scope
        end

        [exit_type, exit_scope]
      end

      # Rescue arms that never fall through contribute neither a type fragment NOR a scope to the post-begin flow —
      # control left the `begin` via that arm. That is an arm ending in `return`, `next`, `break`, `raise`, `throw`,
      # `exit`, `abort` or `fail`, and one whose type is `bot` ({#branch_terminates?}): an arm ending in `retry`, or in
      # `tries < 3 ? retry : raise`, leaves back into the primary body, and joining its scope would carry the retry
      # edge's widened entry past the `begin`. Mirrors the `eval_if` / `eval_unless` / `eval_and_or` early-return
      # narrowing. Without this filter, a `rescue ... return` on a local bound only in the primary body nil-injects that
      # local across the join, defeating the rescue arm's whole point of guaranteeing the primary local is in scope for
      # downstream statements.
      def live_rescue_results(rescue_chain)
        rescue_chain.reject { |(arm_type, _), arm_node| branch_terminates?(arm_node.statements, arm_type) }
                    .map(&:first)
      end

      # The jump sinks' sizes as a `begin … ensure` starts, or nil for a `begin` without `ensure`: every `next` /
      # `break` scope recorded past these marks leaves through that `ensure`.
      def ensure_jump_marks(node)
        return nil unless node.ensure_clause

        [@next_scope_sink&.size, Thread.current[BREAK_SINK_KEY]&.size]
      end

      # A `next` or `break` inside `begin … ensure` leaves only once the `ensure` clause has run, so each jump scope the
      # clauses recorded is replaced by that scope carried through the clause: `buf = nil; next if c` under `ensure
      # buf = +"reset"` leaves with `"reset"`, never `nil`. The clause is evaluated without recording into the
      # per-node scope index, which keeps the fall-through's visit.
      def carry_jumps_through_ensure(ensure_clause, marks)
        next_mark, break_mark = marks
        carry_through_ensure(ensure_clause, @next_scope_sink, next_mark)
        carry_through_ensure(ensure_clause, Thread.current[BREAK_SINK_KEY], break_mark)
      end

      def carry_through_ensure(ensure_clause, sink, mark)
        return if sink.nil? || mark.nil?

        (mark...sink.size).each do |index|
          jump, jump_scope = sink[index]
          sink[index] = [jump, sub_eval(ensure_clause, jump_scope, **UNRECORDED).last]
        end
      end

      # `BeginNode#statements` is the primary body; when an else-clause is present, its value replaces the body's per
      # Ruby semantics (the else runs only when no exception was raised), but the body's scope effects still apply
      # because the body did run before the else.
      #
      # `edge`, when given, collects every scope the primary body could raise from: the scope after each statement of
      # its frame ({#record_raise_points}), and the scope it ends with. The else-clause is not among them: what it
      # raises is not rescued here.
      def eval_begin_primary_under(node, entry_scope, edge: nil)
        body_type, body_scope =
          if node.statements
            with_raise_frame(edge) { sub_eval(node.statements, entry_scope) }
          else
            [Type::Combinator.constant_of(nil), entry_scope]
          end
        edge.raise_scopes << body_scope if edge

        if node.else_clause
          else_type, else_scope = sub_eval(node.else_clause, body_scope)
          [else_type, else_scope]
        else
          [body_type, body_scope]
        end
      end

      # B2.1 — what one pass over a `begin` whose rescue chain retries collects: the `retry` nodes that target it, the
      # arms holding them, the nodes of its primary body's frame and the names that frame writes, and the scopes control
      # carries back into the primary body — at each point the body can raise from (`raise_scopes`), and at each of
      # those `retry`s together with the post-scope of each arm holding one (`retry_scopes`).
      RetryEdge = Data.define(:retries, :retrying_arms, :frame, :body_writes, :raise_scopes, :retry_scopes) do
        def fresh = with(raise_scopes: [], retry_scopes: [])

        def merge(other)
          with(raise_scopes: raise_scopes + other.raise_scopes, retry_scopes: retry_scopes + other.retry_scopes)
        end
      end
      private_constant :RetryEdge

      # The entry and edge one widening reads, whether it widens to the Nominal envelope or keeps literals, and, per
      # name, the rebinds it has already weighed: a statement-by-statement body shares one binding object across every
      # scope until the name is rebound, and weighing each copy again is what made a long body quadratic.
      RetryWidening = Data.define(:entry, :edge, :envelope, :weighed) do
        def initialize(entry:, edge:, envelope:, weighed: {}) = super
      end
      private_constant :RetryWidening

      # The thread-local stack of the {RetryEdge}s whose primary body is being evaluated, innermost last, or nil.
      RETRY_FRAMES_KEY = :rigor_retry_frames
      private_constant :RETRY_FRAMES_KEY

      # The retry edge of `node`, or nil when no `retry` in its rescue chain targets it. Allocation-free for a `begin`
      # no `retry` targets.
      def retry_edge_for(node)
        retries = nil
        retrying_arms = nil
        current = node.rescue_clause
        while current
          found = collect_retries(current.statements)
          if found
            (retries ||= Set.new.compare_by_identity).merge(found)
            (retrying_arms ||= Set.new.compare_by_identity) << current
          end
          current = current.subsequent
        end
        return nil unless retries

        frame = Set.new.compare_by_identity
        body_writes = Set.new
        walk_primary_frame(node.statements, true, frame, body_writes) if node.statements
        RetryEdge.new(retries: retries, retrying_arms: retrying_arms, frame: frame, body_writes: body_writes,
                      raise_scopes: [], retry_scopes: [])
      end

      # The `retry` nodes under `node` that re-enter the `begin` whose rescue arm holds it, or nil for none. A nested
      # `rescue` clause, or a rescue modifier's fallback, owns the `retry`s inside it (Ruby 4.0.5 retries the modifier's
      # own expression), and a nested block, lambda, `def` or class body cannot hold one for this `begin`.
      def collect_retries(node, found = nil)
        case node
        when nil, Prism::RescueNode then found
        when Prism::RetryNode then (found || []) << node
        when Prism::RescueModifierNode then collect_retries(node.expression, found)
        else
          return found if scope_boundary?(node)

          node.rigor_each_child { |child| found = collect_retries(child, found) }
          found
        end
      end

      def scope_boundary?(node)
        SCOPE_NESTING_NODES.any? { |klass| node.is_a?(klass) } || SCOPE_BODY_NODES.any? { |klass| node.is_a?(klass) }
      end

      RETRY_WRITE_NODES = (CapturedLocals::LOCAL_WRITE_NODES | CapturedLocals::NON_LOCAL_WRITE_NODES).freeze
      private_constant :RETRY_WRITE_NODES

      # Collects into `frame` the nodes of the primary body that run in its own frame — a nested block or lambda keeps
      # its own locals (a block parameter can shadow the counter) — and into `writes` every variable name the body
      # writes, a block's included (it may write an outer local). A `def` or class body runs nothing here.
      def walk_primary_frame(node, in_frame, frame, writes)
        return if SCOPE_BODY_NODES.any? { |klass| node.is_a?(klass) }

        in_frame &&= SCOPE_NESTING_NODES.none? { |klass| node.is_a?(klass) }
        frame << node if in_frame
        writes << node.name if RETRY_WRITE_NODES.include?(node.class)
        node.rigor_each_child { |child| walk_primary_frame(child, in_frame, frame, writes) }
      end

      # B2.1 — the primary path's `[type, scope]` and the rescue chain's results re-evaluated under an entry the retry
      # edge widens, or nil when nothing crosses the edge. The widening first keeps literals, the entry joined with each
      # rebind, and holds when one re-evaluation under it puts nothing new on the edge: `st = :ok; …; st = :retrying`
      # stays `:ok | :retrying`. A counter moves again (`0 | 1` meets `2`), so the entry is then widened to the Nominal
      # envelope of everything both passes saw, and evaluated once more; that pass is taken as converged.
      def eval_retried_begin(node, entry, edge)
        literal = widen_entry_for_retry(RetryWidening.new(entry: entry, edge: edge, envelope: false))
        return nil unless literal

        closing = edge.fresh
        result = eval_begin_paths(node, literal, closing)
        return result unless widen_entry_for_retry(RetryWidening.new(entry: literal, edge: closing, envelope: false))

        widened = widen_entry_for_retry(RetryWidening.new(entry: entry, edge: edge.merge(closing), envelope: true))
        eval_begin_paths(node, widened || literal, nil)
      end

      def eval_begin_paths(node, entry, edge)
        primary = eval_begin_primary_under(node, entry, edge: edge)
        [*primary, collect_rescue_chain_results(node.rescue_clause, entry, edge: edge)]
      end

      # B2.1 — the entry scope widened by what crosses the retry edge, or nil when nothing does. A local or ivar bound
      # in the entry widens when a scope on the edge binds it to a type the accumulated binding does not already
      # accept ({#retry_binding_accepted?}): inside `log if m == :fast` the scope holds `m: :fast`, which the entry's
      # `:fast | :slow` accepts, and widening it would turn a declared `:fast | :slow` return into `Symbol`.
      #
      # A name the entry does not bind joins the edge only from a retrying arm, and only when the primary body never
      # writes it. One the body writes reads as `Dynamic[top]` on the first entry, as it does on this pass; binding a
      # type onto the edge would claim it set even when the body raised before assigning it — the arm's `conn.close if
      # conn` would fold to always-truthy for the body's connection, or to always-falsey for the arm's own `conn = nil`.
      def widen_entry_for_retry(widening)
        widened = widening.entry
        widening.edge.retry_scopes.each do |retry_scope|
          widened = absorb_retry_rebinds(widened, retry_scope, widening)
        end
        widening.edge.raise_scopes.each do |raise_scope|
          widened = absorb_retry_rebinds(widened, raise_scope, widening, bound_on_entry: true)
        end
        return nil if widened == widening.entry

        widened
      end

      # Runs `block` with `edge` on top of the thread-local stack {#record_raise_points} reads.
      def with_raise_frame(edge)
        return yield unless edge

        previous = Thread.current[RETRY_FRAMES_KEY]
        Thread.current[RETRY_FRAMES_KEY] = previous ? [*previous, edge] : [edge]
        begin
          yield
        ensure
          Thread.current[RETRY_FRAMES_KEY] = previous
        end
      end

      # The scope after each statement of a retrying primary body's frame is a point the body can raise from, the next
      # statement's being the one after. Together they carry every rebind a retry can re-enter with, including one on a
      # branch that then raises and so never reaches the body's exit scope (`if bad; tries += 1; raise; end`), and a
      # write threaded into the raising call's own operands (`raise Retry.new(tries += 1) if flaky?`). A statement of a
      # nested block or lambda body is not in the frame (a block parameter can shadow the counter); the block's effect
      # on this frame shows in the post-scope of the statement holding it. Recording from the evaluator rather than
      # `on_enter` keeps a statement reached with the index recorder off (a threaded operand, a loop fixpoint pass).
      def record_raise_points(frames, stmt, stmt_scope)
        frames.each { |edge| edge.raise_scopes << stmt_scope if edge.frame.include?(stmt) }
      end

      # An `on_enter` that records, besides forwarding to the installed one, the entry scope of each `retry` of `edge`
      # the rescue chain reaches: the scope control carries back into the primary body.
      def retry_scope_recorder(edge)
        forward = @on_enter
        lambda do |node, node_scope|
          edge.retry_scopes << node_scope if edge.retries.include?(node)
          forward&.call(node, node_scope)
        end
      end

      # Widens against the accumulator's binding rather than the entry's, so a name rebound differently by two arms, or
      # at two points of the primary body, keeps every rebind instead of only the last one absorbed.
      def absorb_retry_rebinds(accumulator, post_scope, widening, bound_on_entry: false)
        scope_acc = absorb_retry_kind_rebinds(accumulator, post_scope, widening, :local, bound_on_entry)
        absorb_retry_kind_rebinds(scope_acc, post_scope, widening, :ivar, bound_on_entry)
      end

      RETRY_KIND_TABLES = { local: :locals, ivar: :ivars }.freeze
      private_constant :RETRY_KIND_TABLES

      # Walk every name of `kind` visible on either side (only the entry's under `bound_on_entry`), and widen a binding
      # the accumulated one does not already accept.
      def absorb_retry_kind_rebinds(scope_acc, post_scope, widening, kind, bound_on_entry)
        getter = VAR_KIND_GETTERS.fetch(kind)
        table = RETRY_KIND_TABLES.fetch(kind)
        names = widening.entry.public_send(table).keys
        names |= post_scope.public_send(table).keys unless bound_on_entry
        names.each do |name|
          post = post_scope.public_send(getter, name)
          next if post.nil? || retry_rebind_settled?(widening, name, widening.entry.public_send(getter, name), post)

          current = scope_acc.public_send(getter, name)
          next if current ? retry_binding_accepted?(current, post) : widening.edge.body_writes.include?(name)

          scope_acc = rebind_retried(scope_acc, post_scope, kind, name,
                                     retry_widened_type(current, post, kind, widening.envelope))
        end
        scope_acc
      end

      # The rebind joins the binding a retry re-enters with into the accumulated one, so ADR-58's local mark stays only
      # when both scopes carry it, as `Scope#join` keeps it (issue #1287): `up(r)` in the body floors `r` in place and
      # keeps the mark, while `r = other` in the rescue arm is a write and drops it.
      def rebind_retried(scope_acc, post_scope, kind, name, type)
        rebound = rebind_variable(scope_acc, kind, name, type)
        return rebound unless kind == :local && scope_acc.declaration_sourced?(:local, name) &&
                              post_scope.declaration_sourced?(:local, name)

        rebound.with_local_declaration_mark(name)
      end

      # Whether `post` needs no weighing: this widening has weighed it for `name` already, or it is the entry's binding.
      def retry_rebind_settled?(widening, name, pre, post)
        return true unless (widening.weighed[name] ||= Set.new.compare_by_identity).add?(post)

        pre.equal?(post) || pre == post
      end

      # Whether the binding `current` already covers `post`. A `post` carrying `Dynamic` anywhere could be any value,
      # which only a `current` with a `Dynamic` member covers: `Array[Integer]` gradually accepts `Array[untyped]`, but
      # keeping it would claim the elements are still Integers.
      def retry_binding_accepted?(current, post)
        return ContentJoin.union_members(current).any?(Type::Dynamic) if carries_dynamic?(post)

        Acceptance.accepts(current, post).yes?
      end

      def carries_dynamic?(type)
        case type
        when Type::Dynamic then true
        when Type::Union then type.members.any? { |member| carries_dynamic?(member) }
        when Type::Nominal then type.type_args.any? { |arg| carries_dynamic?(arg) }
        when Type::Tuple then type.elements.any? { |element| carries_dynamic?(element) }
        when Type::HashShape then type.pairs.each_value.any? { |value| carries_dynamic?(value) }
        when Type::Difference, Type::Refined then carries_dynamic?(type.base)
        else false
        end
      end

      # The accumulated binding joined with a rebind, widened to the Nominal envelope when `envelope` is set.
      #
      # `current` is nil when the name was introduced inside a retrying arm. Such a local is nil on the first entry, and
      # stays nil past a `begin` whose body never raised, which reaches the exit only through the primary path (a
      # retrying arm does not join it), so the edge carries `nil` along with the rebind. An instance variable's
      # first-entry value is unknown rather than nil (another method may set it), so it takes the rebind alone.
      def retry_widened_type(current, post, kind, envelope)
        rebind = envelope ? nominal_envelope_for(post) : post
        return rebind if current.nil? && kind == :ivar
        return Type::Combinator.union(Type::Combinator.constant_of(nil), rebind) if current.nil?

        joined = Type::Combinator.union(current, rebind)
        envelope ? nominal_envelope_for(joined) : joined
      end

      # Nominal envelope of a value type: widens Constant / Tuple / HashShape carriers to the underlying class's
      # `Nominal`, preserving everything else (`Nominal`, `Union` of non-shape members, `Top`, `Dynamic`, `Bot`). Union
      # members are walked individually. `nil`, `true` and `false` are the only values of their classes, so their
      # Constant already is the envelope; `Nominal[FalseClass] | Nominal[TrueClass]` would not be accepted where `bool`
      # is declared.
      def nominal_envelope_for(type)
        members = type.is_a?(Type::Union) ? type.members : [type]
        widened = members.map { |m| nominal_envelope_member(m) }
        Type::Combinator.union(*widened)
      end

      SINGLE_VALUE_CONSTANTS = [nil, true, false].freeze
      private_constant :SINGLE_VALUE_CONSTANTS

      def nominal_envelope_member(member)
        case member
        when Type::Constant
          return member if SINGLE_VALUE_CONSTANTS.include?(member.value)

          Type::Combinator.nominal_of(member.value.class.name)
        when Type::Tuple
          MutationWidening.widen_tuple(member)
        when Type::HashShape
          MutationWidening.widen_hash_shape(member)
        else
          member
        end
      end

      # `edge`, when given, collects the scope at each of its `retry`s ({#retry_scope_recorder}) and the post-scope of
      # each arm holding one. The latter still carries a rebind the `retry` itself does not see: a write an `ensure`
      # runs on the way out (`begin; retry; ensure; tries += 1; end`), or one made before a `retry` the evaluator only
      # types (`log(tries < 5 ? retry : :gave_up)`).
      def collect_rescue_chain_results(rescue_node, entry_scope, edge: nil)
        on_enter = edge ? retry_scope_recorder(edge) : @on_enter
        results = []
        current = rescue_node
        while current
          rescue_scope = bind_rescue_reference(current, entry_scope)
          arm = eval_branch_or_nil(current.statements, rescue_scope, on_enter: on_enter)
          edge.retry_scopes << arm.last if edge&.retrying_arms&.include?(current)
          results << [arm, current]
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

      # `while pred; body; end` / `until pred; body; end`. The body might run zero or more times, so half-bound names
      # degrade to `T | nil` in the post-loop scope. The loop expression itself types as `Constant[nil]` (Slice 3 phase
      # 1), reflecting the common case where no `break VALUE` is observed.
      def eval_loop(node)
        _pred_type, post_pred = sub_eval(node.predicate, scope)
        post_pred = widen_predicate_pins(node, post_pred)
        return [Type::Combinator.constant_of(nil), narrow_loop_exit_edge(node, post_pred)] if node.statements.nil?

        # The historical single body pass joined with the pre-loop scope. This continues to carry everything the
        # fixpoint does NOT track: receiver-mutation widening of non-rebound locals (`buf.push(i)` widens `buf`'s
        # Tuple), body-introduced locals' nil-injection, an instance variable's rebind, and the loop value itself. The
        # fixpoint then OVERLAYS only the rebound-local bindings it corrects.
        #
        # The pass ends with its `next` exits as well as its fall-through ({#loop_iteration}). Its `break` arms are
        # superseded by the fixpoint's converged pass ({#loop_break_arms}) except in a `begin … end while` loop, below.
        jumps = loop_jumps(node.statements)
        body_scope, first_breaks = loop_iteration(node.statements, post_pred, jumps)
        base_scope = join_with_nil_injection(post_pred, body_scope)

        rebound, body_first = loop_body_local_writes(node.statements, post_pred)
        names = rebound + body_first

        # Fast path: a loop whose body rebinds no local skips the rebind fixpoint, but still needs the slice-C content
        # writeback (a loop may content-mutate a collection without rebinding any local — `acc << x`), so apply it to
        # the single-pass join before returning.
        if names.empty?
          fast = loop_content_writeback(node.statements, base_scope, pre_body: post_pred)
          return [Type::Combinator.constant_of(nil), narrow_loop_exit_edge(node, fast)]
        end

        post_loop = converged_loop_scope(node, post_pred, base_scope, names, body_first, jumps)
        # A `begin … end while` / `until` body runs once before the predicate is first tested, so that iteration's
        # entry lies outside every fixpoint pass's predicate-narrowed one, and a `break` only it can take (`if state ==
        # :idle` under `end while state != :idle`) is dead in every converged pass. The single pass runs from the
        # un-narrowed post-predicate scope, so its arms stand in for that first iteration.
        post_loop = join_break_scopes(post_loop, first_breaks, names) if node.begin_modifier?
        post_loop = narrow_loop_exit_edge(node, post_loop)
        [Type::Combinator.constant_of(nil), post_loop]
      end

      # A `while` / `until` predicate runs before every iteration and once more to leave, but the walk evaluates it
      # once, from the scope before the loop. A variable it writes therefore holds its first evaluation's value, and a
      # value pin there is a claim about that evaluation alone when a later evaluation can store something else: when
      # the predicate reads the variable it writes (`i = 0; while (i += 1) < 3; end` pinned `i` to `1`, and the exit
      # edge `i >= 3` contradicted the pin and left `i` as `bot`), or reads one the body rebinds (`while check(k = i *
      # 2); i += 1; end`). Each such binding is widened past its value pin (`Type::Combinator.widen_value_pinned`), as
      # the loop fixpoint widens a body's rebinds; a write that reads neither stores the same answer every time and
      # keeps it (`until line = (flag ? "x" : nil)` still exits on `"x"`). Issue #1223 made the shape common: a write
      # nested in a predicate's call operand was not threaded at all before it.
      def widen_predicate_pins(node, post_pred)
        written = OperandEffects.written_variables(node.predicate)
        return post_pred if written.empty?

        reads = OperandEffects.read_variables(node.predicate)
        body_writes = OperandEffects.written_variables(node.statements)
        varying = reads.intersect?(body_writes) ? written : written & reads
        varying.reduce(post_pred) do |acc, name|
          current = CapturedLocals.bound_type(acc, name)
          next acc if current.nil?

          widened = Type::Combinator.widen_value_pinned(current)
          widened == current ? acc : CapturedLocals.bind(acc, name, widened)
        end
      end

      # The continuation scope for a loop whose body rebinds locals: the ADR-56 slice-B rebind fixpoint overlaid on
      # `base_scope`, then the slice-C receiver-content writeback, then the `break`-path bindings the fall-through
      # dropped (`flag = true; break` -> `flag` is `false | true`, not the stale `false`).
      def converged_loop_scope(node, post_pred, base_scope, names, body_first, jumps)
        # ADR-56 slice B — loop-body fixpoint. The body runs 0..N times and may compound (`d *= 2`), so the historical
        # single body pass joined with the pre-loop scope kept stale folded constants (`d = 1; while …; d *= 2; end` →
        # `1 | 2`, never reaching `4, 8`). Fold each body-written local's continuation binding through the same capped
        # fixpoint slice A uses for non-escaping block captures. Seed: a pre-existing local seeds with its
        # post-predicate binding; a local FIRST assigned inside the body seeds with `nil` so the 0-iteration path
        # degrades it to `T | nil`, matching the nil-injection treatment.
        break_pass = jumps.breaks && { entry: nil, arms: [] }
        result = loop_rebind_fixpoint(node, post_pred, names, body_first, jumps, break_pass)
        # Display-path re-record: the fixpoint's body re-evaluations fire `on_enter` with the cap-N INTERMEDIATE
        # assumptions, so the last-visit-wins scope index would annotate loop-body lines with stale pre-convergence
        # constants. One extra pass from the converged bindings (result discarded) re-records the body's entry scopes.
        record_converged_loop_body(node, post_pred, result, names, body_first, jumps, break_pass)
        post_loop = result.reduce(base_scope) { |acc, (name, type)| acc.with_local(name, type) }
        # ADR-56 slice C — loop-body receiver-content element-type join. A loop that content-mutates a collection (`acc
        # << n`) keeps only the seed's element types after the single-pass widen; join the appended/stored types into
        # the continuation collection. Pre-state comes from `post_pred` for a name the loop only content-mutates and
        # from `post_loop` for one it also rebinds, so composition still works — see {#loop_content_writeback}.
        post_loop = loop_content_writeback(node.statements, post_loop, pre_body: post_pred, rebound: names)
        arms = loop_break_arms(node, post_pred, result, body_first, jumps, break_pass)
        join_break_scopes(post_loop, arms, names)
      end

      # Item 4 — loop-exit predicate narrowing. A `while pred` / `until pred` loop exits PRECISELY on the predicate's
      # exit edge: `while` exits when `pred` is falsey, `until` when `pred` is truthy. So after the loop the
      # predicate-assignment target carries the exit polarity — `until line = io.gets; …; end; line.foo` reads `line`
      # non-nil because the loop ran until `gets` returned a truthy (non-nil) line. Apply the exit edge of
      # `Narrowing.predicate_scopes` to the continuation scope.
      #
      # Guarded against `break`: a `break` exits the loop WITHOUT the predicate ever going false (`while line = gets;
      # break if done; end` can leave `line` truthy on a `while`, or exit before the `until` predicate fires), so the
      # exit-edge proof does not hold and the loop is left un-narrowed. `break` inside a NESTED loop/block does not
      # target this loop, but a nested-loop `break` is rare in predicate-assignment loops and the conservative bail only
      # costs precision, never soundness.
      def narrow_loop_exit_edge(node, post_loop)
        return post_loop if loop_body_breaks?(node.statements)

        truthy_scope, falsey_scope = Narrowing.predicate_scopes(node.predicate, post_loop)
        node.is_a?(Prism::UntilNode) ? truthy_scope : falsey_scope
      end

      # True when the loop body can `break` out of THIS loop. Conservatively treats any `BreakNode` under the body as a
      # break for this loop (a break inside a nested loop/block actually targets the inner construct, but bailing is
      # precision-only).
      def loop_body_breaks?(statements)
        return false if statements.nil?

        found = false
        Source::NodeWalker.each(statements) do |descendant|
          found = true if descendant.is_a?(Prism::BreakNode)
        end
        found
      end

      # The jumps that target a loop body ({JumpTargets}): its `next`s and its `break`s, each an identity-keyed Hash
      # used as a membership set, or nil when the body has none. The sinks also collect jumps that belong to a
      # construct evaluated under the loop's collection without installing its own (a `->` body), and the consumers
      # filter against these sets.
      LoopJumps = Data.define(:nexts, :breaks)
      private_constant :LoopJumps

      NO_LOOP_JUMPS = LoopJumps.new(nexts: nil, breaks: nil)
      private_constant :NO_LOOP_JUMPS

      NO_BREAK_ARMS = [].freeze
      private_constant :NO_BREAK_ARMS

      # A body with no targeting jump pays two allocation-free scans.
      def loop_jumps(statements)
        nexts = JumpTargets.of(statements, Prism::NextNode) if JumpTargets.any?(statements, Prism::NextNode)
        breaks = JumpTargets.of(statements, Prism::BreakNode) if JumpTargets.any?(statements, Prism::BreakNode)
        return NO_LOOP_JUMPS if nexts.nil? && breaks.nil?

        LoopJumps.new(nexts: nexts, breaks: breaks)
      end

      # Installs a fresh thread-local break sink around `yield` (a loop-body evaluation), returning `[collected,
      # yield_result]`. Stacks: the previous sink is restored on exit so a nested loop's breaks do not leak to the
      # enclosing loop.
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

      # One evaluation of a loop body from `entry`. Returns `[exit, breaks]`: the scope the iteration ends with, and the
      # scopes at the `break`s that target the loop ({LoopJumps}). Every reader of a loop body goes through here — the
      # single pass `eval_loop` joins with the pre-loop scope, each pass of its rebind fixpoint, and `eval_for`'s only
      # pass.
      #
      # A `next` returns to the predicate as surely as falling off the end does, so `exit` is the fall-through joined
      # with the scope at every `next` that targets the loop. Without that join a rebind on a jumping branch (`if
      # i.odd?; w = i; next; end`) vanished — `eval_if` carries only the arm that falls through — and `w` kept its
      # pre-loop binding. The join nil-injects: a local first bound on a `next` path is unbound on the fall-through, and
      # a plain `Scope#join` would drop it and leave the fixpoint only its `nil` seed.
      #
      # The `next` scopes are collected into a sink threaded through `sub_eval` ({#evaluate_invocation} does the same
      # for a block), and the `break` scopes into a thread-local one, each installed only when the body has such a
      # jump. `recorded: false` evaluates without recording into the per-node scope index.
      def loop_iteration(statements, entry, jumps, recorded: true)
        next_sink = jumps.nexts && []
        recording = recorded ? {} : UNRECORDED
        evaluate = -> { sub_eval(statements, entry, next_scope_sink: next_sink, **recording).last }
        if jumps.breaks
          break_sink, fall_through = collect_break_scopes(&evaluate)
          breaks = targeted_scopes(break_sink, jumps.breaks)
        else
          fall_through = evaluate.call
          breaks = NO_BREAK_ARMS
        end
        return [fall_through, breaks] if next_sink.nil?

        exit_scope = targeted_scopes(next_sink, jumps.nexts).reduce(fall_through) do |acc, next_scope|
          join_with_nil_injection(acc, next_scope)
        end
        [exit_scope, breaks]
      end

      # The `break` scopes the continuation joins. A `break` leaves the loop, so its binding starts no further iteration
      # and is no input to the rebind fixpoint; it IS the continuation's binding on that path. The arms must come from a
      # pass whose entry is the CONVERGED binding, which contains every iteration's entry: read from the first pass
      # alone, a `break` whose branch is dead before any loop-carried rebind has moved (`break(flag = true) if i == 2`
      # while `i` is still `1`) was never reached and `flag` stayed `false`.
      #
      # The fixpoint's last pass is usually one — a fixpoint that stabilised ran it from the binding it returns — so
      # its arms are reused ({#loop_body_exit_bindings}). A capped fixpoint's widened binding was never evaluated, so
      # only then does one more pass run, without recording into the per-node scope index: that index keeps the
      # fixpoint's own last pass, which the check path's diagnostics read. On the display path the re-record pass
      # ({#record_converged_loop_body}) already ran from the converged binding and leaves its arms here, so no
      # unrecorded pass follows it. The block write-back reads its `break` arms the same way
      # ({#join_block_break_bindings}).
      #
      # The unrecorded pass is otherwise an ordinary evaluation: a `return` it reaches joins the enclosing method's
      # inferred return type, as one any other pass reaches does. That only widens the return, toward values a capped
      # fixpoint's own passes never evaluated.
      def loop_break_arms(node, post_pred, converged, body_first, jumps, break_pass)
        return NO_BREAK_ARMS if break_pass.nil?
        return break_pass[:arms] if break_pass[:entry] == converged.except(*body_first)

        entry = loop_pass_entry(node, post_pred, converged, body_first)
        loop_iteration(node.statements, entry, jumps, recorded: false).last
      end

      # Joins each `break` arm's body-written local bindings into the loop continuation, so a `break`-path binding the
      # fall-through dropped is recovered (`flag = true; break` -> `flag` becomes `false | true`). Only
      # loop-body-written names are joined — an unchanged local unions to itself; a break-only-written local is already
      # present via the fixpoint / nil-injection seed, so the union reflects its break value. A name whose continuation
      # binding is `Dynamic[top]` — the fixpoint's floor on non-convergence, or a local that was untyped already —
      # keeps it: a precise arm unioned into it would read as knowledge the analysis does not have.
      def join_break_scopes(continuation, breaks, names)
        return continuation if breaks.empty? || names.empty?

        floor = Type::Combinator.untyped
        breaks.reduce(continuation) do |cont, break_scope|
          names.reduce(cont) do |acc, name|
            break_value = break_scope.local(name)
            current = acc.local(name)
            next acc if break_value.nil? || current == floor

            acc.with_local(name, current ? Type::Combinator.union(current, break_value) : break_value)
          end
        end
      end

      # Joins loop-body content mutations into the continuation collection bindings. The mutator arguments are typed
      # against `post_loop`, whose locals already carry the loop-body fixpoint widening (so an appended `n` that the
      # loop decrements types `Integer`, not its entry `Constant[3]` — otherwise only the first iteration's value would
      # be captured, an unsound under-approximation). A loop body shares the surrounding scope, so the receiver is any
      # `LocalVariableReadNode` (no depth filter).
      #
      # **Pre-state comes from `pre_body` — the scope as of the loop predicate — for every name the loop does not
      # REBIND.** `post_loop` derives from a body evaluation, so the straight-line join inside the body has already
      # written its own result into that binding, floor and all (issue #560: a straight-line seam sees one store, so it
      # never closes the parameter it feeds). Re-deriving on top of that is derivation on derived output: this seam
      # scans the WHOLE body and joins every store in it, so it wants the contents as they stood before the body ran
      # and re-adds the stores itself. Left on `post_loop`, ADR-56's own `acc = []; while …; acc.push(m); end` read
      # `Array[Dynamic[top] | Integer]` where it must read `Array[Integer]`.
      #
      # Scrubbing the floor back out of `post_loop` instead is NOT an option: once inside a union a `Dynamic` is
      # indistinguishable from a DECLARED one, and stripping it closes a declared `Array[Integer | untyped]` parameter
      # and draws a false `undefined method` on correct code. Telling the two apart needs provenance the carriers do
      # not have (issue #580); taking the pre-body binding sidesteps the question entirely.
      #
      # A name the loop rebinds keeps reading `post_loop`, which is what lets a local both rebound (slice B) and
      # content-mutated compose — the documented behaviour, and there the fixpoint's answer IS the right base.
      def loop_content_writeback(statements, post_loop, pre_body: nil, rebound: nil)
        return post_loop if statements.nil?

        mutations = Hash.new { |h, k| h[k] = [] }
        Source::NodeWalker.each(statements) do |descendant|
          name, node = content_mutation_target(descendant) { |_r| true }
          mutations[name] << node unless name.nil?
        end
        return post_loop if mutations.empty?

        rewrites = local_rewrites(statements) { true }
        mutations.reduce(post_loop) do |acc, (name, calls)|
          seed_scope = content_seed_scope(name, acc, pre_body, rebound)
          seed = lookup_mutated_seed(statements, name, seed_scope.local(name)) { |depth, nesting| depth == nesting }
          joined = join_content_for_param(calls, seed, post_loop)
          next acc if joined.nil?

          acc.with_mutated_local(name, rewritten_capture(joined, seed, rewrites.fetch(name, NO_REWRITES)))
        end
      end

      # The scope a loop content join reads its PRE-STATE from: the pre-body scope for a name the loop only
      # content-mutates, and the accumulating post-loop scope for one the loop also rebinds. {#loop_content_writeback}
      # carries the why.
      def content_seed_scope(name, accumulated, pre_body, rebound)
        return accumulated if pre_body.nil? || rebound&.include?(name)

        pre_body
      end

      # Re-evaluates the loop body once from the converged fixpoint bindings, solely for the `on_enter` side effect of
      # re-recording the body's per-node entry scopes. Gated behind the display-path-only `converged_loop_recording`
      # flag so the check path neither pays the extra body evaluation nor risks any diagnostic drift. The pass leaves
      # its `break` arms in `break_pass`, which {#loop_break_arms} then reuses instead of running a pass of its own.
      def record_converged_loop_body(node, post_pred, bindings, names, body_first, jumps, break_pass)
        return unless @converged_loop_recording && @on_enter

        loop_body_exit_bindings(node, post_pred, bindings, names, body_first, jumps, break_pass)
        nil
      end

      # Runs the slice-B loop-body rebind fixpoint, returning the per-name continuation binding. Seed: a pre-existing
      # local seeds with its post-predicate binding; a local FIRST assigned inside the body seeds with `nil` so the
      # 0-iteration path (the body may never run) degrades it to `T | nil`, matching the historical nil-injection
      # treatment. `break_pass` rides along so every pass leaves its `break` arms for {#loop_break_arms}.
      def loop_rebind_fixpoint(node, post_pred, names, body_first, jumps, break_pass)
        nil_const = Type::Combinator.constant_of(nil)
        seed = names.to_h { |name| [name, post_pred.local(name) || nil_const] }
        evaluate_body = lambda do |bindings|
          loop_body_exit_bindings(node, post_pred, bindings, names, body_first, jumps, break_pass)
        end
        BodyFixpoint.converge(
          names: names,
          seed_bindings: seed,
          widen: Type::Combinator.method(:widen_value_pinned),
          evaluate_body: evaluate_body
        )
      end

      # Names of locals the loop body can rebind, partitioned into those already bound in `base_scope` (their pre-loop
      # binding seeds the fixpoint) and those FIRST assigned inside the body (no pre-state, so they seed with `nil` for
      # 0-iteration soundness). A loop body introduces no new binding scope — every write leaks to the surrounding scope
      # — so unlike a block there is no introduced-name filter; every local-write form under the body node counts.
      def loop_body_local_writes(statements, base_scope)
        pre_existing = []
        body_first = []
        Source::NodeWalker.each(statements) do |descendant|
          next unless CapturedLocals::LOCAL_WRITE_NODES.any? { |klass| descendant.is_a?(klass) }

          name = descendant.name
          if base_scope.locals.key?(name)
            pre_existing << name
          else
            body_first << name
          end
        end
        [pre_existing.uniq, body_first.uniq - pre_existing.uniq]
      end

      # Evaluates the loop body once with each fixpoint-tracked local bound to the supplied running assumption and
      # returns the per-name exit binding. Used as the {BodyFixpoint} body-evaluator for `eval_loop`.
      #
      # The body runs from `post_pred` overlaid with the assumptions, then narrowed by the predicate's loop-entry edge:
      # a `while` body only runs when the predicate is TRUTHY, an `until` body only when it is FALSEY. Re-applying that
      # narrowing per iteration keeps loop-carried narrowing sound — without it, an accumulator whose rebind can
      # introduce `nil` (`prefix = idx ? prefix[0, idx] : nil` under `while prefix && …`) would re-enter the body with
      # `nil` un-narrowed and false-fire `possible nil receiver` on the guarded re-read. The historical single body pass
      # (which seeds these locals from their never-nil pre-loop binding) did not need this; the fixpoint, which feeds
      # the widened assumption back in, does.
      #
      # A body-FIRST local (no pre-loop binding) is deliberately NOT overlaid into the body-entry scope: when the body
      # runs it assigns the local before any use, exactly as the historical single body pass saw it. Its `nil` seed
      # exists only to model the 0-iteration path and is kept as a join constituent by {BodyFixpoint#converge}; feeding
      # that `nil` back into the body re-evaluation would leak it past a condition-form assignment the engine does not
      # thread into the branch (`if exps.size > (count = 3)`), false-firing `+`/nil-receiver on the guarded use.
      #
      # The exit joins the pass's `next` exits ({#loop_iteration}), so a `next`-path rebind feeds the next iteration.
      # With a `break_pass` record the pass also leaves its entry and its `break` arms there for {#loop_break_arms};
      # `BodyFixpoint` hands every pass the same mutable assumption, and `except` copies it before the fixpoint moves
      # it.
      def loop_body_exit_bindings(node, post_pred, bindings, names, body_first, jumps, break_pass = nil)
        entry = loop_pass_entry(node, post_pred, bindings, body_first)
        exit_scope, breaks = loop_iteration(node.statements, entry, jumps)
        if break_pass
          break_pass[:entry] = bindings.except(*body_first)
          break_pass[:arms] = breaks
        end
        names.to_h { |name| [name, exit_scope.local(name)] }
      end

      # The scope one fixpoint pass enters the body with: `post_pred` overlaid with the pre-existing names' running
      # assumption, then narrowed by the predicate's loop-entry edge ({#loop_body_exit_bindings} carries the why).
      def loop_pass_entry(node, post_pred, bindings, body_first)
        overlaid = bindings.except(*body_first)
        entry = overlaid.reduce(post_pred) { |acc, (name, type)| acc.with_local(name, type) }
        truthy_scope, falsey_scope = Narrowing.predicate_scopes(node.predicate, entry)
        node.is_a?(Prism::UntilNode) ? falsey_scope : truthy_scope
      end

      # `for index in collection; body; end`. Unlike `each {}` blocks, `for` does NOT create a new variable scope: the
      # index variable AND every local written in the body leak to the surrounding scope. The collection is evaluated
      # once; the body runs zero or more times, so the post-loop scope is the join of the no-iteration scope (just
      # `post_collection`) and the body scope, with half-bound names degraded to `T | nil` via nil-injection. The loop
      # expression itself types as `Constant[nil]`, the policy `eval_loop` uses for `while` / `until` — a known gap for
      # `for`, whose value in Ruby is the collection it iterated (issue #1216).
      def eval_for(node)
        coll_type, post_coll = sub_eval(node.collection, scope)
        element_type = for_iteration_element_type(coll_type)
        body_entry = bind_for_index(node.index, element_type, post_coll)

        if node.statements.nil?
          return [Type::Combinator.constant_of(nil), join_with_nil_injection(post_coll, body_entry)]
        end

        # The body pass ends with its `next` exits as well as its fall-through, and its `break` arms are recovered into
        # the continuation (the `for` sibling of `eval_loop`'s break join; `for` has no fixpoint, so the single pass is
        # the only continuation and the only source of `break` arms).
        jumps = loop_jumps(node.statements)
        body_scope, breaks = loop_iteration(node.statements, body_entry, jumps)
        continuation = join_with_nil_injection(post_coll, body_scope)
        pre_existing, body_first = loop_body_local_writes(node.statements, post_coll)
        continuation = join_break_scopes(continuation, breaks, pre_existing + body_first)
        [Type::Combinator.constant_of(nil), continuation]
      end

      # `for x in coll` is semantically `coll.each { |x| ... }`. We ask the method dispatcher for `coll.each`'s expected
      # block parameter types — that path consults RBS and the iterator dispatch table, which is more precise than the
      # structural `collection_element_type` fallback (it knows, e.g., that `Hash[K, V]#each` yields `[K, V]` even when
      # the receiver is not a literal Hash carrier in our local lattice). When the dispatcher returns nothing (no
      # signature, unknown receiver) we fall back to the structural extractor.
      def for_iteration_element_type(coll_type)
        structural = collection_element_type(coll_type)
        return structural unless structural.equal?(Type::Combinator.untyped)

        block_params = MethodDispatcher.expected_block_param_types(
          receiver_type: coll_type,
          method_name: :each,
          arg_types: [],
          environment: scope.environment,
          scope: scope
        )
        return structural if block_params.nil? || block_params.empty?

        block_params.size == 1 ? block_params.first : Type::Combinator.tuple_of(*block_params)
      rescue StandardError
        Type::Combinator.untyped
      end

      # Binds the `for` index variable(s) into `scope`. A single `LocalVariableTargetNode` is bound to `element_type`
      # (the per-iteration value the collection yields). A `MultiTargetNode` (`for a, b in pairs`) delegates to
      # {MultiTargetBinder}, which decomposes a tuple-shaped element into the inner slots.
      #
      # An index target — the whole index (`for h[:a] in xs`) or a slot of a multi-target one (`for h[:a], w in
      # pairs`) — stores the element / its slot through `[]=` at the top of every iteration, so its receiver widens
      # here, before the body, exactly as a multi-assign target's does; the body then reads the widened receiver and
      # the post-loop join keeps it beside the zero-iteration literal, as it keeps a body store's `h[:a] = x`.
      def bind_for_index(index_node, element_type, scope)
        case index_node
        when Prism::LocalVariableTargetNode
          scope.with_local(index_node.name, element_type)
        when Prism::IndexTargetNode
          widen_index_target(index_node, element_type, scope, type_scope: scope)
        when Prism::MultiTargetNode
          bound = MultiTargetBinder.bind_marked(index_node, element_type, scope: scope)
          widen_index_targets(bound, bound.apply_to(scope), type_scope: scope)
        when Prism::SplatNode
          bind_for_splat_index(index_node, scope)
        else
          scope
        end
      end

      # `for *h[:a] in pairs` — Prism gives a bare splat index as a `SplatNode`, not a `MultiTargetNode`, so the
      # binder never sees it. The store is `*h[:a] = element`, an array of the element's `to_ary` parts; the receiver
      # widens with the binder's floor for a rest it cannot decompose, `Dynamic[top]`. A bare `*name` target stays
      # unbound here, as before.
      def bind_for_splat_index(splat, scope)
        target = splat.expression
        return scope unless target.is_a?(Prism::IndexTargetNode)

        widen_index_target(target, Type::Combinator.untyped, scope, type_scope: scope)
      end

      # Extracts the per-iteration element type from a collection carrier. `Tuple[T1..Tn]` yields the union of its
      # elements; `Nominal[Array, [T]]` and `Nominal[Range, [T]]` yield `T`; `Nominal[Hash, [K, V]]` yields `Tuple[K,
      # V]` (Hash#each yields `[key, value]` pairs); `IntegerRange` yields `Integer`; `Constant<Range>` reads the
      # literal range's element class. Anything else falls back to `untyped`.
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

      # `a && b` / `a || b`. The LHS always runs, the RHS only sometimes runs. Slice 6 phase 1 narrows the RHS
      # evaluation: `a && b` evaluates `b` under the truthy edge of `a`, and `a || b` evaluates `b` under the falsey
      # edge of `a`. The narrowed RHS post-scope is joined with the LHS post-scope (RHS skipped) using nil-injection so
      # half-bound names from the RHS still degrade to `T | nil`. The result type is edge-aware: `a && b` can only
      # produce the falsey fragment of `a` when the RHS is skipped, while `a || b` can only produce the truthy fragment
      # of `a` when the RHS is skipped.
      #
      # When the RHS is a terminating branch — it `raise`s / `return`s / `throw`s / `exit`s / `break`s / `next`s, OR its
      # inferred type is `Bot` (ADR-24 WD6: a divergent helper such as `a or fail_with_message(...)`, recognised via
      # `branch_terminates?`) — the post-OR / post-AND scope is the LHS-skipped edge alone: `a or raise` only survives
      # when `a` was truthy, so subsequent statements observe `a` narrowed to its truthy fragment; the symmetric `a and
      # raise` survives only when `a` was falsey. Same shape as the `eval_if` / `eval_unless` early-return narrowing.
      #
      # This is the only and/or typer: `ExpressionTyper` reads a value-position `&&` / `||` from here (issue #1016),
      # so the RHS narrowing and the constant short-circuit below cannot differ between a statement and a value.
      def eval_and_or(node)
        and_or_with_edges(node, edges: false)
      end

      # {#eval_and_or}, and with `edges:` also the operator's truthy and falsey edge scopes as a predicate
      # ({#eval_with_edges}), read off the scopes its operands left rather than off the joined result.
      def and_or_with_edges(node, edges:)
        and_node = node.is_a?(Prism::AndNode)
        left_type, left_scope, truthy_left, falsey_left = eval_with_edges(node.left, scope)
        right_entry = and_node ? truthy_left : falsey_left
        right_type, right_scope, truthy_right, falsey_right =
          edges ? eval_with_edges(node.right, right_entry) : sub_eval(node.right, right_entry)
        skipped_type = and_node ? Narrowing.narrow_falsey(left_type) : Narrowing.narrow_truthy(left_type)

        # Control never reaches any statement after `a or raise` via the RHS edge — the RHS scope is discarded.
        if branch_terminates?(node.right, right_type)
          skipped_scope = and_node ? falsey_left : truthy_left
          return [skipped_type, skipped_scope, *(Narrowing.predicate_scopes(node, skipped_scope) if edges)]
        end

        # A dead RHS is still evaluated and its scope still joins, so a write inside it nil-injects exactly as
        # before; only its value is dropped, because it cannot be the value of the expression.
        joined_scope = join_with_nil_injection(left_scope, right_scope)
        type = skipped_type
        type = Type::Combinator.union(skipped_type, right_type) unless right_operand_dead?(node, left_type, left_scope)
        return [type, joined_scope] unless edges

        ran = ran_edge(node, right_scope, and_node ? truthy_right : falsey_right, and_node)
        return [type, joined_scope, ran, join_with_nil_injection(falsey_left, falsey_right)] if and_node

        [type, joined_scope, join_with_nil_injection(truthy_left, truthy_right), ran]
      end

      # The edge on which the right operand certainly ran — `&&`'s truthy one, `||`'s falsey one. It is the right
      # operand's own edge, which keeps every binding and provenance mark the operands' writes made, with the
      # instance variables and globals of the whole operator narrowed over the scope the right operand left laid over
      # it. A call in the right operand resets the instance variables and regex globals the left operand narrowed
      # (`@parent && (node = find_node)` read `@parent` as nilable, `$1` after `line =~ re && (k = Integer($2))` as
      # nil), and narrowing afresh puts that back as the joined-scope narrowing always did. No call resets a local, so
      # locals keep the right operand's edge: re-narrowing one the operands write can contradict its new value
      # (`x.nil? && log(x = "d") && ok` read `x` as `bot`) or drop the marks its write stamped (a published-constant
      # copy `m = AppConfig::MODE`). A variable the operands write is never overlaid, for the same reason.
      def ran_edge(node, right_scope, right_edge, and_node)
        truthy, falsey = Narrowing.predicate_scopes(node, right_scope)
        renarrowed = and_node ? truthy : falsey
        written = OperandEffects.written_variables(node)
        edge = renarrowed.ivars.reduce(right_edge) do |acc, (name, type)|
          written.include?(name) || acc.ivar(name) == type ? acc : acc.with_ivar(name, type)
        end
        renarrowed.globals.reduce(edge) do |acc, (name, type)|
          written.include?(name) || acc.global(name) == type ? acc : acc.with_global(name, type)
        end
      end

      # `[type, scope, truthy_edge, falsey_edge]` for `node` evaluated from `entry` as a predicate. The edges are
      # `Narrowing.predicate_scopes` of the scope `node` leaves, except for an `&&` / `||` whose right operand, or
      # the right operand of an `&&` / `||` on its left, holds a write or jump ({OperandEffects}). The scope such an
      # operator leaves joins the path where that operand ran with the path that skipped it, so a local the operand
      # binds reads `nil` there as well, and narrowing that scope cannot tell that the operand certainly ran on the
      # truthy edge of an `&&` and on the falsey edge of an `||`: `if a && xs.size > (n = f)` read `n` as `nil |
      # Integer` in the body and reported `n + 1`. Those edges are built from the scopes the operands left instead —
      # the right operand's edge under the left operand's, and the join where either path reaches the edge. Issue
      # #1223 threads such a write for every operand, not only for a statement-position one.
      def eval_with_edges(node, entry)
        unless and_or_right_effects?(node)
          type, post = sub_eval(node, entry)
          return [type, post, *Narrowing.predicate_scopes(node, post)]
        end

        @on_enter&.call(node, entry)
        evaluator_at(entry).send(:and_or_with_edges, node, edges: true)
      end

      def and_or_right_effects?(node)
        return false unless node.is_a?(Prism::AndNode) || node.is_a?(Prism::OrNode)

        OperandEffects.any?(node.right) || and_or_right_effects?(node.left)
      end

      # Whether a genuine `Constant` left operand proves the RHS never supplies the value: `false && b` and
      # `1 || b`. The gate is `Constant`-only (issue #152 evaluated a wider one and declined it).
      #
      # Issue #313 — it MUST decline an optimistically nil-free operand. A uniform-valued literal hash reads as a lone
      # `Constant` (`UNIFORM[key]` → `1`), so without the mark `UNIFORM[key] || key` would discard the author's
      # fallback, and `MAP[key].nil? && b` would drop `b` the program runs when the lookup misses. The mark is
      # resolved against the LEFT operand's post-scope, as `branch_certainty` does for `if`, so a write in the left
      # operand (`(v = MAP[key]) || key`) is judged by the binding it just made rather than by an older one.
      def right_operand_dead?(node, left_type, left_scope)
        return false unless left_type.is_a?(Type::Constant)
        return false unless optimistic_origin_for(node.left, left_scope).nil?

        truthy = left_type.value ? true : false
        node.is_a?(Prism::AndNode) ? !truthy : truthy
      end

      # `(body)`. Threads scope through the inner expression so `(x = 1; x + 2)` binds `x` and produces `Constant[3]`.
      def eval_parentheses(node)
        return [Type::Combinator.constant_of(nil), scope] if node.body.nil?

        sub_eval(node.body, scope)
      end

      # An array or hash literal, an interpolation or a range: its value is the literal's, typed where it starts, and
      # its scope is the one its children leave in order ({#thread_operand}). Issue #1223 — `[s = 1]`, `x = [:a, s +=
      # 1]` and `"#{s = 1}"` left `s` on its pre-write binding. A literal holding no write or jump keeps the entry
      # scope and costs one scan. Issue #1256 — an element after one that wrote is typed from the scope the elements
      # before it left ({OperandWalk}), so `[n += 1, n += 1]` is `[1, 2]`.
      def eval_value_container(node)
        unless OperandEffects.any?(node)
          return [scope.type_of(node, tracer: tracer), forget_rebound_match_globals(scope, node)]
        end

        walk = OperandWalk.new(walk_recorder)
        after = thread_operand_children(node, scope, walk, scope)
        [OperandWalk.type_of(scope, node, tracer, walk.types(tracer)), forget_rebound_match_globals(after, node)]
      end

      # `expr rescue alt`. The rescue arm runs only when `expr` raised, possibly after some of its writes, so the arm
      # starts from the entry scope joined with the scope `expr` leaves, and the result joins the arm's scope with
      # the one `expr` leaves; an arm that always exits (`rescue next`) contributes no scope. Issue #1223 — `x = foo
      # rescue (s = 1)` left `s` on its pre-write binding. The value is the modifier's own, and one holding no write
      # or jump keeps the entry scope.
      def eval_rescue_modifier(node)
        unless OperandEffects.any?(node)
          return [scope.type_of(node, tracer: tracer), forget_rebound_match_globals(scope, node)]
        end

        walk = OperandWalk.new(walk_recorder)
        after_expression = thread_operand(node.expression, scope, walk, scope)
        # The arm is threaded outside the walk: its entry nil-injects a local `expr` first binds, which is the
        # sound join (the raise may come before the write) but reads `u` as `String?` in `Float(u = s) rescue
        # u.strip`, where the raise almost always comes from `Float` after it. Neither the arm nor anything in it
        # is recorded or typed from there, which keeps it where it was before #1256: an ADR-5 trade of the rare
        # raise-before-write path for no false positive on the common one.
        arm_entry = join_with_nil_injection(scope, after_expression)
        after_rescue = thread_operand(node.rescue_expression, arm_entry, OperandWalk.new(nil), arm_entry)
        type = OperandWalk.type_of(scope, node, tracer, walk.types(tracer))
        after = if branch_unconditionally_exits?(node.rescue_expression)
                  after_expression
                else
                  join_with_nil_injection(after_expression, after_rescue)
                end
        [type, forget_rebound_match_globals(after, node)]
      end

      # `class Foo; body; end` and `module Foo; body; end`. The class body runs in a fresh scope (Ruby's class scope
      # does not see the outer locals), and the StatementEvaluator pushes a new `ClassFrame` so nested `def`s know their
      # lexical owner. The outer scope is unchanged on exit because Ruby's class definition does not bind any local in
      # the enclosing scope. The class body's value is the value of its last statement (`Constant[nil]` for an empty
      # body); we discard the body's post-scope.
      #
      # Issue #708 — a ROOTED header (`class ::Rooted::Bar`) re-anchors at the top level, so the frame stack
      # RESETS to that class alone rather than gaining a frame under the enclosure. `current_class_path` joins
      # the stack, so keeping the enclosing frames named the class `Outer::Rooted::Bar` and every `def` in it
      # registered under a name no caller writes. The nesting CHAIN is not reset the same way — Ruby leaves the
      # enclosing entries beneath the un-prefixed one — which is why {Source::ConstantPath.pushed_nesting} owns
      # that half rather than this one deriving it from the frames.
      def eval_class_or_module(node)
        path = node.constant_path
        frame = ClassFrame.new(name: Source::ConstantPath.qualified_name(path), singleton: false)
        new_context = Source::ConstantPath.rooted?(path) ? [frame] : @class_context + [frame]
        body_type, _body_scope = eval_class_body(node, new_context,
                                                 Source::ConstantPath.pushed_nesting(@lexical_nesting, path))
        [body_type, scope]
      end

      # `class << expr; body; end`. When `expr` is `self`, the body defines class methods on the immediate enclosing
      # class — the innermost frame flips to `singleton: true` so a nested `def foo` resolves through `singleton_method`
      # rather than `instance_method`. For non-`self` expressions we cannot statically resolve the receiver, so we keep
      # the existing context and accept that nested defs degrade to the `Dynamic[Top]` default.
      # Issue #652 — the body INHERITS this evaluator's chain. Ruby pushes the singleton class onto
      # `Module.nesting` and leaves the enclosing entries beneath it, so `class << Other` written inside
      # `module Admin` reads `Admin::Y`: the enclosing rung is live, and only the singleton rung itself
      # (`#<Class:Other>`) is one Rigor does not model, on either path
      # ([#662](https://github.com/rigortype/rigor/issues/662)). Discarding the chain here because
      # {#singleton_context_for} resets the FRAME STACK for the cross-class form would answer `Other::Y`
      # off the name-peel instead — a rung Ruby's lookup does not have at all.
      def eval_singleton_class(node)
        new_context = singleton_context_for(node)
        body_type, _body_scope = eval_class_body(node, new_context)
        [body_type, scope]
      end

      # `def name(params); body; end`. Builds the method-entry scope by binding the parameter list (RBS-driven where
      # available, or `Dynamic[Top]` for the slice 3 phase 2 fallback) into a fresh scope, then evaluates the body under
      # that scope. The outer scope is left unchanged: a `def` does not introduce a binding in its enclosing scope. Ruby
      # evaluates `def` to the method's name as a Symbol, so the produced type is `Constant[:name]`.
      def eval_def(node)
        body_scope = build_method_entry_scope(node)
        # Parameter default value expressions (e.g. `self.x` in `def copy(x: self.x)`) execute when the method is
        # *invoked*, not when the `def` is read; their `self` is the instance receiver, not the surrounding class body.
        # Walk the parameters subtree under `body_scope` so the scope-index records the instance `self_type` for every
        # node inside parameter defaults. `propagate` would otherwise drop them to the outer class-body scope (where
        # `self_type` is `singleton(C)`), making `self.foo` look like a singleton-side call. Observed surfacing 915
        # false positives in `prism-1.9.0`'s auto-generated `copy` methods alone. A nested `def` is a return barrier:
        # its body's `return`s belong to the inner method, not the one currently being inferred. Suspend the return sink
        # across the nested body so `eval_return` does not record them into the outer method's return type.
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

      # `recv.foo(args) { |params| body }` and friends. The call type comes from `Scope#type_of` (which routes through
      # `ExpressionTyper#call_type_for` and is itself block-aware since Slice 6 phase C sub-phase 2: it builds the
      # block-entry scope from the receiving method's RBS signature, types the block body, and threads the body's type
      # into `MethodDispatcher.dispatch`'s `block_type:` so generic methods like `Array#map { |n| n.to_s }` resolve to
      # `Array[String]`).
      #
      # The handler still re-evaluates the block under its entry scope so the per-node scope index sees the bindings on
      # the `on_enter` callback path. Block effects do NOT leak into the post-call scope: a block-local write is
      # observed only inside the block body.
      #
      # Issue #1223 — Ruby evaluates the receiver, then the arguments, and only then runs the method, so a write in
      # an operand (`out << (n += 1)`, `puts(g = e)`, `(seen += 1) == 2`) is visible to the block and to everything
      # after the call. {#call_operand_scope} threads each operand that holds one; when none does it answers the
      # entry scope itself and the call is handled exactly as before. Otherwise the rest of the call — the block's
      # entry, its write-back and every post-call widening — runs from the scope the operands left
      # ({#invoke_call}), while the call's value is still typed where the operands started ({#operand_scope}), and
      # each operand where it was entered: `out << (n += 1)` appends `1`, not the `2` a re-typing after the write
      # reads. Issue #1256 — an operand after one that wrote is entered from the scope the operands before it left,
      # and {OperandWalk} records it into the per-node scope index and types it from there: `puts(b.unshift("s"),
      # b.first.upcase)` reads `b` as the `unshift` left it. The operands are threaded first and the call is typed
      # after, with those later operands' values in hand, so no operand is typed twice.
      def eval_call(node)
        walk = OperandWalk.new(walk_recorder)
        invoked = call_operand_scope(node, walk, scope)
        invoked = forget_operand_match_globals(node, invoked)
        operand_types = walk.types(tracer)
        call_type = OperandWalk.type_of(scope, node, tracer, operand_types)
        # ADR-56 slice C (B3) — `each_with_object(memo) { |x, acc| acc << … }` returns the memo; the engine otherwise
        # types the call `Dynamic[top]`. Compute the joined memo type from the block's content mutations of the memo
        # block-param and adopt it as the call's return type.
        call_type = each_with_object_return(node, call_type)
        [call_type, invoke_from(node, invoked, call_type, operand_types)]
      end

      # The scope after `node` runs as another expression's operand ({#thread_operand}), from the receiver scope.
      # Such a call is not typed, since its value is discarded and typing it re-types the whole subtree the
      # enclosing root types — once per level of an operator chain whose every operand writes (`f(a = 1) + f(a =
      # 2) + …`), and each through the callee's return inference. For the same reason it applies no post-return
      # narrowing ({#invoke_call}): each of those resolves the method by typing the receiver, the same subtree
      # again. They only narrow, and a call in an operand never applied them before #1223, so leaving them out is
      # the sound side. Its own later operands join `walk` and are typed as soon as they are all taken, so its
      # invocation reads them ({#type_operand}) and the enclosing root does not type them again.
      def call_effects(node, walk, typed_from)
        mark = walk.mark
        invoked = call_operand_scope(node, walk, typed_from)
        invoke_from(node, invoked, nil, walk.types(tracer, since: mark))
      end

      # The rest of the call from `invoked`, the scope its operands left, with each later operand's own value in
      # `operand_types` for the helpers that type the call's operands ({#type_operand}).
      def invoke_from(node, invoked, call_type, operand_types)
        return invoke_call(node, call_type) if invoked.equal?(scope) && operand_types.nil?

        evaluator_at(invoked, operand_scope: scope, operand_types: operand_types).send(:invoke_call, node, call_type)
      end

      # The scope Ruby runs `node`'s method from: the receiver, then the arguments, then a block-pass argument, each
      # threaded in turn ({#thread_operand}). A safe-navigation call skips its arguments when the receiver is nil,
      # so their scope joins with the receiver's.
      def call_operand_scope(node, walk, typed_from)
        after_receiver = thread_operand(node.receiver, scope, walk, typed_from)
        after_arguments = thread_operand(node.arguments, after_receiver, walk, typed_from)
        block_pass = node.block
        if block_pass.is_a?(Prism::BlockArgumentNode)
          after_arguments = thread_operand(block_pass, after_arguments, walk, typed_from)
        end
        return after_arguments if after_arguments.equal?(after_receiver) || !node.safe_navigation?

        join_with_nil_injection(after_receiver, after_arguments)
      end

      # The scope after `node` from `entry`, for an expression otherwise typed as a pure value. One that holds no
      # write or jump ({OperandEffects}) answers `entry` itself. A call contributes its effects without its value
      # ({#call_effects}), any other node with a handler is evaluated through it, and an {OPERAND_CONTAINERS} node
      # threads its children in order.
      #
      # `typed_from` is the scope the root types `node` from: its own entry, or that of the nearest enclosing operand
      # {OperandWalk} took as a later one. When `entry` is not that scope, an earlier operand has moved it, and `walk`
      # takes `node` ({OperandWalk#later}) before anything below it, so its descendants are typed and recorded against
      # `entry` in turn. Nothing else is recorded into the per-node scope index.
      #
      # A call threaded this way is an operand, so it also leaves out the two resets a statement-position call
      # applies because it might have done anything ({#invoke_call}): the class's narrowed instance variables and the
      # regex globals. A call in an operand never applied them before #1223, and applying them only when the operand
      # happens to write made `$stdout.puts(Integer(v = $2)); $1.upcase` report where `$stdout.puts(Integer($2))`
      # does not. The same holds for every call under an operand evaluated through its handler, so the evaluator
      # carries `in_operand` into everything it opens: an in-place mutation counts as an effect, and threading
      # `opts[:k] = strict? ? queue.shift : nil` must not let the typed `strict?` inside the ternary reset
      # the regex globals or the narrowed ivars that the same line without the `shift` leaves alone. Issue #1365 —
      # the statement that holds the operand forgets the regex globals for every call in it instead, threaded or not,
      # when that call is known to match ({#forget_operand_match_globals}), so an operand's answer still does not
      # depend on whether it writes.
      def thread_operand(node, entry, walk, typed_from)
        return entry unless node.is_a?(Prism::Node)

        taken = !entry.equal?(typed_from)
        slot = walk.later(node, entry) if taken
        typed_from = entry if slot
        unless OperandEffects.any?(node)
          # A taken position with no value of its own leaves its children to be taken: nothing types it whole.
          thread_operand_children(node, entry, walk, typed_from) if taken && slot.nil?
          return entry
        end

        operand = evaluator_at(entry, on_enter: nil, in_operand: true, operand_recorder: walk.recorder)
        return operand.send(:call_effects, node, walk, typed_from) if node.is_a?(Prism::CallNode)
        # A container is threaded child by child even when it has a handler: the handler types the whole literal,
        # which a nested literal would repeat once per level of nesting. A statement list or `(…)` inside an operand
        # runs its statements in order just the same, and evaluating it would type each statement it holds.
        if OPERAND_CONTAINERS.include?(node.class) || OPERAND_SEQUENCES.include?(node.class)
          return thread_operand_children(node, entry, walk, typed_from)
        end
        return entry unless HANDLERS.key?(node.class)

        # The handler types the operand from `entry`, which is the value a later operand takes.
        type, after = operand.evaluate(node)
        walk.resolve(slot, type) if slot
        after
      end

      def thread_operand_children(node, entry, walk, typed_from)
        threaded = entry
        node.rigor_each_child { |child| threaded = thread_operand(child, threaded, walk, typed_from) }
        threaded
      end

      # The recorder an {OperandWalk} rooted here records later operands with: the per-node scope index's, whether
      # this evaluator records into it itself or is an operand evaluator threading a recording one's operands. An
      # unrecorded pass ({UNRECORDED}) has neither.
      def walk_recorder
        @operand_recorder || @on_enter
      end

      # A call operand's type, read from where the call's operands were typed ({#operand_scope}), with each later
      # operand's own value ({OperandWalk}) where the call has one.
      def type_operand(node)
        OperandWalk.type_of(operand_scope, node, tracer, @operand_types)
      end

      # The scope this evaluator types a call's receiver and arguments under: where they were evaluated, which
      # {#invoke_call} under {#call_effects}' rebase is not the receiver scope. Every helper below that types the
      # current call's own operands reads this rather than `scope`, so it reads exactly what it read before the
      # rebase existed.
      def operand_scope
        @operand_scope || scope
      end

      # The rest of {#eval_call}: the call's block and every effect the call leaves on the scope, from the receiver
      # scope, which is the scope its operands left. Returns the post-call scope. `call_type` is nil for a threaded
      # operand, which applies no post-return narrowing ({#call_effects}); nor does a call an operand evaluator
      # types through a handler ({#thread_operand}).
      def invoke_call(node, call_type)
        evaluate_block_if_present(node)
        # `ruby2_keywords def foo(...)` (and similar wrappers like `private def`, `public def`, `module_function def`)
        # parse the def as the call's positional argument; the ExpressionTyper#type_of_def handler types it as
        # `Constant[:foo]` without walking the body. Without explicitly evaluating the argument-position def, the body's
        # scope-index entries inherit the outer class-body `self_type = singleton(C)` from `ScopeIndexer.propagate`, so
        # `self.helper` inside reports `undefined method 'helper' for singleton(C)`. Walking each argument-position def
        # under the current evaluator (not a sub_eval — the def's effects do not bind into the surrounding scope)
        # populates the scope index with the correct instance / singleton `self_type` for the def's body.
        evaluate_def_arguments(node)
        post_scope = record_closure_escape_if_any(node)
        # ADR-56 slice A — non-escaping block captured-local write-back. A `:non_escaping` block (each / times / upto /
        # map …) that rebinds an outer local must not leave that local's pre-call binding unmodified in the continuation
        # scope; the spec MUST in § "Fact stability and mutation" names captured locals a first-class invalidation
        # category. (The escaping / unknown path already widened to Dynamic[top] via `record_closure_escape_if_any`.)
        post_scope = write_back_block_captures(node, post_scope)
        statement_call = !call_type.nil? && !@in_operand
        post_scope = apply_post_return_narrowing(node, post_scope) if statement_call
        # Flow-folding G1 / G2 — widen a local- or instance-variable binding when the call is an in-place mutator on it
        # (e.g. `arms << x`, `@tags << hashtag`). Stops a literal-shape carrier (`Tuple` / `HashShape`) from outliving
        # its justification when the value is mutated. Always-safe (loses precision, never invents facts).
        post_scope = widen_mutated_receivers(node, post_scope)
        # ADR-48 slice 4 — Struct member-setter re-typing. After `s.x = v` on a fold-safe StructInstance local, rebind
        # `s` to a StructInstance with member `:x` replaced by the assigned type, so a later `s.x` folds to `v` and a
        # sibling `s.y` stays precise. `call_type` is the setter's own result (the assigned value type). Sound only for
        # a fold-safe local (never aliased / escaped, straight-line setters) — the fold-safe scan is the gate.
        post_scope = MethodDispatcher::StructFolding.apply_setter_writeback(
          call_node: node, assigned_type: call_type || local_attribute_write_value(node), scope: post_scope
        )
        # ADR-57 slice 3 work-item 1 (cross-method-boundary variant). When a self-call resolves to a user method that
        # CONTENT-mutates one of its parameters inside an escaping block (the `build_option_parser(opts)` idiom — the
        # callee returns an `OptionParser` whose `opts.on { o[:k] = v }` blocks close over the passed-in hash), floor
        # the matching caller-argument local. The callee's escape is invisible across the boundary, so without this the
        # caller's `options` keeps its seed and `options.fetch(:mode)` folds to a wrong constant. Precise: fires only
        # when the resolved callee actually escape-mutates that parameter (not for every self-call), and sound — only
        # loses precision on the floored argument.
        post_scope = widen_callee_escaped_argument_captures(node, post_scope)
        # Same always-safe rationale as `widen_after_call` above — propagates outer-scope local / ivar widening from
        # block body mutations (`items.each { |x| arr << x }`).
        #
        # The slice-C join below reads its SEED from here, before the widening runs: `widen_after_block` spells an
        # empty `[]` as `Array[untyped]`, and read back after the fact that `untyped` is indistinguishable from a
        # declared one (issue #586 — see {#content_writeback_block_captures}).
        pre_widen_scope = post_scope
        post_scope = MutationWidening.widen_after_block(call_node: node, outer_scope: post_scope)
        # ADR-56 slice C — receiver-content element-type join. Joins appended / stored element / key / value types into
        # the continuation collection so `out = [0]; arr.each { |x| out << x }` types `Array[0 | Integer]`, not
        # `Array[0]`. Same always-safe rationale (only widens).
        post_scope = content_writeback_block_captures(node, post_scope, seed_scope: pre_widen_scope)
        # Indexed-collection narrowing — drop any `receiver[key] ||= default` narrowing the analyzer recorded earlier
        # when an intervening `[]=` writes the same slot or any other mutator runs against the receiver. Always-safe
        # (only forgets; never invents).
        post_scope = IndexedNarrowing.invalidate_after_call(call_node: node, current_scope: post_scope)
        # Single-hop method-chain narrowing — drop every `(receiver, *)` chain narrowing rooted at the call's outer
        # stable receiver (any-call-against-the-root invalidation rule, B2 from the slice's design notes). Calls whose
        # outer receiver is itself a chain node (e.g. `x.last << y`) do NOT drop narrowings keyed on `x` — only direct
        # calls against the root variable invalidate the chain.
        post_scope = IndexedNarrowing.invalidate_chain_after_call(call_node: node, current_scope: post_scope)
        # B2.2 — intervening method call ivar invalidation. An implicit-self / self-receiver call could mutate any ivar
        # of the enclosing class (we cannot prove purity without an effect system). Reset each ivar whose current local
        # binding has narrowed below the class-ivar seed back to the seed itself, so a subsequent `if @flag` predicate
        # observes the seed's union (not the pre-call narrowed value). Always-safe (only widens; no new facts). See
        # [`docs/CURRENT_WORK.md`](../../../docs/CURRENT_WORK.md) § "Flow-folding" — G2 intervening-call case.
        post_scope = invalidate_ivars_for_intervening_call(node, post_scope) if statement_call
        # C1 — regex match-data globals (`$~`, `$1..$9`, `$&`, …) are narrowed to non-nil on a successful-match edge; a
        # later call that itself runs a regex match rebinds them, so the narrowed facts must be dropped. We forget them
        # only when the call may run a match in this frame ({#rebinds_match_globals?}). A call provably match-free on a
        # known receiver — `$3.to_i`, `year < 50` — does NOT clobber, so the multi-statement `m = /…/ =~ s; …; use($2)`
        # stdlib idiom keeps its precision while a genuinely interposed match still invalidates.
        # The chain above is Scope-total by construction (every helper returns its input scope or a
        # combinator result); the `||=` is a runtime no-op that pins the INFERRED type back to Scope for
        # the negative rules when a helper's return widens to `Scope?` under call-site binding (#524).
        post_scope ||= scope
        post_scope = post_scope.forget_match_globals if statement_call && rebinds_match_globals?(node, post_scope)
        post_scope
      end

      # True when the call may rebind this frame's match globals: it is match-capable itself ({#match_capable_call?}),
      # its own block may run a match ({MatchRebinding.block_may_match?} — issue #1358: the block runs in this frame,
      # so `items.each { |i| i =~ re }` rebinds the enclosing method's `$~`, while a match inside a called Ruby method
      # rebinds that method's own), or the frame has made a closure that may run one whenever it is called
      # ({Scope#match_rebinding_closure?}). The receiver chain and arguments ran before the call, and
      # {#forget_operand_match_globals} answered for them. The scans run only while a match global is narrowed, the
      # one state a forget can drop.
      def rebinds_match_globals?(node, post_scope)
        return false unless post_scope.match_globals_bound?
        return true if match_capable_call?(node)

        MatchRebinding.block_may_match?(node, scope) || post_scope.match_rebinding_closure?
      end

      # Issue #1365 — the scope a statement call runs its method from, with the match globals forgotten when its
      # receiver chain or arguments may rebind them ({MatchRebinding.operands_may_rebind?}): Ruby runs those first,
      # so the call's own block already reads the rebound globals (`s.sub(re, "").each_char { $1 }`). No call in them
      # forgot before, so each forgets here only when it is known to match ({MatchRebinding::Calls.rebinds?}), and
      # none resets by itself ({#invoke_call}), so an operand's answer does not depend on whether the evaluator
      # threads it: `$stdout.puts(Integer(v = $2))` keeps `$1` narrowed as `$stdout.puts(Integer($2))` does.
      def forget_operand_match_globals(node, invoked)
        return invoked if @in_operand || !invoked.match_globals_bound?
        return invoked unless MatchRebinding.operands_may_rebind?(node, scope)

        invoked.forget_match_globals
      end

      # Issue #1365 — `after` with the match globals forgotten when `node`, a value this statement types without
      # evaluating the calls in it as statements (an array, hash or interpolation literal, a `rescue` modifier, a
      # constant's value, a `super` or `yield`), may rebind them ({MatchRebinding.value_may_rebind?}). Inside an
      # operand the statement that holds it answers instead.
      def forget_rebound_match_globals(after, node)
        return after if @in_operand || !after.match_globals_bound?
        return after unless MatchRebinding.value_may_rebind?(node, scope)

        after.forget_match_globals
      end

      # The value an untyped setter call on a local stores (`foo(s.x = v)`), for the Struct member write-back; nil for
      # any other call, which that write-back ignores.
      def local_attribute_write_value(node)
        return nil unless node.attribute_write? && node.receiver.is_a?(Prism::LocalVariableReadNode)

        type_operand(node)
      end

      def apply_post_return_narrowing(node, post_scope)
        post_scope = apply_rbs_extended_assertions(node, post_scope)
        post_scope = apply_plugin_assertions(node, post_scope)
        apply_rspec_matcher_narrowing(node, post_scope)
      end

      # True when `node` could rebind the regex match-data globals by itself
      # ({MatchRebinding::Calls.statement_rebinds?}): a method that matches on this frame's behalf, on any receiver,
      # read with the operands where they were typed (issue #1365: a name the old table forgot on keeps forgetting
      # unless its literal arguments prove it match-free, so `row[:name]`, `csv.split(",")` and `s.match?(re)` keep
      # the narrowing and `row[key]` does not; any other call forgets when it is known to match, as
      # `u.start_with?(/(q)/)` is); or an implicit-self / `self.` call that may reach this frame's slot. Issue #1364 —
      # a method defined in Ruby runs in a frame of its own, so a match in its body rebinds its own `$~`, never its
      # caller's, and `log("parsed"); key = $1` keeps `$1` narrowed; such a call forgets as every implicit-self call
      # did before only in a frame that hands its slot to code the analyzer does not trace, or where no body stamped
      # a frame. A call to a non-matching method (`$3.to_i`, `year < 50`, `buf << c`) is match-free, so the
      # multi-statement `m = /…/ =~ s; …; use($2)` idiom keeps the narrowed globals.
      def match_capable_call?(node)
        return true unless node.is_a?(Prism::CallNode)

        MatchRebinding::Calls.statement_rebinds?(node, operand_scope)
      end

      # Returns a scope with each ivar's narrowed local binding widened back to its class-ivar seed value when the call
      # is one that could plausibly mutate ivars on the enclosing class (implicit-self or explicit `self.foo`).
      # External- receiver calls (`obj.method`) cannot reach the caller's ivars; they pass through unchanged.
      def invalidate_ivars_for_intervening_call(call_node, current_scope)
        return current_scope unless intervening_call_candidate?(call_node)

        class_name = enclosing_class_name_for(current_scope.self_type)
        return current_scope if class_name.nil?

        seed = current_scope.class_ivars_for(class_name)
        return current_scope if seed.empty?

        widened = current_scope
        seed.each do |ivar_name, seed_type|
          local_type = current_scope.ivar(ivar_name)
          next if local_type.nil? || local_type == seed_type

          widened = widened.with_ivar(ivar_name, Type::Combinator.union(local_type, seed_type))
        end
        widened
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

      # v0.0.3 — recognises a small catalogue of RSpec matcher patterns as assert-shaped narrows on the local passed to
      # `expect(...)`. The pattern is matched purely on AST shape; no RBS for RSpec is required (and none is shipped
      # today).
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
      # Anything else is silently passed through. Symmetric negative class assertions (`not_to be_a(C)`) and narrowing
      # TO `NilClass` are intentionally NOT modelled: they are rarely useful in practice and risk masking bugs if the
      # assertion later fails.
      def apply_rspec_matcher_narrowing(call_node, current_scope)
        narrow = rspec_matcher_narrowing_request(call_node)
        return current_scope if narrow.nil?

        local_name = narrow.fetch(:local)
        current_type = current_scope.local(local_name)
        return current_scope if current_type.nil?

        narrowed = apply_rspec_narrow(current_type, narrow, current_scope.environment)
        current_scope.with_local(local_name, narrowed)
      end

      # Decodes an `expect(x).<chain>` outer call into a narrowing request hash, or `nil` when the shape is not
      # recognised. The hash carries `:local` (the local name being narrowed) plus the narrowing parameters.
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

      # `be_a` / `be_kind_of` / `be_an_instance_of` accept a single class argument — either a `ConstantReadNode`
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

      # Returns the local name passed to `expect(...)` when the receiver chain matches `expect(<local>)` exactly, or nil
      # otherwise. Centralised so each per-matcher decoder can short-circuit on a non-matching outer call.
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

      # True when `call_node`'s sole argument is an implicit-self matcher call with the given name and no positional
      # arguments — used by the no-arg matchers (`be_nil`).
      def rspec_matcher_argument?(call_node, matcher_name)
        matcher = rspec_matcher_node(call_node)
        return false if matcher.nil?
        return false unless matcher.name == matcher_name

        matcher.arguments.nil? || matcher.arguments.arguments.empty?
      end

      # Slice 4b-2 (ADR-7 § "Slice 4-A/4-B") — applies the post-return facts the merger produces for an
      # `RBS::Extended`-annotated call. Reads through `RbsExtended.read_flow_contribution` so the bundle carries the
      # canonical `Rigor::FlowContribution::Fact` rows for `:always` assert directives (the slice-4a routing places
      # conditional asserts on `truthy_facts` / `falsey_facts`, which `Narrowing.predicate_scopes` consumes). Plugin
      # `:always` assertions are handled by the sibling `apply_plugin_assertions`, not this path.
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

      # ADR-7 § "Slice 4-A" / T.bind priority slice 2 — applies the post-return facts plugin contributions produce. This
      # is the sibling of {apply_rbs_extended_assertions}: the carrier (`Rigor::FlowContribution::Fact`) and the
      # downstream narrowing path (`apply_post_return_fact` → `apply_self_post_return_fact`) are the same; only the
      # *source* of the bundle changes (RBS::Extended vs the registered plugins' `flow_contribution_for`).
      #
      # `:self`-targeted facts narrow `scope.self_type` for the surrounding scope. In a block body, the surrounding
      # scope is the block's own scope, so the narrowing applies to the rest of the block — exactly the contract
      # Sorbet's `T.bind(self, T)` commits to.
      #
      # `:parameter`-targeted facts only land when the called method has an authoritative RBS sig (via
      # `resolve_call_method`); plugins recognising their own synthetic call shapes (e.g. `T.assert_type!`) have no
      # method_def and the parameter facts silently skip — the plugin's own diagnostics_for_file path covers those
      # cases. The full plugin-side parameter-targeting story (PHPStan-style Type-Specifying Extensions on
      # plugin-recognised calls) lives behind a follow-up slice that introduces `:local` / `:argument_at` target kinds.
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

      # ADR-37 slice 2 / ADR-52 WD3 — gathers each plugin's post-return narrowing from the method-gated
      # `narrowing_facts` DSL, wrapped as a facts-only `FlowContribution`, swallowing per-plugin exceptions so a buggy
      # plugin can't abort the assertion path.
      EMPTY_CONTRIBUTIONS = [].freeze
      private_constant :EMPTY_CONTRIBUTIONS

      # Fast-exit guard: skip if no plugin declares a `narrowing_facts` rule, or if no registered method-name gate
      # matches the call. See `collect_gated_statement_contributions` for the full consultation.
      def collect_plugin_contributions(registry, call_node, current_scope)
        index = registry.contribution_index
        relevant = index.for_statement
        return EMPTY_CONTRIBUTIONS if relevant.empty?

        name = call_node.respond_to?(:name) ? call_node.name : nil
        return EMPTY_CONTRIBUTIONS unless index.statement_candidate?(name)

        collect_gated_statement_contributions(index, relevant, name, call_node, current_scope)
      end

      # ADR-37 slice 2 / ADR-52 WD1 — post-gate walk in registry order. Visits only plugins in `for_statement` (declare
      # a `narrowing_facts` rule), further gated by the method-name Set probe so the common no-candidate case is a
      # single lookup. Accumulates lazily; caller is read-only.
      def collect_gated_statement_contributions(index, relevant, name, call_node, current_scope)
        result = nil
        relevant.each do |plugin|
          next unless index.narrowing_facts_candidate_for?(plugin, name)

          facts = plugin.narrowing_facts_for(call_node: call_node, scope: current_scope)
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

      # Slice 4b-2 — applies a single post-return Fact to the scope. Mirrors `Narrowing#apply_fact_to_scope` (Fact
      # variant of the v0.0.2 `apply_assert_effect`); shares the narrowing logic via `Narrowing.narrow_for_fact` so the
      # predicate / assert / plugin paths all converge on the same hierarchy-aware narrowing rules.
      #
      # v0.1.8 Pillar 2 Slice 1 added the `:local` target_kind branch so plugins recognising bespoke call shapes
      # (`expect(x).to be_a(T)`) can directly narrow a named local in the surrounding scope, bypassing the
      # parameter-name lookup that requires an authoritative RBS sig on the called method (which RSpec matchers lack).
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

      # v0.1.8 Pillar 2 Slice 1 — narrows the named local directly without consulting the call node's argument list. The
      # fact's `target_name` is the local-variable name as written in source. Silently no-ops when the local is unbound
      # in the current scope (the plugin's named local may have already gone out of scope when the contribution fires).
      def apply_local_post_return_fact(fact, current_scope)
        local_name = fact.target_name
        current_type = current_scope.local(local_name)
        return current_scope if current_type.nil?

        narrowed = Narrowing.narrow_for_fact(current_type, fact, current_scope.environment)
        current_scope.with_local(local_name, narrowed)
      end

      # v0.1.1 Track 1 slice 3 — `assert self is T` post-return narrowing for the four supported receiver shapes
      # (mirrors `Narrowing#apply_self_fact`).
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

      # `:self` routes to the call receiver; otherwise we look up the matching positional argument by parameter name.
      def fact_target_node(fact, call_node, method_def)
        if fact.target_kind == :self
          call_node.receiver
        else
          lookup_post_return_arg(call_node, method_def, fact.target_name)
        end
      end

      def lookup_post_return_arg(call_node, method_def, target_name)
        # Plugin-source contributions arrive without an authoritative method_def (the plugin recognised the call shape
        # directly). Parameter-targeting falls back to "no narrow" in that case — the wider plugin-side parameter
        # mapping (`:local` / `:argument_at`) is a follow-up slice.
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

        block_entry = narrow_define_method_block_self(node, build_block_entry_scope(node, block))
        # #319 — `Class.new do ... end` and friends evaluate their block as a CLASS BODY (`class_eval`
        # semantics): `self` is the freshly created class, so a `def` inside defines an instance method on it
        # and `attr_reader` runs as a class-level macro. Enter the block under the same `self_type` /
        # class-context a `class Foo ... end` body gets, keyed by the call site's anonymous name — the name
        # `ScopeIndexer` registered the body's methods under. Without it the body inherits the enclosing
        # scope, and at file top level that means `Scope#toplevel?` (a nil `self_type`) reports every macro
        # call in the body as `call.unresolved-toplevel`.
        #
        # Outer locals stay visible: unlike a `class` keyword body, the block is a closure.
        anonymous = AnonymousMetaClass.name_for(node, scope.source_path)
        if anonymous.nil?
          return sub_eval(block, block_entry) unless return_barrier_block?(node)

          return without_return_sink { sub_eval(block, block_entry) }
        end

        enter_meta_class_body(block, block_entry, [ClassFrame.new(name: anonymous, singleton: false)])
      end

      # The block calls whose body `return` leaves only the block ({ReturnBarrier.block_call?}). Like a `->` body
      # ({#eval_lambda}), each runs with the enclosing method's return sink suspended.
      def return_barrier_block?(node)
        ReturnBarrier.block_call?(node)
      end

      # Runs the block with the method's return sink suspended, for a body whose `return` is not the method's.
      def without_return_sink
        outer_sink = Thread.current[RETURN_SINK_KEY]
        Thread.current[RETURN_SINK_KEY] = nil
        begin
          yield
        ensure
          Thread.current[RETURN_SINK_KEY] = outer_sink
        end
      end

      # Issue #963 — `define_method(:name) { ... }` in a class body defines an INSTANCE method, and Ruby runs
      # the block with `self` bound to the receiving instance. Without this the block inherits the class body's
      # `Singleton[C]`, and #618's own-method veto asks the singleton side of a name the instance side answers.
      # {DefineMethodBlockSelf} owns the match; a non-match leaves the entry scope exactly as it was.
      #
      # The exclusion — the `class << ...` BODY, where `self` is the singleton class and the call defines a class
      # method — rides on `Scope#singleton_class_body?`, not on the frame stack: a `def` reached from that body
      # still carries the singleton frame although its `self` is the class object, and it is an instance method
      # the call defines there. Carrying the mark on the scope is also what lets the return-typing path apply the
      # same exclusion, which has no frame stack of its own.
      def narrow_define_method_block_self(call_node, block_entry)
        narrowed = DefineMethodBlockSelf.narrow_self_type_for(
          scope: scope, call_node: call_node
        )
        narrowed ? block_entry.with_self_type(narrowed) : block_entry
      end

      # Enters a meta-new `block` as the body of the class `class_context` names: `self_type` is that class's
      # singleton, so a `def` inside binds an instance method on it through the ordinary
      # {#self_type_for_method_body} route, while `block_entry` keeps the outer locals visible. Shared by the two
      # positions such a block is reached from — a statement-level call ({#evaluate_block_if_present}) and a
      # constant-write rvalue ({#eval_constant_write}) — so the two cannot drift on what a class body's entry is.
      #
      # Issue #652 — the body keeps this evaluator's `Module.nesting`. A BLOCK never pushes a cref, however
      # much `class_eval` semantics make it behave like a class body in every other respect, so
      # `K = Class.new do … end` written inside `module Outer` reads `Outer::LABEL` at runtime and MUST NOT
      # record a `Outer::K` entry: that is a rung Ruby's constant lookup does not have. The `class_context`
      # frame is still pushed — it is what a nested `def` registers its method under — which is exactly the
      # divergence that makes the chain a separate record rather than a view of the frame stack.
      def enter_meta_class_body(block, block_entry, class_context)
        entry = block_entry.with_self_type(self_type_for_class_body(class_context)).with_singleton_class_body(false)
        sub_eval(block, stamp_nesting(entry, @lexical_nesting), class_context: class_context)
      end

      # Slice 6 phase C sub-phase 3b/3c. When the call carries a block whose receiving method is NOT proven
      # non-escaping:
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
      # A `:non_escaping` classification (or any block-less call) leaves the post-call scope unchanged.
      def record_closure_escape_if_any(node)
        # ADR-57 slice 3 work-item 1: an escaping block can also be attached to a RECEIVER call in a chain rather than
        # to `node` itself — the canonical `OptionParser.new do |opts| opts.on { o[:k] = v } end .parse!(argv)` idiom,
        # where the content-mutating block hangs off `OptionParser.new` but the statement-level call node is the chained
        # `.parse!`. A receiver call is evaluated as an expression, never as a statement, so its block never reaches
        # this escape handler on its own. Fold each escaping receiver-chain block's content widening into the
        # continuation here so the captured collection is floored regardless of how deep in the receiver chain its
        # mutating block lives.
        post_scope = widen_escaping_receiver_chain_captures(node, scope)

        return post_scope unless node.block.is_a?(Prism::BlockNode)

        classification = classify_closure_escape(node)
        return post_scope if classification == :non_escaping

        post_scope = escaping_closure_captures(node.block, post_scope)
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

      # Floor each caller-argument local whose matching parameter the resolved callee escape-mutates (see the call-site
      # comment). Only self-dispatch calls resolving to a discovered user def are considered; the per-def "which
      # parameters escape-mutate" set is memoised on the def node.
      def widen_callee_escaped_argument_captures(node, base_scope)
        # Apply to the statement call AND every call in its receiver chain: the
        # `build_option_parser(options).parse!(argv)` idiom puts the escape- mutating helper call in the RECEIVER
        # position, where its argument is never the statement node's own argument.
        acc = floor_callee_escaped_args_for_call(node, base_scope)
        receiver = node.receiver
        while receiver.is_a?(Prism::CallNode)
          acc = floor_callee_escaped_args_for_call(receiver, acc)
          receiver = receiver.receiver
        end
        acc
      end

      # Runs for every call of every body it walks, and nearly every call reports no argument, so that case returns
      # before `reduce`: `Enumerable#inject` allocates its iteration state even over an empty array.
      def floor_callee_escaped_args_for_call(node, base_scope)
        arguments = content_mutated_arguments(node)
        return base_scope if arguments.empty?

        arguments.reduce(base_scope) do |acc, argument|
          next acc unless acc.locals.key?(argument.name)

          floored = content_floor_for(acc.local(argument.name))
          floored.nil? ? acc : acc.with_mutated_local(argument.name, floored)
        end
      end

      # The `{ name => position }` positional parameters whose content the callee mutates, from either channel: those
      # escape-mutated inside a block (which may run later / repeatedly) AND those mutated directly in the method body
      # during the call itself (`declaration[:prefix] = v`). Both leave the caller's argument binding stale after the
      # call, so both floor it. Memoised per def node (the merge is otherwise recomputed at every call site).
      def callee_content_mutated_parameters(def_node)
        cache = (@callee_mutated_param_cache ||= {}.compare_by_identity)
        cache[def_node] ||= escaped_content_parameters(def_node).merge(direct_content_parameters(def_node))
      end

      # The user def a self-dispatch `node` resolves to in the enclosing class, or nil. Reuses the discovery index
      # `Scope#user_def_for` reads; no ancestor walk (the boundary-escape idiom is same-class), keeping this off the hot
      # path for the overwhelming majority of self-calls that resolve to nothing escaping.
      def resolve_self_callee_def(node)
        class_name = enclosing_class_name_for(scope.self_type)
        return scope.top_level_def_for(node.name) if class_name.nil?

        scope.user_def_for(class_name, node.name)
      end

      def self_dispatch_call?(node)
        return false unless node.is_a?(Prism::CallNode)

        node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)
      end

      # The set of `[name, position]` parameters of `def_node` whose content a block in the body escape-mutates.
      # Memoised per def node (the body walk is otherwise repeated at every call site). A parameter is "escape- mutated"
      # when a `param[k] = v` / `param << x` mutation on it appears inside a block whose receiving call is not proven
      # non-escaping.
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

      # The `{ name => position }` positional parameters whose CONTENT the callee mutates directly in its method body —
      # a top-level `param[k] = v` / `param << x`, outside a nested block. Memoised per def node. The block-nested case
      # is `escaped_content_parameters`'s job; walking only outside nested blocks / defs / lambdas here means a matching
      # parameter-name read is genuinely at method scope (depth 0) rather than a block-local of the same name that
      # merely shadows the parameter — so we never floor a caller argument the callee did not actually mutate.
      def direct_content_parameters(def_node)
        cache = (@direct_param_cache ||= {}.compare_by_identity)
        cache[def_node] ||= compute_direct_content_parameters(def_node)
      end

      def compute_direct_content_parameters(def_node)
        positions = positional_parameter_positions(def_node)
        return {} if positions.empty?

        mutated = Set.new
        each_node_outside_nested_scopes(def_node.body) do |descendant|
          name, = content_mutation_target(descendant) { |r| r.is_a?(Prism::LocalVariableReadNode) && r.depth.zero? }
          mutated << name if !name.nil? && positions.key?(name)
        end
        positions.slice(*mutated)
      end

      # Yields every node reachable from `body` without crossing into a nested block / def / lambda — i.e. the nodes
      # that execute in the method's own scope. A local-variable read found here has depth 0 relative to the method, so
      # a content mutation whose receiver is a positional-parameter name is a genuine mutation of that parameter.
      def each_node_outside_nested_scopes(node, &)
        return if node.nil?

        yield node
        node.rigor_each_child do |child|
          next if child.is_a?(Prism::BlockNode) || child.is_a?(Prism::DefNode) || child.is_a?(Prism::LambdaNode)

          each_node_outside_nested_scopes(child, &)
        end
      end

      # A receiver-independent over-approximation of `ClosureEscapeAnalyzer`'s non-escaping verdict, used when scanning
      # a callee body where the block- owning call's receiver TYPE is not available. A call whose method name is a known
      # structural iterator (`each` / `map` / `tap` / …) runs its block synchronously and does not retain it, so its
      # captured mutations are not a cross-boundary escape. Any other name (`on`, `subscribe`, `define_method`, an
      # unknown DSL hook) is treated as escaping — sound, since mis-classifying a truly-non-escaping call only floors an
      # argument that was about to be precise.
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

      # `{ name => position }` for the required / optional positional parameters of a def. Keyword / rest / block
      # parameters are skipped — the boundary-escape idiom passes a plain positional collection.
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

      # True when at least one argument of `node` is a bare local-variable read (positional or keyword value) bound in
      # the current scope — a cheap pre-filter so the def resolution / body scan only runs for calls that could actually
      # floor something.
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

      # Walk the receiver chain of `node` and fold the escaping-content widening of every block-bearing, escaping
      # receiver call into `base_scope`. Only receiver calls are walked — `node` itself is handled by the caller. A
      # `:non_escaping` receiver block is left to slice C's non-escaping write-back (which the receiver expression
      # evaluation already drives), so we only floor the escaping / unknown ones here.
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

      # ADR-57 slice 2 (ADR-56 mechanisms 2 / 8 extended to escaping blocks). An escaping / unknown block that
      # CONTENT-mutates a captured outer local (`options[:k] = v` in an `OptionParser#on` block, `s << x` in a stored
      # proc) previously left that local's content untouched — only its narrowing was dropped, so a constant seed
      # (`options = {}`, `s = ""`) survived and its element fold (`options[:format]` -> `"text"`, `s.empty?` -> `true`)
      # was unsoundly precise.
      #
      # An escaping block may run later and any number of times, so joining a bounded evidence set is not sound (unlike
      # slice C's non-escaping join): the sound continuation is the bare-collection floor — Array ->
      # `Array[Dynamic[top]]`, Hash -> `Hash[untyped, untyped]`, String -> `String`. The seed's element/key/value
      # precision is forgotten; only the carrier survives. Read-only captures and locals the block merely rebinds
      # (already floored by `drop_captured_narrowing`) are untouched.
      def widen_escaping_content_captures(block_node, post_scope)
        body = block_node.body
        return post_scope if body.nil?

        # Transitive case first: the body may content-mutate a captured local through a self-call rather than a direct
        # `local[k] = v` write, which `collect_content_mutations` cannot see (see below).
        post_scope = floor_block_body_callee_escaped_args(body, post_scope)

        mutations = collect_content_mutations(body)
        return post_scope if mutations.empty?

        mutations.keys.reduce(post_scope) do |acc, name|
          floored = content_floor_for(acc.local(name))
          floored.nil? ? acc : acc.with_mutated_local(name, floored)
        end
      end

      # Inside an ESCAPING block body, a captured outer local can be content- mutated transitively: the body is (or
      # contains) a self-call that escape-mutates one of its arguments. The canonical shape is the CLI's own
      # `OptionParser.new { |opts| define_options(opts, options) }` — the block body is a bare `define_options(opts,
      # options)` whose `options` parameter is escape-mutated inside ITS nested `opts.on { options[:k] = v }` blocks.
      # `collect_content_mutations` only sees direct `local[k] = v` writes in THIS body, so it misses the transitive
      # write and the captured Hash keeps its literal-false seed (folding the caller's `options[:mutation]` guard to an
      # always-falsey constant). Reuse the cross-method-boundary callee-escaped-argument floor (the same gate the
      # receiver-chain path uses at the call site) on every self-call in the body. Sound — only ever floors a captured
      # local passed as an argument to a callee that demonstrably escape-mutates the matching parameter.
      def floor_block_body_callee_escaped_args(body, post_scope)
        acc = post_scope
        Source::NodeWalker.each(body) do |descendant|
          acc = floor_callee_escaped_args_for_call(descendant, acc) if descendant.is_a?(Prism::CallNode)
        end
        acc
      end

      # The Dynamic-floor carrier for a content-mutated escaping capture, or nil when the pre-state is not a recognised
      # mutable collection (leave it alone — e.g. an already-`Dynamic` binding or an unknown shape).
      #
      # A String counts in any refined form (`non-empty-string`, `decimal-int-string`), which `stringish?` does not
      # accept: the mutation can empty or rewrite it as it can a plain `String`.
      def content_floor_for(type)
        return nil if type.nil?
        # A union with a String member floors member by member, so neither carrier swallows the other and a member no
        # mutation can fill (`nil`) stays: taken whole, `Array | String` floored to `Array[untyped]` and `String?` to
        # nothing at all.
        return UnknownStoreWidening.content_floor(type) if string_union?(type)

        if UnknownStoreWidening.carrier_class(type) == "String"
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
        receiver_type = call_node.receiver ? type_operand(call_node.receiver) : nil
        ClosureEscapeAnalyzer.classify(
          receiver_type: receiver_type,
          method_name: call_node.name,
          environment: scope.environment
        )
      rescue StandardError
        :unknown
      end

      # Sub-phase 3c. Replace the outer-local types that the block body can rebind with `Dynamic[Top]`. The conservative
      # drop matches the spec line "facts about locals it can write become unstable after the escape point": rather than
      # synthesise the union of the block's write types (which the current pass does not yet expose), we discard the
      # narrowed binding altogether. A future sub-phase MAY refine this to the union of the block's actual writes.
      #
      # An instance variable the body rebinds is dropped the same way: the block shares the caller's `self`, so a
      # callback that runs later writes the very ivar the continuation reads (`@clicked = false; button.on_click {
      # @clicked = true }` left `if @clicked` folding always-falsey). One still on its ADR-58 declaration seed is
      # left alone ({CapturedLocals.writes}): that seed already holds whatever the callback stores.
      def drop_captured_narrowing(block_node, base_scope)
        names = CapturedLocals.writes(block_node, base_scope, ivars: true)
        return base_scope if names.empty?

        names.reduce(base_scope) { |acc, name| bind_capture(acc, name, Type::Combinator.untyped) }
      end

      # ADR-56 slice A. For a `:non_escaping` block, fold the continuation binding of every outer local the body can
      # rebind back into `post_scope`. The binding is a capped fixpoint (cap 3) over the block body re-evaluated under
      # the running per-name assumption, joined with the pre-call binding (kept as a constituent so the 0-iteration path
      # — `[].each { … }` — stays sound), value-pinned- widened on the final permitted iteration, and floored to
      # `Dynamic[top]` on non-convergence (matching `drop_captured_narrowing`).
      #
      # The instance variables the body rebinds (`CapturedLocals.writes` with `ivars: true`) outlive the call the same
      # way — `@n = 0; [1, 2].each { @n += 1 }` left `@n == 0` folding always-truthy — so they join the name set,
      # seeded from their pre-call binding. See {#converge_captures_by_kind} for how a block that rebinds both kinds is
      # answered.
      #
      # Fast path: a block writing no outer local and no rebindable ivar leaves `post_scope` byte-identical (the
      # overwhelming majority of blocks), so this costs one `CapturedLocals.writes` walk and nothing else.
      #
      # Every pass reads a captured local the body mutates IN PLACE at its unknown-store widening
      # ({#capture_pass_bindings}), never at the contents the collection held before the call: only the rebound names
      # move between passes, so a rebind read from such a collection (`last = a.last; a << x`) would otherwise record
      # the first iteration's answer on every pass and the fixpoint would close over it (ADR-56 WD2.13, second
      # residue).
      def write_back_block_captures(call_node, post_scope)
        block = call_node.block
        return post_scope unless block.is_a?(Prism::BlockNode)
        return post_scope unless classify_closure_escape(call_node) == :non_escaping

        names = CapturedLocals.writes(block, scope, ivars: true)
        return post_scope if names.empty?

        break_pass = block_break_pass(block)
        result = converge_captures_by_kind(call_node, block, names, break_pass)
        result = join_block_break_bindings(call_node, block, result, break_pass)
        result.reduce(post_scope) { |acc, (name, type)| bind_capture(acc, name, type) }
      end

      # The {BodyFixpoint} continuation of `names`, seeded from their pre-call bindings.
      def converge_block_captures(call_node, block, names, break_pass)
        BodyFixpoint.converge(
          names: names,
          seed_bindings: names.to_h { |name| [name, CapturedLocals.bound_type(scope, name)] },
          widen: Type::Combinator.method(:widen_value_pinned),
          evaluate_body: ->(bindings) { block_pass_exit_bindings(call_node, block, bindings, names, break_pass) }
        )
      end

      # The continuation of a block's rebound names. One {BodyFixpoint} over locals and ivars together is the wrong
      # answer for most of them: its final pass widens every name while any name still moves, so an ivar counter beside
      # `mode = :b` turned `mode`'s converged `:a | :b` into `Symbol` — and a local counter beside `@mode = :b` did the
      # same to `@mode` — and `take(mode)` against `(:a | :b) -> void` fired on code each kind's own fixpoint accepts.
      #
      # So each kind converges on its own first, with the other at its pre-call binding; for a block that rebinds one
      # kind that is the only fixpoint, and for the locals it is exactly the one a block rebinding no ivar has always
      # had. A name converged that way is wrong when it reads the other kind (`last = @n; @n += 1`, `@last = count`),
      # so one more pass under the settled bindings checks every name, and one whose exit leaves its settled binding
      # takes its answer from a joint fixpoint over both kinds, computed only then. The check repeats, because a name
      # read off a moved one (`first = last`) may move in turn; every round moves a name to its joint answer or stops.
      #
      # The body's last evaluation is therefore a pass under the settled bindings, so the scopes recorded inside the
      # block read those rather than a pass that pinned one kind to its pre-call value.
      #
      # `break_pass` ({#block_break_pass}) rides along so every pass — a fixpoint's or a check's — leaves its `break`
      # scopes for {#join_block_break_bindings}.
      def converge_captures_by_kind(call_node, block, names, break_pass)
        kinds = names.partition { |name| !CapturedLocals.ivar_name?(name) }
        return converge_block_captures(call_node, block, names, break_pass) if kinds.any?(&:empty?)

        settled = kinds.map { |kind| converge_block_captures(call_node, block, kind, break_pass) }.reduce(:merge)
        joint = nil
        loop do
          exits = block_pass_exit_bindings(call_node, block, settled, names, break_pass)
          moved = escaped_captures(settled, exits, joint)
          return settled if moved.empty?

          joint ||= converge_block_captures(call_node, block, names, break_pass)
          moved.each { |name| settled[name] = joint[name] }
        end
      end

      # The names whose `exits` leave their `settled` binding, less those already on their `joint` answer.
      def escaped_captures(settled, exits, joint)
        settled.keys.select do |name|
          exit_type = exits[name]
          next false if exit_type.nil? || (joint && settled[name] == joint[name])

          Type::Combinator.union(settled[name], exit_type) != settled[name]
        end
      end

      # Binds a name from `CapturedLocals.writes`. An ivar goes through {CapturedLocals.bind}, which keeps its issue
      # #286 optimistic mark. A local keeps the plain `with_local` these seams have always used, so a block that
      # rebinds no ivar leaves the locals exactly as before.
      def bind_capture(scope, name, type)
        CapturedLocals.ivar_name?(name) ? CapturedLocals.bind(scope, name, type) : scope.with_local(name, type)
      end

      # A block-level `break` ends the CALL, so the binding it leaves with starts no further iteration and is no input
      # to the write-back fixpoint — feeding it back would type the next pass's body under a value the body never sees
      # (`acc = "s"; break` reaching the next pass's `acc`). It IS the continuation's binding on that path, though, and
      # without this join `found = nil; xs.each { |x| if x > 1; found = x; break; end }` left `found` on `nil` and
      # folded `if found` always-falsey.
      #
      # The arms must come from a pass whose entry is the CONVERGED binding, which contains every iteration's entry.
      # The write-back's last pass usually is one — a fixpoint that stabilised, and every by-kind check pass
      # ({#converge_captures_by_kind}), ran from the binding it returns — so its arms are reused
      # ({#block_pass_exit_bindings}). A capped fixpoint's widened binding was never evaluated, so only then does one
      # more pass run, without recording into the per-node scope index: that index keeps the write-back's own last
      # pass, which the check path's diagnostics read, exactly as the loop fixpoint's converged re-record is
      # display-only ({#record_converged_loop_body}). A name the fixpoint floored to `Dynamic[top]` keeps the floor; a
      # precise arm unioned into it would read as knowledge the analysis does not have.
      def join_block_break_bindings(call_node, block, converged, break_pass)
        return converged if break_pass.nil?

        arms =
          if break_pass[:entry] == converged
            break_pass[:arms]
          else
            converged_break_arms(call_node, block, converged, break_pass[:targets])
          end
        return converged if arms.empty?

        floor = Type::Combinator.untyped
        converged.to_h do |name, type|
          next [name, type] if type == floor

          [name, Type::Combinator.union(type, *arms.filter_map { |arm| CapturedLocals.bound_type(arm, name) })]
        end
      end

      # nil for a body with no block-level `break` — one allocation-free scan, and the write-back runs exactly as
      # before. Otherwise the record {#block_pass_exit_bindings} fills: the targeting `break`s, and the entry
      # bindings and `break` scopes of the most recent fixpoint pass.
      def block_break_pass(block)
        body = block.body
        return nil unless JumpTargets.any?(body, Prism::BreakNode)

        { targets: JumpTargets.of(body, Prism::BreakNode), entry: nil, arms: [] }
      end

      # One write-back fixpoint pass ({#block_exit_bindings}), collecting the scopes at the block-level `break`s it
      # reaches when there are any. `BodyFixpoint` hands every pass the same mutable assumption, so the entry is
      # copied before the fixpoint moves it.
      def block_pass_exit_bindings(call_node, block, bindings, names, break_pass)
        return block_exit_bindings(call_node, block, bindings, names) if break_pass.nil?

        sink, exits = collect_break_scopes { block_exit_bindings(call_node, block, bindings, names) }
        break_pass[:entry] = bindings.dup
        break_pass[:arms] = targeted_scopes(sink, break_pass[:targets])
        exits
      end

      # The `break` scopes of one unrecorded pass from `converged` — for a capped fixpoint, whose widened binding no
      # pass has run from.
      def converged_break_arms(call_node, block, converged, targets)
        entry = block_pass_entry(call_node, block, converged)
        sink, = collect_break_scopes { sub_eval(block, entry, **UNRECORDED) }
        targeted_scopes(sink, targets)
      end

      # ADR-56 slice C — receiver-content element-type join. After the rebind write-back and
      # `MutationWidening.widen_after_block` (which forgets a content-mutated collection's literal arity but keeps only
      # the SEED's element types), join the appended/stored element / key / value types INTO the continuation
      # collection's parameter, so `out = [0]; arr.each { |x| out << x }` types `out` as `Array[0 | Integer]` (sound)
      # rather than `Array[0]` (the B1 under-approximation: the runtime array is `[0, 1, 2, 3]`).
      #
      # **Pre-state is read from `seed_scope` — the scope as it stood BEFORE `widen_after_block` ran.** The widening
      # spells an empty `[]` as `Array[untyped]`, and read back after the fact that `untyped` cannot be told from a
      # DECLARED one: the join used to drop every seed `Dynamic` once the body contributed concrete evidence, which
      # made `out = []; xs.each { out << x }` read `Array[Integer]` — and closed a parameter declared `Array[untyped]`
      # to `Array[Integer]` on the same rule, so `a.first.upcase` drew `undefined method` on code the declaration
      # licenses (issue #586). Read before the widening, an empty literal contributes no element and a declared
      # gradual arm is just another seed arm the join keeps. The pre-widen scope still carries the slice-A rebind
      # write-back — so a local that is BOTH rebound and content-mutated composes as before — and every other
      # post-call effect applied ahead of the widening; the pre-CALL `scope` would carry neither. The loop seam makes
      # the same choice with `pre_body`; see {#loop_content_writeback}.
      #
      # The stored evidence is typed in the block-entry scope and iterated to a fixpoint when a store reads a
      # collection the join moves — see {#join_content_to_fixpoint}. Always sound — only ever widens.
      def content_writeback_block_captures(call_node, post_scope, seed_scope:)
        block = call_node.block
        return post_scope unless block.is_a?(Prism::BlockNode)
        return post_scope unless classify_closure_escape(call_node) == :non_escaping

        body = block.body
        return post_scope if body.nil?

        shadows = {}.compare_by_identity
        mutations = captured_content_mutations(block, shadows)
        return post_scope if mutations.empty?

        seeds = mutations.to_h do |name, _calls|
          [name, lookup_mutated_seed(body, name, seed_scope.local(name)) { |depth, nesting| depth > nesting }]
        end
        shadow_rebound_reads(block, mutations, seeds, shadows)
        joined = join_content_to_fixpoint(mutations, seeds, build_block_entry_scope(call_node, block), shadows)
        rewrites = local_rewrites(block.body) { |receiver, ancestors| receiver.depth > scope_nesting(ancestors) }
        joined.reduce(post_scope) do |acc, (name, type)|
          acc.with_mutated_local(name, rewritten_capture(type, seeds[name], rewrites.fetch(name, NO_REWRITES)))
        end
      end

      NO_REWRITES = [].freeze
      private_constant :NO_REWRITES

      # The {RewriteMutation} names `root` calls on each local its block admits — `a.map!(&:to_s)` beside an `a << x`.
      # The receiver test is the one the caller's content-mutation walk applies.
      def local_rewrites(root)
        rewrites = {}
        Source::NodeWalker.each_with_ancestors(root) do |node, ancestors|
          next unless node.is_a?(Prism::CallNode) && RewriteMutation.rewriter?(node.name)

          receiver = node.receiver
          next unless receiver.is_a?(Prism::LocalVariableReadNode) && yield(receiver, ancestors)

          (rewrites[receiver.name] ||= []) << node.name
        end
        rewrites
      end

      # The slice-C join (and the loop seam's) rebuilds a collection from its SEED, so the rewrite the body's own
      # widening applied is gone from it: `a = [1]; [0].each { a.map!(&:to_s); a << "x" }` read `Array["x" | 1]`, and
      # `a[0] == "1"` folded always-falsey. Each rewrite the body makes on the local is re-applied here, on the seam's
      # terms: a seed the straight-line widening may not grow (a precise nominal, #561) is left as the join answered it.
      def rewritten_capture(type, seed, method_names)
        return type if method_names.empty? || !MutationWidening.shape_carrier?(seed)

        method_names.uniq.reduce(type) { |acc, method_name| RewriteMutation.arm_through(acc, method_name) }
      end

      # Adds to each store's `shadows` every local it reads that the block body writes and the block-entry scope binds:
      # an outer local the body rebinds, or a block parameter or `;`-local it reassigns. A local the body introduces
      # already reads `Dynamic[top]` there. A joined collection the body also rebinds is included: the join's seed
      # carries slice A's continuation, which misses a value written between two rebinds.
      #
      # The block-entry scope binds such a local where the call found it, so a store reading one recorded the first
      # iteration's value: `total = 0; out = []; [1, 2].each { |x| total += x; out << total }` stored `0` as far as the
      # join could tell, `out` read `Array[0]`, and `out.last == 3` folded always-falsey on a program whose `out` is
      # `[1, 3]`. Typed as `Dynamic[top]`, the store is `out`'s one unknown member and nothing folds.
      #
      # Every precise reading tried reported on correct code instead:
      #
      # - slice A's continuation misses a value written between two rebinds;
      # - joined with the block-entry typing, it still stores exit values no store reads;
      # - one more walk of the body to the store inherits every gap in the engine's in-body flow.
      #
      # See ADR-56 WD2.13.
      def shadow_rebound_reads(block, sites, seeds, shadows)
        entry_names = scope.locals.keys | CapturedLocals.introduced_locals(block).to_a
        written = scope_local_writes(block) & entry_names
        return if written.empty?

        sites.each do |name, nodes|
          # A mixed `Array | Hash` seed reads as a Hash here: its key arguments are the Hash side's evidence, and a
          # `Dynamic` index only makes the Array side read the store as both forms.
          array = content_kind(seeds[name]) == :array
          nodes.each do |site|
            names = store_value_reads(site, array) & written
            shadows[site] = shadows.fetch(site, []) | names unless names.empty?
          end
        end
      end

      # The locals a store reads to build what it stores. An Array index write's index arguments are left out, and so
      # is any name they read: the join classifies the store as an element or a splice from the index's type, and a
      # `Dynamic` index reads as both, so `grid[i] = [x, x]` would join `x` itself as a member of `grid` beside the
      # pair. Such an index keeps its block-entry binding, which is master's reading, and so does a stored value that
      # reads the same name: `ids[n] = n; n += 1` still stores `n`'s first-iteration value.
      def store_value_reads(site, array)
        return local_reads(site) unless array

        if site.is_a?(Prism::CallNode) && site.name == :[]=
          *index, value = site.arguments&.arguments || []
          [value, site.receiver].compact.flat_map { |n| local_reads(n) } - index.flat_map { |n| local_reads(n) }
        elsif IndexWriteWidening.index_write?(site)
          value = site.respond_to?(:value) ? site.value : nil
          [value, site.receiver].compact.flat_map { |n| local_reads(n) } - local_reads(site.arguments)
        else
          local_reads(site)
        end
      end

      # Every local the block writes in its own scope or an outer one, in its body or in a parameter's default. A
      # write inside an inner block or lambda to a name that block introduces is a different variable: its `depth`
      # climbs fewer scopes than it is nested in. A method, class or module body inside the block is a scope of its own.
      def scope_local_writes(block)
        names = []
        [block.parameters, block.body].compact.each do |root|
          Source::NodeWalker.each_with_ancestors(root) do |node, ancestors|
            next unless CapturedLocals::LOCAL_WRITE_NODES.any? { |klass| node.is_a?(klass) }

            names << node.name if same_scope_local?(node, ancestors)
          end
        end
        names.uniq
      end

      # The bodies that open a scope of their own, where a local's `depth` starts again from zero.
      SCOPE_BODY_NODES = [Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode].freeze
      private_constant :SCOPE_BODY_NODES

      # True when the local `node` names lives in the scope the walk started in or an outer one.
      def same_scope_local?(node, ancestors)
        return false if ancestors.any? { |ancestor| SCOPE_BODY_NODES.any? { |klass| ancestor.is_a?(klass) } }

        node.depth >= scope_nesting(ancestors)
      end

      # The nodes that read a local's current value: a plain read, and the compound writes that read before they store.
      LOCAL_READ_NODES = [
        Prism::LocalVariableReadNode,
        Prism::LocalVariableOperatorWriteNode,
        Prism::LocalVariableOrWriteNode,
        Prism::LocalVariableAndWriteNode
      ].freeze
      private_constant :LOCAL_READ_NODES

      # Every local `node` reads from the scope it sits in: a read inside an inner block of a name that block
      # introduces is a different variable.
      def local_reads(node)
        return [] if node.nil?

        names = []
        Source::NodeWalker.each_with_ancestors(node) do |n, ancestors|
          next unless LOCAL_READ_NODES.any? { |klass| n.is_a?(klass) }

          names << n.name if same_scope_local?(n, ancestors)
        end
        names.uniq
      end

      # The evidence a content join reads, per collection kind: one element union for an Array, a key union and a
      # value union for a Hash, all three for a seed carrying both ({ContentJoin.join_mixed_content}), and none for a
      # String, which widens to `String` whatever it stored.
      CONTENT_EVIDENCE_SLOTS = {
        array: %i[element].freeze, hash: %i[key value].freeze, mixed: %i[key value element].freeze, string: [].freeze
      }.freeze
      private_constant :CONTENT_EVIDENCE_SLOTS

      # The joined continuation carrier of each content-mutated name, shared by the block seam and
      # {#each_with_object_return}. `sites` maps each name to its mutation nodes, `seeds` to its pre-state; the answer
      # omits a name whose pre-state is no collection.
      #
      # The evidence is typed in the block-entry scope, where each mutated collection still holds its PRE-CALL
      # contents. A store whose evidence reads one of them therefore records the FIRST iteration's answer: `h = { a:
      # 0 }; [:a, :a, :a].each { |k| h[k] = h[k] + 1 }` stored `1` as far as a single pass could tell, the join read
      # `Hash[:a | Symbol, 0 | 1]`, and `h[:a] == 3` folded always-falsey on a program that prints.
      #
      # So each collection a store reads is bound to what it holds at ANY iteration's entry. A name none of whose
      # stores reads a mutated Array or Hash is FIXED: its evidence is the same on every iteration, so it is typed
      # once and the name is bound to its own join — a String to `String`, whatever it stored, so `lens << buf.length`
      # after `buf << w` reads `Integer`, not the length of `buf`'s pre-call value. Every other name MOVES, and its
      # evidence is iterated to a fixpoint through {BodyFixpoint}: each of its evidence slots is one fixpoint name,
      # and each pass re-types its stores with every moving collection bound to its seed joined with the evidence so
      # far. The join above widens to `Hash[Symbol, 0 | Integer]` on the final pass, and evidence that keeps growing
      # structurally floors to `Dynamic[top]`, the slot's one-unknown-store answer. Only moving slots are ever
      # widened, so `acc << 1` beside such a store keeps `Array[1]`.
      #
      # That is what keeps this seam's claim to complete evidence ({MutationWidening#gradual_floor} rests on it): the
      # scan sees every store in the body, and no store's evidence is read off a first-iteration binding. The final
      # pass trusts its widening without re-checking it, exactly as slice A's fixpoint does (ADR-56 WD3). A gradual
      # arm on every self-reading store would be sound too, but its `Dynamic` would quiet every later read of the
      # collection, where the converged `Integer` still reports `h[:a].upcase`. With no moving name — the `acc = [];
      # xs.each { |x| acc.push(x) }` accumulator — this is the single pass it always was.
      #
      # `shadows` maps a site to the names its evidence is typed with bound to `Dynamic[top]`. A site nested in an inner
      # block or lambda lists the names that block binds itself (parameters, `;`-locals): the entry scope is the seam
      # block's, where such a name resolves to the OUTER local it shadows, and `|y| out << y.first` inside the block
      # must not read an outer `y = [0]`. Every site also lists the locals it reads that the body writes
      # ({#shadow_rebound_reads}).
      def join_content_to_fixpoint(sites, seeds, entry, shadows = NO_SHADOWS)
        kinds = seeds.filter_map { |name, seed| (kind = content_kind(seed)) && [name, kind] }.to_h
        return {} if kinds.empty?

        moving = moving_content_names(sites, kinds)
        fixed = kinds.except(*moving)
        strings, settled = fixed.partition { |_name, kind| kind == :string }.map(&:to_h)
        fixed_entry = bind_content_joins(entry, strings, seeds, {})
        evidence = content_evidence(sites, fixed, fixed_entry, shadows)
        unless moving.empty?
          base = bind_content_joins(fixed_entry, settled, seeds, evidence)
          evidence = evidence.merge(converge_content_evidence(sites, seeds, kinds.slice(*moving), base, shadows))
        end
        kinds.to_h { |name, kind| [name, join_content_evidence(seeds[name], kind, name, evidence)] }
      end

      # The pre-state's collection kind, or nil when the join has no carrier to rederive — the dispatch
      # {#join_content_for_param} makes, and the reason it answers nil for the same pre-states. A seed carrying both
      # an Array and a Hash member is `:mixed`, and each side joins with its own class's evidence.
      def content_kind(pre_state)
        return nil if pre_state.nil?
        return :string if stringish?(pre_state)
        return (arrayish?(pre_state) ? :mixed : :hash) if hashish?(pre_state)

        :array if arrayish?(pre_state)
      end

      # The names whose evidence can differ between iterations: a store that reads a mutated Array or Hash among its
      # arguments (a `[]=` call's stored value is one), or an Array-side compound index write (`a[i] += v`), whose
      # stored value is computed from the slot it overwrites. A String never moves — its join is `String` whatever it
      # stored — and the Hash side floors an index write's value, so there only the key arguments are typed.
      def moving_content_names(sites, kinds)
        movable = kinds.reject { |_name, kind| kind == :string }.keys
        movable.select do |name|
          sites[name].any? do |node|
            (kinds[name] == :array && IndexWriteWidening.index_write?(node)) || store_arguments_read?(node, movable)
          end
        end
      end

      def bind_content_joins(scope, kinds, seeds, evidence)
        kinds.reduce(scope) do |acc, (name, kind)|
          acc.with_local(name, content_entry_binding(seeds[name], kind, name, evidence))
        end
      end

      # What a collection holds at any iteration's entry, given the evidence so far: its join, plus the seed members
      # that join refutes. The join already covers every other seed value — a `Tuple`, `HashShape` or `Difference`
      # is absorbed into the rederived carrier and any other member survives beside it — but it drops a seed's
      # `nil` ({ContentJoin::NON_SURVIVING_CLASSES}). The first iteration's entry still holds that `nil`, and it can
      # outlive another collection's growth: without it `out << a.nil?; a ||= []; a << v` read `Array[false]`.
      # Unioning the whole seed back would re-add its literal shape as well, and dispatch over `[] | Array[2]` is
      # wider than over `Array[2]`, so `a[0, 1] ||= [2]` stopped converging.
      def content_entry_binding(seed, kind, name, evidence)
        join = join_content_evidence(seed, kind, name, evidence)
        members = seed.is_a?(Type::Union) ? seed.members : [seed]
        refuted = members.select do |member|
          ContentJoin::NON_SURVIVING_CLASSES.include?(ContentJoin.evidence_class(member))
        end
        refuted.empty? ? join : Type::Combinator.union(join, *refuted)
      end

      # The nodes that open a local scope a read's `depth` counts.
      SCOPE_NESTING_NODES = [Prism::BlockNode, Prism::LambdaNode].freeze
      private_constant :SCOPE_NESTING_NODES

      # The block's captured content mutations: `{ name => [node, ...] }` for every content mutator whose receiver is
      # a local from OUTSIDE the block. A read's `depth` counts the scopes it climbs, so it reaches past the seam's
      # block only when it climbs more scopes than the blocks and lambdas nested between it and the block's body.
      # `collect_content_mutations` tests `depth >= 1`, which is that rule only directly in the body: it took a block
      # PARAMETER mutated inside a nested block (`|y| [9].each { y << 9 }`), or a nested block's own parameter one
      # level deeper, for the outer local it shadows, and the join rebound the parameter to that local's contents.
      #
      # Each site nested in an inner block or lambda is recorded in `shadows` with the names those blocks bind
      # themselves (see {#join_content_to_fixpoint}).
      def captured_content_mutations(block, shadows)
        mutations = Hash.new { |h, k| h[k] = [] }
        Source::NodeWalker.each_with_ancestors(block.body) do |node, ancestors|
          name, site = content_mutation_target(node) { |receiver| receiver.depth > scope_nesting(ancestors) }
          next if name.nil?

          mutations[name] << site
          record_shadows(shadows, site, ancestors)
        end
        mutations
      end

      def scope_nesting(ancestors)
        ancestors.count { |ancestor| scope_nesting_node?(ancestor) }
      end

      def scope_nesting_node?(node)
        SCOPE_NESTING_NODES.any? { |klass| node.is_a?(klass) }
      end

      def record_shadows(shadows, site, ancestors)
        names = ancestors.select { |a| scope_nesting_node?(a) }
                         .flat_map { |a| CapturedLocals.introduced_locals(a).to_a }
        shadows[site] = names unless names.empty?
      end

      # `scope` with each name a site's enclosing inner blocks bind bound to `Dynamic[top]`: the seam's scope cannot
      # see those bindings, and the name would otherwise resolve to the outer local it shadows.
      def site_evidence_scope(scope, site, shadows)
        names = shadows[site]
        return scope if names.nil?

        names.reduce(scope) { |acc, name| acc.with_local(name, Type::Combinator.untyped) }
      end

      # `base` binds every fixed name to its join; the moving names are rebound on each pass.
      def converge_content_evidence(sites, seeds, kinds, base, shadows)
        slots = kinds.flat_map { |name, kind| CONTENT_EVIDENCE_SLOTS.fetch(kind).map { |slot| [name, slot] } }
        BodyFixpoint.converge(
          names: slots,
          seed_bindings: slots.to_h { |slot| [slot, Type::Combinator.bot] },
          widen: Type::Combinator.method(:widen_value_pinned),
          evaluate_body: lambda do |assumption|
            pass_entry = kinds.reduce(base) do |acc, (name, kind)|
              acc.with_local(name, content_carrier_under(seeds[name], kind, name, assumption))
            end
            content_evidence(sites, kinds, pass_entry, shadows)
          end
        )
      end

      # The binding a fixpoint pass reads a moving collection at: its seed until any evidence exists, then — as for a
      # fixed name — {#content_entry_binding} over the evidence so far.
      def content_carrier_under(seed, kind, name, evidence)
        no_evidence = CONTENT_EVIDENCE_SLOTS.fetch(kind).all? { |slot| present_evidence(evidence[[name, slot]]).empty? }
        no_evidence ? seed : content_entry_binding(seed, kind, name, evidence)
      end

      # `{ [name, slot] => union }` for every collection name, typed in `evidence_scope`; a slot no store contributes
      # to reads `bot`.
      def content_evidence(sites, kinds, evidence_scope, shadows)
        kinds.each_with_object({}) do |(name, kind), evidence|
          case kind
          when :hash
            record_pair_evidence(evidence, name, hash_pair_evidence(sites[name], evidence_scope, shadows))
          when :array
            evidence[[name, :element]] =
              Type::Combinator.union(*array_element_evidence(sites[name], evidence_scope, shadows).compact)
          when :mixed
            pairs, elements = mixed_content_evidence(sites[name], evidence_scope, shadows)
            record_pair_evidence(evidence, name, pairs)
            evidence[[name, :element]] = Type::Combinator.union(*elements.compact)
          end
        end
      end

      # A collection seed with a String member (`[1] | "ab"`) joins that member as `String` and the rest as the
      # collection it is ({#join_string_members}); joined whole, the String member survived with its value pinned
      # although a String mutator in the body is what put the name here.
      def join_content_evidence(seed, kind, name, evidence)
        if kind != :string && string_union?(seed)
          return join_string_members(seed) { |others| join_content_evidence(others, kind, name, evidence) }
        end

        case kind
        when :string
          Type::Combinator.nominal_of("String")
        when :hash
          ContentJoin.join_hash_content(seed, joined_pair_evidence(name, evidence))
        when :mixed
          ContentJoin.join_mixed_content(
            seed, joined_pair_evidence(name, evidence), present_evidence(evidence[[name, :element]])
          )
        else
          ContentJoin.join_array_content(seed, present_evidence(evidence[[name, :element]]))
        end
      end

      def record_pair_evidence(evidence, name, pairs)
        evidence[[name, :key]] = Type::Combinator.union(*pairs.map(&:first).compact)
        evidence[[name, :value]] = Type::Combinator.union(*pairs.map(&:last).compact)
      end

      # The `[pairs, elements]` the `calls` on a mixed `Array | Hash` seed store, typed in `entry_scope`. The seam
      # cannot tell which member a store reached, so an index store (`[]=` or an index write) is routed by its index.
      # One no Array accepts — a Symbol, String, `nil` or boolean key, where `[1][:k] = v` raises `TypeError` — is the
      # Hash side's alone. One that could reach either member floors BOTH sides to `Dynamic[top]`: read precisely, its
      # value lands on the side it never reached, and a hand-written `-> Array[Integer] | Hash[Symbol, String]`
      # rejects the `Array["t" | Integer]` a guarded `x[:b] = "t" if x.is_a?(Hash)` made of the Array member. Every
      # other adder belongs to one class, and each side reads it as its single-class join does.
      def mixed_content_evidence(calls, entry_scope, shadows = NO_SHADOWS)
        index_stores, adders = calls.partition { |c| index_write?(c) || (c.is_a?(Prism::CallNode) && c.name == :[]=) }
        hash_only, either = index_stores.partition do |site|
          array_index_excluded?(site, site_evidence_scope(entry_scope, site, shadows))
        end
        pairs = hash_pair_evidence(adders + hash_only, entry_scope, shadows)
        elements = array_element_evidence(adders, entry_scope, shadows)
        return [pairs, elements] if either.empty?

        untyped = Type::Combinator.untyped
        [pairs + [[untyped, untyped]], elements + [untyped]]
      end

      # The classes an Array index never converts from: none defines `to_int`, and none is a Range.
      NON_ARRAY_INDEX_CLASSES = %w[Symbol String NilClass TrueClass FalseClass].to_set.freeze
      private_constant :NON_ARRAY_INDEX_CLASSES

      # True when one of the index store `site`'s index arguments provably holds no value an Array accepts as an index.
      # A splat, and a type with any member of another or unknown class, may hold one.
      def array_index_excluded?(site, scope)
        arguments = site.arguments
        list = arguments.is_a?(Prism::ArgumentsNode) ? arguments.arguments : []
        list = list.take(list.size - 1) if site.is_a?(Prism::CallNode)
        list.any? do |arg|
          next false if arg.is_a?(Prism::SplatNode)

          ContentJoin.union_members(scope.type_of(arg, tracer: tracer)).all? do |member|
            NON_ARRAY_INDEX_CLASSES.include?(ContentJoin.evidence_class(member))
          end
        end
      rescue StandardError
        false
      end

      # The Hash side's evidence as the one `[key, value]` pair its slots join to, or none.
      def joined_pair_evidence(name, evidence)
        key = present_evidence(evidence[[name, :key]]).first
        value = present_evidence(evidence[[name, :value]]).first
        key.nil? && value.nil? ? [] : [[key, value]]
      end

      def present_evidence(type)
        type.nil? || type.is_a?(Type::Bot) ? [] : [type]
      end

      def store_arguments_read?(node, names)
        arguments = node.arguments
        return false if arguments.nil?

        Source::NodeWalker.each(arguments).any? { |n| n.is_a?(Prism::LocalVariableReadNode) && names.include?(n.name) }
      end

      # ADR-56 slice C (B3). For `recv.each_with_object(memo) { |x, acc| … }` the return is the memo object after the
      # block has mutated it through the `acc` alias. Compute the joined memo type the same way captured- local content
      # mutations are joined: pre-state = the memo argument's type, added evidence = the content-mutator args on the
      # memo block param. Returns `call_type` unchanged for any other call, a missing block, or a memo whose pre-state
      # is not a collection.
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

        # The memo alias is a block-local (depth 0) — collect content mutations on it directly rather than via the
        # captured-local walk.
        shadows = {}.compare_by_identity
        calls = body_content_mutations_on(body, memo_param, shadows)
        return call_type if calls.empty?

        pre_state = lookup_mutated_seed(body, memo_param, scope.type_of(memo_arg, tracer: tracer)) do |depth, nesting|
          depth == nesting
        end
        joined = join_memo_content(call_node, memo_param, calls, pre_state, shadows)
        joined || call_type
      end

      # `seed` as the {HashLookupMutation} calls `body` makes on `name` leave it. They add no content, so the join
      # never sees them as sites, and a seed read before `widen_after_block` is still the closed shape whose known
      # values answer every missing key: `b = { a: 1 }; [1].each { b.default = 0; b[:c] = 2 }` read `b[:zz]` as
      # `1 | 2`, and so did an `each_with_object({})` memo given a default beside its stores, and a `while` body. The
      # block receives a read's `depth` and its enclosing block count, and says whether the read is the variable
      # `seed` describes. A `def` opens a scope of its own, so nothing under one is.
      def lookup_mutated_seed(body, name, seed)
        Source::NodeWalker.each_with_ancestors(body) do |node, ancestors|
          next unless node.is_a?(Prism::CallNode) && HashLookupMutation::MUTATORS.include?(node.name)
          next if ancestors.any?(Prism::DefNode)

          receiver = node.receiver
          next unless receiver.is_a?(Prism::LocalVariableReadNode) && receiver.name == name
          next unless yield(receiver.depth, scope_nesting(ancestors))

          seed = MutationWidening.widen_for_mutator(seed, node.name) || seed
        end
        seed
      end

      # The memo's joined carrier. The captured collections the block content-mutates join alongside it, and only the
      # memo's carrier is kept: a memo store reading one of them (`buf << w; m << buf.length`) must see it as it
      # stands at any iteration's entry, not at its pre-call contents. Their own continuation is the block seam's to
      # write.
      def join_memo_content(call_node, memo_param, calls, pre_state, shadows)
        block = call_node.block
        captured = captured_content_mutations(block, shadows)
        seeds = captured.keys.to_h { |name| [name, scope.local(name)] }
        seeds[memo_param] = pre_state
        sites = captured.merge(memo_param => calls)
        shadow_rebound_reads(block, sites, seeds, shadows)
        join_content_to_fixpoint(sites, seeds, build_block_entry_scope(call_node, block), shadows)[memo_param]
      end

      # The name of the memo block parameter (the SECOND positional param of an `each_with_object` block), or nil when
      # the block does not bind a second positional param.
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

      # Content-mutator calls on the block-local `var_name` within `body` — directly, or from a nested block that
      # reaches it by exactly the scopes it is nested in. A nested block's own parameter of the same name is a
      # different variable and does not count.
      def body_content_mutations_on(body, var_name, shadows)
        calls = []
        Source::NodeWalker.each_with_ancestors(body) do |descendant, ancestors|
          next unless descendant.is_a?(Prism::CallNode)
          next unless CONTENT_MUTATORS.include?(descendant.name)

          receiver = descendant.receiver
          next unless receiver.is_a?(Prism::LocalVariableReadNode)
          next unless receiver.name == var_name && receiver.depth == scope_nesting(ancestors)

          calls << descendant
          record_shadows(shadows, descendant, ancestors)
        end
        calls
      end

      # Joins content evidence for a memo / param given its pre-state and a list of mutator calls, dispatching Array vs
      # Hash by the PRE-STATE's own evidence. The mutator set never picks the arm on its own: `[]=` is legal on Array,
      # Hash, and countless index-writable classes, so an index-write against a receiver the engine cannot shape must
      # not synthesize a hash carrier — mail's `compose_codepoints` mutated its untyped Array param through
      # integer/range index writes and returned `Hash[Integer | Range, …]` to its caller (issue #553). Dynamic in,
      # Dynamic out: a shapeless pre-state falls through to `join_array_param`, which declines it.
      def join_content_for_param(calls, pre_state, block_entry)
        return nil if pre_state.nil?
        return join_string_union(calls, pre_state, block_entry) if string_union?(pre_state)

        if stringish?(pre_state)
          # String carries no element parameter; mutating `<<`/`concat` makes the constant value unsound (`s = "a"; s <<
          # x` → runtime `"a…"`), so widen to the nominal base. Sound — only widens.
          Type::Combinator.nominal_of("String")
        elsif content_kind(pre_state) == :mixed
          ContentJoin.join_mixed_content(pre_state, *mixed_content_evidence(calls, block_entry))
        elsif hashish?(pre_state)
          join_hash_param(calls, pre_state, block_entry)
        else
          join_array_param(calls, pre_state, block_entry)
        end
      end

      # A union with a String member (`Array | String`, `String?`) joins member by member: the String members widen to
      # `String`, which has no element evidence to join, and the rest join as a union of their own. Joined whole, the
      # union reached the Array or Hash join, which dropped the String member and read a String mutator's arguments as
      # elements — `x.force_encoding(e)` on an `Array | String` capture typed it `Array[1 | Encoding]`.
      def join_string_union(calls, union, block_entry)
        join_string_members(union) { |others| join_content_for_param(calls, others, block_entry) }
      end

      # `String` for the String members of `union`, beside what the block answers for the rest (as a union of their
      # own), or the rest unchanged when the block answers nil.
      def join_string_members(union)
        rest = union.members.reject { |member| string_member?(member) }
        string = Type::Combinator.nominal_of("String")
        return string if rest.empty?

        others = Type::Combinator.union(*rest)
        Type::Combinator.union(string, yield(others) || others)
      end

      def string_union?(type)
        type.is_a?(Type::Union) && type.members.any? { |member| string_member?(member) }
      end

      def string_member?(type)
        UnknownStoreWidening.carrier_class(type) == "String"
      end

      def join_hash_param(calls, pre_state, block_entry)
        pairs = hash_pair_evidence(calls, block_entry)
        return nil if pairs.empty? && !hashish?(pre_state)

        ContentJoin.join_hash_content(pre_state, pairs)
      end

      def join_array_param(calls, pre_state, block_entry)
        return nil unless arrayish?(pre_state)

        ContentJoin.join_array_content(pre_state, array_element_evidence(calls, block_entry))
      end

      # No site sits under an inner block that shadows a name — the loop seam's answer, and the default.
      NO_SHADOWS = {}.freeze
      private_constant :NO_SHADOWS

      # The `[key, value]` pairs `calls` store into a Hash, typed in `block_entry`.
      def hash_pair_evidence(calls, block_entry, shadows = NO_SHADOWS)
        calls.flat_map { |c| hash_pair_types(c, site_evidence_scope(block_entry, c, shadows)) }
      end

      # The elements `calls` add to an Array, typed in `block_entry`.
      def array_element_evidence(calls, entry_scope, shadows = NO_SHADOWS)
        calls.flat_map do |c|
          block_entry = site_evidence_scope(entry_scope, c, shadows)
          # An index-write in the block (`a[i] += v`, `a[i] ||= v`, an index target) stores
          # through `[]=` the same way — emit its index arguments ahead of the node's own stored
          # type so the join classifies the same splice / element forms the straight-line path
          # does (issue #1140).
          next ContentJoin.array_added_elements(:[]=, index_write_block_arg_types(c, block_entry)) if index_write?(c)

          ContentJoin.array_added_elements(c.name, content_arg_types(c, block_entry))
        end
      end

      # `[index_type..., stored_value_type]` for an index-write node inside a block, typed in the
      # block-entry scope — the stored value is what the write stores through `[]=`, which for a
      # compound write is the dispatched compound result (`a[i] += v` stores `a[i] + v`, the same
      # compound result the node itself types as); an index target (a multi-assign slot, a `for`
      # index, a rescue reference) stays untyped.
      # `[]` when any type cannot be read, which reproduces the pre-join no-evidence answer.
      def index_write_block_arg_types(node, block_entry)
        args = node.arguments
        return [] if args.nil?

        stored = index_write_stored_type(node, block_entry)
        return [] if stored.nil?

        list = args.respond_to?(:arguments) ? args.arguments : args
        list.map { |a| a.is_a?(Prism::SplatNode) ? nil : block_entry.type_of(a, tracer: tracer) } + [stored]
      rescue StandardError
        []
      end

      # Walks the block body for content-mutator calls (`<<`, `push`, `[]=`, …) whose receiver is a captured outer local
      # (depth >= 1), returning `{ name => [call_node, ...] }`. Mirrors the `MutationWidening.widen_after_block` walk
      # (descends into nested blocks; the depth check keeps nested block-locals out).
      def collect_content_mutations(body)
        mutations = Hash.new { |h, k| h[k] = [] }
        Source::NodeWalker.each(body) do |descendant|
          name, node = content_mutation_target(descendant) { |r| r.is_a?(Prism::LocalVariableReadNode) && r.depth.positive? }
          mutations[name] << node unless name.nil?
        end
        mutations
      end

      # Index-write forms (`h[k] ||= v`, `h[k] += v`, and an index target's `h[k] = v` — a multi-assign slot, a `for`
      # index, a rescue reference) that mutate a collection's
      # CONTENT without a `[]=` CallNode. `h[k] ||= []; h[k] << v` mutates `h` through the OrWrite even though the
      # appended values land on the nested array — leaving `h` an empty `{}` is unsound (`h.empty?` folds to `true`).
      INDEX_WRITE_NODES = IndexWriteWidening::CONTENT_WRITE_NODE_CLASSES
      private_constant :INDEX_WRITE_NODES

      # Every call name a content scan counts: the adders the joins read evidence from, and the String mutators no
      # Array or Hash table lists. A String carries no element parameter, so a join answers a String pre-state with the
      # bare `String` whatever the name, and a floor floors it; without them `def strip(s) = s.delete_prefix!("a")` and
      # an escaping `-> { s.upcase! }` left the caller's `+"ab"` pinned. A name an Array or Hash table also lists stays
      # with those tables' adders: a scan cannot see the receiver's class, and the Array join reads a non-adder's
      # arguments as appended elements (`slice!(0)`'s index).
      CONTENT_MUTATORS = (ContentJoin::CONTENT_ADDERS |
                          (StringMutation::MUTATORS - MutationWidening::ARRAY_MUTATORS -
                           MutationWidening::HASH_MUTATORS)).freeze
      private_constant :CONTENT_MUTATORS

      # The shared "not a content mutation" answer. This predicate runs on every node of every block, loop and
      # method body it censuses (~950k calls on the lib self-check) and almost always declines, so a fresh
      # `[nil, nil]` per decline was one of the largest allocation sites in the evaluator.
      NO_CONTENT_MUTATION = [nil, nil].freeze
      private_constant :NO_CONTENT_MUTATION

      # `[receiver_name, node]` when `node` is a content mutation whose receiver is a local variable satisfying `accept`
      # (depth predicate), else the frozen `[nil, nil]`. Covers `[]=`-style CallNode mutators and the index-write node
      # forms.
      def content_mutation_target(node)
        is_call_mutator = node.is_a?(Prism::CallNode) && CONTENT_MUTATORS.include?(node.name)
        return NO_CONTENT_MUTATION unless is_call_mutator || index_write?(node)

        receiver = node.receiver
        return NO_CONTENT_MUTATION unless receiver.is_a?(Prism::LocalVariableReadNode)
        return NO_CONTENT_MUTATION unless yield(receiver)

        [receiver.name, node]
      end

      def index_write?(node)
        INDEX_WRITE_NODES.any? { |k| node.is_a?(k) }
      end

      # A `Difference` (`non-empty-array[T]`) counts as its base. The seams read their seed from before the mutation
      # widening ran, so they meet the refinement carrier where they used to meet the `Array[T]` it widens to;
      # declining it would leave the continuation on that widened base with every appended arm missing.
      def arrayish?(type)
        case type
        when Type::Tuple then true
        when Type::Nominal then type.class_name == "Array"
        when Type::Union then type.members.any? { |m| arrayish?(m) }
        when Type::Difference then arrayish?(type.base)
        else false
        end
      end

      def hashish?(type)
        case type
        when Type::HashShape then true
        when Type::Nominal then type.class_name == "Hash"
        when Type::Union then type.members.any? { |m| hashish?(m) }
        when Type::Difference then hashish?(type.base)
        else false
        end
      end

      def stringish?(type)
        (type.is_a?(Type::Constant) && type.value.is_a?(String)) ||
          (type.is_a?(Type::Nominal) && type.class_name == "String")
      end

      # `[key_type, value_type]` for a `h[k] = v` / `h.store(k, v)` call or an index-write node (`h[k] ||= v`), typed in
      # the block-entry scope. For an index-write the stored value is opaque (the appended values often land on a NESTED
      # collection via `h[k] << v`), so the value is floored to `untyped` — sound: it only ever widens the value param.
      # Returns `[]` for other forms.
      def hash_pair_types(node, block_entry)
        if index_write?(node)
          key = index_key_type(node, block_entry)
          return [] if key.nil?

          return [[key, Type::Combinator.untyped]]
        end

        # Only a Hash adder stores a pair; a String mutator a content scan counted (`x.sub!("a", "b")` on a
        # `Hash | String` capture) stores none.
        return [] unless ContentJoin::HASH_CONTENT_ADDERS.include?(node.name)

        args = content_arg_types(node, block_entry)
        return [] if args.size < 2

        # A splat index marker (`nil`) means unknown arity only to the Array classifier;
        # read as a key it is an unknown value — degrade to untyped (issue #1140).
        [[args.first || Type::Combinator.untyped, args.last]]
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

      # Argument types for a content-mutator call, typed against the block-entry scope (block params bound). A
      # sub-evaluator over `block_entry` keeps the argument typing flow-correct for params / `;`-locals without leaking
      # into the outer scope.
      def content_arg_types(call_node, block_entry, operand_types = nil)
        arguments = call_node.arguments
        return [] if arguments.nil?

        list = arguments.arguments
        list.map.with_index do |arg, i|
          # For `[]=` a splat in an index position leaves the store's arity open — it is
          # marked `nil` for {ContentJoin.array_added_elements}, which counts it as
          # arity-unknown rather than as the untyped index it would type as (issue #1140).
          next nil if call_node.name == :[]= && i < list.size - 1 && arg.is_a?(Prism::SplatNode)

          OperandWalk.type_of(block_entry, arg, tracer, operand_types)
        end
      rescue StandardError
        []
      end

      # Evaluates `block`'s body once with each written outer local or ivar bound to the supplied `bindings` (block
      # params / `;`-locals re-bound as usual) and returns the per-name exit binding for `names`. Used as the
      # `BodyFixpoint` body-evaluator.
      def block_exit_bindings(call_node, block, bindings, names)
        _type, exit_scope = sub_eval(block, block_pass_entry(call_node, block, bindings))
        names.to_h { |name| [name, CapturedLocals.bound_type(exit_scope, name)] }
      end

      # The entry scope of one write-back pass: the block's entry with each written outer local or ivar bound to
      # `bindings`.
      def block_pass_entry(call_node, block, bindings)
        entry = build_block_entry_scope(call_node, block)
        capture_pass_bindings(block, bindings).reduce(entry) { |acc, (name, type)| bind_capture(acc, name, type) }
      end

      # `bindings` plus the pass binding of every captured local the body mutates in place
      # ({CapturedLocals.content_mutations}): its binding widened for a store of UNKNOWN values at every mutation site
      # ({#unknown_store_binding}), so it holds whatever any earlier iteration stored. A name the pass does not move
      # is widened from its call-site binding; a name it moves (the body both rebinds and mutates it) is widened over
      # the running assumption, as the per-element fold widens the same name (#587 (b)) — that assumption carries the
      # exits of the body's straight-line seam, which can close the collection without a gradual arm
      # (`stack ||= [0]; top = stack.pop; stack.push(x)` kept `top` at `0?`). The stored values are not typed: one
      # computed from the collection's own entry contents is the same first-iteration answer. `bindings` itself
      # comes back for the common body that mutates nothing captured.
      #
      # The price is the gradual arm on a rebind that reads such a collection — `last = a.last; a << x` over `a =
      # [0]` reads `0 | Dynamic[top] | nil`, not `0 | 1 | 2 | nil`. Precise evidence would mean iterating this
      # fixpoint jointly with slice C's content join; ADR-56 WD2.13 records why that was not taken.
      def capture_pass_bindings(block, bindings)
        stores = block_content_mutations(block)
        return bindings if stores.empty?

        widened = stores.each_with_object({}) do |(name, sites), acc|
          next if bindings.key?(name)

          seed = scope.local(name)
          acc[name] = unknown_store_binding(seed, sites) unless seed.nil?
        end
        widened.merge(bindings.to_h do |name, type|
          sites = stores[name]
          [name, sites.nil? || type.nil? ? type : unknown_store_binding(type, sites)]
        end)
      end

      # {CapturedLocals.content_mutations} of `block` against this evaluator's scope, once per block: every write-back
      # pass asks, and neither input changes between them.
      def block_content_mutations(block)
        (@block_content_mutations ||= {}.compare_by_identity)[block] ||= CapturedLocals.content_mutations(block, scope)
      end

      # `type` widened through `sites` for a store of unknown values, with one more step: when the result is still a
      # collection whose contents are value-pinned, those pins are the first-iteration answer and the contents take
      # the gradual arm. A widening that DECLINES leaves such a binding — `s = [0, 9]; s.pop` leaves `Array[0 | 9]`,
      # a nominal the `push` in the body then declines — and so does one that only changes a refinement: under `if
      # s.any?` the `pop` drops `non-empty-array[0 | 9]` to that same pinned `Array[0 | 9]` before the `push` declines
      # it. Either way `top = s.last; s.push(x)` would keep `top` at `0 | 9`. A result that already carries the arm
      # is unchanged by it.
      def unknown_store_binding(type, sites)
        widened = UnknownStoreWidening.widen(type, sites)
        return widened unless UnknownStoreWidening.value_pinned_collection?(widened)

        UnknownStoreWidening.gradual_content(widened)
      end

      # `Prism::BlockNode` is reached through {#eval_call}; the handler runs the body under `scope`, which the caller
      # has already augmented with the block's parameter bindings. Effects do not leak past the block (the outer
      # eval_call returns the caller's scope unchanged), but the body's local writes are threaded through subsequent
      # statements *inside* the block so `each { |x| sum = x; sum.succ }` types `sum.succ` under the `sum: x` binding.
      # The scope returned is the one the invocation ENDS with — the fall-through joined with every `next` that
      # leaves it ({#evaluate_invocation}).
      def eval_block(node)
        type, _fall_through, exit_scope = evaluate_invocation(node)
        [type, exit_scope]
      end

      # `base` joined with every collected jump scope whose node is in `targets` — a jump belonging to a nested
      # construct lands in the same sink and is dropped by identity.
      def join_jump_scopes(base, sink, targets)
        targeted_scopes(sink, targets).reduce(base) { |acc, jump_scope| acc.join(jump_scope) }
      end

      # The scopes a sink collected at the jumps in `targets`.
      def targeted_scopes(sink, targets)
        sink.filter_map { |node, jump_scope| jump_scope if targets.key?(node) }
      end

      # Issue #878 — `->() { }` and `lambda { }` build the same object, so they MUST type the same. The `lambda`
      # spelling is an ordinary call carrying a `Prism::BlockNode` and reaches {#eval_call}; the `->` spelling is a
      # node of its own, and without an entry here it was only ever typed as an expression (`Proc`) with its body left
      # un-evaluated. The body's reads and literals still reported — the rule walker falls back to the enclosing
      # method's scope — but a write made INSIDE the body joined no scope, so every later read in the body kept the
      # pre-write type.
      #
      # The body is run under the same entry scope `lambda { }` gets ({#build_block_entry_scope}, which binds the
      # parameters and enters `self` opaque), and the continuation gets the same escaping-closure treatment: a lambda
      # literal is a value that outlives the expression, exactly like the Proc `lambda` returns, so the outer locals it
      # can rebind lose their narrowing rather than being written back through ADR-56's non-escaping fixpoint. Both
      # halves are widenings — the two spellings now agree in both directions instead of `->` being the precise one.
      # A lambda is a return barrier: `return` inside it returns from the lambda, so its body runs with the method's
      # return sink suspended, as a nested `def` body does ({#eval_def}). Issue #1223 made the barrier matter more
      # often: a lambda passed as an argument (`register(-> { return :skip if … })`) is now evaluated with its
      # enclosing call's operands, where it used to be typed as a value only.
      def eval_lambda(node)
        lambda_type = scope.type_of(node, tracer: tracer)
        without_return_sink { sub_eval(node.body, build_block_entry_scope(nil, node)) } unless node.body.nil?

        [lambda_type, escaping_closure_captures(node, scope)]
      end

      # The continuation effects of an escaping closure body: the outer locals it can rebind drop their narrowing, and
      # the ones it content-mutates are floored. Shared by the two spellings — a block on an escaping call
      # ({#record_closure_escape_if_any}) and a lambda literal ({#eval_lambda}) — so they cannot drift.
      def escaping_closure_captures(closure_node, post_scope)
        widen_escaping_content_captures(closure_node, drop_captured_narrowing(closure_node, post_scope))
      end

      # Builds the entry scope for a block body. The block sees the outer scope's locals (Ruby's lexical scoping rule)
      # and adds bindings for every named block parameter on top. Parameter types come from the receiving method's RBS
      # signature when one is available; the rest default to `Dynamic[Top]`.
      #
      # `;`-prefixed block-locals (`do |i; x|`) are bound to `Constant[nil]` so the inner read shadows any outer `x` per
      # Ruby's semantics — at runtime the block-local is a fresh nil-valued variable on every block invocation. Without
      # this shadow, an inner `x.even?` before the first write would type-check against the OUTER `x` (e.g. `Integer`)
      # when the runtime would actually `NoMethodError` on `nil`.
      def build_block_entry_scope(call_node, block_node)
        expected = expected_block_param_types_for(call_node)
        # Issue #316 — every block body enters with `self` unmodelled (`Scope#entering_opaque_block`); the
        # yielding method, not the lexical context, decides what `self` is, and Rigor does not track it.
        # Issue #1358 — a body that may run a match reads the match globals an earlier iteration may have rebound
        # ({MatchRebinding.block_entry}).
        entry = MatchRebinding.block_entry(scope.entering_opaque_block, block_node, call_node)
        scope_with_params = BlockParameterBinder.new(expected_param_types: expected).bind_onto(block_node, entry)
        # ADR-16 Tier A — a plugin `block_as_methods:` entry that matches `(receiver, name)` narrows the
        # body's `self` to the object the DSL `instance_eval`s the block on (`params` on
        # `Grape::Validations::ParamsScope`, `namespace` on the `Grape::API::Instance` class object, verb
        # bodies on `Grape::Endpoint`). The expression-side narrowing
        # ({ExpressionTyper#block_body_self_narrowing}) already applies the same contract to block-return
        # typing; without it here the recorded per-node scopes — what `dump_type`/`assert_type` and the
        # survey read — keep the enclosing `self_type` and every DSL call inside stays `Dynamic[top]`.
        narrowed = call_node && narrow_macro_block_self(call_node)
        scope_with_params = scope_with_params.with_self_type(narrowed) if narrowed
        block_local_names(block_node).reduce(scope_with_params) do |acc, name|
          acc.with_local(name, Type::Combinator.constant_of(nil))
        end
      end

      # The receiver an ADR-16 `block_as_methods:` match is keyed on: the explicit receiver's type, or the
      # current `self_type` for an implicit-self DSL call (the `params do` / `namespace do` shapes, whose
      # receiver is the enclosing `Singleton[X]`). A miss leaves the entry scope as built — the false-
      # positive-safe direction.
      def narrow_macro_block_self(call_node)
        receiver_type =
          if call_node.receiver
            type_operand(call_node.receiver)
          else
            scope.self_type
          end
        return nil if receiver_type.nil?

        MacroBlockSelfType.narrow_self_type_for(
          scope: scope, call_node: call_node, receiver_type: receiver_type
        )
      rescue StandardError
        nil
      end

      def block_local_names(block_node)
        params_root = block_node.parameters
        return [] unless params_root.is_a?(Prism::BlockParametersNode)

        params_root.locals.map(&:name)
      end

      # A lambda literal has no receiving method, so it passes no call node and every parameter defaults to
      # `Dynamic[Top]` — the same answer `lambda { |y| }` gets, where the implicit-self receiver yields no signature.
      def expected_block_param_types_for(call_node)
        return [] if call_node.nil?

        receiver_type =
          if call_node.receiver
            type_operand(call_node.receiver)
          else
            scope.self_type || scope.environment.nominal_for_name("Object")
          end
        return [] if receiver_type.nil?

        arg_types = call_arg_types_for(call_node)
        MethodDispatcher.expected_block_param_types(
          receiver_type: receiver_type,
          method_name: call_node.name,
          arg_types: arg_types,
          environment: scope.environment,
          scope: scope
        )
      rescue StandardError
        []
      end

      def call_arg_types_for(call_node)
        arguments = call_node.arguments
        return [] if arguments.nil?

        arguments.arguments.map { |arg| type_operand(arg) }
      end

      # ----- def/class helpers -----

      def eval_class_body(node, new_context, new_nesting = @lexical_nesting)
        return [Type::Combinator.constant_of(nil), scope] if node.body.nil?

        # Class/module bodies run in a fresh scope: the outer scope's locals are NOT visible inside `class Foo; ...
        # end`. We keep the same Environment so RBS lookups continue to work, and simply drop the locals. Slice
        # A-engine: `self` inside a class body is the class object itself, so we set `self_type` to
        # `Singleton[<qualified>]`.
        fresh = build_fresh_body_scope
        body_self = self_type_for_class_body(new_context)
        fresh = fresh.with_self_type(body_self) if body_self
        # Issue #963 — `self` in a `class << ...` body is the SINGLETON class, which shares the `Singleton[X]`
        # carrier a `class X` body gets. The mark is the only thing that tells the two apart downstream, and a
        # `def` reached from this body clears it by starting from a fresh scope.
        fresh = fresh.with_singleton_class_body(node.is_a?(Prism::SingletonClassNode))
        fresh = fresh.with_match_frame(node.body)
        fresh = stamp_nesting(fresh, new_nesting)
        sub_eval(node.body, fresh, class_context: new_context, lexical_nesting: new_nesting)
      end

      def build_method_entry_scope(def_node) # rubocop:disable Metrics/AbcSize
        singleton = singleton_def?(def_node)
        binder = MethodParameterBinder.new(
          environment: scope.environment,
          class_path: current_class_path,
          singleton: singleton,
          source_path: scope.source_path
        )
        bindings = binder.bind(def_node)
        # ADR-67 WD3 — override an undeclared parameter with its call-site inferred type (precision-additive; an
        # RBS-declared parameter wins, the table is empty on a normal `check` run). The inferred type lives only as a
        # body local, never as an RBS contract, so it cannot fire a parameter-boundary diagnostic (WD1, satisfied by
        # construction). WD6b — the second element is the set of parameters this seed overrode, stamped with
        # the "inferred, not declared" provenance mark at bind time so the in-body rules can decline on them.
        seeded = seed_inferred_param_types(bindings, def_node, singleton)
        bindings = seeded.fetch(0)
        inferred_names = seeded.fetch(1)

        # Method bodies do NOT see the outer scope's locals. They start from a fresh scope with the same environment,
        # then receive the parameter bindings. Slice 7 phase 2: instance defs ALSO seed their `ivars` map from the
        # class-level accumulator so `def get; @x; end` reads the type that a sibling `def init; @x = 1; end` wrote.
        fresh = build_fresh_body_scope
        body_self = self_type_for_method_body(singleton: singleton)
        fresh = fresh.with_self_type(body_self) if body_self
        # A `def` opens no new `Module.nesting` entry — the body resolves constants against the chain of the
        # declaration that encloses it, which is what the evaluator is already carrying (#652).
        fresh = stamp_nesting(fresh, @lexical_nesting)
        fresh = seed_instance_ivars(fresh, singleton: singleton)
        fresh = seed_class_cvars(fresh)
        fresh = seed_program_globals(fresh)
        # Issue #1358 — the body runs in a frame of its own, whose match globals its blocks and closures share, and
        # so do its parameters' default expressions.
        fresh = fresh.with_match_frame(def_node.body, def_node.parameters)
        # ADR-48 Struct slice 3 — install the method body's fold-safe-local set so a member read off a mutation-free
        # local folds during the in-body walk (the call-return inference path is seeded separately).
        fresh = fresh.with_struct_fold_safe(
          StructFoldSafety.fold_safe_locals(
            def_node.body, ->(name) { scope.struct_member_layout(name)&.[](:members) }
          )
        )
        bindings.reduce(fresh) { |acc, (name, type)| bind_param(acc, name, type, inferred_names) }
      end

      # ADR-82 root-enrichment — bind a method parameter, and for an *undeclared* (untyped) parameter seed its
      # provenance to `inferred_return_untyped`. An untyped param is the archetypal inference gap ([ADR-67](
      # docs/adr/67-parameter-type-inference.md): no call-site type flows in), so a `x.foo` receiver on it should
      # route to parameter inference rather than reporting no cause at all. Reuses the WD1 `local_origins`
      # channel, so WD6 then carries the cause through any chain rooted at the parameter (`x.foo.bar`). An
      # RBS-declared / call-site-inferred parameter (a non-untyped binding) keeps no origin — it is not a hole.
      #
      # ADR-67 WD6b — a parameter the call-site inference seed overrode (`inferred_names`) is stamped with the
      # "inferred, not declared" provenance mark instead: its type is a concrete (non-untyped) lower bound, so it
      # is not an `inferred_return_untyped` hole, but the negative in-body rules must still decline on it (the
      # union is open, so firing is an FP by construction). The mark drops on any flow-live rewrite of the local.
      def bind_param(acc, name, type, inferred_names = nil)
        bound = acc.with_local(name, type)
        return bound.with_inferred_param_mark(name) if inferred_names&.include?(name)
        return bound unless untyped_binding?(type)

        bound.with_local_origin(name, DynamicOrigin::INFERRED_RETURN_UNTYPED)
      end

      # ADR-67 WD3 — consult the call-site parameter-inference table for this `def` and replace each undeclared
      # (untyped) parameter binding with its inferred type. Keyed by `[class_name, method_name, kind]`, reconstructed
      # from the lexical class path — the same triple {Inference::ParameterInferenceCollector} records. An RBS-declared
      # parameter (a non-untyped binding) always wins. No-op when the table is empty (the normal `check` path), so the
      # seed is byte-identical there.
      def seed_inferred_param_types(bindings, def_node, singleton)
        inferred = scope.param_inferred_types
        return [bindings, nil] if inferred.empty?

        path = current_class_path
        return [bindings, nil] if path.nil?

        table = inferred[[path, def_node.name, singleton ? :singleton : :instance]]
        return [bindings, nil] if table.nil? || table.empty?

        merged = bindings.dup
        overridden = nil
        table.each do |name, type|
          next unless merged.key?(name) && untyped_binding?(merged[name])

          merged[name] = type
          (overridden ||= Set.new) << name
        end
        [merged, overridden]
      end

      # True for the `Dynamic[Top]` carrier `MethodParameterBinder` leaves on an undeclared parameter — the only
      # bindings ADR-67 WD3 overrides.
      def untyped_binding?(type)
        type.is_a?(Type::Dynamic) && type.static_facet.is_a?(Type::Top)
      end

      def seed_instance_ivars(body_scope, singleton:)
        return body_scope if singleton

        path = current_class_path
        return body_scope if path.nil?

        seeded = scope.class_ivars_for(path)
        return body_scope if seeded.empty?

        # ADR-58 WD1 — the class-ivar index unions every `@x = …` write across the class flow-insensitively, so a ctor
        # `@x = nil` seed makes a read in a *different* method type `T | nil`. That `nil` is declaration-sourced, not
        # flow-live, so `seed_declaration_sourced_ivar` marks each seeded ivar: `possible-nil-receiver` then declines to
        # fire on the cross-method invariant unless a method-local write or narrowing makes the nil flow-live (which
        # drops the mark).
        #
        # Issue #667 — the same seed carries the published-constant mark for the ivars the class-ivar census
        # found assigned straight from a foreign published constant, so `@mode == :production` in a sibling
        # method withholds `flow.always-truthy-condition` the way the direct read of the constant does.
        marked = scope.published_constant_ivars_for(path)
        seeded.reduce(body_scope) do |acc, (name, type)|
          stamped = acc.seed_declaration_sourced_ivar(name, type)
          marked.include?(name) ? stamped.with_published_constant_mark(:ivar, name) : stamped
        end
      end

      # Cvars are visible from BOTH instance and singleton method bodies of the enclosing class, so this seed is
      # unconditional (no `singleton:` gate). At the top-level (no class context) the accumulator is empty and the seed
      # is a no-op.
      def seed_class_cvars(body_scope)
        path = current_class_path
        return body_scope if path.nil?

        seeded = scope.class_cvars_for(path)
        return body_scope if seeded.empty?

        seeded.reduce(body_scope) { |acc, (name, type)| acc.with_cvar(name, type) }
      end

      # Globals are process-wide. The body scope already inherited the program-globals accumulator through
      # `with_program_globals`; seeding here just materialises each entry into the body's `globals` map so reads observe
      # a precise type without consulting the accumulator on every lookup.
      def seed_program_globals(body_scope)
        seeded = scope.program_globals
        return body_scope if seeded.empty?

        seeded.reduce(body_scope) { |acc, (name, type)| acc.with_global(name, type) }
      end

      # Slice A-declarations. Class- and method-bodies start from a fresh local-empty scope, but they MUST keep the
      # `declared_types` table visible at the outer scope so the ScopeIndexer-populated declaration overrides
      # (`Prism::ConstantReadNode` for `module Foo` headers, etc.) remain reachable from inside nested bodies.
      def build_fresh_body_scope
        # Single allocation instead of a deep `with_*` chain — this runs per class/method body on the main walk, so the
        # chain's throwaway intermediate Scopes were a top `Scope#rebuild` source (ADR-44). Local-empty by design; the
        # discovery index is inherited whole by reference (ADR-53 Track A), so a table added to the index can no longer
        # be dropped here by a missed per-field copy.
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

      # `def Foo.bar` inside `module Foo` (or `def Meta.init` inside `module Meta`) — explicit-receiver def that
      # semantically equals `def self.bar` because the receiver constant resolves to `self` at the def-site. Matched
      # against the current class context's tail to cover both the `def OpenURI.x` form (single segment) and the `def
      # OpenURI::Meta.x` form (qualified path). Cross-class receivers (`def Bar.baz` inside `module Foo` where the
      # receiver names a different constant) are not promoted to singleton at this slice.
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

      # Slice A-engine. Inside a class body `class Foo; ...; end`, `self` is the class object — `Singleton[Foo]`.
      # Returns nil at the top level (no enclosing class).
      def self_type_for_class_body(class_context)
        return nil if class_context.empty?

        Type::Combinator.singleton_of(class_context.map(&:name).join("::"))
      end

      # Slice A-engine. Inside a method body, `self` depends on whether the def is on the singleton or instance side of
      # the surrounding class:
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

          # `class << Foo` inside `class Foo` (the canonical pattern in Ruby's own time.rb) is semantically `class <<
          # self` — replace the enclosing frame with a singleton frame for the same name so method registration and
          # `self_type` lookup land on Foo. When the target names a different constant (rare cross-class form), append a
          # fresh singleton frame tagged with the target FQN; the bodies are scoped to that target rather than to the
          # lexical enclosing class.
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

      # Stamps a recorded chain onto a body-entry scope. An empty chain (a top-level body) and an unknown one
      # are both left unstamped, so `Reflection.lexical_nesting_chain` keeps its peel fallback for them.
      def stamp_nesting(body_scope, chain)
        return body_scope if chain.nil? || chain.empty?

        body_scope.with_lexical_nesting(chain)
      end

      # The qualified name of the immediately-enclosing class (joining every nested `ClassFrame` with `::`). Returns
      # `nil` for a top-level def with no enclosing class, which routes the parameter binder past RBS lookup.
      def current_class_path
        return nil if @class_context.empty?

        @class_context.map(&:name).join("::")
      end

      def current_frame_singleton?
        @class_context.last&.singleton == true
      end

      # ----- helpers -----

      # Explicit `return value` (including `return` inside a block, which in Ruby returns from the *enclosing method*).
      # The control-transfer value is `Bot` — a `return` produces no value at its own position — but the returned
      # expression's type is recorded into the active return sink so the method-return inference joins it with the
      # body's tail type. Returns inside a nested `def`/lambda are barriers: `eval_def` clears the sink around the
      # nested body, so this handler only ever appends a return that genuinely exits the method currently being
      # inferred.
      def eval_return(node)
        sink = Thread.current[RETURN_SINK_KEY]
        sink << jump_value_type(node) if sink
        [Type::Combinator.bot, scope]
      end

      # `next value` ends the current block invocation and makes `value` that invocation's result. Structurally the same
      # story as {#eval_return} one level down: the control-transfer value is `Bot`, and the escaping value is recorded
      # into the active `next` sink so `ExpressionTyper#type_block_body` joins it with the body's fall-through tail
      # (issue #841). The node itself is recorded alongside the type because the sink also collects `next`s belonging to
      # a nested block / loop / def; the consumer filters by identity.
      #
      # A `next` on a provably dead branch is never reached by the evaluator at all (`eval_if` / `eval_unless` skip the
      # dead arm), so the join is flow-sensitive for free: `[1, 2].map { |x| next nil if x.nil?; x.to_s }` keeps its
      # exact per-element answer.
      def eval_next(node)
        sink = Thread.current[NEXT_SINK_KEY]
        sink << [node, jump_value_type(node)] if sink
        @next_scope_sink << [node, jump_scope(node)] if @next_scope_sink
        [Type::Combinator.bot, scope]
      end

      # The scope control leaves with at a `next` / `break`: the entry scope threaded through the jump's arguments, so a
      # write inside one (`next(n = :odd)`, `break(flag = true)`) is part of the path that leaves. The arguments are
      # evaluated without recording into the per-node scope index: whether a sink is collecting depends on unrelated
      # context (a captured write elsewhere in the block), and the index must not change with it.
      def jump_scope(node)
        args = node.arguments&.arguments || []
        args.reduce(scope) { |acc, arg| sub_eval(arg, acc, **UNRECORDED).last }
      end

      # A `break` transfers control to the loop exit (its flow value is `Bot`, like `return`). It records the scope it
      # leaves with ({#jump_scope}) into the active break sink so the loop join can recover a `break`-path binding the
      # fall-through would drop (`flag = true; break` -> `flag` is `false | true` after the loop); ADR-56's block
      # write-back reads the same sink for a `break` that ends a yielding call ({#join_block_break_bindings}), and an
      # enclosing `begin … ensure` carries the recorded scope through its clause ({#carry_jumps_through_ensure}). nil
      # sink = a `break` reached outside either collection (top level, or an escaping block) — left to the existing
      # escaping-block / no-op handling.
      #
      # Issue #853: the value it carries out belongs to the yielding CALL, so it is recorded into the separate
      # break-value sink for `ExpressionTyper#call_dispatch_type_for` to union in. Both sinks are optional and
      # independent — a loop body collects scopes while an enclosing call collects values from the same walk.
      def eval_break(node)
        sink = Thread.current[BREAK_SINK_KEY]
        sink << [node, jump_scope(node)] if sink
        value_sink = Thread.current[BREAK_VALUE_SINK_KEY]
        value_sink << [node, jump_value_type(node)] if value_sink
        [Type::Combinator.bot, scope]
      end

      # The value a `return` / `next` / `break` carries out of the construct it leaves. A bare jump carries nil; a
      # single argument carries its own type; `return a, b, c` (and `next` / `break` alike) packs `[a, b, c]`, so the
      # corresponding Tuple is contributed element-by-element. The argument is evaluated under the entry scope and the
      # resulting scope discarded — control leaves here, so nothing the argument binds is observable downstream.
      def jump_value_type(node)
        args = node.arguments&.arguments || []
        return Type::Combinator.constant_of(nil) if args.empty?
        return sub_eval(args.first, scope).first if args.size == 1

        Type::Combinator.tuple_of(*args.map { |arg| sub_eval(arg, scope).first })
      end

      # `on_enter: nil` evaluates without recording into the per-node scope index — for a pass whose scopes are not
      # the ones the index should keep. `next_scope_sink:` is replaced only by {#evaluate_invocation} and
      # {#loop_iteration}.
      def sub_eval(node, with_scope, class_context: @class_context, lexical_nesting: @lexical_nesting,
                   on_enter: @on_enter, next_scope_sink: @next_scope_sink, operand_recorder: @operand_recorder)
        evaluator_at(with_scope, class_context: class_context, lexical_nesting: lexical_nesting, on_enter: on_enter,
                                 next_scope_sink: next_scope_sink, operand_recorder: operand_recorder).evaluate(node)
      end

      # An evaluator over `with_scope` that inherits everything else from this one. `operand_scope:` and
      # `operand_types:` are set only by {#invoke_from}, for the evaluator that runs a call from the scope its
      # operands left.
      def evaluator_at(with_scope, class_context: @class_context, lexical_nesting: @lexical_nesting, # rubocop:disable Metrics/ParameterLists
                       on_enter: @on_enter, next_scope_sink: @next_scope_sink, operand_scope: nil,
                       in_operand: @in_operand, operand_recorder: @operand_recorder, operand_types: nil)
        StatementEvaluator.new(
          scope: with_scope,
          tracer: tracer,
          on_enter: on_enter,
          class_context: class_context,
          lexical_nesting: lexical_nesting,
          converged_loop_recording: @converged_loop_recording,
          next_scope_sink: next_scope_sink,
          operand_scope: operand_scope,
          in_operand: in_operand,
          operand_recorder: operand_recorder,
          operand_types: operand_types
        )
      end

      # Slice 7 phase 14 — branch exit detection. Returns true when the branch's body unconditionally exits the
      # surrounding control flow through a `return`, `next`, `break`, or `raise`. Used by `eval_if` / `eval_unless` to
      # narrow the post-scope: when one branch exits, the surrounding scope can carry the OTHER branch's edge forward
      # without nil-injection.
      #
      # The detection is intentionally conservative — it recognises only the most common patterns:
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

      # ADR-24 WD6 / slice 3 — generalised terminating-branch detection. `branch_unconditionally_exits?` recognises a
      # branch SYNTACTICALLY (return / next / break / a call named raise / throw / exit / abort / fail). A branch whose
      # *inferred type is `Bot`* also terminates — it cannot produce a value, so control never falls through it —
      # regardless of how it is spelled. The canonical case is a resolved guard helper (`fail_with_message(...)`) whose
      # body always raises: ADR-24 slice 1 types the call `bot`, and this OR-test makes `helper(...) if x.nil?` narrow
      # exactly like `raise ... if x.nil?`. The branch type is already computed by `eval_if` / `eval_unless`.
      def branch_terminates?(branch_node, branch_type)
        branch_unconditionally_exits?(branch_node) ||
          branch_type.is_a?(Type::Bot)
      end

      def eval_branch_or_nil(branch_node, branch_scope, on_enter: @on_enter)
        return [Type::Combinator.constant_of(nil), branch_scope] if branch_node.nil?

        sub_eval(branch_node, branch_scope, on_enter: on_enter)
      end

      # Joins two branch scopes at a control-flow merge point. Names bound in only one branch are nil-injected into the
      # other side so the joined scope sees them as `T | nil` rather than dropping them outright. This implements the
      # contract the Slice 3 phase 1 `Scope#join` documentation defers to the statement-level evaluator.
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

      # Generalises {#join_with_nil_injection} to N branches (case/when, begin/rescue chain). The reduce order does not
      # affect the result because nil-injection commutes with union under `Scope#join`.
      def reduce_scopes_with_nil_injection(scopes)
        scopes.reduce { |a, b| join_with_nil_injection(a, b) }
      end

      # --------------------------------------------------------------- rescue variable binding helpers
      # ---------------------------------------------------------------

      # Returns `scope` extended with the rescue reference variable bound to the exception instance type. Leaves scope
      # unchanged when the node carries no reference (bare `rescue` without `=> var`). An index-target reference
      # (`rescue => h[:e]`) stores the exception through `[]=` instead, so its receiver widens with the exception
      # instance type as the stored value, exactly as `rescue => e; h[:e] = e` widens it.
      def bind_rescue_reference(rescue_node, scope)
        ref = rescue_node.reference
        case ref
        when Prism::LocalVariableTargetNode
          scope.with_local(ref.name, rescue_exception_type(rescue_node, scope))
        when Prism::IndexTargetNode
          widen_index_target(ref, rescue_exception_type(rescue_node, scope), scope, type_scope: scope)
        else
          scope
        end
      end

      # Derives the exception instance type for a `RescueNode`. When the exceptions list is empty (bare `rescue`) the
      # type is `StandardError`. When one or more exception classes are named the types are unioned. A class that
      # cannot be resolved to a `Singleton` type contributes `Dynamic[top]`.
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

      # --------------------------------------------------------------- `case/in` pattern variable binding helpers
      # ---------------------------------------------------------------

      # Builds the entry scope for an `in` branch by injecting every variable captured by the pattern as a local
      # binding. `subject_type` is the type of the `case` subject — nil when the `case` carries no predicate, which
      # leaves every binding at the `Dynamic[top]` floor — and `subject_node` the subject expression, which the
      # `deconstruct` / `deconstruct_keys` dispatch reads for its freshness gate.
      def apply_in_pattern_bindings(subject_type, subject_node, pattern, scope)
        bindings = collect_in_pattern_bindings(subject_type, pattern, scope, subject_node: subject_node)
        bindings.reduce(scope) { |s, (name, type)| s.with_local(name, type) }
      end

      # Returns an array of `[Symbol, Rigor::Type]` pairs for every variable captured by `pattern`, typed against the
      # subject. Unrecognised pattern nodes contribute no bindings (fail-soft).
      #
      # A union subject distributes first (see {#collect_union_pattern_bindings}); every other subject walks the
      # pattern once, and each node kind decides how much of the subject it can name:
      #
      # - a bare target (`in [i, s]`, `in x`) binds the slot the enclosing pattern hands it,
      # - a capture (`Integer => i`, `[a, b] => whole`) binds its own constraint, and recurses into the captured
      #   pattern,
      # - an array / find / hash pattern decomposes the subject (see the three collectors below).
      def collect_in_pattern_bindings(subject_type, pattern, scope, subject_node: nil)
        if subject_type.is_a?(Type::Union)
          return collect_union_pattern_bindings(subject_type.members, pattern, scope, subject_node: subject_node)
        end

        case pattern
        when Prism::CapturePatternNode
          collect_capture_pattern_bindings(subject_type, pattern, scope)
        when Prism::LocalVariableTargetNode
          [[pattern.name, subject_type || Type::Combinator.untyped]]
        when Prism::ImplicitNode
          collect_in_pattern_bindings(subject_type, pattern.value, scope)
        when Prism::ArrayPatternNode
          collect_array_pattern_bindings(subject_type, pattern, scope, subject_node: subject_node)
        when Prism::FindPatternNode
          collect_find_pattern_bindings(subject_type, pattern, scope, subject_node: subject_node)
        when Prism::HashPatternNode
          collect_hash_pattern_bindings(subject_type, pattern, scope, subject_node: subject_node)
        when Prism::AlternationPatternNode
          collect_alternation_pattern_bindings(subject_type, pattern, scope)
        else
          []
        end
      end

      # `pattern => target` binds `target` to what the pattern matched AND every name the pattern itself binds:
      # `in [a, b] => whole` binds `a`, `b` and `whole`. The target's own type is the pattern's constraint when it
      # names a class (`Integer => i`), and the subject otherwise — a capture over any other pattern IS the subject
      # the pattern matched.
      def collect_capture_pattern_bindings(subject_type, pattern, scope)
        target = pattern.target
        inner = collect_in_pattern_bindings(subject_type, pattern.value, scope)
        return inner unless target.is_a?(Prism::LocalVariableTargetNode)

        [[target.name, capture_pattern_type(subject_type, pattern.value, scope)]] + inner
      end

      # `in [i, s]` / `in [a, *rest, z]` / `in Foo[a, b]`.
      def collect_array_pattern_bindings(subject_type, pattern, scope, subject_node:)
        subject_type = pattern_class_constraint(subject_type, pattern.constant, scope)
        fronts, rest_type, backs = pattern_slot_types(subject_type, pattern, scope, subject_node)
        bindings = pattern.requireds.each_with_index.flat_map do |elem, i|
          collect_in_pattern_bindings(fronts[i], elem, scope)
        end
        bindings += pattern.posts.each_with_index.flat_map do |elem, i|
          collect_in_pattern_bindings(backs[i], elem, scope)
        end
        append_array_splat_binding(bindings, pattern.rest, rest_type)
        bindings
      end

      # The per-slot types a positional pattern reads: the subject's own decomposition when it is a carrier
      # {MultiTargetBinder.decompose_slots} accepts (`Tuple`, `Array[T]`), else the `deconstruct` projection of a
      # subject that defines one (`Struct#deconstruct`, a `Data` instance, a class whose `deconstruct` names the
      # parts), else the `Dynamic[top]` floor per slot.
      def pattern_slot_types(subject_type, pattern, scope, subject_node)
        view = positional_pattern_view(subject_type, scope, subject_node)
        return floor_pattern_slots(pattern.requireds.size, pattern.posts.size, !pattern.rest.nil?) if view.nil?

        MultiTargetBinder.decompose_slots(
          view, front_count: pattern.requireds.size, back_count: pattern.posts.size,
                rest_present: !pattern.rest.nil?, scope: scope
        )
      end

      # The carrier a positional pattern decomposes: the subject itself when {MultiTargetBinder} already accepts it,
      # else what the subject's `deconstruct` answers with (a `Tuple` / `Array[T]` carrier), else nil.
      #
      # `subject_node` rides along as the dispatch's call node so the `Struct` fold's freshness gate can see the
      # receiver: `case Point.new(1, 2); in [x, y]` is a freshly materialised instance and folds, while a stored
      # binding that may have been mutated since does not (ADR-48).
      def positional_pattern_view(subject_type, scope, subject_node)
        return subject_type if subject_type.is_a?(Type::Tuple)
        return subject_type if MultiTargetBinder.array_element_type(subject_type)

        deconstruct_projection(subject_type, scope, subject_node)
      end

      # What `subject.deconstruct` answers with, when that is a carrier this binder decomposes; nil otherwise —
      # an absent method, or `Struct#deconstruct`'s RBS `Array[untyped]` for a class whose members are not known.
      def deconstruct_projection(subject_type, scope, subject_node)
        result = struct_instance_projection(subject_type, :deconstruct, scope, subject_node) ||
                 pattern_decomposition_dispatch(subject_type, :deconstruct, [], scope) ||
                 source_decomposition_projection(subject_type, :deconstruct, [], scope)
        return nil if result.nil?
        return result if result.is_a?(Type::Tuple) || MultiTargetBinder.array_element_type(result)

        nil
      end

      # The inferred return type of a project-defined `deconstruct` / `deconstruct_keys` (issue #1122). The
      # dispatcher answers nil for a class no RBS describes: the body-inference tier that would type
      # `subject.deconstruct` lives on `ExpressionTyper` and needs the call NODE a pattern does not have, so
      # this asks the scope's own entry point for the same answer a resolved call site gets (ADR-84 memo
      # included). nil when the project defines no such method, or when the body's answer is the gradual floor.
      def source_decomposition_projection(subject_type, method_name, arg_types, scope)
        return nil unless subject_type.is_a?(Type::Nominal)

        def_node = scope.discovered_def_nodes[subject_type.class_name]&.[](method_name)
        return nil if def_node.nil?

        result = scope.user_method_return(def_node, subject_type, arg_types)
        return nil if result.nil? || result.is_a?(Type::Dynamic) || result.is_a?(Type::Top)

        result
      end

      # A `StructInstance`'s own projection — `Tuple` of its member values for `deconstruct`, `HashShape` of
      # its members for `deconstruct_keys` — or nil when the subject is another carrier or the projection would
      # be unsound.
      #
      # The `Struct` fold's freshness gate cannot answer for a pattern through the dispatcher: it asks whether
      # the CALL's receiver was freshly materialised (`Point.new(1, 2).x`), while a pattern's subject node IS
      # that materialisation (`case Point.new(1, 2); in [x, y]`). The gate still applies — a `Struct` is
      # mutable, so a stored binding's member map may be stale (ADR-48) — so this asks it the pattern's own
      # question, with the subject expression as the materialisation. A `Data` instance needs none of this:
      # it is frozen, and the dispatcher already projects it (see `DataFolding`).
      def struct_instance_projection(subject_type, method_name, scope, subject_node)
        return nil unless subject_type.is_a?(Type::StructInstance)
        return nil unless MethodDispatcher::StructMaterialization.materialization_call?(subject_node, subject_type,
                                                                                        scope)

        case method_name
        when :deconstruct then Type::Combinator.tuple_of(*subject_type.members.values)
        when :deconstruct_keys then Type::Combinator.hash_shape_of(subject_type.members.dup)
        end
      end

      # `deconstruct` / `deconstruct_keys` on a subject carrier. A `Dynamic` / `Top` answer is the gradual floor
      # rather than a method's result, so it reads as "cannot ask" to every caller here.
      #
      # The subject node is deliberately NOT passed as the dispatch's `call_node`: the tiers read a call node's
      # receiver and arguments, and a pattern's subject is any expression at all — `StructFolding`'s freshness
      # gate dereferences `call_node.receiver`, which a local read or a literal does not answer. The one
      # freshness question a pattern needs (`case Point.new(1, 2)`) is asked by
      # {#struct_instance_projection} instead.
      def pattern_decomposition_dispatch(subject_type, method_name, args, scope)
        return nil if subject_type.nil?

        result = MethodDispatcher.dispatch(
          receiver_type: subject_type, method_name: method_name, arg_types: args,
          environment: scope.environment, scope: scope
        )
        return nil if result.is_a?(Type::Dynamic) || result.is_a?(Type::Top)

        result
      end

      # `in [*pre, m, *post]`. Ruby matches a find pattern's required elements at the EARLIEST position the
      # surrounding splats allow (the pre-splat is non-greedy: `[1, 2, 3] in [*pre, x, *post]` binds `pre = []`, `x =
      # 1`), but a required that does not match there slides right, so each required binds the union of every
      # position it could occupy and the surrounding splats bind an `Array` of the subject's element type.
      def collect_find_pattern_bindings(subject_type, pattern, scope, subject_node:)
        subject_type = pattern_class_constraint(subject_type, pattern.constant, scope)
        view = positional_pattern_view(subject_type, scope, subject_node)
        slots = find_pattern_slots(view, pattern.requireds.size)
        bindings = pattern.requireds.each_with_index.flat_map do |elem, i|
          collect_in_pattern_bindings(slots ? slots[i] : Type::Combinator.untyped, elem, scope)
        end
        surround = find_pattern_surround_type(view)
        [pattern.left, pattern.right].each { |splat| append_array_splat_binding(bindings, splat, surround) }
        bindings
      end

      # The type each of a find pattern's `count` requireds can see, or nil when the subject cannot supply that many
      # elements (the pattern cannot match).
      def find_pattern_slots(view, count)
        if view.is_a?(Type::Tuple)
          elements = view.elements
          return nil if elements.size < count

          return Array.new(count) { |i| Type::Combinator.union(*elements[i..(elements.size - count + i)]) }
        end

        element = view && MultiTargetBinder.array_element_type(view)
        element && Array.new(count) { element }
      end

      # `*pre` / `*post` capture the elements the requireds did not: `Array[T]` for an `Array[T]` subject, an `Array`
      # of the element union for a `Tuple`, `Array[untyped]` when the subject could not be decomposed.
      def find_pattern_surround_type(view)
        element = case view
                  when Type::Tuple then union_of_types(view.elements)
                  else view && MultiTargetBinder.array_element_type(view)
                  end
        Type::Combinator.nominal_of("Array", type_args: [element || Type::Combinator.untyped])
      end

      # `in {name: String => n}` / `in {name:, **rest}`. Each element reads the subject's value at its key through
      # the subject's `deconstruct_keys` projection; `**rest` binds the remaining entries.
      def collect_hash_pattern_bindings(subject_type, pattern, scope, subject_node:)
        subject_type = pattern_class_constraint(subject_type, pattern.constant, scope)
        view = hash_pattern_view(subject_type, scope, subject_node)
        bindings = pattern.elements.flat_map do |assoc|
          next [] unless assoc.is_a?(Prism::AssocNode) && assoc.value

          collect_in_pattern_bindings(hash_pattern_value_type(view, assoc.key), assoc.value, scope)
        end
        rest = pattern.rest
        if rest.is_a?(Prism::AssocSplatNode) && rest.value.is_a?(Prism::LocalVariableTargetNode)
          bindings << [rest.value.name, hash_pattern_rest_type(view)]
        end
        bindings
      end

      # The `Hash`-shaped view a hash pattern reads: the subject's `deconstruct_keys` answer, which is a `HashShape`
      # for a shape carrier or a `deconstruct_keys` body and `Hash[K, V]` for the RBS answer of a plain `Hash` — or
      # nil when the subject cannot be asked.
      def hash_pattern_view(subject_type, scope, subject_node)
        args = [Type::Combinator.constant_of(nil)]
        struct_instance_projection(subject_type, :deconstruct_keys, scope, subject_node) ||
          pattern_decomposition_dispatch(subject_type, :deconstruct_keys, args, scope) ||
          source_decomposition_projection(subject_type, :deconstruct_keys, args, scope)
      end

      # The value type the pattern's key reads out of the view: a `HashShape` answers per key, a `Hash[K, V]`
      # answers `V` for every key, and anything else — a key the AST does not pin (`in {"#{k}": v}`), a shape that
      # does not carry the key — answers the floor.
      def hash_pattern_value_type(view, key_node)
        key = hash_pattern_key(key_node)
        return Type::Combinator.untyped if key.nil?
        return view.pairs[key] || Type::Combinator.untyped if view.is_a?(Type::HashShape)

        hash_value_type(view) || Type::Combinator.untyped
      end

      # The key a hash pattern element names, or nil when the AST does not pin one (an interpolated or computed key).
      def hash_pattern_key(key_node)
        case key_node
        when Prism::SymbolNode then key_node.unescaped.to_sym
        when Prism::StringNode then key_node.unescaped
        end
      end

      # `{ key:, **rest }` binds `rest` to a Hash whose keys are Symbols (the only legal key shape for a hash pattern)
      # and whose values are the view's own value type — the entries the pattern named are a subset of it.
      def hash_pattern_rest_type(view)
        value = view.is_a?(Type::HashShape) ? union_of_types(view.pairs.values) : hash_value_type(view)
        Type::Combinator.nominal_of(
          "Hash",
          type_args: [Type::Combinator.nominal_of("Symbol"), value || Type::Combinator.untyped]
        )
      end

      # The `V` of a `Hash[K, V]`, or nil for a raw `Hash`, a non-`Hash` nominal, or a `Dynamic` / `Top` value.
      def hash_value_type(type)
        return nil unless type.is_a?(Type::Nominal) && type.class_name == "Hash" && type.type_args.size == 2

        value = type.type_args.last
        return nil if value.is_a?(Type::Dynamic) || value.is_a?(Type::Top)

        value
      end

      # The union of a list of types, ignoring the gradual floor (`Dynamic[top]` / `Top` carries nothing to union)
      # and answering nil when nothing is left.
      def union_of_types(types)
        known = types.reject { |type| type.is_a?(Type::Dynamic) || type.is_a?(Type::Top) }
        known.empty? ? nil : Type::Combinator.union(*known)
      end

      # `[..., *rest, ...]` / `[*pre, x, *post]` capture an Array of the unmatched elements. `rest_type` is the
      # enclosing decomposition's own rest (a `Tuple` of the middle elements for a tuple subject, `Array[T]` for an
      # `Array[T]`); without one — a subject that did not decompose — the rest is `Array[untyped]`.
      def append_array_splat_binding(bindings, splat, rest_type)
        return unless splat.is_a?(Prism::SplatNode)

        target = splat.expression
        return unless target.is_a?(Prism::LocalVariableTargetNode)

        bindings << [target.name, rest_type || Type::Combinator.nominal_of("Array", type_args: [Type::Combinator.untyped])]
      end

      # The `Dynamic[top]` floor per slot, for a subject no rule decomposes.
      def floor_pattern_slots(front_count, back_count, rest_present)
        [
          Array.new(front_count) { Type::Combinator.untyped },
          rest_present ? Type::Combinator.nominal_of("Array", type_args: [Type::Combinator.untyped]) : nil,
          Array.new(back_count) { Type::Combinator.untyped }
        ]
      end

      # The class a pattern's own constant asserts (`in Point[x, y]`, `in Foo{...}`), applied to the subject. An
      # opaque subject — `Dynamic` / `Top`, which no `is_a?`-style narrowing can refine — becomes `Nominal[C]`: the
      # pattern's `C === subject` test has just established the class, which is what lets a constrained pattern bind
      # off a subject whose own type named nothing. A subject whose class is already known keeps it.
      def pattern_class_constraint(subject_type, constant_node, scope)
        return subject_type if constant_node.nil?

        nominal = singleton_to_nominal(sub_eval(constant_node, scope).first)
        return subject_type unless opaque_pattern_subject?(subject_type)
        return subject_type if nominal.is_a?(Type::Dynamic) || nominal.is_a?(Type::Top)

        nominal
      end

      def opaque_pattern_subject?(subject_type)
        subject_type.nil? || subject_type.is_a?(Type::Dynamic) || subject_type.is_a?(Type::Top)
      end

      # Distributes a union subject over the pattern, the rule {MultiTargetBinder} applies to `a, b = union`: every
      # member walks the same pattern and each name binds the join of its per-member types, while a member that binds
      # `Dynamic[top]` floors the name for the whole union — a precise member must not stand for one nothing is known
      # about. A member that PROVABLY cannot match the pattern contributes nothing at all instead of flooring:
      # `case maybe; in [a, b]` over `Tuple[1, "a"] | nil` binds `1` / `"a"`, because a `nil` subject raises
      # `NoMatchingPatternError` rather than reaching the body.
      def collect_union_pattern_bindings(members, pattern, scope, subject_node: nil)
        reachable = members.reject { |member| pattern_match_impossible?(member, pattern, scope) }
        walks = (reachable.empty? ? [Type::Combinator.untyped] : reachable).map do |member|
          collect_in_pattern_bindings(member, pattern, scope, subject_node: subject_node)
        end
        merge_pattern_bindings(walks)
      end

      # Whether `type` provably cannot match `pattern`, so its arm contributes no binding. Only the two
      # decompositions a pattern asks for are checked — `deconstruct` (array / find patterns) and `deconstruct_keys`
      # (hash patterns) — and both only for a class the RBS environment knows, whose method set is closed, the same
      # rule `array_conversion_free?` applies to the multi-assign `to_ary` question (issue #1094). A carrier the
      # check cannot prove negative about (Dynamic, a source class, an unresolved constant) answers false, which
      # keeps the union at the conservative floor.
      def pattern_match_impossible?(type, pattern, scope)
        case pattern
        when Prism::ArrayPatternNode, Prism::FindPatternNode then !decomposable_as_array?(type, scope)
        when Prism::HashPatternNode then !decomposable_as_hash?(type, scope)
        when Prism::CapturePatternNode then pattern_match_impossible?(type, pattern.value, scope)
        else false
        end
      end

      def decomposable_as_array?(type, scope)
        return true unless pattern_decomposition_dispatch(type, :deconstruct, [], scope).nil?

        class_name = MultiTargetBinder.conversion_class_name(type)
        class_name.nil? || !MethodDispatcher::RbsDispatch.array_conversion_free?(class_name, scope)
      end

      def decomposable_as_hash?(type, scope)
        args = [Type::Combinator.constant_of(nil)]
        return true unless pattern_decomposition_dispatch(type, :deconstruct_keys, args, scope).nil?

        class_name = MultiTargetBinder.conversion_class_name(type)
        return true if class_name.nil? || scope.environment.nil?

        !Reflection.rbs_class_known?(class_name, environment: scope.environment)
      end

      # Joins per-member binding lists by name: `Dynamic[top]` from any walk — or a name a walk does not bind —
      # floors the name, otherwise the members union. The first walk's order is the declaration order.
      def merge_pattern_bindings(walks)
        floor = Type::Combinator.untyped
        walks.first.map do |name, _type|
          types = walks.map { |walk| walk.assoc(name)&.last }
          [name, types.any? { |type| type.nil? || type == floor } ? floor : Type::Combinator.union(*types)]
        end
      end

      # `expr in pattern` (a `MatchPredicateNode`, evaluating to a boolean) and `expr => pattern` (a
      # `MatchRequiredNode`, evaluating to `nil` and raising `NoMatchingPatternError` on a mismatch) — the one-line
      # pattern matches. Both bind every name the pattern captures into the post-scope, decomposed exactly as an `in`
      # branch of a `case` is, and WITHOUT the nil-injection a surrounding join would add: a name is read on the
      # truthy side only after the pattern matched it, which is the shape `if config in {timeout: Integer => t}`
      # depends on.
      def eval_match_pattern(node)
        subject_type, post_value = sub_eval(node.value, scope)
        bound = apply_in_pattern_bindings(subject_type, node.value, node.pattern, post_value)
        [scope.type_of(node, tracer: tracer), bound]
      end

      # --------------------------------------------------------------- named-capture regex binding (`MatchWriteNode`)
      # ---------------------------------------------------------------

      # `/(?<year>\d+)/ =~ str` — Prism emits a `MatchWriteNode` that wraps the `=~` call and lists the named-capture
      # targets. Each target is bound to `String | nil` (the capture is absent as nil when the pattern doesn't match or
      # the group didn't participate).
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

      # --------------------------------------------------------------- shared type conversion helper
      # ---------------------------------------------------------------

      # Converts a `Singleton[ClassName]` (the class object) to the corresponding `Nominal[ClassName]` (an instance).
      # Falls back to `untyped` for carriers that are not Singleton (e.g. Dynamic[Top] when the class could not be
      # resolved).
      def singleton_to_nominal(type)
        type.is_a?(Type::Singleton) ? Type::Combinator.nominal_of(type.class_name) : Type::Combinator.untyped
      end

      # Returns the type to bind for a `CapturePatternNode`'s target. A class reference (`Integer => x`, and every
      # alternate of `Integer | String => x`) answers the constraint's `Nominal[T]` — the pattern's own `T ===
      # subject` test is what licenses the binding even when the subject's type is opaque. A value pattern (`1 => x`)
      # answers the literal's own type. A capture over any other pattern (`[a, b] => whole`, `^(x) => y`) answers the
      # subject, which is what that pattern matched.
      def capture_pattern_type(subject_type, value_node, scope)
        case value_node
        when Prism::ConstantReadNode, Prism::ConstantPathNode
          singleton_to_nominal(sub_eval(value_node, scope).first)
        when Prism::AlternationPatternNode
          Type::Combinator.union(
            capture_pattern_type(subject_type, value_node.left, scope),
            capture_pattern_type(subject_type, value_node.right, scope)
          )
        when Prism::ArrayPatternNode, Prism::FindPatternNode, Prism::HashPatternNode,
             Prism::PinnedVariableNode, Prism::PinnedExpressionNode, Prism::ImplicitNode
          subject_type || Type::Combinator.untyped
        else
          literal_pattern_type(value_node, scope)
        end
      end

      # The type a non-class pattern node evaluates to: `Constant[1]` for `1 => x`, the nominal for `/re/ => x`,
      # the range for `1..5 => x`. A class reference is the one carrier that must convert (`Singleton[C]` is the
      # class object; the binding holds an instance), which the caller's constant arm does.
      def literal_pattern_type(value_node, scope)
        type = sub_eval(value_node, scope).first
        type.is_a?(Type::Singleton) ? singleton_to_nominal(type) : type
      end

      # `in PatternA | PatternB` — Ruby requires both alternates to bind the same names, but the binder runs against
      # the AST and cannot enforce that. We collect bindings from each side and merge by name, unioning types when both
      # alternates contribute. Names that only one alternate contributes still surface (the parser would have rejected
      # the case at compile time, so by the time we see it the user's intent is the merged set).
      def collect_alternation_pattern_bindings(subject_type, pattern, scope)
        left = collect_in_pattern_bindings(subject_type, pattern.left, scope)
        right = collect_in_pattern_bindings(subject_type, pattern.right, scope)
        merged = {}
        (left + right).each do |name, type|
          merged[name] = merged.key?(name) ? Type::Combinator.union(merged[name], type) : type
        end
        merged.to_a
      end
    end
  end
end
