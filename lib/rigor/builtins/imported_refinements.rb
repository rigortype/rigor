# frozen_string_literal: true

require "strscan"

require_relative "../type"

module Rigor
  module Builtins
    # Canonical-name registry for the imported-built-in
    # refinement catalogue. See `imported-built-in-types.md`
    # in `docs/type-specification/` for the full catalogue
    # rationale and the kebab-case naming rule.
    #
    # Maps kebab-case names (`non-empty-string`, `positive-int`,
    # `non-empty-array`, …) to the Rigor type each name denotes.
    # The registry is the single integration point for:
    #
    # - The `rigor:v1:return:` RBS::Extended directive
    #   ([`Rigor::RbsExtended.read_return_type_override`](../rbs_extended.rb)),
    #   which overrides a method's RBS-declared return type
    #   with a refinement carrier.
    # - Future `RBS::Extended` directives that accept a
    #   refinement name in any type position (`param:`,
    #   `assert: x is non-empty-string`, …).
    # - The display side: `Type::Difference#describe` already
    #   recognises the same shapes and prints the kebab-case
    #   spelling without consulting the registry.
    #
    # Names not in the registry resolve to `nil`; callers
    # decide whether to fall back to the RBS-declared type or
    # raise a parse error.
    #
    # The registry covers two surfaces:
    #
    # - **No-argument refinement names** (`non-empty-string`,
    #   `non-zero-int`, `lowercase-string`, …) live in `REGISTRY`
    #   and resolve through `lookup(name)`.
    # - **Parameterised refinement payloads** (`non-empty-array[Integer]`,
    #   `non-empty-hash[Symbol, Integer]`, `int<5, 10>`) are
    #   accepted by `parse(payload)`. The full grammar is documented
    #   on `Parser`. The two surfaces share `REGISTRY` for the
    #   no-arg head names; the parameterised head names live in
    #   `PARAMETERISED_TYPE_BUILDERS` (square-bracket form, type
    #   args) and `PARAMETERISED_INT_BUILDERS` (angle-bracket form,
    #   integer bounds).
    module ImportedRefinements
      REGISTRY = {
        "non-empty-string" => -> { Type::Combinator.non_empty_string },
        "non-zero-int" => -> { Type::Combinator.non_zero_int },
        "non-empty-array" => -> { Type::Combinator.non_empty_array },
        "non-empty-hash" => -> { Type::Combinator.non_empty_hash },
        "positive-int" => -> { Type::Combinator.positive_int },
        "non-negative-int" => -> { Type::Combinator.non_negative_int },
        "negative-int" => -> { Type::Combinator.negative_int },
        "non-positive-int" => -> { Type::Combinator.non_positive_int },
        "lowercase-string" => -> { Type::Combinator.lowercase_string },
        "uppercase-string" => -> { Type::Combinator.uppercase_string },
        "numeric-string" => -> { Type::Combinator.numeric_string },
        "decimal-int-string" => -> { Type::Combinator.decimal_int_string },
        "octal-int-string" => -> { Type::Combinator.octal_int_string },
        "hex-int-string" => -> { Type::Combinator.hex_int_string }
      }.freeze
      private_constant :REGISTRY

      # `name[T]` / `name[K, V]` — type-arg parameterised
      # refinements. Each builder takes an `Array<Rigor::Type>`
      # and returns a `Rigor::Type` (or `nil` on arity / shape
      # mismatch so the caller surfaces a parse failure).
      PARAMETERISED_TYPE_BUILDERS = {
        "non-empty-array" => lambda { |args|
          return nil unless args.size == 1

          Type::Combinator.non_empty_array(args.first)
        },
        "non-empty-hash" => lambda { |args|
          return nil unless args.size == 2

          Type::Combinator.non_empty_hash(args[0], args[1])
        }
      }.freeze
      private_constant :PARAMETERISED_TYPE_BUILDERS

      # `name<min, max>` — integer-bound parameterised
      # refinements. Each builder takes an `Array<Integer>` and
      # returns a `Rigor::Type` (or `nil`). Bounds are signed
      # integer literals; `min` MUST be ≤ `max` for the carrier
      # to construct successfully (`Type::IntegerRange` enforces
      # the invariant).
      PARAMETERISED_INT_BUILDERS = {
        "int" => lambda { |bounds|
          return nil unless bounds.size == 2

          Type::Combinator.integer_range(bounds[0], bounds[1])
        }
      }.freeze
      private_constant :PARAMETERISED_INT_BUILDERS

      module_function

      # @param name [String] kebab-case refinement name.
      # @return [Rigor::Type, nil] the matching refinement
      #   carrier, or `nil` if the name is not registered.
      def lookup(name)
        builder = REGISTRY[name.to_s]
        builder&.call
      end

      # @param payload [String] the trailing payload of a
      #   `rigor:v1:return:` (or sibling) directive. Accepts
      #   the bare-name forms `lookup` already handles plus the
      #   parameterised forms documented on {Parser}.
      # @return [Rigor::Type, nil] the resolved refinement
      #   carrier, or `nil` when the payload is unparseable or
      #   names a refinement / class not in the registry.
      def parse(payload)
        Parser.new(payload.to_s).parse
      end

      def known?(name)
        REGISTRY.key?(name.to_s) ||
          PARAMETERISED_TYPE_BUILDERS.key?(name.to_s) ||
          PARAMETERISED_INT_BUILDERS.key?(name.to_s)
      end

      def known_names
        REGISTRY.keys + PARAMETERISED_TYPE_BUILDERS.keys + PARAMETERISED_INT_BUILDERS.keys
      end

      # Recursive-descent parser for the refinement-payload
      # grammar:
      #
      #   type        := simple_name | parametric
      #   simple_name := /[a-z][a-z0-9-]*/
      #   parametric  := simple_name '[' type_arg_list ']'
      #                | simple_name '<' int_bound_list '>'
      #   type_arg_list := type_arg (',' type_arg)*
      #   type_arg    := type | class_name
      #   class_name  := /[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*/
      #   int_bound_list := signed_int (',' signed_int)*
      #   signed_int  := /-?\d+/
      #
      # Whitespace between tokens is ignored. The parser fails
      # soft (returns `nil` from `parse`) on any deviation so the
      # `RBS::Extended` directive site can fall back to the
      # RBS-declared type rather than crash on a typo.
      class Parser
        def initialize(input)
          @scanner = StringScanner.new(input.strip)
        end

        def parse
          type = parse_type
          return nil if type.nil?
          return nil unless @scanner.eos?

          type
        end

        private

        SIMPLE_NAME = /[a-z][a-z0-9-]*/
        CLASS_NAME = /[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*/
        SIGNED_INT = /-?\d+/
        private_constant :SIMPLE_NAME, :CLASS_NAME, :SIGNED_INT

        def parse_type
          name = @scanner.scan(SIMPLE_NAME)
          return nil if name.nil?

          case @scanner.peek(1)
          when "[" then parse_parametric_type_args(name)
          when "<" then parse_parametric_int_bounds(name)
          else          ImportedRefinements.lookup(name)
          end
        end

        def parse_parametric_type_args(name)
          builder = PARAMETERISED_TYPE_BUILDERS[name]
          return nil if builder.nil?

          @scanner.getch # consume '['
          args = parse_type_arg_list
          return nil if args.nil?
          return nil unless @scanner.getch == "]"

          builder.call(args)
        end

        def parse_parametric_int_bounds(name)
          builder = PARAMETERISED_INT_BUILDERS[name]
          return nil if builder.nil?

          @scanner.getch # consume '<'
          bounds = parse_int_bound_list
          return nil if bounds.nil?
          return nil unless @scanner.getch == ">"

          builder.call(bounds)
        end

        def parse_type_arg_list
          collect_separated_list { parse_type_arg }
        end

        def parse_int_bound_list
          collect_separated_list { parse_int_bound }
        end

        def collect_separated_list
          items = []
          loop do
            skip_ws
            item = yield
            return nil if item.nil?

            items << item
            skip_ws
            break unless @scanner.peek(1) == ","

            @scanner.getch # consume ','
          end
          items
        end

        def parse_type_arg
          skip_ws
          if (class_name = @scanner.scan(CLASS_NAME))
            Type::Combinator.nominal_of(class_name)
          else
            parse_type
          end
        end

        def parse_int_bound
          skip_ws
          literal = @scanner.scan(SIGNED_INT)
          return nil if literal.nil?

          Integer(literal)
        end

        def skip_ws
          @scanner.skip(/\s+/)
        end
      end
      private_constant :Parser
    end
  end
end
