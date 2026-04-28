# frozen_string_literal: true

require_relative "../../type"
require_relative "../rbs_type_translator"

module Rigor
  module Inference
    module MethodDispatcher
      # Slice 4 dispatch tier that consults RBS instance method
      # signatures. Sits behind {ConstantFolding}, so anything the
      # constant folder already proves (e.g., `1 + 2 == 3`) keeps its
      # full Constant precision; only the calls the folder cannot
      # prove fall through to RBS.
      #
      # Limitations of phase 1:
      #
      # * Only the first overload of a method is consulted. Argument-
      #   driven overload selection lands in Slice 5.
      # * Only instance-method dispatch. Class-method dispatch
      #   (`Foo.bar`) requires the singleton-class type model and is
      #   deferred until that lands.
      # * Generics are erased: `Array[Integer]#first` translates to
      #   `Optional[Integer?]` with `Integer?` resolved as
      #   `Dynamic[Top]` because we do not yet substitute the type
      #   variable.
      # * `block_type:` is ignored; method types that constrain the
      #   block return type are not yet honored.
      #
      # See docs/adr/4-type-inference-engine.md for the broader plan.
      module RbsDispatch
        module_function

        # @param receiver [Rigor::Type]
        # @param method_name [Symbol]
        # @param args [Array<Rigor::Type>]
        # @param environment [Rigor::Environment]
        # @return [Rigor::Type, nil] inferred return type, or `nil`
        #   when no rule resolves (no class name, no method, dispatch
        #   on a Top/Dynamic[Top] receiver, etc.).
        def try_dispatch(receiver:, method_name:, args:, environment:)
          return nil if environment.nil?
          return nil unless environment.rbs_loader

          dispatch_for(
            receiver: receiver,
            method_name: method_name,
            args: args,
            environment: environment
          )
        end

        class << self
          private

          def dispatch_for(receiver:, method_name:, args:, environment:)
            case receiver
            when Type::Union
              dispatch_union(receiver, method_name, args, environment)
            else
              dispatch_singleton(receiver, method_name, args, environment)
            end
          end

          def dispatch_union(receiver, method_name, args, environment)
            results = receiver.members.map do |member|
              dispatch_singleton(member, method_name, args, environment)
            end
            return nil if results.any?(&:nil?)

            Type::Combinator.union(*results)
          end

          def dispatch_singleton(receiver, method_name, _args, environment)
            class_name = receiver_class_name(receiver)
            return nil unless class_name

            method_definition = environment.rbs_loader.instance_method(
              class_name: class_name,
              method_name: method_name
            )
            return nil unless method_definition

            translate_return_type(method_definition, class_name)
          rescue StandardError
            # Defensive: if RBS' definition builder raises on a broken
            # hierarchy (e.g., partially loaded user signatures), the
            # dispatcher MUST stay fail-soft.
            nil
          end

          # Maps a Rigor::Type receiver to a Ruby class name suitable
          # for RBS lookup. Returns nil when the receiver does not
          # correspond to a single concrete class -- callers fall back
          # to Dynamic[Top] in that case.
          def receiver_class_name(receiver)
            case receiver
            when Type::Constant
              receiver.value.class.name
            when Type::Nominal
              receiver.class_name
            when Type::Dynamic
              receiver_class_name(receiver.static_facet)
            end
          end

          def translate_return_type(method_definition, class_name)
            method_type = method_definition.method_types.first
            return nil unless method_type

            return_type = method_type.type.return_type
            self_type = Type::Combinator.nominal_of(class_name)
            RbsTypeTranslator.translate(return_type, self_type: self_type)
          end
        end
      end
    end
  end
end
