# frozen_string_literal: true

module Rigor
  module Inference
    # ADR-20 Slice 2a — node types for the parsed body of a
    # type-function `Definition`. Each node represents one
    # piece of a Rigor-side type expression that the reducer
    # ({HktReducer}) walks against a concrete argument list.
    #
    # Slice 2a ships a programmatic constructor surface only:
    # plugin and Rigor-bundled overlay authors build a body
    # tree by hand using these node types. The string-grammar
    # parser that reads `Definition#body` (the raw String slot
    # already populated by Slice 1's `HktDirectives.parse_define`)
    # into a tree is Slice 2b's deliverable; until it ships, the
    # `body` String stays opaque and `body_tree` is the
    # evaluable form.
    #
    # The five node types cover the JSON.parse and dry-monads
    # use cases ADR-20 § Implementation slicing names as
    # near-term adopters:
    #
    # - {TypeLeaf}    — wraps a fully-built `Rigor::Type`
    #   (use for atoms like `nil`, `Constant<true>`,
    #   `Nominal[Integer]`).
    # - {Param}       — reference to a formal parameter
    #   declared in the enclosing `Definition#params` list
    #   (e.g. `K` in `json::value[K]`). The reducer
    #   substitutes from the application's `args`.
    # - {AppRef}      — abstract HKT application; the reducer
    #   resolves it via the registry, or returns the `App`
    #   carrier as-is when the reference is self-recursive
    #   (lazy "tying-the-knot" handling that lets recursive
    #   sums like `json::value` reduce without infinite
    #   expansion).
    # - {Union}       — N-ary union of arms.
    # - {NominalApp}  — parameterised nominal class
    #   (`Array[X]`, `Hash[K, V]`) whose type args are
    #   themselves body nodes.
    #
    # Every node is a frozen `Data.define` value; structural
    # equality is by-field.
    module HktBody
      # Wraps a pre-built `Rigor::Type` value. Use for atoms
      # that need no substitution (e.g. `Nominal[Integer]`,
      # `Constant<nil>`).
      TypeLeaf = Data.define(:type) do
        def initialize(type:)
          raise ArgumentError, "type must not be nil" if type.nil?

          super
        end
      end

      # Reference to a formal parameter the enclosing
      # `Definition#params` declared. The reducer substitutes
      # this node with the matching positional arg from the
      # `App` being reduced; an unknown name raises during
      # reduction (the parser, when it ships, MUST reject
      # unknown names earlier).
      Param = Data.define(:name) do
        def initialize(name:)
          raise ArgumentError, "name must be a Symbol, got #{name.class}" unless name.is_a?(Symbol)

          super
        end
      end

      # Abstract HKT application — the reducer's primary
      # recursion point. `uri` is a namespaced Symbol
      # matching some `Registration` in the registry; `args`
      # is an Array of body nodes (each gets substituted /
      # resolved before being used).
      AppRef = Data.define(:uri, :args) do
        def initialize(uri:, args:)
          raise ArgumentError, "uri must be a Symbol, got #{uri.class}" unless uri.is_a?(Symbol)
          raise ArgumentError, "uri must be namespaced as `:a::b`, got #{uri.inspect}" unless uri.to_s.include?("::")
          raise ArgumentError, "args must be an Array, got #{args.class}" unless args.is_a?(Array)
          raise ArgumentError, "args must be non-empty" if args.empty?

          super(uri: uri, args: args.dup.freeze)
        end
      end

      # N-ary union. The reducer builds the result through
      # `Type::Combinator.union(*reduced_arms)` so
      # normalization (flattening, dedup, Bot drop) applies.
      Union = Data.define(:arms) do
        def initialize(arms:)
          raise ArgumentError, "arms must be an Array, got #{arms.class}" unless arms.is_a?(Array)
          raise ArgumentError, "arms must be non-empty" if arms.empty?

          super(arms: arms.dup.freeze)
        end
      end

      # Parameterised nominal class. `class_name` is the
      # Ruby class name (`"Array"`, `"Hash"`); `args` is an
      # Array of body nodes for the type arguments. The
      # reducer builds the result through
      # `Type::Combinator.nominal_of(class_name, type_args:
      # reduced_args)`.
      NominalApp = Data.define(:class_name, :args) do
        def initialize(class_name:, args:)
          unless class_name.is_a?(String) && !class_name.empty?
            raise ArgumentError, "class_name must be a non-empty String, got #{class_name.inspect}"
          end
          raise ArgumentError, "args must be an Array, got #{args.class}" unless args.is_a?(Array)
          raise ArgumentError, "args must be non-empty (use TypeLeaf with Nominal for raw class refs)" if args.empty?

          super(class_name: class_name, args: args.dup.freeze)
        end
      end
    end
  end
end
