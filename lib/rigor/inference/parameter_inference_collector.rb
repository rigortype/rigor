# frozen_string_literal: true

require "prism"

require_relative "scope_indexer"
require_relative "fork_map"
require_relative "../source/node_walker"

module Rigor
  module Inference
    # Pure argument-type classification for {ParameterInferenceCollector} — no collector state,
    # so it lives outside the orchestration class. Decides which argument types may seed a
    # parameter (concrete enough for the protection metric to bite) and widens a literal
    # argument to its nominal.
    module ParameterArgTypes
      module_function

      CONSTANT_CLASSES = {
        Integer => "Integer", Float => "Float", String => "String",
        Symbol => "Symbol", Range => "Range", TrueClass => "TrueClass",
        FalseClass => "FalseClass", NilClass => "NilClass"
      }.freeze

      # A parameter holds a *value of* a type across its lifetime, not a pinned literal — so a
      # `Constant<"text">` argument widens to its nominal (`String`); recurses through unions so
      # `Constant<"a"> | Constant<"b">` collapses to `String`.
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

      def constant_class_name(value)
        CONSTANT_CLASSES.each { |klass, name| return name if value.is_a?(klass) }
        nil
      end

      # The dispatch class for a receiver type, for the subset the collector resolves to a user
      # `def` (mirrors `CheckRules#concrete_class_name` for the carriers a user-method receiver
      # is typed as). `class_name_of` is the Nominal/Singleton-only variant for an implicit-self
      # `self_type`.
      def concrete_class_name(type)
        case type
        when Type::Nominal, Type::Singleton then type.class_name
        when Type::Tuple then "Array"
        when Type::HashShape then "Hash"
        end
      end

      def class_name_of(type)
        type.class_name if type.is_a?(Type::Nominal) || type.is_a?(Type::Singleton)
      end

      # Whether `type` is too gradual to seed (not a concrete dispatch target) — the negation of
      # `ProtectionScanner#concrete_receiver?` (a union is concrete only when every arm is).
      def non_concrete?(type)
        case type
        when Type::Dynamic, Type::Top, Type::Bot then true
        when Type::Union then type.members.any? { |member| non_concrete?(member) }
        else false
        end
      end
    end

    # ADR-67 WD3 + WD5 — call-site parameter type inference (capped fixpoint).
    #
    # A `def` parameter with no RBS signature types `untyped` (the gradual entry point), so a
    # param flowing into an ivar or a receiver drains everything downstream to `Dynamic`. This
    # pass closes that hole: it walks every project file, types each call's positional
    # arguments in their lexical scope, resolves which user-defined `def` each call targets,
    # and records the **union of resolved call-site argument types** per parameter — TypeProf's
    # "a parameter's type is the union of every actual argument across all call sites". WD5: it
    # iterates (cap {DEFAULT_ROUNDS}), re-seeding each round with the previous round's inferred
    # parameters, so a parameter passed *another* parameter is typed one hop further per round
    # (round 1 alone is the single-level pass).
    #
    # The result is keyed by `[class_name, method_name, kind]` — the same triple
    # `StatementEvaluator#build_method_entry_scope` reconstructs from the lexical class path —
    # so the consumer can seed an undeclared parameter with its inferred type. The table is
    # precision-additive only: it never feeds a parameter-boundary diagnostic (an inferred type
    # lives solely as a body local, and the boundary rules consult RBS, not body locals — see
    # ADR-67 WD1), so being wrong cannot manufacture a false positive at a caller.
    #
    # Soundness (WD4): the inferred type is a sound over-approximation only when every
    # contributed call site resolves to a concrete argument type. Any `Dynamic` / `Top` /
    # `Bot` argument (a `send`/dynamic-dispatch caller, or a parameter not yet typed in an
    # earlier round) **poisons** the parameter, which then contributes nothing this round (it
    # may type in a later round once its own argument resolves). Unresolved call sites do not
    # contribute.
    #
    # What it does NOT do yet (deferred — the check-wiring slice): feeding the table into the
    # `check` walk (only `coverage --protection` consumes it today), keyword / optional / rest
    # / block parameters, inherited-method receivers, top-level helpers, and a rigorous
    # closed-call-site-set proof (the union is optimistic over resolved sites — acceptable
    # because the only consumer is the protection metric, which runs no diagnostics).
    class ParameterInferenceCollector
      EMPTY = {}.freeze

      # A defensive widening cap (ADR-41): a parameter unioned from more than this many distinct
      # concrete call-site types is widened to `untyped` (poisoned) rather than carrying an
      # unbounded union.
      MAX_CALL_SITE_TYPES = 16

      # WD5 — the call-site union is a worklist fixpoint: each round re-types the project with
      # the previous round's inferred parameters seeded, so a parameter passed *another*
      # parameter is typed one hop further per round. Capped (no true-convergence requirement —
      # the metric tolerates a bounded approximation, and the table can oscillate at the margin
      # since a newly resolved receiver can surface a fresh untyped-argument call site). The cap
      # matches the `Inference::BodyFixpoint` cap-3 convention. Round 1 alone is the
      # single-level pass.
      DEFAULT_ROUNDS = 3

      # @rbs files: Array[String] -- Project `.rb` paths to scan for call sites.
      # @rbs target_ruby: String? -- Prism parse target.
      # @rbs max_rounds: Integer -- The WD5 fixpoint cap (1 = single-level).
      # @rbs return: Hash[[String, Symbol, Symbol], Hash[Symbol, Rigor::Type]] -- Frozen.
      def self.collect(files:, environment:, target_ruby: nil, max_rounds: DEFAULT_ROUNDS, workers: 0)
        new(files: files, environment: environment, target_ruby: target_ruby,
            max_rounds: max_rounds, workers: workers).collect
      end

      def initialize(files:, environment:, target_ruby: nil, max_rounds: DEFAULT_ROUNDS, workers: 0)
        @files = files
        @environment = environment
        @target_ruby = target_ruby
        @max_rounds = max_rounds
        # P3-10 — fork-parallelism for the per-round re-typing (the dominant coverage-protection cost). A
        # round's per-file typing is independent; contributions merge associatively (see {#merge_round}), so
        # forking over file slices is byte-identical to the sequential pass. 0/1 → sequential.
        @workers = workers
        # Reset per round (see {#run_round}). `[[class, method, kind], param_sym]` => [Type] of
        # observed concrete arguments (a default-block Hash, not a `{}` literal, so the
        # analyzer types its reads generically — {#finalize}), plus the ids widened to
        # `untyped` (an untyped / over-cap argument).
        @type_observations = Hash.new { |hash, id| hash[id] = [] }
        @poisoned_params = Set.new
      end

      def collect
        parsed = parse_all
        # Force the full RBS load on the parent so forked round-workers copy-on-write inherit a warm
        # environment instead of each rebuilding it (mirrors the check / scan fork pools). A no-op on the
        # sequential path.
        @environment.rbs_loader&.prewarm if ForkMap.parallel?([@workers, parsed.size].min)
        discovery = discovery_seed_tables
        # The union of every method name any discovered `def` declares. A call whose name is absent cannot
        # bind in `resolve_callee`, so {#record_call} short-circuits it before typing its receiver (an
        # on-demand dispatch for an otherwise-unresolved call). ~73% of call sites in a Rails app name a
        # method no user def declares; a pure negative filter, so the resolved table is byte-identical.
        @user_method_names = user_method_names(discovery)
        table = EMPTY
        @max_rounds.times do
          rounded = run_round(parsed, discovery, table)
          return rounded if rounded == table # fixpoint reached

          table = rounded
        end
        table
      end

      private

      # Parse every project file once; rounds re-index the cached ASTs against an evolving seed
      # rather than re-parsing.
      def parse_all
        @files.filter_map do |path|
          result = Prism.parse(File.read(path), filepath: path, version: @target_ruby)
          [path, result.value] if result.errors.empty?
        rescue Errno::ENOENT, Errno::EISDIR, Errno::EACCES
          nil
        end
      end

      # One fixpoint round: re-type every file with `seed_table` (the previous round's inferred
      # parameters) seeded, collecting the next round's table. The per-file typing is fork-mapped over
      # `@workers` (byte-identical to sequential — see {#merge_round}); each slice returns a marshalable
      # `[observations, poisoned]` contribution the parent merges in slice order.
      def run_round(parsed, discovery_tables, seed_table)
        seed_scope = build_seed_scope(discovery_tables, seed_table)
        contributions = ForkMap.call(items: parsed, workers: @workers) do |slice|
          accumulate_slice(slice, seed_scope)
        end
        merge_round(contributions)
      end

      # Types every call in one contiguous file slice, returning a marshalable contribution: the per-`id`
      # observed argument types (default proc stripped for `Marshal`) and the poisoned-`id` list. Uses the
      # per-process observation ivars, so a forked worker and the sequential single-slice call share this
      # exact code.
      def accumulate_slice(parsed_slice, seed_scope)
        @type_observations = Hash.new { |hash, id| hash[id] = [] }
        @poisoned_params = Set.new
        parsed_slice.each do |path, ast|
          index = ScopeIndexer.index(ast, default_scope: seed_scope.with_source_path(path))
          Source::NodeWalker.each(ast) do |node|
            record_call(node, index) if node.is_a?(Prism::CallNode)
          end
        end
        # Copy into a plain Hash, dropping the default proc — a Marshal-unfriendly proc the fork worker
        # would otherwise fail to dump. (`.to_h` returns self here, keeping the proc, so copy explicitly.)
        observations = @type_observations.each_with_object({}) { |(id, types), plain| plain[id] = types }
        [observations, @poisoned_params.to_a]
      end

      # Merges the per-slice contributions into the round's table. Associative and order-preserving, so the
      # result is identical to a sequential single-slice run: a parameter is poisoned if ANY slice poisoned
      # it, its observations are the file-order concatenation across slices, and the {MAX_CALL_SITE_TYPES}
      # cap re-applies over the merged total (a per-slice sub-cap can undercount, so the parent enforces the
      # real cap — the same "poisoned" outcome the sequential mid-stream cap reaches).
      def merge_round(contributions)
        poisoned = contributions.each_with_object(Set.new) { |(_obs, pois), set| set.merge(pois) }
        observations = {}
        contributions.each do |(obs, _pois)|
          obs.each do |id, types|
            (observations[id] ||= []).concat(types) unless poisoned.include?(id)
          end
        end
        observations.each { |id, types| poisoned << id if types.length > MAX_CALL_SITE_TYPES }
        finalize(observations, poisoned)
      end

      # A scope carrying the cross-file discovery index (so `Foo.new` receivers and
      # implicit-self calls resolve to a user `def`) plus the prior round's inferred parameters
      # (so an argument that reads a parameter types to its current inferred type — the WD5
      # propagation).
      def build_seed_scope(discovery_tables, seed_table)
        base = Scope.empty(environment: @environment)
        tables = discovery_tables
        tables = tables.merge(param_inferred_types: seed_table) unless seed_table.empty?
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
        # Discovery is best-effort; a malformed corner of the project must not crash the
        # protection scan. Without discovery the collector simply resolves fewer call sites.
        {}
      end

      DISCOVERY_FIELD = {
        def_nodes: :discovered_def_nodes,
        singleton_def_nodes: :discovered_singleton_def_nodes,
        def_sources: :discovered_def_sources,
        superclasses: :discovered_superclasses,
        header_nestings: :discovered_header_nestings,
        includes: :discovered_includes,
        class_sources: :discovered_class_sources,
        method_visibilities: :discovered_method_visibilities,
        methods: :discovered_methods,
        data_member_layouts: :data_member_layouts,
        struct_member_layouts: :struct_member_layouts
      }.freeze
      private_constant :DISCOVERY_FIELD

      # Built once over the whole project and inherited by the fork workers via copy-on-write; a frozen Set
      # for O(1) membership in the {#record_call} hot loop.
      def user_method_names(discovery)
        tables = [discovery[:discovered_def_nodes], discovery[:discovered_singleton_def_nodes]].compact
        tables.flat_map { |table| table.values.flat_map(&:keys) }.to_set.freeze
      end

      def record_call(call_node, index)
        # See {#collect}: a name no discovered def declares cannot resolve, so skip without typing anything.
        return unless @user_method_names.include?(call_node.name)

        args = positional_args(call_node)
        return if args.nil?

        scope = index[call_node]
        return if scope.nil?

        callee = resolve_callee(call_node, scope, index)
        return if callee.nil?

        class_name, method, kind, def_node = callee
        requireds = leading_requireds(def_node)
        # Enough positional arguments to fill every leading required (extra args map to trailing
        # optional / rest parameters, which this pass does not infer). Fewer would be an arity error
        # or a mis-resolved callee; skip rather than mis-attribute.
        return if requireds.nil? || args.size < requireds.size

        key = [class_name, method, kind]
        requireds.each_with_index do |param, i|
          arg_scope = index[args[i]]
          accumulate(key, param.name, arg_scope&.type_of(args[i]))
        end
      end

      # The plain leading positional arguments. A trailing keyword hash (`f(x, k: 1)`) or block-pass
      # (`f(x, &blk)`) is dropped — it occupies no positional slot, so the leading args still map to
      # the leading required parameters. Returns nil when the call carries a splat (`f(*xs, x)`) or
      # forwarding (`f(...)`) argument: those make an argument's position depend on runtime length,
      # breaking the positional-index ↔ parameter mapping, so the call site is skipped.
      def positional_args(call_node)
        arguments = call_node.arguments
        return [] if arguments.nil?

        list = arguments.arguments
        return nil if list.any? { |arg| position_breaking_argument?(arg) }

        list.reject { |arg| non_positional_argument?(arg) }
      end

      def position_breaking_argument?(arg)
        arg.is_a?(Prism::SplatNode) || arg.is_a?(Prism::ForwardingArgumentsNode)
      end

      def non_positional_argument?(arg)
        arg.is_a?(Prism::KeywordHashNode) ||
          arg.is_a?(Prism::BlockArgumentNode) ||
          arg.is_a?(Prism::AssocNode) ||
          arg.is_a?(Prism::AssocSplatNode)
      end

      # @rbs return: [String, Symbol, Symbol, Prism::DefNode]?
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

        [ParameterArgTypes.class_name_of(self_type), self_type.is_a?(Type::Singleton) ? :singleton : :instance]
      end

      def explicit_receiver_target(receiver, index, scope)
        receiver_type = (index[receiver] || scope).type_of(receiver)
        [ParameterArgTypes.concrete_class_name(receiver_type),
         receiver_type.is_a?(Type::Singleton) ? :singleton : :instance]
      end

      def lookup_def(scope, class_name, method, kind)
        table = kind == :singleton ? scope.discovered_singleton_def_nodes : scope.discovered_def_nodes
        per_class = table[class_name]
        per_class && per_class[method]
      end

      # The leading required-positional parameters — the ones a call's leading positional arguments
      # map to. Ruby orders parameters requireds-first, so optional / rest / keyword / block
      # parameters that FOLLOW the requireds do not disturb the leading positional-index ↔
      # required-parameter mapping; this covers the common `def f(x, opts = {}, **kw)` /
      # `def f(x, y, &block)` shapes the earlier all-required contract skipped entirely. Returns nil
      # only when a required slot is a destructured `(a, b)` (no bindable name) or a post-rest
      # required (`def f(a, *b, c)` — `c` maps to a trailing arg, breaking the leading-prefix
      # assumption for the whole call), which would mis-attribute arguments.
      def leading_requireds(def_node)
        params = def_node.parameters
        return [] if params.nil?
        return nil unless params.is_a?(Prism::ParametersNode)
        return nil unless params.posts.empty?
        return nil unless params.requireds.all?(Prism::RequiredParameterNode)

        params.requireds
      end

      def accumulate(key, param_name, arg_type)
        id = [key, param_name.to_sym]
        return if @poisoned_params.include?(id)

        if arg_type.nil? || ParameterArgTypes.non_concrete?(arg_type)
          poison(id)
        else
          observations = @type_observations[id]
          observations << ParameterArgTypes.widen_for_param(arg_type)
          poison(id) if observations.length > MAX_CALL_SITE_TYPES
        end
      end

      # A poisoned parameter is dropped from the observation store and recorded so later call
      # sites short-circuit. `id` is the `[[class, method, kind], param]` pair.
      def poison(id)
        @poisoned_params << id
        @type_observations.delete(id)
      end

      # Builds the round's frozen `[class, method, kind] => {param => Type}` table from the merged
      # observations and poisoned set.
      def finalize(merged_observations, poisoned)
        # `result` is a default-block Hash (not a `{}` literal) so the analyzer types its reads
        # generically rather than folding the empty shape — the nesting writes stay plain
        # assignments, no literal-fold conditions.
        result = Hash.new { |hash, key| hash[key] = {} }
        merged_observations.each do |id, observations|
          next if poisoned.include?(id)
          next if observations.empty?

          union = Type::Combinator.union(*observations)
          # A union that collapsed to a non-concrete shape (e.g. a gradual arm leaked in) is no
          # better than `untyped`; drop it.
          next if ParameterArgTypes.non_concrete?(union)

          key, param = id
          result[key][param] = union
        end
        result.transform_values(&:freeze).freeze
      end
    end
  end
end
