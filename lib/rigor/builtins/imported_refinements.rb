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
        "non-lowercase-string" => -> { Type::Combinator.non_lowercase_string },
        "uppercase-string" => -> { Type::Combinator.uppercase_string },
        "non-uppercase-string" => -> { Type::Combinator.non_uppercase_string },
        "numeric-string" => -> { Type::Combinator.numeric_string },
        "non-numeric-string" => -> { Type::Combinator.non_numeric_string },
        "decimal-int-string" => -> { Type::Combinator.decimal_int_string },
        "octal-int-string" => -> { Type::Combinator.octal_int_string },
        "hex-int-string" => -> { Type::Combinator.hex_int_string },
        "non-empty-lowercase-string" => -> { Type::Combinator.non_empty_lowercase_string },
        "non-empty-uppercase-string" => -> { Type::Combinator.non_empty_uppercase_string },
        "literal-string" => -> { Type::Combinator.literal_string },
        "non-empty-literal-string" => -> { Type::Combinator.non_empty_literal_string }
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
        },
        # v0.0.7 — `key_of[T]` and `value_of[T]` type functions.
        # Each takes a single type argument and projects the
        # known-keys (resp. known-values) union out of `T`. See
        # `Type::Combinator.key_of` for the per-shape projection
        # rules. Use `lower_snake` per the
        # imported-built-in-types.md type-function naming rule.
        "key_of" => lambda { |args|
          return nil unless args.size == 1

          Type::Combinator.key_of(args.first)
        },
        "value_of" => lambda { |args|
          return nil unless args.size == 1

          Type::Combinator.value_of(args.first)
        },
        # `int_mask[1, 2, 4]` — every integer representable by
        # a bitwise OR over the listed flags. Each arg must be a
        # `Constant<Integer>`; the parser wraps integer literals
        # for this purpose. Builder declines on any non-integer
        # arg.
        "int_mask" => lambda { |args|
          flags = args.map { |arg| arg.is_a?(Type::Constant) && arg.value.is_a?(Integer) ? arg.value : nil }
          return nil if flags.any?(&:nil?)

          Type::Combinator.int_mask(flags)
        },
        # `int_mask_of[T]` — derives the closure from a finite
        # integer literal type (single Constant<Integer> or a
        # Union of them).
        "int_mask_of" => lambda { |args|
          return nil unless args.size == 1

          Type::Combinator.int_mask_of(args.first)
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
      # @param name_scope [Rigor::TypeNode::NameScope, nil]
      #   ADR-13 slice 3 — when provided, the parser consults the
      #   scope's `#resolver` chain after the built-in registry
      #   and built-in parametric forms but before the RBS Nominal
      #   fallback. `nil` (default) preserves the slice-1 / slice-2
      #   behaviour of consulting only built-ins + RBS.
      # @return [Rigor::Type, nil] the resolved refinement
      #   carrier, or `nil` when the payload is unparseable or
      #   names a refinement / class no registered source resolved.
      def parse(payload, name_scope: nil)
        Parser.new(payload.to_s, name_scope: name_scope).parse
      end

      # Builder helpers reachable from the Resolver. They live on
      # the module so the Resolver does not have to import the
      # `private_constant` builder hashes.
      def parametric_type_builder(name)
        PARAMETERISED_TYPE_BUILDERS[name]
      end

      def parametric_int_builder(name)
        PARAMETERISED_INT_BUILDERS[name]
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
      #
      # ADR-13 slice 3 split the original "scan + resolve" loop
      # into two passes: the parser emits a {Rigor::TypeNode} AST,
      # and a sibling {Resolver} walks the AST to produce a
      # {Rigor::Type} carrier — consulting the built-in registry,
      # the plugin {Rigor::TypeNode::ResolverChain}, and finally
      # the RBS Nominal fallback in that order. Plugin resolvers
      # never see partial parses.
      class Parser # rubocop:disable Metrics/ClassLength
        def initialize(input, name_scope: nil)
          @scanner = StringScanner.new(input.strip)
          @resolver = Resolver.new(name_scope: name_scope)
        end

        def parse
          ast = parse_type_ast
          return nil if ast.nil?

          # v0.0.7 — trailing `[K]` indexed-access projects into
          # the parsed type. Multiple `[K]` segments chain
          # (`Tuple[A, B, C][1][0]`). Each segment wraps the
          # previous AST in an {IndexedAccess} node so the chain
          # composes cleanly through the resolver pass.
          ast = parse_indexed_access_chain_ast(ast)
          return nil if ast.nil?
          return nil unless @scanner.eos?

          @resolver.resolve_ast(ast)
        end

        private

        # Refinement names use kebab-case (`non-empty-string`),
        # type-function names use lower_snake (`key_of`,
        # `value_of`, `int_mask`). The regex accepts both shapes;
        # the registry lookup decides which family the name
        # belongs to.
        SIMPLE_NAME = /[a-z][a-z0-9_-]*/
        CLASS_NAME = /[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*/
        SIGNED_INT = /-?\d+/
        private_constant :SIMPLE_NAME, :CLASS_NAME, :SIGNED_INT

        def parse_type_ast
          if (class_name = @scanner.scan(CLASS_NAME))
            return parse_class_arg_tail_ast(class_name)
          end

          name = @scanner.scan(SIMPLE_NAME)
          return nil if name.nil?

          case @scanner.peek(1)
          when "[" then parse_bracket_args_ast(name)
          when "<" then parse_angle_bounds_ast(name)
          else          TypeNode::Identifier.new(name: name)
          end
        end

        def parse_indexed_access_chain_ast(ast)
          loop do
            skip_ws
            break unless @scanner.peek(1) == "["

            @scanner.getch
            args = parse_type_arg_list_ast
            return nil if args.nil? || args.size != 1
            return nil unless @scanner.getch == "]"

            ast = TypeNode::IndexedAccess.new(receiver: ast, key: args.first)
          end
          ast
        end

        def parse_bracket_args_ast(name)
          @scanner.getch # consume '['
          args = parse_type_arg_list_ast
          return nil if args.nil?
          return nil unless @scanner.getch == "]"

          TypeNode::Generic.new(head: name, args: args)
        end

        def parse_angle_bounds_ast(name)
          @scanner.getch # consume '<'
          bounds = parse_int_bound_list
          return nil if bounds.nil?
          return nil unless @scanner.getch == ">"

          TypeNode::Generic.new(
            head: name,
            args: bounds.map { |b| TypeNode::IntegerLiteral.new(value: b) }
          )
        end

        def parse_type_arg_list_ast
          collect_separated_list { parse_type_arg_ast }
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

        def parse_type_arg_ast
          skip_ws
          if (class_name = @scanner.scan(CLASS_NAME))
            parse_class_arg_tail_ast(class_name)
          elsif (literal = @scanner.scan(SIGNED_INT))
            TypeNode::IntegerLiteral.new(value: Integer(literal))
          else
            parse_type_ast
          end
        end

        # Class-name-headed type argument with optional `[T_1,
        # …]` type-args tail. Used so `key_of[Hash[Symbol,
        # Integer]]` parses as the projection of a parameterised
        # nominal carrier rather than rejecting the inner brackets.
        def parse_class_arg_tail_ast(class_name)
          return TypeNode::Identifier.new(name: class_name) unless @scanner.peek(1) == "["

          @scanner.getch # consume '['
          args = parse_type_arg_list_ast
          return nil if args.nil?
          return nil unless @scanner.getch == "]"

          TypeNode::Generic.new(head: class_name, args: args)
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

      # AST → {Rigor::Type} resolver. ADR-13's resolution order
      # for every named-type production:
      #
      #   1. Built-in `ImportedRefinements.lookup` (no-arg
      #      refinements like `non-empty-string`).
      #   2. Built-in parametric builders
      #      (`PARAMETERISED_TYPE_BUILDERS` for `[...]` forms,
      #      `PARAMETERISED_INT_BUILDERS` for `<...>` forms).
      #   3. Plugin resolver chain from the supplied
      #      {Rigor::TypeNode::NameScope}, if any.
      #   4. RBS Nominal fallback for class-shaped names
      #      (PascalCase head, with or without type args).
      #
      # Returns `nil` when every step declined — preserves the
      # parser's fail-soft contract so callers fall back to the
      # RBS-declared type instead of raising.
      class Resolver
        def initialize(name_scope: nil)
          @name_scope = name_scope
        end

        def resolve_ast(node)
          case node
          when TypeNode::Identifier     then resolve_identifier(node)
          when TypeNode::Generic        then resolve_generic(node)
          when TypeNode::IntegerLiteral then Type::Combinator.constant_of(node.value)
          when TypeNode::IndexedAccess  then resolve_indexed_access(node)
          end
        end

        private

        CLASS_SHAPED_HEAD = /\A[A-Z]/
        private_constant :CLASS_SHAPED_HEAD

        def resolve_identifier(node)
          if class_shaped?(node.name)
            chain_type = consult_chain(node)
            return chain_type unless chain_type.nil?

            return Type::Combinator.nominal_of(node.name)
          end

          builtin = ImportedRefinements.lookup(node.name)
          return builtin unless builtin.nil?

          consult_chain(node)
        end

        def resolve_generic(node)
          builtin = try_builtin_parametric(node)
          return builtin unless builtin.nil?

          chain_type = consult_chain(node)
          return chain_type unless chain_type.nil?

          return nil unless class_shaped?(node.head)

          args = resolve_args(node.args)
          return nil if args.nil?

          Type::Combinator.nominal_of(node.head, type_args: args)
        end

        def resolve_indexed_access(node)
          receiver = resolve_ast(node.receiver)
          return nil if receiver.nil?

          key = resolve_ast(node.key)
          return nil if key.nil?

          Type::Combinator.indexed_access(receiver, key)
        end

        def try_builtin_parametric(node)
          try_parametric_type_builder(node) || try_parametric_int_builder(node)
        end

        def try_parametric_type_builder(node)
          builder = ImportedRefinements.parametric_type_builder(node.head)
          return nil if builder.nil?

          args = resolve_args(node.args)
          return nil if args.nil?

          builder.call(args)
        end

        def try_parametric_int_builder(node)
          builder = ImportedRefinements.parametric_int_builder(node.head)
          return nil if builder.nil?

          bounds = node.args.map { |a| a.is_a?(TypeNode::IntegerLiteral) ? a.value : nil }
          return nil if bounds.any?(&:nil?)

          builder.call(bounds)
        end

        def resolve_args(args)
          resolved = args.map { |a| resolve_ast(a) }
          resolved.any?(&:nil?) ? nil : resolved
        end

        def consult_chain(node)
          return nil if @name_scope.nil?

          @name_scope.resolver.resolve(node, @name_scope)
        end

        def class_shaped?(name)
          name.match?(CLASS_SHAPED_HEAD)
        end
      end
      private_constant :Resolver
    end
  end
end
