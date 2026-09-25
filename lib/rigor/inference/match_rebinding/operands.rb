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
      # Outside a block, the flow scope types the operand a statement runs, so the statement-level rule reads it by
      # its type instead ({.typed_regexp?}, issue #1365).
      module Operands
        REGEX_LITERALS = Set[Prism::RegularExpressionNode, Prism::InterpolatedRegularExpressionNode].freeze
        # Values whose `===` cannot run a match. An interpolated String or Symbol is still a String or Symbol; the
        # code it embeds is scanned like any other.
        NON_REGEXP_LITERALS = Set[
          Prism::SymbolNode, Prism::InterpolatedSymbolNode, Prism::StringNode, Prism::InterpolatedStringNode,
          Prism::IntegerNode, Prism::FloatNode, Prism::RationalNode, Prism::ImaginaryNode,
          Prism::NilNode, Prism::TrueNode, Prism::FalseNode
        ].freeze
        # Literals {.typed_regexp?} answers without typing them: none of them builds a Regexp.
        NON_REGEXP_VALUES = Set[
          Prism::ArrayNode, Prism::HashNode, Prism::KeywordHashNode, Prism::RangeNode, Prism::LambdaNode,
          Prism::XStringNode, Prism::InterpolatedXStringNode
        ].freeze
        CONSTANT_NODES = Set[Prism::ConstantReadNode, Prism::ConstantPathNode].freeze
        PINNED_NODES = Set[Prism::PinnedVariableNode, Prism::PinnedExpressionNode].freeze
        REGEXP_CONSTRUCTORS = Set[:new, :union, :compile].freeze
        # The classes a Regexp is an instance of, so a value of one of these types may be a Regexp.
        REGEXP_ANCESTORS = Set["Regexp", "Object", "BasicObject", "Kernel"].freeze
        # How a class relates to `Regexp` when its instances may be one: a subclass, `Regexp` itself, or an ancestor.
        REGEXP_ORDERINGS = Set[:subclass, :equal, :superclass].freeze
        private_constant :REGEX_LITERALS, :NON_REGEXP_LITERALS, :NON_REGEXP_VALUES, :CONSTANT_NODES, :PINNED_NODES,
                         :REGEXP_CONSTRUCTORS, :REGEXP_ANCESTORS, :REGEXP_ORDERINGS

        module_function

        # True when an operand a statement runs may be a Regexp, read by its type in the flow scope: a regex
        # literal, a forwarded `...`, a splat whose elements may be one, or a value whose type admits one — `Regexp`
        # or a subclass, an ancestor such as `Object`, `top`, an interface, a union holding one, or `Dynamic[top]`,
        # which nothing is known about (an unannotated parameter, an unresolved constant). A literal that is not a
        # Regexp, and any other type, do not: a `Symbol`, `String`, `Integer`, `Array` or `Hash`, a class, a tuple
        # or hash shape. A `Dynamic` value with a static facet is read by its facet.
        def typed_regexp?(node, scope)
          klass = node.class
          return true if REGEX_LITERALS.include?(klass) || klass == Prism::ForwardingArgumentsNode
          return false if NON_REGEXP_LITERALS.include?(klass) || NON_REGEXP_VALUES.include?(klass)
          return splat_typed_regexp?(node.expression, scope) if node.is_a?(Prism::SplatNode)

          type_may_be_regexp?(node_type(node, scope), scope)
        end

        # `*args` passes each element; an anonymous `*` forwards the method's own, which may be anything.
        def splat_typed_regexp?(expression, scope)
          return true if expression.nil?

          type = node_type(expression, scope)
          case type
          when Type::Tuple then type.elements.any? { |element| type_may_be_regexp?(element, scope) }
          when Type::Nominal
            arguments = type.type_args
            return type_may_be_regexp?(type, scope) unless type.class_name == "Array" && !arguments.empty?

            arguments.any? { |element| type_may_be_regexp?(element, scope) }
          else type_may_be_regexp?(type, scope)
          end
        end
        private_class_method :splat_typed_regexp?

        def type_may_be_regexp?(type, scope)
          case type
          when nil, Type::Top, Type::App then true
          when Type::Dynamic then type_may_be_regexp?(type.static_facet, scope)
          when Type::Constant then type.value.is_a?(Regexp)
          when Type::Nominal then nominal_may_be_regexp?(type.class_name, scope)
          when Type::Union then type.members.any? { |member| type_may_be_regexp?(member, scope) }
          when Type::Intersection then type.members.all? { |member| type_may_be_regexp?(member, scope) }
          when Type::Difference, Type::Refined then type_may_be_regexp?(type.base, scope)
          else false
          end
        end
        private_class_method :type_may_be_regexp?

        # A class the environment does not relate to `Regexp` is taken to be a project class, not a Regexp subclass.
        def nominal_may_be_regexp?(class_name, scope)
          return true if REGEXP_ANCESTORS.include?(class_name) || class_name.start_with?("_")

          environment = scope&.environment
          environment.nil? || REGEXP_ORDERINGS.include?(environment.class_ordering(class_name, "Regexp"))
        end
        private_class_method :nominal_may_be_regexp?

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
          when Prism::ConstantReadNode, Prism::ConstantPathNode then known_regexp?(node_type(node, scope))
          when Prism::LocalVariableReadNode then known_regexp?(scope&.local(node.name))
          when Prism::InstanceVariableReadNode then known_regexp?(scope&.ivar(node.name))
          when Prism::CallNode
            REGEXP_CONSTRUCTORS.include?(node.name) && node.receiver.is_a?(Prism::ConstantReadNode) &&
              node.receiver.name == :Regexp
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

        def known_regexp?(type)
          case type
          when Type::Constant then type.value.is_a?(Regexp)
          when Type::Nominal then type.class_name == "Regexp"
          when Type::Union then type.members.any? { |member| known_regexp?(member) }
          else false
          end
        end
        private_class_method :known_regexp?
      end
    end
  end
end
