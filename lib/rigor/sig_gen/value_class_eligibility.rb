# frozen_string_literal: true

require "prism"

require_relative "../source/constant_path"
require_relative "../source/literals"
require_relative "../source/node_children"

module Rigor
  module SigGen
    # Which `Data.define` / `Struct.new` classes `--params=observed` may type members for (#1150, #1183). An
    # allow-list: a class is eligible only when everything the parsed files (the source paths and the observed
    # roots) do with it is proven plain, so a construction site of it maps onto its members. Every other value class
    # keeps every member `untyped`, whatever spelling made it ineligible.
    #
    # Eligible means:
    #
    # 1. Every reference to the class's constant, in any spelling, is its definition (`X = Struct.new(...)`,
    #    `class X < Data.define(...)`), a reopening `class X`, a call `X.new(...)` / `X[...]` / `X.members`, a class
    #    guard (`when X`, `rescue X`, `X === v`, the argument of `is_a?` / `kind_of?` / `instance_of?`), or the
    #    namespace of a path `X::Y`. Any other reference — an alias `B = X`, an argument, a superclass, `class << X`,
    #    `def X.new`, `refine X`, any other call on `X` — may change how `X` builds its instances.
    # 2. The class body, its `Struct.new do ... end` / `Data.define do ... end` block and every reopening hold only
    #    instance `def`s of ordinary names, `attr_*` of non-member names, constants, and visibility calls.
    # 3. For a Struct, no observed file calls `send` / `__send__` / `public_send` with `:initialize`,
    #    `:initialize_copy` or a name that is not a literal: that re-runs `initialize` on an existing instance with
    #    arguments no construction site shows. A `Data` instance is frozen, so the same call raises `FrozenError`.
    class ValueClassEligibility # rubocop:disable Metrics/ClassLength
      FACTORIES = { define: :Data, new: :Struct }.freeze
      CONSTRUCTION_CALLS = %i[new [] members].freeze
      GUARD_CALLS = %i[is_a? kind_of? instance_of?].freeze
      SEND_CALLS = %i[send __send__ public_send].freeze
      REINITIALIZERS = %i[initialize initialize_copy].freeze
      FORBIDDEN_DEFS = %i[
        initialize initialize_copy initialize_dup initialize_clone new [] allocate method_missing respond_to_missing?
      ].freeze
      ATTR_CALLS = %i[attr attr_reader attr_writer attr_accessor].freeze
      VISIBILITY_CALLS = %i[private public protected private_constant public_constant].freeze
      CONSTANT_REFLECTION = %i[const_get const_set remove_const].freeze
      private_constant :FACTORIES, :CONSTRUCTION_CALLS, :GUARD_CALLS, :SEND_CALLS, :REINITIALIZERS, :FORBIDDEN_DEFS,
                       :ATTR_CALLS, :VISIBILITY_CALLS, :CONSTANT_REFLECTION

      ValueClass = Data.define(:kind, :member_names)
      private_constant :ValueClass

      # The qualified names of the value classes defined in `source_roots` + `observed_roots` that are NOT eligible.
      def self.ineligible(source_roots:, observed_roots:)
        new(source_roots, observed_roots).ineligible
      end

      def initialize(source_roots, observed_roots)
        @roots = (source_roots + observed_roots).uniq(&:object_id)
        @observed_roots = observed_roots
        @known = Set.new
        @value_classes = {}
        @ineligible = Set.new
      end

      def ineligible
        # Two passes: a class another file defines must be known before any reference to it is resolved.
        @roots.each { |root| index(root, []) }
        visit_all
        mark_structs_ineligible if @observed_roots.any? { |root| reinitializes?(root) }
        (@ineligible & @value_classes.keys.to_set).freeze
      end

      private

      def visit_all
        @roots.each { |root| visit(root, nil, [], nil) }
      end

      # Pass 1: every class / module / constant name, and the value classes with their member lists.
      def index(node, prefix)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          child = Source::ConstantPath.declaration_prefix(prefix, node.constant_path)
          if child
            name = child.join("::")
            @known << name
            record_value_class(name, node.superclass) if node.is_a?(Prism::ClassNode)
            index(node.body, child)
            return
          end
        when Prism::ConstantWriteNode
          name = [*prefix, node.name.to_s].join("::")
          @known << name
          record_value_class(name, node.value)
        end
        node.rigor_each_child { |c| index(c, prefix) }
      end

      def record_value_class(name, call)
        kind = factory_kind(call)
        return if kind.nil?

        # A class defined twice is not one layout the observations can be read against.
        @ineligible << name if @value_classes.key?(name)
        members = (call.arguments&.arguments || []).filter_map { |arg| Source::Literals.symbol(arg) }
        @value_classes[name] = ValueClass.new(kind: kind, member_names: members)
      end

      def factory_kind(call)
        return nil unless call.is_a?(Prism::CallNode)

        expected = FACTORIES[call.name]
        receiver = call.receiver
        unless expected && constant?(receiver) && Source::ConstantPath.qualified_name(receiver) == expected.to_s
          return nil
        end

        expected == :Data ? :data : :struct
      end

      # Pass 2: every node, with its parent, so each constant reference is judged by where it sits.
      def visit(node, parent, prefix, grandparent)
        return unless node.is_a?(Prism::Node)

        judge_reference(node, parent, grandparent, prefix) if constant?(node)
        judge_reflection(node) if node.is_a?(Prism::CallNode) && CONSTANT_REFLECTION.include?(node.name)
        check_body(node, prefix)
        child_prefix = prefix
        if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
          child_prefix = Source::ConstantPath.declaration_prefix(prefix, node.constant_path) || prefix
        end
        node.rigor_each_child do |child|
          visit(child, node, namespace_child?(node, child) ? child_prefix : prefix, parent)
        end
      end

      # A class / module header and superclass are read in the enclosing namespace; only the body is inside it.
      def namespace_child?(node, child)
        (node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)) && node.body.equal?(child)
      end

      def judge_reference(node, parent, grandparent, prefix)
        name = resolve(node, prefix)
        return unless @value_classes.key?(name)
        return if plain_reference?(node, parent, grandparent)

        @ineligible << name
      end

      # `Object.const_get(:X)` spells a reference as a literal; one naming a value class counts as a non-plain one.
      def judge_reflection(call)
        spelled = Source::Literals.symbol_or_string_name(call.arguments&.arguments&.first)
        return if spelled.nil?

        @value_classes.each_key do |name|
          @ineligible << name if name == spelled || name.end_with?("::#{spelled}")
        end
      end

      def plain_reference?(node, parent, grandparent)
        case parent
        when Prism::ConstantPathNode then parent.parent.equal?(node)
        when Prism::ClassNode then parent.constant_path.equal?(node) && class_header_plain?(parent)
        when Prism::CallNode then plain_call_reference?(node, parent)
        when Prism::WhenNode, Prism::RescueNode then true
        when Prism::ArgumentsNode
          grandparent.is_a?(Prism::CallNode) && GUARD_CALLS.include?(grandparent.name) &&
            parent.arguments.size == 1
        else false
        end
      end

      def class_header_plain?(class_node)
        class_node.superclass.nil? || !factory_kind(class_node.superclass).nil?
      end

      def plain_call_reference?(node, call)
        return false unless call.receiver.equal?(node)

        CONSTRUCTION_CALLS.include?(call.name) || call.name == :===
      end

      # Rule 2, on the bodies that belong to a value class.
      def check_body(node, prefix)
        case node
        when Prism::ClassNode
          name = class_name(node, prefix)
          check_statements(node.body, name) if name
          check_factory_block(node.superclass, name) if name
        when Prism::ConstantWriteNode
          name = [*prefix, node.name.to_s].join("::")
          return unless @value_classes.key?(name)

          # A write of the name that is not the factory call rebinds it.
          factory_kind(node.value) ? check_factory_block(node.value, name) : @ineligible << name
        end
      end

      def class_name(node, prefix)
        child = Source::ConstantPath.declaration_prefix(prefix, node.constant_path)
        name = child&.join("::")
        @value_classes.key?(name) ? name : nil
      end

      def check_factory_block(call, name)
        return if factory_kind(call).nil?

        block = call.block
        if block.is_a?(Prism::BlockNode)
          check_statements(block.body, name)
        elsif block
          @ineligible << name
        end
      end

      def check_statements(body, name)
        return if body.nil?
        return @ineligible << name unless body.is_a?(Prism::StatementsNode)

        members = @value_classes.fetch(name).member_names
        @ineligible << name unless body.body.all? { |statement| plain_statement?(statement, members) }
      end

      def plain_statement?(statement, members)
        case statement
        when Prism::DefNode then plain_def?(statement, members)
        when Prism::ConstantWriteNode then true
        when Prism::CallNode then plain_body_call?(statement, members)
        else false
        end
      end

      def plain_def?(node, members)
        node.receiver.nil? && !FORBIDDEN_DEFS.include?(node.name) &&
          !members.include?(node.name.to_s.delete_suffix("=").to_sym)
      end

      def plain_body_call?(call, members)
        return false unless call.receiver.nil? && call.block.nil?

        args = call.arguments&.arguments || []
        if ATTR_CALLS.include?(call.name)
          args.all? { |arg| (name = Source::Literals.symbol_or_string(arg)) && !members.include?(name) }
        elsif VISIBILITY_CALLS.include?(call.name)
          args.all? { |arg| arg.is_a?(Prism::DefNode) ? plain_def?(arg, members) : Source::Literals.symbol_or_string(arg) }
        else
          false
        end
      end

      # Rule 3: a `send` that may re-run `initialize` on an existing instance.
      def reinitializes?(node)
        return false unless node.is_a?(Prism::Node)
        return true if node.is_a?(Prism::CallNode) && reinitializing_send?(node)

        node.rigor_each_child { |child| return true if reinitializes?(child) }
        false
      end

      def reinitializing_send?(call)
        return false unless SEND_CALLS.include?(call.name)

        first = call.arguments&.arguments&.first
        return false if first.nil?

        name = Source::Literals.symbol_or_string(first)
        name.nil? || REINITIALIZERS.include?(name)
      end

      def mark_structs_ineligible
        @value_classes.each { |name, value_class| @ineligible << name if value_class.kind == :struct }
      end

      def constant?(node)
        node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)
      end

      # The lexically nearest known name `node` can mean, else its written spelling.
      def resolve(node, prefix)
        name = Source::ConstantPath.qualified_name(node)
        return name if name.nil? || Source::ConstantPath.rooted?(node)

        prefix.size.downto(0) do |depth|
          candidate = [*prefix.first(depth), name].join("::")
          return candidate if @known.include?(candidate)
        end
        name
      end
    end
  end
end
