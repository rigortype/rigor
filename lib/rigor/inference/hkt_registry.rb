# frozen_string_literal: true

module Rigor
  module Inference
    # ADR-20 § "Decision D1 / D2" — registry of Lightweight HKT
    # tag registrations + type-function bodies parsed off the
    # `%a{rigor:v1:hkt_register: ...}` /
    # `%a{rigor:v1:hkt_define: ...}` annotations in shipped
    # `.rbs` files.
    #
    # Slice 1 keeps the registry **opaque**: it stores the
    # registration metadata (arity, variance, bound) and the
    # un-evaluated definition body (a raw String — Slice 2
    # introduces the conditional / indexed-access evaluator that
    # parses the body and reduces `Type::App` instances against
    # it). The carrier never needs to read from the registry
    # because Slice 1's `Type::App` carries its `bound` directly;
    # the registry exists at this slice solely so the parser
    # round-trip and downstream slices have a stable target API.
    #
    # The registry is immutable after construction. Callers that
    # need to extend it (e.g. plugin registrations layered on top
    # of stdlib registrations) MUST build a new registry via
    # `merge` rather than mutating an existing one. This keeps the
    # registry shareable across Ractor boundaries per ADR-15.
    class HktRegistry
      # Frozen value object recording one tag registration.
      #
      # - `uri`: namespaced Symbol per ADR-20 WD1 (must include
      #   `"::"`).
      # - `arity`: positive Integer — the number of formal
      #   parameters the registered constructor takes.
      # - `variance`: ordered Array of Symbols, one per
      #   parameter, each `:out` (covariant), `:in`
      #   (contravariant), or `:inv` (invariant; default).
      # - `bound`: a `Rigor::Type` to erase to when an `App`
      #   referring to this URI cannot be reduced. Defaults to
      #   `Dynamic[Top]` (the parser fills in the default when
      #   the annotation omits `bound:`).
      Registration = Data.define(:uri, :arity, :variance, :bound) do
        def initialize(uri:, arity:, variance:, bound:)
          raise ArgumentError, "uri must be a Symbol, got #{uri.class}" unless uri.is_a?(Symbol)
          raise ArgumentError, "uri must be namespaced as `:a::b`, got #{uri.inspect}" unless uri.to_s.include?("::")
          unless arity.is_a?(Integer) && arity.positive?
            raise ArgumentError,
                  "arity must be a positive Integer, got #{arity.inspect}"
          end
          raise ArgumentError, "variance must be an Array, got #{variance.class}" unless variance.is_a?(Array)
          raise ArgumentError, "variance must have #{arity} entries, got #{variance.size}" unless variance.size == arity

          variance.each do |v|
            unless %i[out in inv].include?(v)
              raise ArgumentError, "variance entries must be :out, :in, or :inv, got #{v.inspect}"
            end
          end
          raise ArgumentError, "bound must not be nil" if bound.nil?

          super(uri: uri, arity: arity, variance: variance.dup.freeze, bound: bound)
        end
      end

      # Frozen value object recording the un-evaluated body of
      # one type-function definition. Slice 1 stores `body` as a
      # raw String — the literal payload text from the `%a{...}`
      # annotation; Slice 2's evaluator parses it into a
      # conditional / indexed-access expression tree.
      Definition = Data.define(:uri, :params, :body, :source_path, :source_line) do
        def initialize(uri:, params:, body:, source_path: nil, source_line: nil)
          raise ArgumentError, "uri must be a Symbol, got #{uri.class}" unless uri.is_a?(Symbol)
          raise ArgumentError, "params must be an Array, got #{params.class}" unless params.is_a?(Array)

          params.each do |p|
            raise ArgumentError, "params entries must be Symbols, got #{p.inspect}" unless p.is_a?(Symbol)
          end
          raise ArgumentError, "body must be a String, got #{body.class}" unless body.is_a?(String)

          super(uri: uri, params: params.dup.freeze, body: body, source_path: source_path, source_line: source_line)
        end
      end

      attr_reader :registrations, :definitions

      # @param registrations [Array<Registration>]
      # @param definitions [Array<Definition>]
      def initialize(registrations: [], definitions: [])
        @registrations = registrations.to_h { |r| [r.uri, r] }.freeze
        @definitions = definitions.to_h { |d| [d.uri, d] }.freeze
        freeze
      end

      def registered?(uri)
        @registrations.key?(uri)
      end

      def defined?(uri)
        @definitions.key?(uri)
      end

      def registration(uri)
        @registrations[uri]
      end

      def definition(uri)
        @definitions[uri]
      end

      # @return [HktRegistry] a new registry whose entries are
      #   the union of this registry's and `other`'s. On URI
      #   collisions `other`'s entries win (last-write-wins; OQ3
      #   tentative).
      def merge(other)
        raise ArgumentError, "merge target must be an HktRegistry, got #{other.class}" unless other.is_a?(HktRegistry)

        self.class.new(
          registrations: @registrations.merge(other.registrations).values,
          definitions: @definitions.merge(other.definitions).values
        )
      end

      def empty?
        @registrations.empty? && @definitions.empty?
      end

      EMPTY = new.freeze
    end
  end
end
