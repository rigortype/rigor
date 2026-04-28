# frozen_string_literal: true

require_relative "../../type"
require_relative "../acceptance"
require_relative "../rbs_type_translator"

module Rigor
  module Inference
    module MethodDispatcher
      # Picks the RBS overload that should answer a call given the
      # caller's actual argument types. Slice 4 phase 2c shape:
      #
      # 1. Filter overloads by positional arity (required, optional and
      #    rest_positionals are honored; required_keywords disqualify the
      #    overload because we do not yet thread keyword args through
      #    `call_arg_types`).
      # 2. Within the arity-matching overloads, accept the first one
      #    whose every (param, arg) pair returns a `yes` or `maybe`
      #    answer from `Rigor::Type#accepts(arg, mode: :gradual)`.
      # 3. If no overload matches, fall back to `method_types.first`
      #    so existing call sites keep their phase 1 / 2b behavior.
      #    This preserves the fail-soft invariant of the dispatcher.
      #
      # The selector is intentionally agnostic about the dispatch kind
      # (instance vs singleton). Both kinds share the same arity and
      # acceptance shape; the difference is only in which `Definition`
      # the caller fetched.
      module OverloadSelector
        module_function

        # @param method_definition [RBS::Definition::Method]
        # @param arg_types [Array<Rigor::Type>] caller-provided types in
        #   positional order. Empty when there are no arguments.
        # @param self_type [Rigor::Type] substitute for `Bases::Self`.
        # @param instance_type [Rigor::Type] substitute for `Bases::Instance`.
        # @return [RBS::MethodType, nil] the chosen overload, or nil
        #   when the definition has no method types at all.
        def select(method_definition, arg_types:, self_type:, instance_type:)
          overloads = method_definition.method_types
          return nil if overloads.empty?

          match = overloads.find do |method_type|
            matches?(method_type, arg_types, self_type: self_type, instance_type: instance_type)
          end

          match || overloads.first
        end

        class << self
          private

          def matches?(method_type, arg_types, self_type:, instance_type:)
            return false if method_type.respond_to?(:type_params) && rejects_keyword_required?(method_type)

            fun = method_type.type
            return false unless arity_compatible?(fun, arg_types.size)

            params = positional_params_for(fun, arg_types.size)
            params.zip(arg_types).all? do |param, arg|
              accepts_param?(param, arg, self_type: self_type, instance_type: instance_type)
            end
          end

          # Slice 4 phase 2c does not pass keyword arguments through the
          # call site (caller passes only positional `arg_types`). An
          # overload that requires keywords is therefore not a viable
          # candidate; we skip it instead of forcing a fallback.
          def rejects_keyword_required?(method_type)
            fun = method_type.type
            return false unless fun.respond_to?(:required_keywords)

            !fun.required_keywords.empty?
          end

          def arity_compatible?(fun, actual_count)
            min_arity = fun.required_positionals.size + fun.trailing_positionals.size
            return false if actual_count < min_arity

            return true if fun.rest_positionals

            max_arity = min_arity + fun.optional_positionals.size
            actual_count <= max_arity
          end

          # Builds the list of formal parameter declarations to compare
          # against the actual arguments, in positional order: required
          # first, then as many optionals as needed, then trailing
          # required. Rest_positionals consumes the remainder; we
          # repeat its single declaration for each absorbed argument.
          def positional_params_for(fun, actual_count)
            required = fun.required_positionals
            optional = fun.optional_positionals
            rest = fun.rest_positionals
            trailing = fun.trailing_positionals

            head = required.dup
            optional_needed = [actual_count - head.size - trailing.size, 0].max
            head.concat(optional.first(optional_needed))

            absorbed_by_rest = actual_count - head.size - trailing.size
            head.concat([rest] * absorbed_by_rest) if rest && absorbed_by_rest.positive?

            head.concat(trailing)
            head
          end

          def accepts_param?(param, arg, self_type:, instance_type:)
            param_type = RbsTypeTranslator.translate(
              param.type,
              self_type: self_type,
              instance_type: instance_type
            )
            result = param_type.accepts(arg, mode: :gradual)
            result.yes? || result.maybe?
          end
        end
      end
    end
  end
end
