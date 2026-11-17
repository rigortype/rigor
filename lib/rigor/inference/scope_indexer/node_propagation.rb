# frozen_string_literal: true

require "prism"

require_relative "../../scope"
require_relative "../../source/constant_path"
require_relative "../../source/node_children"
require_relative "../../type"
require_relative "../../typing_state"
require_relative "../anonymous_meta_class"
require_relative "../define_method_block_self"
require_relative "../fresh_frame_blocks"
require_relative "../guard_rebinding"
require_relative "../in_effect_refinements"
require_relative "../last_line"
require_relative "../macro_block_self_type"
require_relative "../narrowing"
require_relative "../operand_effects"

module Rigor
  module Inference
    module ScopeIndexer
      module NodePropagation # rubocop:disable Metrics/ModuleLength
        module_function

        # Walks `node`'s subtree DFS and fills in scope entries for every Prism node the StatementEvaluator did not
        # visit (i.e. expression- interior nodes like the receiver/args of a CallNode). Those nodes inherit their
        # nearest recorded ancestor's scope.
        #
        # `IfNode` / `UnlessNode` are special-cased: the truthy and falsey branches each get their predicate's narrowed
        # scope before recursing. This handles expression-position conditionals (e.g. `cache[k] = if cond; t; else; e;
        # end` and conditionals nested as call arguments) which are typed by ExpressionTyper without going through
        # `eval_if`'s narrowing path.
        #
        # A block or lambda the evaluator never entered is special-cased too ({#closure_scope}): its own locals shadow
        # the enclosing bindings of the same names. Such a block of a call {FreshFrameBlocks} names enters as the
        # evaluator enters it ({#propagate_call}).
        def propagate(node, table, parent_scope)
          return unless node.is_a?(Prism::Node)

          recorded = table.key?(node)
          current_scope =
            if recorded
              table[node]
            else
              table[node] = parent_scope
              parent_scope
            end
          evaluate_unentered_flow(node, table, current_scope)

          case node
          when Prism::IfNode
            propagate_if_branches(node, table, current_scope)
          when Prism::UnlessNode
            propagate_unless_branches(node, table, current_scope)
          when Prism::BlockNode, Prism::LambdaNode
            # An entered block is recorded with its entry scope, parameters bound. An entered `->` is recorded with
            # the ENCLOSING scope ({StatementEvaluator#eval_lambda} enters only its body), so its parameter list
            # still needs the boundary: `f = ->(o, b = (o + 1)) { b }` reads the default's `o` as the parameter. A
            # `when ->(o) { … }` condition is recorded without being entered at all, body included.
            entered = recorded && node.is_a?(Prism::BlockNode)
            child_scope = entered ? current_scope : closure_scope(node, current_scope)
            node.rigor_each_child { |child| propagate(child, table, child_scope) }
          when Prism::CallNode
            propagate_call(node, table, current_scope, recorded: recorded)
          when Prism::RescueNode, Prism::EnsureNode
            # Issue #1360 — a clause the evaluator did not enter (a `begin` in a value position) reads `$!`, `$@` and
            # `$?` unbound, not the enclosing clause's; one it entered keeps what it recorded.
            child_scope = current_scope.forget_error_info.forget_last_status
            node.rigor_each_child { |child| propagate(child, table, child_scope) }
          when Prism::RescueModifierNode
            propagate(node.expression, table, current_scope)
            propagate(node.rescue_expression, table, current_scope.forget_error_info.forget_last_status)
          when Prism::PostExecutionNode then propagate_end_body(node, table, current_scope)
          else propagate_children(node, table, current_scope)
          end
        end

        # Issues #2196 and #2056 — the constructs whose parts run under a narrowing their own condition or left operand
        # makes, keyed to the part {StatementEvaluator} records first when it enters one. Issue #2214 — a `&&=` on a
        # variable runs its value under the variable's truthy narrowing (`[c &&= c + 1]`).
        UNENTERED_FLOW_ENTRY = {
          Prism::AndNode => :left, Prism::OrNode => :left,
          Prism::IfNode => :predicate, Prism::UnlessNode => :predicate,
          Prism::WhileNode => :predicate, Prism::UntilNode => :predicate,
          Prism::LocalVariableAndWriteNode => :value, Prism::InstanceVariableAndWriteNode => :value,
          Prism::ClassVariableAndWriteNode => :value, Prism::GlobalVariableAndWriteNode => :value,
          Prism::CaseNode => :predicate
        }.freeze
        private_constant :UNENTERED_FLOW_ENTRY

        # ADR-129 WD1 — a Frame: {#with_unentered_evaluator} installs the walk's evaluation for the walk and restores
        # the outer one, and whether one is installed changes answers (an unentered construct is evaluated only inside a
        # walk).
        UNENTERED_EVALUATOR = TypingState.frame(
          :scope_index_unentered_evaluator,
          reason: "installed around the index walk that evaluates its unentered constructs; the lambda writes the " \
                  "walk's own table (the walk's state, not typing state) and reads its converged-loop recording and " \
                  "clause widening, and is frozen while installed",
          # G1′: the evaluation types under the Frame, but only the index walk, outside `type_of`, reads it.
          typing_never_reads: true
        )
        private_constant :UNENTERED_EVALUATOR

        # Issues #2196 and #2056 — an `&&` / `||` / `and` / `or`, an `if` / `unless` / ternary or a `while` / `until`
        # in a value position (an array element, a hash value, a call argument, an interpolation, a multi-value
        # `return`) is typed by `ExpressionTyper` and never entered, so no part of it was recorded and this walk handed
        # every part one scope. A walk that narrows by the condition's edges cannot follow a write inside the narrowed
        # part (`[c && (c = c.size; c.even?)]`, `[x || (set!; @x.upcase)]`) nor one inside a block in an earlier
        # conjunct (`[x.nil? && [1].each { x = "d" } && x.upcase]`). Such a construct is evaluated here instead, from
        # the scope this walk reached it with, under the index's own recorder, so each part is recorded with the scope
        # the statement form records it with. What it does not visit (a dead arm) is walked as before.
        def evaluate_unentered_flow(node, table, current_scope)
          return evaluate_unentered_block(node, table, current_scope) if node.is_a?(Prism::CallNode)

          entry = UNENTERED_FLOW_ENTRY[node.class]
          return if entry.nil?

          # An entered construct is already recorded; skipping it is a performance guard, not a behaviour. A `case`
          # without a subject records its first `when` test first.
          part = node.public_send(entry) || (node.conditions.first&.conditions&.first if node.is_a?(Prism::CaseNode))
          return if part.nil? || table.key?(part)

          evaluate = TypingState.current[UNENTERED_EVALUATOR]
          evaluate&.call(node, current_scope, code_body_nodes(node, current_scope.source_path))
        end

        # Issue #1246 — the block of a call in a value position (`show([1].map { x = "s"; x.upcase })`, a receiver
        # chain, an array element, a `->`'s body) is never entered: {StatementEvaluator} types the call through
        # `ExpressionTyper`, and this walk could only floor a local the block rebinds ({#closure_scope}). Such a block
        # is entered here instead, alone, from the scope this walk reached its call with, so its body is recorded with
        # the scopes the statement form records: a capture read before the block rebinds it reads its binding, and the
        # block's parameters are bound. The call's receiver and arguments stay with the walk. A class-creating or
        # `refine` block keeps the walk ({#unentered_block_entry}), and a code body inside the block is left out of the
        # recording ({#code_body_nodes}). A `super` block is a `SuperNode`'s, which the evaluator never enters either.
        def evaluate_unentered_block(node, table, current_scope)
          block = node.block
          return unless block.is_a?(Prism::BlockNode)
          return if table.key?(block) || class_body_block_call?(node, current_scope.source_path)

          evaluate = TypingState.current[UNENTERED_EVALUATOR]
          evaluate&.call(node, current_scope, code_body_nodes(block, current_scope.source_path), block_only: true)
        end

        # The evaluation of an unentered construct starts with no class frame and no lexical nesting, which only a code
        # body observes: a `def`, a `class` / `module` / `class << …` body, and the block of a class-creating call
        # (`Class.new { … }`, `Struct.new`, `Data.define`, `Module.new`) or of a `refine`, whose `def`s and constants
        # resolve against the class the walk tracks and the evaluation does not. Every node in one is left out of the
        # recording, so the walk reaches it unrecorded and handles it as it did before #2196 ({#unentered_block_entry},
        # {#record_class_body_defs}).
        # Answers nil, allocating nothing, for a construct holding no code body: the common case.
        def code_body_nodes(node, source_path, acc = nil, inside: false)
          inside ||= CODE_BODY_NODES.include?(node.class)
          (acc ||= Set.new.compare_by_identity) << node if inside
          if !inside && node.is_a?(Prism::CallNode) && class_body_block_call?(node, source_path)
            acc = code_body_nodes(node.block, source_path, acc, inside: true)
            node.rigor_each_child do |child|
              acc = code_body_nodes(child, source_path, acc) unless child.equal?(node.block)
            end
            return acc
          end
          node.rigor_each_child { |child| acc = code_body_nodes(child, source_path, acc, inside: inside) }
          acc
        end

        def class_body_block_call?(node, source_path)
          node.block.is_a?(Prism::BlockNode) &&
            (!AnonymousMetaClass.name_for(node, source_path).nil? || !ScopeIndexer.refine_target(node).nil?)
        end

        # The evaluation {#evaluate_unentered_flow} runs for the walk of one {#index}, installed for that walk only.
        # Index walks nest (a rule may re-index a file while another file's walk is suspended), so the outer one is
        # restored on exit. A `propagate` called directly while an outer index walk is running would record into the
        # OUTER index's table through it; nothing outside {#index} calls `propagate`.
        def with_unentered_evaluator(evaluate, &)
          TypingState.current.with(UNENTERED_EVALUATOR, evaluate.freeze, &)
        end

        # Issue #1717 — a `def` / `class` / `module` body opens its own `self`, so an enclosing unentered block's
        # unknown-`self` mark ({Scope#block_self_unknown?}) stops at it, as the evaluator's fresh body scope does.
        # Issue #1246 — it opens its own local table too, so a name in it (a `def`'s parameter, a body local) is a new
        # variable, never the enclosing statement's local of that name: `show(Class.new { def call(o) = o + 1 })` after
        # `o = { x: 1 }` read the parameter as the Hash. Such a name reads `Dynamic[top]` ({#shadow_local}), as in an
        # unentered closure ({#closure_scope}); a body the evaluator entered is recorded and keeps its own scopes. Only
        # the parameters and the body take that table: a `def`'s receiver, a `class`'s name and superclass and a
        # `class << …`'s expression run in the enclosing scope (`class K < base.nope; base = 2; end`).
        # A `case` narrows its clauses ({#propagate_subjectless_case}, {#propagate_subject_case}). Every other node
        # hands its children the scope as is.
        def propagate_children(node, table, current_scope)
          if node.is_a?(Prism::CaseNode) || node.is_a?(Prism::CaseMatchNode)
            return propagate_subjectless_case(node, table, current_scope) if node.predicate.nil?

            return propagate_subject_case(node, table, current_scope)
          end
          return propagate_code_body(node, table, current_scope) if SELF_OPENING_BODIES.include?(node.class)

          node.rigor_each_child { |child| propagate(child, table, current_scope) }
        end

        def propagate_code_body(node, table, current_scope)
          outer_scope = current_scope.with_block_self_unknown(false)
          inner = [node.body]
          inner << node.parameters if node.is_a?(Prism::DefNode)
          inner_scope = node.locals.reduce(outer_scope) { |acc, name| shadow_local(acc, name) }
          node.rigor_each_child do |child|
            propagate(child, table, inner.any? { |part| part.equal?(child) } ? inner_scope : outer_scope)
          end
        end

        # Issue #1361 — the block of `Thread.new`, `Fiber.new`, `define_method` and the other calls
        # {FreshFrameBlocks.fresh_entry?} names does not read the match-global narrowing of the body it is written in.
        # The evaluator enters it as {FreshFrameBlocks.entry} gives ({MatchRebinding.block_entry}), but a block in a
        # value position — the receiver of `Thread.new { $1 }.value` — is not entered, and its body would read the
        # statement's narrowing. Issue #1359 — nor does such a block read a `$_` narrowing it or the call's operands may
        # set ({LastLine.block_entry}): this walk evaluates nothing, so no `gets` in the body forgets it. Issue #1360 —
        # and the block of a call that keeps it, a closure, reads `$!`, `$@` and `$?` unbound
        # ({FreshFrameBlocks.closure_entry}).
        #
        # Issue #1468 — the arguments and block of a safe-navigation call run only once its receiver is non-nil, so
        # they inherit the scope with the receiver narrowed ({Narrowing.safe_navigation_scope},
        # {Narrowing.safe_navigation_block_scope}); the receiver itself keeps the call's own. This walk hands every
        # argument one scope and threads none, so arguments that write keep the call's: an earlier one may rebind the
        # receiver a later one reads (`return y&.concat((y = nil).to_s, y.upcase)`, where the evaluator threads no
        # operand).
        #
        # Issue #1246 — the block of a value-position call is evaluated before this walk reaches it
        # ({#evaluate_unentered_block}), so it arrives recorded and keeps the evaluator's entry. The block entries
        # above therefore reach only a block that evaluation declines: a class-creating or `refine` block.
        def propagate_call(node, table, current_scope, recorded: false)
          block = node.block
          operands =
            OperandEffects.any?(node.arguments) ? current_scope : Narrowing.safe_navigation_scope(node, current_scope)
          entry = unentered_block_entry(node, block, table, current_scope, call_recorded: recorded)
          if entry.equal?(current_scope) && operands.equal?(current_scope)
            node.rigor_each_child { |child| propagate(child, table, current_scope) }
            return
          end

          receiver = node.receiver
          node.rigor_each_child do |child|
            child_scope =
              if child.equal?(receiver) then current_scope
              elsif child.equal?(block) && block.is_a?(Prism::BlockNode) then entry
              else operands
              end
            propagate(child, table, child_scope)
          end
        end

        # Issue #1429 — an `END { }` body runs at exit, after any code that may rebind a guarded global or constant
        # ({GuardRebinding.block_entry}).
        def propagate_end_body(node, table, current_scope)
          child_scope = GuardRebinding.block_entry(current_scope, node, nil)
          node.rigor_each_child { |child| propagate(child, table, child_scope) }
        end

        def unentered_block_entry(node, block, table, current_scope, call_recorded: false)
          return current_scope unless block.is_a?(Prism::BlockNode) && !table.key?(block)

          narrowing = unentered_block_narrowing(node, current_scope)
          current_scope = Narrowing.safe_navigation_block_scope(node, current_scope)
          # Issue #1429 — nor a guard's narrowing of a global or constant the body may run after code rebinds.
          current_scope = GuardRebinding.block_entry(current_scope, block, node)
          current_scope = current_scope.entering_block_without_gradual_marks(block)
          entry =
            if FreshFrameBlocks.fresh_entry?(node, current_scope)
              FreshFrameBlocks.entry(current_scope, node)
            else
              LastLine.block_entry(FreshFrameBlocks.closure_entry(current_scope, block, node), block, node)
            end
          # Issue #2196 — a class-body block whose call the evaluator recorded but did not enter (one inside a construct
          # {#evaluate_unentered_flow} evaluated, or a later operand) starts from the scope the call was evaluated in,
          # which may narrow a captured local the body writes; this walk runs the body's statements from one scope, so
          # such a local reads `Dynamic[top]` in it: `[c && Class.new { c = c.size; c.even? }]`. A block whose call was
          # not recorded keeps the enclosing scope as before.
          if call_recorded && class_body_block_call?(node, entry.source_path)
            entry = widen_condition_writes(block, entry)
          end
          anonymous = AnonymousMetaClass.name_for(node, current_scope.source_path)
          return unentered_meta_class_body_entry(block, entry, anonymous, table) if anonymous

          refined = refined_body_name(node, current_scope)
          record_class_body_defs(block, entry, table, Type::Combinator.nominal_of(refined), nil) if refined

          # Issue #1717 — the body's `self` is unknown unless narrowed, as on the evaluator's entry; only the
          # `call.undefined-method` mark is set here, never #316's opaque mark (its bind gate reads the evaluator's).
          entry = entry.with_block_self_unknown(true) unless narrowing&.self_type
          return entry unless narrowing

          MacroBlockSelfType.apply(entry, narrowing, keeps_unknown: current_scope.block_self_narrowing_unknown?(node))
        end

        # Issue #1120 — the class a `refine X do … end` call's block refines, or nil when the call is not that shape
        # or is a `refine` where `self` is a class (issue #1689: the class's own method, its block an ordinary one).
        # The evaluator asks the same two questions ({StatementEvaluator#refined_class_context}).
        def refined_body_name(node, scope)
          target = ScopeIndexer.refine_target(node)
          return nil if target.nil? || InEffectRefinements.class_body_refine?(scope, node)

          refined_class_name(target, scope)
        end

        # Issue #1120 — the name of the class `refine target do … end` refines: the class `target` types as, or the
        # constant as written when it does not type as a class object (a gem class with no RBS). Shared by
        # {StatementEvaluator#refined_class_context} and {#refined_body_name}.
        def refined_class_name(target, scope)
          refined = scope.type_of(target)
          name = refined.is_a?(Type::Singleton) ? refined.class_name : Source::ConstantPath.qualified_name(target)
          name&.delete_prefix("::")
        end

        # Issue #1696 — the entry of a `Class.new` / `Module.new` / `Struct.new` / `Data.define` block the evaluator
        # never entered because it sits in a value position: `Object.const_set(:K, Class.new { attr_reader :x })`,
        # `[Struct.new(:a) { def b = a }]`. Its `self` is the class `name` ({AnonymousMetaClass.name_for}) names, as
        # {StatementEvaluator#enter_meta_class_body} gives the statement form; left on the enclosing `self`, a
        # top-level one read every macro in it as `call.unresolved-toplevel`. Its `def`s are recorded as
        # {#record_class_body_defs} says.
        def unentered_meta_class_body_entry(block, entry, name, table)
          entry = entry.with_block_self_type(Type::Combinator.singleton_of(name)).with_singleton_class_body(false)
          record_class_body_defs(block, entry, table, Type::Combinator.nominal_of(name), entry.self_type)
          entry
        end

        # Issue #1696 — records each `def` a value-position class-body block defines ({#each_class_body_def}) with the
        # `self` its body runs on, since no evaluator pass enters it: `instance_self` for a plain `def`, `class_self`
        # for a `def self.m` (skipped when nil). A `refine X` block passes only `Nominal[X]`: Ruby runs its defs on an
        # instance of X, but the block itself on the refinement module, which Rigor does not model, so the block keeps
        # the unknown `self` an unnarrowed block has. A `def obj.m` is left to the walk.
        def record_class_body_defs(block, entry, table, instance_self, class_self)
          each_class_body_def(block.body) do |def_node|
            next if table.key?(def_node)

            receiver = def_node.receiver
            def_self =
              if receiver.nil? then instance_self
              elsif receiver.is_a?(Prism::SelfNode) then class_self
              end
            table[def_node] = entry.with_block_self_type(def_self) if def_self
          end
        end

        # The `def`s a class-body block defines on its class: every one in the body, `private def m` included, short
        # of a nested block, lambda or `class` / `module` / `class << …` body, each of which opens its own.
        def each_class_body_def(node, &)
          return unless node.is_a?(Prism::Node)
          return yield(node) if node.is_a?(Prism::DefNode)
          return if CLASS_BODY_DEF_BARRIERS.include?(node.class)

          node.rigor_each_child { |child| each_class_body_def(child, &) }
        end

        # The narrowing ({MacroBlockSelfType::Match}) an unentered block's body runs with — its `self` and, for a
        # `block_as_methods:` entry, the declared refinements (issue #1667) — when the call is one whose block the
        # engine narrows: an ADR-16 Tier A `block_as_methods:` match ({MacroBlockSelfType}) or `define_method` on the
        # lexical `self` ({DefineMethodBlockSelf}, issue #963). The evaluator applies the same two narrowings to
        # the blocks it enters ({StatementEvaluator#build_block_entry_scope}, {StatementEvaluator#enter_call_block})
        # and the value pass to every block it types ({ExpressionTyper#block_body_self_narrowing}); without this a
        # block in a value position — `puts(MyApp.get("/x") { redirect "/y" })`, `render json: Alba.serialize(x) {
        # attributes :id }`, `private define_method(:m) { helper }` — kept the enclosing `self`, and every DSL call
        # in it read as a call on that. The receiver is typed only when some plugin declares an entry for the
        # call's name, so a call no entry names costs one table lookup. A miss, or a raise, keeps the entry as
        # built — the false-positive-safe direction.
        def unentered_block_narrowing(node, scope)
          registry = scope.environment&.plugin_registry
          if registry && !registry.empty? && !registry.contribution_index.block_entries_for(node.name).empty?
            receiver_type =
              node.receiver ? scope.type_of(node.receiver) : MacroBlockSelfType.implicit_receiver_type(scope)
            match = MacroBlockSelfType.match_for(scope: scope, call_node: node, receiver_type: receiver_type)
            return match if match
          end
          defined = DefineMethodBlockSelf.narrow_self_type_for(scope: scope, call_node: node)
          defined && MacroBlockSelfType::Match.new(self_type: defined, refinements: InEffectRefinements::EMPTY)
        rescue StandardError
          nil
        end

        # The scope the children of an unentered block or lambda inherit. The evaluator enters a statement-level
        # call's block ({StatementEvaluator#evaluate_block_if_present}), an assignment's rvalue and a statement-level
        # `->`'s body, but not a closure in a value position — a call argument (`show(xs.map { |o| o + 1 })`), a
        # receiver chain (`xs.map { |o| o + 1 }.sum`), a literal element — nor a `super` call's block, so its body
        # falls to this walk and would inherit the enclosing statement's scope verbatim. That scope still binds an
        # outer `o` the block parameter shadows, and a read of the parameter typed as the outer local: `o = { x: 1 }`
        # made `o + 1` an undefined-method error.
        #
        # Every name in the closure's own local table (Prism's `locals`: its parameters, `;`-locals and the locals
        # its body introduces) is a new variable, and so is the implicit `it` of a block that uses it, which Prism
        # keeps out of `locals` although the binder binds it (`xs.each { show(it.map { it + 1 }) }` read the inner
        # `it` as the outer block's). An enclosing binding of such a name is replaced with `Dynamic[top]`. Not the
        # signature's parameter type: this walk evaluates nothing, and a body write to the name is never threaded,
        # so any narrower claim could be stale. A name the enclosing scope does not bind is left unbound, which
        # reads the same `Dynamic[top]`. Issue #1246 — for the same reason a captured name the body (or a closure
        # nested in it) writes reads `Dynamic[top]` too ({#widen_condition_writes}): `x = 1; show([1].map { x = "s";
        # x.upcase })` read `x` as `1` after the write. A captured name the body only reads keeps the enclosing
        # binding. Issue #1360 — a `->` body and its parameter defaults run whenever the lambda is called, so they read
        # `$!`, `$@` and `$?` unbound ({FreshFrameBlocks.closure_entry}).
        def closure_scope(closure, scope)
          scope = GuardRebinding.block_entry(scope, closure, nil)
          scope = FreshFrameBlocks.closure_entry(scope, closure, nil)
          scope = shadow_local(scope, :it) if closure.parameters.is_a?(Prism::ItParametersNode)
          scope = closure.locals.reduce(scope) { |acc, name| shadow_local(acc, name) }
          widen_condition_writes(closure, scope)
        end

        def shadow_local(scope, name)
          scope.local(name).nil? ? scope : scope.with_local(name, Type::Combinator.untyped)
        end

        # Issue #1924 — an `if` / `elsif` / `unless` / ternary the evaluator did not enter (`[if (x ||= "d").empty?
        # then 0 else x.upcase end]`) applies no write its condition makes, so its edges are taken from a scope where
        # every bound local the condition writes reads `Dynamic[top]` ({#widen_condition_writes}), as
        # {#propagate_subjectless_case} takes a `when` condition's. The condition itself reads the scope before it.
        def propagate_if_branches(node, table, current_scope)
          truthy_scope, falsey_scope = conditional_edges(node.predicate, current_scope)
          propagate(node.predicate, table, current_scope) if node.predicate
          propagate(node.statements, table, truthy_scope) if node.statements
          propagate(node.subsequent, table, falsey_scope) if node.subsequent
        end

        def propagate_unless_branches(node, table, current_scope)
          truthy_scope, falsey_scope = conditional_edges(node.predicate, current_scope)
          propagate(node.predicate, table, current_scope) if node.predicate
          propagate(node.statements, table, falsey_scope) if node.statements
          propagate(node.else_clause, table, truthy_scope) if node.else_clause
        end

        def conditional_edges(predicate, scope)
          Narrowing.predicate_scopes(predicate, widen_condition_writes(predicate, scope))
        end

        # Issue #1495 — a `case` without a subject the evaluator did not enter (`[case; when x.nil? then 0; else x.size
        # end]`) narrows by its conditions' edges, as {StatementEvaluator#subjectless_when_scopes} does: each condition
        # under the falsey edges of the conditions before it, each clause under the join of its conditions' truthy
        # edges, and the `else` under the last falsey edge. Like the walk of an `if`, it applies no write a condition
        # makes, so the edges are taken from a scope where every bound local the condition writes reads `Dynamic[top]`
        # ({#widen_condition_writes}): neither the local's old type nor an earlier condition's narrowing of it reaches
        # them, as `when (x = s ? String(s) : nil) then x.upcase` after `x = 1` would.
        def propagate_subjectless_case(node, table, current_scope)
          falsey = current_scope
          node.conditions.each do |when_node|
            truthy_edges = when_node.conditions.map do |condition|
              propagate(condition, table, falsey)
              truthy, falsey = Narrowing.predicate_scopes(condition, widen_condition_writes(condition, falsey))
              truthy
            end
            propagate(when_node, table, truthy_edges.reduce(:join))
          end
          propagate(node.else_clause, table, falsey) if node.else_clause
        end

        # Issue #1484 — a `case` with a subject the evaluator did not enter (`[case io when StringIO then io.string
        # end]`, `[case io in StringIO then io.string else nil end]`) narrows each clause as the evaluator does
        # ({Narrowing.case_clause_scopes}): the body under the clause's narrowed edge, the next clause and the `else`
        # under its falsey edge. The walk applies no write the subject, a `when` condition or an `in` pattern makes, so
        # every bound local one of them writes reads `Dynamic[top]` from that point on ({#widen_condition_writes}).
        # Nor does it run the evaluator's per-clause `LastLine.forget_if_set`: the statement holding the `case`
        # already forgets a `$_` any of its tests may set. A clause's tests are recorded under the scope the earlier
        # clauses' falsey edges left, where the evaluator's `when` tests read the post-subject scope: a test reading
        # the subject sees what the earlier clauses ruled out (`when NilClass then 0 when v.succ`).
        #
        # A test that calls a method may rebind an instance-variable or global subject before the body reads it
        # (`when String then 1 when reset! then @x.upcase`, where `reset!` writes `@x`), and the walk cannot tell. From
        # the first such test on, the subject reads `Dynamic[top]` on both edges ({#forget_called_subject}). The
        # evaluator forgets a global subject there too (issue #2211). A `case` / `when` the evaluator did not enter is
        # evaluated ({#evaluate_unentered_flow}); this walk handles only a clause that evaluation does not visit.
        def propagate_subject_case(node, table, current_scope)
          subject = node.predicate
          propagate(subject, table, current_scope)
          falsey = widen_condition_writes(subject, current_scope)
          called = false
          node.conditions.each do |clause|
            tests = clause.is_a?(Prism::WhenNode) ? clause.conditions : [clause.pattern]
            tests.each { |test| propagate(test, table, falsey) }
            falsey = tests.reduce(falsey) { |acc, test| widen_condition_writes(test, acc) }
            called ||= tests.any? { |test| runs_call?(test) }
            body, falsey = Narrowing.case_clause_scopes(subject, clause, falsey)
            body, falsey = [body, falsey].map { |scope| forget_called_subject(subject, scope) } if called
            propagate(clause, table, body)
          end
          propagate(node.else_clause, table, falsey) if node.else_clause
        end

        CODE_RUNNING_NODES = [Prism::CallNode, Prism::SuperNode, Prism::ForwardingSuperNode, Prism::YieldNode].freeze
        private_constant :CODE_RUNNING_NODES

        # Whether `node` holds a method call, `super` or `yield` anywhere, a lambda body's included.
        def runs_call?(node)
          return false unless node.is_a?(Prism::Node)
          return true if CODE_RUNNING_NODES.include?(node.class)

          node.rigor_each_child { |child| return true if runs_call?(child) }
          false
        end

        # `scope` with an instance-variable or global `subject` rebound to `Dynamic[top]`; any other subject as is.
        def forget_called_subject(subject, scope)
          case subject
          when Prism::InstanceVariableReadNode then scope.with_ivar(subject.name, Type::Combinator.untyped)
          when Prism::GlobalVariableReadNode then scope.with_global(subject.name, Type::Combinator.untyped)
          else scope
          end
        end

        # `scope` with every bound local `condition` writes rebound to `Dynamic[top]`.
        def widen_condition_writes(condition, scope)
          OperandEffects.written_variables(condition).reduce(scope) do |acc, name|
            acc.local(name) ? acc.with_local(name, Type::Combinator.untyped) : acc
          end
        end

        private_class_method :evaluate_unentered_flow, :evaluate_unentered_block, :code_body_nodes,
                             :class_body_block_call?, :propagate_children, :propagate_code_body, :propagate_call,
                             :propagate_end_body, :unentered_block_entry, :refined_body_name,
                             :unentered_meta_class_body_entry, :record_class_body_defs, :each_class_body_def,
                             :unentered_block_narrowing, :closure_scope, :shadow_local, :propagate_if_branches,
                             :propagate_unless_branches, :conditional_edges, :propagate_subjectless_case,
                             :propagate_subject_case, :runs_call?, :forget_called_subject, :widen_condition_writes
      end
    end
  end
end
