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
        @observations = observations
        @include_private = include_private
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
      def collect_method_definitions(root)
        out = []
        walk_defs(root, [], false, out)
        out
      end

      def walk_defs(node, prefix, in_singleton_class, out) # rubocop:disable Metrics/CyclomaticComplexity
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          name = qualified_constant_path(node.constant_path)
          if name
            walk_defs(node.body, prefix + [name], false, out) if node.body
            return
          end
        when Prism::SingletonClassNode
          if node.expression.is_a?(Prism::SelfNode) && node.body
            walk_defs(node.body, prefix, true, out)
            return
          end
        when Prism::DefNode
          collect_def_node(node, prefix, in_singleton_class, out)
          return
        end

        node.compact_child_nodes.each { |child| walk_defs(child, prefix, in_singleton_class, out) }
      end

      def collect_def_node(node, prefix, in_singleton_class, out)
        return if prefix.empty?

        kind = node.receiver.is_a?(Prism::SelfNode) || in_singleton_class ? :singleton : :instance
        out << [node, prefix.join("::"), kind]
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
      # `{}`), which produces nonsense return types for
      # `sig/`. Skipping entirely lets the `Object#initialize`
      # RBS fallback cover the lookup; users who want a
      # specific initialize sig hand-author it.
      def initialize_excludes?(def_node, kind)
        kind == :instance && def_node.name == :initialize
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

      def classify_def(path, def_node, class_name, kind, scope_index) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        return nil if visibility_excludes?(def_node, class_name, kind, scope_index)
        return nil if initialize_excludes?(def_node, kind)

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

      def type_return_node(return_node, scope_index, out) # rubocop:disable Metrics/CyclomaticComplexity
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
        MethodCandidate.new(
          path: path,
          class_name: class_name,
          method_name: def_node.name,
          kind: kind,
          classification: Classification::NEW_METHOD,
          inferred_return: inferred,
          rbs: render_rbs_line(def_node, inferred, class_name, kind)
        )
      end

      def compare_against_declared(path, def_node, class_name, kind, inferred, method_def) # rubocop:disable Metrics/ParameterLists
        declared = build_declared_return(method_def)
        declared_rbs = declared&.erase_to_rbs
        inferred_rbs = inferred.erase_to_rbs

        if declared.nil? || declared_rbs == inferred_rbs
          return equivalent(path, def_node, class_name, kind, inferred, declared_rbs)
        end

        return equivalent(path, def_node, class_name, kind, inferred, declared_rbs) unless tighter?(declared, inferred)

        MethodCandidate.new(
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

      def replaces_untyped_type_arg?(declared, inferred)
        return false unless declared.is_a?(Type::Nominal) && inferred.is_a?(Type::Nominal)
        return false unless declared.class_name == inferred.class_name
        return false unless declared.type_args.size == inferred.type_args.size

        declared.type_args.zip(inferred.type_args).any? do |d_arg, i_arg|
          d_arg.is_a?(Type::Dynamic) && !i_arg.is_a?(Type::Dynamic)
        end
      end

      def equivalent(path, def_node, class_name, kind, inferred, declared_rbs) # rubocop:disable Metrics/ParameterLists
        MethodCandidate.new(
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
        MethodCandidate.new(
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
        prefix = kind == :singleton ? "def self." : "def "
        "#{prefix}#{def_node.name}: #{head} -> #{elaborated_rbs(inferred)}"
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

        Array.new(arity) { |i| union_erase(tuples.map { |args| args[i] }) }.join(", ")
      end

      def matching_observations(class_name, method_name, arity)
        return [] if @observations.empty?

        list = @observations[[class_name, method_name]] || []
        list.select { |tuple| tuple.size == arity }
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

      def walk_attr_calls(node, prefix, in_singleton_class, ctx) # rubocop:disable Metrics/CyclomaticComplexity
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
        MethodCandidate.new(
          path: path,
          class_name: class_name,
          method_name: method_name,
          kind: :instance,
          classification: Classification::NEW_METHOD,
          inferred_return: ivar_type,
          rbs: render_attr_rbs_line(method_name, variant, ivar_type)
        )
      end

      def attr_compare_against_declared(path, class_name, method_name, variant, ivar_type, method_def) # rubocop:disable Metrics/ParameterLists
        declared = build_declared_return(method_def)
        declared_rbs = declared&.erase_to_rbs
        inferred_rbs = ivar_type.erase_to_rbs

        if declared.nil? || declared_rbs == inferred_rbs || !tighter?(declared, ivar_type)
          return attr_equivalent(path, class_name, method_name, ivar_type, declared_rbs)
        end

        MethodCandidate.new(
          path: path, class_name: class_name, method_name: method_name,
          kind: :instance, classification: Classification::TIGHTER_RETURN,
          inferred_return: ivar_type, declared_return_rbs: declared_rbs,
          rbs: render_attr_rbs_line(method_name, variant, ivar_type)
        )
      end

      def attr_equivalent(path, class_name, method_name, ivar_type, declared_rbs)
        MethodCandidate.new(
          path: path, class_name: class_name, method_name: method_name,
          kind: :instance, classification: Classification::EQUIVALENT,
          inferred_return: ivar_type, declared_return_rbs: declared_rbs
        )
      end

      def attr_skipped(path, class_name, method_name, reason)
        MethodCandidate.new(
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
        case variant
        when :reader then "def #{method_name}: () -> #{erased}"
        when :writer then "def #{method_name}: (#{erased}) -> #{erased}"
        end
      end
    end
  end
end
