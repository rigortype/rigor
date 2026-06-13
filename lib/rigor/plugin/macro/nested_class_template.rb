# frozen_string_literal: true

module Rigor
  module Plugin
    module Macro
      # ADR-36 — the nested-class emission tier of the ADR-16
      # macro substrate. Where Tier C ({HeredocTemplate}) synthesises
      # *methods* on the calling class, this tier synthesises *nested
      # subclasses* declared by an enum-shaped block DSL.
      #
      # Motivating shape — Mangrove's `Enum`:
      #
      #     class Shape
      #       extend Mangrove::Enum
      #       variants do
      #         variant Circle, Float
      #         variant Rectangle, Float
      #       end
      #     end
      #
      # Each `variant <Const>, <Type>` row is meant to mint a nested
      # subclass `Shape::Circle < Shape` carrying `#inner : <Type>`.
      # Mangrove builds this at runtime via `const_missing` +
      # `class_eval`; the substrate replays the same contract
      # statically so `Shape::Circle.new(1.0).inner` resolves the
      # payload to `Float` instead of `call.undefined-constant` /
      # `Dynamic[Top]`.
      #
      # ## Authoring shape
      #
      #     nested_class_templates: [
      #       Rigor::Plugin::Macro::NestedClassTemplate.new(
      #         receiver_constraint: "Mangrove::Enum", # `extend`-ed marker module
      #         block_method: :variants,               # the enclosing DSL block
      #         variant_method: :variant,              # each declaration call
      #         symbol_arg_position: 0,                  # constant arg → nested class
      #         inner_arg_position: 1,                 # type arg → `#inner` return
      #         inner_reader: :inner                   # the payload reader name
      #       )
      #     ]
      #
      # ## Fields
      #
      # - `receiver_constraint` — fully-qualified module name (String)
      #   the enclosing class must `extend` for the block to be
      #   recognised (e.g. `"Mangrove::Enum"`).
      # - `block_method` — Symbol naming the enclosing DSL block
      #   (`:variants`).
      # - `variant_method` — Symbol naming each declaration call
      #   inside the block (`:variant`).
      # - `symbol_arg_position` — Integer (default 0): the argument
      #   index whose literal **constant** names the nested subclass.
      #   (Named `name_arg_position:` before ADR-60 WD2 normalised
      #   the macro value-object vocabulary.)
      # - `inner_arg_position` — Integer (default 1): the argument
      #   index whose type expression becomes the `#inner` reader's
      #   return type. Slice A resolves a constant type argument
      #   (`Float`, `String`); non-constant inner shapes (shape
      #   hashes) degrade to `Dynamic[Top]`.
      # - `inner_reader` — Symbol (default `:inner`): the payload
      #   reader synthesised on each variant subclass.
      #
      # ## Floor / ceiling per ADR-16 WD13 + ADR-36 WD4
      #
      # Slice A ships the floor: each variant constant resolves as a
      # class (so `<Variant>.new(...)` and the constant reference
      # type), and the `#inner` reader resolves to the declared inner
      # type. The `sealed`-parent fact + `is_a?` cross-variant
      # exhaustive narrowing (ADR-36 WD3) is the ceiling, deferred —
      # it needs the synthetic-class hierarchy threaded into
      # `Environment#class_ordering`.
      class NestedClassTemplate
        attr_reader :receiver_constraint, :block_method, :variant_method,
                    :symbol_arg_position, :inner_arg_position, :inner_reader

        def initialize(receiver_constraint:, block_method: :variants, variant_method: :variant,
                       symbol_arg_position: 0, inner_arg_position: 1, inner_reader: :inner)
          validate_constraint!(receiver_constraint)
          validate_method!(block_method, "block_method")
          validate_method!(variant_method, "variant_method")
          validate_position!(symbol_arg_position, "symbol_arg_position")
          validate_position!(inner_arg_position, "inner_arg_position")
          validate_method!(inner_reader, "inner_reader")

          @receiver_constraint = receiver_constraint.dup.freeze
          @block_method = block_method.to_sym
          @variant_method = variant_method.to_sym
          @symbol_arg_position = symbol_arg_position
          @inner_arg_position = inner_arg_position
          @inner_reader = inner_reader.to_sym
          freeze
        end

        def to_h
          {
            "receiver_constraint" => receiver_constraint,
            "block_method" => block_method.to_s,
            "variant_method" => variant_method.to_s,
            "symbol_arg_position" => symbol_arg_position,
            "inner_arg_position" => inner_arg_position,
            "inner_reader" => inner_reader.to_s
          }
        end

        def ==(other)
          other.is_a?(NestedClassTemplate) && to_h == other.to_h
        end
        alias eql? ==

        def hash
          to_h.hash
        end

        private

        def validate_constraint!(value)
          return if value.is_a?(String) && !value.empty?

          raise ArgumentError,
                "Plugin::Macro::NestedClassTemplate#receiver_constraint must be a non-empty String, " \
                "got #{value.inspect}"
        end

        def validate_method!(value, label)
          return if value.is_a?(Symbol) || (value.is_a?(String) && !value.empty?)

          raise ArgumentError,
                "Plugin::Macro::NestedClassTemplate##{label} must be a Symbol or non-empty String, " \
                "got #{value.inspect}"
        end

        def validate_position!(value, label)
          return if value.is_a?(Integer) && value >= 0

          raise ArgumentError,
                "Plugin::Macro::NestedClassTemplate##{label} must be a non-negative Integer, " \
                "got #{value.inspect}"
        end
      end
    end
  end
end
