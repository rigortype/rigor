# frozen_string_literal: true

require "rigor/plugin"

module Rigor
  module Plugin
    # Example plugin: ships the TypeScript-canonical utility-type
    # aliases (`Pick<T, K>`, `Omit<T, K>`, `Partial<T>`,
    # `Required<T>`, `Readonly<T>`) as opt-in vocabulary that
    # resolves to the Rigor-canonical shape-projection type
    # functions introduced in ADR-13.
    #
    # Background. `docs/type-specification/imported-built-in-types.md`
    # § "Deferred or rejected imports" deliberately rejects
    # TypeScript-canonical names from the Rigor core surface: the
    # core stays RBS-canonical per ADR-0 / ADR-1, and the shape
    # semantics live in core under `pick_of[T, K]` /
    # `omit_of[T, K]` / `partial_of[T]` / `required_of[T]` /
    # `readonly_of[T]` (added in ADR-13 slice 4). This plugin
    # ships the TS spellings as an opt-in translation layer for
    # users migrating from TypeScript / Sorbet / Flow-style RBI.
    #
    # Off by default — users add the gem to their `.rigor.yml`
    # plugins list to enable.
    #
    # @example .rigor.yml
    #   plugins:
    #     - gem: rigor-typescript-utility-types
    #
    # Once loaded, an RBS::Extended payload such as
    # `%a{rigor:v1:return: Pick[Foo, :a | :b]}` resolves through
    # the chain: the parser builds a `Generic("Pick", …)` AST,
    # the registry / built-in parametric builders decline, the
    # chain consults `Resolvers::Pick`, which recursively
    # resolves the two arguments to Rigor types and calls
    # `Type::Combinator.pick_of` on them.
    #
    # ## Translation table
    #
    # | TypeScript spelling | Rigor core call                          |
    # | --- | --- |
    # | `Pick<T, K>`     | `Type::Combinator.pick_of(T, K)`     |
    # | `Omit<T, K>`     | `Type::Combinator.omit_of(T, K)`     |
    # | `Partial<T>`     | `Type::Combinator.partial_of(T)`     |
    # | `Required<T>`    | `Type::Combinator.required_of(T)`    |
    # | `Readonly<T>`    | `Type::Combinator.readonly_of(T)`    |
    #
    # ## Deferred TypeScript utility names
    #
    # `Parameters<F>` / `ReturnType<F>` / `InstanceType<C>` /
    # `Awaited<P>` / `Uppercase<S>` / `Lowercase<S>` /
    # `Capitalize<S>` / `Uncapitalize<S>` / `ThisParameterType<F>`
    # / `OmitThisParameter<F>` / `ConstructorParameters<C>` /
    # `NoInfer<T>` are NOT mapped today. The plugin returns `nil`
    # from `#resolve` for those heads, leaving the parser's
    # default Nominal-fallback to produce `Nominal[ReturnType, …]`
    # etc. Function-type projection operators (`params_of[F]` /
    # `return_of[F]`) and class projections (`instance_type[C]`)
    # would unlock these — they remain deferred in core.
    class TypescriptUtilityTypes < Rigor::Plugin::Base
      module Resolvers
        # Common helper: extract a single-arg utility-type Generic
        # whose head matches `name`. Returns the resolved
        # argument's `Rigor::Type` or `nil` (so the chain falls
        # through).
        module SingleArg
          def self.resolve(node, scope, name)
            return nil unless node.is_a?(Rigor::TypeNode::Generic)
            return nil unless node.head == name
            return nil unless node.args.size == 1

            scope.resolver.resolve(node.args[0], scope)
          end
        end

        # Common helper for two-arg utility types.
        module TwoArg
          def self.resolve(node, scope, name)
            return nil unless node.is_a?(Rigor::TypeNode::Generic)
            return nil unless node.head == name
            return nil unless node.args.size == 2

            [scope.resolver.resolve(node.args[0], scope),
             scope.resolver.resolve(node.args[1], scope)]
          end
        end

        # `Pick<T, K>` → `pick_of[T, K]`.
        class Pick < Rigor::Plugin::TypeNodeResolver
          def resolve(node, scope)
            resolved = TwoArg.resolve(node, scope, "Pick")
            return nil if resolved.nil?

            t_type, k_type = resolved
            return nil if t_type.nil? || k_type.nil?

            Rigor::Type::Combinator.pick_of(t_type, k_type)
          end
        end

        # `Omit<T, K>` → `omit_of[T, K]`.
        class Omit < Rigor::Plugin::TypeNodeResolver
          def resolve(node, scope)
            resolved = TwoArg.resolve(node, scope, "Omit")
            return nil if resolved.nil?

            t_type, k_type = resolved
            return nil if t_type.nil? || k_type.nil?

            Rigor::Type::Combinator.omit_of(t_type, k_type)
          end
        end

        # `Partial<T>` → `partial_of[T]`.
        class Partial < Rigor::Plugin::TypeNodeResolver
          def resolve(node, scope)
            t_type = SingleArg.resolve(node, scope, "Partial")
            return nil if t_type.nil?

            Rigor::Type::Combinator.partial_of(t_type)
          end
        end

        # `Required<T>` → `required_of[T]`.
        class Required < Rigor::Plugin::TypeNodeResolver
          def resolve(node, scope)
            t_type = SingleArg.resolve(node, scope, "Required")
            return nil if t_type.nil?

            Rigor::Type::Combinator.required_of(t_type)
          end
        end

        # `Readonly<T>` → `readonly_of[T]`.
        class Readonly < Rigor::Plugin::TypeNodeResolver
          def resolve(node, scope)
            t_type = SingleArg.resolve(node, scope, "Readonly")
            return nil if t_type.nil?

            Rigor::Type::Combinator.readonly_of(t_type)
          end
        end
      end

      manifest(
        id: "typescript-utility-types",
        version: "0.1.0",
        description: "Maps TypeScript-canonical utility-type aliases " \
                     "(Pick, Omit, Partial, Required, Readonly) onto the " \
                     "Rigor-canonical shape-projection type functions.",
        type_node_resolvers: [
          Resolvers::Pick.new,
          Resolvers::Omit.new,
          Resolvers::Partial.new,
          Resolvers::Required.new,
          Resolvers::Readonly.new
        ]
      )
    end

    register(TypescriptUtilityTypes)
  end
end
