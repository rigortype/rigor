# frozen_string_literal: true

require "prism"

require_relative "../type"
require_relative "../reflection"
require_relative "../ast"
require_relative "../source/constant_path"
require_relative "../source/node_children"
require_relative "../source/node_walker"
require_relative "../analysis/self_call_resolution_recorder"
require_relative "block_parameter_binder"
require_relative "method_parameter_binder"
require_relative "body_fixpoint"
require_relative "budget_trace"
require_relative "captured_locals"
require_relative "dynamic_origin"
require_relative "origin_lookup"
require_relative "../effects/collector"
require_relative "fallback"
require_relative "flow_tracer"
require_relative "indexed_narrowing"
require_relative "macro_block_self_type"
require_relative "method_dispatcher"
require_relative "mutation_widening"
require_relative "narrowing"
require_relative "receiver_alias"
require_relative "singleton_object_constant"
require_relative "optimistic_origin"
require_relative "struct_fold_safety"
require_relative "version_guard"

module Rigor
  module Inference
    # Translates AST nodes into Rigor::Type values, consulting the surrounding Rigor::Scope for local-variable
    # bindings and the environment registry for nominal-type resolution. Pure: never mutates the receiver
    # scope.
    #
    # Accepts both real Prism nodes and synthetic Rigor::AST::Node instances; the synthetic family lets
    # callers and plugins ask "what would the analyzer infer if a value of type T appeared here?" without
    # building a real Prism expression.
    #
    # Slice 1 recognises literal expressions, local-variable reads/writes, shallow Array literals, and
    # Rigor::AST::TypeNode. Slice 2 adds Prism::CallNode (routed through Rigor::Inference::MethodDispatcher),
    # Prism::ArgumentsNode (a non-value position whose children are typed individually by the CallNode
    # handler), constant references resolved through Rigor::Environment::ClassRegistry, hash and interpolated
    # string/symbol literals, definition expressions (def/class/module), and explicit handlers for parameter,
    # block, splat, instance/class/global-variable, and self positions. Many of those handlers return
    # Dynamic[Top] silently because they are non-value or out-of-scope positions for Slice 2; later slices
    # refine them in place.
    #
    # Slice 4 phase 2b types bare-constant references (`Foo`, `Foo::Bar`) as `Singleton[Foo]` rather than
    # `Nominal[Foo]`, so that method dispatch on the constant correctly looks up *class* methods. The
    # corresponding instance type is reachable through `Foo.new` and the value-lattice projections.
    #
    # Every other node falls back to Dynamic[Top] per the fail-soft policy in
    # docs/internal-spec/inference-engine.md. The optional tracer is a Rigor::Inference::FallbackTracer (or
    # any object answering #record_fallback) that receives a Fallback event for each fallback; the tracer
    # MUST NOT change the return value of type_of.
    # rubocop:disable-next Metrics/ClassLength
    class ExpressionTyper
      # Hash-based dispatch keeps `type_of` linear and lets future slices add node kinds without growing a
      # single case statement past RuboCop's cyclomatic budget. Anonymous Prism subclasses are not expected.
      PRISM_DISPATCH = {
        # Literals
        Prism::IntegerNode => :type_of_literal_value,
        Prism::FloatNode => :type_of_literal_value,
        # `1i` / `2.5ri` lift via `node.value` which is already a `Complex` Ruby value; same for `1r` / `1.5r`
        # whose value is a `Rational`. `Type::Constant` accepts both via `SCALAR_CLASSES`.
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
        Prism::CallOrWriteNode => :call_or_write_type_for,
        Prism::CallAndWriteNode => :call_and_write_type_for,
        Prism::CallOperatorWriteNode => :call_operator_write_type_for,
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
        # LHS-only target nodes (destructuring assignment, pattern matching, `for x in xs`, block parameter
        # `|a, (b, c)|`). They have no value to extract — the type-of pass acknowledges the node class so the
        # coverage scanner stops flagging it; binding the inner names back into the scope is the
        # StatementEvaluator / MultiTargetBinder / BlockParameterBinder side's concern.
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
        # `for` matches `eval_for`'s statement-path policy: the loop expression types `Constant[nil]` (no
        # `break VALUE` observed), same as `while` / `until` — annotating a `for`'s `end` line as
        # `Dynamic[top]` was a display artifact of the old mapping.
        Prism::ForNode => :type_of_loop,
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

      # Sentinel distinguishing "the key is not a value-pinned literal" from the legitimate literal hash
      # keys `nil` and `false` (see {#static_hash_key}).
      NO_STATIC_HASH_KEY = Object.new.freeze
      private_constant :NO_STATIC_HASH_KEY

      def initialize(scope:, tracer: nil)
        @scope = scope
        @tracer = tracer
        @typing_node = nil
      end

      def type_of(node)
        previous = @typing_node
        @typing_node = node
        result = if FlowTracer.active?
                   FlowTracer.trace_node(node) { untraced_type_of(node) }
                 else
                   untraced_type_of(node)
                 end
        result
      ensure
        @typing_node = previous
      end

      def untraced_type_of(node)
        # Slice A-declarations. ScopeIndexer pre-fills `scope.declared_types` for declaration-position nodes
        # (`module Foo` / `class Bar` headers) with the qualified `Singleton` type so the header itself does
        # not fall through to `Dynamic[Top]`. The override is consulted before any other dispatch and
        # bypasses fail-soft tracing on a recognised match.
        declared = scope.declared_types[node]
        return declared if declared

        return type_of_virtual(node) if node.is_a?(AST::Node)

        handler = PRISM_DISPATCH[node.class]
        return send(handler, node) if handler

        fallback_for(node, family: :prism)
      end

      # ADR-89 WD2 — the return type of `def_node` called with `receiver` / `arg_types`, computed exactly as a
      # resolved in-body dispatch does (through the ADR-84 memo, so it is cheap and yields FINAL values only).
      # Public entry point for the incremental session's return-summary re-evaluation: it re-drives a
      # declaration-stable changed callee at each previously-observed call key to prove its return is
      # unchanged before skipping the callee's symbol dependents. nil for an abstract / bodyless def, or when
      # the memo refuses a transient result — the caller treats either as "not provably stable" (keeps the
      # dependents), the conservative direction.
      def return_type_for(def_node, receiver, arg_types)
        infer_user_method_return(def_node, receiver, arg_types)
      end

      # ADR-89 WD2 — the current run's return memo bucket as `{ def_node => [MemoEntry, …] }` (only entries
      # that carry a call descriptor, i.e. every stored entry). Read by the incremental session right after a
      # recording run to harvest each analyzed callee's observed call keys → return descriptors. Returns an
      # empty hash when no bucket exists (a run that memoised nothing). Class method: the bucket lives on
      # `Thread.current`, independent of any one `ExpressionTyper` instance.
      def self.harvest_return_memo
        slot = Thread.current[RETURN_MEMO_KEY]
        return {} if slot.nil?

        slot[1].transform_values(&:values)
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

      # All `*WriteNode` flavours expose a `.value` rvalue child. Their type is the type of that rvalue.
      # Binding the result back into the scope is the responsibility of the statement-level evaluator
      # (Slice 3), never of `type_of` itself.
      def type_of_assignment_write(node)
        type_of(node.value)
      end

      # Slice 7 phase 1 — instance/class/global variable reads. Each lookup returns the type currently bound
      # in the surrounding scope's per-kind binding map (populated by `StatementEvaluator` write handlers
      # within the same method body), falling through to `Dynamic[Top]` when no binding is recorded.
      # Cross-method ivar/cvar inference is a follow-up slice; the read handlers MUST NOT raise on a missing
      # binding and MUST NOT record a fallback event in either branch — the absence of a binding is a
      # recognised semantic outcome, not a fail-soft compromise.
      def type_of_instance_variable_read(node)
        bound = scope.ivar(node.name)
        return bound if bound

        # ADR-82 — an unbound instance-variable read is dynamic because the engine does not track this
        # field's type (it is assigned in another method, or never seen). Route it to ivar-field typing
        # (ADR-58) rather than reporting no cause, and let WD6 carry it through a `@x.foo.bar` chain. This
        # records provenance only (still `dynamic_top`), never a fallback / tracer event.
        scope.record_dynamic_origin(node, DynamicOrigin::INFERRED_RETURN_UNTYPED)
        dynamic_top
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

      # Recognised position that does not produce a value: parameter lists and individual parameter
      # declarations, splats inside argument lists, key-value pairs in hashes, and the implicit-rest token
      # inside destructuring. Returning Dynamic[Top] silently keeps these off the unrecognised list without
      # faking a value type.
      def type_of_non_value(_node)
        dynamic_top
      end

      # `Prism::SelfNode` resolves to the scope's `self_type` when one has been injected (by
      # `StatementEvaluator` at class-body and method-body boundaries) or `Dynamic[Top]` at the top level.
      # Class-body `self` is `Singleton[<class>]`; instance-method `self` is `Nominal[<class>]`;
      # singleton-method `self` is `Singleton[<class>]`.
      def type_of_self_node(_node)
        scope.self_type || dynamic_top
      end

      def type_of_dynamic_top(_node)
        dynamic_top
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
      def type_of_numbered_reference(node)
        scope.global(:"$#{node.number}") || type_of_string_or_nil(node)
      end

      # `$&` / `$'` / `$\`` / `$+` — symbolic back-references. Same narrowing model as numbered references.
      def type_of_back_reference(node)
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

      # The expression `Foo` evaluates to the *class object* `Foo`, not an instance. From Slice 4 phase 2b on
      # we therefore type a bare-constant reference as `Singleton[Foo]`; method dispatch on that receiver
      # looks up class methods (`Foo.new`, `Foo.bar`, ...).
      #
      # Slice A constant-walk: when the literal name does not resolve, we try a lexical walk based on the
      # surrounding class context exposed through `scope.self_type` so a reference like
      # `Inference::FallbackTracer` from inside `Rigor::CLI::Foo` resolves to
      # `Rigor::Inference::FallbackTracer`.
      def type_of_constant_read(node)
        resolve_constant_name(node.name.to_s) || unresolved_constant_fallback(node, node.name.to_s)
      end

      # A leading `::` (`::Rails`, `::Rails::Application`) is Ruby's escape hatch out of the lexical ladder:
      # it names the top-level constant whatever the enclosing nesting defines. The rendered name is
      # deliberately un-rooted (the discovery tables are keyed that way), so the marker rides alongside it
      # into the resolver (#614).
      def type_of_constant_path(node)
        full_name = Source::ConstantPath.qualified_name_or_nil(node)
        return fallback_for(node, family: :prism) if full_name.nil?

        resolve_constant_name(full_name, rooted: Source::ConstantPath.rooted?(node)) ||
          unresolved_constant_fallback(node, full_name)
      end

      # ADR-82 WD9 — an unresolved constant whose root name a locked, RBS-less gem declares carries the
      # `external_gem_without_rbs` cause instead of the generic `unsupported_syntax`. The constant read is
      # where the class name is last visible (a no-RBS gem's receiver never types Nominal, so the dispatch
      # tiers that record this cause under ADR-10 / `pre_eval:` opt-ins can't see it); WD6 chain inheritance
      # then carries the cause through `Faraday.new.get(...)`. Side-channel only — the type stays the same
      # `Dynamic[top]`, and an unindexed constant (project typo, unanalyzed project path) keeps the generic
      # cause: the fail-open direction is a missing label, never a wrong one.
      def unresolved_constant_fallback(node, full_name)
        record_missing_constant(full_name) if Analysis::DependencyRecorder.active?
        root = full_name.delete_prefix("::").split("::").first
        owner = root && scope.environment.missing_rbs_gem_owner(root)
        return fallback_for(node, family: :prism) unless owner

        inner = dynamic_top
        record_fallback(node, family: :prism, inner_type: inner, origin: DynamicOrigin::EXTERNAL_GEM_WITHOUT_RBS)
        scope.record_dynamic_origin(node, DynamicOrigin::EXTERNAL_GEM_WITHOUT_RBS)
        inner
      end

      # ADR-46 slice 3 / issue #622 — a constant reference that resolved to NOTHING is a negative cross-file
      # dependency: a file declaring that constant later must re-check every file that read it as missing.
      # Without this edge the structural tier had no record of the read at all — `read_missing(:method, …)`
      # fires only once the receiver constant has RESOLVED and the method lookup misses, so a missing
      # constant short-circuited before any edge existed, and a warm `--incremental` run kept
      # `Rails.logger`'s `Dynamic[top]` (and missed the `call.undefined-method` a full run fires) after a
      # later edit added `module Rails`.
      #
      # Reuses the existing `class:Name` negative kind (`CheckRules`'s override-ancestor miss records the
      # same one) rather than adding a `constant:` kind, because the producer that has to invert it already
      # exists: `Incremental.appeared_classes` reports a newly declared class / module by its QUALIFIED name
      # and `negative_affected` matches it by simple (last-segment) name. The snapshot row grammar is
      # therefore unchanged — no `IncrementalSnapshot::SCHEMA` bump — and a snapshot recorded by an engine
      # without this edge is already dropped by the fingerprint's engine-source part.
      #
      # The LAST segment is the whole key, and one row per reference is the whole cost: a qualified read
      # resolves only once its final segment is declared, and every constant form that resolves cross-file —
      # a `class` / `module`, and the constant-assigned `Data.define` / `Struct.new` forms — registers in the
      # discovery pre-pass's class sources under its qualified name, so its final segment always appears.
      # (A plain value constant, `FOO = 1` or a `VERSION` nested in a module, resolves in NO cross-file read
      # today, so there is nothing for a root-segment or a `constant:` key to salvage; if that changes, the
      # answer is a producer that reports appeared value constants, not a wider key here.) Simple-name
      # matching over-invalidates — a nested `MyApp::Rails` also re-checks a reader of the top-level `Rails`
      # — which is the sound direction and the grammar the class negatives already use. Consumers hold
      # `missing` as a Set, so a name repeated across a file still costs one row.
      def record_missing_constant(full_name)
        segments = full_name.delete_prefix("::").split("::")
        return if segments.empty?

        Analysis::DependencyRecorder.read_missing(:class, segments.last)
        # Issue #644's `constant:<last segment>` edge is NOT recorded here. It is recorded once per
        # reference by `Reflection.resolve_constant_type`, before the resolver ladder runs, so it covers a
        # reference that resolves through RBS or the class registry as well as one that misses — all three
        # answers move when the project's constant write set moves. Recording it again on this path would be
        # a second source of truth for the same key.
      end

      # Resolves a constant reference through Ruby's lexical constant lookup. Delegates to the shared
      # `Reflection.resolve_constant_type` owner so the same walk (registry singleton, discovered class,
      # in-source value, RBS constant, across the peeled `::` prefix candidates) is reused by
      # `Inference::Narrowing`'s `Constant[Regexp]` match-operand recognition. Returns the matched
      # `Rigor::Type` or nil; the caller decides whether to fall back.
      def resolve_constant_name(name, rooted: false)
        Reflection.resolve_constant_type(name, scope: scope, rooted: rooted)
      end

      # Slice 5 phase 1 upgrades hash literals to `HashShape{...}` when every entry is a static `AssocNode`
      # whose key is a value-pinned scalar literal — Symbol, plain String, Integer, Float, `true`, `false`,
      # or `nil` (covering `{ a: 1, "b" => 2 }` and `{ 1 => 2, 1.0 => 4 }` alike) — falling back to the
      # generic `Hash[K, V]` form otherwise. Splatted entries (`{ **other }`) and dynamic keys widen to the
      # underlying `Hash[K, V]` form by unioning the types each entry exposes; when no concrete pair
      # survives we fall back to the raw `Hash` so callers stay backward compatible.
      def type_of_hash(node)
        elements = node.respond_to?(:elements) ? node.elements : []
        # v0.0.7 — `{}` resolves to the empty `HashShape{}` carrier rather than `Nominal[Hash]`, mirroring the
        # v0.0.6 empty-array literal change. Both forms erase to plain `Hash`, but `HashShape{}` pins the
        # literal's known size (zero) so HashShape projections (`empty?`, `first`, `count`, …) fold against it.
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

      # Builds `HashShape{...}` when every entry is an `AssocNode` whose key is a value-pinned scalar
      # literal (Symbol, plain String, Integer, Float, true, false, nil). Returns nil otherwise so the
      # caller falls back to the generic shape.
      #
      # Duplicate keys are LAST-WINS, matching the runtime (`{ a: 1, a: 2 }` keeps `a: 2`; Ruby itself
      # only warns under `-w`). Key identity is Ruby `Hash` `eql?` identity because `pairs` is a native
      # Hash — `1` and `1.0` stay distinct entries, `1.0` and `1.00` collide. The plain re-assignment
      # also reproduces the runtime's ordering: the key keeps its FIRST insertion position while the
      # value comes from the LAST occurrence.
      def static_hash_shape_for(elements)
        pairs = {}
        elements.each do |entry|
          return nil unless entry.is_a?(Prism::AssocNode)

          key = static_hash_key(entry.key)
          return nil if key.equal?(NO_STATIC_HASH_KEY)

          pairs[key] = type_of(entry.value)
        end
        return nil if pairs.empty?

        Type::Combinator.hash_shape_of(pairs)
      end

      # Returns the value-pinned scalar literal carried by a hash key node, or {NO_STATIC_HASH_KEY} when
      # the key is dynamic (a computed expression, an interpolated string — SymbolNode#value /
      # StringNode#unescaped are nil under interpolation — a constant, a local, …). `nil` / `false` are
      # real key values here, hence the sentinel rather than a nil return.
      def static_hash_key(node)
        case node
        when Prism::SymbolNode
          raw = node.value
          raw.nil? ? NO_STATIC_HASH_KEY : raw.to_sym
        when Prism::StringNode
          node.unescaped || NO_STATIC_HASH_KEY
        when Prism::IntegerNode, Prism::FloatNode then node.value
        when Prism::TrueNode then true
        when Prism::FalseNode then false
        when Prism::NilNode then nil
        else NO_STATIC_HASH_KEY
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

      # An interpolated string `"#{a}b#{c}"` is `literal-string` when every part contributes literal-bearing
      # material: plain text segments are literal by construction, embedded expressions count when their type
      # is itself literal-string-compatible (a `Constant<String>`, the `literal-string` carrier, an
      # `Intersection` containing it, or a `Union` whose members all qualify). Otherwise the result widens to
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

      # `class Foo; body; end`, `module Foo; body; end`, and `class << x; body; end` evaluate to the value of
      # the body's last expression, or `nil` when the body is empty. We do not track class/module scope yet,
      # so the body is typed in the surrounding scope and that result is returned.
      def type_of_class_or_module(node)
        body = node.body
        return Type::Combinator.constant_of(nil) if body.nil?

        type_of(body)
      end

      # `alias x y`, `alias $x $y`, and `undef foo` all evaluate to nil at runtime; the constant carrier
      # captures that exactly.
      def type_of_nil_value(_node)
        Type::Combinator.constant_of(nil)
      end

      # `if c; t; (elsif c2; ...; )* else; e; end`. Prism nests `elsif` branches as `IfNode#subsequent`. Slice
      # 3 phase 1 types both branches in the receiver scope and returns their union; scope rebinding is the
      # StatementEvaluator's job (Slice 3 phase 2). Without an else clause the branch's implicit value is nil,
      # which is included in the union.
      #
      # v0.0.6 — when the predicate folds to a `Type::Constant` whose value is Ruby-truthy (resp.
      # Ruby-falsey), the unreachable branch is elided so the if-expression's type is the live branch alone.
      # Statement-level branch elision lives in `StatementEvaluator#eval_if`; this handler covers the
      # expression-position ternary form (`a ? b : c`) and any `if`/`unless` reached through `type_of`.
      def type_of_if(node)
        then_type = statements_or_nil(node.statements)
        else_type = if_else_type(node.subsequent)
        elide_or_union(node.predicate, then_type, else_type)
      end

      # `unless c; t; else; e; end`. Prism uses `else_clause` here (no `elsif` chain). Branch-elision logic
      # mirrors `type_of_if`, inverted: a truthy predicate selects the else branch.
      def type_of_unless(node)
        then_type = statements_or_nil(node.statements)
        else_type = if_else_type(node.else_clause)
        elide_or_union(node.predicate, else_type, then_type)
      end

      # Issue #286 — the effective optimistic-nil-free cause of an expression. {OptimisticOrigin.resolve} owns
      # the judgment, shared verbatim with `StatementEvaluator#optimistic_origin_for` and the
      # `flow.always-truthy-condition` collector.
      def optimistic_origin_for(node)
        OptimisticOrigin.resolve(node, scope)
      end

      def if_else_type(subsequent)
        return Type::Combinator.constant_of(nil) if subsequent.nil?

        type_of(subsequent)
      end

      # Routes the predicate's typed value through branch elision. `live_when_truthy` and `live_when_falsey`
      # are the branch types selected by the predicate's polarity; the names match `IfNode` semantics
      # directly and invert at the `type_of_unless` call site.
      def elide_or_union(predicate, live_when_truthy, live_when_falsey)
        case constant_predicate_polarity(predicate)
        when :truthy then live_when_truthy
        when :falsey then live_when_falsey
        else Type::Combinator.union(live_when_truthy, live_when_falsey)
        end
      end

      # Returns `:truthy`, `:falsey`, or `nil` for an arbitrary predicate expression under three-valued logic.
      # {Narrowing.predicate_certainty} owns the judgment (the same one `StatementEvaluator#live_branch_for_if`
      # reads on the scope side): `Nominal[Integer]` (always truthy in Ruby), `Constant[nil]`, and
      # `Constant[false]` fold one branch; `Union[true, false]`, `Dynamic[T]`, and `Top` keep both branches live.
      def constant_predicate_polarity(predicate)
        return nil if predicate.nil?

        # ADR-47 WD5 — a decidable version guard (#627) answers first, exactly as it does on the scope side
        # in `StatementEvaluator#branch_certainty`. Both readers ask the same pure function of the AST, so
        # the expression form (`RUBY_VERSION >= "3.1" ? a : b`) and the statement form cannot disagree about
        # which arm survives. The verdict rests on literals, so the ADR-101 optimistic-carrier decline below
        # — which guards an RBS-derived judgment — does not apply to it.
        guard = VersionGuard.verdict(predicate)
        return guard if guard
        # ADR-101 — decline on an optimistically nil-free carrier; see
        # `StatementEvaluator#optimistic_carrier?` for why the gate is here and not in `Narrowing`.
        return nil unless optimistic_origin_for(predicate).nil?

        Narrowing.predicate_certainty(type_of(predicate))
      end

      def type_of_else(node)
        statements_or_nil(node.statements)
      end

      # `a && b` and `a || b` short-circuit at the value level: `a && b` returns `a` when `a` is falsey, else
      # `b`. `a || b` returns `a` when `a` is truthy, else `b`.
      #
      # v0.0.6 — when the left operand folds to a `Type::Constant`, we know which side actually flows
      # through, so the result is one operand's type instead of a union. Otherwise the union-of-both-operands
      # fallback is preserved.
      def type_of_and_or(node)
        left_type = type_of(node.left)
        polarity = left_operand_polarity(node.left, left_type)
        return short_circuit_for(node, left_type, polarity) if polarity

        # The left operand only flows through on the edge that short-circuits: `a || b` yields `a` solely
        # when `a` is truthy, so its falsey constituents (`nil` / `false`) can never be the value of the
        # OrNode (they hand off to `b`); `a && b` yields `a` solely when `a` is falsey. Narrow the surviving
        # left edge before the union so `s || full` (with `s : String?`) types `String | <full>` rather than
        # re-admitting the stripped `nil`. Mirrors `StatementEvaluator#eval_and_or`'s `skipped_type`.
        surviving_left =
          if node.is_a?(Prism::AndNode)
            Narrowing.narrow_falsey(left_type)
          else
            Narrowing.narrow_truthy(left_type)
          end
        Type::Combinator.union(surviving_left, type_of(node.right))
      end

      def short_circuit_for(node, left_type, polarity)
        and_node = node.is_a?(Prism::AndNode)
        if polarity == :truthy
          and_node ? type_of(node.right) : left_type
        else
          and_node ? left_type : type_of(node.right)
        end
      end

      # Issue #313 — the node-aware wrapper the `&&` / `||` short-circuit reads. The spec's exclusion binds
      # this gate as much as it binds `flow.always-truthy-condition`, and a `Constant`-only gate is not by
      # itself enough to honour it: a literal hash whose values share one type reads as a lone `Constant`
      # (`UNIFORM[key]` → `Constant[1]`), so the gate would judge the left operand of `UNIFORM[key] || key`
      # provably truthy and discard the author's fallback — the counter-example the spec names verbatim.
      # Declining returns the union of both operands, which is what `StatementEvaluator#eval_and_or` produces
      # anyway, so the two `&&` / `||` typers stay in agreement.
      def left_operand_polarity(left_node, left_type)
        return nil unless optimistic_origin_for(left_node).nil?

        constant_value_polarity(left_type)
      end

      # Returns `:truthy` / `:falsey` for a `Type::Constant`, nil otherwise. Mirrors
      # `constant_predicate_polarity` but operates on a typed value (already-type-of'd) rather than a Prism
      # node, so the same predicate analysis can be reused in both contexts.
      def constant_value_polarity(type)
        return nil unless type.is_a?(Type::Constant)

        type.value ? :truthy : :falsey
      end

      # Three-valued evaluation of `case predicate when pattern` dispatch. For each `when` clause we ask:
      # under static types, does `pattern === predicate` definitely match (`:yes`), definitely not match
      # (`:no`), or possibly match (`:maybe`)? Walking in source order:
      #
      # - `:yes` — this branch fires, subsequent branches are unreachable. Result = union(prior `:maybe`
      #   branches, this `:yes` branch).
      # - `:no`  — branch dropped.
      # - `:maybe` — branch is a candidate, continue.
      #
      # If no `:yes` was reached, the else clause (or `Constant[nil]` when absent) is added to the candidate
      # set.
      #
      # The `case ... in` pattern-matching form (`CaseMatchNode`) and the predicate-less form (`case; when
      # c1; ...`) bypass the `===` analysis: pattern matching has richer semantics, and a predicate-less
      # `case` reduces to a `if c1; ...; elsif c2` chain that statement-level narrowing already handles.
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

      # Combines per-pattern certainty across a `when` clause's conditions (`when a, b, c` ≡ `a === s || b
      # === s || c === s`). `:yes` if any pattern is `:yes`; `:no` if all are `:no`; `:maybe` otherwise.
      def case_when_branch_certainty(subject_type, when_node)
        return :maybe unless when_node.respond_to?(:conditions)

        results = when_node.conditions.map { |c| case_when_pattern_certainty(subject_type, c) }
        return :maybe if results.empty?
        return :yes if results.include?(:yes)
        return :no if results.all?(:no)

        :maybe
      end

      # Static three-valued certainty for `pattern === subject`. Specialises two pattern shapes:
      #
      # - **Class / Module reference** (`Integer`, `Foo::Bar`): reduce to `subject.is_a?(class)` via
      #   `Narrowing.narrow_class` / `narrow_not_class`. A Bot truthy fragment means no inhabitant matches
      #   (`:no`); a Bot falsey fragment means every inhabitant matches (`:yes`).
      # - **Value-equality literal** (numeric / String / Symbol / true / false / nil) against a
      #   `Constant[c]` subject: the static comparison `pattern_value === c` is exact. Other subject
      #   carriers stay `:maybe` because the runtime value isn't pinned.
      #
      # Other pattern shapes (Range, Regexp, custom `===`) stay `:maybe` — the existing union fallback
      # handles them.
      def case_when_pattern_certainty(subject_type, pattern_node)
        class_name = Source::ConstantPath.qualified_name_or_nil(pattern_node)
        return Narrowing.class_pattern_certainty(subject_type, class_name, environment: scope.environment) if class_name

        literal = literal_pattern_value(pattern_node)
        return Narrowing.value_pattern_certainty(subject_type, literal[:value]) if literal

        :maybe
      end

      # Returns `{ value: v }` when `pattern_node` types to a `Constant[v]` of a value-equality-safe class
      # (so `===` reduces to `==`), else nil. Wrapped in a hash so a literal `nil` / `false` value doesn't
      # collide with the "no literal" signal.
      def literal_pattern_value(pattern_node)
        type = type_of(pattern_node)
        return nil unless type.is_a?(Type::Constant)
        return nil unless Narrowing::VALUE_EQUALITY_CLASSES.any? { |klass| type.value.is_a?(klass) }

        { value: type.value }
      end

      # `when` clauses for `case` and `in` clauses for `case ... in` have the same body shape; we reuse one
      # handler for both Prism node classes.
      def type_of_when_or_in(node)
        statements_or_nil(node.statements)
      end

      # `begin; body; rescue R => e; r1; rescue; r2; else; e; ensure; f; end`. The result is the union of
      # every value-producing branch: the body (or the else-clause when present, since it replaces the body's
      # value when no exception fires), plus each rescue body in the rescue chain. The ensure clause runs but
      # does not contribute to the begin's value.
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

      # `expr rescue fallback` is RescueModifierNode in Prism. The result is `expr`'s type when no exception
      # is raised and `fallback`'s type otherwise; both paths are reachable, so the result is their union.
      def type_of_rescue_modifier(node)
        Type::Combinator.union(type_of(node.expression), type_of(node.rescue_expression))
      end

      def type_of_ensure(node)
        statements_or_nil(node.statements)
      end

      # `return`, `break`, `next`, `retry`, and `redo` all transfer control instead of producing a value.
      # Their type is Bot, the empty type that absorbs cleanly under union (e.g. `Constant[1] | Bot ==
      # Constant[1]`), so the surrounding control-flow handlers collapse correctly when one branch jumps.
      def type_of_jump(_node)
        Type::Combinator.bot
      end

      # `while` and `until` loops produce nil unless interrupted by `break VALUE`; the expression value of
      # `break VALUE` is not yet modeled (scope break-path propagation landed in `eval_loop`). Returning
      # Constant[nil] is safe and matches Ruby semantics for the common case.
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

      # Derives `Nominal[Range, [T]]` from the endpoint expression types when at least one endpoint is
      # statically typeable. The element parameter is the union of the endpoint types (lifted from
      # `Constant<v>` to `Nominal<v.class>` so the carrier matches what `Range#each` would yield). Falls back
      # to bare `Nominal[Range]` when no endpoint contributes a typable shape.
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

      # v0.0.7 — non-interpolated regex literals lift to `Constant<Regexp>` so `Constant<String>#scan(/regex/)`
      # / `#match(/regex/)` etc. can fold through the catalog tier. Interpolated regexes (`/foo#{x}/`) reach
      # the second `Prism::InterpolatedRegularExpressionNode` arm which keeps the conservative
      # `Nominal[Regexp]` answer.
      def type_of_regexp(node)
        return Type::Combinator.nominal_of(Regexp) unless node.is_a?(Prism::RegularExpressionNode)

        regex = Regexp.new(node.unescaped, node.options)
        Type::Combinator.constant_of(regex)
      rescue StandardError
        Type::Combinator.nominal_of(Regexp)
      end

      # A range endpoint folds to a static value when it is a literal (`IntegerNode` / `StringNode`) or when
      # its *evaluated* type is a `Constant<v>` carrying a range-able value (Integer / Float / String —
      # matching the literal-path value kinds). The evaluated arm lets `(1..n)` fold to `Constant<Range>`
      # when per-call body inference has pinned `n` to a constant (fact2 chain). A `nil` node is a
      # beginless/endless boundary: keep today's static-nil behaviour (which yields `Constant<Range>` only
      # when the *other* end is also static, preserving today's beginless/endless path).
      def static_range_endpoint(node)
        return [true, nil] if node.nil?
        return [true, node.value] if node.is_a?(Prism::IntegerNode)
        return [true, node.unescaped] if node.is_a?(Prism::StringNode) && node.respond_to?(:unescaped)

        type = type_of(node)
        if type.is_a?(Type::Constant)
          value = type.value
          return [true, value] if value.is_a?(Integer) || value.is_a?(Float) || value.is_a?(String)
        end

        [false, nil]
      end

      # Helper for the many control-flow handlers that read a body `Prism::StatementsNode` or treat its
      # absence as nil. Note that Prism uses nil (rather than an empty `StatementsNode`) for missing bodies
      # in many node kinds.
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

      def fallback_for(node, family:, origin: DynamicOrigin::UNSUPPORTED_SYNTAX)
        inner = dynamic_top
        record_fallback(node, family: family, inner_type: inner, origin: origin)
        scope.record_dynamic_origin(node, origin)
        inner
      end

      def record_fallback(node, family:, inner_type:, origin: nil)
        return unless tracer

        location = node.respond_to?(:location) ? node.location : nil
        event = Fallback.new(
          node_class: node.class,
          location: location,
          family: family,
          inner_type: inner_type,
          origin: origin
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

      # `# shareable_constant_value:` magic comment wraps the next constant write. Type is the wrapped
      # write's value.
      def type_of_shareable_constant(node)
        type_of(node.write)
      end

      # `{ x: }` shorthand hash. The implicit value is the call to `x` (or a local read of `x`). Delegate.
      def type_of_implicit(node)
        type_of(node.value)
      end

      def local_read(node)
        scope.local(node.name) || dynamic_top
      end

      # `it` (Ruby 3.4) — `ItLocalVariableReadNode` carries no `name` field; the implicit name is always
      # `:it`, matching the binding `BlockParameterBinder` installs for `Prism::ItParametersNode`.
      def it_read(_node)
        scope.local(:it) || dynamic_top
      end

      # Slice 5 phase 1 upgrades array literals to `Tuple[T1..Tn]` when every element is a non-splat value.
      # Splatted entries (`[*xs, 1]`) preserve the Slice 4 phase 2d behavior: we union the contributed
      # element types and emit `Nominal[Array, [union]]`.
      #
      # v0.0.6 — the empty literal `[]` resolves to the empty `Tuple[]` carrier rather than the raw
      # `Nominal[Array]`. Both carriers erase to RBS `Array`, but `Tuple[]` pins the literal's known arity
      # (zero), which lets the per-element block fold concatenate across all-empty positions like `[1,
      # 2].flat_map { |_| [] }`.
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

      # Indexed-collection narrowing — `receiver[key]` after a prior `receiver[key] ||= default` reads the
      # post-`||=` type when the receiver and key are stable enough to address. Sits ahead of
      # `MethodDispatcher.dispatch` so the standard `Hash#[]` / `Array#[]` answer (which would fold to
      # `Constant[nil]` for an empty `HashShape{}` or `Tuple[]`) does not override the narrowing. See
      # {Inference::IndexedNarrowing}.
      def indexed_narrowing_for(node)
        IndexedNarrowing.lookup_for_call(node, scope) || method_chain_narrowing_for(node)
      end

      # Stable single-hop chain narrowing — `receiver.method` after an `is_a?` / `kind_of?` / `instance_of?`
      # predicate established the narrowing on the dominated edge. The call MUST be no-arg + no-block +
      # rooted at a local-var / ivar read; everything else falls through to the standard dispatcher. ROADMAP
      # § Future cycles — "Method-call receiver narrowing across stable receivers" — Law-of-Demeter-justified
      # single-hop scope.
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

      # v0.0.3 A — implicit-self calls prefer a same-named top-level `def` over RBS dispatch. Without this, a
      # helper like `def select(...)` defined inside an `RSpec.describe ... do ... end` block mis-routes
      # through `Enumerable#select` / `Object#select` and the caller observes `Array[Elem]` instead of the
      # helper's actual return type. The check fires only for `node.receiver.nil?` (true implicit self), so
      # explicit-receiver dispatch is unaffected.
      #
      # Issue #316 — the lookup goes through the confidence-gated `Scope#bindable_top_level_def_for`, not the
      # raw table: inside a block whose `self` is unmodelled, a top-level `def` from ANOTHER file is not
      # evidence about which method the call reaches, so the bind is declined and the call widens.
      #
      # Issue #618 — the binding is a fallback for names the enclosing `self` does NOT answer, not a
      # first-choice tier. A top-level `def` is a private method on `Object`, the last link of every MRO, so
      # whenever the call's own `self` carries the name the class wins at runtime and the top-level body is
      # never reached. Binding regardless of `self_type` inverted that: a top-level `def text` typed the
      # member read inside `class Line < Struct.new(:text); def shout = text.upcase; end` as the def's `nil`
      # and fired `undefined method 'upcase' for nil` on correct code. The candidate is still looked up
      # first — that lookup is a hash probe and owns the ADR-46 cross-file dependency edge — and
      # {#self_type_answers?} then vetoes the bind for a name the enclosing class answers itself.
      def try_local_def_dispatch(node, receiver, arg_types)
        local_def = node.receiver.nil? ? scope.bindable_top_level_def_for(node.name) : nil
        return nil unless local_def
        return nil if self_type_answers?(node.name)

        local_inference = infer_top_level_user_method(local_def, receiver, arg_types)
        return local_inference if local_inference

        # The local def matches by name but the inference was disqualified — the parameter shape is too
        # complex for the first-iteration binder (kwargs / optionals / rest), so the body could not be
        # re-typed. `Dynamic[Top]` is the safest answer: RBS dispatch would be wrong (the method is
        # user-defined and shadows whatever ancestor method the dispatch would find), and `Dynamic[Top]`
        # propagates correctly through downstream call chains without surfacing misleading false-positive
        # diagnostics.
        dynamic_top
      end

      # Issue #618 — whether the call's enclosing `self` already answers `method_name`. Only a `self` whose
      # class is KNOWN participates: at genuine top level, and inside a block whose `self` is unmodelled,
      # `scope.self_type` is nil, the predicate is false, and the historical top-level binding stands — that
      # is #316's / #319's territory and this veto stays out of it.
      #
      # The ADR-48 member carriers answer from their own map first: a `StructInstance` / `DataInstance`
      # `self` carries the member set the body reads through, and an anonymous `Struct.new(...)` value has no
      # class name to look anything else up under.
      def self_type_answers?(method_name)
        case (self_type = scope.self_type)
        when Type::Singleton then singleton_self_answers?(self_type.class_name, method_name)
        when Type::Nominal then instance_self_answers?(self_type.class_name, method_name)
        when Type::StructInstance, Type::DataInstance
          self_type.members.key?(method_name.to_sym) || instance_self_answers?(self_type.class_name, method_name)
        else false
        end
      end

      # The instance side of {#self_type_answers?}: the class's own discovered methods (`def`, `attr_*`,
      # `define_method`, `alias`), its `Struct.new` / `Data.define` member accessors, a `def` reached through
      # its project ancestors (superclass chain and included modules), and an RBS method declared on the
      # class ITSELF.
      #
      # The RBS arm is own-class only, deliberately. An inherited-declaration test would match every
      # `Object` / `Kernel` / `Enumerable` name and retract the binding v0.0.3 A exists for — a `def
      # select(...)` collocated with its DSL-block call site would route straight back through
      # `Enumerable#select`.
      def instance_self_answers?(class_name, method_name)
        return false if class_name.nil?
        return true if scope.discovered_method?(class_name, method_name, :instance)
        return true if meta_member?(class_name, method_name)
        return true if resolve_user_def_through_ancestors(class_name, method_name)

        rbs_declared_on_class?(safe_rbs_method_definition(class_name, method_name, :instance), class_name)
      end

      # The singleton side: a class-body `self` is `Singleton[Foo]`, where an implicit-self call reaches
      # `Foo`'s own class methods before `Object`'s private top-level `def`.
      def singleton_self_answers?(class_name, method_name)
        return false if class_name.nil?
        return true if scope.discovered_method?(class_name, method_name, :singleton)
        return true unless scope.singleton_def_for(class_name, method_name).nil?

        rbs_declared_on_class?(safe_rbs_method_definition(class_name, method_name, :singleton), class_name)
      end

      # A `Struct.new(:a, :b)` / `Data.define(:a, :b)` member accessor. The layouts are a discovery table of
      # their own, separate from `discovered_methods`, so the accessor names they imply have to be asked for
      # explicitly. Only the reader name is tested: a writer is unreachable as an implicit-self call, since
      # bare `a = v` is a local assignment.
      def meta_member?(class_name, method_name)
        layout = scope.struct_member_layout(class_name)
        members = layout ? layout[:members] : scope.data_member_layout(class_name)
        !members.nil? && members.include?(method_name.to_sym)
      end

      def safe_rbs_method_definition(class_name, method_name, kind)
        if kind == :singleton
          Rigor::Reflection.singleton_method_definition(class_name, method_name, scope: scope)
        else
          Rigor::Reflection.instance_method_definition(class_name, method_name, scope: scope)
        end
      rescue StandardError
        nil
      end

      # True when the RBS declaration found for the name sits on `class_name` itself rather than on an
      # ancestor; mirrors `CheckRules#defined_on?` and `SigGen::Generator#declared_on_class_itself?`.
      def rbs_declared_on_class?(definition, class_name)
        return false if definition.nil?
        return false unless definition.respond_to?(:defined_in)

        defined_in = definition.defined_in
        return false if defined_in.nil?

        defined_in.to_s.delete_prefix("::") == class_name.to_s.delete_prefix("::")
      end

      # Issue #520 — Ruby defines the value of an attribute / index assignment (`x.attr = v`, `h[k] = v`)
      # as the RHS object itself, whatever the writer method returns. The dispatch pipeline still runs
      # first for everything it observes on the side (effect collection, provenance, recorders, and the
      # rules' own view of the writer), but its RESULT is discarded in favor of the last argument's type —
      # `Hash#[]=`'s declared V made `h[k] = true` read Dynamic on an untyped hash, ~300 sites across the
      # 2026-09-01 corpus sweep. Safe-navigation writes stay on the dispatch result: `x&.attr = v` is
      # `v | nil`, which is #518's (safe-navigation) territory, not plain value semantics.
      def call_type_for(node)
        return safe_navigation_call_type(node) if node.safe_navigation?

        attribute_write_value(node, call_dispatch_type_for(node))
      end

      # The RHS-value override for plain attribute / index writes (#520); a non-write call keeps the
      # dispatch result.
      def attribute_write_value(node, result)
        return result unless node.attribute_write?

        rhs = node.arguments&.arguments&.last
        return result if rhs.nil? || rhs.is_a?(Prism::SplatNode)

        type_of(rhs)
      end

      # Issue #518 — `x&.m` is NOT a plain call: when `x` is nil the method never runs and the expression
      # is nil. Typed as a plain call it inherited both defects of union dispatch — the nil arm's method
      # was folded as if `&.` called it (`s&.to_s` on `String?` read `String`, missing the nil the runtime
      # produces), and a method absent from NilClass declined the whole union to `Dynamic[top]` even when
      # the non-nil arm is fully typed (herb's own sig declares `Token#value: String`; the `?` alone
      # discarded it). The call is dispatched on the nil-stripped receiver and the nil the skip produces is
      # unioned back in; a receiver that IS nil skips the call statically.
      def safe_navigation_call_type(node)
        # A literal `nil&.m` is the statically-skipped call and folds to nil. An INFERRED exactly-nil
        # receiver deliberately does NOT fold: every corpus site with that shape traced to a wrong
        # upstream nil (an `attr_writer`-backed ivar whose only static write is nil — #541 — or a mutated
        # literal-shape constant — #540), and folding it turned those latent wrong types into
        # `flow.always-truthy-condition` firings on working programs. Until those uplinks are honest,
        # the inferred-nil receiver keeps the plain pipeline's Dynamic.
        return Type::Combinator.constant_of(nil) if node.receiver.is_a?(Prism::NilNode)

        receiver = type_of(node.receiver)
        non_nil = Narrowing.narrow_non_nil(receiver)
        # A Bot or Dynamic fragment cannot improve on the plain pipeline (Bot: the inferred-exactly-nil
        # receivers trace to the #540 / #541 uplinks; Dynamic: the stripped dispatch re-answers Dynamic),
        # so both keep the historical path and its flow bookkeeping.
        return call_dispatch_type_for(node) if non_nil.is_a?(Type::Bot) || non_nil.is_a?(Type::Dynamic)

        result = attribute_write_value(node, call_dispatch_type_for(node, receiver_override: non_nil))
        # Structural equality: `narrow_non_nil` rebuilds a Union even when it removed nothing, and a
        # receiver that cannot be nil must not have a phantom nil unioned into its result.
        return result if non_nil == receiver

        Type::Combinator.union(result, Type::Combinator.constant_of(nil))
      end

      # Issue #532 — the attribute compound-write family (`x.attr ||= v`, `&&=`, `+=`), the last
      # genuinely unmodeled value-position constructs the 2026-09-01 corpus census found (they fell to the
      # `unsupported_syntax` fallback). Value semantics mirror the local / ivar / index siblings:
      # `||=` is `truthy(read) | rhs`, `&&=` is `falsey(read) | rhs`, and an operator write is the
      # operator dispatched on the read result. A `&.`-form compound write unions the skipped-call nil in
      # (#518's rule). Scope effects stay as before (none) — the struct member writeback and shape
      # widening for these forms are follow-up work recorded on #532.
      def call_or_write_type_for(node)
        current = attribute_compound_read_type(node)
        value = Type::Combinator.union(Narrowing.narrow_truthy(current), type_of(node.value))
        with_compound_write_safe_nav(node, value)
      end

      def call_and_write_type_for(node)
        current = attribute_compound_read_type(node)
        value = Type::Combinator.union(Narrowing.narrow_falsey(current), type_of(node.value))
        with_compound_write_safe_nav(node, value)
      end

      def call_operator_write_type_for(node)
        current = attribute_compound_read_type(node)
        result = MethodDispatcher.dispatch(
          receiver_type: current, method_name: node.binary_operator, arg_types: [type_of(node.value)],
          environment: scope.environment, call_node: node, scope: scope
        ) || dynamic_top
        with_compound_write_safe_nav(node, result)
      end

      def attribute_compound_read_type(node)
        receiver = type_of(node.receiver)
        MethodDispatcher.dispatch(
          receiver_type: receiver, method_name: node.read_name, arg_types: [],
          environment: scope.environment, call_node: node, scope: scope
        ) || dynamic_top
      end

      def with_compound_write_safe_nav(node, value)
        return value unless node.call_operator_loc&.slice == "&."

        Type::Combinator.union(value, Type::Combinator.constant_of(nil))
      end

      # Slice 2 routes call expressions through `MethodDispatcher`. The receiver and every argument are typed
      # first, then the dispatcher is asked for a result type. A nil result triggers the fail-soft fallback
      # for the CallNode itself (the inner type_of calls already record their own fallbacks for unrecognised
      # receivers/args, so the tracer captures both the immediate dispatch miss and the deeper cause).
      # `receiver_override` substitutes the receiver type for the whole pipeline (folds, dispatch, the
      # inference tiers) without re-reading the receiver node — the safe-navigation path (#518) dispatches
      # on the nil-stripped fragment, and the optional-receiver retry (#519) re-runs the pipeline on it.
      def call_dispatch_type_for(node, receiver_override: nil)
        narrowed = indexed_narrowing_for(node)
        return narrowed if narrowed

        receiver = receiver_override || call_receiver_type_for(node)
        arg_types = call_arg_types(node)
        block_type = block_return_type_for(node, receiver, arg_types)

        # ADR-103 WD13 — the effect collector's one hot-path site. Purely observational: it reads the
        # receiver type the typer has just computed and the `dynamic_origins` cause already recorded, and
        # asks nothing further of dispatch. Off (the default) this is one integer read.
        Effects::Collector.record_call(node, receiver, scope) if Effects::Collector.active?

        literal_send = try_literal_send(node, receiver)
        return literal_send if literal_send

        local_def_result = try_local_def_dispatch(node, receiver, arg_types)
        return local_def_result if local_def_result

        # v0.0.6 phase 2 — per-element block fold for Tuple receivers. When `[a, b, c].map { |x| f(x) }` and
        # the receiver is a `Tuple` carrier with finite elements, type the block body once per position with
        # the corresponding element bound to the block parameter and assemble the results into a
        # `Tuple[U_1..U_n]`. This sits ahead of `MethodDispatcher.dispatch` so the RBS tier does not re-widen
        # the answer back to `Array[union]`.
        block_fold = try_receiver_block_folds(node, receiver, arg_types)
        return block_fold if block_fold

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

        dispatch_miss_result(node, receiver, arg_types)
      end

      # The post-dispatch tiers for a call `MethodDispatcher` could not answer, in their historical
      # order; extracted from {#call_dispatch_type_for} whole.
      def dispatch_miss_result(node, receiver, arg_types)
        # v0.0.2 #5 — inter-procedural inference for user-defined methods. When dispatch misses but the
        # receiver is a user class with a `def` body, re-type the body with the call's argument types bound
        # and return the body's last-expression type.
        user_inference = try_user_method_inference(receiver, node, arg_types)
        return user_inference if user_inference

        # Module-singleton call resolution (ADR-57 follow-up) — when the receiver is `Singleton[Foo]` (a
        # module/class constant or a singleton-method `self`) and `Foo` declares a user-side `def self.x` /
        # `module_function` body, re-type that body with the call args bound. Sits after the RBS dispatch
        # tier, so foreign / RBS-known singletons (`Math.sqrt`) keep their catalog answer; only
        # project-defined singleton methods reach here.
        singleton_inference = try_project_singleton_inference(receiver, node, arg_types)
        return singleton_inference if singleton_inference

        # Dynamic-origin propagation: when the receiver is Dynamic[T] and no positive rule resolves the call,
        # the result inherits the dynamic origin. Per the value-lattice algebra, this is a recognised
        # semantic outcome, not a fail-soft compromise, so it MUST NOT record a tracer event.
        return inherit_receiver_origin(node) if receiver.is_a?(Type::Dynamic)

        # Issue #519 — a `T | nil` receiver whose dispatch exhausted every tier: the nil arm vetoed the
        # union (dispatch_union declines when ANY member declines, and the later tiers refuse unions), so
        # `StringScanner?#scan` lost a type its RBS fully declares. Retry the whole pipeline on the
        # non-nil fragment and answer its result: the nil path raises, which is `possible-nil-receiver`'s
        # job (that rule reads the RECEIVER and is untouched); the value describes the path that returns
        # (ADR-5 optimism, same polarity as the accessor-read nil-drop ADR-58 records). Unions whose
        # non-nil members still decline fall through unchanged.
        optional_retry = try_non_nil_receiver_retry(node, receiver)
        return optional_retry if optional_retry

        unresolved_call_result(node, receiver)
      end

      def try_non_nil_receiver_retry(node, receiver)
        return nil unless receiver.is_a?(Type::Union)
        # When NilClass DEFINES the method (`nil?`, `to_s`, `==`, `inspect`, …), the nil arm is a live
        # returner, not the veto — the union declined on some other member, and answering the stripped
        # receiver's result would drop the nil arm's contribution (`(Journal | nil).nil?` must never
        # answer the non-nil arm's constant-folded `false`). Retry only when the nil path raises.
        return nil if nil_class_defines?(node.name)

        non_nil = Narrowing.narrow_non_nil(receiver)
        # Structural equality, not identity: `narrow_non_nil` rebuilds a Union even when it removed
        # nothing, and an identity check would send a nil-free union that exhausts dispatch through the
        # retry forever. A Dynamic fragment is excluded too: its retry can only re-answer Dynamic, and
        # running the pipeline twice for that non-answer perturbs the flow bookkeeping for nothing.
        return nil if non_nil.is_a?(Type::Bot) || non_nil.is_a?(Type::Dynamic) || non_nil == receiver

        call_dispatch_type_for(node, receiver_override: non_nil)
      end

      # Conservative when NilClass's definition is unavailable: without the proof that the nil path
      # raises, the retry stays off.
      def nil_class_defines?(method_name)
        definition = Rigor::Reflection.instance_definition("NilClass", scope: scope)
        return true if definition.nil?

        !definition.methods[method_name.to_sym].nil?
      end

      # The engine choke-point where a call has exhausted every resolution tier (RBS dispatch + user-class
      # ancestor walk) and falls through to `Dynamic[top]`. Two observational recorders read it, both a
      # plain integer read when inactive, and neither changes the answer:
      #
      # - ADR-24 slice 4a captures an implicit-self miss so a later slice's closed-class gate can flag it;
      # - ADR-103 WD13 retracts the effect collector's optimistic `resolved: true`, which is what separates
      #   an implicit-self call the closed world has no definition for from an ordinary inherited one.
      def unresolved_call_result(node, receiver)
        record_unresolved_self_call(node, receiver) if Analysis::SelfCallResolutionRecorder.active?
        Effects::Collector.record_unresolved(node, scope.source_path) if Effects::Collector.active?

        fallback_for(node, family: :prism, origin: unresolved_call_origin(receiver, node.name))
      end

      # Issue #522 — the honest cause for a call the tiers exhausted. When the receiver's class HAS a
      # discovered project def for the method, the miss is a return the engine could not infer (the
      # discovered-method tier deliberately declined in favor of body inference, which then declined too —
      # `MethodDispatcher#try_discovered_method`'s decline arms), which is ADR-82's
      # `INFERRED_RETURN_UNTYPED`, not "unsupported syntax". Without this, every service-object `#call`
      # whose body defeats inference reports to `coverage --protection` as a syntax gap. The generic cause
      # stays for genuinely unresolved names (framework DSL sends, methods no scanned file defines).
      def unresolved_call_origin(receiver, method_name)
        class_name, kind = case receiver
                           when Type::Nominal then [receiver.class_name, :instance]
                           when Type::Singleton then [receiver.class_name, :singleton]
                           else [nil, nil]
                           end
        return DynamicOrigin::UNSUPPORTED_SYNTAX if class_name.nil?
        return DynamicOrigin::UNSUPPORTED_SYNTAX unless scope.discovered_method?(class_name, method_name, kind)

        DynamicOrigin::INFERRED_RETURN_UNTYPED
      end

      # ADR-82 WD6 — carry the receiver's provenance onto the call it produces (returning the unchanged
      # `dynamic_top` result), so a specific cause survives a method chain (`x.foo.bar`): without this,
      # `.foo` on a Dynamic `x` records nothing and `.bar`'s receiver looks causeless. Side-channel only
      # (the result type is untouched); a nil cause is skipped. This is the lever for the
      # intermediate-expression / chain receivers that dominate a real app's `coverage --protection`
      # catch-all.
      def inherit_receiver_origin(node)
        inherited = OriginLookup.origin_for(scope, node.receiver)
        scope.record_dynamic_origin(node, inherited) if inherited
        dynamic_top
      end

      # ADR-24 slice 4a — records an unresolved *implicit-self* call (no explicit receiver) whose `self`
      # types to a concrete user class. Explicit-receiver misses are out of scope (the existing
      # `call.undefined-method` rule already owns receiver-typed dispatch); a non-`Nominal` self (top-level /
      # DSL-block `self`, or a `Dynamic` self) is skipped so the gradual guarantee is never touched here.
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

      # The recorder must capture *existence* misses, not type misses. Reaching the choke-point means RBS
      # dispatch produced no result, but a project method can still EXIST without an inferable return type —
      # a `module_function` sibling whose body the engine can't fully type, an `attr_reader` /
      # `define_method` / `Data.define` member. Recording those would reproduce the 135 false positives of
      # slice-4 attempt 1. So skip any name the engine's own existence signals already know: a `def`
      # resolvable through the ancestor walk, or an own-class entry in the discovered-methods table (`def` /
      # `attr_*` / `define_method` / alias). This reuses the engine's real resolution — the "collect, don't
      # recompute" lesson — so only a name that exists nowhere a project signal can see reaches the recorder.
      # `module_function` records its defs as `:singleton` (an implicit-self call inside such a method
      # dispatches to the module's singleton method), while ordinary instance methods record `:instance`. The
      # recorder cannot tell the two contexts apart from the call node, so existence under EITHER kind
      # suppresses recording — the FP-safe choice, since either means the method genuinely exists.
      def self_call_method_known?(class_name, method_name)
        return true if resolve_user_def_through_ancestors(class_name, method_name)

        scope.discovered_method?(class_name, method_name, :instance) ||
          scope.discovered_method?(class_name, method_name, :singleton)
      end

      # v0.0.2 #5 — re-types the body of a user-defined instance method with the call site's argument types
      # bound to the method's parameters. Used as a last-resort tier after `MethodDispatcher.dispatch` has
      # exhausted its catalogue (RBS, shape, constant folding, user-class fallback). Returns nil when:
      #
      # - the receiver is not `Nominal[T]` for some T;
      # - no def_node is recorded for that class/method (the receiver is foreign or has only an RBS sig);
      # - the def has no body, or has a parameter shape we cannot bind from the call's positional args;
      # - the inference is already in progress for this (class, method, signature) tuple — recursion safety
      #   net.
      # v0.0.3 A — re-types a top-level (or DSL-block-nested) `def` discovered by `ScopeIndexer` under the
      # `TOP_LEVEL_DEF_KEY` sentinel. Mirrors the `infer_user_method_return` shape but uses the current
      # `scope.self_type` (or implicit `Object`) as the receiver carrier so the body's own self is
      # consistent with the call site's. Returns nil when the parameter shape disqualifies the def, when the
      # body is empty, or when a recursion cycle is detected.
      def infer_top_level_user_method(def_node, receiver, arg_types)
        infer_user_method_return(def_node, receiver, arg_types)
      rescue StandardError
        nil
      end

      # ADR-24 slice 1 — implicit-self method-call resolution. `discovered_def_nodes` is now carried into
      # method / class body scopes (see `StatementEvaluator#build_fresh_body_scope`), so a call written with
      # no explicit receiver inside a method body resolves against the enclosing class's own definitions and
      # the file's top-level defs. Before slice 1 every such call typed `Dynamic[top]`.
      #
      # The resolved return type is adopted UNCONDITIONALLY — a resolved user-method call site reads the
      # callee's inferred return, exactly as a toplevel call has since v0.0.3.
      #
      # ADR-24 WD3 originally gated this: inside a class / method body only a `Bot` return was adopted,
      # everything else stayed `Dynamic[top]`, because an early unconditional-adoption experiment regressed
      # `rigor check lib` by 16 diagnostics. ADR-55 / ADR-56 then chipped the gate open for the
      # recursive-fixpoint summary and the value-pinned unroll envelope. ADR-57 closed the arc: it re-ran the
      # gate-open experiment per engine generation and adjudicated every firing as genuine-or-artifact,
      # fixing the artifacts at their root — the tail-only body evaluator dropping explicit `return` (slice
      # 1), multi-value returns not contributing a Tuple (slice 1), escaping block-captured content mutation
      # surviving as a precise seed both inline and across a method boundary (slices 2/3), two over-strict
      # self-authored RBS signatures (slice 1), and an over-optional tuple-slot destructure (slice 3). With
      # the residual all genuine-or-win, the gate opened permanently on 2026-06-12 (ADR-57 WD2): the
      # gate-open `rigor check lib` + plugin self-check delta is zero, and the Mastodon / haml / kramdown
      # corpora show only adjudicated wins (a more precise error message; FP removals).
      #
      # The historical `adoptable_self_call_result?` predicate (its `self_type.nil?` / `Bot` /
      # fixpoint-summary / unroll special cases) is now subsumed by unconditional adoption and removed;
      # `try_local_def_dispatch` / `try_user_method_inference` simply return the inferred return.
      # `clamp_unroll_result` still backstops an untrustworthy unrolled value independently of adoption.

      # An extended (value-keyed) guard frame is `[plain_signature, value_key]` where `plain_signature` is
      # itself the `[receiver, method]` pair; a plain frame is that pair directly.
      def extended_frame?(frame)
        frame.is_a?(Array) && frame.size == 2 && frame.first.is_a?(Array)
      end

      # The plain `(receiver, method)` signature carried by a guard frame: the frame itself for a plain
      # frame, or its first element for an extended (value-keyed) frame.
      def plain_part(frame)
        extended_frame?(frame) ? frame.first : frame
      end

      # True when `type` is a concrete value — a `Type::Constant` or a `Type::Tuple` whose elements are
      # (recursively) all value-pinned. ADR-55 slice 1: a value-pinned self-call result is adopted even
      # inside a class/method body (where WD3 otherwise keeps non-`Bot` returns as `Dynamic[top]`). A
      # concrete value at a call site is strictly more precise and can never enable an undefined-method or
      # argument-type false positive — it is FP-neutral by construction.
      def fully_value_pinned?(type)
        case type
        when Type::Constant then true
        when Type::Tuple then type.elements.all? { |element| fully_value_pinned?(element) }
        else false
        end
      end

      # #525 — instance-side user-method inference accepts the named ADR-48 member carriers alongside
      # plain nominals: a `Line = Struct.new(...) do ... end` value is a StructInstance whose block defs
      # live under "Line", and the carrier itself is the right `self` for the body (member reads inside
      # the def project through it).
      def user_inference_receiver?(receiver)
        case receiver
        when Type::Nominal then true
        when Type::StructInstance, Type::DataInstance then !receiver.class_name.nil?
        else false
        end
      end

      # The three receiver-shaped block folds, in their historical order (extracted whole from
      # `call_dispatch_type_for` for method-length budget).
      def try_receiver_block_folds(node, receiver, arg_types)
        per_element = try_per_element_block_fold(node, receiver)
        return per_element if per_element

        inject_fold = try_block_inject_fold(node, receiver, arg_types)
        return inject_fold if inject_fold

        try_hash_shape_block_fold(node, receiver)
      end

      # Issue #533 — `x.send(:selector, args)` with a LITERAL symbol is statically `x.selector(args)`:
      # the private-boundary idiom (protobuf's `send(:get_file_descriptor)` at 84 sites) resolves through
      # the same dispatch + project-inference tiers as the direct call would. `send` legitimately crosses
      # visibility, so no public-only gate applies (`public_send` is treated identically — typing the
      # success path of a call that would raise on a private method is ADR-5 optimism). Declines: a
      # non-literal selector, a splat / forwarded tail (positional correspondence unknown), or a block at
      # the call site (block forwarding is out of this slice).
      LITERAL_SEND_SELECTORS = %i[send __send__ public_send].freeze
      private_constant :LITERAL_SEND_SELECTORS

      def try_literal_send(node, receiver)
        return nil unless LITERAL_SEND_SELECTORS.include?(node.name)
        return nil unless node.block.nil?

        args = node.arguments&.arguments
        return nil unless args && args.first.is_a?(Prism::SymbolNode)

        rest = args[1..]
        return nil if rest.any? { |a| a.is_a?(Prism::SplatNode) || a.is_a?(Prism::ForwardingArgumentsNode) }

        inner_name = args.first.unescaped.to_sym
        inner_args = rest.map { |a| type_of(a) }
        MethodDispatcher.dispatch(
          receiver_type: receiver, method_name: inner_name, arg_types: inner_args,
          block_type: nil, environment: scope.environment, call_node: node, scope: scope
        ) ||
          try_user_method_inference(receiver, node, inner_args, method_name: inner_name) ||
          try_project_singleton_inference(receiver, node, inner_args, method_name: inner_name)
      end

      def try_user_method_inference(receiver, call_node, arg_types, method_name: call_node.name)
        return nil unless user_inference_receiver?(receiver)

        def_node, owner = resolve_user_def_with_owner(receiver.class_name, method_name)
        return nil if def_node.nil?

        result = infer_user_method_return(def_node, receiver, arg_types,
                                          self_fold_safe: fold_safe_call_receiver?(call_node, receiver))
        return result if result.nil?

        degrade_if_overridable(result, owner, method_name, :instance)
      rescue StandardError
        nil
      end

      # Issue #525 — whether the RECEIVER EXPRESSION of this call is one whose struct member map is still
      # current. Three arms:
      #
      # - a call that MATERIALISES the struct (`Point.new(…)`, `Point[…]`, `Struct.new(:x).new(…)`, a
      #   `.with(…)` copy) — the object was created by this very expression, so nothing has run against it;
      # - a local the fold-safe scan proved is never mutated / aliased / escaped;
      # - `nil` / `self`, inheriting the CURRENT body's own grant, which is what lets a chain of
      #   implicit-self readers propagate: `Line.new(…).outer` grants `outer`'s body `:self`, and an
      #   `inner` call inside it carries the grant into `inner`'s body.
      #
      # The first arm shares `StructFolding`'s materialisation test with the direct member-read gate. Neither
      # accepts a bare chained call: "chained" is not "fresh" once a method can hand back its own receiver,
      # and a self-returning fluent builder is ordinary Ruby:
      #
      #     Line = Struct.new(:text) do
      #       def with_text(v) = (self.text = v; self)
      #       def shout       = text.upcase
      #     end
      #     Line.new("a").with_text("z").shout   # runtime "Z"
      #
      # Accepting the `with_text(…)` receiver as fresh would grant `shout` a member map two statements
      # stale and fold `"A"`. Only the shapes the folding layer itself materialises qualify here.
      #
      # This is only a property of the receiver expression; whether the grant is actually issued also needs
      # a `StructInstance` carrier and a body that survives the self-use scan, both decided in
      # {#build_user_method_body_scope}.
      def fold_safe_call_receiver?(call_node, receiver)
        return false if call_node.nil?

        case call_node.receiver
        when Prism::CallNode then materialization_call?(call_node.receiver, receiver)
        when Prism::LocalVariableReadNode then scope.struct_fold_safe?(call_node.receiver.name)
        when nil, Prism::SelfNode then scope.struct_fold_safe?(:self)
        else false
        end
      end

      # Issue #595 — the materialisation test lives ONCE, in
      # [`struct_materialization.rb`](method_dispatcher/struct_materialization.rb), because the direct
      # member-read gate ({MethodDispatcher::StructFolding}`#fresh_receiver?`) needs the identical answer;
      # see {MethodDispatcher::StructMaterialization.materialization_call?}. It resolves its own `.with`
      # guard through `Scope`, so neither consumer supplies a lookup and neither can answer differently.
      def materialization_call?(node, receiver)
        MethodDispatcher::StructMaterialization.materialization_call?(node, receiver, scope)
      end

      # Module-singleton call resolution (ADR-57 follow-up) — resolves `Foo.<name>` on a `Singleton[Foo]`
      # receiver against `Foo`'s user-side singleton defs (`def self.x`, `def Foo.x`, a `class << self`
      # body, or a `module_function` method) and re-types the body with the call's argument types bound.
      # The body scope's `self_type` is the SAME `Singleton[Foo]` carrier, so an implicit-self call inside
      # (`def self.via; helper(x); end`) re-enters this tier and resolves against the same singleton table
      # — the symmetric counterpart of the instance-side ancestor walk.
      #
      # Resolution is OWN-class only: the singleton-ancestry chain (`extend`ed modules, inherited
      # class-method dispatch) is not walked at this slice. A miss degrades to today's `Dynamic[top]`, never
      # a false resolution (ADR-57 follow-up § module-singleton).
      def try_singleton_method_inference(receiver, call_node, arg_types, method_name: call_node.name)
        return nil unless receiver.is_a?(Type::Singleton)

        def_node = scope.singleton_def_for(receiver.class_name, method_name)
        return nil if def_node.nil?

        result = infer_user_method_return(def_node, receiver, arg_types)
        return result if result.nil?

        degrade_if_overridable(result, receiver.class_name, method_name, :singleton)
      rescue StandardError
        nil
      end

      # The project-side singleton-method band: a `Foo.bar` call resolved against a `class << …` / `def self.…`
      # body the project itself wrote. Which of the two tiers applies is decided by the receiver carrier —
      # `Singleton[Foo]` when the constant names a class or module, `Nominal[…]` when it holds an ordinary
      # object (#320) — so the two are mutually exclusive and consulting both is one resolution attempt.
      def try_project_singleton_inference(receiver, call_node, arg_types, method_name: call_node.name)
        try_singleton_method_inference(receiver, call_node, arg_types, method_name: method_name) ||
          try_singleton_object_constant_inference(receiver, call_node, arg_types, method_name: method_name)
      end

      # #320 — resolves a call whose receiver is a constant holding an ordinary object with a `class << Const`
      # singleton body, re-typing that body with the call's argument types bound. `self` inside the body IS
      # that object, so the receiver carrier is passed through unchanged. Own-constant only, and only for a
      # name the project actually recorded — a miss degrades to today's `Dynamic[top]`, never a false
      # resolution. `Singleton` receivers never reach here: {#try_singleton_method_inference} owns them.
      def try_singleton_object_constant_inference(receiver, call_node, arg_types, method_name: call_node.name)
        return nil unless receiver.is_a?(Type::Nominal)

        def_node = SingletonObjectConstant.def_node_for(call_node, receiver, method_name, scope)
        return nil if def_node.nil?

        infer_user_method_return(def_node, receiver, arg_types)
      rescue StandardError
        nil
      end

      # ADR-24 slice 2 — resolves `method_name` against `class_name`'s own `def`s, then walks the user-class
      # ancestor chain: included / prepended modules (transitive) and the superclass chain. RBS-known
      # ancestors are NOT walked here — the `MethodDispatcher` RBS tier runs before
      # `try_user_method_inference` and already covers them; an ancestor name that resolves to no
      # project-discovered class/module ends that branch. Cross-file: the chain is followed through
      # `Scope#discovered_superclasses` / `#discovered_includes` / `#discovered_def_nodes`, which the runner
      # seeds from the project-wide pre-pass. The walk is breadth-first, cycle-guarded, and node-count-capped.

      CLASS_GRAPH_CACHE_KEY = :__rigor_class_graph_cache__
      private_constant :CLASS_GRAPH_CACHE_KEY

      # Run-scoped memo for the static class-graph resolvers below. They are pure functions of the *frozen*
      # project index trio (`discovered_def_nodes` / `discovered_superclasses` / `discovered_includes`) —
      # `user_def_for` / `superclass_of` / `includes_of` read nothing else, and never touch the current
      # scope's locals or narrowings — so a result computed for one `(class, method)` is valid for every
      # `Scope` that shares those tables. `ExpressionTyper` is rebuilt per `Scope#type_of`, so the memo lives
      # on `Thread.current` rather than on `self`. It is keyed by the *identity* of the three frozen tables
      # (nested `compare_by_identity` stores): a new analysis generation, or any `Scope` that swaps an index
      # via `with_discovered_*`, transparently lands in a fresh bucket while everything sharing the tables
      # shares the memo. Steady-state cost is three identity-keyed hash reads and zero allocation — the `||=`
      # chains only allocate on the first miss of a generation. (Pool mode forks per worker, so the
      # `Thread.current` store is process-local and never crosses a project boundary.)
      def class_graph_buckets
        store = (Thread.current[CLASS_GRAPH_CACHE_KEY] ||= {}.compare_by_identity)
        by_def = (store[scope.discovered_def_nodes] ||= {}.compare_by_identity)
        by_super = (by_def[scope.discovered_superclasses] ||= {}.compare_by_identity)
        # `self_pure` is issue #525's grant scan (identity-keyed by def node); it belongs here because it
        # is a pure function of the same frozen index trio — the sibling resolver it walks reads nothing
        # else.
        by_super[scope.discovered_includes] ||= { name: {}, user_def: {}, self_pure: {}.compare_by_identity }
      end

      def resolve_user_def_through_ancestors(class_name, method_name)
        resolve_user_def_with_owner(class_name, method_name).first
      end

      # ADR-57 N5 follow-up — resolves the method's def node AND the ancestor that owns it (the class/module
      # whose own `def` table holds the body, which may differ from `class_name` when the method is
      # inherited from a superclass or included module). The owner is what the overridable-method adoption
      # gate keys on. Both are cached together (the walk is identical to the def-only path it replaced) and
      # returned as a `[def_node, owner]` pair; `owner` is nil exactly when `def_node` is nil.
      def resolve_user_def_with_owner(class_name, method_name)
        cache = class_graph_buckets[:user_def]
        table = (cache[class_name.to_s] ||= {})
        key = method_name.to_sym
        return table[key] if table.key?(key)

        table[key] = compute_user_def_with_owner(class_name, method_name)
      end

      # ADR-24 slice 2 — the walk itself lives on `Scope` ({Scope#user_def_through_ancestors}); it reads
      # nothing but the frozen discovery index, and the `.with` guard in
      # {MethodDispatcher::StructMaterialization} needs the SAME answer without threading dispatcher state
      # through the dispatcher (#598 review). What stays here is the caching: the run-scoped
      # `(class_name, method_name)` memo above, plus the per-edge name bucket handed to the walk so a class
      # whose many methods are resolved pays each ancestor edge once.
      def compute_user_def_with_owner(class_name, method_name)
        scope.user_def_through_ancestors(class_name, method_name,
                                         name_memo: class_graph_buckets[:name])
      end

      # ADR-57 N5 — overridable-method adoption gate. A self-call resolved to a project `def` whose owner has
      # a discovered subclass / includer that REDEFINES the same method (same instance-vs-singleton kind) is
      # a template-method site: the base body's literal return is the *default*, not the value every
      # receiver sees, so adopting it as a flow constant is unsound (rgl `module Graph; def directed?; false`
      # folds `unless directed?` always-true, ignoring `DirectedAdjacencyGraph` overriding it to `true` — the
      # entire rgl warning set, per the 2026-06-13 app/network survey N5 row). On such a hit the precise
      # return degrades to `Dynamic[top]`, deliberately re-opening a Dynamic source ONLY for
      # genuinely-overridden methods. A method with no discovered override folds exactly as before —
      # over-conservatism must not re-open Dynamic for final methods.
      #
      # The gate only inspects a *flow-constant-foldable* result (a `Constant`, or a `Tuple` of such): only a
      # value-pinned return can mislead a downstream `if`/`unless`/`case` into an `always-truthy-condition`
      # fold, which is exactly the unsoundness the gate exists to remove. A `Nominal` / `Dynamic` / union
      # return cannot produce a flow constant, so adopting it from an overridden method is harmless and is
      # left untouched — this keeps the override-relation walk off the hot path for the overwhelming
      # majority of self-calls (whose return is not a bare constant).
      def degrade_if_overridable(result, owner, method_name, kind)
        return result if owner.nil?
        return result unless fully_value_pinned?(result)
        return result unless overridden_in_project?(owner.to_s, method_name, kind)

        dynamic_top
      end

      OVERRIDE_GATE_CACHE_KEY = :__rigor_overridable_method_gate__
      private_constant :OVERRIDE_GATE_CACHE_KEY

      # Run-scoped memo for {#overridden_in_project?}, keyed (like `class_graph_buckets`) by the identity of
      # the frozen discovery trio so a new analysis generation lands in a fresh bucket, then nested `kind →
      # owner → method_name`. The predicate is a pure function of those tables. Nesting avoids allocating a
      # composite cache key on the hot path (the gate runs on every adopted self-call return), so a
      # steady-state hit is three identity hash reads + two string/symbol hash reads with zero allocation.
      def override_gate_buckets
        store = (Thread.current[OVERRIDE_GATE_CACHE_KEY] ||= {}.compare_by_identity)
        by_def = (store[scope.discovered_def_nodes] ||= {}.compare_by_identity)
        by_super = (by_def[scope.discovered_superclasses] ||= {}.compare_by_identity)
        by_super[scope.discovered_includes] ||= { instance: {}, singleton: {} }
      end

      # True when some discovered project class/module — distinct from `owner` — redefines `(method_name,
      # kind)` AND is related to `owner` (a transitive discovered subclass of an owner class, or a
      # class/module that includes/prepends — extends, for singleton kind — an owner module). A same-name
      # reopen of `owner` itself is NOT an override (monkey-patch reopen shares the owner identity). Memoized
      # per `(owner, method_name, kind)`.
      def overridden_in_project?(owner, method_name, kind)
        by_owner = (override_gate_buckets[kind][owner] ||= {})
        return by_owner[method_name] if by_owner.key?(method_name)

        by_owner[method_name] = compute_overridden_in_project?(owner, method_name, kind)
      end

      def compute_overridden_in_project?(owner, method_name, kind)
        redefiners_of(method_name, kind).any? do |candidate|
          next false if candidate == owner

          related_to_owner?(candidate, owner)
        end
      end

      # Every discovered project class/module whose OWN def table redefines `(method_name, kind)`. Instance
      # kind reads `discovered_def_nodes`, singleton kind reads `discovered_singleton_def_nodes` — both are
      # genuine project `def` bodies (not RBS / accessor synthesis), so a name's presence is a real
      # redefinition. Served from a per-generation inverted index (`method_name → [owner names]`) built once
      # per def table, so the lookup is a single hash read rather than a full-table scan on every
      # `(method_name, kind)` first-miss — the gate runs on every adopted self-call return, so the full-table
      # `filter_map` it replaced was the dominant added allocation on a large `lib`.
      def redefiners_of(method_name, kind)
        method_definers_index(kind)[method_name] || EMPTY_REDEFINERS
      end

      EMPTY_REDEFINERS = [].freeze
      private_constant :EMPTY_REDEFINERS

      METHOD_DEFINERS_INDEX_KEY = :__rigor_method_definers_index__
      private_constant :METHOD_DEFINERS_INDEX_KEY

      # Per-generation `method_name (Symbol) → [owner names]` inverted index over the instance / singleton
      # def tables, memoised by the identity of the def table it inverts (a new analysis generation lands in
      # a fresh bucket). The toplevel sentinel is excluded — a toplevel `def` has no class ancestry and so
      # can never be an override.
      def method_definers_index(kind)
        table = kind == :singleton ? scope.discovered_singleton_def_nodes : scope.discovered_def_nodes
        store = (Thread.current[METHOD_DEFINERS_INDEX_KEY] ||= {}.compare_by_identity)
        store[table] ||= build_method_definers_index(table)
      end

      def build_method_definers_index(table)
        index = {}
        table.each do |class_name, methods|
          next if class_name == Inference::ScopeIndexer::TOP_LEVEL_DEF_KEY

          methods.each_key { |method_name| (index[method_name] ||= []) << class_name }
        end
        index
      end

      # True when `candidate`'s transitive ancestor chain (superclasses + included/prepended modules) reaches
      # `owner` — i.e. `candidate` is a subclass of an owner class or an includer of an owner module. Reuses
      # the same BFS resolver the method-resolution ancestor walk uses, so name resolution (lexical nesting,
      # RBS-known-ancestor pruning) is identical.
      # Delegates to the shared walk's edge step so this BFS and method resolution resolve ancestor names
      # identically, sharing the per-edge memo bucket.
      def enqueue_ancestors(current, queue)
        scope.enqueue_ancestors(current, queue, class_graph_buckets[:name])
      end

      def related_to_owner?(candidate, owner)
        queue = []
        enqueue_ancestors(candidate, queue)
        seen = {}
        visited = 0
        until queue.empty?
          current = queue.shift
          next if current.nil? || seen[current]

          return true if current == owner

          seen[current] = true
          visited += 1
          return false if visited > Scope::ANCESTOR_WALK_LIMIT

          enqueue_ancestors(current, queue)
        end
        false
      end

      INFERENCE_GUARD_KEY = :__rigor_user_method_inference_stack__
      private_constant :INFERENCE_GUARD_KEY

      INFERENCE_UNROLL_FUEL_KEY = :__rigor_user_method_unroll_fuel__
      private_constant :INFERENCE_UNROLL_FUEL_KEY

      # ADR-55 slice 2 — thread-local fixpoint return-summary table, keyed by the plain `(receiver, method)`
      # signature (NOT the value-extended signature: extended frames from slice 1 share the same summary).
      # Each entry is `{ assumption:, consulted: }` where `assumption` is the current Kleene iterate (seeded
      # `bot`) and `consulted` flips true when an in-cycle re-entry returns it.
      INFERENCE_SUMMARY_KEY = :__rigor_user_method_return_summary__
      private_constant :INFERENCE_SUMMARY_KEY

      # Monotonic per-thread counter, bumped once each time `consult_summary` actually reads an in-flight
      # fixpoint assumption (ADR-55 slice 2). A method return computed across an interval in which this
      # counter does NOT move depended on no transient Kleene iterate, so it is FINAL and safe to memoise —
      # even when the `summaries` table is non-empty because some unrelated outermost frame merely *seeded*
      # (but never consulted) its own entry. See `infer_user_method_return`'s post-hoc memo gate.
      SUMMARY_CONSULT_COUNTER_KEY = :__rigor_user_method_summary_consults__
      private_constant :SUMMARY_CONSULT_COUNTER_KEY

      # Per-thread append-only log of the seed depths of every in-flight summary `consult_summary` read
      # (ADR-55 slice 2 mutual-recursion soundness fix, 2026-06-12). Each fixpoint owner records the guard
      # stack size at seed time on its entry (`depth:`); a consult appends the consulted entry's depth here.
      # A fixpoint whose body evaluation logged a depth SHALLOWER than its own seed depth read an ancestor
      # signature's transient Kleene iterate -- cross-signature mutual recursion (`even?`/`odd?`) -- so its
      # computed return is entangled with a not-yet-converged foreign assumption and must degrade to
      # `untyped` rather than fold one branch's seed into a "final" constant. Own-signature consults log
      # depth == own depth, and a nested fixpoint that completes within the evaluation logs depths > own
      # depth; neither is foreign. Cleared with the summary table when the guard stack drains to empty.
      SUMMARY_CONSULT_DEPTHS_KEY = :__rigor_user_method_summary_consult_depths__
      private_constant :SUMMARY_CONSULT_DEPTHS_KEY

      # ADR-57 follow-up — run-scoped memo for resolved user-method return types. The ADR-57 gate-open made
      # every resolved in-body self-call adopt the callee's inferred return, which re-types the callee body
      # once per call site. With a project-wide discovery index, file N re-types callees defined in files
      # 1..N-1, so whole-`lib` cost grows superlinearly in files-per-process (the 2026-06-12 Rails survey's
      # whole-`lib` scaling wall).
      #
      # `infer_user_method_return` is a pure function of `(def_node, receiver, arg_types)` PLUS the frozen
      # project discovery index: `build_user_method_body_scope` binds the args to the params in a FRESH
      # `Scope` seeded from an empty fact / narrowing store and inherits `scope.discovery` whole by
      # reference — the caller's narrowing state never enters. (This is what makes a signature-keyed return
      # memo sound where the ADR-52 WD5 per-call-NODE contribution cache was not: that cache keyed
      # scope-sensitive results on the node; this memo keys a scope-INSENSITIVE result on its real inputs.)
      #
      # Two dimensions are call-site-varying and so live IN the key: the receiver carrier
      # (`describe(:short)`) and the argument-type signature (`describe(:short)` of each arg) — value-pinned
      # args change folds (`factorial(5)` vs `factorial(6)`), so a coarser key would serve a stale fold. The
      # third unsafe dimension — the ADR-55 recursion machinery (unroll fuel / fixpoint Kleene
      # assumption / WD1 clamp) producing a TRANSIENT result rather than a final return — is excluded
      # post-hoc (ADR-84 WD3): candidacy only requires that the plain signature not already be on the
      # recursion guard stack (a frame inside its own cycle returns a Kleene iterate by construction), and
      # the store gate brackets the compute over the transient-event depth log
      # (TRANSIENT_EVENT_DEPTHS_KEY), refusing only when an event referenced a frame BELOW the bracket's
      # entry depth — proof the ancestor context (an in-flight ancestor summary, the shared unroll fuel, a
      # possibly-ancestor-caused clamp) influenced the result. Events at-or-above the entry depth are the
      # compute's own deterministic machinery — a recursive method's own converged fixpoint stores from a
      # top-of-stack entry (standalone by construction: fuel reseeds, summary tables cleared at the
      # previous drain) — and a nested compute whose bracket saw no below-entry event ran as if standalone
      # (fuel consumed without exhausting is invisible; every summary read fires a logged guard event). A
      # memo HIT while an unroll is merely in flight elsewhere on the stack is legal (stored values are
      # final and context-free). This replaced the blanket unroll-in-flight candidacy exclusion, which
      # refused 82% of mail's body evaluations for results that were overwhelmingly final (PR #79
      # counters; ADR-84).
      #
      # Bucket scope (ADR-84 WD2): ONE bucket per analysis run, keyed by the identity of the run-generation
      # token `Analysis::Runner#run_analysis` mints and seeds through `scope.discovery` — hits cross
      # consumer-file boundaries within a run, and a re-run in the same process (LSP re-check, ADR-62 warm
      # loop) rolls the bucket over. Scopes without a runner seed (single-file probes) fall back to the
      # per-file merged `discovered_def_nodes` identity — exactly the pre-WD2 per-file scope. Inside the
      # bucket, entries key on the `def_node`'s object identity (the identity Hash holds the node strongly,
      # so a collected parse can never recycle an object id into a stale hit) and then on the
      # `[receiver, *args]` descriptor tuple; a callee may appear under at most two node identities per run
      # (the project-index parse every OTHER file resolves through, plus the defining file's own analysis
      # parse). Only the current generation's bucket is retained (single slot) — a rolled-over run's entries
      # become garbage instead of accumulating across LSP runs. `ExpressionTyper` is rebuilt per
      # `Scope#type_of`, so the store lives on `Thread.current`; fork-pool workers are separate processes,
      # so it never crosses a project boundary (ADR-84 WD5).
      RETURN_MEMO_KEY = :__rigor_user_method_return_memo__
      private_constant :RETURN_MEMO_KEY

      # ADR-84 WD2 — one memo entry: the final inferred return plus, when the entry was computed under
      # ADR-46 dependency recording, the frozen `Analysis::DependencyRecorder::ReadSet` its body walk
      # produced (nil on non-recording runs — recording is decided per run and the bucket never outlives a
      # run, so a recording run only ever hits entries that carry a read-set; pinned by
      # return_memo_recording_spec's rollover example). ADR-89 WD2 additionally carries the CALL DESCRIPTOR
      # (`receiver` + `arg_types`) so the incremental session can harvest each observed call key and persist
      # it as a return-summary — a recheck re-evaluates the (declaration-stable) callee at those keys and,
      # when every return is unchanged, skips its symbol dependents. Carrying two frozen type refs is
      # negligible on the memo-store path (already in scope) and never enters memo equality (entries are
      # keyed by `memo_key`, retrieved by `.result` / `.read_set`).
      MemoEntry = Data.define(:result, :read_set, :receiver, :arg_types)
      private_constant :MemoEntry

      # ADR-84 WD3 — thread-local transient-machinery event log, appended by `note_transient_fallback` at
      # EVERY site where the ADR-55 recursion machinery substitutes transient state for a plain body
      # evaluation. Each entry is the STACK POSITION (guard-stack index) of the frame whose in-flight state
      # the event referenced — the consulted owner for a guard hit, 0 for the whole-stack resources (shared
      # unroll fuel; conservatively the clamp), the owner's own position for its cap collapse.
      # `consult_and_store_return_memo` brackets a candidate's compute over the log and refuses to store
      # only when an event referenced a frame BELOW the bracket's entry depth: such an event proves the
      # ancestor context influenced the result, while events at-or-above the entry depth are the compute's
      # OWN deterministic machinery (a recursive method's own converged fixpoint, a sub-cycle that opened
      # and closed inside the bracket) which a standalone recompute reproduces event-for-event. A
      # top-of-stack compute (entry depth 0) can never see a below-entry event — it is standalone by
      # construction (fuel reseeds on an empty stack, the summary tables were cleared at the previous
      # drain). Cleared with the other per-outermost-entry tables when the guard stack drains. LOAD-BEARING:
      # unlike `BudgetTrace` counters the log must be maintained on every run, not only under
      # RIGOR_BUDGET_TRACE.
      #
      # Audit table (ADR-84 WD3) — every early-return / fallback in the recursion machinery, each either
      # LOGGED (routes through `note_transient_fallback` with the referenced frame's position) or PROVABLY
      # FINAL (a deterministic pure function of the frame's own inputs, so a standalone recompute
      # reproduces it):
      #
      #   compute_user_method_return
      #     - in-cycle re-entry (`stack.include?(signature)` → `consult_summary`)  LOGGED at the consulted
      #       owner's stack position (the outermost frame carrying the plain signature — the seeder whose
      #       in-flight Kleene iterate the re-entry returns)
      #   evaluate_guarded_user_method_body
      #     - non-outermost plain evaluation, clamp pass-through                   PROVABLY FINAL (plain
      #       body eval; nested transient events log at their own sites)
      #     - `clamp_unroll_result` clamp branch (ADR-55 WD1 → `untyped`)          LOGGED at 0 (the
      #       would-have-been-guarded match may be an ancestor frame; position not threaded — conservative)
      #   fixpoint_user_method_return
      #     - `degrade_entangled_fixpoint` (foreign in-flight consult)             LOGGED at the degrading
      #       owner's own position (the foreign consult that caused it was already logged at the ancestor's
      #       position by the guard site, which is what taints the enclosing brackets)
      #     - "summary never consulted" early return (body did not recurse)        PROVABLY FINAL
      #     - `resolve_bot_collapse` (widened re-run / explicit-return floor)      PROVABLY FINAL in itself
      #       (deterministic); transient events inside the re-run log at their own sites
      #     - `fixpoint_step` convergence (`joined == assumption`)                 converged value; any
      #       consults the iterations performed were already LOGGED at the guard site
      #     - `fixpoint_step` cap collapse (`RECURSION_FIXPOINT_CAP` → `untyped`)  LOGGED at the owner's own
      #       position (per-owner constant cap — deterministic for every enclosing bracket; the iterates'
      #       context-dependence, if any, logs separately at its own sites)
      #   unroll helpers
      #     - `unroll_fuel_remaining` exhaustion (extended key denied → plain)     LOGGED at 0 (fuel is ONE
      #       shared resource seeded at stack bottom, so a nested frame's unroll budget depends on what ran
      #       before it — the hazard the blanket exclusion used to over-approximate)
      #     - `constant_argument_value_key` / `pinned_value_descriptor` nil        PROVABLY FINAL (pure
      #       functions of `arg_types`)
      #
      # Adding a fallback? Route it through `note_transient_fallback` unless it is provably final in the
      # sense above — position 0 is always a sound (conservative) choice; spec/rigor/inference/
      # return_memo_taint_spec.rb pins this (no raw `BudgetTrace.hit` on the recursion categories outside
      # the helper).
      TRANSIENT_EVENT_DEPTHS_KEY = :__rigor_user_method_transient_event_depths__
      private_constant :TRANSIENT_EVENT_DEPTHS_KEY

      # Per-inference recursion context threaded through the guard / fixpoint helpers (ADR-55 slice 2).
      # Bundles the call descriptor (`receiver`, `arg_types`, `plain_signature`), the thread-local summary
      # table, and the WD1 clamp flag so the helpers stay within the parameter-list budget. `def_node` is
      # carried separately (it is the body owner, not call context).
      RecursionContext = Data.define(
        :receiver, :arg_types, :plain_signature, :summaries, :would_have_been_guarded,
        :self_fold_safe
      )
      private_constant :RecursionContext

      # Total body evaluations the fixpoint iteration is permitted per outermost entry for a signature
      # (ADR-55 WD2). Hard, non-configurable — the iteration cap is part of the termination story (ADR-41
      # WD4).
      RECURSION_FIXPOINT_CAP = 3
      private_constant :RECURSION_FIXPOINT_CAP

      # Hard, non-configurable caps for the ADR-55 slice 1 constant-arg unroll. `RECURSION_UNROLL_FUEL`
      # bounds the number of extended (value-keyed) frames per outermost inference entry;
      # `RECURSION_VALUE_SIZE_CAP` disqualifies a frame whose pinned argument values are structurally large.
      # Both are termination guards (ADR-41 WD4) — not measurement-gated precision budgets — so they ship
      # default-on with no opt-in.
      RECURSION_UNROLL_FUEL = 32
      private_constant :RECURSION_UNROLL_FUEL

      RECURSION_VALUE_SIZE_CAP = 64
      private_constant :RECURSION_VALUE_SIZE_CAP

      # `self_fold_safe` (issue #525) is the caller's statement that its RECEIVER EXPRESSION was foldable;
      # {#build_user_method_body_scope} turns it into the body scope's `:self` sentinel when the carrier and
      # the body both qualify. It does NOT need its own memo-key slot here — the bit is observable on the
      # built `body_scope`, which is where every downstream consumer (the memo key, the recursion context)
      # reads it from, so the two can never disagree.
      def infer_user_method_return(def_node, receiver, arg_types, self_fold_safe: false)
        return nil if def_node.body.nil?

        body_scope = build_user_method_body_scope(def_node, receiver, arg_types,
                                                  self_fold_safe: self_fold_safe)
        return nil if body_scope.nil?

        # Recursion-guard signature. Keyed on `(receiver, method)` only — NOT the argument types. ADR-24 WD5:
        # a method whose summary is still being computed resolves to `Dynamic[top]` for that cycle. Keying on
        # arg types would let mutual recursion through a `module_function` module (`Acceptance#accepts` →
        # `accepts_one` → `accepts_dynamic` → `accepts`) recurse unboundedly whenever the carried argument
        # types differ at each level — observed as a `SystemStackError` once implicit-self calls began
        # resolving during the main walk. `describe(:short)` keeps non-Nominal receivers (the implicit
        # `Object` carrier for top-level / DSL-block defs) printable.
        plain_signature = [receiver.describe(:short), def_node.name]
        stack = (Thread.current[INFERENCE_GUARD_KEY] ||= [])
        summaries = (Thread.current[INFERENCE_SUMMARY_KEY] ||= {})

        # WD0 (RIGOR_BUDGET_TRACE) — one entry into user-method return inference. No-op when disabled.
        BudgetTrace.hit(BudgetTrace::MEMO_ENTRIES)

        # ADR-57 follow-up — return memo. The inferred return is a pure function of `(def_node, receiver,
        # arg_types)` and the frozen discovery index whenever the computation does NOT depend on a transient
        # ADR-55 Kleene assumption (an in-flight fixpoint summary). Two structural preconditions decide
        # whether THIS frame's result is even a memo candidate, both stable across the body walk: the
        # signature must not already be on the recursion guard stack (else we are inside its own cycle) and
        # no constant-arg unroll may be in flight (its value-keyed frames are transient). When both hold we
        # consult the memo, and on a miss we compute, then store the result only if no fixpoint summary was
        # *consulted* during the computation (the post-hoc consult-counter check) — which is sound
        # regardless of whether the `summaries` table holds inert *seeded-but-unconsulted* entries left by
        # unrelated outermost frames. This is the fix for the whole-`lib` scaling wall: a deep DAG of
        # non-recursive private readers (ActiveStorage `video_analyzer.rb`) seeded a summary on its first
        # outermost method and thereafter the old `summaries.empty?` gate disabled the memo for every nested
        # call, re-walking the shared sub-readers combinatorially (~932k body evaluations for ~20 tiny
        # methods). The computation itself lives in `compute_user_method_return`.
        unless memo_candidate?(stack, plain_signature)
          trace_memo_refusal(stack, plain_signature)
          return compute_user_method_return(def_node, body_scope, stack, summaries,
                                            receiver, arg_types, plain_signature)
        end

        # INVARIANT (ADR-46 recording soundness, ADR-84 WD2) — the deep cross-file dependency edges (the
        # reads a callee body's dispatches perform through the instrumented `Scope` accessors) are recorded,
        # per consumer, only as a side effect of evaluating that body, and a memo hit serves the return
        # WITHOUT re-evaluating it. Since the bucket is run-scoped, hits CROSS consumer-file boundaries, so
        # every cross-file hit is PAIRED WITH CACHE-AND-REPLAY of the callee's read-set: under recording,
        # the first evaluation of a key captures the recorder events of its body walk
        # (`DependencyRecorder.capture` — observe-and-forward, so the first consumer's own record is
        # untouched) onto the entry, and a hit replays that set into the current consumer's accumulator
        # (`DependencyRecorder.replay`, which re-applies the per-consumer self-read filter). A memo hit is
        # thereby edge-equivalent to a fresh body evaluation for EVERY consumer. The naive alternative —
        # bypassing the memo while the recorder is active — measured >200x wall on analyzer-shaped files
        # (ActiveStorage video_analyzer.rb's subtree, 0.43s -> >90s; PR #79) and stays rejected. Pinned by
        # spec/rigor/inference/return_memo_recording_spec.rb (cross-file replay completeness) and
        # dependency_recorder_spec.rb's transitive deep-edge example.
        consult_and_store_return_memo(def_node, body_scope, stack, summaries,
                                      receiver, arg_types, plain_signature)
      end

      # The candidate-frame memo path: consult the current run generation's bucket, and on a miss compute
      # and store a FINAL result. Reached only when `memo_candidate?` held (see `infer_user_method_return`).
      # The store gate (ADR-84 WD3): a result is stored when the ADR-55 fixpoint consult counter did not
      # move across the compute (the WD0 `MEMO_REFUSE_CONSULT_TAINTED` non-store) AND no transient-machinery
      # event during the bracket referenced a stack frame BELOW the bracket's entry depth (see
      # TRANSIENT_EVENT_DEPTHS_KEY). Below-entry events — an ancestor's in-flight Kleene iterate read by a
      # guard hit, a shared-fuel exhaustion, a possibly-ancestor-caused WD1 clamp — mean the ancestor
      # context influenced `result`, which a standalone recompute would not reproduce; at-or-above-entry
      # events are the compute's own deterministic machinery (its own converged fixpoint, sub-cycles that
      # opened and closed inside the bracket) and do not block the store. A top-of-stack compute (entry
      # depth 0) is standalone by construction. A hit under ADR-46 recording replays the entry's captured
      # read-set into the current consumer (see the INVARIANT comment at the call site).
      def consult_and_store_return_memo(def_node, body_scope, stack, summaries,
                                        receiver, arg_types, plain_signature)
        per_def = (return_memo_bucket[def_node] ||= {})
        # Issue #525 — the `:self` fold-safety grant is a THIRD call-site-varying dimension: the same
        # `(receiver, arg_types)` body returns a folded member type when the caller's receiver expression
        # was foldable and `Dynamic[top]` when it was not. Without it in the key the first call site to
        # reach a def would poison every later one with the other polarity. It is read off the body scope
        # rather than passed in, so the key cannot drift from the scope that produced the result.
        memo_key = [receiver.describe(:short),
                    arg_types.map { |type| type.describe(:short) },
                    body_scope.struct_fold_safe?(:self)]
        if (entry = per_def[memo_key])
          BudgetTrace.hit(BudgetTrace::MEMO_HITS)
          Analysis::DependencyRecorder.replay(entry.read_set) if Analysis::DependencyRecorder.active?
          return entry.result
        end
        BudgetTrace.hit(BudgetTrace::MEMO_MISSES)
        trace_distinct_memo_key(plain_signature, def_node, memo_key)

        entry_depth = stack.size
        event_mark = transient_event_mark
        consults_before = summary_consult_count
        result, read_set = compute_with_read_capture(def_node, body_scope, stack, summaries,
                                                     receiver, arg_types, plain_signature)

        if summary_consult_count != consults_before
          BudgetTrace.hit(BudgetTrace::MEMO_REFUSE_CONSULT_TAINTED)
        elsif context_tainted?(event_mark, entry_depth)
          BudgetTrace.hit(BudgetTrace::MEMO_REFUSE_TRANSIENT)
        else
          per_def[memo_key] = MemoEntry.new(result: result, read_set: read_set,
                                            receiver: receiver, arg_types: arg_types)
        end
        result
      end

      def transient_event_mark
        Thread.current[TRANSIENT_EVENT_DEPTHS_KEY]&.size || 0
      end

      def summary_consult_count
        Thread.current[SUMMARY_CONSULT_COUNTER_KEY] || 0
      end

      # ADR-84 WD3 — true when a transient-machinery event logged during the bracket (entries past
      # `event_mark`) referenced a frame below `entry_depth`. The log is cleared when the guard stack drains
      # (only possible mid-bracket for a top-of-stack compute, whose events are deterministic anyway), so a
      # missing / shorter log reads as untainted.
      def context_tainted?(event_mark, entry_depth)
        log = Thread.current[TRANSIENT_EVENT_DEPTHS_KEY]
        return false if log.nil? || log.size <= event_mark

        log[event_mark..].any? { |depth| depth < entry_depth }
      end

      # ADR-84 WD2 — the memo-miss compute, wrapped in a `DependencyRecorder.capture` window when ADR-46
      # recording is active so the entry can carry its replayable read-set. Returns `[result, read_set]`
      # (`read_set` nil when not recording).
      def compute_with_read_capture(def_node, body_scope, stack, summaries,
                                    receiver, arg_types, plain_signature)
        unless Analysis::DependencyRecorder.active?
          return [compute_user_method_return(def_node, body_scope, stack, summaries,
                                             receiver, arg_types, plain_signature), nil]
        end

        Analysis::DependencyRecorder.capture do
          compute_user_method_return(def_node, body_scope, stack, summaries,
                                     receiver, arg_types, plain_signature)
        end
      end

      # The ADR-55 recursion-guard + value-unroll + fixpoint body of user-method return inference, factored
      # out so `infer_user_method_return` is a thin memo wrapper (the memo is the ADR-57 follow-up; this is
      # unchanged from pre-memo behaviour).
      def compute_user_method_return(def_node, body_scope, stack, summaries,
                                     receiver, arg_types, plain_signature)
        trace_body_eval(plain_signature)
        # ADR-55 slice 1: when every bound argument is value-pinned, extend the guard key with a stable
        # descriptor of the argument *values* so distinct constant frames may recurse (e.g. `factorial(5)`
        # folds to `Constant[120]`). Distinct constant frames are bounded by `RECURSION_UNROLL_FUEL` per
        # outermost entry; exhaustion or value blow-up falls back to the plain `(receiver, method)` guard —
        # today's behaviour. Non-constant args never reach this path.
        signature = plain_signature
        value_key = constant_argument_value_key(arg_types)
        extended = value_key && unroll_fuel_remaining(stack).positive?
        signature = [plain_signature, value_key] if extended

        if stack.include?(signature)
          # ADR-84 WD3 — the referenced frame is the consulted owner: the OUTERMOST frame carrying this
          # plain signature (the seeder whose in-flight iterate the re-entry returns).
          note_transient_fallback(BudgetTrace::RECURSION_GUARD,
                                  stack.index { |frame| plain_part(frame) == plain_signature } || 0)
          # ADR-55 slice 2: in-cycle re-entries return the current assumed summary (Kleene iterate, seeded
          # `bot`) instead of bare `untyped`. The fixpoint loop below seeds the entry on the outermost frame;
          # if a re-entry beats it here the entry already exists. The WD4 composition: slice 1's clamp/fuel
          # fallbacks also route here when a summary is active.
          return consult_summary(summaries, plain_signature)
        end

        # ADR-55 WD1 clamp (governing rule): the constant-arg unroll may only ever surface a fully
        # value-pinned result; any other outcome must be byte-identical to the plain guard's `untyped`. A
        # frame that took the extended (value-keyed) path but whose plain `(receiver, method)` signature is
        # already on the stack — in plain form or as the plain part of an extended frame — would have been
        # guarded before slice 1. If such a frame's body folds to a non-pinned type, the unroll surfaced a
        # precise value the plain guard would have masked (and the body evaluator's blind spots can make
        # that value wrong), so clamp it back to `untyped`.
        would_have_been_guarded =
          extended &&
          stack.any? { |frame| plain_part(frame) == plain_signature }

        context = RecursionContext.new(
          receiver: receiver, arg_types: arg_types, plain_signature: plain_signature,
          summaries: summaries, would_have_been_guarded: would_have_been_guarded,
          # Issue #525 — read off the built scope so the bot-collapse retry rebuilds a widened scope with
          # the SAME `:self` polarity the first attempt used; a retry that silently dropped the grant would
          # return a different type for the same call.
          self_fold_safe: body_scope.struct_fold_safe?(:self)
        )
        evaluate_guarded_user_method_body(def_node, body_scope, stack, signature, context)
      end

      # True when this frame's result is a candidate for the return memo: the one structural precondition,
      # stable across the body walk, that is necessary (but not sufficient) for a FINAL result — this plain
      # signature must not itself be on the recursion guard stack (else we are inside its own cycle,
      # returning a Kleene iterate by construction). Sufficiency is decided post-hoc in
      # `consult_and_store_return_memo` by the two bracket counters (fixpoint consults + ADR-84 WD3
      # transient-machinery events) — so unlike the prior form this deliberately does NOT refuse while a
      # constant-arg unroll is in flight: a nested frame whose compute finishes without a single transient
      # event ran exactly as it would standalone (fuel consumption without exhaustion is invisible), and
      # the blanket exclusion refused 82% of mail's body evaluations for such final results (ADR-84).
      def memo_candidate?(stack, plain_signature)
        stack.none? { |frame| plain_part(frame) == plain_signature }
      end

      # Run-scoped return-memo bucket (ADR-84 WD2): a single retained slot keyed by the identity of the
      # run-generation token the runner seeds (`Scope#run_generation`), falling back to the per-file merged
      # `def_nodes` table identity for runner-less scopes (single-file probes) — the pre-WD2 per-file
      # scope. A generation mismatch drops the previous bucket whole, so a re-run in one process (LSP,
      # ADR-62 warm loop) can neither hit stale entries nor accumulate them. The bucket maps `def_node`
      # (object identity, held strongly — see RETURN_MEMO_KEY) to its per-descriptor entries.
      def return_memo_bucket
        generation = scope.run_generation || scope.discovered_def_nodes
        slot = Thread.current[RETURN_MEMO_KEY]
        unless slot && slot[0].equal?(generation)
          slot = [generation, {}.compare_by_identity]
          Thread.current[RETURN_MEMO_KEY] = slot
        end
        slot[1]
      end

      # WD0 (RIGOR_BUDGET_TRACE) trace helpers. Each guards on `BudgetTrace.enabled?` before doing any work
      # beyond a single boolean check, so a normal run pays nothing (no signature-label string built, no
      # stack scan). Attributes a non-candidate frame's non-store to on-stack vs unroll-in-flight; since
      # ADR-84 WD3 reduced candidacy to the on-stack check alone, the unroll-in-flight branch is
      # structurally unreachable and is kept only so the printed counter table still shows the category
      # (pinned ~0 — the ADR-84 WD3 gate).
      def trace_memo_refusal(stack, plain_signature)
        return unless BudgetTrace.enabled?

        if stack.any? { |frame| plain_part(frame) == plain_signature }
          BudgetTrace.hit(BudgetTrace::MEMO_REFUSE_ON_STACK)
        else
          BudgetTrace.hit(BudgetTrace::MEMO_REFUSE_UNROLL)
        end
      end

      # The observed member is the full `(def-node identity, receiver, args)` entry key, so the per-signature
      # count also surfaces the ADR-84 WD2 dual-parse duplication (project-index parse vs the defining
      # file's own parse — at most 2 node identities per def per run).
      def trace_distinct_memo_key(plain_signature, def_node, memo_key)
        return unless BudgetTrace.enabled?

        BudgetTrace.observe_distinct(
          BudgetTrace::MEMO_DISTINCT_KEY_BY_SIGNATURE, signature_label(plain_signature),
          [def_node.object_id, memo_key]
        )
      end

      def trace_body_eval(plain_signature)
        return unless BudgetTrace.enabled?

        BudgetTrace.hit(BudgetTrace::MEMO_BODY_EVALS)
        BudgetTrace.observe(BudgetTrace::MEMO_BODY_EVAL_BY_SIGNATURE, signature_label(plain_signature))
      end

      # `"Receiver#method"` label for a `[receiver_descriptor, method_name]` plain signature — the bucket key
      # for the WD0 per-signature distributions. Built only under `BudgetTrace.enabled?`.
      def signature_label(plain_signature)
        "#{plain_signature[0]}##{plain_signature[1]}"
      end

      # ADR-84 WD3 — the single choke point every transient-machinery fallback routes through: appends the
      # referenced frame's stack position to the load-bearing thread-local event log (regardless of
      # RIGOR_BUDGET_TRACE) and forwards the category to `BudgetTrace`. The taint spec pins that no
      # recursion-machinery `BudgetTrace.hit` exists outside this helper, so a future fallback cannot
      # silently join unlogged (see the audit table at TRANSIENT_EVENT_DEPTHS_KEY; `context_depth` 0 is
      # always a sound conservative choice).
      def note_transient_fallback(category, context_depth)
        (Thread.current[TRANSIENT_EVENT_DEPTHS_KEY] ||= []) << context_depth
        BudgetTrace.hit(category)
      end

      # Pushes the recursion-guard frame, evaluates the body (the outermost frame for a plain signature runs
      # the ADR-55 slice 2 fixpoint; nested extended frames evaluate once and let the owner iterate), and on
      # the way out pops the frame and resets the per-outermost-entry fuel and summary tables when the guard
      # stack drains to empty.
      def evaluate_guarded_user_method_body(def_node, body_scope, stack, signature, context)
        # The outermost frame for this plain signature owns the summary entry and runs the fixpoint loop.
        # ADR-55 WD2.
        outermost = stack.none? { |frame| plain_part(frame) == context.plain_signature }
        stack.push(signature)
        begin
          if outermost
            fixpoint_user_method_return(def_node, body_scope, context)
          else
            type, = evaluate_body_with_returns(body_scope, def_node.body)
            clamp_unroll_result(type, context.would_have_been_guarded)
          end
        ensure
          stack.pop
          if stack.empty?
            Thread.current[INFERENCE_UNROLL_FUEL_KEY] = nil
            Thread.current[INFERENCE_SUMMARY_KEY] = nil
            Thread.current[SUMMARY_CONSULT_DEPTHS_KEY] = nil
            Thread.current[TRANSIENT_EVENT_DEPTHS_KEY] = nil
          end
        end
      end

      # Evaluates a method body and joins the value types of every explicit `return value` reached during
      # the walk with the body's tail type.
      #
      # The tail-only evaluator (`statements_type_for` → `type_of(body.last)`) models only the fall-through
      # value; an early `return false` or a block-internal `return x` produces `Bot` at its own position and
      # is otherwise invisible to method-return inference. Without this join a predicate helper shaped
      # `return false unless cond; ...; true` infers `Constant[true]` (the early `return false` dropped),
      # which folds `if helper` to always-truthy. `StatementEvaluator.with_return_sink` collects the returns
      # (nested `def`/lambda are barriers; block-internal returns correctly bubble to the enclosing method)
      # so the inferred return is `tail | return_1 | … | return_n`, matching Ruby semantics.
      def evaluate_body_with_returns(body_scope, body)
        (type, post_scope), returns = StatementEvaluator.with_return_sink do
          body_scope.evaluate(body)
        end
        joined = returns.empty? ? type : Type::Combinator.union(type, *returns)
        [joined, post_scope]
      end

      # ADR-55 slice 2 — Kleene fixpoint over a recursive method's return summary. Seeds the assumption to
      # `bot`, evaluates the body, and (only if the summary was actually consulted during evaluation — i.e.
      # the method really recursed) iterates: if the computed return is subsumed by the assumption the
      # fixpoint is reached; otherwise the assumption joins in the computed return and the body re-evaluates.
      # Capped at `RECURSION_FIXPOINT_CAP` total evaluations; the final permitted iteration widens
      # value-pinned constituents to their nominal base to force convergence, and any residual instability
      # collapses to `untyped` (today's behaviour).
      def fixpoint_user_method_return(def_node, body_scope, context, widened: false)
        plain_signature = context.plain_signature
        summaries = context.summaries
        depth = seed_fixpoint_summary(summaries, plain_signature)
        consult_depths = (Thread.current[SUMMARY_CONSULT_DEPTHS_KEY] ||= [])
        computed = nil

        RECURSION_FIXPOINT_CAP.times do |iteration|
          summaries[plain_signature][:consulted] = false
          consult_mark = consult_depths.size
          type, = evaluate_body_with_returns(body_scope, def_node.body)
          computed = clamp_unroll_result(type, context.would_have_been_guarded)

          # Cross-signature mutual recursion (ADR-55 soundness fix, 2026-06-12): the evaluation consulted an
          # ANCESTOR signature's in-flight summary (seed depth shallower than this frame's), so `computed`
          # embeds a transient foreign Kleene iterate -- e.g. `odd?` folding `even?`'s seeded `bot` into
          # `Constant[false]`. The per-signature iteration below cannot converge such an entangled pair (each
          # side's iterate is conditioned on the other's unfinished assumption), so degrade this frame to the
          # sound `untyped` floor instead of surfacing a one-sided value.
          if consult_depths[consult_mark..].any? { |d| d < depth }
            return degrade_entangled_fixpoint(summaries, plain_signature)
          end

          # The summary was never consulted — the method did not recurse on this evaluation, so there is no
          # fixpoint to chase. Return the computed type directly (pre-fixpoint behaviour for non-recursive
          # bodies that merely share `infer_user_method_return`).
          return computed unless summaries.dig(plain_signature, :consulted)

          # ADR-55 slice 2 bot-collapse fix (2026-06-11). When the recursive method's only contribution this
          # evaluation was the seeded `bot` assumption (so `computed` is `bot` even though the body
          # recursed), the `joined == assumption` check below would trivially converge at the seed and
          # return `bot` — UNSOUND for a method with a reachable non-recursive exit (`passthrough` returns
          # `:done`, `pick` returns `nil`). `bot` means "never returns", which feeds ADR-47 reachability /
          # always-falsey diagnostics, so it must be reserved for genuinely diverging methods (`spin`).
          if computed.is_a?(Type::Bot)
            resolved = resolve_bot_collapse(def_node, context, widened: widened)
            return resolved unless resolved.nil?
          end

          step = fixpoint_step(summaries, plain_signature, computed, iteration)
          return step unless step == :continue
        end
      end

      # Seeds the thread-local summary entry for a fixpoint owner: the `bot` Kleene seed plus the
      # guard-stack depth at seed time (the frame for this signature is already pushed), which
      # `consult_summary` logs so nested fixpoints can detect a foreign in-flight (ancestor) consult.
      # Returns the seed depth. ADR-55 slice 2.
      def seed_fixpoint_summary(summaries, plain_signature)
        depth = (Thread.current[INFERENCE_GUARD_KEY] || []).size
        summaries[plain_signature] = {
          assumption: Type::Combinator.bot, consulted: false, depth: depth
        }
        depth
      end

      # Degrades an entangled mutual-recursion fixpoint to the sound `untyped` floor (ADR-55 mutual-recursion
      # soundness fix, 2026-06-12), parking `untyped` in the assumption so any consumer that still reads
      # this signature's summary sees the floor, not the stale `bot` seed.
      def degrade_entangled_fixpoint(summaries, plain_signature)
        # ADR-84 WD3 — logged at the degrading owner's own position: the foreign consult that caused the
        # entanglement was already logged at the ANCESTOR's position by the guard site.
        note_transient_fallback(BudgetTrace::RECURSION_GUARD, own_guard_frame_position)
        scope.record_dynamic_origin(@typing_node, DynamicOrigin::ANALYZER_BUDGET_CUTOFF) if @typing_node
        summaries[plain_signature][:assumption] = Type::Combinator.untyped
        Type::Combinator.untyped
      end

      # The stack position of the currently-evaluating owner frame (the guard stack's top) — the
      # self-referential `context_depth` for events that are deterministic per owner (ADR-84 WD3).
      def own_guard_frame_position
        size = Thread.current[INFERENCE_GUARD_KEY]&.size || 0
        size.positive? ? size - 1 : 0
      end

      # One Kleene-iteration step of the fixpoint loop. Joins `computed` into the running assumption
      # (widening value-pinned constituents on the final permitted iteration to force convergence) and
      # either returns a final type — convergence, or the capped `untyped` collapse — or `:continue` to
      # request another body evaluation, having advanced the stored assumption. ADR-55 WD2.
      def fixpoint_step(summaries, plain_signature, computed, iteration)
        assumption = summaries[plain_signature][:assumption]
        last_iteration = iteration == RECURSION_FIXPOINT_CAP - 1
        candidate = last_iteration ? widen_value_pinned(computed) : computed
        joined = Type::Combinator.union(assumption, candidate)

        # Convergence: the assumption already subsumes the computed return
        # (joining it back changes nothing).
        return candidate if joined == assumption

        if last_iteration
          # Out of iterations and still unstable — collapse to today's widening behaviour. ADR-84 WD3: the
          # cap is a per-owner constant, so the event references the owner's own frame.
          note_transient_fallback(BudgetTrace::RECURSION_FIXPOINT_CAP, own_guard_frame_position)
          scope.record_dynamic_origin(@typing_node, DynamicOrigin::ANALYZER_BUDGET_CUTOFF) if @typing_node
          summaries[plain_signature][:assumption] = Type::Combinator.untyped
          return Type::Combinator.untyped
        end

        summaries[plain_signature][:assumption] = joined
        :continue
      end

      # Rebuilds the user-method body scope with every bound positional parameter widened to its nominal
      # base (`1 | 2 | 3` → `Integer`, `Constant[:x]` → `Symbol`). Used by the bot-collapse retry in
      # `fixpoint_user_method_return`: call-site argument narrowing can prune a recursive method's base
      # case, and widening restores the declared-type view under which the base case is reachable. Returns
      # `nil` when the parameter shape is not inferable (mirrors `build_user_method_body_scope`).
      def widened_user_method_body_scope(def_node, receiver, arg_types, self_fold_safe: false)
        widened_args = arg_types.map { |arg_type| widen_value_pinned(arg_type) }
        build_user_method_body_scope(def_node, receiver, widened_args, self_fold_safe: self_fold_safe)
      end

      # ADR-55 slice 2 bot-collapse resolution (2026-06-11). Called when a fixpoint iteration computed `bot`
      # for a recursive body. Two escape hatches keep `bot` reserved for genuinely diverging methods:
      #
      #   1. Re-run the fixpoint ONCE over a parameter-widened body scope (`1 | 2 | 3` → `Integer`):
      #      call-site argument narrowing can prune a base-case *tail* branch (`n <= 0 ? :done : recurse`
      #      with a positive-only `n`), and widening un-prunes it so the base constituent (`:done`) surfaces.
      #      `passthrough` recovers here.
      #
      #   2. If the (possibly widened) body STILL computes `bot` but contains a reachable explicit `return`
      #      — whose value the tail-only body evaluator never folds into the result (`pick`'s `return nil`)
      #      — fall to the conservative `Dynamic[top]` floor (the pre-slice-2 observable) rather than the
      #      unsound `bot`.
      #
      # Returns the resolved type, or `nil` to let the caller's normal fixpoint convergence proceed (genuine
      # divergence — `spin`).
      def resolve_bot_collapse(def_node, context, widened:)
        unless widened
          widened_scope = widened_user_method_body_scope(def_node, context.receiver, context.arg_types,
                                                         self_fold_safe: context.self_fold_safe)
          return fixpoint_user_method_return(def_node, widened_scope, context, widened: true) unless widened_scope.nil?
        end

        return Type::Combinator.untyped if body_has_explicit_return?(def_node.body)

        nil
      end

      # True when `node` contains a reachable explicit `return` statement — one not nested inside a return
      # barrier (`def` / lambda / block). The tail-only body evaluator in `infer_user_method_return` never
      # folds an early-return value into the method result, so a recursive method whose base case is
      # spelled as `return value` (rather than a tail branch) looks like it only diverges. This detector is
      # the signal that such a method has a non-recursive exit, so its bot-collapse must floor to
      # `Dynamic[top]` rather than `bot` (ADR-55 slice 2, 2026-06-11).
      RETURN_BARRIER_NODES = [Prism::DefNode, Prism::LambdaNode, Prism::BlockNode].freeze
      private_constant :RETURN_BARRIER_NODES

      def body_has_explicit_return?(node)
        return false unless node.is_a?(Prism::Node)
        return false if RETURN_BARRIER_NODES.any? { |klass| node.is_a?(klass) }
        return true if node.is_a?(Prism::ReturnNode)

        found = false
        node.rigor_each_child do |child|
          next unless body_has_explicit_return?(child)

          found = true
          break
        end
        found
      end

      # Returns the current assumed summary for `plain_signature`, recording that it was consulted (so the
      # fixpoint owner knows the body actually recursed). Falls back to `untyped` when no summary is active
      # — e.g. a nested extended frame guarded before its plain signature seeded an entry, which is the
      # pre-slice-2 observable.
      def consult_summary(summaries, plain_signature)
        entry = summaries[plain_signature]
        return Type::Combinator.untyped if entry.nil?

        entry[:consulted] = true
        (Thread.current[SUMMARY_CONSULT_DEPTHS_KEY] ||= []) << entry[:depth]
        entry[:assumption]
      end

      # ADR-55 WD1 governing-rule clamp. When the just-evaluated frame took the extended (value-keyed) path
      # but its plain signature was already guarded (`would_have_been_guarded`), the unroll may only surface
      # a fully value-pinned result; any other outcome must be byte-identical to the plain guard's `untyped`
      # (and counts a `RECURSION_GUARD` hit, matching the pre-slice-1 observable).
      def clamp_unroll_result(type, would_have_been_guarded)
        return type unless would_have_been_guarded && !fully_value_pinned?(type)

        # ADR-84 WD3 — position 0 (conservative): the would-have-been-guarded match may be an ancestor
        # frame, and the matched position is not threaded through RecursionContext.
        note_transient_fallback(BudgetTrace::RECURSION_GUARD, 0)
        scope.record_dynamic_origin(@typing_node, DynamicOrigin::ANALYZER_BUDGET_CUTOFF) if @typing_node
        # ADR-55 WD1 clamp: a guarded extended frame whose body is non-pinned must be byte-identical to the
        # plain guard's `untyped`. This path deliberately does NOT route to the in-progress fixpoint summary:
        # the summary is a Kleene lower bound mid-iteration, while the clamp is a soundness backstop for an
        # untrustworthy unrolled value, so it must stay the conservative `untyped` upper bound. (WD4's
        # summary-composition applies to the in-cycle guard and fuel paths, which DO return the assumed
        # summary — see `consult_summary`.)
        Type::Combinator.untyped
      end

      # Widens every value-pinned constituent of `type` to its nominal base (`Constant[1]` → `Integer`,
      # `Tuple[Constant…]` → its element bases), leaving non-pinned constituents untouched. Used on the
      # fixpoint's final permitted iteration (ADR-55 WD2) to force convergence — the tower of distinct
      # constant iterates collapses to one nominal type.
      def widen_value_pinned(type)
        Type::Combinator.widen_value_pinned(type)
      end

      # Consumes one unit from the thread-local unroll-fuel counter and returns the units that were
      # available *before* this consumption (so a positive return means the extended value-key may be used).
      # Fuel is per-outermost inference entry: at the top level (empty guard stack) it seeds to
      # `RECURSION_UNROLL_FUEL`, and the `ensure` in `infer_user_method_return` clears it once the stack
      # drains back to empty. On exhaustion (return 0) it records a `RECURSION_UNROLL_FUEL` hit so the caller
      # keeps the plain `(receiver, method)` signature — today's behaviour.
      def unroll_fuel_remaining(stack)
        remaining = Thread.current[INFERENCE_UNROLL_FUEL_KEY]
        remaining = RECURSION_UNROLL_FUEL if remaining.nil? || stack.empty?
        if remaining.positive?
          Thread.current[INFERENCE_UNROLL_FUEL_KEY] = remaining - 1
        else
          # ADR-84 WD3 — position 0: fuel is one shared resource seeded at the stack bottom, so its
          # exhaustion is context-dependent for every nested bracket.
          note_transient_fallback(BudgetTrace::RECURSION_UNROLL_FUEL, 0)
        end
        remaining
      end

      # A stable, hashable descriptor of the argument values when EVERY element of `arg_types` is
      # value-pinned: a `Type::Constant`, or a `Type::Tuple` whose elements are (recursively) all
      # value-pinned. Returns nil when any argument is not value-pinned (the ordinary type-keyed path) or
      # when any pinned value's structural size exceeds `RECURSION_VALUE_SIZE_CAP` (value blow-up → fall
      # back).
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

      # Returns `[descriptor, structural_size]` for a value-pinned type, or nil for anything else. Strings
      # count by a cheap length proxy (length > 256 ≈ 64+ nodes) so a long built string disqualifies the
      # frame without a deep walk; tuples recurse.
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

      # Builds the body scope for a user-defined instance method call: a fresh `Scope` with `self_type` set
      # to the receiver's nominal type, the project-wide accumulators inherited (so the body sees the same
      # `discovered_classes` / `class_ivars` / etc. the caller does), and the call's `arg_types` bound to
      # the parameters. Returns nil when the binding is truly ambiguous (arity mismatch, trailing `post`
      # params, `...` forwarding).
      #
      # Issue #524 — the binder is per-PARAMETER, not per-signature. The first iteration declined any def
      # with an optional / rest / keyword / block parameter outright, so ONE `options = {}` default zeroed
      # out an otherwise-inferable return at every call site (the widest engine lever the 2026-09-01 sweep
      # measured, verified on ten targets). Now: requireds bind by index; supplied optionals by index and
      # unsupplied ones from a LITERAL default (else `Dynamic`); `*rest` collects the leftover positionals
      # as a Tuple; keywords bind by name from a trailing keyword-hash shape, falling back to their literal
      # default — or `Dynamic` when the shape is open or absent; `**kwrest`, `&block`, and destructured
      # positionals bind `Dynamic`. Binding `Dynamic` is monotone-safe (wider in → wider out), so the only
      # declines left are the shapes where positional CORRESPONDENCE itself is unknowable.
      def build_user_method_body_scope(def_node, receiver, arg_types, self_fold_safe: false)
        params = def_node.parameters
        locals = bind_params_from_call_types(params, arg_types)
        return nil if locals.nil?

        # Construct the body scope in a SINGLE allocation — the previous `Scope.empty.with_*.with_*…` chain
        # allocated a fresh frozen Scope per field, run per user-method-call inference (ADR-44). The
        # discovery index is inherited whole by reference (ADR-53 Track A); the hand-copied per-field list
        # this replaces had silently dropped `data_member_layouts` and `discovered_method_visibilities`.
        Scope.new(
          environment: scope.environment,
          locals: locals.freeze,
          self_type: receiver,
          # Issue #681 — the chain the walk recorded as it entered `def_node`'s own declaration. Without it
          # this scope carried a self type alone, and `Reflection.lexical_nesting_chain` fell back to peeling
          # `receiver`'s qualified name — which cannot tell a compact `class Admin::Maker` from the nested
          # spelling, and for an INHERITED body peels the subclass rather than the declaration that owns it.
          # The same `Post.new` then typed one way on the line that writes it and another through this
          # re-walk. `nil` for a top-level def and for a body restored from an ADR-85 seed bundle, both of
          # which keep the peel.
          lexical_nesting: scope.discovery.discovered_def_nestings[def_node],
          discovery: scope.discovery,
          struct_fold_safe_locals: body_fold_safe_locals(def_node, receiver, self_fold_safe),
          dynamic_origins: scope.dynamic_origins
        )
      end

      # The body scope's fold-safe set: the body's own struct locals, plus issue #525's `:self` sentinel
      # when the caller's receiver expression was foldable AND the carrier is a `StructInstance` AND the
      # body's every use of `self` is a pure read (no member setter, no escape, no unrecognised self-call —
      # see {Inference::StructFoldSafety.self_fold_safe_body?}). All three are required: the first is the
      # caller's evidence that the map is current on entry, the last two that the body keeps it current.
      def body_fold_safe_locals(def_node, receiver, self_fold_safe)
        locals = struct_fold_safe_locals_for(def_node.body)
        return locals unless self_fold_safe && receiver.is_a?(Type::StructInstance)
        return locals unless self_fold_safe_grant?(def_node, receiver)

        locals + [:self]
      end

      # The memoised entry point to the grant scan. Without the memo the walk re-runs on every
      # granted-CANDIDATE call, return-memo HITS included — the body scope is built before the memo is
      # consulted, so a hot call site pays the scan every time. Only the OUTERMOST scan is memoised: an
      # inner answer can rest on the cycle guard's `seen` set, which is not part of the key.
      def self_fold_safe_grant?(def_node, receiver)
        per_def = (class_graph_buckets[:self_pure][def_node] ||= {})
        key = [receiver.class_name, receiver.member_names]
        return per_def[key] if per_def.key?(key)

        per_def[key] = self_fold_safe_body?(def_node.body, receiver, [def_node])
      end

      # Whether `body`'s every use of `self` is a pure read, resolving each unrecognised self-call against
      # the receiver's own class so a body that DELEGATES can still hold the grant: `def outer; shout; end`
      # keeps it because `shout` reads a member, while `def go; reset!; text; end` loses it because `reset!`
      # writes one. `seen` breaks a mutual-call cycle by refusing (the conservative direction) and
      # `SELF_PURE_DEPTH` bounds the walk — an unresolvable name (`puts`, `raise`, a method from an RBS-only
      # ancestor) refuses too, so every answer this returns is backed by a body actually examined.
      SELF_PURE_DEPTH = 4
      private_constant :SELF_PURE_DEPTH

      def self_fold_safe_body?(body, receiver, seen)
        StructFoldSafety.self_fold_safe_body?(body, receiver.member_names) do |name|
          next false if seen.size > SELF_PURE_DEPTH

          sibling, = resolve_user_def_with_owner(receiver.class_name, name)
          next false if sibling.nil? || sibling.body.nil? || seen.include?(sibling)

          self_fold_safe_body?(sibling.body, receiver, seen + [sibling])
        end
      end

      # The locals table for the body scope, or nil to decline. Keys match `with_local`'s `name.to_sym`.
      # The body scope starts from an empty fact store and narrowing set, so `with_local`'s fact /
      # narrowing invalidations would be no-ops here — the table is built directly.
      def bind_params_from_call_types(params, arg_types)
        return arg_types.empty? ? {} : nil if params.nil?
        return nil unless bindable_param_shape?(params)

        positional = arg_types.dup
        kw_shape = positional.pop if takes_keywords?(params) && positional.last.is_a?(Type::HashShape)
        locals = bind_positional_params(params, positional)
        return nil if locals.nil?

        bind_keyword_params(params, kw_shape, locals)
        locals[params.keyword_rest.name.to_sym] = dynamic_top if params.keyword_rest&.name
        locals[params.block.name.to_sym] = dynamic_top if params.block&.name
        locals
      end

      # Trailing required positionals after a rest (`def f(a, *m, z)`) shift the correspondence; `...`
      # arrives as the keyword_rest slot. Both stay declined — correspondence, not width, is the issue.
      def bindable_param_shape?(params)
        params.is_a?(Prism::ParametersNode) &&
          params.posts.empty? &&
          !params.keyword_rest.is_a?(Prism::ForwardingParameterNode)
      end

      def takes_keywords?(params)
        params.keywords.any? || !params.keyword_rest.nil?
      end

      def bind_positional_params(params, positional)
        requireds = params.requireds
        optionals = params.optionals
        return nil if positional.size < requireds.size
        return nil if params.rest.nil? && positional.size > requireds.size + optionals.size

        locals = {}
        requireds.each_with_index { |param, index| bind_positional_param(locals, param, positional[index]) }
        optionals.each_with_index do |param, index|
          supplied = positional[requireds.size + index]
          locals[param.name.to_sym] = supplied || literal_default_type(param.value)
        end
        bind_rest_param(params, positional, locals)
        locals
      end

      def bind_rest_param(params, positional, locals)
        rest_name = params.rest&.name
        return if rest_name.nil?

        leftover = positional[(params.requireds.size + params.optionals.size)..] || []
        locals[rest_name.to_sym] = Type::Combinator.tuple_of(*leftover)
      end

      # A destructured positional (`def f((a, b))`) consumes one argument slot but binds its leaf names
      # `Dynamic` — element correspondence through the destructure is a later slice.
      def bind_positional_param(locals, param, arg_type)
        if param.is_a?(Prism::MultiTargetNode)
          Destructure.target_names(param).each { |name| locals[name.to_sym] = dynamic_top }
        else
          locals[param.name.to_sym] = arg_type
        end
      end

      def bind_keyword_params(params, kw_shape, locals)
        open_shape = kw_shape && kw_shape.extra_keys == :open
        params.keywords.each do |param|
          name = param.name.to_s.delete_suffix(":").to_sym
          supplied = kw_shape&.pairs&.[](name)
          locals[name] = supplied ||
                         (open_shape ? dynamic_top : keyword_default_type(param))
        end
      end

      def keyword_default_type(param)
        param.respond_to?(:value) && param.value ? literal_default_type(param.value) : dynamic_top
      end

      # A default expression contributes its type only when it is lexically scope-free — a scalar literal
      # or an EMPTY collection literal (`options = {}` is the dominant Rails idiom). Anything that could
      # read the def's own lexical scope binds `Dynamic` instead of being mis-typed in the caller's scope.
      LITERAL_DEFAULT_NODES = [
        Prism::IntegerNode, Prism::FloatNode, Prism::StringNode, Prism::SymbolNode,
        Prism::TrueNode, Prism::FalseNode, Prism::NilNode
      ].freeze
      private_constant :LITERAL_DEFAULT_NODES

      def literal_default_type(value_node)
        return dynamic_top if value_node.nil?
        return type_of(value_node) if LITERAL_DEFAULT_NODES.any? { |klass| value_node.is_a?(klass) }
        return type_of(value_node) if value_node.is_a?(Prism::ArrayNode) && value_node.elements.empty?
        return type_of(value_node) if value_node.is_a?(Prism::HashNode) && value_node.elements.empty?

        dynamic_top
      end

      # ADR-48 Struct slice 3 — the fold-safe-local set for a method body (runs only on a return-memo miss,
      # so the per-call cost is bounded — measured perf-neutral). Struct member layouts of constant
      # receivers are resolved through the discovery side-table the body scope inherits.
      def struct_fold_safe_locals_for(body)
        StructFoldSafety.fold_safe_locals(
          body,
          ->(name) { scope.struct_member_layout(name)&.[](:members) }
        )
      end

      # Slice A-engine. Implicit-self calls (no `node.receiver`) adopt the surrounding scope's `self_type`
      # as their receiver so calls like `attr_reader_method_name` or `private_helper(...)` inside an
      # instance method dispatch against the enclosing class. Slice 7 phase 10 — when `self_type` is nil
      # (top-level program), the receiver MUST default to `Nominal[Object]` so Kernel intrinsics like
      # `require`, `require_relative`, `raise`, and `puts` dispatch through Object/Kernel rather than
      # falling through to `Dynamic[Top]`.
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

      # When the call carries a `Prism::BlockNode`, build the block's entry scope (outer locals plus
      # parameter bindings driven by the receiving method's RBS signature), type the block body under that
      # scope, and return the body's value type. The result feeds `MethodDispatcher.dispatch`'s
      # `block_type:` so generic methods like `Array#map[U] { (Elem) -> U } -> Array[U]` resolve `U` to the
      # block's return type. Returns `nil` when the call has no block, when the receiver is unknown, or when
      # typing the body raises (defensive against malformed subtrees); the dispatcher then runs in its
      # no-block-aware path.
      #
      # ADR-14 gap-#3 (d): a `Prism::BlockArgumentNode` carrying `&:symbol` (the Symbol#to_proc shorthand) is
      # treated as a block. The block's return type is computed by dispatching `:symbol` on the expected
      # block param type (per `Symbol#to_proc`'s `{ |x| x.symbol }` semantics). A precise inner dispatch
      # produces the right return; any failure step falls back to `Dynamic[Top]` so the dispatcher still
      # SEES a block — selecting the block-bearing overload of e.g. `Hash#transform_values` over the
      # no-block overload that returns `Enumerator`.
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
        # ADR-16 Tier A: when a registered plugin's `block_as_methods` entry matches `(receiver_type,
        # call_node.name)`, narrow the block body's `self_type` to the receiver class's instance type. The
        # narrowing is `nil` for unmatched calls, leaving the existing scope contract unchanged.
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
          # Issue #316 — mirrors `StatementEvaluator#build_block_entry_scope`: the block body's `self` is the
          # yielding method's business, so the return-typing pass must see the same unmodelled-self mark.
          block_scope = bindings.reduce(scope.entering_opaque_block) do |acc, (name, type)|
            acc.with_local(name, type)
          end
          block_scope = block_scope.with_self_type(narrowed_self_type) if narrowed_self_type
          type_block_body(block_arg, block_scope)
        when Prism::BlockArgumentNode
          symbol_block_return_type(block_arg, expected)
        end
      end

      # `&:symbol` desugars to a one-arg Proc that dispatches `symbol` against its argument. When the param
      # type is known and the resulting inner dispatch is precise, this returns the precise carrier;
      # otherwise it returns `Dynamic[Top]` (still non-nil) so the outer dispatcher selects the
      # block-bearing overload. `&proc_local` / `&method(:foo)` and friends — anything not a bare
      # SymbolNode — still resolve to `Dynamic[Top]` for the same block-presence signal.
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

      # The block body's value type — what the dispatcher binds a generic block-return variable to.
      #
      # Issue #533 item 9: this pass used to type only the body's LAST statement, in the block's ENTRY scope.
      # A tail reading a name an earlier statement of the same body binds (`m.synchronize do v = 42; v end`)
      # therefore never saw the binding and fell through `local_read` to `Dynamic[top]`, while the main pass
      # — which threads scope statement by statement through `StatementEvaluator` — held `42` for the very
      # same node. {#threaded_block_body_type} closes that gap by reusing the main pass's evaluator; a decline
      # keeps the tail-only answer verbatim.
      def type_block_body(block_node, block_scope)
        body = block_node.body
        return Type::Combinator.constant_of(nil) if body.nil?

        threaded_block_body_type(body, block_scope) || block_scope.type_of(body)
      end

      # Re-typing the whole body would be wrong to do unconditionally: this path runs for EVERY block-bearing
      # call, and the statements ahead of the tail are pure cost whenever the tail does not depend on them.
      # Three declines keep that cost where the defect actually is, each falling back to the tail-only path:
      #
      # - a `nil` or non-`StatementsNode` body (`do … rescue … end` parses as a `BeginNode`) and a
      #   single-statement body — the overwhelming majority of blocks — pay nothing at all;
      # - a multi-statement body pays one DFS over its non-tail statements, and threads only when the tail
      #   READS a variable name one of them WRITES or MUTATES IN PLACE ({#tail_depends_on_body_binding?}).
      #   That is exactly the diagnosed shape, so a block whose tail does not consume the body's own
      #   bindings keeps today's type;
      # - the fold is not re-entrant. `StatementEvaluator#eval_call` already evaluates each nested block body
      #   once, plus up to three more times under the ADR-56 `BodyFixpoint` when the block rebinds a captured
      #   local, so a fold nested inside a fold would multiply that work per block-nesting level. Inside a
      #   threaded body a nested block-bearing call reverts to the tail-only path — a wider answer in a rare
      #   shape, never a new false positive.
      #
      # ADR-56 interaction: the fold cannot double-apply or fight the captured-local write-back. That
      # write-back is `StatementEvaluator#write_back_block_captures`, computed from the CALLER's scope into
      # the caller's continuation; this pass only derives a value type from a throwaway block scope and
      # discards the exit scope, exactly as the tail-only path did.
      #
      # Any failure inside the fold falls back to the tail-only answer rather than propagating: the enclosing
      # `block_return_type_for` rescue would otherwise report "no block" to the dispatcher, which is a much
      # larger regression than a wide block return.
      def threaded_block_body_type(body, block_scope)
        return nil unless body.is_a?(Prism::StatementsNode)

        statements = body.body
        return nil if statements.size < 2
        return nil if block_body_threading_suppressed?
        return nil unless tail_depends_on_body_binding?(statements)

        without_block_body_threading { block_scope.evaluate(body).first }
      rescue StandardError
        nil
      end

      # Suppression flag for {#threaded_block_body_type} — set while a fold is running (so a fold never nests)
      # and while the per-element Tuple fold is over its arity cap. Thread-local because block typing is
      # re-entrant within one thread and the fork-pool workers each own their own.
      THREADED_BLOCK_BODY_KEY = :__rigor_threaded_block_body__
      private_constant :THREADED_BLOCK_BODY_KEY

      def block_body_threading_suppressed?
        Thread.current[THREADED_BLOCK_BODY_KEY] ? true : false
      end

      # Runs the block with the scope-threading fold suppressed, restoring the previous state (not clearing
      # it) on the way out, so nesting a suppressed region inside another cannot re-enable threading.
      def without_block_body_threading
        previous = Thread.current[THREADED_BLOCK_BODY_KEY]
        Thread.current[THREADED_BLOCK_BODY_KEY] = true
        begin
          yield
        ensure
          Thread.current[THREADED_BLOCK_BODY_KEY] = previous
        end
      end

      # Every variable-write form whose name `StatementEvaluator` threads into the following statement's
      # scope, including the multi-assign / pattern targets that appear under a `MultiWriteNode`.
      VARIABLE_WRITE_NODES = Set[
        Prism::LocalVariableWriteNode, Prism::LocalVariableOperatorWriteNode,
        Prism::LocalVariableOrWriteNode, Prism::LocalVariableAndWriteNode,
        Prism::LocalVariableTargetNode,
        Prism::InstanceVariableWriteNode, Prism::InstanceVariableOperatorWriteNode,
        Prism::InstanceVariableOrWriteNode, Prism::InstanceVariableAndWriteNode,
        Prism::InstanceVariableTargetNode,
        Prism::ClassVariableWriteNode, Prism::ClassVariableOperatorWriteNode,
        Prism::ClassVariableOrWriteNode, Prism::ClassVariableAndWriteNode,
        Prism::ClassVariableTargetNode,
        Prism::GlobalVariableWriteNode, Prism::GlobalVariableOperatorWriteNode,
        Prism::GlobalVariableOrWriteNode, Prism::GlobalVariableAndWriteNode,
        Prism::GlobalVariableTargetNode
      ].freeze
      private_constant :VARIABLE_WRITE_NODES

      # Every node that OBSERVES a variable binding: the plain reads plus the compound writes, which read
      # their target before rebinding it (`v += 1` in the tail depends on an earlier `v = 0`).
      VARIABLE_READ_NODES = (
        VARIABLE_WRITE_NODES | [
          Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode,
          Prism::ClassVariableReadNode, Prism::GlobalVariableReadNode
        ]
      ).freeze
      private_constant :VARIABLE_READ_NODES

      # A `next` / `break` that leaves THIS block carries a value the fold cannot see: `evaluate(body).first`
      # is the fall-through value only, and no next-value join into the block return exists (`type_of_jump`
      # types both as `Bot`). So `m.synchronize do next 5 if flag; v = 42; v end` really can answer 5 at
      # runtime, and threading would type it `42`. Both forms escape with a value — `next v` is the block's
      # value for that yield, `break v` is the yielding CALL's value — so both must decline.
      JUMP_NODES = Set[Prism::NextNode, Prism::BreakNode].freeze
      private_constant :JUMP_NODES

      # Constructs that RETARGET a `next` / `break` nested inside them, so a jump below one of these says
      # nothing about our block's value and must not trigger the decline. A nested `BlockNode` / `LambdaNode`
      # is the jump's own block (`do xs.each { next 1 }; v = 42; v end` threads soundly — the inner `next`
      # ends the inner iteration); a loop consumes both forms (`while … next 5 … end` continues the loop);
      # a `DefNode` body is a different method entirely.
      JUMP_BOUNDARY_NODES = Set[
        Prism::BlockNode, Prism::LambdaNode, Prism::DefNode,
        Prism::WhileNode, Prism::UntilNode, Prism::ForNode
      ].freeze
      private_constant :JUMP_BOUNDARY_NODES

      # True when the tail statement observes a variable name one of the earlier statements binds OR mutates
      # in place — the two ways threading the scope through the body can change the tail's type — AND no
      # earlier statement can jump out of the block with a value. The name sets are compared sigil-and-all
      # across kinds, so the answer over-approximates (an `@x` write plus an `x` read threads needlessly);
      # over-approximating only spends the fold, it never changes an answer.
      #
      # The in-place half is issue #587. `outer = []; m.synchronize do outer.push(1); outer end` binds no
      # variable in its prefix — `push` is a call, not a write node — so a write-only scan declined and the
      # tail kept the entry scope's empty `Tuple[]`, a wrong-precise answer (the runtime value is `[1]`) that
      # hands downstream rules a provably-empty array. Threading is the fix, not a cost: `StatementEvaluator`
      # runs `MutationWidening.widen_after_call` on the `push`, so the threaded tail reads the widened
      # `Array[…]`. A call therefore contributes every variable its receiver can evaluate to
      # ({ReceiverAlias.candidates} — the ternary-selected receiver of issue #277 included) whenever its name
      # is one the widening responds to ({MutationWidening::SHAPE_MUTATORS}); keying on the widening's own
      # tables is what keeps "the scan says thread" and "threading changes something" the same predicate.
      #
      # Cost is two walks of the body, the second only when the first found a write and no jump — the same
      # order of cost `StatementEvaluator`'s own per-call captured-write scan already pays, and far below
      # re-typing. The prefix walk is hand-rolled rather than `Source::NodeWalker.each` because the two
      # questions it answers have different depths: a write is collected at ANY depth (a block is a closure,
      # so `[1].each { v = 5 }` really does bind the outer `v`, and `[1].each { outer << 1 }` really does
      # mutate the outer `outer`), while a jump counts only above the nearest {JUMP_BOUNDARY_NODES} boundary.
      def tail_depends_on_body_binding?(statements)
        written = Set.new
        statements[0...-1].each do |statement|
          return false unless prefix_statement_jump_free?(statement, written, false)
        end
        return false if written.empty?

        Source::NodeWalker.each(statements.last) do |node|
          return true if VARIABLE_READ_NODES.include?(node.class) && written.include?(node.name)
        end
        false
      end

      # True when `node` cannot jump out of the block with a value, collecting into `written` the names it
      # binds (a variable-write node) or mutates in place (a {MutationWidening::SHAPE_MUTATORS} call, through
      # every variable its receiver can evaluate to) on the way down. `retargeted` is true once the descent
      # has passed a boundary.
      #
      # A `Prism::DefinedNode`'s operand is never evaluated, so it is not descended into — the same rule
      # {Source::NodeWalker} applies, for the same reason: neither a write nor a jump under `defined?` runs.
      def prefix_statement_jump_free?(node, written, retargeted)
        return false if !retargeted && JUMP_NODES.include?(node.class)

        written << node.name if VARIABLE_WRITE_NODES.include?(node.class)
        collect_mutated_receivers(node, written) if node.is_a?(Prism::CallNode)
        return true if node.is_a?(Prism::DefinedNode)

        child_retargeted = retargeted || JUMP_BOUNDARY_NODES.include?(node.class)
        node.rigor_each_child do |child|
          return false unless prefix_statement_jump_free?(child, written, child_retargeted)
        end
        true
      end

      def collect_mutated_receivers(call_node, written)
        return unless MutationWidening::SHAPE_MUTATORS.include?(call_node.name)

        ReceiverAlias.candidates(call_node.receiver).each { |read| written << read.name }
      end

      # v0.0.6 phase 2 — per-element block fold for Tuple receivers under `:map` / `:collect`. Walks every
      # Tuple position, binds the block parameter to that element's type, and re-types the block body. The
      # per-position results are assembled into `Tuple[U_1..U_n]`, strictly tighter than the RBS-projected
      # `Array[union]`.
      #
      # Declines (returns nil) when the receiver is not a `Tuple` with at least one element, when the call
      # has no `Prism::BlockNode`, when the method is outside the supported set, when block typing raises
      # mid-loop, or when the block has no body. The decline path leaves the dispatch chain untouched.
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

      # Cardinality cap for per-element block fold over finite-bound `Constant<Range>` receivers. Walking
      # `(1..1_000_000).map { … }` element-wise would balloon block-typing cost and explode the resulting
      # Tuple, so only short ranges expand into per-position folds. Larger ranges decline so the RBS tier
      # widens.
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

      # Evaluates the call's block once per receiver element. Two block shapes are supported:
      #
      # - `Prism::BlockNode` — a full `do … end` / `{ … }` block; the body is re-typed per position with the
      #   element bound to the block parameter.
      # - `Prism::BlockArgumentNode` wrapping a `SymbolNode` — the `&:predicate` shorthand; the symbol is
      #   dispatched as a zero-arg method on each element type.
      #
      # Any other shape (`&proc_local`, `&method(:foo)`, no block) returns `nil` so the fold declines.
      # Arity cap on the scope-threading fold under this per-element walk. The `Constant<Range>` receivers are
      # already capped at {PER_ELEMENT_RANGE_LIMIT} positions, but a Tuple's elements come through
      # {#per_element_elements_of} uncapped — a 40-element array literal is 40 positions, and each one that
      # threads pays a FULL body evaluation rather than the tail-only typing this walk used to cost. Above the
      # cap the walk still runs (the fold's own per-position precision is unchanged); only the threading is
      # suppressed, so a body whose tail reads a body-local answers `Dynamic[top]` at every position instead
      # of its value. That is the cliff: `[1, …, 8].map do v = e; v end` folds to the values and a ninth
      # element drops the whole result to `Dynamic[top]` positions. It is set at the Range path's limit so one
      # number governs both receivers.
      PER_ELEMENT_THREADING_LIMIT = PER_ELEMENT_RANGE_LIMIT
      private_constant :PER_ELEMENT_THREADING_LIMIT

      def per_element_block_results(block, element_types)
        case block
        when Prism::BlockNode
          per_element_body_results(block, element_types)
        when Prism::BlockArgumentNode
          per_element_symbol_results(block, element_types)
        end
      end

      def per_element_body_results(block, element_types)
        captured = per_element_captured_bindings(block, element_types)
        results = lambda do
          element_types.map { |element_type| type_block_body_with_param(block, [element_type], captured: captured) }
        end
        return results.call if element_types.size <= PER_ELEMENT_THREADING_LIMIT

        without_block_body_threading(&results)
      end

      # Issue #587 (b) — first-iteration pinning. Every position of this fold is typed from the SAME entry
      # scope, so a body that rebinds a captured outer local answers the FIRST iteration's value at every
      # position: `total = 0; [1, 2].map do total += 1; total end` folded to `[1, 1]` (runtime `[1, 2]`), and
      # `r.first == 1` then folded to `true` — a live always-truthy on correct code. The ADR-56 fixpoint
      # (`StatementEvaluator#write_back_block_captures`) already computes the honest binding of such a local
      # — the join over the pre-call binding and every permitted iteration, value-pin widened, floored to
      # `Dynamic[top]` on structural compounding (`x = [x]`) — but it runs AFTER the call is typed and feeds
      # only the continuation. This fold runs the same `BodyFixpoint` over the same name set
      # ({CapturedLocals.writes}) up front and binds each such local to its converged type in every
      # position's entry scope, so a position answers what the local can be in ANY iteration
      # (`[Integer, Integer]`), never what it was in the first.
      #
      # Only the rebound names move. A position whose tail reads an untouched captured local or a block-local
      # keeps its exact fold (`[5, 5]`, `[42, 42]`), and a predicate that ignores the rebound counter still
      # decides (`select do seen += 1; e > 1 end` still folds to `[2]`); a blanket decline would have lost all
      # three for nothing. The fixpoint binds the block parameter to the union of the elements, so its cost
      # is independent of the arity — which is why the per-element threading cap is NOT a reason to floor: a
      # ninth element keeps `Integer` where it would otherwise keep the stale `0`.
      #
      # Under threading suppression — this fold nested inside another threaded body — the fixpoint's body
      # evaluations are exactly the re-entrant cost the suppression exists to refuse, so the names take the
      # escaping-block floor (`Dynamic[top]`) instead: cheaper, wider, still sound. A failure inside the
      # fixpoint takes the same floor rather than the seed — a seed that reaches a position is the pin this
      # exists to remove.
      #
      # Returns `nil` (no binding to apply) for the overwhelmingly common body that rebinds nothing captured.
      def per_element_captured_bindings(block, element_types)
        names = CapturedLocals.writes(block, scope)
        return nil if names.empty?
        return captured_floor(names) if block_body_threading_suppressed?

        begin
          converged_captured_bindings(block, names, element_types)
        rescue StandardError
          captured_floor(names)
        end
      end

      def captured_floor(names)
        names.to_h { |name| [name, Type::Combinator.untyped] }
      end

      def converged_captured_bindings(block, names, element_types)
        param_types = [Type::Combinator.union(*element_types)]
        BodyFixpoint.converge(
          names: names,
          seed_bindings: names.to_h { |name| [name, scope.local(name)] },
          widen: Type::Combinator.method(:widen_value_pinned),
          evaluate_body: ->(bindings) { captured_exit_bindings(block, param_types, bindings, names) }
        )
      end

      # One fixpoint pass: the body evaluated from `bindings` with the block parameters bound over them (the
      # same layering as {#type_block_body_with_param}), returning the per-name exit binding. Threading is
      # suppressed for the pass, as it is for every full body evaluation the block-return pass runs.
      def captured_exit_bindings(block, param_types, bindings, names)
        params = BlockParameterBinder.new(expected_param_types: param_types).bind(block)
        entry = bindings.reduce(scope) { |acc, (name, type)| acc.with_local(name, type) }
        entry = params.reduce(entry) { |acc, (name, type)| acc.with_local(name, type) }
        _type, exit_scope = without_block_body_threading { entry.evaluate(block.body) }
        names.to_h { |name| [name, exit_scope.local(name)] }
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

      # Returns the per-position element types for a finite, statically-known receiver shape — or nil when
      # the receiver does not pin a finite element list.
      #
      # `Tuple[A, B, …]`        → [A, B, …]
      # `Constant<a..b>`        → [Constant[a], …, Constant[b]]
      # everything else         → nil
      #
      # Note: `Type::IntegerRange` is the bounded-Integer carrier (`int<a, b>` represents "an Integer between
      # a and b"), not a Range value. Calls like `.map` / `.find` on an `IntegerRange` receiver would resolve
      # to `Integer#map` / `Integer#find` — neither exists — so IntegerRange does NOT participate in this
      # fold.
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

      INJECT_METHODS = Set[:inject, :reduce].freeze
      private_constant :INJECT_METHODS

      # Cap on the element count for the Part 2 constant-threading fold — mirrors
      # `ReduceFolding::CONSTANT_FOLD_ELEMENT_CAP`. The size is checked BEFORE enumeration so `(1..1_000_000)`
      # declines without materialising.
      INJECT_CONSTANT_ELEMENT_CAP = 64
      private_constant :INJECT_CONSTANT_ELEMENT_CAP

      # Magnitude cap on a folded Integer accumulator — mirrors `ReduceFolding`'s bit cap so factorial-style
      # blow-up declines to the Part 1 nominal result rather than parking a heavy bignum literal in the type
      # graph.
      INJECT_CONSTANT_BIT_CAP = 256
      private_constant :INJECT_CONSTANT_BIT_CAP

      # Block-form `inject` / `reduce` return-type fold.
      #
      # Part 1 (soundness): the accumulator of a block-form fold must reach a fixpoint over an unknown
      # number of iterations — the RBS tier's generic `(S) { (S, E) -> S } -> S` binds `S` from a SINGLE
      # block pass (acc=seed, elem=element-join), so `(1..5).inject(1) { |a, i| a * i }` types `int<1, 5>`
      # while the runtime is 120 (out of range — unsound). We iterate the accumulator type to a capped
      # fixpoint (ADR-55/56 `BodyFixpoint`) so the multiply converges to `Integer`, never a value-bounded
      # interval the runtime escapes.
      #
      # Part 2 (precision): when the receiver is a fully-constant finite collection (`Constant[Range]` /
      # `Tuple` of `Constant`), the seed is `Constant` (or the no-seed first element), and the block body
      # folds to a `Constant` on EVERY iteration with the running accumulator + element bound, thread the
      # accumulator through per-element block evaluation and return the final `Constant` (`(1..5).inject(1)
      # { |a, i| a * i } -> 120`).
      #
      # The two are layered: Part 2 is attempted first (a constant answer is strictly tighter); on any
      # decline it falls through to the Part 1 sound nominal fixpoint, and on a Part 1 decline to the RBS
      # tier. Captured-local write-back (ADR-56) runs at the statement level independent of this return-type
      # computation, so a block that both accumulates and mutates captured state keeps its write-back
      # regardless of which arm answers here.
      #
      # @return [Rigor::Type, nil]
      def try_block_inject_fold(call_node, receiver, arg_types)
        return nil unless INJECT_METHODS.include?(call_node.name)

        block = call_node.block
        return nil unless block.is_a?(Prism::BlockNode)

        seed, has_seed = inject_seed(arg_types)
        return nil if arg_types.size > (has_seed ? 1 : 0)

        constant = try_constant_inject_fold(receiver, block, seed, has_seed)
        return constant if constant

        try_nominal_inject_fixpoint(receiver, block, seed, has_seed)
      end

      # Splits the positional args into the optional seed. A Symbol final arg (`inject(seed, :*)`) is the
      # no-block Symbol form and never reaches here (the block guard already failed for it).
      #
      # @return [Array(Rigor::Type, nil), Boolean] `[seed, has_seed]`
      def inject_seed(arg_types)
        case arg_types.size
        when 0 then [nil, false]
        else [arg_types.first, true]
        end
      end

      # Part 2 — thread the accumulator through per-element block evaluation over a fully-constant finite
      # receiver. Declines (nil) on a non-constant receiver / seed, a size or magnitude cap, or any per-step
      # result that is not a foldable `Constant`.
      def try_constant_inject_fold(receiver, block, seed, has_seed)
        members = inject_constant_members(receiver)
        return nil if members.nil?

        acc, rest = inject_constant_start(members, seed, has_seed)
        return nil if acc.nil?

        rest.each do |element_value|
          acc = inject_constant_step(block, acc, element_value)
          return nil if acc.nil?
        end
        acc
      end

      # Extracts the receiver's foldable constant values, size-capped before enumeration, or nil to decline.
      def inject_constant_members(receiver)
        case receiver
        when Type::Constant then inject_constant_range_members(receiver.value)
        when Type::Tuple then inject_constant_tuple_members(receiver.elements)
        end
      end

      def inject_constant_range_members(value)
        return nil unless value.is_a?(Range)

        first = value.begin
        last = value.end
        return nil unless inject_foldable?(first) && inject_foldable?(last)

        size = value.size
        return nil unless size.is_a?(Integer)
        return nil if size > INJECT_CONSTANT_ELEMENT_CAP

        value.to_a
      rescue StandardError
        nil
      end

      def inject_constant_tuple_members(elements)
        return nil if elements.size > INJECT_CONSTANT_ELEMENT_CAP
        return nil unless elements.all? { |e| e.is_a?(Type::Constant) && inject_foldable?(e.value) }

        elements.map(&:value)
      end

      # Seeds the constant accumulator: with a seed the memo starts at the (foldable) seed value and every
      # member is folded; without a seed the first member seeds the memo and the rest are folded. The
      # accumulator is carried as a `Constant` type (so the block body sees a value-pinned param).
      #
      # @return [Array(Rigor::Type::Constant, nil), Array] `[acc, rest]`
      def inject_constant_start(members, seed, has_seed)
        if has_seed
          return [nil, []] unless seed.is_a?(Type::Constant) && inject_foldable?(seed.value)

          [seed, members]
        else
          return [nil, []] if members.empty?

          [Type::Combinator.constant_of(members.first), members[1..]]
        end
      end

      # Evaluates the block body once with the running constant accumulator + the next constant element
      # bound to the block params, returning the result when it is a foldable `Constant` within the
      # magnitude cap, else nil to decline the whole fold.
      def inject_constant_step(block, acc, element_value)
        element = Type::Combinator.constant_of(element_value)
        result = type_block_body_with_param(block, [acc, element])
        return nil unless result.is_a?(Type::Constant)
        return nil unless inject_foldable?(result.value)
        return nil if inject_magnitude_too_large?(result.value)

        result
      end

      INJECT_FOLDABLE_CLASSES = [Integer, Float, Rational].freeze
      private_constant :INJECT_FOLDABLE_CLASSES

      def inject_foldable?(value)
        INJECT_FOLDABLE_CLASSES.any? { |klass| value.is_a?(klass) }
      end

      def inject_magnitude_too_large?(value)
        value.is_a?(Integer) && value.bit_length > INJECT_CONSTANT_BIT_CAP
      end

      # Part 1 — the sound nominal accumulator fixpoint. Iterates `acc = join(acc, block(acc, element))` to
      # a capped fixpoint with final `Constant -> Nominal` widening (ADR-55/56 `BodyFixpoint`), seeding `acc`
      # from the seed type (or the element type for the no-seed form) and binding the element-join to the
      # element param. Declines (nil) when the element type is unknown so the RBS tier owns the call.
      def try_nominal_inject_fixpoint(receiver, block, seed, has_seed)
        element = MethodDispatcher::IteratorDispatch.element_type_of(receiver)
        return nil if element.nil?

        seed_acc = has_seed ? seed : element
        return nil if seed_acc.nil?

        converged = BodyFixpoint.converge(
          names: [:__inject_acc__],
          seed_bindings: { __inject_acc__: seed_acc },
          widen: method(:widen_value_pinned),
          evaluate_body: lambda do |bindings|
            acc = bindings[:__inject_acc__]
            result = type_block_body_with_param(block, [acc, element])
            result.nil? ? {} : { __inject_acc__: result }
          end
        )
        converged[:__inject_acc__] || seed_acc
      end

      # `index(value)` and `find_index(value)` carry a positional argument and search by `==` rather than
      # running the block. Decline so the RBS tier owns those forms.
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

      # `select` / `filter` / `reject`: keeps each receiver element whose per-position predicate result
      # folds to a decisive `Constant` — Ruby-truthy for `select` / `filter`, Ruby-falsey for `reject`. The
      # surviving elements assemble into a `Tuple`, strictly tighter than the RBS-projected `Array[Elem]`.
      #
      # Folds tightly only when EVERY position is a `Constant`: a single non-`Constant` position leaves the
      # result cardinality unknown (the element might or might not survive), so the dispatcher declines and
      # the RBS tier widens to `Array[Elem]`. `[].select` style empty results are sound — an empty `Tuple`
      # is the empty-array carrier.
      def assemble_filter_result(per_position, element_types, keep_on_truthy:)
        return nil unless per_position.all?(Type::Constant)

        kept = element_types.each_index.filter_map do |index|
          element_types[index] if truthy_constant?(per_position[index]) == keep_on_truthy
        end
        Type::Combinator.tuple_of(*kept)
      end

      # `filter_map` folds tightly only when every per-position result is a `Constant`: positions whose
      # value is `nil` or `false` drop, the rest survive in declaration order. When any position is
      # non-Constant the dispatcher declines (returns nil) so the RBS tier widens to `Array[U]`.
      def assemble_filter_map_result(per_position)
        return nil unless per_position.all?(Type::Constant)

        kept = per_position.reject { |type| type.value.nil? || type.value == false }
        Type::Combinator.tuple_of(*kept)
      end

      # `flat_map` flattens a single level: if the per-position result is a `Tuple`, its elements are
      # concatenated; if it's a non-Array scalar carrier (`Constant<…>` over a non-Array literal) it
      # contributes one element. We fold tightly only when every per-position result is one of those two
      # recognisable shapes — `Nominal[Array[T]]`, `Union[…]`, and other opaque carriers decline so the RBS
      # tier widens to `Array[U]`.
      #
      # `Type::Constant` only ever holds non-Array scalars (the carrier rejects Array literals), so a single
      # `Constant` safely contributes itself as a single Tuple element.
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

      # `find` / `detect`: returns the first receiver element whose block result is Ruby-truthy, or `nil`
      # when no position folds to truthy.
      #
      # Folds tightly only when every per-position block result is a `Type::Constant` — otherwise we cannot
      # decide which position (if any) is "the first matching one". When the first decisive truthy position
      # is found, the answer is the corresponding receiver element. When every position folds to falsey,
      # the answer is `Constant[nil]`.
      def assemble_find_result(per_position, element_types)
        return nil unless per_position.all?(Type::Constant)

        first_truthy_index = per_position.index { |type| truthy_constant?(type) }
        return Type::Combinator.constant_of(nil) if first_truthy_index.nil?

        element_types[first_truthy_index]
      end

      # `find_index` / `index`: returns the index of the first truthy position, or `Constant[nil]` when
      # nothing matches.
      def assemble_find_index_result(per_position)
        return nil unless per_position.all?(Type::Constant)

        first_truthy_index = per_position.index { |type| truthy_constant?(type) }
        return Type::Combinator.constant_of(nil) if first_truthy_index.nil?

        Type::Combinator.constant_of(first_truthy_index)
      end

      def truthy_constant?(type)
        type.is_a?(Type::Constant) && type.value && type.value != false
      end

      # Per-pair block fold for `HashShape#transform_keys` and `HashShape#transform_values` (and their bang
      # variants).
      #
      # When the receiver is a closed `HashShape` with no optional keys, applies the call's block (a
      # `Prism::BlockNode` or `Prism::BlockArgumentNode`) to each key/value pair independently and
      # assembles a new `HashShape`:
      #
      # - `transform_values` / `transform_values!`: re-types each VALUE by binding it to the block
      #   parameter; keys are preserved unchanged.
      # - `transform_keys` / `transform_keys!`: re-types each KEY by wrapping it in `Constant[k]` and
      #   passing it to the block; values are preserved unchanged. The result key must be a
      #   `Constant[Symbol | String]` — otherwise the tier declines (the new key cannot be used as a static
      #   HashShape index). Collisions (two old keys mapping to the same new key) also decline.
      #
      # Returns `nil` on any decline so the dispatcher falls through to `RbsDispatch` and gets the widened
      # `Hash[K, V]` answer.
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

      # Applies a single-argument block (either a full BlockNode or a `&:symbol` BlockArgumentNode) to
      # `param_type` and returns the resulting type, or `nil` on failure.
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

      # `captured:` — issue #587 (b): the per-name entry binding of every captured outer local the body rebinds
      # ({#per_element_captured_bindings}), laid under the parameter bindings so a parameter still shadows.
      def type_block_body_with_param(block_node, expected_param_types, captured: nil)
        bindings = BlockParameterBinder.new(expected_param_types: expected_param_types).bind(block_node)
        block_scope = (captured || {}).reduce(scope) { |acc, (name, type)| acc.with_local(name, type) }
        block_scope = bindings.reduce(block_scope) { |acc, (name, type)| acc.with_local(name, type) }
        type_block_body(block_node, block_scope)
      rescue StandardError
        nil
      end
    end
  end
end
