# frozen_string_literal: true

require "prism"

require_relative "anonymous_meta_class"

module Rigor
  module Inference
    # Issue #2490 — a block, inside an instance body of a class `K`, whose `self` is provably not an instance of `K`, so
    # an `@x` write directly in it writes some other object's ivar and the class-ivar censuses must not credit it to
    # `K`. Read syntactically, before any type is known, by both the per-file census ({ScopeIndexer}) and the cross-file
    # {IvarWriterCensus}. False positives come first, so a receiver that may hold a `K` instance keeps the credit:
    #
    # - `instance_eval` / `instance_exec` on a receiver that is provably no `K` instance ({.provably_other?}): a
    #   constant or `self.class` (a class object), `X.new` / `X.allocate` on a constant `X` not spelling `K`, a
    #   literal. Any other receiver (a parameter, a local, `dup`, `itself`) may be a `K` and still counts;
    # - `class_eval` / `module_eval` / `class_exec` / `module_exec` on an explicit receiver: `self` is the receiver
    #   module, so `@x` directly in the block is that module object's own ivar;
    # - `define_method` on a constant not spelling `K` (its block runs on that class's instances), and
    #   `define_singleton_method` on a class object or a literal;
    # - a `Class.new` / `Module.new` / `Struct.new` / `Data.define` block: `self` is the new class.
    #
    # `class << obj` inside an instance body is one more barred body; the callers bar it themselves, since it is no
    # call. Only a barred body's own statements are dropped: a `define_method` block on the implicit or `self` receiver
    # nested in a `class_eval` on `self.class` or `K`, or in a `class << self` body, runs on a `K` instance and still
    # counts ({.reentry_blocks}).
    module CensusForeignBlock
      INSTANCE_EVALS = %i[instance_eval instance_exec].to_set.freeze
      MODULE_EVALS = %i[class_eval module_eval class_exec module_exec].to_set.freeze
      DEFINERS = %i[define_method define_singleton_method].to_set.freeze
      # The constructors whose receiver names the class of the object they answer.
      CONSTRUCTORS = %i[new allocate].to_set.freeze
      # The literal receivers, none of them an instance of a project class.
      LITERALS = [Prism::StringNode, Prism::InterpolatedStringNode, Prism::SymbolNode, Prism::IntegerNode,
                  Prism::FloatNode, Prism::ArrayNode, Prism::HashNode, Prism::RangeNode, Prism::RegularExpressionNode,
                  Prism::NilNode, Prism::TrueNode, Prism::FalseNode, Prism::LambdaNode].freeze
      BARRIERS = [Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode].freeze
      NONE = [].freeze
      # Every name {.foreign?} can answer true for, so any other call returns at one Set probe.
      CALLS = (INSTANCE_EVALS | MODULE_EVALS | DEFINERS | %i[new define]).freeze

      module_function

      # Whether `node`'s literal block runs with a `self` that is provably not an instance of `class_name`.
      def foreign?(node, class_name)
        unless node.is_a?(Prism::CallNode) && CALLS.include?(node.name) && node.block.is_a?(Prism::BlockNode)
          return false
        end
        return true if AnonymousMetaClass.block_form_receiver(node)

        name = node.name
        receiver = node.receiver
        return false if self_node?(receiver)
        return true if MODULE_EVALS.include?(name)
        return provably_other?(receiver, class_name) if INSTANCE_EVALS.include?(name)
        return provably_other?(receiver, class_name) if name == :define_singleton_method

        foreign_constant?(receiver, class_name)
      end

      # A receiver that is provably no instance of `class_name`: a constant or `self.class` (a class object, `K`
      # itself included), `X.new` / `X.allocate` on a constant `X` not spelling `class_name`, or a literal.
      def provably_other?(receiver, class_name)
        case receiver
        when Prism::ConstantReadNode, Prism::ConstantPathNode then true
        when Prism::CallNode
          return receiver.arguments.nil? if receiver.name == :class

          CONSTRUCTORS.include?(receiver.name) && foreign_constant?(receiver.receiver, class_name)
        else LITERALS.any? { |klass| receiver.is_a?(klass) }
        end
      end

      # A constant that does not spell `class_name`.
      def foreign_constant?(node, class_name)
        (node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)) && !own_class?(node, class_name)
      end

      # The `define_method` blocks inside barred code whose `self` is again an instance of `class_name`: a
      # `define_method` on the implicit or `self` receiver in a `class_eval`-family block on `self.class` or a
      # constant spelling `class_name`, or in a `class << self` body. Ruby runs each on a `K` instance (a `K` method,
      # or a singleton method of the instance), so its writes are `K`'s.
      def reentry_blocks(node, class_name)
        body =
          case node
          when Prism::SingletonClassNode then node.body if node.expression.is_a?(Prism::SelfNode)
          when Prism::CallNode
            node.block.body if MODULE_EVALS.include?(node.name) && own_class?(node.receiver, class_name)
          end
        return NONE if body.nil?

        found = []
        collect_define_method_blocks(body, found)
        found
      end

      def collect_define_method_blocks(node, found)
        return unless node.is_a?(Prism::Node)
        return if BARRIERS.any? { |klass| node.is_a?(klass) }

        if node.is_a?(Prism::CallNode) && node.name == :define_method && self_node?(node.receiver) &&
           node.block.is_a?(Prism::BlockNode)
          return found << node.block
        end
        return if node.is_a?(Prism::CallNode) && node.block.is_a?(Prism::BlockNode) && CALLS.include?(node.name)

        node.rigor_each_child { |child| collect_define_method_blocks(child, found) }
      end

      # `self.class`, or a constant spelling `class_name`.
      def own_class?(node, class_name)
        case node
        when Prism::CallNode
          node.name == :class && self_node?(node.receiver) && node.arguments.nil?
        when Prism::ConstantReadNode, Prism::ConstantPathNode
          spelled = node.slice.delete_prefix("::")
          spelled == class_name || spelled == class_name.split("::").last
        else
          false
        end
      end

      def self_node?(node) = node.nil? || node.is_a?(Prism::SelfNode)
    end
  end
end
