# frozen_string_literal: true

require "prism"

module Rigor
  module Plugin
    class Sorbet < Rigor::Plugin::Base
      # Maps Sorbet's type expressions (the AST inside a `sig` block's `params(...)` and `returns(...)`
      # clauses) into Rigor's internal type carriers.
      #
      # | Sorbet form              | Rigor carrier                            |
      # | ------------------------ | ---------------------------------------- |
      # | `Integer` etc.           | `Nominal["Integer"]`                     |
      # | `::Foo::Bar`             | `Nominal["Foo::Bar"]`                    |
      # | `T.untyped`              | `Dynamic[top]`                           |
      # | `T.anything`             | `top`                                    |
      # | `T.noreturn`             | `bot`                                    |
      # | `T.nilable(X)`           | `Union[X, Constant[nil]]`                |
      # | `T.any(A, B, ...)`       | `Union[A, B, ...]`                       |
      # | `T.all(A, B, ...)`       | `Intersection[A, B, ...]`                |
      # | `T::Boolean`             | `Union[Constant[true], Constant[false]]` |
      # | `T::Array[E]`            | `Nominal["Array", [E]]`                  |
      # | `T::Hash[K, V]`          | `Nominal["Hash", [K, V]]`                |
      # | `T::Set[E]`              | `Nominal["Set", [E]]`                    |
      # | `T::Range[E]`            | `Nominal["Range", [E]]`                  |
      # | `T::Enumerable[E]`       | `Nominal["Enumerable", [E]]`             |
      # | `T::Enumerator[E]`       | `Nominal["Enumerator", [E]]`             |
      # | `T::Class[T]`            | `Singleton[T-class-name]` (lossy)        |
      # | `T.class_of(C)`          | `Singleton[C]`                           |
      # | `[A, B]` (tuple in sig)  | `Tuple[A, B]`                            |
      # | `{a: A, b: B}` (shape)   | `HashShape{a: A, b: B}` (closed)         |
      # | `Foo::Bar[A, B]` (user)  | `Nominal["Foo::Bar", [A, B]]`            |
      #
      # Anything else (`T.proc`, `T.attached_class`, `T.self_type`, `T.type_parameter`, `T::Struct` /
      # `T::Enum` subclasses, …) degrades silently to `Dynamic[top]`. The `dynamic.sorbet.unsupported`
      # diagnostic for degraded forms is deferred.
      module TypeTranslator
        BOOLEAN_NAME = "Boolean"

        # `T::*` constants whose `[]` application maps directly onto a Rigor `Nominal` with the matching
        # standard-library class name. Ordering matches the table above for ease of reading.
        T_GENERIC_CLASSES = {
          "Array" => "Array",
          "Hash" => "Hash",
          "Set" => "Set",
          "Range" => "Range",
          "Enumerable" => "Enumerable",
          "Enumerator" => "Enumerator",
          "Enumerator::Lazy" => "Enumerator::Lazy",
          "Enumerator::Chain" => "Enumerator::Chain"
        }.freeze

        module_function

        # @return [Rigor::Type] never `nil`; unrecognised forms degrade to `Type::Combinator.untyped`.
        def translate(node)
          return Rigor::Type::Combinator.untyped if node.nil?

          case node
          when Prism::ConstantReadNode then translate_constant_read(node)
          when Prism::ConstantPathNode then translate_constant_path(node)
          when Prism::CallNode then translate_call(node)
          when Prism::ArrayNode then translate_tuple(node)
          when Prism::HashNode then translate_shape(node)
          else degraded
          end
        end

        def translate_constant_read(node)
          name = node.name.to_s
          return Rigor::Type::Combinator.untyped if name.empty?

          Rigor::Type::Combinator.nominal_of(name)
        end

        def translate_constant_path(node)
          name = constant_path_name(node)
          return degraded if name.nil?

          # Sorbet's `T::Boolean` is a special alias rather than a nominal class, expressed as the Boolean
          # type alias.
          return boolean_type if name == "T::Boolean"

          Rigor::Type::Combinator.nominal_of(name)
        end

        # `Prism::CallNode` covers three distinct surfaces:
        #
        # 1. `T.something(...)` — `untyped` / `anything` / `noreturn` / `nilable` / `any` / `all` /
        #    `class_of`.
        # 2. `T::SomeClass[...]` — the `[]` method on a generic `T::*` constant (slice 3 widening). Maps
        #    to `Nominal[name, type_args]`.
        # 3. `Some::User::Generic[...]` — the `[]` method on any OTHER constant (a user-defined generic
        #    application, e.g. `Mangrove::Result::Ok[String, StandardError]`). Maps to `Nominal[name,
        #    type_args]` so generic carriers authored outside Sorbet's `T::*` set round-trip with their
        #    instantiation intact (the unwrap-site receiver a plugin like rigor-mangrove reads `type_args`
        #    from). Without this branch such forms degraded to `untyped`, silently dropping the
        #    receiver's generic arguments.
        def translate_call(node)
          return translate_t_method(node) if sorbet_t_namespaced?(node.receiver)
          return translate_t_subscript(node) if sorbet_subscript?(node)
          return translate_user_subscript(node) if user_generic_subscript?(node)

          degraded
        end

        # Handles the `T.foo(...)` family.
        def translate_t_method(node)
          case node.name
          when :untyped then Rigor::Type::Combinator.untyped
          when :anything then Rigor::Type::Combinator.top
          when :noreturn then Rigor::Type::Combinator.bot
          when :nilable then translate_nilable(node)
          when :any then translate_any(node)
          when :all then translate_all(node)
          when :class_of then translate_class_of(node)
          else degraded
          end
        end

        def translate_nilable(node)
          inner = first_argument(node)
          return degraded if inner.nil?

          Rigor::Type::Combinator.union(
            translate(inner), Rigor::Type::Combinator.constant_of(nil)
          )
        end

        def translate_any(node)
          args = call_arguments(node)
          return degraded if args.empty?

          Rigor::Type::Combinator.union(*args.map { |arg| translate(arg) })
        end

        def translate_all(node)
          args = call_arguments(node)
          return degraded if args.empty?

          Rigor::Type::Combinator.intersection(*args.map { |arg| translate(arg) })
        end

        # `T.class_of(C)` — singleton-class type for a single constant. Sorbet docs note
        # `T.class_of(MyInterface)` rarely means what users expect (it's the singleton class of
        # `MyInterface`, not "any class implementing the interface"); we honour the literal meaning here
        # and translate to `Singleton[C]`.
        def translate_class_of(node)
          target = first_argument(node)
          name = constant_path_name(target)
          return degraded if name.nil?

          Rigor::Type::Combinator.singleton_of(name)
        end

        # Handles `T::Array[E]`, `T::Hash[K, V]`, etc. The Prism AST for `T::Array[Integer]` is a
        # `CallNode` whose receiver is the `T::Array` `ConstantPathNode` and whose `name` is `:[]`.
        # `T::Class[T]` lands here too; we collapse it to `Singleton[name]` (a deliberate narrowing —
        # `T::Class` is structurally generic in Sorbet, but Rigor's `Singleton` carries class identity only).
        def translate_t_subscript(node)
          base_name = sorbet_subscript_base(node.receiver)
          args = call_arguments(node).map { |arg| translate(arg) }
          mapped = T_GENERIC_CLASSES[base_name]

          if mapped
            Rigor::Type::Combinator.nominal_of(mapped, type_args: args)
          elsif base_name == "Class"
            translate_t_class_subscript(args)
          else
            degraded
          end
        end

        # A user-defined generic application — a `[]` call on a constant that is NOT `T`-rooted, e.g.
        # `Mangrove::Result::Ok[String, StandardError]` or a top-level `Box[Integer]`. Translates to
        # `Nominal[name, type_args]`, recursively translating each argument (so nested `T::Array[...]`
        # inside a user generic still resolves). Ordered AFTER `translate_t_subscript` in `translate_call`,
        # so the `T::*` forms never reach here.
        def user_generic_subscript?(node)
          return false unless node.name == :[]

          receiver = node.receiver
          return false unless receiver.is_a?(Prism::ConstantReadNode) ||
                              receiver.is_a?(Prism::ConstantPathNode)

          # `T::Foo[...]` is handled by translate_t_subscript; only non-`T`-rooted constants are user
          # generics.
          !sorbet_t_qualified?(receiver)
        end

        def translate_user_subscript(node)
          # Parity with translate_constant_path: the constant's rendered name (carrying a leading `::` for
          # absolute paths) becomes the nominal class name.
          name = constant_path_name(node.receiver)
          return degraded if name.nil?

          args = call_arguments(node).map { |arg| translate(arg) }
          Rigor::Type::Combinator.nominal_of(name, type_args: args)
        end

        # `T::Class[T]` — Sorbet's "any class object whose instances are at least `T`". Rigor has no exact
        # analogue (Singleton names a specific class); the closest faithful translation is `Singleton[name]`
        # when `T` is a constant, or `Singleton[Object]` for broader applications. Lossy — the
        # `dynamic.sorbet.degraded` diagnostic for this case is deferred.
        def translate_t_class_subscript(args)
          inner = args.first
          return Rigor::Type::Combinator.singleton_of("Class") if inner.nil?

          case inner
          when Rigor::Type::Nominal then Rigor::Type::Combinator.singleton_of(inner.class_name)
          else Rigor::Type::Combinator.singleton_of("Class")
          end
        end

        # Tuple types in `sig` position appear as bare array literals: `sig { returns([String, Integer]) }`.
        # Each element is itself a type expression we translate recursively.
        def translate_tuple(node)
          elements = node.elements.map { |element| translate(element) }
          Rigor::Type::Combinator.tuple_of(*elements)
        end

        # Shape types in `sig` position appear as bare hash literals with symbol keys:
        # `sig { returns({a: Integer, b: String}) }`. Each value is a type expression; the resulting
        # `HashShape` is closed (no extra keys allowed).
        def translate_shape(node)
          pairs = []
          node.elements.each do |element|
            next unless element.is_a?(Prism::AssocNode)
            next unless element.key.is_a?(Prism::SymbolNode)

            pairs << [element.key.unescaped.to_sym, translate(element.value)]
          end
          Rigor::Type::Combinator.hash_shape_of(pairs)
        end

        # Renders a constant-path node (`Foo::Bar`, `::Foo::Bar`) as a `::`-joined String. Mirrors the
        # helper used by rigor-activerecord's ModelDiscoverer for parity.
        def constant_path_name(node)
          return nil if node.nil?

          case node
          when Prism::ConstantReadNode then node.name.to_s
          when Prism::ConstantPathNode then constant_path_name_for_path(node)
          end
        end

        def constant_path_name_for_path(node)
          parts = []
          current = node
          while current.is_a?(Prism::ConstantPathNode)
            parts.unshift(current.name.to_s)
            current = current.parent
          end
          case current
          when nil
            "::#{parts.join('::')}"
          when Prism::ConstantReadNode
            "#{current.name}::#{parts.join('::')}"
          end
        end

        def sorbet_t_namespaced?(receiver)
          receiver.is_a?(Prism::ConstantReadNode) && receiver.name == :T
        end

        # `T::Array[Integer]` parses as `CallNode(receiver: T::Array, name: :[])`. The receiver is a
        # `ConstantPathNode` rooted at the `T` constant.
        def sorbet_subscript?(node)
          node.name == :[] && sorbet_t_qualified?(node.receiver)
        end

        def sorbet_t_qualified?(node)
          return false unless node.is_a?(Prism::ConstantPathNode)

          # Walk to the root; require that it terminates at a `T` ConstantReadNode (not an absolute `::T`).
          current = node
          current = current.parent while current.is_a?(Prism::ConstantPathNode)
          current.is_a?(Prism::ConstantReadNode) && current.name == :T
        end

        # Strips the leading `T::` from a `T::Foo::Bar` constant-path node, returning `"Foo::Bar"`.
        # Returns nil for shapes that aren't `T`-rooted.
        def sorbet_subscript_base(node)
          return nil unless sorbet_t_qualified?(node)

          parts = []
          current = node
          while current.is_a?(Prism::ConstantPathNode)
            parts.unshift(current.name.to_s)
            current = current.parent
          end
          parts.join("::")
        end

        def first_argument(node)
          node.arguments&.arguments&.first
        end

        def call_arguments(node)
          node.arguments&.arguments || []
        end

        def degraded
          Rigor::Type::Combinator.untyped
        end

        # `T::Boolean` corresponds to the union of the singleton `true` / `false` values, matching how
        # RBS's `bool` would translate. Built from `Constant[true]` / `Constant[false]` so the analyzer's
        # flow-sensitive narrowing recognises the discriminating shape.
        def boolean_type
          Rigor::Type::Combinator.union(
            Rigor::Type::Combinator.constant_of(true),
            Rigor::Type::Combinator.constant_of(false)
          )
        end
      end
    end
  end
end
