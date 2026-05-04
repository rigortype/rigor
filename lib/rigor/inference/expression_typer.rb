# frozen_string_literal: true

require "prism"

require_relative "../type"
require_relative "../ast"
require_relative "block_parameter_binder"
require_relative "fallback"
require_relative "method_dispatcher"

module Rigor
  module Inference
    # Translates AST nodes into Rigor::Type values, consulting the surrounding
    # Rigor::Scope for local-variable bindings and the environment registry
    # for nominal-type resolution. Pure: never mutates the receiver scope.
    #
    # Accepts both real Prism nodes and synthetic Rigor::AST::Node
    # instances; the synthetic family lets callers and plugins ask
    # "what would the analyzer infer if a value of type T appeared here?"
    # without building a real Prism expression.
    #
    # Slice 1 recognises literal expressions, local-variable reads/writes,
    # shallow Array literals, and Rigor::AST::TypeNode. Slice 2 adds
    # Prism::CallNode (routed through Rigor::Inference::MethodDispatcher),
    # Prism::ArgumentsNode (a non-value position whose children are typed
    # individually by the CallNode handler), constant references resolved
    # through Rigor::Environment::ClassRegistry, hash and interpolated
    # string/symbol literals, definition expressions (def/class/module),
    # and explicit handlers for parameter, block, splat, instance/class/
    # global-variable, and self positions. Many of those handlers return
    # Dynamic[Top] silently because they are non-value or out-of-scope
    # positions for Slice 2; later slices refine them in place.
    #
    # Slice 4 phase 2b types bare-constant references (`Foo`, `Foo::Bar`)
    # as `Singleton[Foo]` rather than `Nominal[Foo]`, so that method
    # dispatch on the constant correctly looks up *class* methods. The
    # corresponding instance type is reachable through `Foo.new` and the
    # value-lattice projections.
    #
    # Every other node falls back to Dynamic[Top] per the fail-soft
    # policy in docs/internal-spec/inference-engine.md. The optional
    # tracer is a Rigor::Inference::FallbackTracer (or any object
    # answering #record_fallback) that receives a Fallback event for
    # each fallback; the tracer MUST NOT change the return value of
    # type_of.
    # rubocop:disable Metrics/ClassLength
    class ExpressionTyper
      # Hash-based dispatch keeps `type_of` linear and lets future slices add
      # node kinds without growing a single case statement past RuboCop's
      # cyclomatic budget. Anonymous Prism subclasses are not expected.
      PRISM_DISPATCH = {
        # Literals
        Prism::IntegerNode => :type_of_literal_value,
        Prism::FloatNode => :type_of_literal_value,
        Prism::SymbolNode => :symbol_type_for,
        Prism::StringNode => :string_type_for,
        Prism::TrueNode => :type_of_true,
        Prism::FalseNode => :type_of_false,
        Prism::NilNode => :type_of_nil,
        # Locals
        Prism::LocalVariableReadNode => :local_read,
        Prism::LocalVariableWriteNode => :type_of_assignment_write,
        # Containers and pass-throughs
        Prism::ArrayNode => :array_type_for,
        Prism::ParenthesesNode => :parentheses_type_for,
        Prism::StatementsNode => :type_of_statements_node,
        Prism::ProgramNode => :type_of_program,
        # Calls
        Prism::CallNode => :call_type_for,
        Prism::ArgumentsNode => :type_of_non_value,
        # Constants
        Prism::ConstantReadNode => :type_of_constant_read,
        Prism::ConstantPathNode => :type_of_constant_path,
        Prism::ConstantWriteNode => :type_of_assignment_write,
        Prism::ConstantPathWriteNode => :type_of_assignment_write,
        Prism::ConstantOperatorWriteNode => :type_of_assignment_write,
        Prism::ConstantOrWriteNode => :type_of_assignment_write,
        Prism::ConstantAndWriteNode => :type_of_assignment_write,
        Prism::ConstantPathOperatorWriteNode => :type_of_assignment_write,
        Prism::ConstantPathOrWriteNode => :type_of_assignment_write,
        Prism::ConstantPathAndWriteNode => :type_of_assignment_write,
        # Self and instance/class/global variables
        Prism::SelfNode => :type_of_self_node,
        Prism::InstanceVariableReadNode => :type_of_instance_variable_read,
        Prism::InstanceVariableWriteNode => :type_of_assignment_write,
        Prism::InstanceVariableOperatorWriteNode => :type_of_assignment_write,
        Prism::InstanceVariableOrWriteNode => :type_of_assignment_write,
        Prism::InstanceVariableAndWriteNode => :type_of_assignment_write,
        Prism::ClassVariableReadNode => :type_of_class_variable_read,
        Prism::ClassVariableWriteNode => :type_of_assignment_write,
        Prism::ClassVariableOperatorWriteNode => :type_of_assignment_write,
        Prism::ClassVariableOrWriteNode => :type_of_assignment_write,
        Prism::ClassVariableAndWriteNode => :type_of_assignment_write,
        Prism::GlobalVariableReadNode => :type_of_global_variable_read,
        Prism::GlobalVariableWriteNode => :type_of_assignment_write,
        Prism::GlobalVariableOperatorWriteNode => :type_of_assignment_write,
        Prism::GlobalVariableOrWriteNode => :type_of_assignment_write,
        Prism::GlobalVariableAndWriteNode => :type_of_assignment_write,
        # Compound writes that share the .value rvalue protocol
        Prism::LocalVariableOperatorWriteNode => :type_of_assignment_write,
        Prism::LocalVariableOrWriteNode => :type_of_assignment_write,
        Prism::LocalVariableAndWriteNode => :type_of_assignment_write,
        Prism::IndexOperatorWriteNode => :type_of_assignment_write,
        Prism::IndexOrWriteNode => :type_of_assignment_write,
        Prism::IndexAndWriteNode => :type_of_assignment_write,
        Prism::MultiWriteNode => :type_of_assignment_write,
        Prism::LocalVariableTargetNode => :type_of_non_value,
        # Hashes and interpolation
        Prism::HashNode => :type_of_hash,
        Prism::KeywordHashNode => :type_of_hash,
        Prism::AssocNode => :type_of_non_value,
        Prism::AssocSplatNode => :type_of_non_value,
        Prism::InterpolatedStringNode => :type_of_interpolated_string,
        Prism::InterpolatedSymbolNode => :type_of_interpolated_symbol,
        Prism::EmbeddedStatementsNode => :type_of_embedded_statements,
        Prism::EmbeddedVariableNode => :type_of_dynamic_top,
        # Definitions
        Prism::DefNode => :type_of_def,
        Prism::ClassNode => :type_of_class_or_module,
        Prism::ModuleNode => :type_of_class_or_module,
        Prism::SingletonClassNode => :type_of_class_or_module,
        Prism::AliasMethodNode => :type_of_nil_value,
        Prism::AliasGlobalVariableNode => :type_of_nil_value,
        Prism::UndefNode => :type_of_nil_value,
        Prism::ForwardingSuperNode => :type_of_dynamic_top,
        Prism::BlockArgumentNode => :type_of_non_value,
        # Parameters and blocks (non-value positions)
        Prism::ParametersNode => :type_of_non_value,
        Prism::RequiredParameterNode => :type_of_non_value,
        Prism::OptionalParameterNode => :type_of_non_value,
        Prism::RequiredKeywordParameterNode => :type_of_non_value,
        Prism::OptionalKeywordParameterNode => :type_of_non_value,
        Prism::KeywordRestParameterNode => :type_of_non_value,
        Prism::RestParameterNode => :type_of_non_value,
        Prism::BlockParameterNode => :type_of_non_value,
        Prism::BlockParametersNode => :type_of_non_value,
        Prism::ForwardingParameterNode => :type_of_non_value,
        Prism::NoKeywordsParameterNode => :type_of_non_value,
        Prism::ImplicitRestNode => :type_of_non_value,
        Prism::BlockNode => :type_of_dynamic_top,
        Prism::SplatNode => :type_of_non_value,
        # Control flow (Slice 3 phase 1): branch types are unioned, jumps
        # type as Bot, loops type as Constant[nil].
        Prism::IfNode => :type_of_if,
        Prism::UnlessNode => :type_of_unless,
        Prism::ElseNode => :type_of_else,
        Prism::AndNode => :type_of_and_or,
        Prism::OrNode => :type_of_and_or,
        Prism::CaseNode => :type_of_case,
        Prism::CaseMatchNode => :type_of_case,
        Prism::WhenNode => :type_of_when_or_in,
        Prism::InNode => :type_of_when_or_in,
        Prism::BeginNode => :type_of_begin,
        Prism::RescueNode => :type_of_rescue,
        Prism::RescueModifierNode => :type_of_rescue_modifier,
        Prism::EnsureNode => :type_of_ensure,
        Prism::ReturnNode => :type_of_jump,
        Prism::BreakNode => :type_of_jump,
        Prism::NextNode => :type_of_jump,
        Prism::RetryNode => :type_of_jump,
        Prism::RedoNode => :type_of_jump,
        Prism::YieldNode => :type_of_dynamic_top,
        Prism::SuperNode => :type_of_dynamic_top,
        Prism::ForwardingArgumentsNode => :type_of_non_value,
        Prism::WhileNode => :type_of_loop,
        Prism::UntilNode => :type_of_loop,
        Prism::ForNode => :type_of_dynamic_top,
        Prism::DefinedNode => :type_of_dynamic_top,
        Prism::MatchPredicateNode => :type_of_dynamic_top,
        Prism::MatchRequiredNode => :type_of_dynamic_top,
        Prism::MatchWriteNode => :type_of_dynamic_top,
        # Literal containers
        Prism::LambdaNode => :type_of_lambda,
        Prism::RangeNode => :type_of_range,
        Prism::RegularExpressionNode => :type_of_regexp,
        Prism::InterpolatedRegularExpressionNode => :type_of_regexp
      }.freeze
      private_constant :PRISM_DISPATCH

      def initialize(scope:, tracer: nil)
        @scope = scope
        @tracer = tracer
      end

      def type_of(node)
        # Slice A-declarations. ScopeIndexer pre-fills
        # `scope.declared_types` for declaration-position nodes
        # (`module Foo` / `class Bar` headers) with the qualified
        # `Singleton` type so the header itself does not fall
        # through to `Dynamic[Top]`. The override is consulted
        # before any other dispatch and bypasses fail-soft
        # tracing on a recognised match.
        declared = scope.declared_types[node]
        return declared if declared

        return type_of_virtual(node) if node.is_a?(AST::Node)

        handler = PRISM_DISPATCH[node.class]
        return send(handler, node) if handler

        fallback_for(node, family: :prism)
      end

      private

      attr_reader :scope, :tracer

      def dynamic_top
        Type::Combinator.untyped
      end

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

      # All `*WriteNode` flavours expose a `.value` rvalue child. Their type
      # is the type of that rvalue. Binding the result back into the scope
      # is the responsibility of the statement-level evaluator (Slice 3),
      # never of `type_of` itself.
      def type_of_assignment_write(node)
        type_of(node.value)
      end

      # Slice 7 phase 1 — instance/class/global variable reads.
      # Each lookup returns the type currently bound in the
      # surrounding scope's per-kind binding map (populated by
      # `StatementEvaluator` write handlers within the same
      # method body), falling through to `Dynamic[Top]` when no
      # binding is recorded. Cross-method ivar/cvar inference is
      # a follow-up slice; the read handlers MUST NOT raise on a
      # missing binding and MUST NOT record a fallback event in
      # either branch — the absence of a binding is a recognised
      # semantic outcome, not a fail-soft compromise.
      def type_of_instance_variable_read(node)
        scope.ivar(node.name) || dynamic_top
      end

      def type_of_class_variable_read(node)
        scope.cvar(node.name) || dynamic_top
      end

      def type_of_global_variable_read(node)
        scope.global(node.name) || dynamic_top
      end

      def type_of_statements_node(node)
        statements_type_for(node)
      end

      def type_of_program(node)
        statements_type_for(node.statements)
      end

      # Recognised position that does not produce a value: parameter lists
      # and individual parameter declarations, splats inside argument
      # lists, key-value pairs in hashes, and the implicit-rest token
      # inside destructuring. Returning Dynamic[Top] silently keeps these
      # off the unrecognised list without faking a value type.
      def type_of_non_value(_node)
        dynamic_top
      end

      # Recognised value-bearing position the Slice 2 engine does not yet
      # narrow: self, instance/class/global variable reads, block bodies.
      # Slice 3+ refines these in place; for now we acknowledge the node
      # class so the coverage scanner stops flagging it without recording
      # a fail-soft event for every occurrence.
      # Slice A-engine. `Prism::SelfNode` resolves to the scope's
      # `self_type` when one has been injected (by
      # `StatementEvaluator` at class-body and method-body
      # boundaries) or `Dynamic[Top]` at the top level. Class-body
      # `self` is `Singleton[<class>]`; instance-method `self` is
      # `Nominal[<class>]`; singleton-method `self` is
      # `Singleton[<class>]`.
      def type_of_self_node(_node)
        scope.self_type || dynamic_top
      end

      def type_of_dynamic_top(_node)
        dynamic_top
      end

      # The expression `Foo` evaluates to the *class object* `Foo`, not
      # an instance. From Slice 4 phase 2b on we therefore type a
      # bare-constant reference as `Singleton[Foo]`; method dispatch on
      # that receiver looks up class methods (`Foo.new`, `Foo.bar`, ...).
      #
      # Slice A constant-walk: when the literal name does not resolve,
      # we try a lexical walk based on the surrounding class context
      # exposed through `scope.self_type` so a reference like
      # `Inference::FallbackTracer` from inside `Rigor::CLI::Foo`
      # resolves to `Rigor::Inference::FallbackTracer`.
      def type_of_constant_read(node)
        resolve_constant_name(node.name.to_s) || fallback_for(node, family: :prism)
      end

      def type_of_constant_path(node)
        full_name = build_constant_path_name(node)
        return fallback_for(node, family: :prism) if full_name.nil?

        resolve_constant_name(full_name) || fallback_for(node, family: :prism)
      end

      # Try the literal name first, then walk Ruby's lexical lookup by
      # progressively prefixing the surrounding class path (peeled
      # one `::segment` at a time). For each candidate the lookup
      # consults `Environment#singleton_for_name` (a class object)
      # and then `Environment#constant_for_name` (a non-class
      # constant value such as `BUCKETS: Array[Symbol]`).
      # Returns the matched `Rigor::Type` or nil; the caller decides
      # whether to fall back.
      def resolve_constant_name(name)
        env = scope.environment
        discovered = scope.discovered_classes
        in_source = scope.in_source_constants
        lexical_constant_candidates(name).each do |candidate|
          singleton = env.singleton_for_name(candidate)
          return singleton if singleton

          in_source_class = discovered[candidate]
          return in_source_class if in_source_class

          # In-source value-bearing constants take precedence
          # over RBS constant decls because user code is the
          # authoritative source for its own constants.
          in_source_value = in_source[candidate]
          return in_source_value if in_source_value

          value = env.constant_for_name(candidate)
          return value if value
        end
        nil
      end

      # The candidate qualified names to try, in Ruby's lexical
      # order: most-qualified first (the surrounding class path
      # joined to `name`), then progressively less-qualified, then
      # the bare `name`. Top-level scopes (no `self_type`) yield
      # only `[name]`, preserving the pre-walk behaviour.
      def lexical_constant_candidates(name)
        prefix = enclosing_class_path
        candidates = []
        while prefix && !prefix.empty?
          candidates << "#{prefix}::#{name}"
          prefix = prefix.rpartition("::").first
          prefix = nil if prefix.empty?
        end
        candidates << name
        candidates
      end

      # Pulls the enclosing qualified class name out of
      # `scope.self_type` when one is set. `Nominal[T]` and
      # `Singleton[T]` both expose `class_name`. Returns nil when
      # no class context is available (top-level).
      def enclosing_class_path
        st = scope.self_type
        case st
        when Type::Nominal, Type::Singleton then st.class_name
        end
      end

      # Builds the dotted-colon name for a `Foo`, `Foo::Bar`, or `::Foo`
      # path. Returns nil when an inner segment is not itself a constant
      # reference (for example `expr::Foo`), so the caller can fall back.
      def build_constant_path_name(node)
        case node
        when Prism::ConstantReadNode
          node.name.to_s
        when Prism::ConstantPathNode
          parent = node.parent
          return node.name.to_s if parent.nil?

          parent_name = build_constant_path_name(parent)
          return nil if parent_name.nil?

          "#{parent_name}::#{node.name}"
        end
      end

      # Slice 5 phase 1 upgrades hash literals to `HashShape{...}`
      # when every entry is a static `AssocNode` whose key is a
      # `SymbolNode` or `StringNode` with a known value (covering the
      # `{ a: 1, "b" => 2 }` pattern and falling back to the generic
      # `Hash[K, V]` form otherwise). Splatted entries
      # (`{ **other }`) and dynamic keys widen to the underlying
      # `Hash[K, V]` form by unioning the types each entry exposes;
      # when no concrete pair survives we fall back to the raw `Hash`
      # so callers stay backward compatible.
      def type_of_hash(node)
        elements = node.respond_to?(:elements) ? node.elements : []
        return Type::Combinator.nominal_of(Hash) if elements.empty?

        shape = static_hash_shape_for(elements)
        return shape if shape

        keys, values = generic_hash_pairs_for(elements)
        return Type::Combinator.nominal_of(Hash) if keys.empty? || values.empty?

        Type::Combinator.nominal_of(
          Hash,
          type_args: [Type::Combinator.union(*keys), Type::Combinator.union(*values)]
        )
      end

      # Builds `HashShape{...}` when every entry is an `AssocNode`
      # whose key is a static Symbol or String literal. Returns nil
      # otherwise so the caller falls back to the generic shape.
      def static_hash_shape_for(elements)
        pairs = {}
        elements.each do |entry|
          return nil unless entry.is_a?(Prism::AssocNode)

          key = static_hash_key(entry.key)
          return nil if key.nil?
          return nil if pairs.key?(key)

          pairs[key] = type_of(entry.value)
        end
        return nil if pairs.empty?

        Type::Combinator.hash_shape_of(pairs)
      end

      # Returns the static (Symbol|String) literal carried by a hash
      # key node, or nil when the key is dynamic. We only treat
      # SymbolNode#value and StringNode#unescaped as static when they
      # are non-nil (interpolation produces a nil unescaped).
      def static_hash_key(node)
        case node
        when Prism::SymbolNode
          raw = node.value
          raw&.to_sym
        when Prism::StringNode
          node.unescaped
        end
      end

      def generic_hash_pairs_for(elements)
        keys = []
        values = []
        elements.each do |entry|
          next unless entry.is_a?(Prism::AssocNode)

          keys << type_of(entry.key)
          values << type_of(entry.value)
        end
        [keys, values]
      end

      def type_of_interpolated_string(_node)
        Type::Combinator.nominal_of(String)
      end

      def type_of_interpolated_symbol(_node)
        Type::Combinator.nominal_of(Symbol)
      end

      def type_of_embedded_statements(node)
        statements_type_for(node.statements)
      end

      def type_of_def(node)
        Type::Combinator.constant_of(node.name)
      end

      # `class Foo; body; end`, `module Foo; body; end`, and `class << x;
      # body; end` evaluate to the value of the body's last expression,
      # or `nil` when the body is empty. We do not track class/module
      # scope yet, so the body is typed in the surrounding scope and
      # that result is returned.
      def type_of_class_or_module(node)
        body = node.body
        return Type::Combinator.constant_of(nil) if body.nil?

        type_of(body)
      end

      # `alias x y`, `alias $x $y`, and `undef foo` all evaluate to nil at
      # runtime; the constant carrier captures that exactly.
      def type_of_nil_value(_node)
        Type::Combinator.constant_of(nil)
      end

      # `if c; t; (elsif c2; ...; )* else; e; end`. Prism nests `elsif`
      # branches as `IfNode#subsequent`. Slice 3 phase 1 types both
      # branches in the receiver scope and returns their union; scope
      # rebinding is the StatementEvaluator's job (Slice 3 phase 2).
      # Without an else clause the branch's implicit value is nil, which
      # is included in the union.
      #
      # v0.0.6 — when the predicate folds to a `Type::Constant` whose
      # value is Ruby-truthy (resp. Ruby-falsey), the unreachable
      # branch is elided so the if-expression's type is the live
      # branch alone. Statement-level branch elision lives in
      # `StatementEvaluator#eval_if`; this handler covers the
      # expression-position ternary form (`a ? b : c`) and any
      # `if`/`unless` reached through `type_of`.
      def type_of_if(node)
        then_type = statements_or_nil(node.statements)
        else_type = if_else_type(node.subsequent)
        elide_or_union(node.predicate, then_type, else_type)
      end

      # `unless c; t; else; e; end`. Prism uses `else_clause` here (no
      # `elsif` chain). Branch-elision logic mirrors `type_of_if`,
      # inverted: a truthy predicate selects the else branch.
      def type_of_unless(node)
        then_type = statements_or_nil(node.statements)
        else_type = if_else_type(node.else_clause)
        elide_or_union(node.predicate, else_type, then_type)
      end

      def if_else_type(subsequent)
        return Type::Combinator.constant_of(nil) if subsequent.nil?

        type_of(subsequent)
      end

      # Routes the predicate's typed value through branch elision.
      # `live_when_truthy` and `live_when_falsey` are the branch
      # types selected by the predicate's polarity; the names
      # match `IfNode` semantics directly and invert at the
      # `type_of_unless` call site.
      def elide_or_union(predicate, live_when_truthy, live_when_falsey)
        case constant_predicate_polarity(predicate)
        when :truthy then live_when_truthy
        when :falsey then live_when_falsey
        else Type::Combinator.union(live_when_truthy, live_when_falsey)
        end
      end

      # Returns `:truthy`, `:falsey`, or `nil` for an arbitrary
      # predicate expression. Only `Type::Constant` answers
      # decisively — `Union[true, false]`, `Nominal[bool]`, and
      # `Dynamic[T]` keep both branches live.
      def constant_predicate_polarity(predicate)
        return nil if predicate.nil?

        type = type_of(predicate)
        return nil unless type.is_a?(Type::Constant)

        type.value ? :truthy : :falsey
      end

      def type_of_else(node)
        statements_or_nil(node.statements)
      end

      # `a && b` and `a || b` short-circuit at the value level:
      # `a && b` returns `a` when `a` is falsey, else `b`.
      # `a || b` returns `a` when `a` is truthy,  else `b`.
      #
      # v0.0.6 — when the left operand folds to a `Type::Constant`,
      # we know which side actually flows through, so the result
      # is one operand's type instead of a union. Otherwise the
      # union-of-both-operands fallback is preserved.
      def type_of_and_or(node)
        left_type = type_of(node.left)
        polarity = constant_value_polarity(left_type)
        return short_circuit_for(node, left_type, polarity) if polarity

        Type::Combinator.union(left_type, type_of(node.right))
      end

      def short_circuit_for(node, left_type, polarity)
        and_node = node.is_a?(Prism::AndNode)
        if polarity == :truthy
          and_node ? type_of(node.right) : left_type
        else
          and_node ? left_type : type_of(node.right)
        end
      end

      # Returns `:truthy` / `:falsey` for a `Type::Constant`,
      # nil otherwise. Mirrors `constant_predicate_polarity` but
      # operates on a typed value (already-type-of'd) rather
      # than a Prism node, so the same predicate analysis can
      # be reused in both contexts.
      def constant_value_polarity(type)
        return nil unless type.is_a?(Type::Constant)

        type.value ? :truthy : :falsey
      end

      def type_of_case(node)
        branch_types = node.conditions.map { |branch| type_of(branch) }
        else_type =
          if node.else_clause
            type_of(node.else_clause)
          else
            Type::Combinator.constant_of(nil)
          end
        Type::Combinator.union(*branch_types, else_type)
      end

      # `when` clauses for `case` and `in` clauses for `case ... in` have
      # the same body shape; we reuse one handler for both Prism node
      # classes.
      def type_of_when_or_in(node)
        statements_or_nil(node.statements)
      end

      # `begin; body; rescue R => e; r1; rescue; r2; else; e; ensure; f; end`.
      # The result is the union of every value-producing branch: the body
      # (or the else-clause when present, since it replaces the body's
      # value when no exception fires), plus each rescue body in the
      # rescue chain. The ensure clause runs but does not contribute to
      # the begin's value.
      def type_of_begin(node)
        rescue_clause = node.rescue_clause
        else_clause = node.else_clause

        primary_type =
          if else_clause
            type_of(else_clause)
          elsif node.statements
            statements_or_nil(node.statements)
          else
            Type::Combinator.constant_of(nil)
          end

        rescue_types = rescue_chain_types(rescue_clause)
        Type::Combinator.union(primary_type, *rescue_types)
      end

      def rescue_chain_types(rescue_node)
        types = []
        current = rescue_node
        while current
          types << statements_or_nil(current.statements)
          current = current.subsequent
        end
        types
      end

      def type_of_rescue(node)
        statements_or_nil(node.statements)
      end

      # `expr rescue fallback` is RescueModifierNode in Prism. The result
      # is `expr`'s type when no exception is raised and `fallback`'s
      # type otherwise; both paths are reachable, so the result is their
      # union.
      def type_of_rescue_modifier(node)
        Type::Combinator.union(type_of(node.expression), type_of(node.rescue_expression))
      end

      def type_of_ensure(node)
        statements_or_nil(node.statements)
      end

      # `return`, `break`, `next`, `retry`, and `redo` all transfer
      # control instead of producing a value. Their type is Bot, the
      # empty type that absorbs cleanly under union (e.g.
      # `Constant[1] | Bot == Constant[1]`), so the surrounding
      # control-flow handlers collapse correctly when one branch jumps.
      def type_of_jump(_node)
        Type::Combinator.bot
      end

      # `while` and `until` loops produce nil unless interrupted by
      # `break VALUE`, which Slice 3 phase 1 does not yet model.
      # Returning Constant[nil] is safe and matches Ruby semantics for
      # the common case.
      def type_of_loop(_node)
        Type::Combinator.constant_of(nil)
      end

      def type_of_lambda(_node)
        Type::Combinator.nominal_of(Proc)
      end

      def type_of_range(node)
        left_static, left = static_range_endpoint(node.left)
        right_static, right = static_range_endpoint(node.right)
        return Type::Combinator.nominal_of(Range) unless left_static && right_static

        Type::Combinator.constant_of(Range.new(left, right, node.exclude_end?))
      end

      def type_of_regexp(_node)
        Type::Combinator.nominal_of(Regexp)
      end

      def static_range_endpoint(node)
        return [true, nil] if node.nil?
        return [true, node.value] if node.is_a?(Prism::IntegerNode)

        [false, nil]
      end

      # Helper for the many control-flow handlers that read a body
      # `Prism::StatementsNode` or treat its absence as nil. Note that
      # Prism uses nil (rather than an empty `StatementsNode`) for
      # missing bodies in many node kinds.
      def statements_or_nil(statements_node)
        return Type::Combinator.constant_of(nil) if statements_node.nil?

        statements_type_for(statements_node)
      end

      def type_of_virtual(node)
        case node
        when AST::TypeNode then node.type
        else
          fallback_for(node, family: :virtual)
        end
      end

      def fallback_for(node, family:)
        inner = dynamic_top
        record_fallback(node, family: family, inner_type: inner)
        inner
      end

      def record_fallback(node, family:, inner_type:)
        return unless tracer

        location = node.respond_to?(:location) ? node.location : nil
        event = Fallback.new(
          node_class: node.class,
          location: location,
          family: family,
          inner_type: inner_type
        )
        tracer.record_fallback(event)
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

      def local_read(node)
        scope.local(node.name) || dynamic_top
      end

      # Slice 5 phase 1 upgrades array literals to `Tuple[T1..Tn]`
      # when every element is a non-splat value. Splatted entries
      # (`[*xs, 1]`) preserve the Slice 4 phase 2d behavior: we union
      # the contributed element types and emit
      # `Nominal[Array, [union]]`. An empty literal stays as the raw
      # `Array` (no element evidence to lock either an arity or an
      # element type).
      def array_type_for(node)
        elements = node.elements
        return Type::Combinator.nominal_of(Array) if elements.empty?

        if elements.any?(Prism::SplatNode)
          element_types = elements.map { |e| type_of(e) }
          element_union = Type::Combinator.union(*element_types)
          return Type::Combinator.nominal_of(Array, type_args: [element_union])
        end

        Type::Combinator.tuple_of(*elements.map { |e| type_of(e) })
      end

      def parentheses_type_for(node)
        body = node.body
        return Type::Combinator.constant_of(nil) if body.nil?

        type_of(body)
      end

      def statements_type_for(statements_node)
        return Type::Combinator.constant_of(nil) if statements_node.nil?

        body = statements_node.body
        return Type::Combinator.constant_of(nil) if body.empty?

        type_of(body.last)
      end

      # Slice 2 routes call expressions through `MethodDispatcher`. The
      # receiver and every argument are typed first, then the dispatcher is
      # asked for a result type. A nil result triggers the fail-soft fallback
      # for the CallNode itself (the inner type_of calls already record
      # their own fallbacks for unrecognised receivers/args, so the tracer
      # captures both the immediate dispatch miss and the deeper cause).
      # rubocop:disable Metrics/CyclomaticComplexity
      def call_type_for(node)
        receiver = call_receiver_type_for(node)
        arg_types = call_arg_types(node)
        block_type = block_return_type_for(node, receiver, arg_types)

        # v0.0.3 A — implicit-self calls prefer a same-named
        # top-level `def` over RBS dispatch. Without this,
        # a helper like `def select(...)` defined inside an
        # `RSpec.describe ... do ... end` block mis-routes
        # through `Enumerable#select` / `Object#select` and
        # the caller observes `Array[Elem]` instead of the
        # helper's actual return type. The check fires only
        # for `node.receiver.nil?` (true implicit self), so
        # explicit-receiver dispatch is unaffected.
        local_def = node.receiver.nil? ? scope.top_level_def_for(node.name) : nil
        if local_def
          local_inference = infer_top_level_user_method(local_def, receiver, arg_types)
          return local_inference if local_inference

          # The local def matches by name but the
          # parameter shape is too complex for the first-
          # iteration binder (kwargs / optionals / rest).
          # Returning `Dynamic[Top]` is the safest answer:
          # we know RBS dispatch would be wrong (the
          # method is user-defined and shadows whatever
          # ancestor method the dispatch would find), and
          # `Dynamic[Top]` propagates correctly through
          # downstream call chains without surfacing
          # misleading false-positive diagnostics.
          return dynamic_top
        end

        # v0.0.6 phase 2 — per-element block fold for Tuple
        # receivers. When `[a, b, c].map { |x| f(x) }` and the
        # receiver is a `Tuple` carrier with finite elements,
        # type the block body once per position with the
        # corresponding element bound to the block parameter
        # and assemble the results into a `Tuple[U_1..U_n]`.
        # This sits ahead of `MethodDispatcher.dispatch` so
        # the RBS tier does not re-widen the answer back to
        # `Array[union]`.
        per_element = try_per_element_block_fold(node, receiver)
        return per_element if per_element

        result = MethodDispatcher.dispatch(
          receiver_type: receiver,
          method_name: node.name,
          arg_types: arg_types,
          block_type: block_type,
          environment: scope.environment
        )
        return result if result

        # v0.0.2 #5 — inter-procedural inference for
        # user-defined methods. When dispatch misses but the
        # receiver is a user class with a `def` body, re-type
        # the body with the call's argument types bound and
        # return the body's last-expression type.
        user_inference = try_user_method_inference(receiver, node, arg_types)
        return user_inference if user_inference

        # Dynamic-origin propagation: when the receiver is Dynamic[T] and
        # no positive rule resolves the call, the result inherits the
        # dynamic origin. Per the value-lattice algebra, this is a
        # recognised semantic outcome, not a fail-soft compromise, so it
        # MUST NOT record a tracer event.
        return dynamic_top if receiver.is_a?(Type::Dynamic)

        fallback_for(node, family: :prism)
      end
      # rubocop:enable Metrics/CyclomaticComplexity

      # v0.0.2 #5 — re-types the body of a user-defined
      # instance method with the call site's argument types
      # bound to the method's parameters. Used as a
      # last-resort tier after `MethodDispatcher.dispatch`
      # has exhausted its catalogue (RBS, shape, constant
      # folding, user-class fallback). Returns nil when:
      #
      # - the receiver is not `Nominal[T]` for some T;
      # - no def_node is recorded for that class/method
      #   (the receiver is foreign or has only an RBS sig);
      # - the def has no body, or has a parameter shape we
      #   cannot bind from the call's positional args;
      # - the inference is already in progress for this
      #   (class, method, signature) tuple — recursion
      #   safety net.
      # v0.0.3 A — re-types a top-level (or DSL-block-nested)
      # `def` discovered by `ScopeIndexer` under the
      # `TOP_LEVEL_DEF_KEY` sentinel. Mirrors the
      # `infer_user_method_return` shape but uses the
      # current `scope.self_type` (or implicit `Object`)
      # as the receiver carrier so the body's own self is
      # consistent with the call site's. Returns nil when
      # the parameter shape disqualifies the def, when the
      # body is empty, or when a recursion cycle is
      # detected.
      def infer_top_level_user_method(def_node, receiver, arg_types)
        infer_user_method_return(def_node, receiver, arg_types)
      rescue StandardError
        nil
      end

      def try_user_method_inference(receiver, call_node, arg_types)
        return nil unless receiver.is_a?(Type::Nominal)

        def_node = scope.user_def_for(receiver.class_name, call_node.name)
        return nil if def_node.nil?

        infer_user_method_return(def_node, receiver, arg_types)
      rescue StandardError
        nil
      end

      INFERENCE_GUARD_KEY = :__rigor_user_method_inference_stack__
      private_constant :INFERENCE_GUARD_KEY

      def infer_user_method_return(def_node, receiver, arg_types)
        return nil if def_node.body.nil?

        body_scope = build_user_method_body_scope(def_node, receiver, arg_types)
        return nil if body_scope.nil?

        # Recursion-guard signature. Uses `describe(:short)`
        # so non-Nominal receivers (e.g. the implicit
        # `Object` carrier used for top-level / DSL-block
        # defs in v0.0.3 A) can participate without raising.
        signature = [receiver.describe(:short), def_node.name, arg_types.map { |t| t.describe(:short) }]
        stack = (Thread.current[INFERENCE_GUARD_KEY] ||= [])
        return Type::Combinator.untyped if stack.include?(signature)

        stack.push(signature)
        begin
          type, _post = body_scope.evaluate(def_node.body)
          type
        ensure
          stack.pop
        end
      end

      # Builds the body scope for a user-defined instance
      # method call: a fresh `Scope` with `self_type` set to
      # the receiver's nominal type, the project-wide
      # accumulators inherited (so the body sees the same
      # `discovered_classes` / `class_ivars` / etc. the
      # caller does), and required positional parameters
      # bound from the call's `arg_types` by index. Returns
      # nil when the parameter shape is too complex for the
      # first-iteration binder (rest args, keyword args,
      # block params, etc.).
      def build_user_method_body_scope(def_node, receiver, arg_types) # rubocop:disable Metrics/AbcSize
        params = def_node.parameters
        required = params&.requireds || []
        return nil unless params.nil? || user_method_param_shape_simple?(params)
        return nil unless required.size == arg_types.size

        fresh = Scope.empty(environment: scope.environment)
                     .with_declared_types(scope.declared_types)
                     .with_discovered_classes(scope.discovered_classes)
                     .with_in_source_constants(scope.in_source_constants)
                     .with_class_ivars(scope.class_ivars)
                     .with_class_cvars(scope.class_cvars)
                     .with_program_globals(scope.program_globals)
                     .with_discovered_methods(scope.discovered_methods)
                     .with_discovered_def_nodes(scope.discovered_def_nodes)
                     .with_self_type(receiver)

        required.each_with_index do |param, index|
          fresh = fresh.with_local(param.name, arg_types[index])
        end
        fresh
      end

      # First iteration accepts only required positional
      # parameters: `def foo(a, b, c)`. Optionals, rest,
      # keyword params, and block params disqualify the
      # method from inference (the caller observes
      # `Dynamic[Top]` instead).
      def user_method_param_shape_simple?(params)
        return false unless params.is_a?(Prism::ParametersNode)

        params.optionals.empty? &&
          params.rest.nil? &&
          params.keywords.empty? &&
          params.keyword_rest.nil? &&
          params.block.nil?
      end

      # Slice A-engine. Implicit-self calls (no `node.receiver`)
      # adopt the surrounding scope's `self_type` as their receiver
      # so calls like `attr_reader_method_name` or
      # `private_helper(...)` inside an instance method dispatch
      # against the enclosing class. Slice 7 phase 10 — when
      # `self_type` is nil (top-level program), the receiver
      # MUST default to `Nominal[Object]` so Kernel intrinsics
      # like `require`, `require_relative`, `raise`, and `puts`
      # dispatch through Object/Kernel rather than falling through
      # to `Dynamic[Top]`.
      def call_receiver_type_for(node)
        return type_of(node.receiver) if node.receiver

        scope.self_type || implicit_top_level_self
      end

      def implicit_top_level_self
        scope.environment.nominal_for_name("Object") || dynamic_top
      end

      def call_arg_types(node)
        arguments_node = node.arguments
        return [] if arguments_node.nil?

        arguments_node.arguments.map { |argument| type_of(argument) }
      end

      # When the call carries a `Prism::BlockNode`, build the block's
      # entry scope (outer locals plus parameter bindings driven by
      # the receiving method's RBS signature), type the block body
      # under that scope, and return the body's value type. The
      # result feeds `MethodDispatcher.dispatch`'s `block_type:` so
      # generic methods like `Array#map[U] { (Elem) -> U } -> Array[U]`
      # resolve `U` to the block's return type. Returns `nil` when
      # the call has no block, when the receiver is unknown, or
      # when typing the body raises (defensive against malformed
      # subtrees); the dispatcher then runs in its no-block-aware
      # path.
      def block_return_type_for(call_node, receiver_type, arg_types)
        block_node = call_node.block
        return nil unless block_node.is_a?(Prism::BlockNode)
        return nil if receiver_type.nil?

        expected = MethodDispatcher.expected_block_param_types(
          receiver_type: receiver_type,
          method_name: call_node.name,
          arg_types: arg_types,
          environment: scope.environment
        )
        bindings = BlockParameterBinder.new(expected_param_types: expected).bind(block_node)
        block_scope = bindings.reduce(scope) { |acc, (name, type)| acc.with_local(name, type) }
        type_block_body(block_node, block_scope)
      rescue StandardError
        nil
      end

      def type_block_body(block_node, block_scope)
        body = block_node.body
        return Type::Combinator.constant_of(nil) if body.nil?

        block_scope.type_of(body)
      end

      # v0.0.6 phase 2 — per-element block fold for Tuple
      # receivers under `:map` / `:collect`. Walks every Tuple
      # position, binds the block parameter to that element's
      # type, and re-types the block body. The per-position
      # results are assembled into `Tuple[U_1..U_n]`, strictly
      # tighter than the RBS-projected `Array[union]`.
      #
      # Declines (returns nil) when the receiver is not a
      # `Tuple` with at least one element, when the call has
      # no `Prism::BlockNode`, when the method is outside the
      # supported set, when block typing raises mid-loop, or
      # when the block has no body. The decline path leaves
      # the dispatch chain untouched.
      PER_ELEMENT_TUPLE_METHODS = Set[:map, :collect, :filter_map].freeze
      private_constant :PER_ELEMENT_TUPLE_METHODS

      # rubocop:disable Metrics/CyclomaticComplexity
      def try_per_element_block_fold(call_node, receiver_type)
        return nil unless PER_ELEMENT_TUPLE_METHODS.include?(call_node.name)
        return nil unless receiver_type.is_a?(Type::Tuple)
        return nil if receiver_type.elements.empty?

        block_node = call_node.block
        return nil unless block_node.is_a?(Prism::BlockNode)

        per_position = receiver_type.elements.map do |element_type|
          type_block_body_with_param(block_node, [element_type])
        end
        return nil if per_position.any?(&:nil?)

        assemble_per_element_result(call_node.name, per_position)
      end
      # rubocop:enable Metrics/CyclomaticComplexity

      def assemble_per_element_result(method_name, per_position)
        case method_name
        when :map, :collect then Type::Combinator.tuple_of(*per_position)
        when :filter_map then assemble_filter_map_result(per_position)
        end
      end

      # `filter_map` folds tightly only when every per-position
      # result is a `Constant`: positions whose value is `nil`
      # or `false` drop, the rest survive in declaration order.
      # When any position is non-Constant the dispatcher
      # declines (returns nil) so the RBS tier widens to
      # `Array[U]`.
      def assemble_filter_map_result(per_position)
        return nil unless per_position.all?(Type::Constant)

        kept = per_position.reject { |type| type.value.nil? || type.value == false }
        Type::Combinator.tuple_of(*kept)
      end

      def type_block_body_with_param(block_node, expected_param_types)
        bindings = BlockParameterBinder.new(expected_param_types: expected_param_types).bind(block_node)
        block_scope = bindings.reduce(scope) { |acc, (name, type)| acc.with_local(name, type) }
        type_block_body(block_node, block_scope)
      rescue StandardError
        nil
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
