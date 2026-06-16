# frozen_string_literal: true

require "prism"

require_relative "scope_indexer"
require_relative "../source/node_walker"

module Rigor
  module Inference
    # ADR-67 WD3 — call-site parameter type inference (single-level).
    #
    # A `def` parameter with no RBS signature types `untyped` (the gradual
    # entry point), so a param flowing into an ivar or a receiver drains
    # everything downstream to `Dynamic`. This pass closes the *single-level*
    # slice of that hole: it walks every project file, types each call's
    # positional arguments in their lexical scope, resolves which user-defined
    # `def` each call targets, and records the **union of resolved call-site
    # argument types** per parameter — TypeProf's "a parameter's type is the
    # union of every actual argument across all call sites", taken one level
    # deep (no fixpoint).
    #
    # The result is keyed by `[class_name, method_name, kind]` — the same triple
    # `StatementEvaluator#build_method_entry_scope` reconstructs from the lexical
    # class path — so the consumer can seed an undeclared parameter with its
    # inferred type. The table is precision-additive only: it never feeds a
    # parameter-boundary diagnostic (an inferred type lives solely as a body
    # local, and the boundary rules consult RBS, not body locals — see ADR-67
    # WD1), so being wrong cannot manufacture a false positive at a caller.
    #
    # Soundness (WD4): the inferred type is a sound over-approximation only when
    # every contributed call site resolves to a concrete argument type. Any
    # `Dynamic` / `Top` / `Bot` argument (the fixpoint case — an argument that is
    # itself an untyped parameter — or a `send`/dynamic-dispatch caller)
    # **poisons** the parameter, which then contributes nothing (stays
    # `untyped`). Unresolved call sites simply do not contribute. This keeps the
    # single-level pass from ever narrowing a parameter on incomplete evidence.
    #
    # What it does NOT do yet (deferred follow-ups, ADR-67 WD5 / the check-wiring
    # slice): the whole-program worklist *fixpoint* (so a parameter passed
    # another untyped parameter is never typed), keyword / optional / rest /
    # block parameters, inherited-method receivers, top-level helpers, and a
    # rigorous closed-call-site-set proof (today's union is optimistic over
    # resolved sites — acceptable because the only consumer is the protection
    # metric, which runs no diagnostics).
    class ParameterInferenceCollector
      EMPTY = {}.freeze

      # A defensive widening cap (ADR-41): a parameter unioned from more than
      # this many distinct concrete call-site types is widened to `untyped`
      # (poisoned) rather than carrying an unbounded union.
      MAX_CALL_SITE_TYPES = 16

      # @param files [Array<String>] project `.rb` paths to scan for call sites.
      # @param environment [Rigor::Environment]
      # @param target_ruby [String, nil] Prism parse target.
      # @return [Hash{[String,Symbol,Symbol] => Hash{Symbol => Rigor::Type}}] frozen.
      def self.collect(files:, environment:, target_ruby: nil)
        new(files: files, environment: environment, target_ruby: target_ruby).collect
      end

      def initialize(files:, environment:, target_ruby: nil)
        @files = files
        @environment = environment
        @target_ruby = target_ruby
        # `[[class, method, kind], param_sym]` => [Type] of observed concrete
        # arguments. A default-block Hash (not a `{}` literal) so the analyzer
        # types its reads generically — see {#finalize}.
        @type_observations = Hash.new { |hash, id| hash[id] = [] }
        # The same ids whose union was widened to `untyped` (an untyped /
        # over-cap argument); short-circuits later call sites.
        @poisoned_params = Set.new
      end

      def collect
        seed_scope = build_seed_scope
        @files.each { |path| collect_file(path, seed_scope) }
        finalize
      end

      private

      # A scope carrying the cross-file discovery index so the collector can
      # resolve `Foo.new` receivers and implicit-self calls to a user `def`.
      def build_seed_scope
        base = Scope.empty(environment: @environment)
        tables = discovery_seed_tables
        return base if tables.empty?

        base.with_discovery(base.discovery.with(**tables))
      end

      def discovery_seed_tables
        classes = ScopeIndexer.discovered_classes_for_paths(@files)
        def_index = ScopeIndexer.discovered_def_index_for_paths(@files)
        tables = {}
        tables[:discovered_classes] = classes unless classes.empty?
        DISCOVERY_FIELD.each do |index_key, field|
          table = def_index.fetch(index_key)
          tables[field] = table unless table.empty?
        end
        tables
      rescue StandardError
        # Discovery is best-effort; a malformed corner of the project must not
        # crash the protection scan. Without discovery the collector simply
        # resolves fewer call sites.
        {}
      end

      DISCOVERY_FIELD = {
        def_nodes: :discovered_def_nodes,
        singleton_def_nodes: :discovered_singleton_def_nodes,
        def_sources: :discovered_def_sources,
        superclasses: :discovered_superclasses,
        includes: :discovered_includes,
        class_sources: :discovered_class_sources,
        method_visibilities: :discovered_method_visibilities,
        methods: :discovered_methods,
        data_member_layouts: :data_member_layouts,
        struct_member_layouts: :struct_member_layouts
      }.freeze
      private_constant :DISCOVERY_FIELD

      def collect_file(path, seed_scope)
        source = File.read(path)
        parse = Prism.parse(source, filepath: path, version: @target_ruby)
        return unless parse.errors.empty?

        file_scope = seed_scope.with_source_path(path)
        index = ScopeIndexer.index(parse.value, default_scope: file_scope)
        Source::NodeWalker.each(parse.value) do |node|
          record_call(node, index) if node.is_a?(Prism::CallNode)
        end
      rescue Errno::ENOENT, Errno::EISDIR, Errno::EACCES
        nil
      end

      def record_call(call_node, index)
        args = positional_args(call_node)
        return if args.nil?

        scope = index[call_node]
        return if scope.nil?

        callee = resolve_callee(call_node, scope, index)
        return if callee.nil?

        class_name, method, kind, def_node = callee
        requireds = simple_requireds(def_node)
        return if requireds.nil? || requireds.size != args.size

        key = [class_name, method, kind]
        args.each_with_index do |arg, i|
          arg_scope = index[arg]
          accumulate(key, requireds[i].name, arg_scope&.type_of(arg))
        end
      end

      # The plain positional arguments, or nil when the call carries any
      # non-plain argument (splat / keyword / block-pass / forwarding) — those
      # break the positional-index ↔ parameter mapping, so the call site is
      # skipped rather than mis-attributed.
      def positional_args(call_node)
        arguments = call_node.arguments
        return [] if arguments.nil?

        list = arguments.arguments
        return nil if list.any? { |arg| non_plain_argument?(arg) }

        list
      end

      def non_plain_argument?(arg)
        arg.is_a?(Prism::SplatNode) ||
          arg.is_a?(Prism::KeywordHashNode) ||
          arg.is_a?(Prism::BlockArgumentNode) ||
          arg.is_a?(Prism::ForwardingArgumentsNode) ||
          arg.is_a?(Prism::AssocNode) ||
          arg.is_a?(Prism::AssocSplatNode)
      end

      # @return [[String, Symbol, Symbol, Prism::DefNode], nil]
      def resolve_callee(call_node, scope, index)
        if call_node.receiver.nil?
          class_name, kind = implicit_self_target(scope)
        else
          class_name, kind = explicit_receiver_target(call_node.receiver, index, scope)
        end
        return nil if class_name.nil?

        def_node = lookup_def(scope, class_name, call_node.name, kind)
        return nil if def_node.nil?

        [class_name, call_node.name, kind, def_node]
      end

      def implicit_self_target(scope)
        self_type = scope.self_type
        return [nil, nil] if self_type.nil?

        [class_name_of(self_type), self_type.is_a?(Type::Singleton) ? :singleton : :instance]
      end

      def explicit_receiver_target(receiver, index, scope)
        receiver_type = (index[receiver] || scope).type_of(receiver)
        [concrete_class_name(receiver_type), receiver_type.is_a?(Type::Singleton) ? :singleton : :instance]
      end

      def lookup_def(scope, class_name, method, kind)
        table = kind == :singleton ? scope.discovered_singleton_def_nodes : scope.discovered_def_nodes
        per_class = table[class_name]
        per_class && per_class[method]
      end

      # The required-positional parameters, or nil when the method's parameter
      # list is not a simple all-required shape (matching the single-level
      # contract `ExpressionTyper#user_method_param_shape_simple?` uses) or
      # contains a destructured `(a, b)` slot (no bindable name).
      def simple_requireds(def_node)
        params = def_node.parameters
        return [] if params.nil?
        return nil unless params.is_a?(Prism::ParametersNode)
        return nil unless params.optionals.empty? && params.rest.nil? && params.posts.empty? &&
                          params.keywords.empty? && params.keyword_rest.nil? && params.block.nil?
        return nil unless params.requireds.all?(Prism::RequiredParameterNode)

        params.requireds
      end

      def accumulate(key, param_name, arg_type)
        id = [key, param_name.to_sym]
        return if @poisoned_params.include?(id)

        if arg_type.nil? || non_concrete?(arg_type)
          poison(id)
        else
          observations = @type_observations[id]
          observations << widen_for_param(arg_type)
          poison(id) if observations.length > MAX_CALL_SITE_TYPES
        end
      end

      # A parameter holds a *value of* a type across its lifetime, not a pinned
      # literal — so a `Constant<"text">` argument widens to its nominal
      # (`String`). Keeps the inferred type sound as a parameter type (and avoids
      # a downstream literal-fold the parameter never actually guarantees).
      # Recurses through unions so `Constant<"a"> | Constant<"b">` collapses to
      # `String`.
      def widen_for_param(type)
        case type
        when Type::Constant
          name = constant_class_name(type.value)
          name ? Type::Combinator.nominal_of(name) : type
        when Type::Union
          Type::Combinator.union(*type.members.map { |member| widen_for_param(member) })
        else
          type
        end
      end

      CONSTANT_CLASSES = {
        Integer => "Integer", Float => "Float", String => "String",
        Symbol => "Symbol", Range => "Range", TrueClass => "TrueClass",
        FalseClass => "FalseClass", NilClass => "NilClass"
      }.freeze
      private_constant :CONSTANT_CLASSES

      def constant_class_name(value)
        CONSTANT_CLASSES.each { |klass, name| return name if value.is_a?(klass) }
        nil
      end

      # A poisoned parameter is dropped from the observation store and recorded
      # so later call sites short-circuit. `id` is the `[[class, method, kind],
      # param]` pair.
      def poison(id)
        @poisoned_params << id
        @type_observations.delete(id)
      end

      def finalize
        # `result` is a default-block Hash (not a `{}` literal) so the analyzer
        # types its reads generically rather than folding the empty shape — the
        # nesting writes stay plain assignments, no literal-fold conditions.
        result = Hash.new { |hash, key| hash[key] = {} }
        @type_observations.each do |id, observations|
          next if @poisoned_params.include?(id)
          next if observations.empty?

          union = Type::Combinator.union(*observations)
          # A union that collapsed to a non-concrete shape (e.g. a gradual arm
          # leaked in) is no better than `untyped`; drop it.
          next if non_concrete?(union)

          key, param = id
          result[key][param] = union
        end
        result.transform_values(&:freeze).freeze
      end

      def class_name_of(type)
        type.class_name if type.is_a?(Type::Nominal) || type.is_a?(Type::Singleton)
      end

      # The dispatch class for a receiver type, for the subset the collector
      # resolves to a user `def`. Mirrors `CheckRules#concrete_class_name` for
      # the carriers a user-method receiver is typed as.
      def concrete_class_name(type)
        case type
        when Type::Nominal, Type::Singleton then type.class_name
        when Type::Tuple then "Array"
        when Type::HashShape then "Hash"
        end
      end

      # Whether `type` is too gradual to seed: it is not a concrete dispatch
      # target the protection metric can bite. Mirrors the negation of
      # `ProtectionScanner#concrete_receiver?` (a union is concrete only when
      # every arm is).
      def non_concrete?(type)
        case type
        when Type::Dynamic, Type::Top, Type::Bot then true
        when Type::Union then type.members.any? { |member| non_concrete?(member) }
        else false
        end
      end
    end
  end
end
