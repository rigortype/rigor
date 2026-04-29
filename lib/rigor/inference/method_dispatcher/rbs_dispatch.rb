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
      # Phase 2d adds generics instantiation. Receivers carry an
      # ordered `type_args` array on `Rigor::Type::Nominal`. The
      # dispatcher zips the receiver's `type_args` against the class's
      # declared type-parameter names (`Array` -> `[:Elem]`, `Hash` ->
      # `[:K, :V]`, ...) to build a substitution map; that map is then
      # threaded through {RbsTypeTranslator} so a return type like
      # `::Array[Elem]` resolves to `Nominal["Array", [Integer]]`
      # rather than degrading the variable to `Dynamic[Top]`. When
      # arities mismatch (raw receiver, partial generics) the map is
      # left empty and free variables degrade as before.
      #
      # Slice 5 phase 1 projects shape-carrying receivers onto their
      # underlying nominal so the existing dispatch + substitution
      # machinery works without duplication: `Tuple[Integer, String]`
      # dispatches as `Array[Integer | String]`, and
      # `HashShape{a: Integer}` dispatches as `Hash[Symbol, Integer]`.
      # Tuple-aware refinements (e.g., `tuple[0]` returning the precise
      # member) are deferred to Slice 5 phase 2.
      #
      # Remaining limitations:
      #
      # * `block_type:` is ignored; method types that constrain the
      #   block return type are not yet honored.
      # * Keyword arguments are not threaded through call_arg_types,
      #   so overloads with required keywords are skipped (they cannot
      #   match the empty kwargs we send).
      # * Method-level type parameters (e.g., `def foo[T]: (T) -> T`)
      #   are not bound; their variables remain `Dynamic[Top]` after
      #   substitution.
      #
      # See docs/adr/4-type-inference-engine.md for the broader plan.
      # rubocop:disable Metrics/ModuleLength
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

        # Slice 6 (Phase C sub-phase 1) probe: returns the positional
        # block-parameter types declared by the receiving method's
        # selected RBS overload, translated into `Rigor::Type`. Used
        # by the StatementEvaluator to bind block parameter names
        # before evaluating the block body.
        #
        # The probe shares the receiver descriptor / overload selector
        # plumbing with `try_dispatch`; only the projection at the end
        # differs (the block's positional params instead of the return
        # type). Returns an empty array when:
        #
        # - the environment / RBS loader is missing,
        # - the receiver does not project to a known class,
        # - the method has no signature in RBS,
        # - the selected overload has no `block:` clause, or
        # - the block is `untyped` / `UntypedFunction` (no statically
        #   declared parameter types).
        #
        # This deliberately does NOT differentiate "no overload had a
        # block" from "the block is untyped"; the binder treats both
        # the same way (every parameter defaults to `Dynamic[Top]`).
        # @return [Array<Rigor::Type>] positional block parameter types.
        def block_param_types(receiver:, method_name:, args:, environment:)
          return [] if environment.nil?
          return [] unless environment.rbs_loader

          probe_block_param_types(
            receiver: receiver,
            method_name: method_name,
            args: args,
            environment: environment
          )
        end

        # rubocop:disable Metrics/ClassLength
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

            class_name, kind, receiver_args = descriptor
            method_definition = lookup_method(environment, class_name, kind, method_name)
            return nil unless method_definition

            type_vars = build_type_vars(environment, class_name, receiver_args)
            translate_return_type(
              method_definition,
              class_name: class_name,
              kind: kind,
              args: args,
              type_vars: type_vars
            )
          rescue StandardError
            # Defensive: if RBS' definition builder raises on a broken
            # hierarchy (e.g., partially loaded user signatures), the
            # dispatcher MUST stay fail-soft.
            nil
          end

          # Maps a Rigor::Type receiver to a
          # `[class_name, kind, type_args]` triple where `kind` is
          # either `:instance` or `:singleton` and `type_args` carries
          # the receiver's generic instantiation (empty for raw or
          # singleton receivers, since `Singleton[Foo]` carries no
          # generic args today). Returns nil when the receiver does
          # not correspond to a single concrete class.
          #
          # Slice 5 phase 1 projects Tuple/HashShape receivers to
          # their underlying Array/Hash nominal so dispatch reuses the
          # generic-typed pipeline.
          def receiver_descriptor(receiver)
            case receiver
            when Type::Constant
              [receiver.value.class.name, :instance, []]
            when Type::Nominal
              [receiver.class_name, :instance, receiver.type_args]
            when Type::Singleton
              [receiver.class_name, :singleton, []]
            when Type::Tuple
              ["Array", :instance, tuple_type_args(receiver)]
            when Type::HashShape
              ["Hash", :instance, hash_shape_type_args(receiver)]
            when Type::Dynamic
              receiver_descriptor(receiver.static_facet)
            end
          end

          def tuple_type_args(tuple)
            return [] if tuple.elements.empty?

            [Type::Combinator.union(*tuple.elements)]
          end

          def hash_shape_type_args(shape)
            return [] if shape.pairs.empty?

            key_types = shape.pairs.keys.map { |k| Type::Combinator.constant_of(k) }
            value_types = shape.pairs.values
            [
              Type::Combinator.union(*key_types),
              Type::Combinator.union(*value_types)
            ]
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

          # Slice 4 phase 2d substitution map. Zips the class's
          # declared type-parameter names against the receiver's
          # `type_args`. Returns an empty hash when either side is
          # empty or when arities disagree -- in both cases free
          # variables in the method's return type degrade to
          # `Dynamic[Top]` per the translator's contract.
          def build_type_vars(environment, class_name, receiver_args)
            return {} if receiver_args.empty?

            param_names = environment.rbs_loader.class_type_param_names(class_name)
            return {} if param_names.empty?
            return {} if param_names.size != receiver_args.size

            param_names.zip(receiver_args).to_h
          end

          def translate_return_type(method_definition, class_name:, kind:, args:, type_vars:)
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
              instance_type: instance_type,
              type_vars: type_vars
            )
            return nil unless method_type

            RbsTypeTranslator.translate(
              method_type.type.return_type,
              self_type: self_type,
              instance_type: instance_type,
              type_vars: type_vars
            )
          end

          # ----- block parameter probe (Phase C sub-phase 1) -----

          def probe_block_param_types(receiver:, method_name:, args:, environment:)
            args ||= []
            case receiver
            when Type::Union then probe_block_param_types_union(receiver, method_name, args, environment)
            else                  probe_block_param_types_one(receiver, method_name, args, environment)
            end
          end

          # For a union receiver we keep the conservative answer: only
          # return block param types when every member resolves the
          # same arity and types (otherwise the call sites would have
          # to thread per-member binders, which the slice does not
          # support yet). Mismatches degrade to the empty array so the
          # binder defaults all params to Dynamic[Top].
          def probe_block_param_types_union(receiver, method_name, args, environment)
            results = receiver.members.map do |member|
              probe_block_param_types_one(member, method_name, args, environment)
            end
            return [] if results.empty?
            return [] unless results.all? { |r| r == results.first }

            results.first
          end

          def probe_block_param_types_one(receiver, method_name, args, environment)
            descriptor = receiver_descriptor(receiver)
            return [] unless descriptor

            class_name, kind, receiver_args = descriptor
            method_definition = lookup_method(environment, class_name, kind, method_name)
            return [] unless method_definition

            type_vars = build_type_vars(environment, class_name, receiver_args)
            extract_block_param_types(
              method_definition,
              class_name: class_name,
              kind: kind,
              args: args,
              type_vars: type_vars
            )
          rescue StandardError
            []
          end

          def extract_block_param_types(method_definition, class_name:, kind:, args:, type_vars:)
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
              instance_type: instance_type,
              type_vars: type_vars,
              block_required: true
            )
            return [] unless method_type

            block = method_type.respond_to?(:block) ? method_type.block : nil
            return [] unless block

            translate_block_positional_params(
              block,
              self_type: self_type,
              instance_type: instance_type,
              type_vars: type_vars
            )
          end

          # `RBS::Types::Block#type` is normally an `RBS::Types::Function`
          # carrying the block's parameter list; some signatures use
          # `RBS::Types::UntypedFunction` (a `(?)` block) which exposes
          # no parameter types -- we treat it as "no information" and
          # return an empty array so the binder defaults every slot.
          def translate_block_positional_params(block, self_type:, instance_type:, type_vars:)
            fun = block.type
            return [] unless fun.respond_to?(:required_positionals)

            params = fun.required_positionals + fun.optional_positionals
            params.map do |param|
              RbsTypeTranslator.translate(
                param.type,
                self_type: self_type,
                instance_type: instance_type,
                type_vars: type_vars
              )
            end
          end
        end
        # rubocop:enable Metrics/ClassLength
      end
      # rubocop:enable Metrics/ModuleLength
    end
  end
end
