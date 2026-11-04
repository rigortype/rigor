# frozen_string_literal: true

require "prism"

require_relative "../../type"
require_relative "../../typing_state"
require_relative "argument_nodes"

module Rigor
  module Inference
    module MethodDispatcher
      # ADR-130 WD3 — the overload-shape rule for a call on a `Rigor::Plugin` interface value. The argument rules
      # never check a call on a `Dynamic` receiver, so nothing else would notice a call no overload of the member
      # takes; without this rule dispatch took whichever overload the selector's fallback picked, and that
      # overload's return made the next call wrong (`xs.each.with_index` read the block overload's
      # `Array[Integer]`). A call resolves only through the overloads that take its shape:
      #
      # - a block when the call passes one, and no required block when it does not;
      # - the positional count, within required plus optional unless the overload has a rest parameter;
      # - no required keyword the call omits.
      #
      # A shape the AST cannot state, a splat (`*xs`), a keyword splat (`**opts`) or a forwarded `...`, is taken
      # by no overload, so the call reads `untyped` as it does on master.
      module InterfaceShape
        # ADR-130 WD5 — the dispatch-off flag {.without_dispatch} installs (`RbsDispatch.without_interface_dispatch`).
        DISPATCH_OFF = TypingState.frame(
          :interface_dispatch_off, reason: "a flag installed around a dispatch-off run (sig-gen, the parity harness)"
        )
        private_constant :DISPATCH_OFF

        module_function

        # Runs the block with interface dispatch switched off.
        def without_dispatch(&) = TypingState.current.with(DISPATCH_OFF, true, &)

        # False inside {.without_dispatch}.
        def dispatch? = TypingState.current[DISPATCH_OFF] != true

        # `definition` narrowed to the overloads that take the call's shape (the definition itself when every
        # overload does), or nil when none does.
        #
        # Nil too when more than one overload takes the shape and one of them has a parameter that mentions `self`
        # (`(self other)`, `(Array[self] others)`): which of them the call reaches depends on whether an argument is
        # the receiver's kind, and the interface names no class acceptance could decide that against. Read as a
        # precise overload, `x.same(1)` against `(self) -> Integer | (Integer) -> String` answered the first one's
        # `Integer`; the call reads `untyped` instead.
        def accepting(definition, args, block:, call_node:)
          shape = call_shape(args, call_node)
          return nil if shape.nil?

          positional, keywords = shape
          defs = definition.defs.select { |type_def| takes?(type_def.type, positional, keywords, block) }
          return nil if defs.empty?
          return nil if defs.size > 1 && defs.any? { |type_def| self_parameter?(type_def.type.type) }

          defs.size == definition.defs.size ? definition : definition.update(defs: defs)
        end

        # True when a parameter type of `function` mentions RBS `self`, at any depth.
        def self_parameter?(function)
          return false unless function.respond_to?(:required_positionals)

          params = function.required_positionals + function.optional_positionals + function.trailing_positionals +
                   function.required_keywords.values + function.optional_keywords.values
          params << function.rest_positionals if function.rest_positionals
          params << function.rest_keywords if function.rest_keywords
          params.any? { |param| mentions_self?(param.type) }
        end

        def mentions_self?(rbs_type)
          return true if rbs_type.is_a?(RBS::Types::Bases::Self)

          rbs_type.each_type { |inner| return true if mentions_self?(inner) }
          false
        end

        # True when the call's block is a block-pass whose value may be nil at runtime, so the call may run
        # block-less: `&blk` unless `blk` is provably not nil ({.never_nil?}), and an anonymous `&`, which forwards
        # the enclosing method's own block. `&:sym` is never nil.
        def nilable_block_pass?(call_node, scope)
          block = call_node.respond_to?(:block) ? call_node.block : nil
          return false unless block.is_a?(Prism::BlockArgumentNode)

          expression = block.expression
          return true if expression.nil?
          return false if expression.is_a?(Prism::SymbolNode)
          return true if scope.nil?

          !never_nil?(scope.type_of(expression))
        end

        # The classes a value of which may be `nil`: `NilClass` and its ancestors.
        NIL_ANCESTORS = %w[NilClass Object BasicObject Kernel].freeze
        private_constant :NIL_ANCESTORS

        # True only for a type that provably excludes `nil`: a non-nil literal, an instance of a class `nil` is not
        # (a `Proc`, a `Method`), a class object, or a shape. `top`, `Dynamic`, `Object` and anything this does not
        # list may be `nil` (ADR-130 WD3, as amended).
        def never_nil?(type)
          case type
          when Type::Union then type.members.all? { |member| never_nil?(member) }
          when Type::Constant then !type.value.nil?
          when Type::Nominal then !NIL_ANCESTORS.include?(type.class_name)
          when Type::Refined, Type::Difference then never_nil?(type.base)
          when Type::Singleton, Type::Tuple, Type::HashShape, Type::BoundMethod, Type::IntegerRange, Type::FloatRange,
               Type::DataInstance, Type::StructInstance, Type::DataClass, Type::StructClass then true
          else false
          end
        end

        # `[positional count, keyword names or nil]`, or nil for a shape the AST cannot state, which includes a keyword
        # hash whose keys are not all literal symbols. The keyword names are nil when the call passes no keyword hash.
        def call_shape(args, call_node)
          arguments = call_node.respond_to?(:arguments) ? call_node.arguments&.arguments : nil
          return [args.size, nil] if arguments.nil? || arguments.size != args.size
          return nil if arguments.any? { |node| opaque_argument?(node) }
          return [args.size, nil] unless ArgumentNodes.keyword_hash_last?(call_node, args)

          names = keyword_names(arguments.last)
          names && [args.size - 1, names]
        end

        def opaque_argument?(node)
          case node
          when Prism::SplatNode, Prism::ForwardingArgumentsNode then true
          when Prism::KeywordHashNode then node.elements.any?(Prism::AssocSplatNode)
          else false
          end
        end

        # The literal keyword names of a keyword hash, or nil when one is not a literal symbol.
        def keyword_names(hash_node)
          hash_node.elements.map do |element|
            key = element.key
            return nil unless key.is_a?(Prism::SymbolNode)

            key.unescaped.to_sym
          end
        end

        def takes?(method_type, positional, keywords, block)
          function = method_type.type
          # `(...) -> T`: an untyped parameter list takes every call.
          return block_taken?(method_type.block, block) unless function.respond_to?(:required_positionals)

          block_taken?(method_type.block, block) && arguments_taken?(function, positional, keywords)
        end

        def block_taken?(declared, block)
          block ? !declared.nil? : (declared.nil? || !declared.required)
        end

        def arguments_taken?(function, positional, keywords)
          return positional_taken?(function, positional) && function.required_keywords.empty? if keywords.nil?
          # A keyword hash an overload declares no keywords for is its last positional argument.
          return positional_taken?(function, positional + 1) unless keywords?(function)

          positional_taken?(function, positional) && function.required_keywords.keys.all? do |key|
            keywords.include?(key)
          end
        end

        def positional_taken?(function, count)
          required = function.required_positionals.size + function.trailing_positionals.size
          return false if count < required

          !function.rest_positionals.nil? || count <= required + function.optional_positionals.size
        end

        def keywords?(function)
          !function.required_keywords.empty? || !function.optional_keywords.empty? || !function.rest_keywords.nil?
        end
      end
    end
  end
end
