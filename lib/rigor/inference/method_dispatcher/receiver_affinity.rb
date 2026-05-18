# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # Stable-sort an overload list so that "receiver-affinity"
      # arms come first. An overload is receiver-affinity-matching
      # when every positional param's class equals `self_type`'s
      # class name OR is one of its proper RBS ancestors. The
      # canonical case the helper exists for: when `bigdecimal`'s
      # stdlib RBS reopens `Integer#+` at the FRONT of the
      # overload list with `(BigDecimal) -> BigDecimal`, that
      # disjoint-sibling arm would win every dispatch for
      # `Integer#+(?)` by overload-list position alone, returning
      # a spurious `BigDecimal` for plain integer arithmetic.
      # Demoting the arm honours the coerce convention: when the
      # arg type is unknown or itself an Integer, the
      # receiver-preserving `(Integer) -> Integer` arm should win.
      #
      # No-op when (a) the environment can't answer
      # `class_ordering` (nil env), or (b) the receiver isn't a
      # nominal / singleton carrying a class name. The partition
      # is stable, so within each bucket the RBS-declared order
      # is preserved.
      module ReceiverAffinity
        module_function

        def reorder(overloads, self_type:, environment:)
          return overloads if environment.nil?

          self_class_name = self_type_class_name(self_type)
          return overloads if self_class_name.nil?

          affinity, other = overloads.partition do |mt|
            overload_param_classes_in_ancestry?(mt, self_class_name, environment)
          end
          affinity + other
        end

        class << self
          private

          def self_type_class_name(self_type)
            case self_type
            when Type::Nominal, Type::Singleton then self_type.class_name
            end
          end

          def overload_param_classes_in_ancestry?(method_type, self_class_name, environment)
            fun = method_type.type
            params = fun.required_positionals + fun.optional_positionals + fun.trailing_positionals
            return false if params.empty?

            params.all? { |param| param_class_in_ancestry?(param.type, self_class_name, environment) }
          end

          # Walks Optional and Union one level so `(Numeric?)` and
          # `(Integer | Float)` still classify when every branch
          # sits in the ancestry. Non-`ClassInstance` shapes
          # (Alias / Interface / Intersection / type variables)
          # don't carry a clean class identity and therefore
          # disqualify the overload from the affinity bucket.
          def param_class_in_ancestry?(rbs_type, self_class_name, environment)
            case rbs_type
            when RBS::Types::ClassInstance
              class_in_ancestry?(rbs_type.name.to_s.delete_prefix("::"), self_class_name, environment)
            when RBS::Types::Optional
              param_class_in_ancestry?(rbs_type.type, self_class_name, environment)
            when RBS::Types::Union
              rbs_type.types.all? { |t| param_class_in_ancestry?(t, self_class_name, environment) }
            else
              false
            end
          end

          def class_in_ancestry?(param_class_name, self_class_name, environment)
            return true if param_class_name == self_class_name

            environment.class_ordering(self_class_name, param_class_name) == :subclass
          end
        end
      end
    end
  end
end
