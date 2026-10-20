# frozen_string_literal: true

require "prism"

require_relative "../environment"
require_relative "../project_environment"
require_relative "../scope"
require_relative "../type"
require_relative "../source/constant_path"
require_relative "../source/literals"
require_relative "../source/node_children"
require_relative "../inference/scope_indexer"
require_relative "../rooted_glob"

module Rigor
  module SigGen
    # ADR-14 slice 3 — caller-side argument-type observation collector.
    #
    # Walks the `--observe=PATH...` tree (default: the project's test roots), parses every `.rb` file with `Prism`,
    # scope- indexes it the same way the main generator does, and records the per-call-site argument-type tuples
    # for every `Prism::CallNode` whose receiver types as a `Type::Nominal`. The {Generator} consumes the
    # resulting map to render `--params=observed` RBS:
    #
    # @return => Array<Array<Rigor::Type>>}]
    #
    # ADR-5 clause 2 compliance: the observed union is the MOST PERMISSIVE parameter contract the existing
    # callers prove sufficient — by construction it accepts every type any caller has already passed. The
    # collector only surfaces the data; the default `--params=untyped` keeps the observation inert until the
    # user opts in.
    #
    # MVP scope:
    # - Explicit-receiver calls only (`foo.bar(args)`). Implicit-self calls inside class bodies and RSpec-style
    #   `let` / `subject` bindings ride on slice 5's optional `rigor-rspec` integration.
    # - Calls whose receiver does not type as a `Type::Nominal` (e.g. `(some_dynamic).bar(...)`) are skipped —
    #   the collector cannot attribute them to a specific class.
    # - A `T | nil` receiver with one `Nominal` / `Singleton` non-nil member counts as that member (#1389).
    # - Zero-argument calls give no observation; methods are matched by `(class_name, method_name)` only.
    class ObservationCollector # rubocop:disable Metrics/ClassLength
      # The key a `Foo[...]` call is observed under. On a `Data.define` / `Struct.new` class `.[]` is `.new`
      # (#1150, #1183), and {MetaMemberObservation} reads it as a construction; on any other class nothing reads
      # it. Not an instance method name, so no `def` of the class can collide with it.
      BRACKET_NEW = :"self.[]"

      # @param paths — observe paths (files /
      #   directories).
      # @param source_paths — source-tree paths
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

        resolved = resolve_paths(@paths)
        environment = build_environment(resolved)
        discovered_classes = preindex_source_classes
        observations = Hash.new { |h, k| h[k] = [] }
        resolved.each do |path|
          collect_from_file(path, environment, discovered_classes, observations)
        end
        observations.transform_values(&:freeze).freeze
      end

      # Whether `arg` names something {#collect} reads: a directory, or a `.rb` file. The CLI's
      # `observation` report splits roots on this, so "observed" means what the collector does (#1398).
      def self.readable_root?(arg)
        File.directory?(arg) || (File.file?(arg) && arg.end_with?(".rb"))
      end

      private

      # Issue #821 — same universe as the generator and as `rigor check`; see
      # {Generator#build_environment}. An observation collected against a narrower environment types its
      # argument differently from the run that will consume it.
      def build_environment(source_files = [])
        ProjectEnvironment.build(configuration: @configuration, source_files: source_files)
      end

      def resolve_paths(args)
        args.flat_map do |arg|
          if File.directory?(arg)
            RootedGlob.glob(arg, "**/*.rb")
          elsif self.class.readable_root?(arg)
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

        base_scope = Scope.empty(environment: environment)
        base_scope = base_scope.with_discovery(base_scope.discovery.with(discovered_classes: discovered_classes))
        scope_index = Inference::ScopeIndexer.index(parse_result.value, default_scope: base_scope)
        bindings = collect_rspec_bindings(parse_result.value, scope_index)
        @before_ivars = collect_before_ivars(parse_result.value, scope_index)

        walk_calls(parse_result.value, scope_index, bindings, observations, [])
      end

      # Pre-walks `@source_paths` to collect every qualified class / module declaration. The result seeds the
      # `discovered_classes` table on each observe-tree scope so `Foo.new` and `Foo` resolve to the right
      # singleton carrier even when no RBS sig describes `Foo` yet.
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
        # Source-side harvest failures are tolerated silently — the collector still runs on whichever files
        # parsed cleanly.
      end

      def walk_class_decls(node, prefix, accumulator)
        return unless node.is_a?(Prism::Node)

        if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
          child_prefix = Source::ConstantPath.declaration_prefix(prefix, node.constant_path)
          if child_prefix
            full = child_prefix.join("::")
            accumulator[full] = Type::Combinator.singleton_of(full)
            walk_class_decls(node.body, child_prefix, accumulator) if node.body
            return
          end
        end
        register_value_class(node, prefix, accumulator)

        node.rigor_each_child { |child| walk_class_decls(child, prefix, accumulator) }
      end

      # `P = Data.define(...)` / `S = Struct.new(...)` declares a class with no `class` keyword, so a construction
      # site in another file (`P.new(name: "a")` in a spec) would read `P` as an unknown constant and observe
      # nothing (#1150, #1183). Registering it here is observation only: the analyser's own view of `P` is
      # untouched.
      def register_value_class(node, prefix, accumulator)
        return unless node.is_a?(Prism::ConstantWriteNode) && value_class_call?(node.value)

        full = [*prefix, node.name.to_s].join("::")
        accumulator[full] ||= Type::Combinator.singleton_of(full)
      end

      def value_class_call?(node)
        return false unless node.is_a?(Prism::CallNode)

        expected = { define: :Data, new: :Struct }[node.name]
        receiver = node.receiver
        case receiver
        when Prism::ConstantReadNode then receiver.name == expected
        when Prism::ConstantPathNode then receiver.parent.nil? && receiver.name == expected
        else false
        end
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

      # `blocks` is the chain of enclosing RSpec group / example / hook blocks, innermost last — the blocks a
      # `before` ivar can reach the call from ({#before_ivar_type}). See {#enclosing_blocks} for where it is cut.
      def walk_calls(node, scope_index, bindings, observations, blocks)
        return unless node.is_a?(Prism::Node)

        record_call(node, scope_index, bindings, observations, blocks) if node.is_a?(Prism::CallNode)
        node.rigor_each_child do |child|
          walk_calls(child, scope_index, bindings, observations, enclosing_blocks(node, child, blocks))
        end
      end

      # Group, example and hook calls whose block runs with the example's ivars. `RSpec.` may prefix a group call.
      RSPEC_GROUP_CALLS = %i[
        describe context feature shared_examples shared_examples_for shared_context
      ].freeze
      RSPEC_EXAMPLE_OR_HOOK_CALLS = %i[
        it specify example scenario its before prepend_before append_before
      ].freeze
      private_constant :RSPEC_GROUP_CALLS, :RSPEC_EXAMPLE_OR_HOOK_CALLS

      # The chain `child` of `parent` sees. A group / example / hook call's block extends it; every other block or
      # lambda (`Class.new { … }`, `instance_eval { … }`, `define_method(:m) { … }`, `each { … }`), a class / module /
      # singleton-class body, and a `def` that is not a direct statement of a group block cut it, since their `self`
      # may be another object.
      def enclosing_blocks(parent, child, blocks)
        case child
        when Prism::BlockNode then rspec_scope_call?(parent) ? [*blocks, child] : []
        when Prism::LambdaNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode then []
        when Prism::DefNode then group_statement?(child, blocks.last) ? blocks : []
        else blocks
        end
      end

      def rspec_scope_call?(node)
        return false unless node.is_a?(Prism::CallNode)
        return rspec_group_receiver?(node.receiver) if RSPEC_GROUP_CALLS.include?(node.name)

        node.receiver.nil? && RSPEC_EXAMPLE_OR_HOOK_CALLS.include?(node.name)
      end

      def rspec_group_receiver?(receiver)
        receiver.nil? || (receiver.is_a?(Prism::ConstantReadNode) && receiver.name == :RSpec)
      end

      def group_statement?(node, block)
        body = block&.body
        body.is_a?(Prism::StatementsNode) && body.body.any? { |statement| statement.equal?(node) }
      end

      def record_call(call_node, scope_index, bindings, observations, blocks)
        receiver = call_node.receiver
        return if receiver.nil?

        scope = scope_index[call_node] || scope_index[receiver]
        return if scope.nil?

        receiver_type = resolve_receiver_type(receiver, scope, bindings, blocks)
        key = observation_key(call_node, observed_receiver(receiver_type, call_node, scope))
        return if key.nil?

        observation = collect_args(call_node, scope)
        return if observation.nil? || observation.empty?

        observations[key] << observation
      end

      # ADR-14 follow-up (A): `.new` → `:initialize` routing. `MethodCatalog.new(path: ...)` types its receiver
      # as `Type::Singleton[MethodCatalog]` and its call name as `:new`, but the *implicit* effect at runtime is
      # a call to `MethodCatalog#initialize(path: ...)`. Route the observation under `[class_name, :initialize]`
      # so the initialize-stub renderer can consult it.
      def observation_key(call_node, receiver_type)
        if receiver_type.is_a?(Type::Singleton) && call_node.name == :new
          [receiver_type.class_name, :initialize]
        elsif receiver_type.is_a?(Type::Singleton) && call_node.name == :[]
          [receiver_type.class_name, BRACKET_NEW]
        elsif receiver_type.is_a?(Type::Nominal)
          [receiver_type.class_name, call_node.name]
        end
      end

      # Issue #1389 — a receiver typed `T | nil` whose one non-nil member is a `Nominal` or `Singleton` is observed as
      # that member. A Minitest `setup` ivar read in a test method types as `Foo?` (setup is not `initialize`), and a
      # call of a method `nil` does not answer can only have reached `Foo#bar` with its arguments: on `nil` it raises
      # `NoMethodError`, and `&.` skips the call. A method `NilClass`'s RBS declares (`==`, `respond_to?`, `is_a?`)
      # may have run on `nil` instead, so a plain `.` call of one keeps the union unobserved. The sole member still
      # has to pass {#observation_key}'s `Nominal` / `Singleton` checks, so `untyped | nil` stays unobserved, and a
      # union with two non-nil members (`Foo | Bar | nil`) passes through unchanged. Observation only: the
      # receiver's inferred type elsewhere is untouched.
      def observed_receiver(receiver_type, call_node, scope)
        return receiver_type unless receiver_type.is_a?(Type::Union)

        non_nil = receiver_type.members.reject { |member| nil_type?(member) }
        return receiver_type unless non_nil.size == 1
        return receiver_type if !call_node.safe_navigation? && nil_answers?(call_node.name, scope)

        non_nil.first
      end

      # Whether `nil` may answer `method_name`: `NilClass`'s RBS declares it, or that RBS is not available to ask.
      def nil_answers?(method_name, scope)
        loader = scope.environment.rbs_loader
        return true if loader.nil? || loader.instance_definition("NilClass").nil?

        !loader.instance_method(class_name: "NilClass", method_name: method_name).nil?
      end

      def nil_type?(type)
        (type.is_a?(Type::Constant) && type.value.nil?) || (type.is_a?(Type::Nominal) && type.class_name == "NilClass")
      end

      # ADR-14 slice 5 — RSpec-aware receiver typing. Resolves a CallNode receiver against the collected
      # `bindings` map (built by {#collect_rspec_bindings}) before falling back to ordinary `scope.type_of`. The
      # three RSpec-shaped receivers we recognise:
      #
      # - Bare-name CallNode (`subject`, `other`, ...) whose name matches a `subject` / `let(:name)` binding —
      #   return the binding's recorded type.
      # - `described_class.new(...)` chain — when the surrounding `describe Foo do … end` resolved `Foo`,
      #   return `Type::Nominal[Foo]`.
      # - Anything else — pass through to `scope.type_of`, matching slice-3 behaviour.
      def resolve_receiver_type(receiver, scope, bindings, blocks)
        return resolve_described_class_new(bindings) if described_class_new?(receiver)
        return bindings[receiver.name] if bound_call?(receiver, bindings)

        type = safe_type_of(scope, receiver)
        return type unless receiver.is_a?(Prism::InstanceVariableReadNode) && (type.nil? || type.is_a?(Type::Dynamic))

        before_ivar_type(receiver.name, blocks) || type
      end

      # Issue #1389 — an ivar read inside an `it` block types as `Dynamic` (the block's ivars are not a class's), so
      # a `before { @foo = Foo.new }` write stands in for it. Only a `before` whose example-group block encloses the
      # read counts — a sibling `describe`, an un-included `shared_context` or a class body never reaches it — and
      # when those `before`s write the name with more than one type, no type is answered.
      def before_ivar_type(name, blocks)
        types = blocks.flat_map { |block| @before_ivars.dig(block, name) || [] }.uniq
        types.size == 1 ? types.first : nil
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

      # Walks the spec file for `describe X do … end` / `RSpec.describe X do … end` blocks plus the
      # `subject` / `let(:name)` declarations inside them. Returns a flat map `{ binding_name (Symbol) => Type }`
      # plus a synthetic `:described_class` slot keyed off the nearest enclosing `describe`.
      #
      # The recogniser is intentionally lightweight: it does not enforce RSpec scope rules across `describe` /
      # `context` blocks. Nested `describe` declarations overwrite the outer `described_class` for the
      # remainder of the walk; same-name `let` bindings are last-wins. This matches the typical one-spec-file
      # shape ADR-14 slice 5 targets without re-implementing the `rigor-rspec` plugin's full scope analyser.
      def collect_rspec_bindings(root, scope_index)
        bindings = {}
        walk_rspec_bindings(root, bindings, scope_index)
        bindings
      end

      def walk_rspec_bindings(node, bindings, scope_index)
        return unless node.is_a?(Prism::Node)

        recognise_describe(node, bindings)
        recognise_subject_or_let(node, bindings, scope_index)

        node.rigor_each_child { |child| walk_rspec_bindings(child, bindings, scope_index) }
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

      # `before { @foo = Foo.new }` / `before(:each) do … end` inside an example-group block: records each ivar the
      # `before` block's top-level statements write, with the written value's type, under that enclosing group
      # block — `{ BlockNode => { :@foo => [Type] } }`, keyed by node identity. A `before` outside every group
      # block ({#enclosing_blocks}), and `config.before`, record nothing.
      def collect_before_ivars(root, scope_index)
        index = {}.compare_by_identity
        walk_before_ivars(root, [], index, scope_index)
        index
      end

      def walk_before_ivars(node, blocks, index, scope_index)
        return unless node.is_a?(Prism::Node)

        record_before_ivars(node, blocks.last, index, scope_index) if blocks.last
        node.rigor_each_child do |child|
          walk_before_ivars(child, enclosing_blocks(node, child, blocks), index, scope_index)
        end
      end

      def record_before_ivars(node, group, index, scope_index)
        return unless node.is_a?(Prism::CallNode) && node.name == :before && node.receiver.nil?

        body = block_body_node(node.block)
        statements = body.is_a?(Prism::StatementsNode) ? body.body : [body].compact
        statements.each do |statement|
          next unless statement.is_a?(Prism::InstanceVariableWriteNode)

          scope = scope_index[statement.value] || scope_index[statement]
          type = scope && safe_type_of(scope, statement.value)
          ((index[group] ||= {})[statement.name] ||= []) << type if type
        end
      end

      def binding_name_for(call_node)
        first_arg = call_node.arguments&.arguments&.first
        return call_node.name == :subject ? :subject : nil if first_arg.nil?

        Source::Literals.symbol_or_string(first_arg)
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

      # ADR-14 follow-up (B): walks a call's argument list separating positional from keyword arguments and
      # returning an {ObservedCall} carrier. Splat / forwarded / block arguments still abort the observation
      # (`nil`) — those don't map cleanly to a single per-position type the renderer can union.
      def collect_args(call_node, scope)
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
