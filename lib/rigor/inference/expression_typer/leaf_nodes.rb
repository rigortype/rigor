# frozen_string_literal: true

require "prism"

require_relative "../../type"

module Rigor
  module Inference
    class ExpressionTyper
      # Typers of nodes whose answer reads at most the scope's binding for a name: literals, `nil` / `true` / `false`,
      # the variable reads and `self`, `defined?`, the match globals, jumps, lambdas, source-position literals and the
      # non-value positions. Reads `scope`; calls back {ExpressionTyper#dynamic_top}. The entries are
      # `type_of_literal_value`, `type_of_true`, `type_of_false`, `type_of_nil`, `type_of_instance_variable_read`,
      # `type_of_class_variable_read`, `type_of_global_variable_read`, `type_of_non_value`, `type_of_self_node`,
      # `type_of_dynamic_top`, `type_of_yield`, `type_of_defined`, `type_of_numbered_reference`,
      # `type_of_back_reference`, `type_of_match_predicate`, `type_of_match_required`, `type_of_interpolated_symbol`,
      # `type_of_def`, `type_of_nil_value`, `type_of_jump`, `type_of_lambda`, `type_of_regexp`, `symbol_type_for`,
      # `string_type_for`, `type_of_xstring`, `type_of_source_file`, `type_of_source_line`, `local_read`, `it_read`;
      # every other method is private to the module (ADR-116 C3). State is passed, not shared: each entry takes the
      # values it reads from the typer as trailing positional parameters (`scope`, `tracer`) and the typer itself
      # (`typer`) when it calls back.
      module LeafNodes
        module_function

        def type_of_literal_value(node)
          Type::Combinator.constant_of(node.value)
        end

        def type_of_true(_node)
          Type::Combinator.constant_of(true)
        end

        def type_of_false(_node)
          Type::Combinator.constant_of(false)
        end

        def type_of_nil(_node)
          Type::Combinator.constant_of(nil)
        end

        # Slice 7 phase 1 — instance/class/global variable reads. Each lookup returns the type currently bound
        # in the surrounding scope's per-kind binding map (populated by `StatementEvaluator` write handlers
        # within the same method body), falling through to `Dynamic[Top]` when no binding is recorded.
        # Cross-method ivar/cvar inference is a follow-up slice; the read handlers MUST NOT raise on a missing
        # binding and MUST NOT record a fallback event in either branch — the absence of a binding is a
        # recognised semantic outcome, not a fail-soft compromise.
        def type_of_instance_variable_read(node, scope, typer)
          bound = scope.ivar(node.name)
          return bound if bound

          # ADR-82 — an unbound instance-variable read is dynamic because the engine does not track this
          # field's type (it is assigned in another method, or never seen). Route it to ivar-field typing
          # (ADR-58) rather than reporting no cause, and let WD6 carry it through a `@x.foo.bar` chain. This
          # records provenance only (still `dynamic_top`), never a fallback / tracer event.
          scope.record_dynamic_origin(node, DynamicOrigin::INFERRED_RETURN_UNTYPED)
          typer.dynamic_top
        end

        def type_of_class_variable_read(node, scope, typer)
          scope.cvar(node.name) || typer.dynamic_top
        end

        def type_of_global_variable_read(node, scope, typer)
          scope.global(node.name) || typer.dynamic_top
        end

        # Recognised position that does not produce a value: parameter lists and individual parameter
        # declarations, splats inside argument lists, key-value pairs in hashes, and the implicit-rest token
        # inside destructuring. Returning Dynamic[Top] silently keeps these off the unrecognised list without
        # faking a value type.
        def type_of_non_value(_node, typer)
          typer.dynamic_top
        end

        # `Prism::SelfNode` resolves to the scope's `self_type` when one has been injected (by
        # `StatementEvaluator` at class-body and method-body boundaries) or `Dynamic[Top]` at the top level.
        # Class-body `self` is `Singleton[<class>]`; instance-method `self` is `Nominal[<class>]`;
        # singleton-method `self` is `Singleton[<class>]`.
        #
        # Issue #1763 — directly in a `refine X` block body `self` is the refinement module, which Rigor does not
        # model; its `Singleton[X]` stand-in serves implicit-self calls only, so a value read of `self` is untyped.
        def type_of_self_node(_node, scope, typer)
          return typer.dynamic_top if scope.refinement_block_self?

          scope.self_type || typer.dynamic_top
        end

        def type_of_dynamic_top(_node, typer)
          typer.dynamic_top
        end

        # Issue #720 — `yield` evaluates the block the CALLER passed, so its value is that block's value. The
        # caller is only known when this body is being re-typed on behalf of one call site
        # ({ExpressionTyper#infer_user_method_return} installs the frame); on the main walk over a `def` no caller
        # exists and the answer stays `Dynamic[top]`.
        #
        # Nothing about the yield's arguments is checked here. The block's return type was computed at the call
        # site under the parameter bindings the call implies, so it already answers "what does this block
        # evaluate to for this caller"; a `yield` that passes different arguments than the block's parameters
        # accept is a separate (arity) question this frame does not decide.
        def type_of_yield(_node, typer)
          ExpressionTyper.current_yield_value_type || typer.dynamic_top
        end

        # `defined?(expr)` returns `String | nil` per Ruby semantics — a description of the expression's
        # category (`"local-variable"`, `"method"`, ...) when defined, or `nil` when not. The argument is not
        # evaluated (it is statically inspected by the runtime), so the typer does not recurse into it.
        def type_of_defined(_node)
          Type::Combinator.union(
            Type::Combinator.nominal_of("String"),
            Type::Combinator.constant_of(nil)
          )
        end

        # `$1`, `$&`, `$'`, `$+`, `$\`` — the regex back-reference and numbered-capture globals each carry
        # `String | nil`. They share the typer because the typing rule is identical regardless of which
        # back-reference shape Prism emitted.
        def type_of_string_or_nil(_node)
          Type::Combinator.union(
            Type::Combinator.nominal_of("String"),
            Type::Combinator.constant_of(nil)
          )
        end

        # `$1` / `$2` / ... — numbered match-data globals. When the narrowing tier has bound a tighter type for
        # this number (typically `String` after a `=~`-success guard like `unless /(\d+)/ =~ s; raise; end`),
        # prefer the scope-bound type. Falls back to the default `String | nil`.
        def type_of_numbered_reference(node, scope)
          scope.global(:"$#{node.number}") || type_of_string_or_nil(node)
        end

        # `$&` / `$'` / `$\`` / `$+` — symbolic back-references. Same narrowing model as numbered references.
        def type_of_back_reference(node, scope)
          scope.global(node.name) || type_of_string_or_nil(node)
        end

        # `expr in pattern` — pattern-match predicate. Returns `true` when the pattern matches, `false`
        # otherwise.
        def type_of_match_predicate(_node)
          Type::Combinator.union(
            Type::Combinator.constant_of(true),
            Type::Combinator.constant_of(false)
          )
        end

        # `expr => pattern` — one-line pattern-match assertion. Raises `NoMatchingPatternError` on mismatch; on
        # success the expression itself evaluates to `nil`.
        def type_of_match_required(_node)
          Type::Combinator.constant_of(nil)
        end

        def type_of_interpolated_symbol(_node)
          Type::Combinator.nominal_of(Symbol)
        end

        def type_of_def(node)
          Type::Combinator.constant_of(node.name)
        end

        # `alias x y`, `alias $x $y`, and `undef foo` all evaluate to nil at runtime; the constant carrier
        # captures that exactly.
        def type_of_nil_value(_node)
          Type::Combinator.constant_of(nil)
        end

        # `return`, `break`, `next`, `retry`, and `redo` all transfer control instead of producing a value.
        # Their type is Bot, the empty type that absorbs cleanly under union (e.g. `Constant[1] | Bot ==
        # Constant[1]`), so the surrounding control-flow handlers collapse correctly when one branch jumps.
        def type_of_jump(_node)
          Type::Combinator.bot
        end

        def type_of_lambda(_node)
          Type::Combinator.nominal_of(Proc)
        end

        # v0.0.7 — non-interpolated regex literals lift to `Constant<Regexp>` so `Constant<String>#scan(/regex/)`
        # / `#match(/regex/)` etc. can fold through the catalog tier. Interpolated regexes (`/foo#{x}/`) reach
        # the early return for any node that is not a `Prism::RegularExpressionNode`, which keeps the conservative
        # `Nominal[Regexp]` answer.
        def type_of_regexp(node)
          return Type::Combinator.nominal_of(Regexp) unless node.is_a?(Prism::RegularExpressionNode)

          regex = Regexp.new(node.unescaped, node.options)
          Type::Combinator.constant_of(regex)
        rescue StandardError
          Type::Combinator.nominal_of(Regexp)
        end

        def symbol_type_for(node)
          raw = node.value
          return Type::Combinator.nominal_of(Symbol) if raw.nil?

          Type::Combinator.constant_of(raw.to_sym)
        end

        def string_type_for(node)
          unescaped = node.unescaped
          return Type::Combinator.nominal_of(String) if unescaped.nil?

          Type::Combinator.constant_of(unescaped)
        end

        # Backtick (`cmd`) and `%x{cmd}` invoke Kernel#` and always return a String. Even when the content is
        # statically known, we widen to Nominal[String] because the runtime value depends on the subprocess
        # output, not the source text.
        def type_of_xstring(_node)
          Type::Combinator.nominal_of(String)
        end

        # __FILE__ is the source file path. Always non-empty when parsing a real file (the path resolver gives
        # the buffer name, which is at minimum `"(stdin)"` / `"-e"` / a real path — never the empty String).
        # Widened to `non-empty-string` instead of `Nominal[String]` so downstream String-emptiness checks know
        # the value cannot be `""`.
        def type_of_source_file(_node)
          Type::Combinator.non_empty_string
        end

        # __LINE__ is the line of the source literal. Ruby line numbers are 1-indexed, so `__LINE__` is always
        # at least 1 — `positive-int` (Integer in `[1, +Inf)`) is the canonical refinement.
        def type_of_source_line(_node)
          Type::Combinator.positive_int
        end

        def local_read(node, scope, typer)
          scope.local(node.name) || typer.dynamic_top
        end

        # `it` (Ruby 3.4) — `ItLocalVariableReadNode` carries no `name` field; the implicit name is always
        # `:it`, matching the binding `BlockParameterBinder` installs for `Prism::ItParametersNode`.
        def it_read(_node, scope, typer)
          scope.local(:it) || typer.dynamic_top
        end

        private_class_method :type_of_string_or_nil
      end
    end
  end
end
