# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # Dispatcher tier that lifts string-composition results into
      # the `literal-string` carrier when every operand is itself
      # literal-bearing. Sits between {ConstantFolding} (which
      # handles all-Constant cases) and {ShapeDispatch}; runs for:
      #
      # - `String#+` / `String#*` / `String#<<` / `String#concat`
      #   on string-typed receivers whose inputs the
      #   ConstantFolding tier could not fold to a precise
      #   `Constant<String>` (e.g. one operand is `literal-string`
      #   rather than `Constant<String>`, or the multiplication
      #   exceeds the constant-fold size cap).
      # - `Array#join` on `Tuple[…]` receivers whose every element
      #   plus the separator argument (when given) is
      #   literal-bearing.
      # - `Kernel#format` / `Kernel#sprintf` (any receiver) and
      #   `String#%` (literal-bearing receiver) when every value
      #   argument is literal-bearing or a Type::Constant of any
      #   value.
      #
      # Result rule:
      #
      # - `+`, `<<`, `concat`: receiver and argument MUST both be
      #   `Type::Combinator.literal_string_compatible?`. The result
      #   is `literal-string`. `<<` and `concat` mutate the
      #   receiver at runtime; the analyzer does not track that
      #   mutation against the local's binding, but the call's
      #   *return value* is the receiver itself, and the receiver
      #   stays literal-bearing because every appended slice was
      #   literal-bearing too.
      # - `*`: receiver MUST be literal-bearing; argument MUST be
      #   integer-typed. The result is `literal-string`.
      # - `join`: receiver MUST be `Tuple[…]` with every element
      #   literal-string-compatible; the optional separator
      #   argument MUST also be literal-string-compatible.
      #   Result: `literal-string`. Empty `Tuple[]` lifts too —
      #   `[].join` is the empty string at runtime, which is
      #   literal-bearing trivially.
      #
      # Other receiver / argument shapes decline so the next tier
      # (ShapeDispatch / FileFolding / RbsDispatch) takes over and
      # the call site widens to the RBS-declared `Nominal[String]`
      # as before.
      module LiteralStringFolding
        module_function

        CONCAT_METHODS = %i[+ << concat].freeze
        FORMAT_METHODS = %i[format sprintf].freeze
        # v0.1.1 Track 1 slice 5a — methods that, called with no
        # arguments on a literal-bearing receiver, return a value
        # that is also literal-bearing. `#strip` / `#lstrip` /
        # `#rstrip` / `#chomp` (no-arg) / `#chop` strip a known
        # subset of characters from the ends, so the survivors
        # are always a substring of an already-literal value.
        # `#scrub` (no-arg) replaces invalid bytes; a literal-string
        # value comes from source code and is always valid UTF-8,
        # so the result is identical to the receiver. None of
        # these preserve `non-empty-string`-ness (e.g. `"   ".strip
        # == ""`); the carrier collapses from `non-empty-literal-string`
        # down to plain `literal-string`.
        LITERAL_PRESERVING_METHODS = %i[strip lstrip rstrip chomp chop scrub].freeze
        # v0.1.1 Track 1 slice 5c — width-padding methods. `center`
        # / `ljust` / `rjust` take a `width` Integer plus an
        # optional literal padding `String`. When the receiver
        # and the (default or supplied) padding are both
        # literal-bearing, the result is literal-bearing too.
        WIDTH_PADDING_METHODS = %i[center ljust rjust].freeze
        private_constant :CONCAT_METHODS, :FORMAT_METHODS,
                         :LITERAL_PRESERVING_METHODS, :WIDTH_PADDING_METHODS

        def try_dispatch(receiver:, method_name:, args:, **)
          return fold_array_join(receiver, args) if method_name == :join
          return fold_format(args) if FORMAT_METHODS.include?(method_name)

          return nil unless Type::Combinator.literal_string_compatible?(receiver)

          return fold_string_percent(args) if method_name == :%
          if args.empty?
            return LITERAL_PRESERVING_METHODS.include?(method_name) ? Type::Combinator.literal_string : nil
          end
          return fold_width_pad(args) if WIDTH_PADDING_METHODS.include?(method_name)
          return nil unless args.size == 1

          if CONCAT_METHODS.include?(method_name)
            fold_concat(args.first)
          elsif method_name == :*
            fold_repeat(args.first)
          end
        end

        # `String#center` / `#ljust` / `#rjust` — first argument is
        # the target width (Integer-typed), optional second
        # argument is the padding string (must be literal-bearing
        # for the result to stay literal). The default padding
        # (a space) is always literal so the no-second-arg form
        # passes through. Width is allowed to be any Integer
        # because Ruby's runtime accepts negative widths and
        # widths smaller than the receiver's length without
        # raising.
        def fold_width_pad(args)
          return nil unless [1, 2].include?(args.size)
          return nil unless integer_typed?(args[0])
          return nil if args.size == 2 && !Type::Combinator.literal_string_compatible?(args[1])

          Type::Combinator.literal_string
        end

        def fold_concat(arg_type)
          return nil unless Type::Combinator.literal_string_compatible?(arg_type)

          Type::Combinator.literal_string
        end

        def fold_repeat(arg_type)
          return nil unless integer_typed?(arg_type)
          return nil if known_negative_integer?(arg_type)

          Type::Combinator.literal_string
        end

        # `[lit, lit].join(sep)` — receiver must be a Tuple
        # whose every element is literal-bearing; separator
        # (when given) must be literal-bearing too. Multi-arg
        # forms / `Array#join(*args)` splat shapes don't reach
        # here because the dispatcher only routes through this
        # tier when the call resolves to a single named method.
        def fold_array_join(receiver, args)
          return nil unless receiver.is_a?(Type::Tuple)
          return nil unless receiver.elements.all? { |el| Type::Combinator.literal_string_compatible?(el) }
          return nil unless args.size <= 1
          return nil if args.size == 1 && !Type::Combinator.literal_string_compatible?(args.first)

          Type::Combinator.literal_string
        end

        # `format("hello %s", lit)` / `sprintf(...)` — template
        # plus every value argument must be literal-bearing
        # ({Type::Combinator.literal_string_compatible?}) or a
        # `Type::Constant` of any value (Constants are always
        # provably literal). The template arg specifically must
        # be literal-bearing — a Constant<Integer> first arg
        # would not be a valid format template, so the
        # `Type::Constant` allowance applies only to subsequent
        # value args.
        def fold_format(args)
          return nil if args.empty?
          return nil unless Type::Combinator.literal_string_compatible?(args.first)
          return nil unless args.drop(1).all? { |arg| literal_or_constant?(arg) }

          Type::Combinator.literal_string
        end

        # `"foo %s" % "x"` / `"foo %s" % ["x", "y"]` — receiver
        # is the template (already verified literal-bearing by
        # the caller); arg is either:
        #
        # - a single literal-bearing string / Constant value, or
        # - a Tuple whose every element is literal-bearing or a
        #   Constant.
        #
        # Hash-form `%` (e.g. `"%{name}" % {name: "x"}`) is not
        # yet folded — the analyzer's HashShape carrier could
        # support this, but the v0.0.x catalogue declines and
        # widens to Nominal[String].
        def fold_string_percent(args)
          return nil unless args.size == 1

          arg = args.first
          if arg.is_a?(Type::Tuple)
            return nil unless arg.elements.all? { |el| literal_or_constant?(el) }

            return Type::Combinator.literal_string
          end

          return nil unless literal_or_constant?(arg)

          Type::Combinator.literal_string
        end

        def literal_or_constant?(type)
          Type::Combinator.literal_string_compatible?(type) || type.is_a?(Type::Constant)
        end

        def integer_typed?(type)
          case type
          when Type::Constant then type.value.is_a?(Integer)
          when Type::Nominal then type.class_name == "Integer"
          when Type::IntegerRange then true
          else false
          end
        end

        # `String#*` raises ArgumentError on a negative multiplier, so a
        # `Constant<-1>` argument is not a valid lift target. Decline so
        # the call site keeps the existing nil-result behaviour rather
        # than promising a `literal-string` value that could never
        # exist at runtime.
        def known_negative_integer?(type)
          type.is_a?(Type::Constant) && type.value.is_a?(Integer) && type.value.negative?
        end

        private_class_method :fold_concat, :fold_repeat, :fold_array_join,
                             :fold_format, :fold_string_percent, :fold_width_pad,
                             :literal_or_constant?, :integer_typed?
      end
    end
  end
end
