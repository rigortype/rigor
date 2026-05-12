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
      def initialize(configuration:, paths:, observations: {})
        @configuration = configuration
        @paths = paths
        @observations = observations
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
        candidates_from_defs = defs.map do |def_node, class_name, kind|
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
      # body proves *given an untyped argument tuple*. This is
      # the MVP's clause-1-precision read.
      def infer_return_type(def_node, scope_index)
        body = def_node.body
        return nil if body.nil?

        last = body_last_expression(body)
        return nil if last.nil?

        inner_scope = scope_index[last] || scope_index[body] || scope_index[def_node]
        return nil if inner_scope.nil?

        inner_scope.type_of(last)
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

      def dynamic_top?(type)
        type.is_a?(Type::Dynamic) || (type.respond_to?(:top?) && type.top?.yes?)
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
      def tighter?(declared, inferred)
        return false if inferred.is_a?(Type::Dynamic)

        forward = declared.accepts(inferred)
        return false unless forward.yes?

        backward = inferred.accepts(declared)
        !backward.yes?
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
