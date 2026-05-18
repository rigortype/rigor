# frozen_string_literal: true

require "prism"

require_relative "../configuration"
require_relative "../environment"
require_relative "../scope"
require_relative "../reflection"
require_relative "../type"
require_relative "../inference/scope_indexer"
require_relative "../inference/rbs_type_translator"

module Rigor
  module SigGen
    # Core generator for `rigor sig-gen` (ADR-14 slice 1 — MVP).
    #
    # Walks every `.rb` file under the input paths, builds a
    # per-node scope index via {Rigor::Inference::ScopeIndexer},
    # finds every `Prism::DefNode` whose enclosing class is
    # nameable, types the body's last expression to derive an
    # inferred return, looks up the project's existing RBS
    # declaration (if any), and emits one {MethodCandidate} per
    # def.
    #
    # The MVP keeps the scope deliberately narrow:
    # - Only instance methods inside a `class` / `module` body
    #   are considered. Top-level / DSL-block / singleton defs
    #   are skipped (`sig.skipped.complex-shape`).
    # - Parameter signatures are hard-coded to `untyped` per
    #   ADR-14 § "Robustness principle compliance" clause 2;
    #   `--params=observed` arrives in slice 3.
    # - Optional / rest / keyword / block params disqualify the
    #   def (`sig.skipped.complex-shape`).
    # - A `Dynamic[top]` inferred return becomes
    #   `sig.skipped.untyped-return` — emitting `untyped` would
    #   obscure rather than help.
    # - Tighter-return detection compares the RBS-erased
    #   spellings only when the existing declared return
    #   strictly accepts the inferred one (acceptance check
    #   under the engine's current `:gradual` mode; ADR-14
    #   reserves the eventual `:strict` mode).
    class Generator # rubocop:disable Metrics/ClassLength
      # @param configuration [Rigor::Configuration]
      # @param paths [Array<String>] files / directories to scan.
      # @param observations [Hash{[String, Symbol] => Array<Array<Rigor::Type>>}]
      #   ADR-14 slice 3 — per-target-method arg-tuple observations
      #   produced by {ObservationCollector}. An empty Hash (the default)
      #   means "no observations available; emit `untyped` for every
      #   parameter position" per ADR-5 clause 2.
      def initialize(configuration:, paths:, observations: {}, include_private: false)
        @configuration = configuration
        @paths = paths
        @observations = normalize_observations(observations)
        @include_private = include_private
        # Per-file scratch state. `analyse_file` resets each
        # one to a fresh container for every file walked so
        # candidates from one file don't leak into another;
        # initialising empty here gives downstream consumers
        # (`build_candidate`, `method_def_prefix`) a never-nil
        # invariant without per-call-site defensive guards.
        @namespace_kinds = {}
        @module_function_methods = Set.new
        @class_shells = Set.new
      end

      # Lifts legacy plain-`Array[Type]` observation entries
      # into {ObservedCall} carriers. Specs from the slice-3
      # generation predate the carrier and pass observations
      # as `{ [class, method] => [[type1, type2], ...] }`;
      # the wrapper keeps those passing while internal code
      # always sees the new shape.
      def normalize_observations(map)
        return map if map.empty?

        map.transform_values { |entries| entries.map { |entry| ObservedCall.from(entry) } }
      end

      # @return [Array<MethodCandidate>]
      def run
        @environment = build_environment
        resolved = resolve_paths(@paths)
        resolved.flat_map { |path| analyse_file(path, @environment) }
      end

      private

      def build_environment
        Environment.for_project(
          libraries: @configuration.libraries,
          signature_paths: @configuration.signature_paths
        )
      end

      def resolve_paths(args)
        args.flat_map do |arg|
          if File.directory?(arg)
            Dir.glob(File.join(arg, "**/*.rb"), sort: true)
          elsif File.file?(arg) && arg.end_with?(".rb")
            [arg]
          else
            []
          end
        end.uniq
      end

      def analyse_file(path, environment)
        source = File.read(path)
        parse_result = Prism.parse(source, filepath: path, version: @configuration.target_ruby)
        return [] if parse_result.errors.any?

        base_scope = Scope.empty(environment: environment)
        scope_index = Inference::ScopeIndexer.index(parse_result.value, default_scope: base_scope)

        @namespace_kinds = {}
        @module_function_methods = Set.new
        @class_shells = Set.new
        defs = collect_method_definitions(parse_result.value)
        candidates_from_defs = defs.filter_map do |def_node, class_name, kind|
          classify_def(path, def_node, class_name, kind, scope_index)
        end
        candidates_from_defs + collect_attr_candidates(parse_result.value, path, scope_index)
      end

      # Walks the AST collecting `(def_node, class_name, kind)`
      # tuples for every `def` Rigor can re-type. Slice 1
      # covered instance `def foo` methods inside a nameable
      # `class` / `module` body. Slice 4 extends this to
      # singleton-side methods via `def self.foo` and
      # `class << self; def foo; end`; top-level / DSL-block
      # defs still degrade silently (no nameable receiver).
      #
      # ADR-14 gap-#3 follow-up tracks two extra pieces during
      # the same walk so the Writer can emit kind-correct RBS
      # without guessing:
      #
      # - `@namespace_kinds[qualified_name]` records whether
      #   each segment came from `class Foo` (`:class`) or
      #   `module Foo` (`:module`). Used by the writer's
      #   `wrap_in_modules` step to emit the right keyword for
      #   each intermediate segment AND the leaf.
      # - `@module_function_methods` records `(class_name,
      #   method_name)` pairs where a `module_function` (no
      #   args) call preceded the `def` inside a module body.
      #   The renderer emits `def self?.name` for these, the
      #   RBS spelling that matches the dual instance +
      #   singleton dispatch the runtime produces.
      def collect_method_definitions(root)
        out = []
        walk_defs(root, [], false, false, out)
        out
      end

      def walk_defs(node, prefix, in_singleton_class, module_function_active, out)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          return if descend_into_namespace?(node, prefix, out)
        when Prism::SingletonClassNode
          if node.expression.is_a?(Prism::SelfNode) && node.body
            walk_defs(node.body, prefix, true, false, out)
            return
          end
        when Prism::DefNode
          collect_def_node(node, prefix, in_singleton_class, module_function_active, out)
          return
        when Prism::ConstantWriteNode
          register_data_struct_shell(node, prefix)
          # fall through to recurse into the RHS so a trailing
          # `do ... end` block carrying defs is still walked.
        when Prism::StatementsNode
          walk_statements(node, prefix, in_singleton_class, module_function_active, out)
          return
        end

        node.compact_child_nodes.each do |child|
          walk_defs(child, prefix, in_singleton_class, module_function_active, out)
        end
      end

      def descend_into_namespace?(node, prefix, out)
        name = qualified_constant_path(node.constant_path)
        return false unless name

        full = (prefix + [name]).join("::")
        @namespace_kinds[full] = node.is_a?(Prism::ClassNode) ? :class : :module
        walk_namespace_body(node, prefix + [name], out)
        true
      end

      # ADR-14 gap-#3 (e): recognises
      # `Const = Data.define(...)` and
      # `Const = Struct.new(...)` as class declarations.
      # The runtime side stamps a brand-new anonymous class
      # at the RHS and binds it to `Const`, so the generated
      # RBS needs an explicit `class Const` declaration even
      # though no `class Const ... end` block appears in
      # source. Without it, references to `Const` in return
      # types fail to resolve under Steep (the canonical case
      # is `GemResolver::Resolved | GemResolver::Unresolvable`
      # where `Unresolvable = Data.define(:gem_name, :reason)`).
      #
      # The walker records the fully-qualified constant name
      # in `@class_shells` (carried through to every
      # candidate so the writer's tree-builder picks it up)
      # AND in `@namespace_kinds` so the leaf's `class`
      # keyword wins over the intermediate-segment `module`
      # default.
      def register_data_struct_shell(node, prefix)
        return unless data_or_struct_call?(node.value)

        full = (prefix + [node.name.to_s]).join("::")
        @class_shells << full
        @namespace_kinds[full] = :class
      end

      DATA_STRUCT_SHELL_HEADS = {
        "Data" => :define,
        "Struct" => :new
      }.freeze
      private_constant :DATA_STRUCT_SHELL_HEADS

      def data_or_struct_call?(value)
        return false unless value.is_a?(Prism::CallNode)

        receiver = value.receiver
        return false unless receiver.is_a?(Prism::ConstantReadNode)

        DATA_STRUCT_SHELL_HEADS[receiver.name.to_s] == value.name
      end

      # Module / class bodies are walked through the
      # `walk_statements` path so `module_function` (no-args)
      # encountered as one statement applies to every
      # subsequent sibling def in the same body. The
      # directive is module-scoped semantically — classes
      # inherit `module_function` via `Module`'s ancestor
      # chain but don't honour it the same way at runtime, so
      # tracking is only meaningful inside `ModuleNode`
      # bodies. Generator emits `def self?.name` for the
      # marked defs.
      def walk_namespace_body(namespace_node, prefix, out)
        return if namespace_node.body.nil?

        walk_defs(namespace_node.body, prefix, false, false, out)
      end

      def walk_statements(stmts_node, prefix, in_singleton_class, module_function_active, out)
        stmts_node.body.each do |stmt|
          if module_function_directive?(stmt)
            module_function_active = true
            next
          end
          walk_defs(stmt, prefix, in_singleton_class, module_function_active, out)
        end
      end

      def module_function_directive?(node)
        return false unless node.is_a?(Prism::CallNode)
        return false unless node.name == :module_function && node.receiver.nil?

        (node.arguments&.arguments || []).empty?
      end

      def collect_def_node(node, prefix, in_singleton_class, module_function_active, out)
        return if prefix.empty?

        kind = node.receiver.is_a?(Prism::SelfNode) || in_singleton_class ? :singleton : :instance
        class_name = prefix.join("::")
        @module_function_methods << [class_name, node.name] if module_function_active && kind == :instance
        out << [node, class_name, kind]
      end

      # Wraps `MethodCandidate.new` so every candidate carries
      # the per-file `@namespace_kinds` map AND the
      # `@class_shells` set — the Writer's nested-syntax
      # emission consults both to pick `module` vs `class`
      # for each segment and to emit empty
      # `Const = Data.define(...)` declarations.
      def build_candidate(**)
        MethodCandidate.new(
          namespace_kinds: @namespace_kinds,
          class_shells: @class_shells.to_a,
          **
        )
      end

      # Returns "def self." (kind: :singleton),
      # "def self?." (instance method declared inside a
      # `module_function` region — both instance + singleton
      # dispatch at runtime), or "def " (plain instance).
      def method_def_prefix(class_name, method_name, kind)
        return "def self." if kind == :singleton
        return "def self?." if @module_function_methods.include?([class_name, method_name])

        "def "
      end

      # Slice-4 follow-up surfaced by the Rigor self-dogfood:
      # most `lib/rigor/cli/*` files have a small public
      # surface (`run`) and many private helpers. Emitting the
      # private helpers into a `sig/` file is noise — private
      # methods are implementation details, not part of the
      # type contract downstream consumers (Steep, IDE, gem
      # users) read. The default now skips private and
      # protected methods; the `:include_private` flag
      # restores the slice-4 behaviour for callers that want
      # every method.
      def visibility_excludes?(def_node, class_name, kind, scope_index)
        return false if kind == :singleton
        return false if @include_private

        scope = scope_index[def_node] || scope_index.each_value.first
        return false if scope.nil?

        visibility = scope.discovered_method_visibility(class_name, def_node.name)
        %i[private protected].include?(visibility)
      end

      # Ruby's `initialize` return value is never meaningful;
      # the conventional RBS spelling is `() -> void`. The
      # body-typing path types the last expression (often an
      # ivar assignment whose rvalue happens to be `[]` /
      # `{}`), which produces nonsense return types.
      #
      # Skipping `initialize` entirely is correct ONLY for
      # default constructors — the `Object#initialize: () -> void`
      # RBS fallback then covers the lookup. When the class
      # has a non-trivial `initialize(argv:, ...)` (i.e. any
      # parameter), partial-class sigs trip Steep's
      # method-parameter-mismatch check: Steep sees the
      # runtime `def initialize(...)` and compares against
      # the inherited `Object#initialize: () -> void`. The
      # mismatch surfaces a `Ruby::MethodParameterMismatch`
      # warning even when `rigor check` itself is clean.
      #
      # Returning `nil` here causes `classify_def` to skip
      # emission; returning `:emit_stub` causes
      # `initialize_stub_candidate` to emit a permissive
      # `(<param shape>) -> void` stub matching the
      # runtime parameter list.
      def initialize_excludes?(def_node, kind)
        return false unless kind == :instance
        return false unless def_node.name == :initialize

        # Default constructor with no params — skip; the
        # Object#initialize RBS fallback covers it.
        params = def_node.parameters
        params.nil? || trivial_initialize_params?(params)
      end

      def trivial_initialize_params?(params)
        return true unless params.is_a?(Prism::ParametersNode)

        params.requireds.empty? && params.optionals.empty? &&
          params.rest.nil? && params.keywords.empty? &&
          params.keyword_rest.nil? && params.block.nil?
      end

      def non_trivial_initialize?(def_node, kind)
        kind == :instance && def_node.name == :initialize && !trivial_initialize_params?(def_node.parameters)
      end

      # Emits `def initialize: (<shape>) -> void`. The return
      # is always `void` because Ruby's `initialize` return
      # value is never meaningful. The parameter list mirrors
      # the runtime shape (required / optional / rest /
      # keyword / keyword-rest / block).
      #
      # When `--params=observed` populates `@observations` for
      # `[class_name, :initialize]` (via the
      # `ObservationCollector`'s `.new` → `:initialize`
      # routing), positional and keyword arg types come from
      # the per-position / per-keyword union of observed
      # types; otherwise every position keeps `untyped` per
      # ADR-5 clause 2.
      def initialize_stub_candidate(path, def_node, class_name)
        rbs = "def initialize: (#{render_initialize_param_list(def_node.parameters, class_name)}) -> void"
        build_candidate(
          path: path, class_name: class_name, method_name: :initialize,
          kind: :instance, classification: Classification::NEW_METHOD,
          inferred_return: Type::Combinator.untyped, rbs: rbs
        )
      end

      def render_initialize_param_list(params, class_name)
        return "" unless params.is_a?(Prism::ParametersNode)

        observations = initialize_observations(class_name, params)
        offset = 0
        parts = []

        params.requireds.each_with_index do |_, i|
          parts << initialize_positional_type(observations, offset + i, "")
        end
        offset += params.requireds.size

        params.optionals.each_with_index do |_, i|
          parts << initialize_positional_type(observations, offset + i, "?")
        end

        parts << "*untyped" if params.rest
        params.keywords.each { |kw| parts << render_keyword_param(kw, observations) }
        parts << "**untyped" if params.keyword_rest
        parts << "?{ (?) -> void }" if params.block
        parts.join(", ")
      end

      # Picks observations under `[class_name, :initialize]`
      # whose positional arity matches the def's accepted
      # range (required..required+optional). Looser arities
      # don't get used because they describe a different
      # overload the stub cannot express.
      def initialize_observations(class_name, params)
        return [] if @observations.empty?

        list = @observations[[class_name, :initialize]] || []
        min = params.requireds.size
        max = min + params.optionals.size
        list.select { |obs| (min..max).cover?(obs.positional.size) }
      end

      def initialize_positional_type(observations, index, prefix)
        types = observations.filter_map { |obs| obs.positional[index] }
        "#{prefix}#{types.empty? ? 'untyped' : paren_wrap_union(union_erase(types))}"
      end

      def render_keyword_param(keyword, observations)
        optional_marker = keyword.is_a?(Prism::OptionalKeywordParameterNode) ? "?" : ""
        types = observations.filter_map { |obs| obs.keyword[keyword.name] }
        rendered = types.empty? ? "untyped" : paren_wrap_union(union_erase(types))
        "#{optional_marker}#{keyword.name}: #{rendered}"
      end

      def qualified_constant_path(constant_path)
        case constant_path
        when Prism::ConstantReadNode
          constant_path.name.to_s
        when Prism::ConstantPathNode
          parent = qualified_constant_path(constant_path.parent) if constant_path.parent
          name = constant_path.name&.to_s
          return nil if name.nil?

          parent ? "#{parent}::#{name}" : name
        end
      end

      def classify_def(path, def_node, class_name, kind, scope_index)
        return nil if visibility_excludes?(def_node, class_name, kind, scope_index)
        return nil if initialize_excludes?(def_node, kind)
        return initialize_stub_candidate(path, def_node, class_name) if non_trivial_initialize?(def_node, kind)

        unless simple_parameter_shape?(def_node.parameters)
          return skipped(path, def_node, class_name, kind, :complex_shape)
        end

        inferred = infer_return_type(def_node, scope_index)
        return skipped(path, def_node, class_name, kind, :untyped_return) if inferred.nil? || dynamic_top?(inferred)

        environment = scope_index[def_node]&.environment
        method_def = lookup_existing_method(class_name, def_node.name, kind, environment, scope_index[def_node])

        if method_def.nil?
          new_method_candidate(path, def_node, class_name, kind, inferred)
        else
          compare_against_declared(path, def_node, class_name, kind, inferred, method_def)
        end
      end

      # Required positionals only; the MVP's body-typing path
      # gives well-defined returns for that shape. Optional /
      # rest / keyword / block parameters route through the
      # `sig.skipped.complex-shape` reason until slices 3+
      # widen the param policy.
      def simple_parameter_shape?(params)
        return true if params.nil?
        return false unless params.is_a?(Prism::ParametersNode)

        params.optionals.empty? &&
          params.rest.nil? &&
          params.keywords.empty? &&
          params.keyword_rest.nil? &&
          params.block.nil?
      end

      # Mirrors the `def.return-type-mismatch` rule's body-type
      # extraction: type the implicit-return expression under
      # the scope the indexer associated with the body. The
      # parameter bindings (typed `untyped` per the indexer's
      # default) come from `with_local` inside
      # `StatementEvaluator`; the result is the carrier the
      # body proves *given an untyped argument tuple*.
      #
      # Post-dogfood enhancement: walk the body's AST for
      # explicit `return X` statements and union their value
      # types with the implicit-return expression's type. The
      # earlier MVP only typed the implicit-return path, which
      # routinely produced single-branch artefacts like
      # `parse_options: () -> nil` (the actual runtime return
      # is `options | nil`) or `find: () -> V` (actually
      # `V | nil` via `return nil unless ...`). The walk
      # excludes nested `DefNode` / lambda / block scopes
      # whose returns belong to different methods.
      def infer_return_type(def_node, scope_index)
        body = def_node.body
        return nil if body.nil?

        last = body_last_expression(body)
        return nil if last.nil?

        inner_scope = scope_index[last] || scope_index[body] || scope_index[def_node]
        return nil if inner_scope.nil?

        last_type = inner_scope.type_of(last)
        union_with_explicit_returns(body, last_type, scope_index)
      rescue StandardError
        nil
      end

      def body_last_expression(body)
        case body
        when Prism::StatementsNode then body.body.last
        when Prism::BeginNode then body_last_expression(body.statements)
        else body
        end
      end

      def union_with_explicit_returns(body, last_type, scope_index)
        return_types = []
        collect_return_types(body, scope_index, return_types)
        return last_type if return_types.empty?

        Type::Combinator.union(last_type, *return_types)
      end

      RETURN_BARRIER_NODES = [Prism::DefNode, Prism::LambdaNode, Prism::BlockNode].freeze
      private_constant :RETURN_BARRIER_NODES

      def collect_return_types(node, scope_index, out)
        return unless node.is_a?(Prism::Node)
        return if RETURN_BARRIER_NODES.any? { |klass| node.is_a?(klass) }

        type_return_node(node, scope_index, out) if node.is_a?(Prism::ReturnNode)
        node.compact_child_nodes.each { |c| collect_return_types(c, scope_index, out) }
      end

      def type_return_node(return_node, scope_index, out)
        args = return_node.arguments&.arguments || []
        if args.empty?
          out << Type::Combinator.constant_of(nil)
          return
        end

        scope = scope_index[return_node] || scope_index[args.first]
        return if scope.nil?

        # `return a, b` packs into a Tuple at runtime; the MVP
        # only handles the single-value form. Multi-arg returns
        # contribute no type to keep the implementation
        # focused.
        return unless args.size == 1

        type = safe_return_type_of(scope, args.first)
        out << type unless type.nil?
      end

      def safe_return_type_of(scope, node)
        scope.type_of(node)
      rescue StandardError
        nil
      end

      def dynamic_top?(type)
        return true if type.is_a?(Type::Dynamic)
        return true if type.respond_to?(:top?) && type.top?.yes?

        # Post-dogfood: when explicit-return union absorbs
        # Dynamic and the carrier ends up as a Union containing
        # `Dynamic[top]`, the Bug-1 erasure rule renders it as
        # `untyped`. Emitting `def m: () -> untyped` is the
        # `sig.skipped.untyped-return` case — obscures rather
        # than helps — so the skip check considers the erased
        # form too.
        type.respond_to?(:erase_to_rbs) && type.erase_to_rbs == "untyped"
      end

      def lookup_existing_method(class_name, method_name, kind, environment, scope)
        return nil if environment.nil?

        if kind == :singleton
          Reflection.singleton_method_definition(class_name, method_name, scope: scope, environment: environment)
        else
          Reflection.instance_method_definition(class_name, method_name, scope: scope, environment: environment)
        end
      end

      def new_method_candidate(path, def_node, class_name, kind, inferred)
        build_candidate(
          path: path,
          class_name: class_name,
          method_name: def_node.name,
          kind: kind,
          classification: Classification::NEW_METHOD,
          inferred_return: inferred,
          rbs: render_rbs_line(def_node, inferred, class_name, kind)
        )
      end

      def compare_against_declared(path, def_node, class_name, kind, inferred, method_def)
        declared = build_declared_return(method_def)
        declared_rbs = declared&.erase_to_rbs
        inferred_rbs = inferred.erase_to_rbs

        if declared.nil? || declared_rbs == inferred_rbs
          return equivalent(path, def_node, class_name, kind, inferred, declared_rbs)
        end

        unless tighter?(declared, inferred) && !computed_literal_tightening?(inferred, def_node)
          return equivalent(path, def_node, class_name, kind, inferred, declared_rbs)
        end

        build_candidate(
          path: path,
          class_name: class_name,
          method_name: def_node.name,
          kind: kind,
          classification: Classification::TIGHTER_RETURN,
          inferred_return: inferred,
          declared_return_rbs: declared_rbs,
          rbs: render_rbs_line(def_node, inferred, class_name, kind)
        )
      end

      def build_declared_return(method_def)
        translated = method_def.method_types.filter_map { |mt| translate_method_type_return(mt) }
        return nil if translated.empty?

        translated.size == 1 ? translated.first : Type::Combinator.union(*translated)
      end

      def translate_method_type_return(method_type)
        Inference::RbsTypeTranslator.translate(
          method_type.type.return_type,
          self_type: nil, instance_type: nil, type_vars: {}
        )
      rescue StandardError
        nil
      end

      # ADR-14 § "What 'more precise' means". The MVP uses the
      # engine's gradual-mode acceptance — `:strict` is
      # reserved by `Inference::Acceptance` and lands in a
      # follow-up. The "different spelling" guard ensures we
      # never classify a same-string round-trip as tighter.
      #
      # The `loses_declared_union_member?` guard added after
      # the Rigor self-dogfood pass refuses to classify as
      # tighter-return when the declared form is a top-level
      # Union and the inferred form collapses one or more of
      # its declared members. The body-typing path in slice 1
      # only inspects the implicit-return expression, so
      # methods with `return nil unless ...` / boolean
      # `false | true` shapes / `Float | Integer` numeric
      # alternates routinely look "tighter" while actually
      # dropping reachable branches. Treating those as
      # equivalent matches the project rule that an
      # inferred tightening contradicting an existing RBS
      # member set is suspected incomplete inference until
      # proven otherwise.
      def tighter?(declared, inferred)
        return false if inferred.is_a?(Type::Dynamic)
        return false if loses_declared_lenience?(declared, inferred)

        forward = declared.accepts(inferred)
        return false unless forward.yes?

        backward = inferred.accepts(declared)
        !backward.yes?
      end

      # Composite guard: refuse to classify as tighter-return
      # when the declared RBS expresses lenience that the
      # inferred form removes. Three cases all signal
      # incomplete inference rather than precision gain:
      #
      # 1. Top-level union losing one or more declared
      #    members. `return nil unless ...` paths, two-valued
      #    booleans, `Float | Integer` numeric alternates.
      # 2. Generic collection narrowed to a fixed shape.
      #    `Array[T]` → `Tuple[T, ...]`, `Hash[K, V]` →
      #    HashShape — the body's last expression was a
      #    literal whose specific shape is not the method's
      #    contract.
      # 3. `untyped` type-arg replaced by a concrete form.
      #    Declared `Hash[String, untyped]` carries the
      #    author's intentional value-type lenience; the
      #    inference's narrower Union should not override
      #    it.
      def loses_declared_lenience?(declared, inferred)
        loses_declared_union_member?(declared, inferred) ||
          narrows_collection_to_shape?(declared, inferred) ||
          replaces_untyped_type_arg?(declared, inferred)
      end

      def loses_declared_union_member?(declared, inferred)
        return false unless declared.is_a?(Type::Union)

        inferred_members = inferred.is_a?(Type::Union) ? inferred.members : [inferred]
        declared.members.any? do |declared_member|
          inferred_members.none? { |im| structurally_covers?(im, declared_member) }
        end
      end

      def structurally_covers?(inferred_member, declared_member)
        return true if inferred_member == declared_member

        result = inferred_member.accepts(declared_member)
        result.respond_to?(:yes?) && result.yes?
      end

      GENERIC_COLLECTION_CLASSES = %w[
        Array Hash Set Range Enumerable Enumerator Enumerator::Lazy
      ].freeze
      private_constant :GENERIC_COLLECTION_CLASSES

      def narrows_collection_to_shape?(declared, inferred)
        return false unless declared.is_a?(Type::Nominal)
        return false unless GENERIC_COLLECTION_CLASSES.include?(declared.class_name)

        inferred.is_a?(Type::Tuple) || inferred.is_a?(Type::HashShape)
      end

      # Heuristic added after the third-round self-dogfood:
      # `FallbackTracer#size` body is `@events.size`, where
      # `@events` is initialised to `[]` and never assigned
      # again at the class-ivar pre-pass level. The
      # `Type::Tuple[]` (size 0) folds `.size` to
      # `Constant<0>` — the carrier knows the empty-tuple
      # cardinality exactly. But the runtime contract is
      # `Integer` because callers add events through other
      # methods. The signal is "the body's last expression
      # is NOT a directly-authored literal but the inferred
      # type IS a Constant"; in that case the precision
      # came from inference over an internal computation,
      # not the author's contract, so refuse to tighten.
      def computed_literal_tightening?(inferred, def_node)
        return false unless inferred.is_a?(Type::Constant)

        last = body_last_expression(def_node.body)
        !direct_literal_node?(last)
      end

      DIRECT_LITERAL_NODE_TYPES = [
        Prism::IntegerNode, Prism::FloatNode, Prism::StringNode, Prism::SymbolNode,
        Prism::TrueNode, Prism::FalseNode, Prism::NilNode
      ].freeze
      private_constant :DIRECT_LITERAL_NODE_TYPES

      def direct_literal_node?(node)
        DIRECT_LITERAL_NODE_TYPES.any? { |klass| node.is_a?(klass) }
      end

      def replaces_untyped_type_arg?(declared, inferred)
        return false unless declared.is_a?(Type::Nominal) && inferred.is_a?(Type::Nominal)
        return false unless declared.class_name == inferred.class_name
        return false unless declared.type_args.size == inferred.type_args.size

        declared.type_args.zip(inferred.type_args).any? do |d_arg, i_arg|
          d_arg.is_a?(Type::Dynamic) && !i_arg.is_a?(Type::Dynamic)
        end
      end

      def equivalent(path, def_node, class_name, kind, inferred, declared_rbs)
        build_candidate(
          path: path,
          class_name: class_name,
          method_name: def_node.name,
          kind: kind,
          classification: Classification::EQUIVALENT,
          inferred_return: inferred,
          declared_return_rbs: declared_rbs
        )
      end

      def skipped(path, def_node, class_name, kind, reason)
        build_candidate(
          path: path,
          class_name: class_name,
          method_name: def_node.name,
          kind: kind,
          classification: Classification::SKIPPED,
          skip_reason: reason
        )
      end

      def render_rbs_line(def_node, inferred, class_name, kind)
        arity = required_arity(def_node)
        head = arity.zero? ? "()" : "(#{render_param_list(class_name, def_node.name, arity)})"
        prefix = method_def_prefix(class_name, def_node.name, kind)
        "#{prefix}#{def_node.name}: #{head} -> #{paren_wrap_union(elaborated_rbs(inferred))}"
      end

      # Routes the inferred carrier through {TypeElaborator}
      # so bare generic nominals (`Array` / `Hash` / `Set`
      # / `Range` / `Enumerable`) get their `untyped` type
      # parameters filled in before erasing to RBS. The
      # elaborator consults the class's RBS-declared
      # type-parameter list via `Reflection.class_type_param_names`.
      def elaborated_rbs(type)
        TypeElaborator.elaborate(type, environment: @environment).erase_to_rbs
      end

      # RBS / Steep require return-position unions to be
      # parenthesised when they appear bare at the top
      # level of a method type — `def m: () -> 0 | 1` fails
      # the parser because the trailing `| 1` isn't a valid
      # method-type start. Wrap when the erased form is a
      # top-level union; single types and already-bracketed
      # forms (e.g. `Array[A | B]`) parse without wrapping.
      def paren_wrap_union(rendered)
        top_level_union?(rendered) ? "(#{rendered})" : rendered
      end

      def top_level_union?(rendered)
        return false unless rendered.include?(" | ")

        depth = 0
        rendered.each_char.with_index do |ch, i|
          case ch
          when "(", "[", "{" then depth += 1
          when ")", "]", "}" then depth -= 1
          when " "
            return true if depth.zero? && rendered[i + 1] == "|"
          end
        end
        false
      end

      def required_arity(def_node)
        params = def_node.parameters
        params.is_a?(Prism::ParametersNode) ? params.requireds.size : 0
      end

      # Per ADR-5 clause 2 the default is `untyped` for every
      # position. Observed-policy callers (`--params=observed`)
      # pass an `observations:` map at construction time; the
      # generator unions per-position arg types whose tuple
      # arity matches the def's required-positional count.
      # Observations from arities other than the def's count
      # are discarded — they describe a different overload
      # the MVP does not emit.
      def render_param_list(class_name, method_name, arity)
        tuples = matching_observations(class_name, method_name, arity)
        return Array.new(arity, "untyped").join(", ") if tuples.empty?

        Array.new(arity) { |i| union_erase(tuples.map { |obs| obs.positional[i] }) }.join(", ")
      end

      def matching_observations(class_name, method_name, arity)
        return [] if @observations.empty?

        list = @observations[[class_name, method_name]] || []
        list.select { |obs| obs.positional.size == arity }
      end

      def union_erase(types)
        return "untyped" if types.empty?
        return elaborated_rbs(types.first) if types.size == 1

        # `Type::Combinator.union` dedupes by structural type
        # equality. The carrier-level `erase_to_rbs` now
        # absorbs `untyped` members and dedupes the post-erase
        # strings (`String | String` → `String` for distinct
        # `Constant<"Alice">` / `Constant<"Bob">` envelopes),
        # so the sig-gen layer only needs to elaborate bare
        # generics before erasing.
        elaborated_rbs(Type::Combinator.union(*types))
      end

      # ADR-14 slice 4 — `attr_reader` / `attr_writer` /
      # `attr_accessor` recognition. Each Symbol-named entry in
      # the call's argument list yields one or two
      # {MethodCandidate}s whose inferred return type is the
      # corresponding instance-variable's accumulated type from
      # `Scope#class_ivars_for(class_name)`. `attr_reader` adds
      # one reader candidate; `attr_writer` adds one
      # `name=`-method writer candidate; `attr_accessor` adds
      # both.
      ATTR_METHOD_NAMES = %i[attr_reader attr_writer attr_accessor].freeze
      private_constant :ATTR_METHOD_NAMES

      ATTR_KINDS = {
        attr_reader: [:reader],
        attr_writer: [:writer],
        attr_accessor: %i[reader writer]
      }.freeze
      private_constant :ATTR_KINDS

      # Per-file context the attr_* walker threads through its
      # recursive descent. Keeps parameter lists in check.
      AttrWalkContext = Struct.new(:path, :scope_index, :out, keyword_init: true)
      private_constant :AttrWalkContext

      def collect_attr_candidates(root, path, scope_index)
        ctx = AttrWalkContext.new(path: path, scope_index: scope_index, out: [])
        walk_attr_calls(root, [], false, ctx)
        ctx.out
      end

      def walk_attr_calls(node, prefix, in_singleton_class, ctx)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          name = qualified_constant_path(node.constant_path)
          if name
            walk_attr_calls(node.body, prefix + [name], false, ctx) if node.body
            return
          end
        when Prism::SingletonClassNode
          walk_attr_calls(node.body, prefix, true, ctx) if node.body
          return
        when Prism::DefNode
          # Skip method bodies — attr_* there would refer to
          # whatever the method is doing dynamically, not a
          # class-level declaration.
          return
        when Prism::CallNode
          collect_attr_call(node, prefix, in_singleton_class, ctx)
        end

        node.compact_child_nodes.each { |child| walk_attr_calls(child, prefix, in_singleton_class, ctx) }
      end

      def collect_attr_call(call_node, prefix, in_singleton_class, ctx)
        return unless ATTR_METHOD_NAMES.include?(call_node.name)
        return if prefix.empty?
        return if in_singleton_class

        class_name = prefix.join("::")
        symbol_names = extract_symbol_arguments(call_node)
        return if symbol_names.empty?

        ivar_lookup = ivar_type_lookup(ctx.scope_index, class_name)
        symbol_names.each do |attr_name|
          ivar_type = ivar_lookup.call(attr_name)
          ctx.out.concat(build_attr_candidates(call_node.name, class_name, attr_name, ivar_type, ctx))
        end
      end

      def extract_symbol_arguments(call_node)
        (call_node.arguments&.arguments || []).filter_map do |arg|
          arg.unescaped.to_sym if arg.is_a?(Prism::SymbolNode) || arg.is_a?(Prism::StringNode)
        end
      end

      # Returns a closure that looks up `:@<attr_name>` in the
      # class-ivar accumulator carried by the first scope the
      # indexer associated with this file. The accumulator is
      # populated by `ScopeIndexer#build_class_ivar_index`
      # before any statement evaluation runs, so the lookup
      # works even when attr_* declarations come before the
      # corresponding ivar writes lexically.
      def ivar_type_lookup(scope_index, class_name)
        any_scope = scope_index.each_value.first
        return ->(_) {} if any_scope.nil?

        ivars = any_scope.class_ivars_for(class_name)
        ->(attr_name) { ivars[:"@#{attr_name}"] }
      end

      def build_attr_candidates(call_name, class_name, attr_name, ivar_type, ctx)
        ATTR_KINDS.fetch(call_name).flat_map do |variant|
          method_name = variant == :writer ? :"#{attr_name}=" : attr_name
          candidate = build_attr_candidate(class_name, method_name, variant, ivar_type, ctx)
          candidate ? [candidate] : []
        end
      end

      def build_attr_candidate(class_name, method_name, variant, ivar_type, ctx)
        if ivar_type.nil? || dynamic_top?(ivar_type)
          return attr_skipped(ctx.path, class_name, method_name, :untyped_return)
        end

        scope = ctx.scope_index.each_value.first
        environment = scope&.environment
        method_def = lookup_existing_method(class_name, method_name, :instance, environment, scope)
        if method_def.nil?
          attr_new_candidate(ctx.path, class_name, method_name, variant, ivar_type)
        else
          attr_compare_against_declared(ctx.path, class_name, method_name, variant, ivar_type, method_def)
        end
      end

      def attr_new_candidate(path, class_name, method_name, variant, ivar_type)
        build_candidate(
          path: path,
          class_name: class_name,
          method_name: method_name,
          kind: :instance,
          classification: Classification::NEW_METHOD,
          inferred_return: ivar_type,
          rbs: render_attr_rbs_line(method_name, variant, ivar_type)
        )
      end

      def attr_compare_against_declared(path, class_name, method_name, variant, ivar_type, method_def)
        declared = build_declared_return(method_def)
        declared_rbs = declared&.erase_to_rbs
        inferred_rbs = ivar_type.erase_to_rbs

        if declared.nil? || declared_rbs == inferred_rbs || !tighter?(declared, ivar_type)
          return attr_equivalent(path, class_name, method_name, ivar_type, declared_rbs)
        end

        build_candidate(
          path: path, class_name: class_name, method_name: method_name,
          kind: :instance, classification: Classification::TIGHTER_RETURN,
          inferred_return: ivar_type, declared_return_rbs: declared_rbs,
          rbs: render_attr_rbs_line(method_name, variant, ivar_type)
        )
      end

      def attr_equivalent(path, class_name, method_name, ivar_type, declared_rbs)
        build_candidate(
          path: path, class_name: class_name, method_name: method_name,
          kind: :instance, classification: Classification::EQUIVALENT,
          inferred_return: ivar_type, declared_return_rbs: declared_rbs
        )
      end

      def attr_skipped(path, class_name, method_name, reason)
        build_candidate(
          path: path, class_name: class_name, method_name: method_name,
          kind: :instance, classification: Classification::SKIPPED, skip_reason: reason
        )
      end

      # Slice 4 emits attr_* in the long-form `def` spelling so
      # the existing writer's `MethodDefinition`-based merge
      # path applies without extra wiring. Users who prefer the
      # idiomatic `attr_reader name: Type` short form can
      # normalise post-emit; the writer-side member detection
      # (slice 2) treats existing `attr_*` declarations as
      # user-authored so a paired source-side `attr_reader`
      # never produces a duplicate `def` insertion.
      def render_attr_rbs_line(method_name, variant, ivar_type)
        erased = elaborated_rbs(ivar_type)
        wrapped = paren_wrap_union(erased)
        case variant
        when :reader then "def #{method_name}: () -> #{wrapped}"
        when :writer then "def #{method_name}: (#{erased}) -> #{wrapped}"
        end
      end
    end
  end
end
