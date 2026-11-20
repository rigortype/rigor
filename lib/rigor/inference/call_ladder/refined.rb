# frozen_string_literal: true

require_relative "../../type"
require_relative "../refined_dispatch"

module Rigor
  module Inference
    module CallLadder
      # The `refined` rung of the call ladder (ADR-116 WD12; ADR-121): a call through a Ruby refinement in effect at
      # the call site, answered from the winning refine body ahead of every other rung. `ExpressionTyper` asks it first
      # in a call's ladder, directly behind indexed and method-chain narrowing. {ExpressionTyper} is not required here:
      # it requires this file. Nor is {InEffectRefinements}: `Scope` requires it, and it cannot load ahead of `Scope`.
      #
      # {.try_call} is the rung, asked with the call's site and the walking typer, and the module's one entry: only the
      # ladder's entries ask it, so it has no second entry. Every other function is private to the module.
      #
      # The module holds no state. It reads the scope as `typer.scope` and calls back three methods of the typer:
      # `positional_correspondence` and `infer_user_method_return`, which re-type the winning refine body, and
      # `call_result_type_for`, the call's ladder, which a union receiver re-enters for each member no refinement wins.
      # `CallLadder::PORT` lists them. A function that only reads the scope takes it as a parameter and never sees the
      # typer.
      module Refined
        module_function

        # ADR-121 WD2 (issue #1664) — a call through an in-effect Ruby refinement, typed from the winning refine body
        # with the call's receiver as `self`, ahead of every tier below: each answers from the method the refinement
        # replaces (a refined `String#upcase` must not fold, a refined `map` must not fold per element, a top-level
        # `def` must not bind ahead of a refinement of `Object`, a plugin models the class's own method). An unreadable
        # body, or a list that may hold any refinement, answers `Dynamic[top]`, never the replaced method's signature.
        # A union receiver is decided per member; a `Dynamic` receiver and a call no refinement wins fall through. A
        # class object walks its own lookup (issue #1752): under `refine(Object) { def oo = :o }` a refinement that wins
        # `Integer.oo` answers `Dynamic[top]` ({.refined_class_object_result}). A call site no refinement is in effect
        # at answers nil at once and records nothing: its answer cannot change without an edit to its own file.
        #
        # ADR-121 WD7 (A2) — inside the span of an activation that puts an opaque module in effect
        # ({InEffectRefinements.opaque_module?}), any method of any object may be replaced, so every call on an instance
        # or a class object answers `Dynamic[top]`.
        #
        # The rung, asked with the call's site. The method name is the site's, not the call node's, and so are the
        # receiver, the argument types and the block type. The call node is read for where the call stands (the
        # refinements in effect there, the span of an opaque activation) and for what it writes (a literal name
        # argument, a `&:name` block, the arguments a refine body is bound to).
        def try_call(site, typer)
          node = site.call_node
          receiver = site.receiver
          arg_types = site.args
          method_name = site.method_name
          block_type = site.block_type
          list = typer.scope.in_effect_refinements(node)
          return nil if list.empty?

          InEffectRefinements.record_refinement_names(method_name)
          if refined_receiver?(receiver) && opaque_refinement_span?(node, list, typer.scope)
            return Type::Combinator.untyped
          end
          return nil if typer.scope.discovered_refinements.empty?

          refined_indirect_result(node, receiver, list, method_name, typer.scope) ||
            refined_receiver_result(node, receiver, list, arg_types, block_type, method_name, typer)
        end

        # ADR-121 WD4 — `send` / `__send__` / `public_send` with a literal name, `respond_to?` and `method` /
        # `public_method` with one, and a `&:name` block argument honour refinements too (CRuby `test_refinement.rb`;
        # probed on Ruby 4.0.5). When the name they reach is refined in effect for the receiver they answer
        # `Dynamic[top]`: typing them through the arm is deferred, and `respond_to?` must never fold to `false`. A
        # `&:name` block's receiver is the yielded element, which is not known here, so any in-effect refinement of the
        # name answers. Only `methods` ignores refinements and keeps its answer.
        def refined_indirect_result(node, receiver, list, method_name, scope)
          name = REFINED_NAMING_CALLS.include?(method_name) ? literal_method_name_argument(node) : nil
          return Type::Combinator.untyped if name && refined_name_for?(receiver, name, list, scope)

          block_name = symbol_block_argument(node)
          Type::Combinator.untyped if block_name && RefinedDispatch.refined_anywhere?(scope, block_name, list)
        end

        REFINED_NAMING_CALLS = Set[:send, :__send__, :public_send, :respond_to?, :method, :public_method].freeze
        private_constant :REFINED_NAMING_CALLS

        def literal_method_name_argument(node)
          argument = node.arguments&.arguments&.first
          name = argument.unescaped if argument.is_a?(Prism::SymbolNode) || argument.is_a?(Prism::StringNode)
          return nil if name.nil?

          name = name.to_sym
          InEffectRefinements.record_refinement_names(name)
          name
        end

        def symbol_block_argument(node)
          block = node.block
          return nil unless block.is_a?(Prism::BlockArgumentNode) && block.expression.is_a?(Prism::SymbolNode)

          name = block.expression.unescaped.to_sym
          InEffectRefinements.record_refinement_names(name)
          name
        end

        def refined_name_for?(receiver, name, list, scope)
          members = receiver.is_a?(Type::Union) ? receiver.members : [receiver]
          members.any? do |member|
            next !RefinedDispatch.winner(scope, member.class_name, name, list, kind: :singleton).nil? if
              member.is_a?(Type::Singleton)

            class_name = refined_receiver_class_name(member)
            !class_name.nil? && !RefinedDispatch.winner(scope, class_name, name, list).nil?
          end
        end

        # ADR-121 WD7 — does the call's lexical list (a plugin-declared module is the plugin's declaration and never
        # opaque) hold an opaque module? `list` is the full list, which is the lexical one when nothing is declared.
        def opaque_refinement_span?(node, list, scope)
          lexical =
            scope.declared_refinements.empty? ? list : scope.in_effect_refinements(node, InEffectRefinements::EMPTY)
          InEffectRefinements.opaque_in?(scope, lexical)
        end

        # Does `receiver` (or a member of a union) have a lookup the refined arm answers for: an instance of a class,
        # or a class object (issue #1752), not `Dynamic`?
        def refined_receiver?(receiver)
          members = receiver.is_a?(Type::Union) ? receiver.members : [receiver]
          members.any? { |member| member.is_a?(Type::Singleton) || !refined_receiver_class_name(member).nil? }
        end

        # A union receiver is decided per member, and a member no refinement wins re-enters the call's ladder with that
        # member as the receiver (`ExpressionTyper#call_result_type_for`, a re-entry point of the port).
        def refined_receiver_result(node, receiver, list, arg_types, block_type, method_name, typer)
          unless receiver.is_a?(Type::Union)
            return refined_member_result(node, receiver, list, arg_types, block_type, method_name, typer)
          end

          answers = receiver.members.map do |member|
            refined_member_result(node, member, list, arg_types, block_type, method_name, typer)
          end
          return nil if answers.none?

          members = receiver.members.each_with_index.map do |member, index|
            answers[index] || typer.call_result_type_for(node, receiver_override: member)
          end
          Type::Combinator.union(*members)
        end

        def refined_member_result(node, receiver, list, arg_types, block_type, method_name, typer)
          if receiver.is_a?(Type::Singleton)
            return refined_class_object_result(node, receiver, list, arg_types, block_type, method_name, typer.scope)
          end

          class_name = refined_receiver_class_name(receiver)
          return nil if class_name.nil?

          winner = RefinedDispatch.winner(typer.scope, class_name, method_name, list)
          return nil if winner.nil?
          return Type::Combinator.untyped if winner == RefinedDispatch::UNKNOWN

          refined_body_return(winner, node, Type::Combinator.nominal_of(class_name), arg_types, block_type, method_name,
                              typer) || Type::Combinator.untyped
        end

        # Issue #1752 — a call on a class object, walked through its singleton levels. A refinement that wins answers
        # `Dynamic[top]`, never its refine body's type: a hook on any ancestor (an RBS-declared `include Singleton`, a
        # gem concern, `define_singleton_method(:included)`, a `Module#included` patch) can install the class object's
        # own method where no table sees it, and the body's type then fires downstream on correct code. A walk that
        # finds no winner keeps the class object's own answer (`Integer.sqrt(16)` stays `Integer`).
        def refined_class_object_result(_node, receiver, list, _arg_types, _block_type, method_name, scope)
          winner = RefinedDispatch.winner(scope, receiver.class_name, method_name, list, kind: :singleton)
          Type::Combinator.untyped unless winner.nil?
        end

        # The winning refine body's inferred return, re-typed with the receiver's class as `self` and the call's
        # argument types bound as an undeclared method's are; nil when the body is not readable here.
        #
        # A body another file wrote is re-typed with that file's in-effect refinements at the `def` (its own module
        # among them), so a sibling override it calls answers from its refine body too.
        def refined_body_return(winner, call_node, self_type, arg_types, block_type, method_name, typer)
          def_node, foreign =
            InEffectRefinements.refinement_def_with_query(typer.scope, winner.module_name, winner.refined_class,
                                                          method_name)
          return nil if def_node.nil?

          refinements = foreign&.at(def_node.location.start_offset) do |name|
            InEffectRefinements.activated_modules(typer.scope, name)
          end
          arg_types, positionals_unknown = typer.positional_correspondence(call_node, arg_types)
          typer.infer_user_method_return(def_node, self_type, arg_types, yield_type: block_type,
                                                                         refinements: refinements,
                                                                         positionals_unknown: positionals_unknown)
        rescue StandardError
          nil
        end

        # The class an instance-side receiver is an instance of, or nil for one this instance walk does not answer: a
        # class object (it walks its own lookup, {.refined_class_object_result}), `Dynamic`, `top`, or a shape with no
        # class.
        def refined_receiver_class_name(receiver)
          case receiver
          when Type::Nominal, Type::StructInstance, Type::DataInstance then receiver.class_name
          when Type::Constant then receiver.value.class.name
          when Type::Tuple then "Array"
          when Type::HashShape then "Hash"
          when Type::IntegerRange then "Integer"
          when Type::FloatRange then "Float"
          when Type::Refined, Type::Difference then refined_receiver_class_name(receiver.base)
          end
        end

        private_class_method :refined_indirect_result, :literal_method_name_argument, :symbol_block_argument,
                             :refined_name_for?, :opaque_refinement_span?, :refined_receiver?, :refined_receiver_result,
                             :refined_member_result, :refined_class_object_result, :refined_body_return,
                             :refined_receiver_class_name
      end
    end
  end
end
