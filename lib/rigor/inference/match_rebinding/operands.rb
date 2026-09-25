# frozen_string_literal: true

require "prism"

require_relative "../../source/node_children"
require_relative "../../type"

module Rigor
  module Inference
    module MatchRebinding
      # Whether an operand of a call, a `when` condition or a pattern is a Regexp — the one question that decides
      # whether `===`, `case` and the lookup names run a match. Two readings, because the constructs differ in
      # what they usually hold:
      #
      # - a `when` condition, a pattern value and a `===` receiver are patterns far more often than not, so
      #   anything but a value known not to be a Regexp counts ({.pattern_value?}, {.pattern_matches?});
      # - a `[]` / `split` / `index` argument is a lookup key far more often than not, so only a value known to be
      #   a Regexp counts ({.regexp_argument?}).
      #
      # A constant resolves through the scope. One that does not resolve is read as a class, the usual CamelCase
      # referent, so it does not count either way — except under the `broad` reading, where it may be a Regexp
      # defined in another file (#1373) and counts ({MatchRebinding.broad_may_match?}).
      #
      # Outside a block, a statement's operands are read on two further terms (issue #1365), because the flow scope
      # types them but its types can be stale (#1380): a call the name table forgot on before keeps the narrowing only
      # on a non-Regexp literal ({.keep_literal?}), and a call in a position that never forgot forgets only on an
      # operand known to be a Regexp ({.known_regexp_operand?}).
      module Operands
        REGEX_LITERALS = Set[Prism::RegularExpressionNode, Prism::InterpolatedRegularExpressionNode].freeze
        # Values whose `===` cannot run a match. An interpolated String or Symbol is still a String or Symbol; the
        # code it embeds is scanned like any other.
        NON_REGEXP_LITERALS = Set[
          Prism::SymbolNode, Prism::InterpolatedSymbolNode, Prism::StringNode, Prism::InterpolatedStringNode,
          Prism::IntegerNode, Prism::FloatNode, Prism::RationalNode, Prism::ImaginaryNode,
          Prism::NilNode, Prism::TrueNode, Prism::FalseNode
        ].freeze
        # The literals {.keep_literal?} accepts: each is never a Regexp, whatever a flow type says.
        KEEP_LITERALS = Set[
          Prism::SymbolNode, Prism::StringNode, Prism::IntegerNode, Prism::FloatNode, Prism::RationalNode,
          Prism::ImaginaryNode, Prism::NilNode, Prism::TrueNode, Prism::FalseNode
        ].freeze
        CONSTANT_NODES = Set[Prism::ConstantReadNode, Prism::ConstantPathNode].freeze
        PINNED_NODES = Set[Prism::PinnedVariableNode, Prism::PinnedExpressionNode].freeze
        REGEXP_CONSTRUCTORS = Set[:new, :union, :compile].freeze
        # The classes a Regexp is an instance of, so a value of one of these types may be a Regexp.
        REGEXP_ANCESTORS = Set["Regexp", "Object", "BasicObject", "Kernel"].freeze
        # How a class relates to `Regexp` when every instance of it is one.
        REGEXP_CLASS_ORDERINGS = Set[:subclass, :equal].freeze
        private_constant :REGEX_LITERALS, :NON_REGEXP_LITERALS, :KEEP_LITERALS, :CONSTANT_NODES, :PINNED_NODES,
                         :REGEXP_CONSTRUCTORS, :REGEXP_ANCESTORS, :REGEXP_CLASS_ORDERINGS

        module_function

        # True when a statement's operand is never a Regexp by its syntax alone: a Symbol, a String without
        # interpolation, a number, `nil`, `true`, `false`, or a range of those. A call the name table forgot on before
        # issue #1365 (`row[:name]`, `csv.split(",")`, `list.index(3)`) keeps the narrowing only when every argument is
        # one, because a flow type that says "String" can be stale while the value is a Regexp (#1380).
        def keep_literal?(node)
          return true if KEEP_LITERALS.include?(node.class)
          return false unless node.is_a?(Prism::RangeNode)

          [node.left, node.right].all? { |bound| bound.nil? || KEEP_LITERALS.include?(bound.class) }
        end

        # True when `node` is a constant naming a class or module (`String === s`), whose `===` is `Module#===`.
        def class_constant?(node, scope)
          CONSTANT_NODES.include?(node.class) && node_type(node, scope).is_a?(Type::Singleton)
        end

        # True when a statement's operand is known to be a Regexp: a regex literal, `Regexp.new` / `.union` /
        # `.compile`, a splat whose elements are known to be ones, or a value whose type in the flow scope is one
        # ({.regexp_type?}). `Dynamic[top]`, `Object` and any other type are not: a position that never forgot before
        # issue #1365 forgets only on evidence, so an argument that is a Regexp without the analyzer knowing it is a
        # gap there, as it was before.
        def known_regexp_operand?(node, scope)
          return true if REGEX_LITERALS.include?(node.class) || regexp_constructor?(node)
          return splat_known_regexp?(node.expression, scope) if node.is_a?(Prism::SplatNode)
          return false if NON_REGEXP_LITERALS.include?(node.class)

          regexp_type?(node_type(node, scope), scope)
        end

        # `*args` passes each element; an anonymous `*` forwards elements nothing is known about.
        def splat_known_regexp?(expression, scope)
          return false if expression.nil?

          type = node_type(expression, scope)
          case type
          when Type::Tuple then type.elements.any? { |element| regexp_type?(element, scope) }
          when Type::Nominal
            type.class_name == "Array" ? type.type_args.any? { |element| regexp_type?(element, scope) } : false
          else false
          end
        end
        private_class_method :splat_known_regexp?

        # True when a value of `type` may be a Regexp on the analyzer's evidence: a Regexp constant, `Regexp` or a
        # class the environment places below it, a union or intersection with such a member, a refinement or
        # difference over one, or a `Dynamic` whose static facet is one.
        def regexp_type?(type, scope)
          case type
          when Type::Constant then type.value.is_a?(Regexp)
          when Type::Nominal then regexp_class?(type.class_name, scope)
          when Type::Union, Type::Intersection then type.members.any? { |member| regexp_type?(member, scope) }
          when Type::Dynamic then regexp_type?(type.static_facet, scope)
          when Type::Difference, Type::Refined then regexp_type?(type.base, scope)
          else false
          end
        end
        private_class_method :regexp_type?

        def regexp_class?(class_name, scope)
          return true if class_name == "Regexp"

          environment = scope&.environment
          !environment.nil? && REGEXP_CLASS_ORDERINGS.include?(environment.class_ordering(class_name, "Regexp"))
        end
        private_class_method :regexp_class?

        def regexp_constructor?(node)
          node.is_a?(Prism::CallNode) && REGEXP_CONSTRUCTORS.include?(node.name) &&
            node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name == :Regexp
        end
        private_class_method :regexp_constructor?

        def node_type(node, scope)
          scope&.type_of(node)
        rescue StandardError
          nil
        end
        private_class_method :node_type

        # True when a `===` receiver or a `when` condition may be a Regexp: a regex literal, a constant bound to
        # one, a splat of a constant holding one, or any other expression (`when re`), but not a literal that is
        # not one. `broad` counts an unresolved constant too.
        def pattern_value?(node, scope, broad: false)
          klass = node.class
          return true if REGEX_LITERALS.include?(klass)
          return false if non_regexp_literal?(node)
          return constant_may_be_regexp?(node_type(node, scope), broad) if CONSTANT_NODES.include?(klass)
          return splat_regexp?(node, scope, broad) if node.is_a?(Prism::SplatNode)

          true
        end

        # True when an `in` / `=>` pattern holds a value that may be a Regexp: a regex literal, a pinned variable
        # or expression, or a constant bound to one. Its structure, captures and other literals run no match, and
        # an `if` / `unless` guard is ordinary code, scanned with the rest of the body. `broad` counts an unresolved
        # constant too.
        def pattern_matches?(node, scope, broad: false)
          return false if node.nil?

          klass = node.class
          return true if REGEX_LITERALS.include?(klass) || PINNED_NODES.include?(klass)
          return constant_may_be_regexp?(node_type(node, scope), broad) if CONSTANT_NODES.include?(klass)
          if node.is_a?(Prism::IfNode) || node.is_a?(Prism::UnlessNode)
            return pattern_matches?(node.statements, scope, broad: broad)
          end

          found = false
          node.rigor_each_child { |child| found ||= pattern_matches?(child, scope, broad: broad) }
          found
        end

        # True when an argument is known to be a Regexp: a regex literal, a constant bound to one, a local or
        # instance variable bound to one where the block is written, or `Regexp.new` / `.union` / `.compile`. A
        # block parameter is bound only inside the block, so `row[f]` does not count.
        def regexp_argument?(node, scope)
          case node
          when Prism::RegularExpressionNode, Prism::InterpolatedRegularExpressionNode then true
          when Prism::ConstantReadNode, Prism::ConstantPathNode then regexp_type?(node_type(node, scope), scope)
          when Prism::LocalVariableReadNode then regexp_type?(scope&.local(node.name), scope)
          when Prism::InstanceVariableReadNode then regexp_type?(scope&.ivar(node.name), scope)
          when Prism::CallNode then regexp_constructor?(node)
          else false
          end
        end

        # `when *KEYS` runs `===` on each element of `KEYS`; a splat of anything but a constant counts.
        def splat_regexp?(splat, scope, broad)
          expression = splat.expression
          return true unless CONSTANT_NODES.include?(expression.class)

          type = node_type(expression, scope)
          (broad && unresolved?(type)) || elements_regexp?(type)
        end
        private_class_method :splat_regexp?

        def elements_regexp?(type)
          case type
          when Type::Tuple then type.elements.any? { |element| constant_regexp?(element) }
          when Type::Nominal then type.type_args.any? { |argument| constant_regexp?(argument) }
          when Type::Constant then type.value.is_a?(Array) && type.value.any?(Regexp)
          when Type::Union then type.members.any? { |member| elements_regexp?(member) }
          else false
          end
        end
        private_class_method :elements_regexp?

        def non_regexp_literal?(node)
          return true if NON_REGEXP_LITERALS.include?(node.class)
          return false unless node.is_a?(Prism::RangeNode)

          [node.left, node.right].all? { |bound| bound.nil? || non_regexp_literal?(bound) }
        end
        private_class_method :non_regexp_literal?

        def constant_may_be_regexp?(type, broad)
          constant_regexp?(type) || (broad && unresolved?(type))
        end
        private_class_method :constant_may_be_regexp?

        # A constant that does not resolve reads as `Dynamic`, or as nil without a scope.
        def unresolved?(type)
          case type
          when nil, Type::Dynamic then true
          when Type::Union then type.members.any? { |member| unresolved?(member) }
          else false
          end
        end
        private_class_method :unresolved?

        # True when a constant's type may be a Regexp. A class or module, a Tuple or HashShape, any other value,
        # and a constant that does not resolve do not.
        def constant_regexp?(type)
          case type
          when Type::Constant then type.value.is_a?(Regexp)
          when Type::Nominal then REGEXP_ANCESTORS.include?(type.class_name)
          when Type::Union then type.members.any? { |member| constant_regexp?(member) }
          else false
          end
        end
        private_class_method :constant_regexp?
      end
    end
  end
end
