# frozen_string_literal: true

require "prism"

require_relative "../environment"
require_relative "../scope"
require_relative "../type"
require_relative "../inference/scope_indexer"

module Rigor
  module SigGen
    # ADR-14 slice 3 — caller-side argument-type observation
    # collector.
    #
    # Walks the user-supplied `--observe=PATH...` tree (default
    # `spec/`), parses every `.rb` file with `Prism`, scope-
    # indexes it the same way the main generator does, and
    # records the per-call-site argument-type tuples for every
    # `Prism::CallNode` whose receiver types as a
    # `Type::Nominal`. The {Generator} consumes the resulting
    # map to render `--params=observed` RBS:
    #
    # @return [Hash{[class_name, method_name] =>
    #   Array<Array<Rigor::Type>>}]
    #
    # ADR-5 clause 2 compliance: the observed union is the
    # MOST PERMISSIVE parameter contract the existing callers
    # prove sufficient — by construction it accepts every type
    # any caller has already passed. The collector only
    # surfaces the data; the default `--params=untyped` keeps
    # the observation inert until the user opts in.
    #
    # MVP scope:
    # - Explicit-receiver calls only (`foo.bar(args)`). Implicit-
    #   self calls inside class bodies and RSpec-style
    #   `let` / `subject` bindings ride on slice 5's optional
    #   `rigor-rspec` integration.
    # - Calls whose receiver does not type as a `Type::Nominal`
    #   (e.g. `(some_dynamic).bar(...)`) are skipped — the
    #   collector cannot attribute them to a specific class.
    # - Zero-argument calls give no observation; methods are
    #   matched by `(class_name, method_name)` only.
    class ObservationCollector # rubocop:disable Metrics/ClassLength
      # @param configuration [Rigor::Configuration]
      # @param paths [Array<String>] observe paths (files /
      #   directories).
      # @param source_paths [Array<String>] source-tree paths
      #   (defaults to `configuration.paths`) pre-walked to
      #   register every project-defined class so that calls
      #   like `Foo.new.bar(x)` in the observe tree resolve
      #   to a `Type::Nominal[Foo]` receiver instead of
      #   degrading to `Dynamic[top]` for the unknown
      #   constant.
      def initialize(configuration:, paths:, source_paths: nil)
        @configuration = configuration
        @paths = paths
        @source_paths = source_paths || configuration.paths
      end

      def collect
        return {} if @paths.empty?

        environment = build_environment
        discovered_classes = preindex_source_classes
        observations = Hash.new { |h, k| h[k] = [] }
        resolve_paths(@paths).each do |path|
          collect_from_file(path, environment, discovered_classes, observations)
        end
        observations.transform_values(&:freeze).freeze
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

      def collect_from_file(path, environment, discovered_classes, observations)
        source = File.read(path)
        parse_result = Prism.parse(source, filepath: path, version: @configuration.target_ruby)
        return if parse_result.errors.any?

        base_scope = Scope.empty(environment: environment).with_discovered_classes(discovered_classes)
        scope_index = Inference::ScopeIndexer.index(parse_result.value, default_scope: base_scope)
        bindings = collect_rspec_bindings(parse_result.value, scope_index)

        walk_calls(parse_result.value, scope_index, bindings, observations)
      end

      # Pre-walks `@source_paths` to collect every qualified
      # class / module declaration. The result feeds
      # `Scope#with_discovered_classes` for each observe-tree
      # scope so `Foo.new` and `Foo` resolve to the right
      # singleton carrier even when no RBS sig describes
      # `Foo` yet.
      def preindex_source_classes
        accumulator = {}
        resolve_paths(@source_paths).each { |path| harvest_classes_from(path, accumulator) }
        accumulator.freeze
      end

      def harvest_classes_from(path, accumulator)
        source = File.read(path)
        parse_result = Prism.parse(source, filepath: path, version: @configuration.target_ruby)
        return if parse_result.errors.any?

        walk_class_decls(parse_result.value, [], accumulator)
      rescue StandardError
        # Source-side harvest failures are tolerated silently
        # — the collector still runs on whichever files
        # parsed cleanly.
      end

      def walk_class_decls(node, prefix, accumulator)
        return unless node.is_a?(Prism::Node)

        if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
          name = qualified_constant_path(node.constant_path)
          if name
            full = (prefix + [name]).join("::")
            accumulator[full] = Type::Combinator.singleton_of(full)
            walk_class_decls(node.body, prefix + [name], accumulator) if node.body
            return
          end
        end

        node.compact_child_nodes.each { |child| walk_class_decls(child, prefix, accumulator) }
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

      def walk_calls(node, scope_index, bindings, observations)
        return unless node.is_a?(Prism::Node)

        record_call(node, scope_index, bindings, observations) if node.is_a?(Prism::CallNode)
        node.compact_child_nodes.each { |child| walk_calls(child, scope_index, bindings, observations) }
      end

      def record_call(call_node, scope_index, bindings, observations)
        receiver = call_node.receiver
        return if receiver.nil?

        scope = scope_index[call_node] || scope_index[receiver]
        return if scope.nil?

        receiver_type = resolve_receiver_type(receiver, scope, bindings)
        key = observation_key(call_node, receiver_type)
        return if key.nil?

        observation = collect_args(call_node, scope)
        return if observation.nil? || observation.empty?

        observations[key] << observation
      end

      # ADR-14 follow-up (A): `.new` → `:initialize` routing.
      # `MethodCatalog.new(path: ...)` types its receiver as
      # `Type::Singleton[MethodCatalog]` and its call name as
      # `:new`, but the *implicit* effect at runtime is a call
      # to `MethodCatalog#initialize(path: ...)`. Route the
      # observation under `[class_name, :initialize]` so the
      # initialize-stub renderer can consult it.
      def observation_key(call_node, receiver_type)
        if receiver_type.is_a?(Type::Singleton) && call_node.name == :new
          [receiver_type.class_name, :initialize]
        elsif receiver_type.is_a?(Type::Nominal)
          [receiver_type.class_name, call_node.name]
        end
      end

      # ADR-14 slice 5 — RSpec-aware receiver typing.
      # Resolves a CallNode receiver against the collected
      # `bindings` map (built by {#collect_rspec_bindings})
      # before falling back to ordinary `scope.type_of`. The
      # three RSpec-shaped receivers we recognise:
      #
      # - Bare-name CallNode (`subject`, `other`, ...) whose
      #   name matches a `subject` / `let(:name)` binding —
      #   return the binding's recorded type.
      # - `described_class.new(...)` chain — when the
      #   surrounding `describe Foo do … end` resolved `Foo`,
      #   return `Type::Nominal[Foo]`.
      # - Anything else — pass through to `scope.type_of`,
      #   matching slice-3 behaviour.
      def resolve_receiver_type(receiver, scope, bindings)
        return resolve_described_class_new(bindings) if described_class_new?(receiver)
        return bindings[receiver.name] if bound_call?(receiver, bindings)

        safe_type_of(scope, receiver)
      end

      def bound_call?(receiver, bindings)
        simple_no_arg_call?(receiver) && bindings.key?(receiver.name)
      end

      def described_class_new?(node)
        return false unless node.is_a?(Prism::CallNode) && node.name == :new

        described_class_reference?(node.receiver)
      end

      def described_class_reference?(node)
        return false unless node.is_a?(Prism::CallNode) && node.name == :described_class

        node.receiver.nil? && (node.arguments&.arguments || []).empty?
      end

      def resolve_described_class_new(bindings)
        singleton = bindings[:described_class]
        return nil unless singleton.is_a?(Type::Singleton)

        Type::Combinator.nominal_of(singleton.class_name)
      end

      def simple_no_arg_call?(node)
        node.is_a?(Prism::CallNode) &&
          node.receiver.nil? &&
          (node.arguments&.arguments || []).empty? &&
          node.block.nil?
      end

      # Walks the spec file for `describe X do … end` /
      # `RSpec.describe X do … end` blocks plus the
      # `subject` / `let(:name)` declarations inside them.
      # Returns a flat map `{ binding_name (Symbol) => Type }`
      # plus a synthetic `:described_class` slot keyed off
      # the nearest enclosing `describe`.
      #
      # The recogniser is intentionally lightweight: it does
      # not enforce RSpec scope rules across `describe` /
      # `context` blocks. Nested `describe` declarations
      # overwrite the outer `described_class` for the
      # remainder of the walk; same-name `let` bindings are
      # last-wins. This matches the typical one-spec-file
      # shape ADR-14 slice 5 targets without re-implementing
      # the `rigor-rspec` plugin's full scope analyser.
      def collect_rspec_bindings(root, scope_index)
        bindings = {}
        walk_rspec_bindings(root, bindings, scope_index)
        bindings
      end

      def walk_rspec_bindings(node, bindings, scope_index)
        return unless node.is_a?(Prism::Node)

        recognise_describe(node, bindings)
        recognise_subject_or_let(node, bindings, scope_index)

        node.compact_child_nodes.each { |child| walk_rspec_bindings(child, bindings, scope_index) }
      end

      def recognise_describe(node, bindings)
        return unless describe_call?(node)

        constant_arg = node.arguments&.arguments&.first
        name = qualified_constant_path(constant_arg) if constant_arg
        bindings[:described_class] = Type::Combinator.singleton_of(name) if name
      end

      def describe_call?(node)
        return false unless node.is_a?(Prism::CallNode) && node.name == :describe

        receiver = node.receiver
        receiver.nil? || (receiver.is_a?(Prism::ConstantReadNode) && receiver.name == :RSpec)
      end

      RSPEC_BINDING_METHODS = %i[subject let let!].freeze
      private_constant :RSPEC_BINDING_METHODS

      def recognise_subject_or_let(node, bindings, scope_index)
        return unless node.is_a?(Prism::CallNode) && RSPEC_BINDING_METHODS.include?(node.name)
        return if node.block.nil?

        name = binding_name_for(node)
        return if name.nil?

        body_type = type_block_body(node.block, scope_index)
        bindings[name] = body_type if body_type
      end

      def binding_name_for(call_node)
        first_arg = call_node.arguments&.arguments&.first
        return call_node.name == :subject ? :subject : nil if first_arg.nil?
        return first_arg.unescaped.to_sym if first_arg.is_a?(Prism::SymbolNode) || first_arg.is_a?(Prism::StringNode)

        nil
      end

      def type_block_body(block_node, scope_index)
        body = block_body_node(block_node)
        return nil if body.nil?

        last_expr = body_last_expression(body)
        return nil if last_expr.nil?

        scope = scope_index[last_expr] || scope_index[block_node]
        return nil if scope.nil?

        safe_type_of(scope, last_expr)
      end

      def block_body_node(block_node)
        return nil unless block_node.is_a?(Prism::BlockNode)

        block_node.body
      end

      def body_last_expression(body)
        case body
        when Prism::StatementsNode then body.body.last
        when Prism::BeginNode then body_last_expression(body.statements)
        else body
        end
      end

      # ADR-14 follow-up (B): walks a call's argument list
      # separating positional from keyword arguments and
      # returning an {ObservedCall} carrier. Splat /
      # forwarded / block arguments still abort the
      # observation (`nil`) — those don't map cleanly to a
      # single per-position type the renderer can union.
      def collect_args(call_node, scope) # rubocop:disable Metrics/CyclomaticComplexity
        positional = []
        keyword = {}
        args = call_node.arguments&.arguments || []
        args.each do |arg|
          case arg
          when Prism::KeywordHashNode
            pairs = read_keyword_pairs(arg, scope)
            return nil if pairs.nil?

            keyword.merge!(pairs)
          when Prism::SplatNode, Prism::BlockArgumentNode, Prism::ForwardingArgumentsNode
            return nil
          else
            type = safe_type_of(scope, arg)
            return nil if type.nil?

            positional << type
          end
        end
        ObservedCall.new(positional: positional, keyword: keyword)
      end

      def read_keyword_pairs(hash_node, scope)
        out = {}
        hash_node.elements.each do |pair|
          return nil unless pair.is_a?(Prism::AssocNode) && pair.key.is_a?(Prism::SymbolNode)

          type = safe_type_of(scope, pair.value)
          return nil if type.nil?

          out[pair.key.unescaped.to_sym] = type
        end
        out
      end

      def safe_type_of(scope, node)
        scope.type_of(node)
      rescue StandardError
        nil
      end
    end
  end
end
