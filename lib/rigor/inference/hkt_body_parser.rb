# frozen_string_literal: true

require_relative "hkt_body"
require_relative "../type"

module Rigor
  module Inference
    # ADR-20 slice 2b — parses the body of an
    # `HktRegistry::Definition` (a `String`, as populated by
    # Slice 1's `HktDirectives.parse_define` from
    # `%a{rigor:v1:hkt_define}` payloads) into the `HktBody`
    # node tree the Slice 2a reducer evaluates against.
    #
    # The minimum-viable grammar covered here is the
    # union-of-atoms-and-parameterised-forms subset of ADR-20
    # § D3 — sufficient for `JSON.parse`'s `json::value`
    # recursive sum and for any other recursive-data-shape
    # signatures (Lisp value trees, dry-types refinements
    # without conditionals). The conditional / indexed-access
    # forms (`E <: T ? A : B`, `E in [k1, k2]`) drafted in D3
    # remain a follow-up slice — bodies that contain `?`
    # raise `ParseError` and the calling directive parser
    # drops the body_tree (the body String remains stored and
    # the reducer falls back to `app.bound`).
    #
    # ## Grammar (slice 2b)
    #
    #     body         := union
    #     union        := type_expr ("|" type_expr)*
    #     type_expr    := atom | nominal_app | app_ref | param
    #     atom         := "nil" | "true" | "false" | "bool" | "untyped"
    #     param        := UCNAME   (when UCNAME ∈ params)
    #     nominal_app  := class_name ("[" type_expr ("," type_expr)* "]")?
    #     class_name   := "::"? UCNAME ("::" UCNAME)*
    #     app_ref      := "App" "[" uri "," type_expr ("," type_expr)* "]"
    #     uri          := IDENT ("::" IDENT)+
    #     UCNAME       := /[A-Z]\w*/
    #     IDENT        := /[a-z_]\w*/
    #
    # ## Disambiguation
    #
    # The same syntactic UCNAME spells both a parameter
    # reference (`K` when `params = [:K]`) and a nominal class
    # name (`Integer`). The parser resolves by checking the
    # `params` set passed to {.parse}; an unknown UCNAME is
    # treated as a nominal class name. `App` is reserved at
    # the head position of an `App[...]` form; using `App` as
    # a class name is therefore not supported.
    #
    # Atoms are kept verbatim as `HktBody::TypeLeaf` nodes
    # wrapping the appropriate `Rigor::Type::*` carrier:
    # `nil` / `true` / `false` produce `Constant` carriers;
    # `bool` produces the `Constant<true> | Constant<false>`
    # union; `untyped` produces `Combinator.untyped`
    # (i.e. `Dynamic[Top]`). Nominal class names produce raw
    # `Type::Nominal` carriers (no `name_scope` resolution at
    # this slice — the reducer trusts the name verbatim).
    module HktBodyParser
      class ParseError < StandardError; end

      module_function

      def parse(string, params:)
        raise ArgumentError, "string must be a String, got #{string.class}" unless string.is_a?(String)
        raise ArgumentError, "params must be an Array, got #{params.class}" unless params.is_a?(Array)

        params_set = params.to_h { |p| [p.to_sym, true] }
        tokens = Tokenizer.new(string).tokenize
        parser = Parser.new(tokens, params_set)
        result = parser.parse_union
        parser.expect_eof!
        result
      end

      Token = Data.define(:kind, :value, :pos)

      class Tokenizer
        SCANNER_REGEX = /
          \G
          (?:
            (?<ws>\s+)
          | (?<lb>\[)
          | (?<rb>\])
          | (?<lparen>\()
          | (?<rparen>\))
          | (?<comma>,)
          | (?<pipe>\|)
          | (?<sub><:)
          | (?<eq>==)
          | (?<sep>::)
          | (?<colon>:(?!:))
          | (?<question>\?)
          | (?<ident>[a-z_][a-zA-Z0-9_]*)
          | (?<ucname>[A-Z][a-zA-Z0-9_]*)
          )
        /x

        def initialize(string)
          @string = string
        end

        TOKEN_KINDS = SCANNER_REGEX.named_captures.keys.freeze
        private_constant :TOKEN_KINDS

        def tokenize
          tokens = []
          pos = 0
          while pos < @string.size
            match = SCANNER_REGEX.match(@string, pos)
            raise ParseError, "unexpected character at position #{pos}: #{@string[pos].inspect}" if match.nil?

            kind = TOKEN_KINDS.find { |k| match[k] }
            raise ParseError, "internal tokenizer error at position #{pos}" if kind.nil?

            value = match[kind.to_sym]
            raise ParseError, "internal tokenizer error: no match for #{kind}" if value.nil?

            pos += value.size
            next if kind == "ws"

            tokens << Token.new(kind: kind.to_sym, value: value, pos: pos - value.size)
          end
          tokens
        end
      end

      class Parser
        def initialize(tokens, params_set)
          @tokens = tokens
          @pos = 0
          @params_set = params_set
        end

        def parse_union
          arms = [parse_type_expr]
          while peek_kind == :pipe
            consume
            arms << parse_type_expr
          end
          return arms.first if arms.size == 1

          HktBody::Union.new(arms: arms)
        end

        def parse_type_expr
          tok = peek
          raise ParseError, "unexpected end of input; expected type expression" if tok.nil?

          case tok.kind
          when :lparen  then parse_conditional
          when :ident   then parse_lowercase_atom
          when :ucname  then parse_ucname_form
          when :sep     then parse_classname_with_leading_sep
          else
            raise ParseError, "unexpected token #{tok.kind} (#{tok.value.inspect}) at position #{tok.pos}"
          end
        end

        # ADR-20 § D3 conditional parser. Grammar:
        #
        #     conditional := "(" test "?" union ":" union ")"
        #     test        := type_expr ("<:" | "==") type_expr
        #
        # Parens delimit a conditional unambiguously — bare
        # `(type_expr)` grouping is not supported at this slice
        # (no use case yet). Branches can be unions; test sides
        # are single arms (wrap in `App[my_union, ...]` if you
        # need a union there). `in [opt1, opt2]` membership
        # tests are programmatically supported via
        # `HktBody::TestMembership` but the parser does not yet
        # recognise the `in` keyword (no concrete demand yet).
        def parse_conditional
          expect!(:lparen)
          test = parse_test
          expect!(:question)
          then_branch = parse_union
          expect!(:colon)
          else_branch = parse_union
          expect!(:rparen)
          HktBody::Conditional.new(test: test, then_branch: then_branch, else_branch: else_branch)
        end

        def parse_test
          left = parse_type_expr
          op = peek
          case op&.kind
          when :sub
            consume
            HktBody::TestSubtype.new(left: left, right: parse_type_expr)
          when :eq
            consume
            HktBody::TestEquality.new(left: left, right: parse_type_expr)
          when :ident
            parse_in_membership(left, op_token: op)
          else
            actual = op.nil? ? "end of input" : "#{op.kind} (#{op.value.inspect})"
            raise ParseError, "expected `<:`, `==`, or `in` in conditional test, got #{actual}"
          end
        end

        # `left in [opt1, opt2, ...]` membership test.
        # Distinguished from a lowercase atom by the
        # subsequent `[` — the only place an identifier
        # `in` is permitted at this position is membership
        # syntax.
        def parse_in_membership(left, op_token:)
          unless op_token.value == "in"
            raise ParseError,
                  "expected `<:`, `==`, or `in` in conditional test, got ident (#{op_token.value.inspect})"
          end

          consume # in
          expect!(:lb)
          options = [parse_type_expr]
          while peek_kind == :comma
            consume
            options << parse_type_expr
          end
          expect!(:rb)
          HktBody::TestMembership.new(left: left, options: options)
        end

        def parse_lowercase_atom
          tok = consume
          type = case tok.value
                 when "nil"     then Type::Constant.new(nil)
                 when "true"    then Type::Constant.new(true)
                 when "false"   then Type::Constant.new(false)
                 when "bool"    then Type::Combinator.union(Type::Constant.new(true), Type::Constant.new(false))
                 when "untyped" then Type::Combinator.untyped
                 else raise ParseError, "unknown atom #{tok.value.inspect} at position #{tok.pos}"
                 end
          HktBody::TypeLeaf.new(type: type)
        end

        def parse_ucname_form
          tok = peek
          return parse_app_ref if tok.value == "App"

          if @params_set.key?(tok.value.to_sym) && !class_continuation?
            consume
            return HktBody::Param.new(name: tok.value.to_sym)
          end

          parse_nominal_or_param_with_args
        end

        # Returns true when the current UCName is followed by
        # `::` (qualified class name continuation) or `[`
        # (parameterised application). In either case the
        # token is a nominal, not a param ref — Slice 2b's
        # `Param` nodes are always single bare identifiers.
        def class_continuation?
          next_tok = @tokens[@pos + 1]
          next_tok && %i[sep lb].include?(next_tok.kind)
        end

        def parse_nominal_or_param_with_args
          class_name = parse_class_name
          if peek_kind == :lb
            consume
            args = parse_arg_list
            expect!(:rb)
            HktBody::NominalApp.new(class_name: class_name, args: args)
          else
            HktBody::TypeLeaf.new(type: Type::Nominal.new(class_name))
          end
        end

        def parse_classname_with_leading_sep
          # The leading "::" form (`::Foo::Bar`). Consume the
          # separator so the rest threads through parse_class_name.
          consume
          tok = peek
          raise ParseError, "expected class name after `::`" if tok.nil? || tok.kind != :ucname

          parse_nominal_or_param_with_args
        end

        def parse_class_name
          parts = [expect!(:ucname).value]
          while peek_kind == :sep && @tokens[@pos + 1]&.kind == :ucname
            consume # ::
            parts << expect!(:ucname).value
          end
          parts.join("::")
        end

        def parse_app_ref
          tok = consume
          raise ParseError, "expected `App[...]`, got #{tok.value.inspect}" unless tok.value == "App"

          expect!(:lb)
          uri = parse_uri
          expect!(:comma)
          args = parse_arg_list
          expect!(:rb)
          HktBody::AppRef.new(uri: uri, args: args)
        end

        def parse_uri
          parts = [expect!(:ident).value]
          while peek_kind == :sep
            consume
            parts << expect!(:ident).value
          end
          raise ParseError, "uri must be namespaced (`a::b`), got #{parts.first.inspect}" if parts.size < 2

          parts.join("::").to_sym
        end

        # Arg list for `Foo[A, B, C]` and `App[uri, A, B]`
        # forms. Each arg is parsed as a union so per-arg
        # `A | B` forms work (`Array[K | nil]`); the COMMA
        # at the top level still separates args, so
        # `Hash[K, V]` reads as two args (each a single-arm
        # union that collapses to the arm) rather than one
        # union of two.
        def parse_arg_list
          args = [parse_union]
          while peek_kind == :comma
            consume
            args << parse_union
          end
          args
        end

        def expect_eof!
          return if @pos >= @tokens.size

          tok = @tokens[@pos]
          raise ParseError, "expected end of input, got #{tok.kind} (#{tok.value.inspect}) at position #{tok.pos}"
        end

        private

        def peek
          @tokens[@pos]
        end

        def peek_kind
          @tokens[@pos]&.kind
        end

        def consume
          tok = @tokens[@pos]
          @pos += 1
          tok
        end

        def expect!(kind)
          tok = @tokens[@pos]
          if tok.nil? || tok.kind != kind
            actual = tok.nil? ? "end of input" : "#{tok.kind} (#{tok.value.inspect})"
            raise ParseError, "expected #{kind}, got #{actual}"
          end
          @pos += 1
          tok
        end
      end
    end
  end
end
