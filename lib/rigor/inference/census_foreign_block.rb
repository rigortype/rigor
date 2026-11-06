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
    # call. Only a barred body's own statements are dropped: a `define_method` block nested in a `class_eval` or
    # `class << obj` body whose module may be `K` or an instance's singleton class runs on a `K` instance and still
    # counts ({.reentry_blocks}).
    module CensusForeignBlock
      INSTANCE_EVALS = %i[instance_eval instance_exec].to_set.freeze
      MODULE_EVALS = %i[class_eval module_eval class_exec module_exec].to_set.freeze
      DEFINERS = %i[define_method define_singleton_method].to_set.freeze
      SEND_CALLS = %i[send public_send __send__].to_set.freeze
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

      # The `define_method` blocks inside barred code whose `self` may again be an instance of `class_name`: a
      # `define_method` on the implicit or `self` receiver, called directly or through `send` / `public_send` /
      # `__send__` with the literal name, in a `class_eval`-family block or a `class << obj` body whose module may be
      # `class_name` or the singleton class of one of its instances. Only a module provably not one of those bars
      # them: a `class_eval` on a constant not spelling `class_name`, and a `class << X` on a constant or a literal,
      # whose `define_method` defines methods of `X` itself. Ruby runs every other one on a `K` instance (a `K` method,
      # or a singleton method of the instance), so its writes are `K`'s; an untyped receiver keeps the credit, as
      # {.foreign?} keeps it for `instance_eval`.
      def reentry_blocks(node, class_name)
        body =
          case node
          when Prism::SingletonClassNode then node.body unless singleton_of_other?(node.expression)
          when Prism::CallNode
            node.block.body if MODULE_EVALS.include?(node.name) && !foreign_constant?(node.receiver, class_name)
          end
        return NONE if body.nil?

        found = []
        collect_define_method_blocks(body, found)
        found
      end

      # A `class << X` operand whose singleton's methods run on `X` itself, never on an instance: a constant (a class
      # object or a constant value) or a literal.
      def singleton_of_other?(expression)
        expression.is_a?(Prism::ConstantReadNode) || expression.is_a?(Prism::ConstantPathNode) ||
          LITERALS.any? { |klass| expression.is_a?(klass) }
      end

      def collect_define_method_blocks(node, found)
        return unless node.is_a?(Prism::Node)
        return if BARRIERS.any? { |klass| node.is_a?(klass) }
        return found << node.block if define_method_call?(node)
        return if node.is_a?(Prism::CallNode) && node.block.is_a?(Prism::BlockNode) && CALLS.include?(node.name)

        node.rigor_each_child { |child| collect_define_method_blocks(child, found) }
      end

      # A `define_method` with a literal block on the implicit or `self` receiver, called directly or through a `send`
      # whose first argument is the literal name.
      def define_method_call?(node)
        return false unless node.is_a?(Prism::CallNode) && self_node?(node.receiver)
        return false unless node.block.is_a?(Prism::BlockNode)
        return true if node.name == :define_method
        return false unless SEND_CALLS.include?(node.name)

        first = node.arguments&.arguments&.first
        (first.is_a?(Prism::SymbolNode) || first.is_a?(Prism::StringNode)) && first.unescaped == "define_method"
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
