# frozen_string_literal: true

require "prism"

require_relative "type_translator"

module Rigor
  module Plugin
    class Sorbet < Rigor::Plugin::Base
      # Mini-interpreter for the chained-call expression that
      # makes up a Sorbet `sig` block. The block body is always
      # a single expression — Sorbet's docs (`sigs.md`) show the
      # full grammar:
      #
      #   sig { params(x: T, y: T).returns(U) }
      #   sig { void }
      #   sig { abstract.params(...).returns(...) }
      #   sig { override.params(...).void }
      #   sig { type_parameters(:U).params(...).returns(...) }
      #   sig do
      #     params(...)
      #     .returns(...)
      #   end
      #
      # The parser walks the chain right-to-left, gathering
      # whatever it recognises (`params` / `returns` / `void` /
      # `abstract` / `override` / `overridable` / `final` /
      # `type_parameters` / `checked` / `on_failure`) into a
      # frozen result hash. Slice 1 wires the parsed structure
      # into {MethodSignature}; later slices will start *acting*
      # on the modifiers and `type_parameters`.
      #
      # The parser is intentionally tolerant — unknown chain
      # nodes degrade to "the rest of the chain is opaque" rather
      # than raising. The plugin emits a diagnostic
      # (`plugin.sorbet.parse-error`) only when the entire chain
      # fails to yield either a `returns` or a `void`.
      module SigParser
        # Modifiers we recognise at any position in the chain.
        # Stored in `:modifiers` on the parse result.
        RECOGNISED_MODIFIERS = %i[abstract override overridable final].freeze

        # Sorbet runtime-only chain steps. Recognised so the
        # parser doesn't degrade the whole sig when it sees them,
        # but their payload is intentionally discarded.
        RUNTIME_ONLY_STEPS = %i[checked on_failure].freeze

        ParseResult = Data.define(:return_type, :params, :modifiers, :void) do
          def void? = void
        end

        ParseError = Data.define(:reason, :node)

        module_function

        # @param sig_call [Prism::CallNode] the `sig { ... }` /
        #   `sig do ... end` call.
        # @return [ParseResult, ParseError]
        def parse(sig_call)
          return ParseError.new(reason: :no_block, node: sig_call) if sig_call.block.nil?

          body = sig_call.block.body
          chain_root = first_statement(body)
          return ParseError.new(reason: :empty_block, node: sig_call) if chain_root.nil?

          fold_chain(chain_root, sig_call)
        end

        def first_statement(body)
          case body
          when Prism::StatementsNode then body.body.first
          else body
          end
        end

        # Walks the chain bottom-up. Each chain link is a
        # `Prism::CallNode` whose receiver is the next link;
        # `params` / `returns` / `void` may appear at any
        # position, so we accumulate their effect into a
        # mutable hash and freeze on the way out.
        def fold_chain(node, sig_call)
          accumulator = { return_type: nil, params: {}, modifiers: [], void: false, terminus_kind: nil }
          current = node

          while current.is_a?(Prism::CallNode)
            case current.name
            when :returns
              accumulator[:return_type] = TypeTranslator.translate(first_argument(current))
              accumulator[:terminus_kind] ||= :returns
            when :void
              accumulator[:void] = true
              accumulator[:terminus_kind] ||= :void
            when :params
              accumulator[:params].merge!(parse_params(current))
            when :type_parameters
              # Slice 1: recognise to suppress the degraded
              # path; widen translation in slice 3.
            when *RECOGNISED_MODIFIERS
              accumulator[:modifiers] << current.name
            when *RUNTIME_ONLY_STEPS
              # Discard payload; runtime-only.
            else
              # Unknown chain link — stop folding and treat
              # whatever we accumulated so far as the result.
              break
            end
            current = current.receiver
          end

          return ParseError.new(reason: :missing_returns_or_void, node: sig_call) if accumulator[:terminus_kind].nil?

          ParseResult.new(
            return_type: resolve_return_type(accumulator),
            params: accumulator[:params].freeze,
            modifiers: accumulator[:modifiers].uniq.freeze,
            void: accumulator[:void]
          )
        end

        # `void` and `returns(T)` share the slot; if both are
        # present (unusual but parseable), `returns(T)` wins
        # because Sorbet's static side treats `void` as
        # "discard the value" — when the user explicitly named
        # `T`, that's the more informative shape.
        def resolve_return_type(accumulator)
          accumulator[:return_type] || Rigor::Type::Combinator.untyped
        end

        # `params(x: Integer, y: T.nilable(String))` — extracts
        # the `KeywordHashNode` AST and translates each value.
        # The result is `{ Symbol => Rigor::Type }`. Splat /
        # double-splat / unrecognised keys degrade silently
        # (slice 1 behaviour).
        def parse_params(call_node)
          args = call_node.arguments&.arguments || []
          first = args.first
          return {} unless first.is_a?(Prism::KeywordHashNode)

          first.elements.each_with_object({}) do |element, into|
            next unless element.is_a?(Prism::AssocNode)
            next unless element.key.is_a?(Prism::SymbolNode)

            key = element.key.unescaped.to_sym
            into[key] = TypeTranslator.translate(element.value)
          end
        end

        def first_argument(call_node)
          call_node.arguments&.arguments&.first
        end
      end
    end
  end
end
