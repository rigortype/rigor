# frozen_string_literal: true

require "prism"

require_relative "../../analysis/dependency_recorder"
require_relative "../../reflection"
require_relative "../../source/constant_path"
require_relative "../../type"
require_relative "../method_dispatcher"
require_relative "../narrowing"
require_relative "../statement_evaluator"

module Rigor
  module Inference
    class ExpressionTyper
      # Typers of an assignment or compound write in value position: the rvalue for a plain write, and the value a `+=`
      # / `||=` / `&&=` stores for a variable, constant or index target. Reads `scope` and `tracer`; calls back
      # {ExpressionTyper#type_of}, {ExpressionTyper#dynamic_top} and {ExpressionTyper#resolve_constant_name}. The
      # entries are `type_of_assignment_write`, `type_of_compound_variable_write`, `type_of_compound_constant_write`,
      # `type_of_index_compound_write`; every other method is private to the module (ADR-116 C3). State is passed, not
      # shared: each entry takes the values it reads from the typer as trailing positional parameters (`scope`,
      # `tracer`) and the typer itself (`typer`) when it calls back. `ScopeIndexer` (for `DYNAMIC_TARGET_PREFIX`) is not
      # required here: it requires this class, and a direct require makes a cycle (`ruby -w`).
      module Writes
        module_function

        # All `*WriteNode` flavours expose a `.value` rvalue child. Their type is the type of that rvalue.
        # Binding the result back into the scope is the responsibility of the statement-level evaluator
        # (Slice 3), never of `type_of` itself.
        def type_of_assignment_write(node, typer)
          typer.type_of(node.value)
        end

        # `v += 1` / `@v ||= x` / `$v &&= x` as an EXPRESSION. The value of a compound write is the value it
        # stores, which is a function of the variable's CURRENT binding — not of the rvalue alone. Typing it as
        # `type_of(node.value)` answered `1` for `total += 1` whatever `total` held.
        #
        # `StatementEvaluator#compound_eval` already computes the right answer on the straight-line path, so the
        # gap only showed where a body is typed WITHOUT that evaluator: the block-return pass types a
        # single-statement body by expression alone, and issue #617 residue (3) is the live consequence —
        # `total = 0; r = [1, 2].map { total += 1 }` folded to `[1, 1]`, and `r.last == 1` fired a false
        # `flow.always-truthy-condition` on a program where it is `2`. Under the per-element fold the captured
        # local is already bound to its converged `Integer` (issue #587 (b)); reading that binding here is what
        # turns the stale pin into the honest `Integer`.
        #
        # The algebra is `StatementEvaluator#compound_result_type`'s, deliberately: the two must not disagree
        # about what a compound write evaluates to. An unbound target is `Dynamic[top]` — the same fallback the
        # evaluator takes — and an operator the receiver does not answer widens to `Dynamic[top]` rather than
        # inventing the rvalue.
        #
        # Constant targets have {.type_of_compound_constant_write}, over the same algebra. Index targets have their
        # own handler, {.type_of_index_compound_write}.
        def type_of_compound_variable_write(node, scope, typer)
          compound_write_value(node, compound_write_current_binding(node, scope), typer.type_of(node.value), scope,
                               typer)
        end

        # `H ||= 0` / `Conf::LIMIT += 1` as an EXPRESSION: the value it stores, by
        # {.type_of_compound_variable_write}'s algebra. Typed as the rvalue alone, `H = { x: 1 }; v = (H ||= 0);
        # v[:x]` reported `Integer#[]` on a program whose `v` is `H`, and `F.transform_values { |e| F ||= 0 }`
        # folded every value to `0`.
        #
        # A constant has no scope binding, so its current binding is what a plain read of the same spelling
        # resolves to at the write site — the lexical ladder, the in-source table of plain writes, then RBS —
        # less the caller-derived rungs a top-level body keeps for reads Ruby raises on. The memoization idiom
        # (`def registry = REGISTRY ||= {}`, legal where a plain `REGISTRY = {}` is a dynamic constant
        # assignment) writes a constant nothing else binds, so an unresolved target keeps the rvalue reading
        # exactly as an unbound variable does — unless a write other than a memo binds it
        # ({.written_constant_binding}). A path whose base renders no static name (`klass::X`, `self::X`) names
        # no binding the resolver can look up, and reads as unbound too, on the same condition.
        def type_of_compound_constant_write(node, scope, typer)
          rhs = typer.type_of(node.value)
          compound_write_value(node, compound_write_constant_binding(node, scope, typer), rhs, scope, typer)
        end

        def compound_write_value(node, current, rhs, scope, typer)
          case node
          when Prism::LocalVariableOrWriteNode, Prism::InstanceVariableOrWriteNode,
               Prism::ClassVariableOrWriteNode, Prism::GlobalVariableOrWriteNode,
               Prism::ConstantOrWriteNode, Prism::ConstantPathOrWriteNode
            # An UNBOUND target is the memoization idiom (`def self.default = @default ||= new`): nothing
            # has written the variable on any path the analyzer saw, so the stored value is the rvalue.
            # Reading it as `Dynamic[top] | rhs` would skip every memoized singleton in `sig-gen`
            # (ADR-5 optimism; three `.default` readers went `sig.skipped.untyped-return` without this).
            #
            # The index rule's exception applies: an rvalue with no truthy part makes the write a guard, not a
            # memo. `@settings ||= raise "boot first"` returns only when something the analyzer did not see set
            # `@settings`, and `@verbose ||= false` answers `true` once one did, so the value is that unseen
            # binding — `Dynamic[top]`, the statement evaluator's reading of an unbound target — never the
            # rvalue's `bot` or `false` alone. A local is no exception: the scope a loop body is typed from does
            # not carry what the previous iteration stored.
            if current.nil?
              return rhs unless Narrowing.narrow_truthy(rhs).is_a?(Type::Bot)

              current = typer.dynamic_top
            end

            Type::Combinator.union(Narrowing.narrow_truthy(current), rhs)
          when Prism::LocalVariableAndWriteNode, Prism::InstanceVariableAndWriteNode,
               Prism::ClassVariableAndWriteNode, Prism::GlobalVariableAndWriteNode,
               Prism::ConstantAndWriteNode, Prism::ConstantPathAndWriteNode
            # `&&=` is no memo: an unset target returns its own `nil` without evaluating the rvalue (a constant or
            # class variable raises instead). Beside the rvalue, an UNBOUND target's value is its own falsey value —
            # `nil` when unset, or a falsey value a write the analyzer did not see stored — which
            # `narrow_falsey(Dynamic[top])` carries as `Dynamic[top]`, the statement evaluator's reading. The index
            # rule says the same of `h[k] &&= v`. Read as the rvalue, `if (@x &&= 1)` folded always-truthy on a
            # program that takes the else arm.
            Type::Combinator.union(Narrowing.narrow_falsey(current || typer.dynamic_top), rhs)
          else
            compound_operator_result(current || typer.dynamic_top, rhs, node.binary_operator, scope, typer)
          end
        end

        # `h[k] += v` / `h[k] ||= v` / `h[k] &&= v` as an EXPRESSION. Like a variable compound write, its value is
        # what it stores through `[]=` — the dispatched `h[k] + v`, `truthy(h[k]) | v`, `falsey(h[k]) | v` — which
        # reads the slot's current type, recorded indexed narrowing included. Typed as the rvalue alone it answered
        # `1` for `counts[w] += 1`, so `r = words.map { |w| counts[w] += 1 }` pinned every position to `1` and
        # `r.last == 1` drew a false `flow.always-truthy-condition`.
        #
        # The statement evaluator already owned that algebra for the straight-line write and the `[]=` widening
        # join, so this reads its answer rather than keeping a second copy. It asks for the value alone, not a
        # whole `evaluate`: the widening and the narrowing record are scope effects a value position discards,
        # and the memoizing `@cache[k] ||= build(k)` tail is common enough not to pay for them.
        #
        # One exception carries over, narrowed, from {.type_of_compound_variable_write}: a memoizing `||=` whose
        # slot the analyzer has no evidence about reads as the rvalue. The evaluator's value method owns it,
        # because it is decided on the `[]` read the evaluator performs.
        def type_of_index_compound_write(node, scope, tracer)
          StatementEvaluator.new(scope: scope, tracer: tracer).index_compound_write_value(node)
        end

        def compound_write_current_binding(node, scope)
          case node
          when Prism::LocalVariableOperatorWriteNode, Prism::LocalVariableOrWriteNode,
               Prism::LocalVariableAndWriteNode then scope.local(node.name)
          when Prism::InstanceVariableOperatorWriteNode, Prism::InstanceVariableOrWriteNode,
               Prism::InstanceVariableAndWriteNode then scope.ivar(node.name)
          when Prism::ClassVariableOperatorWriteNode, Prism::ClassVariableOrWriteNode,
               Prism::ClassVariableAndWriteNode then scope.cvar(node.name)
          else scope.global(node.name)
          end
        end

        def compound_write_constant_binding(node, scope, typer)
          case node
          when Prism::ConstantOperatorWriteNode, Prism::ConstantOrWriteNode, Prism::ConstantAndWriteNode
            full_name = node.name.to_s
            rooted = false
          else
            full_name = Source::ConstantPath.qualified_name_or_nil(node.target)
            return unnamed_path_binding(node.target, scope, typer) if full_name.nil?

            rooted = Source::ConstantPath.rooted?(node.target)
          end
          typer.resolve_constant_name(full_name, rooted: rooted, caller_derived: false) ||
            written_constant_binding(full_name, rooted, scope, typer)
        end

        # A constant the plain read cannot resolve may still be bound: another file writes a value that never
        # published (`H = { x: 1 }`), the compound write withdrew one by being the second writer the census
        # counts, or this file writes it in a form its own table does not carry (`A, B = …`, `A = B = …`). The
        # value is one the analyzer does not have, so the binding is `Dynamic[top]` rather than the memo's
        # unbound reading. The one write that does not bind is a memo `||=` no other file shares, so the
        # memoization idiom keeps that reading however often its file repeats it; memos of the name in two files
        # bind, since either may load first and set what the other reads.
        #
        # Which name the write reads is the ladder's to decide, not the spelling's: the same resolution runs
        # again with only the census's binding names in the in-source table, so `Other::REGISTRY` elsewhere
        # leaves a top-level `REGISTRY ||= {}` its memo reading. Two census spellings the ladder cannot reach
        # still bind: a write through a base nothing names (`k::X = 1`), which may have written any of them,
        # and a path the census keeps as written ([#690](https://github.com/rigortype/rigor/issues/690)), so
        # `Foo::BAR = …` inside `module M` binds `M::Foo::BAR ||= 0`.
        def written_constant_binding(full_name, rooted, scope, typer)
          names = scope.bound_constant_names(full_name)
          return nil if names.empty?
          return typer.dynamic_top if names.any? { |name| unladdered_census_name?(name, full_name) }

          written = names.to_h { |name| [name, typer.dynamic_top] }
          probe = scope.with_discovery(scope.discovery.with(in_source_constants: written))
          Reflection.resolve_constant_type(full_name, scope: probe, rooted: rooted, caller_derived: false)
        end

        def unladdered_census_name?(name, full_name)
          return true if name.start_with?(ScopeIndexer::DYNAMIC_TARGET_PREFIX)

          name.include?("::") && full_name.end_with?("::#{name}")
        end

        # `self::X ||= v` / `klass::X ||= v` name no constant the resolver can look up, so any binding write
        # that shares the last segment may be the one the base reaches. The answer now depends on other files'
        # writes, and this path never reaches `Reflection.resolve_constant_type`, which records the
        # `constant:<segment>` edge for every other form — so it records the edge itself, or an incremental
        # run keeps serving the reading from before another file's write of the segment appeared.
        def unnamed_path_binding(target, scope, typer)
          segment = target.name&.to_s
          return nil if segment.nil?

          Analysis::DependencyRecorder.read_name(:constant, segment) if Analysis::DependencyRecorder.active?
          typer.dynamic_top unless scope.bound_constant_names(segment).empty?
        end

        def compound_operator_result(current, rhs, operator, scope, typer)
          MethodDispatcher.dispatch(
            receiver_type: current,
            method_name: operator.to_sym,
            arg_types: [rhs],
            environment: scope.environment
          ) || typer.dynamic_top
        end

        private_class_method :compound_write_value, :compound_write_current_binding, :compound_write_constant_binding,
                             :written_constant_binding, :unladdered_census_name?, :unnamed_path_binding,
                             :compound_operator_result
      end
    end
  end
end
