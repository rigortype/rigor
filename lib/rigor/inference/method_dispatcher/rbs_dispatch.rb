# frozen_string_literal: true

require_relative "../../type"
require_relative "../rbs_type_translator"
require_relative "overload_selector"

module Rigor
  module Inference
    module MethodDispatcher
      # Slice 4 dispatch tier that consults RBS method signatures.
      # Sits behind {ConstantFolding}, so anything the constant folder
      # already proves (e.g., `1 + 2 == 3`) keeps its full Constant
      # precision; only the calls the folder cannot prove fall through
      # to RBS.
      #
      # Phase 2b extends the dispatcher to recognise `Singleton[Foo]`
      # receivers, routing those calls through `singleton_method`
      # instead of `instance_method`. The constant `Foo` therefore now
      # resolves to `Singleton[Foo]`, and `Foo.new` / `Foo.bar` look up
      # the corresponding *class* methods.
      #
      # Phase 2c adds argument-typed overload selection: instead of
      # always returning `method_types.first`, the dispatcher delegates
      # to {OverloadSelector} which filters overloads by positional
      # arity and consults `Rigor::Type#accepts` for each parameter.
      # When no overload accepts the actual argument types, the
      # selector falls back to the first overload so the existing
      # phase-1/2b behavior is preserved.
      #
      # Remaining limitations:
      #
      # * Generics are erased: `Array[Integer]#first` translates to
      #   `Optional[Integer?]` with `Integer?` resolved as
      #   `Dynamic[Top]` because we do not yet substitute the type
      #   variable. Generics instantiation lands in Slice 4 phase 2d.
      # * `block_type:` is ignored; method types that constrain the
      #   block return type are not yet honored.
      # * Keyword arguments are not threaded through call_arg_types,
      #   so overloads with required keywords are skipped (they cannot
      #   match the empty kwargs we send).
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
            args ||= []
            case receiver
            when Type::Union
              dispatch_union(receiver, method_name, args, environment)
            else
              dispatch_one(receiver, method_name, args, environment)
            end
          end

          def dispatch_union(receiver, method_name, args, environment)
            results = receiver.members.map do |member|
              dispatch_one(member, method_name, args, environment)
            end
            return nil if results.any?(&:nil?)

            Type::Combinator.union(*results)
          end

          def dispatch_one(receiver, method_name, args, environment)
            descriptor = receiver_descriptor(receiver)
            return nil unless descriptor

            class_name, kind = descriptor
            method_definition = lookup_method(environment, class_name, kind, method_name)
            return nil unless method_definition

            translate_return_type(method_definition, class_name, kind, args)
          rescue StandardError
            # Defensive: if RBS' definition builder raises on a broken
            # hierarchy (e.g., partially loaded user signatures), the
            # dispatcher MUST stay fail-soft.
            nil
          end

          # Maps a Rigor::Type receiver to a `[class_name, kind]` pair
          # where `kind` is either `:instance` or `:singleton`. Returns
          # nil when the receiver does not correspond to a single
          # concrete class -- callers fall back to Dynamic[Top].
          def receiver_descriptor(receiver)
            case receiver
            when Type::Constant
              [receiver.value.class.name, :instance]
            when Type::Nominal
              [receiver.class_name, :instance]
            when Type::Singleton
              [receiver.class_name, :singleton]
            when Type::Dynamic
              receiver_descriptor(receiver.static_facet)
            end
          end

          def lookup_method(environment, class_name, kind, method_name)
            case kind
            when :instance
              environment.rbs_loader.instance_method(
                class_name: class_name,
                method_name: method_name
              )
            when :singleton
              environment.rbs_loader.singleton_method(
                class_name: class_name,
                method_name: method_name
              )
            end
          end

          def translate_return_type(method_definition, class_name, kind, args)
            instance_type = Type::Combinator.nominal_of(class_name)
            self_type =
              case kind
              when :singleton then Type::Combinator.singleton_of(class_name)
              else                 instance_type
              end

            method_type = OverloadSelector.select(
              method_definition,
              arg_types: args,
              self_type: self_type,
              instance_type: instance_type
            )
            return nil unless method_type

            RbsTypeTranslator.translate(
              method_type.type.return_type,
              self_type: self_type,
              instance_type: instance_type
            )
          end
        end
      end
    end
  end
end
