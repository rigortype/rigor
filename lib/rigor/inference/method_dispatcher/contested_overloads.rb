# frozen_string_literal: true

require_relative "../../type"
require_relative "../rbs_type_translator"

module Rigor
  module Inference
    module MethodDispatcher
      module OverloadSelector
        module_function

        # Issue #2379 — every overload a supertype argument may select, when a nominal argument is wider than the
        # parameter of the overload the call selected, `chosen`: `Integer#-` with a `Numeric` argument matched no
        # overload and took the first, `(Integer) -> Integer`, although the runtime takes `(Float)`, `(Rational)` or
        # `(Complex)` for those subclasses. Answers, in affinity order, every strictly typed overload whose every
        # parameter takes its argument or is taken by a nominal one; nil when no argument is wider than `chosen`'s
        # parameter or `chosen` is the only such overload.
        # rubocop:disable-next Metrics/ParameterLists -- the selection inputs.
        def contested_matches(method_definition, chosen, arg_types:, self_type:, instance_type:, type_vars:,
                              block_required:, environment:)
          return nil unless arg_types.any?(Type::Nominal)

          shared = { arg_types: arg_types, self_type: self_type, instance_type: instance_type,
                     type_vars: type_vars, block_required: block_required,
                     param_overrides: RbsExtended.param_type_override_map(method_definition, environment: environment),
                     environment: environment, keywords_last: false }
          return nil unless wider_argument?(chosen, shared)

          overloads = ReceiverAffinity.reorder(method_definition.method_types, self_type: self_type,
                                                                               environment: environment)
          matches = overloads.select do |method_type|
            engages_block_shape?(method_type, block_required) &&
              strictly_typed_params?(method_type, shared) && overlaps?(method_type, shared)
          end
          matches.empty? || (matches.size == 1 && matches.first.equal?(chosen)) ? nil : matches
        end

        class << self
          private

          # Whether a nominal argument is strictly wider than the parameter `method_type` binds it to: the parameter
          # does not take the whole argument, and the argument takes the parameter (`Numeric` against `(Integer)`).
          def wider_argument?(method_type, shared)
            fun = method_type.type
            arg_types = shared[:arg_types]
            return false unless fun.respond_to?(:required_positionals) && arity_compatible?(fun, arg_types.size)

            params = positional_params_for(fun, arg_types.size)
            index = -1
            params.any? do |param|
              arg = arg_types[index += 1]
              next false unless arg.is_a?(Type::Nominal)

              param_type = translate_param(param, shared)
              !param_type.accepts(arg, mode: :gradual).yes? && arg.accepts(param_type, mode: :gradual).yes?
            end
          end

          # The strict pass's test with a nominal argument also counting where it takes the parameter: some value of
          # a `Numeric` reaches `(Float)`.
          def overlaps?(method_type, shared)
            fun = method_type.type
            ok = KeywordArguments.accepted_by?(fun, shared, true) { |*kv| accepts_param?(*kv, shared, true, true) }
            return false unless ok

            arg_types = shared[:arg_types]
            return false unless arity_compatible?(fun, arg_types.size)

            each_param_accepts?(positional_params_for(fun, arg_types.size), arg_types) do |param, arg|
              accepts_param?(param, arg, shared, true) ||
                (arg.is_a?(Type::Nominal) && arg.accepts(translate_param(param, shared), mode: :gradual).yes?)
            end
          end

          # A parameter's type as the selector reads it: the `rigor:v1:param:` override, else the translated RBS type.
          def translate_param(param, shared)
            shared[:param_overrides][param.name] || RbsTypeTranslator.translate(
              param.type,
              self_type: shared[:self_type],
              instance_type: shared[:instance_type],
              type_vars: shared[:type_vars],
              alias_expander: shared[:environment]&.rbs_loader
            )
          end
        end
      end
    end
  end
end
