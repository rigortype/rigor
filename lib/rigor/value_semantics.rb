# frozen_string_literal: true

module Rigor
  # Generates the value-object identity trio (`==` / `eql?` / `hash`) from a fixed field
  # list. Every `Rigor::Type` carrier and the cache descriptor entries are immutable value
  # objects that each hand-wrote the same three methods; forgetting a field in one of them
  # (or letting `==` and `hash` disagree) silently corrupts `Set` / `Hash`-key behaviour — a
  # carrier vanishes after its first insertion, or two distinct types compare equal.
  #
  # The methods are CODE-GENERATED at class-definition time, not driven by per-call
  # reflection, so they are as fast as the hand-written versions they replace — `hash` and
  # `==` run on the inference hot path (type dedup, fact-store keys, memo caches), where a
  # `send`-per-field would be a real regression.
  #
  # Usage:
  #
  #   class Nominal
  #     include Rigor::ValueSemantics
  #     value_fields :class_name, :type_args
  #   end
  #
  # generates exactly:
  #
  #   def ==(other)
  #     other.is_a?(self.class) && class_name == other.class_name && type_args == other.type_args
  #   end
  #   alias_method :eql?, :==
  #   def hash
  #     [self.class, class_name, type_args].hash
  #   end
  #
  # Value objects whose equality is NOT a plain field-wise comparison keep their
  # hand-written `==` / `hash` and do not call `value_fields` — e.g. `Type::Constant` also
  # distinguishes `value.class` (so `Constant[1] != Constant[1.0]`), and `Type::Top` /
  # `Type::Bot` are field-free singletons.
  module ValueSemantics
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      # Define `==` / `eql?` / `hash` over the given immutable fields.
      def value_fields(*fields)
        comparisons = fields.map { |f| "#{f} == other.#{f}" }
        guard = comparisons.empty? ? "" : " && #{comparisons.join(' && ')}"
        key = (["self.class"] + fields.map(&:to_s)).join(", ")

        # Codegen (not per-call reflection) so the generated `==` / `hash` read fields
        # directly and run at hand-written speed on the inference hot path. For
        # `value_fields :class_name, :type_args` the emitted source is:
        #
        #   def ==(other)
        #     other.is_a?(self.class) && class_name == other.class_name && type_args == other.type_args
        #   end
        #   alias_method :eql?, :==
        #   def hash
        #     [self.class, class_name, type_args].hash
        #   end
        class_eval(<<~RUBY, __FILE__, __LINE__ + 1) # rubocop:disable Style/DocumentDynamicEvalDefinition
          def ==(other)
            other.is_a?(self.class)#{guard}
          end
          alias_method :eql?, :==

          def hash
            [#{key}].hash
          end
        RUBY
      end
    end
  end
end
