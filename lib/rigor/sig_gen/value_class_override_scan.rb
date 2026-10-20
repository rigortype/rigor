# frozen_string_literal: true

require "prism"

require_relative "../source/constant_path"
require_relative "../source/literals"
require_relative "../source/node_children"

module Rigor
  module SigGen
    # The classes whose constructor arguments may not be their `Data.define` / `Struct.new` members, read over every
    # file the observation run parses (#1150, #1183). {ObservationCollector} keeps every member of such a class
    # `untyped`, because a construction site of it says nothing reliable about what a member holds:
    #
    # - the class, in any file, defines `initialize`, aliases a method to it, or `define_method`s it;
    # - the class prepends any module, or includes a project module that defines `initialize`;
    # - the class overrides `new` / `[]` (`def self.new`, `class << self; def new`, an `alias` / `alias_method` naming
    #   `new` or `[]` in its singleton class, `define_singleton_method(:new)`), or extends a project module defining
    #   `new` / `[]`;
    # - the class has a subclass (`class Sub < Base`, `Class.new(Base)`): a subclass's construction and writer sites
    #   are keyed under the subclass, so they would not reach the base's member types.
    #
    # The class body is its `class` body, a `Data.define do ... end` / `Struct.new do ... end` block, or a
    # `Const.class_eval` block; a `Const.prepend(M)` from outside counts too. A module or an override outside the
    # parsed files (a gem) is not seen.
    class ValueClassOverrideScan
      CONSTRUCTORS = %i[new []].freeze
      EVAL_BLOCKS = %i[class_eval class_exec module_eval module_exec].freeze
      private_constant :CONSTRUCTORS, :EVAL_BLOCKS

      # The qualified names of the classes to keep untyped, as a frozen Set of Strings.
      def self.overridden(roots)
        new(roots).overridden
      end

      def initialize(roots)
        @roots = roots
        @known = Set.new
        @module_defs = Hash.new { |hash, name| hash[name] = Set.new }
        @overridden = Set.new
        @value_classes = Set.new
      end

      def overridden
        # Two passes: a module or a class another file defines must be known before any body naming it is read.
        @roots.each { |root| index(root, []) }
        scan_all
        (@overridden & @value_classes).freeze
      end

      private

      def scan_all
        @roots.each { |root| scan(root, [], nil) }
      end

      # Pass 1: every class / module name, and the instance methods each module body defines.
      def index(node, prefix)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          child = Source::ConstantPath.declaration_prefix(prefix, node.constant_path)
          if child
            @known << child.join("::")
            @value_classes << child.join("::") if node.is_a?(Prism::ClassNode) && value_class_call?(node.superclass)
            collect_module_defs(node.body, child.join("::")) if node.is_a?(Prism::ModuleNode)
            index(node.body, child)
            return
          end
        when Prism::ConstantWriteNode
          @known << [*prefix, node.name.to_s].join("::")
          @value_classes << [*prefix, node.name.to_s].join("::") if value_class_call?(node.value)
        end
        node.rigor_each_child { |c| index(c, prefix) }
      end

      def value_class_call?(node)
        return false unless node.is_a?(Prism::CallNode)

        expected = { define: :Data, new: :Struct }[node.name]
        receiver = node.receiver
        expected && constant?(receiver) && Source::ConstantPath.qualified_name(receiver) == expected.to_s
      end

      def collect_module_defs(node, name)
        return unless node.is_a?(Prism::Node)
        return if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode) || node.is_a?(Prism::SingletonClassNode)

        if node.is_a?(Prism::DefNode)
          @module_defs[name] << node.name if node.receiver.nil?
          return
        end
        node.rigor_each_child { |c| collect_module_defs(c, name) }
      end

      # Pass 2. `owner` is the class whose body `node` sits in, or nil outside one.
      def scan(node, prefix, owner)
        return unless node.is_a?(Prism::Node)
        return if scan_declaration?(node, prefix, owner)

        case node
        when Prism::AliasMethodNode
          mark(owner) if owner && alias_names(node).include?(:initialize)
        when Prism::CallNode
          return if scan_call?(node, prefix, owner)
        end
        node.rigor_each_child { |c| scan(c, prefix, owner) }
      end

      # Class, module, singleton-class and `def` nodes, and a value-class constant write with a block: true when the
      # node was handled whole.
      def scan_declaration?(node, prefix, owner)
        case node
        when Prism::ClassNode then scan_class(node, prefix)
        when Prism::ModuleNode then scan_module(node, prefix)
        when Prism::ConstantWriteNode then return scan_constant_write?(node, prefix)
        when Prism::SingletonClassNode
          return false unless owner && node.expression.is_a?(Prism::SelfNode)

          scan_singleton(node.body, owner)
        when Prism::DefNode then note_def(node, owner) if owner
        else return false
        end
        true
      end

      def scan_class(node, prefix)
        child = Source::ConstantPath.declaration_prefix(prefix, node.constant_path)
        mark(resolve(node.superclass, prefix)) if constant?(node.superclass)
        scan(node.superclass, prefix, nil)
        scan(node.body, child || prefix, child&.join("::"))
      end

      def scan_module(node, prefix)
        child = Source::ConstantPath.declaration_prefix(prefix, node.constant_path)
        scan(node.body, child || prefix, nil)
      end

      # The block of `Const = Data.define(...) do ... end`, `Const = Struct.new(...) do ... end` or
      # `Const = Class.new(Base) do ... end` is `Const`'s body. True when the block was scanned.
      def scan_constant_write?(node, prefix)
        call = node.value
        return false unless call.is_a?(Prism::CallNode)

        mark_class_new_superclass(call, prefix)
        block = call.block
        return false unless block.is_a?(Prism::BlockNode)

        scan(call.receiver, prefix, nil)
        (call.arguments&.arguments || []).each { |arg| scan(arg, prefix, nil) }
        scan(block.body, prefix, [*prefix, node.name.to_s].join("::"))
        true
      end

      def class_new?(call)
        call.is_a?(Prism::CallNode) && call.name == :new && call.receiver.is_a?(Prism::ConstantReadNode) &&
          call.receiver.name == :Class
      end

      def mark_class_new_superclass(call, prefix)
        return unless class_new?(call)

        superclass = call.arguments&.arguments&.first
        mark(resolve(superclass, prefix)) if constant?(superclass)
      end

      def note_def(node, owner)
        if node.receiver.nil?
          mark(owner) if node.name == :initialize
        elsif node.receiver.is_a?(Prism::SelfNode)
          mark(owner) if CONSTRUCTORS.include?(node.name)
        end
      end

      # True when the call was fully handled (its block already scanned).
      def scan_call?(node, prefix, owner)
        receiver = node.receiver
        if receiver.nil? || receiver.is_a?(Prism::SelfNode)
          note_body_call(node, owner, prefix) if owner
          false
        elsif constant?(receiver)
          target = resolve(receiver, prefix)
          note_body_call(node, target, prefix)
          return false unless EVAL_BLOCKS.include?(node.name) && node.block.is_a?(Prism::BlockNode)

          scan(node.block.body, prefix, target)
          true
        else
          false
        end
      end

      def note_body_call(node, owner, prefix)
        args = node.arguments&.arguments || []
        first = Source::Literals.symbol_or_string(args.first)
        case node.name
        when :prepend then mark(owner)
        when :include then mark(owner) if defines_any?(args, prefix, [:initialize])
        when :extend then mark(owner) if defines_any?(args, prefix, CONSTRUCTORS)
        when :define_method, :alias_method then mark(owner) if first == :initialize
        when :define_singleton_method then mark(owner) if CONSTRUCTORS.include?(first)
        end
      end

      def scan_singleton(node, owner)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::DefNode
          mark(owner) if CONSTRUCTORS.include?(node.name)
          return
        when Prism::AliasMethodNode
          mark(owner) if alias_names(node).intersect?(CONSTRUCTORS)
        when Prism::CallNode
          note_singleton_call(node, owner)
        end
        node.rigor_each_child { |c| scan_singleton(c, owner) }
      end

      def note_singleton_call(node, owner)
        return unless node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)

        names = (node.arguments&.arguments || []).filter_map { |arg| Source::Literals.symbol_or_string(arg) }
        case node.name
        when :prepend, :include then mark(owner)
        when :alias_method, :define_method then mark(owner) if names.intersect?(CONSTRUCTORS)
        end
      end

      def alias_names(node)
        [node.new_name, node.old_name].filter_map { |name| Source::Literals.symbol_or_string(name) }
      end

      def defines_any?(args, prefix, names)
        args.any? { |arg| constant?(arg) && @module_defs.fetch(resolve(arg, prefix), Set.new).intersect?(names) }
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

      def mark(name)
        @overridden << name if name
      end
    end
  end
end
