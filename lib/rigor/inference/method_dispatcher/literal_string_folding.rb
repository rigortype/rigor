# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # Dispatcher tier that lifts string-composition results into the `literal-string` carrier when every
      # operand is itself literal-bearing. Sits between {ConstantFolding} (which handles all-Constant cases)
      # and {ShapeDispatch}; runs for:
      #
      # - `String#+` / `String#*` / `String#<<` / `String#concat` on string-typed receivers whose inputs
      #   the ConstantFolding tier could not fold to a precise `Constant<String>` (e.g. one operand is
      #   `literal-string` rather than `Constant<String>`, or the multiplication exceeds the constant-fold
      #   size cap).
      # - `Array#join` on `Tuple[…]` receivers whose every element plus the separator argument (when given)
      #   is literal-bearing.
      # - `String#%` (literal-bearing receiver) when every value argument is literal-bearing or a
      #   Type::Constant of any value. (`Kernel#format` / `Kernel#sprintf` moved to {KernelDispatch} in
      #   ADR-91 WD2 — they are Kernel module functions, not receiver-typed String methods.)
      #
      # Result rule:
      #
      # - `+`, `<<`, `concat`: receiver and argument MUST both be
      #   `Type::Combinator.literal_string_compatible?`. The result is `literal-string`. `<<` and `concat`
      #   mutate the receiver at runtime; the analyzer does not track that mutation against the local's
      #   binding, but the call's *return value* is the receiver itself, and the receiver stays
      #   literal-bearing because every appended slice was literal-bearing too.
      # - `*`: receiver MUST be literal-bearing; argument MUST be integer-typed. The result is
      #   `literal-string`.
      # - `join`: receiver MUST be `Tuple[…]` with every element literal-string-compatible; the optional
      #   separator argument MUST also be literal-string-compatible. Result: `literal-string`. Empty
      #   `Tuple[]` lifts too — `[].join` is the empty string at runtime, which is literal-bearing
      #   trivially.
      #
      # Other receiver / argument shapes decline so the next tier (ShapeDispatch / FileFolding /
      # RbsDispatch) takes over and the call site widens to the RBS-declared `Nominal[String]` as before.
      module LiteralStringFolding
        module_function

        CONCAT_METHODS = %i[+ << concat].freeze
        # v0.1.1 Track 1 slice 5a — methods that, called with no arguments on a literal-bearing receiver,
        # return a value that is also literal-bearing. `#strip` / `#lstrip` / `#rstrip` / `#chomp` (no-arg)
        # / `#chop` strip a known subset of characters from the ends, so the survivors are always a
        # substring of an already-literal value. `#scrub` (no-arg) replaces invalid bytes; a literal-string
        # value comes from source code and is always valid UTF-8, so the result is identical to the
        # receiver. None of these preserve `non-empty-string`-ness (e.g. `"   ".strip == ""`); the carrier
        # collapses from `non-empty-literal-string` down to plain `literal-string`.
        LITERAL_PRESERVING_METHODS = %i[strip lstrip rstrip chomp chop scrub].freeze
        # Methods that preserve literal-bearing AND non-empty-string-ness. Unlike `LITERAL_PRESERVING_METHODS`
        # (strip/chomp/etc.) these do not reduce the string — they transform characters without removing
        # any, so a non-empty receiver stays non-empty.
        NON_EMPTY_LITERAL_PRESERVING_METHODS = %i[upcase downcase capitalize swapcase reverse].freeze
        # v0.1.1 Track 1 slice 5c — width-padding methods. `center` / `ljust` / `rjust` take a `width`
        # Integer plus an optional literal padding `String`. When the receiver and the (default or
        # supplied) padding are both literal-bearing, the result is literal-bearing too.
        WIDTH_PADDING_METHODS = %i[center ljust rjust].freeze
        private_constant :CONCAT_METHODS,
                         :LITERAL_PRESERVING_METHODS, :NON_EMPTY_LITERAL_PRESERVING_METHODS,
                         :WIDTH_PADDING_METHODS

        def try_dispatch(context)
          receiver = context.receiver
          method_name = context.method_name
          args = context.args
          return fold_array_join(receiver, args) if method_name == :join
          return nil unless Type::Combinator.literal_string_compatible?(receiver)
          return fold_string_percent(args) if method_name == :%
          return fold_no_arg(receiver, method_name) if args.empty?
          return fold_width_pad(args) if WIDTH_PADDING_METHODS.include?(method_name)
          return nil unless args.size == 1

          if CONCAT_METHODS.include?(method_name)
            fold_concat(receiver, args.first)
          elsif method_name == :*
            fold_repeat(receiver, args.first)
          end
        end

        def fold_no_arg(receiver, method_name)
          return Type::Combinator.literal_string if LITERAL_PRESERVING_METHODS.include?(method_name)
          return non_empty_literal_result(receiver) if NON_EMPTY_LITERAL_PRESERVING_METHODS.include?(method_name)

          nil
        end

        # `String#center` / `#ljust` / `#rjust` — first argument is the target width (Integer-typed),
        # optional second argument is the padding string (must be literal-bearing for the result to stay
        # literal). The default padding (a space) is always literal so the no-second-arg form passes
        # through. Width is allowed to be any Integer because Ruby's runtime accepts negative widths and
        # widths smaller than the receiver's length without raising.
        def fold_width_pad(args)
          return nil unless [1, 2].include?(args.size)
          return nil unless integer_typed?(args[0])
          return nil if args.size == 2 && !Type::Combinator.literal_string_compatible?(args[1])

          Type::Combinator.literal_string
        end

        def fold_concat(receiver, arg)
          return nil unless Type::Combinator.literal_string_compatible?(arg)

          if Type::Combinator.non_empty_string_compatible?(receiver) ||
             Type::Combinator.non_empty_string_compatible?(arg)
            return Type::Combinator.non_empty_literal_string
          end

          Type::Combinator.literal_string
        end

        def fold_repeat(receiver, arg)
          return nil unless integer_typed?(arg)
          return nil if known_negative_integer?(arg)
          return Type::Combinator.constant_of("") if known_zero_integer?(arg)

          if Type::Combinator.non_empty_string_compatible?(receiver) && known_positive_integer?(arg)
            return Type::Combinator.non_empty_literal_string
          end

          Type::Combinator.literal_string
        end

        # Returns `non_empty_literal_string` when the receiver is provably non-empty; otherwise collapses
        # to plain `literal_string`.
        def non_empty_literal_result(receiver)
          if Type::Combinator.non_empty_string_compatible?(receiver)
            Type::Combinator.non_empty_literal_string
          else
            Type::Combinator.literal_string
          end
        end

        # `[lit, lit].join(sep)` — receiver must be a Tuple whose every element is literal-bearing;
        # separator (when given) must be literal-bearing too. Multi-arg forms / `Array#join(*args)` splat
        # shapes don't reach here because the dispatcher only routes through this tier when the call
        # resolves to a single named method.
        def fold_array_join(receiver, args)
          return nil unless receiver.is_a?(Type::Tuple)
          return nil unless receiver.elements.all? { |el| Type::Combinator.literal_string_compatible?(el) }
          return nil unless args.size <= 1
          return nil if args.size == 1 && !Type::Combinator.literal_string_compatible?(args.first)
          # Defer to {ShapeDispatch}'s `tuple_join` when the precise `Constant<String>` fold is reachable —
          # every element is a `Constant` and the separator is absent or a `Constant<String>`. This tier runs
          # AHEAD of ShapeDispatch, so returning the generic `literal-string` here would shadow that strictly
          # more precise result (`["a", "b"].join("-")` → `Constant<"a-b">` rather than `literal-string`).
          # Mixed tuples that carry a non-`Constant` `literal-string` element keep folding to `literal-string`
          # here, because no exact value is knowable for them.
          return nil if constant_join_reachable?(receiver, args)

          Type::Combinator.literal_string
        end

        # True when every tuple element is a `Constant` and the separator is absent or a `Constant<String>` —
        # exactly the inputs for which `ShapeDispatch.tuple_join` materialises a precise `Constant<String>`.
        # An empty tuple qualifies (`[].join` → `Constant<"">`). Callers have already verified every element
        # is literal-string-compatible, so a `Constant` element is necessarily a `Constant<String>`.
        def constant_join_reachable?(receiver, args)
          return false unless receiver.elements.all?(Type::Constant)
          return true if args.empty?

          arg = args.first
          arg.is_a?(Type::Constant) && arg.value.is_a?(String)
        end

        # `"foo %s" % "x"` / `"foo %s" % ["x", "y"]` — receiver is the template (already verified
        # literal-bearing by the caller); arg is either:
        #
        # - a single literal-bearing string / Constant value, or
        # - a Tuple whose every element is literal-bearing or a Constant.
        #
        # Hash-form `%` (e.g. `"%{name}" % {name: "x"}`) is not yet folded — the analyzer's HashShape
        # carrier could support this, but the v0.0.x catalogue declines and widens to Nominal[String].
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

        # `String#*` raises ArgumentError on a negative multiplier, so a `Constant<-1>` argument is not a
        # valid lift target. Decline so the call site keeps the existing nil-result behaviour rather than
        # promising a `literal-string` value that could never exist at runtime.
        def known_negative_integer?(type)
          type.is_a?(Type::Constant) && type.value.is_a?(Integer) && type.value.negative?
        end

        def known_zero_integer?(type)
          case type
          when Type::Constant then type.value.is_a?(Integer) && type.value.zero?
          when Type::IntegerRange then type.lower.zero? && type.upper.zero?
          else false
          end
        end

        def known_positive_integer?(type)
          case type
          when Type::Constant then type.value.is_a?(Integer) && type.value.positive?
          when Type::IntegerRange then type.lower >= 1
          else false
          end
        end

        private_class_method :fold_no_arg, :fold_concat, :fold_repeat, :fold_array_join,
                             :constant_join_reachable?,
                             :fold_string_percent, :fold_width_pad,
                             :non_empty_literal_result, :literal_or_constant?,
                             :integer_typed?, :known_negative_integer?,
                             :known_zero_integer?, :known_positive_integer?
      end
    end
  end
end
