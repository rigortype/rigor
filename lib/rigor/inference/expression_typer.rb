# frozen_string_literal: true

require "prism"

require_relative "../type"
require_relative "../ast"
require_relative "../analysis/self_call_resolution_recorder"
require_relative "block_parameter_binder"
require_relative "budget_trace"
require_relative "fallback"
require_relative "flow_tracer"
require_relative "indexed_narrowing"
require_relative "macro_block_self_type"
require_relative "method_dispatcher"
require_relative "narrowing"

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
        # `1i` / `2.5ri` lift via `node.value` which is already a
        # `Complex` Ruby value; same for `1r` / `1.5r` whose
        # value is a `Rational`. `Type::Constant` accepts both
        # via `SCALAR_CLASSES`.
        Prism::ImaginaryNode => :type_of_literal_value,
        Prism::RationalNode => :type_of_literal_value,
        Prism::SymbolNode => :symbol_type_for,
        Prism::StringNode => :string_type_for,
        Prism::XStringNode => :type_of_xstring,
        Prism::InterpolatedXStringNode => :type_of_xstring,
        Prism::SourceFileNode => :type_of_source_file,
        Prism::SourceLineNode => :type_of_source_line,
        Prism::TrueNode => :type_of_true,
        Prism::FalseNode => :type_of_false,
        Prism::NilNode => :type_of_nil,
        # Locals
        Prism::LocalVariableReadNode => :local_read,
        Prism::ItLocalVariableReadNode => :it_read,
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
        # Compound writes that share the `.value` rvalue accessor
        Prism::LocalVariableOperatorWriteNode => :type_of_assignment_write,
        Prism::LocalVariableOrWriteNode => :type_of_assignment_write,
        Prism::LocalVariableAndWriteNode => :type_of_assignment_write,
        Prism::IndexOperatorWriteNode => :type_of_assignment_write,
        Prism::IndexOrWriteNode => :type_of_assignment_write,
        Prism::IndexAndWriteNode => :type_of_assignment_write,
        Prism::MultiWriteNode => :type_of_assignment_write,
        # LHS-only target nodes (destructuring assignment, pattern matching,
        # `for x in xs`, block parameter `|a, (b, c)|`). They have no value
        # to extract — the type-of pass acknowledges the node class so the
        # coverage scanner stops flagging it; binding the inner names back
        # into the scope is the StatementEvaluator / MultiTargetBinder /
        # BlockParameterBinder side's concern.
        Prism::LocalVariableTargetNode => :type_of_non_value,
        Prism::MultiTargetNode => :type_of_non_value,
        Prism::InstanceVariableTargetNode => :type_of_non_value,
        Prism::ClassVariableTargetNode => :type_of_non_value,
        Prism::GlobalVariableTargetNode => :type_of_non_value,
        Prism::ConstantTargetNode => :type_of_non_value,
        Prism::ConstantPathTargetNode => :type_of_non_value,
        Prism::CallTargetNode => :type_of_non_value,
        Prism::IndexTargetNode => :type_of_non_value,
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
        Prism::PostExecutionNode => :type_of_nil_value,
        Prism::ShareableConstantNode => :type_of_shareable_constant,
        Prism::ImplicitNode => :type_of_implicit,
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
        Prism::ItParametersNode => :type_of_non_value,
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
        Prism::DefinedNode => :type_of_defined,
        Prism::NumberedReferenceReadNode => :type_of_numbered_reference,
        Prism::BackReferenceReadNode => :type_of_back_reference,
        Prism::MatchPredicateNode => :type_of_match_predicate,
        Prism::MatchRequiredNode => :type_of_match_required,
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
        return untraced_type_of(node) unless FlowTracer.active?

        # `rigor trace` — bracket the recursion with enter/result events.
        # The tracer is observational only: the inferred type flows
        # through unchanged (see FlowTracer's contract).
        FlowTracer.trace_node(node) { untraced_type_of(node) }
      end

      def untraced_type_of(node)
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

      # `defined?(expr)` returns `String | nil` per Ruby semantics —
      # a description of the expression's category (`"local-variable"`,
      # `"method"`, ...) when defined, or `nil` when not. The argument
      # is not evaluated (it is statically inspected by the runtime),
      # so the typer does not recurse into it.
      def type_of_defined(_node)
        Type::Combinator.union(
          Type::Combinator.nominal_of("String"),
          Type::Combinator.constant_of(nil)
        )
      end

      # `$1`, `$&`, `$'`, `$+`, `$\`` — the regex back-reference and
      # numbered-capture globals each carry `String | nil`. They share
      # the typer because the typing rule is identical regardless of
      # which back-reference shape Prism emitted.
      def type_of_string_or_nil(_node)
        Type::Combinator.union(
          Type::Combinator.nominal_of("String"),
          Type::Combinator.constant_of(nil)
        )
      end

      # `$1` / `$2` / ... — numbered match-data globals. When the
      # narrowing tier has bound a tighter type for this number
      # (typically `String` after a `=~`-success guard like `unless
      # /(\d+)/ =~ s; raise; end`), prefer the scope-bound type.
      # Falls back to the default `String | nil`.
      def type_of_numbered_reference(node)
        scope.global(:"$#{node.number}") || type_of_string_or_nil(node)
      end

      # `$&` / `$'` / `$\`` / `$+` — symbolic back-references. Same
      # narrowing model as numbered references.
      def type_of_back_reference(node)
        scope.global(node.name) || type_of_string_or_nil(node)
      end

      # `expr in pattern` — pattern-match predicate. Returns `true`
      # when the pattern matches, `false` otherwise.
      def type_of_match_predicate(_node)
        Type::Combinator.union(
          Type::Combinator.constant_of(true),
          Type::Combinator.constant_of(false)
        )
      end

      # `expr => pattern` — one-line pattern-match assertion. Raises
      # `NoMatchingPatternError` on mismatch; on success the expression
      # itself evaluates to `nil`.
      def type_of_match_required(_node)
        Type::Combinator.constant_of(nil)
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
          # Strip the last `::` segment without `rpartition`'s throwaway
          # 3-element array + extra substrings (this loop is the sole
          # caller of the `String#rpartition` allocation seen in the
          # profile): `rindex` + slice gives the same prefix, or nil.
          idx = prefix.rindex("::")
          prefix = idx ? prefix[0, idx] : nil
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
        # v0.0.7 — `{}` resolves to the empty `HashShape{}` carrier
        # rather than `Nominal[Hash]`, mirroring the v0.0.6 empty-
        # array literal change. Both forms erase to plain `Hash`,
        # but `HashShape{}` pins the literal's known size (zero)
        # so HashShape projections (`empty?`, `first`, `count`,
        # …) fold against it.
        return Type::Combinator.hash_shape_of({}) if elements.empty?

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

      # An interpolated string `"#{a}b#{c}"` is `literal-string`
      # when every part contributes literal-bearing material:
      # plain text segments are literal by construction, embedded
      # expressions count when their type is itself literal-string-
      # compatible (a `Constant<String>`, the `literal-string`
      # carrier, an `Intersection` containing it, or a `Union`
      # whose members all qualify). Otherwise the result widens to
      # plain `Nominal[String]` as before.
      def type_of_interpolated_string(node)
        return Type::Combinator.literal_string if interpolation_parts_literal?(node.parts)

        Type::Combinator.nominal_of(String)
      end

      def interpolation_parts_literal?(parts)
        parts.all? { |part| interpolation_part_literal?(part) }
      end

      def interpolation_part_literal?(part)
        case part
        when Prism::StringNode
          true
        when Prism::EmbeddedStatementsNode, Prism::EmbeddedVariableNode
          Type::Combinator.literal_string_compatible?(type_of(part))
        else
          false
        end
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
      # predicate expression under three-valued logic.
      # {Narrowing.predicate_certainty} owns the judgment (the same
      # one `StatementEvaluator#live_branch_for_if` reads on the
      # scope side): `Nominal[Integer]` (always truthy in Ruby),
      # `Constant[nil]`, and `Constant[false]` fold one branch;
      # `Union[true, false]`, `Dynamic[T]`, and `Top` keep both
      # branches live.
      def constant_predicate_polarity(predicate)
        return nil if predicate.nil?

        Narrowing.predicate_certainty(type_of(predicate))
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

      # Three-valued evaluation of `case predicate when pattern`
      # dispatch. For each `when` clause we ask: under static types,
      # does `pattern === predicate` definitely match (`:yes`),
      # definitely not match (`:no`), or possibly match (`:maybe`)?
      # Walking in source order:
      #
      # - `:yes` — this branch fires, subsequent branches are
      #   unreachable. Result = union(prior `:maybe` branches, this
      #   `:yes` branch).
      # - `:no`  — branch dropped.
      # - `:maybe` — branch is a candidate, continue.
      #
      # If no `:yes` was reached, the else clause (or `Constant[nil]`
      # when absent) is added to the candidate set.
      #
      # The `case ... in` pattern-matching form (`CaseMatchNode`) and
      # the predicate-less form (`case; when c1; ...`) bypass the
      # `===` analysis: pattern matching has richer semantics, and a
      # predicate-less `case` reduces to a `if c1; ...; elsif c2`
      # chain that statement-level narrowing already handles.
      def type_of_case(node)
        return type_of_case_simple_union(node) if node.is_a?(Prism::CaseMatchNode) || node.predicate.nil?

        subject_type = type_of(node.predicate)
        candidates = []
        reached_yes = false

        node.conditions.each do |when_node|
          case case_when_branch_certainty(subject_type, when_node)
          when :yes
            candidates << type_of(when_node)
            reached_yes = true
            break
          when :maybe
            candidates << type_of(when_node)
            # :no — drop the branch
          end
        end

        candidates << type_of_case_else(node) unless reached_yes
        Type::Combinator.union(*candidates)
      end

      def type_of_case_simple_union(node)
        branch_types = node.conditions.map { |branch| type_of(branch) }
        Type::Combinator.union(*branch_types, type_of_case_else(node))
      end

      def type_of_case_else(node)
        return Type::Combinator.constant_of(nil) if node.else_clause.nil?

        type_of(node.else_clause)
      end

      # Combines per-pattern certainty across a `when` clause's
      # conditions (`when a, b, c` ≡ `a === s || b === s || c === s`).
      # `:yes` if any pattern is `:yes`; `:no` if all are `:no`;
      # `:maybe` otherwise.
      def case_when_branch_certainty(subject_type, when_node)
        return :maybe unless when_node.respond_to?(:conditions)

        results = when_node.conditions.map { |c| case_when_pattern_certainty(subject_type, c) }
        return :maybe if results.empty?
        return :yes if results.include?(:yes)
        return :no if results.all?(:no)

        :maybe
      end

      # Static three-valued certainty for `pattern === subject`.
      # Specialises two pattern shapes:
      #
      # - **Class / Module reference** (`Integer`, `Foo::Bar`):
      #   reduce to `subject.is_a?(class)` via
      #   `Narrowing.narrow_class` / `narrow_not_class`. A Bot
      #   truthy fragment means no inhabitant matches (`:no`); a
      #   Bot falsey fragment means every inhabitant matches
      #   (`:yes`).
      # - **Value-equality literal** (numeric / String / Symbol /
      #   true / false / nil) against a `Constant[c]` subject:
      #   the static comparison `pattern_value === c` is exact.
      #   Other subject carriers stay `:maybe` because the
      #   runtime value isn't pinned.
      #
      # Other pattern shapes (Range, Regexp, custom `===`) stay
      # `:maybe` — the existing union fallback handles them.
      def case_when_pattern_certainty(subject_type, pattern_node)
        class_name = build_constant_path_name(pattern_node)
        return Narrowing.class_pattern_certainty(subject_type, class_name, environment: scope.environment) if class_name

        literal = literal_pattern_value(pattern_node)
        return Narrowing.value_pattern_certainty(subject_type, literal[:value]) if literal

        :maybe
      end

      # Returns `{ value: v }` when `pattern_node` types to a
      # `Constant[v]` of a value-equality-safe class (so `===`
      # reduces to `==`), else nil. Wrapped in a hash so a literal
      # `nil` / `false` value doesn't collide with the "no literal"
      # signal.
      def literal_pattern_value(pattern_node)
        type = type_of(pattern_node)
        return nil unless type.is_a?(Type::Constant)
        return nil unless Narrowing::VALUE_EQUALITY_CLASSES.any? { |klass| type.value.is_a?(klass) }

        { value: type.value }
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
        return Type::Combinator.constant_of(Range.new(left, right, node.exclude_end?)) if left_static && right_static

        nominal_range_for_endpoints(node.left, node.right)
      end

      # Derives `Nominal[Range, [T]]` from the endpoint expression
      # types when at least one endpoint is statically typeable. The
      # element parameter is the union of the endpoint types (lifted
      # from `Constant<v>` to `Nominal<v.class>` so the carrier matches
      # what `Range#each` would yield). Falls back to bare
      # `Nominal[Range]` when no endpoint contributes a typable shape.
      def nominal_range_for_endpoints(left_node, right_node)
        endpoints = [left_node, right_node].compact.map { |n| range_endpoint_element_type(n) }
        endpoints.reject! { |t| t.equal?(Type::Combinator.untyped) }
        return Type::Combinator.nominal_of("Range") if endpoints.empty?

        Type::Combinator.nominal_of("Range", type_args: [Type::Combinator.union(*endpoints)])
      end

      def range_endpoint_element_type(node)
        type = type_of(node)
        case type
        when Type::Constant
          value = type.value
          return Type::Combinator.untyped if value.nil?

          Type::Combinator.nominal_of(value.class.name)
        when Type::IntegerRange
          Type::Combinator.nominal_of("Integer")
        else
          type
        end
      end

      # v0.0.7 — non-interpolated regex literals lift to
      # `Constant<Regexp>` so `Constant<String>#scan(/regex/)`
      # / `#match(/regex/)` etc. can fold through the catalog
      # tier. Interpolated regexes (`/foo#{x}/`) reach the
      # second `Prism::InterpolatedRegularExpressionNode` arm
      # which keeps the conservative `Nominal[Regexp]` answer.
      def type_of_regexp(node)
        return Type::Combinator.nominal_of(Regexp) unless node.is_a?(Prism::RegularExpressionNode)

        regex = Regexp.new(node.unescaped, node.options)
        Type::Combinator.constant_of(regex)
      rescue StandardError
        Type::Combinator.nominal_of(Regexp)
      end

      def static_range_endpoint(node)
        return [true, nil] if node.nil?
        return [true, node.value] if node.is_a?(Prism::IntegerNode)
        return [true, node.unescaped] if node.is_a?(Prism::StringNode) && node.respond_to?(:unescaped)

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

      # Backtick (`cmd`) and `%x{cmd}` invoke Kernel#` and always return a
      # String. Even when the content is statically known, we widen to
      # Nominal[String] because the runtime value depends on the
      # subprocess output, not the source text.
      def type_of_xstring(_node)
        Type::Combinator.nominal_of(String)
      end

      # __FILE__ is the source file path. Always non-empty when
      # parsing a real file (the path resolver gives the buffer
      # name, which is at minimum `"(stdin)"` / `"-e"` / a real
      # path — never the empty String). Widened to
      # `non-empty-string` instead of `Nominal[String]` so
      # downstream String-emptiness checks know the value cannot
      # be `""`.
      def type_of_source_file(_node)
        Type::Combinator.non_empty_string
      end

      # __LINE__ is the line of the source literal. Ruby line
      # numbers are 1-indexed, so `__LINE__` is always at least
      # 1 — `positive-int` (Integer in `[1, +Inf)`) is the
      # canonical refinement.
      def type_of_source_line(_node)
        Type::Combinator.positive_int
      end

      # `# shareable_constant_value:` magic comment wraps the next
      # constant write. Type is the wrapped write's value.
      def type_of_shareable_constant(node)
        type_of(node.write)
      end

      # `{ x: }` shorthand hash. The implicit value is the call to
      # `x` (or a local read of `x`). Delegate.
      def type_of_implicit(node)
        type_of(node.value)
      end

      def local_read(node)
        scope.local(node.name) || dynamic_top
      end

      # `it` (Ruby 3.4) — `ItLocalVariableReadNode` carries no `name`
      # field; the implicit name is always `:it`, matching the binding
      # `BlockParameterBinder` installs for `Prism::ItParametersNode`.
      def it_read(_node)
        scope.local(:it) || dynamic_top
      end

      # Slice 5 phase 1 upgrades array literals to `Tuple[T1..Tn]`
      # when every element is a non-splat value. Splatted entries
      # (`[*xs, 1]`) preserve the Slice 4 phase 2d behavior: we union
      # the contributed element types and emit
      # `Nominal[Array, [union]]`.
      #
      # v0.0.6 — the empty literal `[]` resolves to the empty
      # `Tuple[]` carrier rather than the raw `Nominal[Array]`.
      # Both carriers erase to RBS `Array`, but `Tuple[]` pins
      # the literal's known arity (zero), which lets the
      # per-element block fold concatenate across all-empty
      # positions like `[1, 2].flat_map { |_| [] }`.
      def array_type_for(node)
        elements = node.elements
        return Type::Combinator.tuple_of if elements.empty?

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

      # Indexed-collection narrowing — `receiver[key]` after a
      # prior `receiver[key] ||= default` reads the post-`||=`
      # type when the receiver and key are stable enough to
      # address. Sits ahead of `MethodDispatcher.dispatch` so
      # the standard `Hash#[]` / `Array#[]` answer (which would
      # fold to `Constant[nil]` for an empty `HashShape{}` or
      # `Tuple[]`) does not override the narrowing. See
      # {Inference::IndexedNarrowing}.
      def indexed_narrowing_for(node)
        IndexedNarrowing.lookup_for_call(node, scope) || method_chain_narrowing_for(node)
      end

      # Stable single-hop chain narrowing — `receiver.method`
      # after an `is_a?` / `kind_of?` / `instance_of?` predicate
      # established the narrowing on the dominated edge. The
      # call MUST be no-arg + no-block + rooted at a local-var /
      # ivar read; everything else falls through to the
      # standard dispatcher. ROADMAP § Future cycles —
      # "Method-call receiver narrowing across stable
      # receivers" — Law-of-Demeter-justified single-hop scope.
      def method_chain_narrowing_for(node)
        return nil unless node.is_a?(Prism::CallNode)
        return nil unless node.block.nil?
        return nil unless node.arguments.nil? || node.arguments.arguments.empty?

        case node.receiver
        when Prism::LocalVariableReadNode
          scope.method_chain_narrowing(:local, node.receiver.name, node.name)
        when Prism::InstanceVariableReadNode
          scope.method_chain_narrowing(:ivar, node.receiver.name, node.name)
        end
      end

      # v0.0.3 A — implicit-self calls prefer a same-named
      # top-level `def` over RBS dispatch. Without this,
      # a helper like `def select(...)` defined inside an
      # `RSpec.describe ... do ... end` block mis-routes
      # through `Enumerable#select` / `Object#select` and
      # the caller observes `Array[Elem]` instead of the
      # helper's actual return type. The check fires only
      # for `node.receiver.nil?` (true implicit self), so
      # explicit-receiver dispatch is unaffected.
      def try_local_def_dispatch(node, receiver, arg_types)
        local_def = node.receiver.nil? ? scope.top_level_def_for(node.name) : nil
        return nil unless local_def

        local_inference = infer_top_level_user_method(local_def, receiver, arg_types)
        return local_inference if local_inference && adoptable_self_call_result?(local_inference)

        # The local def matches by name but the inference was
        # disqualified — either the parameter shape is too complex
        # for the first-iteration binder (kwargs / optionals /
        # rest), or ADR-24 slice 1's conservative gate declined
        # the resolved return type inside a class body (see
        # `adoptable_self_call_result?`). `Dynamic[Top]` is the
        # safest answer: RBS dispatch would be wrong (the method
        # is user-defined and shadows whatever ancestor method the
        # dispatch would find), and `Dynamic[Top]` propagates
        # correctly through downstream call chains without
        # surfacing misleading false-positive diagnostics.
        dynamic_top
      end

      # Slice 2 routes call expressions through `MethodDispatcher`. The
      # receiver and every argument are typed first, then the dispatcher is
      # asked for a result type. A nil result triggers the fail-soft fallback
      # for the CallNode itself (the inner type_of calls already record
      # their own fallbacks for unrecognised receivers/args, so the tracer
      # captures both the immediate dispatch miss and the deeper cause).
      def call_type_for(node)
        narrowed = indexed_narrowing_for(node)
        return narrowed if narrowed

        receiver = call_receiver_type_for(node)
        arg_types = call_arg_types(node)
        block_type = block_return_type_for(node, receiver, arg_types)

        local_def_result = try_local_def_dispatch(node, receiver, arg_types)
        return local_def_result if local_def_result

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

        hash_transform = try_hash_shape_block_fold(node, receiver)
        return hash_transform if hash_transform

        result = MethodDispatcher.dispatch(
          receiver_type: receiver,
          method_name: node.name,
          arg_types: arg_types,
          block_type: block_type,
          environment: scope.environment,
          call_node: node,
          scope: scope
        )
        return result if result

        # v0.0.2 #5 — inter-procedural inference for
        # user-defined methods. When dispatch misses but the
        # receiver is a user class with a `def` body, re-type
        # the body with the call's argument types bound and
        # return the body's last-expression type.
        user_inference = try_user_method_inference(receiver, node, arg_types)
        if user_inference
          return user_inference if adoptable_self_call_result?(user_inference)

          return dynamic_top
        end

        # Dynamic-origin propagation: when the receiver is Dynamic[T] and
        # no positive rule resolves the call, the result inherits the
        # dynamic origin. Per the value-lattice algebra, this is a
        # recognised semantic outcome, not a fail-soft compromise, so it
        # MUST NOT record a tracer event.
        return dynamic_top if receiver.is_a?(Type::Dynamic)

        # ADR-24 slice 4a — this is the engine choke-point where an
        # implicit-self call has exhausted every resolution tier (RBS
        # dispatch + user-class ancestor walk) and falls through to
        # `Dynamic[top]`. When the slice-4 recorder is active, capture the
        # miss so a later slice's closed-class gate can flag it. Off by
        # default: `active?` is a plain integer read.
        record_unresolved_self_call(node, receiver) if Analysis::SelfCallResolutionRecorder.active?

        fallback_for(node, family: :prism)
      end

      # ADR-24 slice 4a — records an unresolved *implicit-self* call (no
      # explicit receiver) whose `self` types to a concrete user class.
      # Explicit-receiver misses are out of scope (the existing
      # `call.undefined-method` rule already owns receiver-typed dispatch);
      # a non-`Nominal` self (top-level / DSL-block `self`, or a `Dynamic`
      # self) is skipped so the gradual guarantee is never touched here.
      def record_unresolved_self_call(node, receiver)
        return unless node.receiver.nil?
        return unless receiver.is_a?(Type::Nominal)
        return if self_call_method_known?(receiver.class_name, node.name)

        location = node.message_loc || node.location
        Analysis::SelfCallResolutionRecorder.record(
          class_name: receiver.class_name,
          method_name: node.name,
          node: node,
          path: scope.source_path,
          line: location&.start_line,
          column: location ? location.start_column + 1 : nil
        )
      end

      # The recorder must capture *existence* misses, not type misses.
      # Reaching the choke-point means RBS dispatch produced no result, but
      # a project method can still EXIST without an inferable return type —
      # a `module_function` sibling whose body the engine can't fully type,
      # an `attr_reader` / `define_method` / `Data.define` member. Recording
      # those would reproduce the 135 false positives of slice-4 attempt 1.
      # So skip any name the engine's own existence signals already know:
      # a `def` resolvable through the ancestor walk, or an own-class entry
      # in the discovered-methods table (`def` / `attr_*` / `define_method`
      # / alias). This reuses the engine's real resolution — the
      # "collect, don't recompute" lesson — so only a name that exists
      # nowhere a project signal can see reaches the recorder.
      # `module_function` records its defs as `:singleton` (an implicit-self
      # call inside such a method dispatches to the module's singleton
      # method), while ordinary instance methods record `:instance`. The
      # recorder cannot tell the two contexts apart from the call node, so
      # existence under EITHER kind suppresses recording — the FP-safe
      # choice, since either means the method genuinely exists.
      def self_call_method_known?(class_name, method_name)
        return true if resolve_user_def_through_ancestors(class_name, method_name)

        scope.discovered_method?(class_name, method_name, :instance) ||
          scope.discovered_method?(class_name, method_name, :singleton)
      end

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

      # ADR-24 slice 1 — implicit-self method-call resolution.
      # `discovered_def_nodes` is now carried into method /
      # class body scopes (see `StatementEvaluator#build_fresh_body_scope`),
      # so a call written with no explicit receiver inside a
      # method body resolves against the enclosing class's own
      # definitions and the file's top-level defs. Before
      # slice 1 every such call typed `Dynamic[top]`.
      #
      # The adoption of the resolved return type is gated:
      #
      # - At top-level / inside a DSL block (`scope.self_type`
      #   is nil) the result is adopted unchanged — this is
      #   the pre-slice-1 surface (the v0.0.3 A local-`def`
      #   shortcut) and MUST keep working.
      # - Inside a class body / method body (`self_type` set)
      #   the result is adopted ONLY when it is `Bot`. A `Bot`
      #   return is an always-diverging guard helper; adopting
      #   it can only ever enable correct terminating-branch
      #   narrowing, never a new `undefined-method` /
      #   argument-type false positive. A non-`Bot` resolved
      #   return is kept as `Dynamic[top]` (WD3) — adopting
      #   precise non-`Bot` returns project-wide awaits the
      #   callee-return-inference precision a later slice
      #   brings (measured: unconditional adoption regressed
      #   `rigor check lib` by 16 diagnostics).
      def adoptable_self_call_result?(type)
        scope.self_type.nil? || type.is_a?(Type::Bot) || fully_value_pinned?(type)
      end

      # True when `type` is a concrete value — a `Type::Constant` or a
      # `Type::Tuple` whose elements are (recursively) all value-pinned.
      # ADR-55 slice 1: a value-pinned self-call result is adopted even
      # inside a class/method body (where WD3 otherwise keeps non-`Bot`
      # returns as `Dynamic[top]`). A concrete value at a call site is
      # strictly more precise and can never enable an undefined-method or
      # argument-type false positive — it is FP-neutral by construction.
      def fully_value_pinned?(type)
        case type
        when Type::Constant then true
        when Type::Tuple then type.elements.all? { |element| fully_value_pinned?(element) }
        else false
        end
      end

      def try_user_method_inference(receiver, call_node, arg_types)
        return nil unless receiver.is_a?(Type::Nominal)

        def_node = resolve_user_def_through_ancestors(receiver.class_name, call_node.name)
        return nil if def_node.nil?

        infer_user_method_return(def_node, receiver, arg_types)
      rescue StandardError
        nil
      end

      # ADR-24 slice 2 — resolves `method_name` against
      # `class_name`'s own `def`s, then walks the user-class
      # ancestor chain: included / prepended modules (transitive)
      # and the superclass chain. RBS-known ancestors are NOT
      # walked here — the `MethodDispatcher` RBS tier runs before
      # `try_user_method_inference` and already covers them; an
      # ancestor name that resolves to no project-discovered
      # class/module ends that branch. Cross-file: the chain is
      # followed through `Scope#discovered_superclasses` /
      # `#discovered_includes` / `#discovered_def_nodes`, which
      # the runner seeds from the project-wide pre-pass. The walk
      # is breadth-first, cycle-guarded, and node-count-capped.
      ANCESTOR_WALK_LIMIT = 100
      private_constant :ANCESTOR_WALK_LIMIT

      CLASS_GRAPH_CACHE_KEY = :__rigor_class_graph_cache__
      private_constant :CLASS_GRAPH_CACHE_KEY

      # Run-scoped memo for the static class-graph resolvers below. They
      # are pure functions of the *frozen* project index trio
      # (`discovered_def_nodes` / `discovered_superclasses` /
      # `discovered_includes`) — `user_def_for` / `superclass_of` /
      # `includes_of` read nothing else, and never touch the current
      # scope's locals or narrowings — so a result computed for one
      # `(class, method)` is valid for every `Scope` that shares those
      # tables. `ExpressionTyper` is rebuilt per `Scope#type_of`, so the
      # memo lives on `Thread.current` rather than on `self`. It is keyed
      # by the *identity* of the three frozen tables (nested
      # `compare_by_identity` stores): a new analysis generation, or any
      # `Scope` that swaps an index via `with_discovered_*`, transparently
      # lands in a fresh bucket while everything sharing the tables shares
      # the memo. Steady-state cost is three identity-keyed hash reads and
      # zero allocation — the `||=` chains only allocate on the first miss
      # of a generation. (Pool mode forks per worker, so the
      # `Thread.current` store is process-local and never crosses a
      # project boundary.)
      def class_graph_buckets
        store = (Thread.current[CLASS_GRAPH_CACHE_KEY] ||= {}.compare_by_identity)
        by_def = (store[scope.discovered_def_nodes] ||= {}.compare_by_identity)
        by_super = (by_def[scope.discovered_superclasses] ||= {}.compare_by_identity)
        by_super[scope.discovered_includes] ||= { name: {}, user_def: {} }
      end

      def resolve_user_def_through_ancestors(class_name, method_name)
        cache = class_graph_buckets[:user_def]
        table = (cache[class_name.to_s] ||= {})
        key = method_name.to_sym
        return table[key] if table.key?(key)

        table[key] = compute_user_def_through_ancestors(class_name, method_name)
      end

      def compute_user_def_through_ancestors(class_name, method_name)
        queue = [class_name.to_s]
        seen = {}
        visited = 0
        until queue.empty?
          current = queue.shift
          next if current.nil? || seen[current]

          seen[current] = true
          visited += 1
          if visited > ANCESTOR_WALK_LIMIT
            BudgetTrace.hit(BudgetTrace::ANCESTOR_WALK_LIMIT)
            return nil
          end

          found = scope.user_def_for(current, method_name)
          return found if found

          enqueue_ancestors(current, queue)
        end
        nil
      end

      # Pushes `current`'s direct ancestors onto the BFS queue:
      # included / prepended modules first (Ruby places mixins
      # nearer than the superclass), then the superclass. Each
      # as-written name is resolved against `current`'s lexical
      # nesting; names that resolve to no project class/module
      # are dropped (RBS-known / third-party ancestors).
      def enqueue_ancestors(current, queue)
        scope.includes_of(current).each do |raw|
          resolved = resolve_ancestor_class_name(current, raw)
          queue.push(resolved) if resolved
        end
        raw_super = scope.superclass_of(current)
        return if raw_super.nil?

        resolved_super = resolve_ancestor_class_name(current, raw_super)
        queue.push(resolved_super) if resolved_super
      end

      # Resolves a superclass name AS WRITTEN (`"Base"`, or a
      # qualified `"A::B"`) to a project-discovered class,
      # following Ruby's `Module.nesting` constant lookup: try
      # the raw name under each enclosing namespace of the
      # subclass, innermost first, then bare. Returns nil when
      # no candidate names a discovered user class (e.g. the
      # superclass is an RBS-known or third-party class).
      def resolve_ancestor_class_name(subclass_qualified, raw_superclass)
        by_subclass = (class_graph_buckets[:name][subclass_qualified] ||= {})
        return by_subclass[raw_superclass] if by_subclass.key?(raw_superclass)

        by_subclass[raw_superclass] =
          compute_ancestor_class_name(subclass_qualified, raw_superclass)
      end

      def compute_ancestor_class_name(subclass_qualified, raw_superclass)
        segments = subclass_qualified.split("::")
        (segments.length - 1).downto(0) do |i|
          candidate = (segments[0, i] + [raw_superclass]).join("::")
          return candidate if known_user_class?(candidate)
        end
        nil
      end

      def known_user_class?(name)
        scope.discovered_superclasses.key?(name) ||
          scope.discovered_def_nodes.key?(name) ||
          scope.discovered_includes.key?(name)
      end

      INFERENCE_GUARD_KEY = :__rigor_user_method_inference_stack__
      private_constant :INFERENCE_GUARD_KEY

      INFERENCE_UNROLL_FUEL_KEY = :__rigor_user_method_unroll_fuel__
      private_constant :INFERENCE_UNROLL_FUEL_KEY

      # Hard, non-configurable caps for the ADR-55 slice 1 constant-arg
      # unroll. `RECURSION_UNROLL_FUEL` bounds the number of extended
      # (value-keyed) frames per outermost inference entry;
      # `RECURSION_VALUE_SIZE_CAP` disqualifies a frame whose pinned
      # argument values are structurally large. Both are termination
      # guards (ADR-41 WD4) — not measurement-gated precision budgets —
      # so they ship default-on with no opt-in.
      RECURSION_UNROLL_FUEL = 32
      private_constant :RECURSION_UNROLL_FUEL

      RECURSION_VALUE_SIZE_CAP = 64
      private_constant :RECURSION_VALUE_SIZE_CAP

      def infer_user_method_return(def_node, receiver, arg_types)
        return nil if def_node.body.nil?

        body_scope = build_user_method_body_scope(def_node, receiver, arg_types)
        return nil if body_scope.nil?

        # Recursion-guard signature. Keyed on `(receiver,
        # method)` only — NOT the argument types. ADR-24 WD5:
        # a method whose summary is still being computed
        # resolves to `Dynamic[top]` for that cycle. Keying on
        # arg types would let mutual recursion through a
        # `module_function` module (`Acceptance#accepts` →
        # `accepts_one` → `accepts_dynamic` → `accepts`)
        # recurse unboundedly whenever the carried argument
        # types differ at each level — observed as a
        # `SystemStackError` once implicit-self calls began
        # resolving during the main walk. `describe(:short)`
        # keeps non-Nominal receivers (the implicit `Object`
        # carrier for top-level / DSL-block defs) printable.
        plain_signature = [receiver.describe(:short), def_node.name]
        stack = (Thread.current[INFERENCE_GUARD_KEY] ||= [])

        # ADR-55 slice 1: when every bound argument is value-pinned,
        # extend the guard key with a stable descriptor of the argument
        # *values* so distinct constant frames may recurse (e.g.
        # `factorial(5)` folds to `Constant[120]`). Distinct constant
        # frames are bounded by `RECURSION_UNROLL_FUEL` per outermost
        # entry; exhaustion or value blow-up falls back to the plain
        # `(receiver, method)` guard — today's behaviour. Non-constant
        # args never reach this path.
        signature = plain_signature
        value_key = constant_argument_value_key(arg_types)
        signature = [plain_signature, value_key] if value_key && unroll_fuel_remaining(stack).positive?

        if stack.include?(signature)
          BudgetTrace.hit(BudgetTrace::RECURSION_GUARD)
          return Type::Combinator.untyped
        end

        stack.push(signature)
        begin
          type, _post = body_scope.evaluate(def_node.body)
          type
        ensure
          stack.pop
          # Fuel is per-outermost-entry: clear it once the guard stack
          # drains back to empty so the next top-level inference starts
          # with full fuel.
          Thread.current[INFERENCE_UNROLL_FUEL_KEY] = nil if stack.empty?
        end
      end

      # Consumes one unit from the thread-local unroll-fuel counter and
      # returns the units that were available *before* this consumption
      # (so a positive return means the extended value-key may be used).
      # Fuel is per-outermost inference entry: at the top level (empty
      # guard stack) it seeds to `RECURSION_UNROLL_FUEL`, and the
      # `ensure` in `infer_user_method_return` clears it once the stack
      # drains back to empty. On exhaustion (return 0) it records a
      # `RECURSION_UNROLL_FUEL` hit so the caller keeps the plain
      # `(receiver, method)` signature — today's behaviour.
      def unroll_fuel_remaining(stack)
        remaining = Thread.current[INFERENCE_UNROLL_FUEL_KEY]
        remaining = RECURSION_UNROLL_FUEL if remaining.nil? || stack.empty?
        if remaining.positive?
          Thread.current[INFERENCE_UNROLL_FUEL_KEY] = remaining - 1
        else
          BudgetTrace.hit(BudgetTrace::RECURSION_UNROLL_FUEL)
        end
        remaining
      end

      # A stable, hashable descriptor of the argument values when EVERY
      # element of `arg_types` is value-pinned: a `Type::Constant`, or a
      # `Type::Tuple` whose elements are (recursively) all value-pinned.
      # Returns nil when any argument is not value-pinned (the ordinary
      # type-keyed path) or when any pinned value's structural size
      # exceeds `RECURSION_VALUE_SIZE_CAP` (value blow-up → fall back).
      def constant_argument_value_key(arg_types)
        return nil if arg_types.empty?

        keys = []
        arg_types.each do |arg|
          descriptor = pinned_value_descriptor(arg)
          return nil if descriptor.nil?

          keys << descriptor
        end
        return nil if keys.sum { |_, size| size } > RECURSION_VALUE_SIZE_CAP

        keys.map(&:first)
      end

      # Returns `[descriptor, structural_size]` for a value-pinned type,
      # or nil for anything else. Strings count by a cheap length proxy
      # (length > 256 ≈ 64+ nodes) so a long built string disqualifies
      # the frame without a deep walk; tuples recurse.
      def pinned_value_descriptor(arg)
        case arg
        when Type::Constant
          value = arg.value
          size = value.is_a?(String) ? (value.length / 4) + 1 : 1
          [["c", arg.describe(:short)], size]
        when Type::Tuple
          parts = []
          total = 1
          arg.elements.each do |element|
            descriptor = pinned_value_descriptor(element)
            return nil if descriptor.nil?

            parts << descriptor.first
            total += descriptor.last
          end
          [["t", parts], total]
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
      def build_user_method_body_scope(def_node, receiver, arg_types)
        params = def_node.parameters
        required = params&.requireds || []
        return nil unless params.nil? || user_method_param_shape_simple?(params)
        return nil unless required.size == arg_types.size

        # Bind required positionals by index. The body scope starts from an
        # empty fact store and narrowing set, so `with_local`'s fact /
        # narrowing invalidations would be no-ops here — build the locals
        # table directly (matching `with_local`'s `name.to_sym` key).
        locals = {}
        required.each_with_index { |param, index| locals[param.name.to_sym] = arg_types[index] }

        # Construct the body scope in a SINGLE allocation — the previous
        # `Scope.empty.with_*.with_*…` chain allocated a fresh frozen Scope
        # per field, run per user-method-call inference (ADR-44). The
        # discovery index is inherited whole by reference (ADR-53 Track A);
        # the hand-copied per-field list this replaces had silently dropped
        # `data_member_layouts` and `discovered_method_visibilities`.
        Scope.new(
          environment: scope.environment,
          locals: locals.freeze,
          self_type: receiver,
          discovery: scope.discovery
        )
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
      #
      # ADR-14 gap-#3 (d): a `Prism::BlockArgumentNode` carrying
      # `&:symbol` (the Symbol#to_proc shorthand) is treated as
      # a block. The block's return type is computed by
      # dispatching `:symbol` on the expected block param type
      # (per `Symbol#to_proc`'s `{ |x| x.symbol }` semantics).
      # A precise inner dispatch produces the right return; any
      # failure step falls back to `Dynamic[Top]` so the
      # dispatcher still SEES a block — selecting the block-
      # bearing overload of e.g. `Hash#transform_values` over
      # the no-block overload that returns `Enumerator`.
      def block_return_type_for(call_node, receiver_type, arg_types)
        block_arg = call_node.block
        return nil if block_arg.nil?
        return nil if receiver_type.nil?

        expected = MethodDispatcher.expected_block_param_types(
          receiver_type: receiver_type,
          method_name: call_node.name,
          arg_types: arg_types,
          environment: scope.environment
        )
        # ADR-16 Tier A: when a registered plugin's `block_as_methods`
        # entry matches `(receiver_type, call_node.name)`, narrow the
        # block body's `self_type` to the receiver class's instance
        # type. The narrowing is `nil` for unmatched calls, leaving
        # the existing scope contract unchanged.
        narrowed_self = MacroBlockSelfType.narrow_self_type_for(
          scope: scope, call_node: call_node, receiver_type: receiver_type
        )
        block_return_for(block_arg, expected, narrowed_self_type: narrowed_self)
      rescue StandardError
        nil
      end

      def block_return_for(block_arg, expected, narrowed_self_type: nil)
        case block_arg
        when Prism::BlockNode
          bindings = BlockParameterBinder.new(expected_param_types: expected).bind(block_arg)
          block_scope = bindings.reduce(scope) { |acc, (name, type)| acc.with_local(name, type) }
          block_scope = block_scope.with_self_type(narrowed_self_type) if narrowed_self_type
          type_block_body(block_arg, block_scope)
        when Prism::BlockArgumentNode
          symbol_block_return_type(block_arg, expected)
        end
      end

      # `&:symbol` desugars to a one-arg Proc that dispatches
      # `symbol` against its argument. When the param type is
      # known and the resulting inner dispatch is precise,
      # this returns the precise carrier; otherwise it
      # returns `Dynamic[Top]` (still non-nil) so the outer
      # dispatcher selects the block-bearing overload.
      # `&proc_local` / `&method(:foo)` and friends — anything
      # not a bare SymbolNode — still resolve to
      # `Dynamic[Top]` for the same block-presence signal.
      def symbol_block_return_type(block_arg, expected_param_types)
        expression = block_arg.expression
        return dynamic_top unless expression.is_a?(Prism::SymbolNode)

        param_type = expected_param_types&.first
        return dynamic_top if param_type.nil?

        result = MethodDispatcher.dispatch(
          receiver_type: param_type,
          method_name: expression.unescaped.to_sym,
          arg_types: [],
          block_type: nil,
          environment: scope.environment,
          call_node: block_arg,
          scope: scope
        )
        result || dynamic_top
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
      PER_ELEMENT_TUPLE_METHODS = Set[
        :map, :collect, :filter_map, :flat_map,
        :select, :filter, :reject,
        :find, :detect, :find_index, :index
      ].freeze
      private_constant :PER_ELEMENT_TUPLE_METHODS

      HASH_SHAPE_TRANSFORM_METHODS = Set[
        :transform_keys, :transform_keys!,
        :transform_values, :transform_values!
      ].freeze
      private_constant :HASH_SHAPE_TRANSFORM_METHODS

      # Cardinality cap for per-element block fold over
      # finite-bound `Constant<Range>` receivers. Walking
      # `(1..1_000_000).map { … }` element-wise would balloon
      # block-typing cost and explode the resulting Tuple, so
      # only short ranges expand into per-position folds.
      # Larger ranges decline so the RBS tier widens.
      PER_ELEMENT_RANGE_LIMIT = 8
      private_constant :PER_ELEMENT_RANGE_LIMIT

      def try_per_element_block_fold(call_node, receiver_type)
        return nil unless PER_ELEMENT_TUPLE_METHODS.include?(call_node.name)
        return nil if find_family_with_args?(call_node)

        element_types = per_element_elements_of(receiver_type)
        return nil if element_types.nil? || element_types.empty?

        per_position = per_element_block_results(call_node.block, element_types)
        return nil if per_position.nil? || per_position.any?(&:nil?)

        assemble_per_element_result(call_node.name, per_position, element_types)
      end

      # Evaluates the call's block once per receiver element.
      # Two block shapes are supported:
      #
      # - `Prism::BlockNode` — a full `do … end` / `{ … }` block;
      #   the body is re-typed per position with the element
      #   bound to the block parameter.
      # - `Prism::BlockArgumentNode` wrapping a `SymbolNode` —
      #   the `&:predicate` shorthand; the symbol is dispatched
      #   as a zero-arg method on each element type.
      #
      # Any other shape (`&proc_local`, `&method(:foo)`, no
      # block) returns `nil` so the fold declines.
      def per_element_block_results(block, element_types)
        case block
        when Prism::BlockNode
          element_types.map { |element_type| type_block_body_with_param(block, [element_type]) }
        when Prism::BlockArgumentNode
          per_element_symbol_results(block, element_types)
        end
      end

      def per_element_symbol_results(block_arg, element_types)
        expression = block_arg.expression
        return nil unless expression.is_a?(Prism::SymbolNode)

        method_name = expression.unescaped.to_sym
        element_types.map do |element_type|
          MethodDispatcher.dispatch(
            receiver_type: element_type,
            method_name: method_name,
            arg_types: [],
            block_type: nil,
            environment: scope.environment,
            scope: scope
          )
        end
      rescue StandardError
        nil
      end

      # Returns the per-position element types for a finite,
      # statically-known receiver shape — or nil when the
      # receiver does not pin a finite element list.
      #
      # `Tuple[A, B, …]`        → [A, B, …]
      # `Constant<a..b>`        → [Constant[a], …, Constant[b]]
      # everything else         → nil
      #
      # Note: `Type::IntegerRange` is the bounded-Integer
      # carrier (`int<a, b>` represents "an Integer between
      # a and b"), not a Range value. Calls like `.map` /
      # `.find` on an `IntegerRange` receiver would resolve
      # to `Integer#map` / `Integer#find` — neither exists —
      # so IntegerRange does NOT participate in this fold.
      def per_element_elements_of(receiver_type)
        case receiver_type
        when Type::Tuple then receiver_type.elements
        when Type::Constant then constant_range_elements(receiver_type.value)
        end
      end

      def constant_range_elements(value)
        return nil unless value.is_a?(Range)
        return nil unless value.begin.is_a?(Integer) && value.end.is_a?(Integer)

        cardinality = value.exclude_end? ? value.end - value.begin : value.end - value.begin + 1
        return nil if cardinality <= 0 || cardinality > PER_ELEMENT_RANGE_LIMIT

        value.to_a.map { |v| Type::Combinator.constant_of(v) }
      end

      # `index(value)` and `find_index(value)` carry a positional
      # argument and search by `==` rather than running the block.
      # Decline so the RBS tier owns those forms.
      def find_family_with_args?(call_node)
        return false unless %i[find_index index].include?(call_node.name)

        args = call_node.arguments
        !args.nil? && !args.arguments.empty?
      end

      def assemble_per_element_result(method_name, per_position, element_types)
        case method_name
        when :map, :collect then Type::Combinator.tuple_of(*per_position)
        when :filter_map then assemble_filter_map_result(per_position)
        when :flat_map then assemble_flat_map_result(per_position)
        when :select, :filter
          assemble_filter_result(per_position, element_types, keep_on_truthy: true)
        when :reject
          assemble_filter_result(per_position, element_types, keep_on_truthy: false)
        when :find, :detect then assemble_find_result(per_position, element_types)
        when :find_index, :index then assemble_find_index_result(per_position)
        end
      end

      # `select` / `filter` / `reject`: keeps each receiver
      # element whose per-position predicate result folds to a
      # decisive `Constant` — Ruby-truthy for `select` / `filter`,
      # Ruby-falsey for `reject`. The surviving elements assemble
      # into a `Tuple`, strictly tighter than the RBS-projected
      # `Array[Elem]`.
      #
      # Folds tightly only when EVERY position is a `Constant`:
      # a single non-`Constant` position leaves the result
      # cardinality unknown (the element might or might not
      # survive), so the dispatcher declines and the RBS tier
      # widens to `Array[Elem]`. `[].select` style empty results
      # are sound — an empty `Tuple` is the empty-array carrier.
      def assemble_filter_result(per_position, element_types, keep_on_truthy:)
        return nil unless per_position.all?(Type::Constant)

        kept = element_types.each_index.filter_map do |index|
          element_types[index] if truthy_constant?(per_position[index]) == keep_on_truthy
        end
        Type::Combinator.tuple_of(*kept)
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

      # `flat_map` flattens a single level: if the per-position
      # result is a `Tuple`, its elements are concatenated; if
      # it's a non-Array scalar carrier (`Constant<…>` over a
      # non-Array literal) it contributes one element. We fold
      # tightly only when every per-position result is one of
      # those two recognisable shapes — `Nominal[Array[T]]`,
      # `Union[…]`, and other opaque carriers decline so the
      # RBS tier widens to `Array[U]`.
      #
      # `Type::Constant` only ever holds non-Array scalars (the
      # carrier rejects Array literals), so a single `Constant`
      # safely contributes itself as a single Tuple element.
      def assemble_flat_map_result(per_position)
        flattened = per_position.flat_map { |type| flat_map_contribution(type) }
        return nil if flattened.nil? || flattened.any?(&:nil?)

        Type::Combinator.tuple_of(*flattened)
      end

      def flat_map_contribution(type)
        case type
        when Type::Tuple then type.elements
        when Type::Constant then [type]
        else [nil]
        end
      end

      # `find` / `detect`: returns the first receiver element
      # whose block result is Ruby-truthy, or `nil` when no
      # position folds to truthy.
      #
      # Folds tightly only when every per-position block result
      # is a `Type::Constant` — otherwise we cannot decide which
      # position (if any) is "the first matching one". When the
      # first decisive truthy position is found, the answer is
      # the corresponding receiver element. When every position
      # folds to falsey, the answer is `Constant[nil]`.
      def assemble_find_result(per_position, element_types)
        return nil unless per_position.all?(Type::Constant)

        first_truthy_index = per_position.index { |type| truthy_constant?(type) }
        return Type::Combinator.constant_of(nil) if first_truthy_index.nil?

        element_types[first_truthy_index]
      end

      # `find_index` / `index`: returns the index of the first
      # truthy position, or `Constant[nil]` when nothing matches.
      def assemble_find_index_result(per_position)
        return nil unless per_position.all?(Type::Constant)

        first_truthy_index = per_position.index { |type| truthy_constant?(type) }
        return Type::Combinator.constant_of(nil) if first_truthy_index.nil?

        Type::Combinator.constant_of(first_truthy_index)
      end

      def truthy_constant?(type)
        type.is_a?(Type::Constant) && type.value && type.value != false
      end

      # Per-pair block fold for `HashShape#transform_keys` and
      # `HashShape#transform_values` (and their bang variants).
      #
      # When the receiver is a closed `HashShape` with no optional
      # keys, applies the call's block (a `Prism::BlockNode` or
      # `Prism::BlockArgumentNode`) to each key/value pair
      # independently and assembles a new `HashShape`:
      #
      # - `transform_values` / `transform_values!`: re-types
      #   each VALUE by binding it to the block parameter; keys
      #   are preserved unchanged.
      # - `transform_keys` / `transform_keys!`: re-types each
      #   KEY by wrapping it in `Constant[k]` and passing it to
      #   the block; values are preserved unchanged. The result
      #   key must be a `Constant[Symbol | String]` — otherwise
      #   the tier declines (the new key cannot be used as a
      #   static HashShape index). Collisions (two old keys
      #   mapping to the same new key) also decline.
      #
      # Returns `nil` on any decline so the dispatcher falls
      # through to `RbsDispatch` and gets the widened `Hash[K, V]`
      # answer.
      def try_hash_shape_block_fold(call_node, receiver_type)
        return nil unless HASH_SHAPE_TRANSFORM_METHODS.include?(call_node.name)
        return nil unless receiver_type.is_a?(Type::HashShape)
        return nil unless receiver_type.closed?
        return nil unless receiver_type.optional_keys.empty?

        block_arg = call_node.block
        return nil if block_arg.nil?

        if %i[transform_values transform_values!].include?(call_node.name)
          fold_hash_shape_transform_values(receiver_type, block_arg)
        else
          fold_hash_shape_transform_keys(receiver_type, block_arg)
        end
      end

      def fold_hash_shape_transform_values(shape, block_arg)
        new_pairs = {}
        shape.pairs.each do |key, value|
          new_value = apply_hash_block(block_arg, value)
          return nil if new_value.nil?

          new_pairs[key] = new_value
        end
        Type::Combinator.hash_shape_of(new_pairs)
      end

      def fold_hash_shape_transform_keys(shape, block_arg)
        new_pairs = {}
        shape.pairs.each do |key, value|
          key_type = Type::Combinator.constant_of(key)
          new_key_type = apply_hash_block(block_arg, key_type)
          return nil unless new_key_type.is_a?(Type::Constant)

          new_key = new_key_type.value
          return nil unless new_key.is_a?(Symbol) || new_key.is_a?(String)
          return nil if new_pairs.key?(new_key)

          new_pairs[new_key] = value
        end
        Type::Combinator.hash_shape_of(new_pairs)
      end

      # Applies a single-argument block (either a full BlockNode
      # or a `&:symbol` BlockArgumentNode) to `param_type` and
      # returns the resulting type, or `nil` on failure.
      def apply_hash_block(block_arg, param_type)
        case block_arg
        when Prism::BlockNode
          type_block_body_with_param(block_arg, [param_type])
        when Prism::BlockArgumentNode
          expression = block_arg.expression
          return nil unless expression.is_a?(Prism::SymbolNode)

          MethodDispatcher.dispatch(
            receiver_type: param_type,
            method_name: expression.unescaped.to_sym,
            arg_types: [],
            block_type: nil,
            environment: scope.environment,
            call_node: block_arg,
            scope: scope
          )
        end
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
