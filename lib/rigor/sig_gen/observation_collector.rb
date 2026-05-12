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

        walk_calls(parse_result.value, scope_index, observations)
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

      def walk_calls(node, scope_index, observations)
        return unless node.is_a?(Prism::Node)

        record_call(node, scope_index, observations) if node.is_a?(Prism::CallNode)
        node.compact_child_nodes.each { |child| walk_calls(child, scope_index, observations) }
      end

      def record_call(call_node, scope_index, observations)
        receiver = call_node.receiver
        return if receiver.nil?

        scope = scope_index[call_node] || scope_index[receiver]
        return if scope.nil?

        receiver_type = safe_type_of(scope, receiver)
        return unless receiver_type.is_a?(Type::Nominal)

        arg_types = collect_arg_types(call_node, scope)
        return if arg_types.nil? || arg_types.empty?

        observations[[receiver_type.class_name, call_node.name]] << arg_types
      end

      def collect_arg_types(call_node, scope)
        args = call_node.arguments&.arguments || []
        return nil if args.any? { |arg| non_positional?(arg) }

        types = args.map { |arg| safe_type_of(scope, arg) }
        types.include?(nil) ? nil : types
      end

      # The MVP rejects splat / keyword / forwarded arguments
      # — those need positional-vs-keyword separation the
      # generator does not yet emit. Slice 4 widens the
      # acceptance once the def-emission surface grows the
      # matching shapes.
      def non_positional?(arg)
        arg.is_a?(Prism::SplatNode) ||
          arg.is_a?(Prism::KeywordHashNode) ||
          arg.is_a?(Prism::BlockArgumentNode) ||
          arg.is_a?(Prism::ForwardingArgumentsNode)
      end

      def safe_type_of(scope, node)
        scope.type_of(node)
      rescue StandardError
        nil
      end
    end
  end
end
