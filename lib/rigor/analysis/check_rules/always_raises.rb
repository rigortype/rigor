# frozen_string_literal: true

require_relative "../../type"
require_relative "../diagnostic"
require_relative "receiver_predicates"

module Rigor
  module Analysis
    module CheckRules
      # ADR-116 WD1 — `flow.always-raises`: a call that raises on every run, today the Integer division and
      # modulo family by a literal zero.
      #
      # The one entry point is {.diagnostic}, called by `CheckRules.call_node_diagnostics`. It reads
      # {ReceiverPredicates} and {AlwaysRaisesShield} and calls nothing else in `CheckRules`.
      module AlwaysRaises
        module_function

        # Diagnoses calls that the analyzer can prove will always raise. Today the only triggering shape is
        # integer division/modulo by a literal zero divisor:
        #
        #   5 / 0          # => ZeroDivisionError
        #   x.modulo(0)    # => ZeroDivisionError when x: Integer
        #   xs.size % 0    # same — non_negative_int / Constant[0]
        #
        # Float divmod by zero returns Infinity/NaN at runtime, so the rule restricts to Integer-rooted
        # receivers (`Constant`, `IntegerRange`, `Nominal[Integer]`). The argument MUST be a
        # `Constant<Integer>` whose value is exactly zero — a `Union[Constant[0], Constant[2]]` divisor
        # "may" raise, which we surface separately (future slice).
        INTEGER_RAISING_OPERATORS = %i[/ % div modulo divmod].freeze
        private_constant :INTEGER_RAISING_OPERATORS

        def diagnostic(path, call_node, facts, lexical_sites = nil, raise_shield = nil)
          return nil unless integer_zero_division?(call_node, facts)

          # ADR-121 WD7 — a refinement of `Integer`'s operator (or one Rigor cannot read) in effect may not raise.
          return nil if ReceiverPredicates.refined_method_in_effect?("Integer", call_node, facts.scope, :instance,
                                                                     lexical_sites)

          # Issue #3036 — a raise an enclosing `begin` / `def … rescue` catches flows to the handler.
          return nil if raise_shield&.rescued?(call_node, facts.scope)

          build_always_raises_diagnostic(path, call_node)
        end

        def integer_zero_division?(call_node, facts)
          return false unless raising_call_shape?(call_node)

          scope = facts.scope
          return false if scope.nil?
          return false unless integer_rooted_for_diagnostic?(facts.receiver_type)

          arg = single_argument(call_node)
          arg && integer_zero_constant?(scope.type_of(arg))
        end

        def raising_call_shape?(call_node)
          !call_node.receiver.nil? && INTEGER_RAISING_OPERATORS.include?(call_node.name)
        end

        def single_argument(call_node)
          args = call_node.arguments&.arguments || []
          args.size == 1 ? args.first : nil
        end

        def integer_rooted_for_diagnostic?(type)
          case type
          when Type::Constant then type.value.is_a?(Integer)
          when Type::IntegerRange then true
          when Type::Nominal then type.class_name == "Integer" && type.type_args.empty?
          else false
          end
        end

        def integer_zero_constant?(type)
          type.is_a?(Type::Constant) && type.value.is_a?(Integer) && type.value.zero?
        end

        def build_always_raises_diagnostic(path, call_node)
          Diagnostic.from_message_loc(
            call_node,
            rule: RULE_ALWAYS_RAISES,
            path: path,
            message: "always raises ZeroDivisionError: `#{call_node.name}' by zero on Integer receiver",
            severity: :error
          )
        end

        private_class_method :integer_zero_division?, :raising_call_shape?, :single_argument,
                             :integer_rooted_for_diagnostic?, :integer_zero_constant?,
                             :build_always_raises_diagnostic
      end
    end
  end
end
